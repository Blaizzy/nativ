import AppKit
import AVFoundation
import NativServerKit

struct VoiceTranscriptionConfiguration {
    let modelSearchPath: String
    let additionalModelSearchPaths: [String]
    let selectedModelID: String?
    let languageModelID: String?
    let serverBaseURL: URL
    let serverAPIKey: String?
    let serverIsRunning: Bool
}

@MainActor
final class VoiceCaptureCoordinator {
    var transcriptionConfigurationProvider: (() -> VoiceTranscriptionConfiguration?)?
    var onOpenSpeechModels: (() -> Void)?

    private let shortcutMonitor = FnControlShortcutMonitor()
    private let recorder = VoiceAudioRecorder()
    private let overlay = VoiceCaptureOverlayController()
    private let analytics = AudioAnalyticsStore.shared
    private var permissionTask: Task<Void, Never>?
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    private var audioDeletionTasks: [URL: Task<Void, Never>] = [:]
    private var insertionTarget: VoiceTranscriptInsertionTarget?
    private var activeOverlayTranscriptionID: UUID?
    private var isShortcutHeld = false
    private var isHandsFreeMode = false
    private var isPresentingAlert = false
    private var hasShownInsertionPermissionAlert = false

    init() {
        shortcutMonitor.onChange = { [weak self] isHeld in
            self?.handleShortcutChange(isHeld)
        }
        shortcutMonitor.onRetry = { [weak self] in
            self?.retryLastTranscription()
        }
        shortcutMonitor.onHandsFreeToggle = { [weak self] in
            self?.toggleHandsFreeCapture()
        }
        recorder.onMeterUpdate = { [weak self] level, elapsed in
            self?.overlay.update(level: level, elapsed: elapsed)
        }
    }

    func start() {
        scheduleExistingAudioDeletion()
        if let directory = try? VoiceAudioRecorder.recordingsDirectory {
            analytics.importTranscripts(in: directory)
        }
        shortcutMonitor.start()
    }

    func stop() {
        permissionTask?.cancel()
        permissionTask = nil
        transcriptionTasks.values.forEach { $0.cancel() }
        transcriptionTasks.removeAll()
        audioDeletionTasks.values.forEach { $0.cancel() }
        audioDeletionTasks.removeAll()
        shortcutMonitor.stop()
        recorder.stop()
        if let directory = try? VoiceAudioRecorder.recordingsDirectory {
            VoiceAudioRetention.removeAllAudioFiles(in: directory)
        }
        overlay.hide()
        activeOverlayTranscriptionID = nil
        insertionTarget = nil
        isShortcutHeld = false
        isHandsFreeMode = false
    }

    func showRecordingsInFinder() {
        guard let directory = try? VoiceAudioRecorder.recordingsDirectory else {
            return
        }
        NSWorkspace.shared.open(directory)
    }

    private func handleShortcutChange(_ isHeld: Bool) {
        guard !isHandsFreeMode else {
            return
        }
        isShortcutHeld = isHeld
        if isHeld {
            beginCapture()
        } else {
            endCapture()
        }
    }

    private func toggleHandsFreeCapture() {
        if isHandsFreeMode {
            isHandsFreeMode = false
            isShortcutHeld = false
            endCapture()
            return
        }

        guard !isShortcutHeld, !recorder.isRecording else {
            return
        }
        isHandsFreeMode = true
        isShortcutHeld = true
        beginCapture()
    }

    private func beginCapture() {
        permissionTask?.cancel()
        activeOverlayTranscriptionID = nil
        insertionTarget = VoiceTranscriptInserter.captureTarget()
        overlay.show(at: NSEvent.mouseLocation)
        permissionTask = Task { [weak self] in
            guard let self else {
                return
            }
            let isAuthorized = await Self.requestMicrophoneAccess()
            guard !Task.isCancelled, self.isShortcutHeld else {
                return
            }
            guard isAuthorized else {
                self.overlay.showFailure()
                return
            }

            do {
                try self.recorder.start(
                    deviceUniqueID: AudioInputDevicePreferences.shared.effectiveDeviceID
                )
                self.overlay.didStartRecording()
            } catch {
                NSLog("Nativ voice recording failed to start: %@", error.localizedDescription)
                self.overlay.showFailure()
            }
        }
    }

    private func endCapture() {
        permissionTask?.cancel()
        permissionTask = nil
        let target = insertionTarget
        insertionTarget = nil
        if let recordingURL = recorder.stop() {
            NSLog("Nativ saved voice recording to %@", recordingURL.path)
            scheduleAudioDeletion(recordingURL)
            let overlayTranscriptionID = UUID()
            activeOverlayTranscriptionID = overlayTranscriptionID
            overlay.waitForTranscription()
            transcribe(
                recordingURL,
                target: target,
                durationSeconds: recorder.lastRecordingDuration,
                overlayTranscriptionID: overlayTranscriptionID
            )
            return
        }
        activeOverlayTranscriptionID = nil
        overlay.hide()
    }

    private func retryLastTranscription() {
        guard !recorder.isRecording else {
            return
        }
        guard let directory = try? VoiceAudioRecorder.recordingsDirectory else {
            showRecentRecordingUnavailable()
            return
        }

        VoiceAudioRetention.removeExpiredAudioFiles(in: directory)
        guard let recordingURL = VoiceAudioRetention.latestAudioFile(in: directory) else {
            showRecentRecordingUnavailable()
            return
        }

        let target = VoiceTranscriptInserter.captureTarget()
        NSLog("Nativ retrying voice transcription from %@", recordingURL.path)
        transcribe(recordingURL, target: target, durationSeconds: nil)
    }

    private func scheduleExistingAudioDeletion() {
        guard let directory = try? VoiceAudioRecorder.recordingsDirectory else {
            return
        }
        VoiceAudioRetention.removeExpiredAudioFiles(in: directory)
        for audioURL in VoiceAudioRetention.audioFiles(in: directory) {
            scheduleAudioDeletion(audioURL)
        }
    }

    private func scheduleAudioDeletion(_ audioURL: URL) {
        let standardizedURL = audioURL.standardizedFileURL
        audioDeletionTasks[standardizedURL]?.cancel()
        let delay = VoiceAudioRetention.deletionDelay(for: standardizedURL)
        let task = Task { [weak self] in
            if delay > 0 {
                do {
                    let milliseconds = Int64((delay * 1_000).rounded(.up))
                    try await Task.sleep(for: .milliseconds(milliseconds))
                } catch {
                    return
                }
            }

            if VoiceAudioRetention.removeAudioFile(at: standardizedURL) {
                NSLog(
                    "Nativ removed temporary voice recording at %@",
                    standardizedURL.path
                )
            }
            self?.audioDeletionTasks[standardizedURL] = nil
        }
        audioDeletionTasks[standardizedURL] = task
    }

    private func transcribe(
        _ recordingURL: URL,
        target: VoiceTranscriptInsertionTarget?,
        durationSeconds: TimeInterval?,
        overlayTranscriptionID: UUID? = nil
    ) {
        let audioData: Data
        do {
            audioData = try Data(contentsOf: recordingURL)
        } catch {
            finishOverlayTranscription(overlayTranscriptionID)
            showRecentRecordingUnavailable()
            return
        }

        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.transcriptionTasks[taskID] = nil
            }
            guard let configuration = self.transcriptionConfigurationProvider?() else {
                self.finishOverlayTranscription(overlayTranscriptionID)
                return
            }

            let installedModels: [LocalModel]
            do {
                installedModels = try await LocalModelDiscovery.scan(
                    path: configuration.modelSearchPath,
                    additionalPaths: configuration.additionalModelSearchPaths
                )
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self.finishOverlayTranscription(overlayTranscriptionID)
                self.showMissingSpeechModelAlert()
                return
            }

            guard !Task.isCancelled else {
                return
            }
            guard let requestConfiguration = self.transcriptionConfigurationProvider?() else {
                self.finishOverlayTranscription(overlayTranscriptionID)
                return
            }
            guard let modelID = LocalModelDiscovery.speechToTextModelID(
                in: installedModels,
                selectedModelID: requestConfiguration.selectedModelID
            ) else {
                self.finishOverlayTranscription(overlayTranscriptionID)
                self.showMissingSpeechModelAlert()
                return
            }
            guard requestConfiguration.serverIsRunning else {
                self.finishOverlayTranscription(overlayTranscriptionID)
                self.showTranscriptionError(
                    title: "Nativ Server Is Not Running",
                    message: "Start the Nativ server, then record again to transcribe the audio."
                )
                return
            }

            do {
                let client = NativAudioClient(
                    baseURL: requestConfiguration.serverBaseURL,
                    apiKey: requestConfiguration.serverAPIKey
                )
                let result = try await client.transcribe(
                    audioData: audioData,
                    fileName: recordingURL.lastPathComponent,
                    model: modelID
                )
                guard !Task.isCancelled else {
                    return
                }

                let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !transcript.isEmpty else {
                    self.handleEmptyTranscription(
                        recordingURL,
                        overlayTranscriptionID: overlayTranscriptionID
                    )
                    return
                }
                let transcriptURL = recordingURL
                    .deletingPathExtension()
                    .appendingPathExtension("txt")
                try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
                self.analytics.upsertTranscription(
                    recordingURL: recordingURL,
                    transcript: transcript,
                    durationSeconds: durationSeconds,
                    modelID: modelID,
                    applicationName: target?.applicationName
                )

                let insertedAtCursor = await VoiceTranscriptInserter.insertAtCursor(
                    transcript,
                    target: target
                )
                guard !Task.isCancelled else {
                    return
                }
                NSLog(
                    "Nativ saved voice transcript to %@ using %@",
                    transcriptURL.path,
                    modelID
                )
                self.finishOverlayTranscription(overlayTranscriptionID)
                if !insertedAtCursor {
                    self.showInsertionPermissionAlertIfNeeded()
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                if Self.isEmptyTranscriptionError(error) {
                    self.handleEmptyTranscription(
                        recordingURL,
                        overlayTranscriptionID: overlayTranscriptionID
                    )
                    return
                }
                self.finishOverlayTranscription(overlayTranscriptionID)
                self.showTranscriptionError(
                    title: "Transcription Failed",
                    message: error.localizedDescription
                )
            }
        }
        transcriptionTasks[taskID] = task
    }

    private func handleEmptyTranscription(
        _ recordingURL: URL,
        overlayTranscriptionID: UUID?
    ) {
        NSLog(
            "Nativ transcription produced no text for %@",
            recordingURL.lastPathComponent
        )
        guard !isShortcutHeld, !recorder.isRecording else {
            return
        }
        guard let overlayTranscriptionID,
              activeOverlayTranscriptionID == overlayTranscriptionID
        else {
            return
        }
        activeOverlayTranscriptionID = nil
        overlay.showNoSpeechFeedback()
    }

    private func finishOverlayTranscription(_ overlayTranscriptionID: UUID?) {
        guard let overlayTranscriptionID,
              activeOverlayTranscriptionID == overlayTranscriptionID
        else {
            return
        }
        activeOverlayTranscriptionID = nil
        overlay.hide()
    }

    private static func isEmptyTranscriptionError(_ error: Error) -> Bool {
        if case NativAudioTranscriptionError.emptyTranscript = error {
            return true
        }

        let message = [
            error.localizedDescription,
            String(describing: error),
        ]
        .joined(separator: " ")
        .lowercased()

        return [
            "no text was generated",
            "no text generated",
            "did not include any text",
            "empty transcript",
            "empty transcription",
        ].contains { message.contains($0) }
    }

    private func showRecentRecordingUnavailable() {
        showTranscriptionError(
            title: "No Recent Recording",
            message: """
            Audio is available for five minutes after recording. Hold Fn + Control \
            to record again, then press Fn + R before the audio expires.
            """
        )
    }

    private func showMissingSpeechModelAlert() {
        guard !isPresentingAlert else {
            return
        }
        isPresentingAlert = true
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Speech-to-Text Model Required"
        alert.informativeText = """
        Install a speech-to-text model such as Parakeet, Qwen3-ASR, or \
        MOSS-Transcribe from the Models table, then record again.
        """
        alert.addButton(withTitle: "Open Speech Models")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        isPresentingAlert = false
        shortcutMonitor.resynchronizeAfterModalInteraction()

        if response == .alertFirstButtonReturn {
            onOpenSpeechModels?()
        }
    }

    private func showTranscriptionError(title: String, message: String) {
        guard !isPresentingAlert else {
            return
        }
        isPresentingAlert = true
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        isPresentingAlert = false
        shortcutMonitor.resynchronizeAfterModalInteraction()
    }

    private func showInsertionPermissionAlertIfNeeded() {
        guard !hasShownInsertionPermissionAlert else {
            return
        }
        hasShownInsertionPermissionAlert = true
        guard !isPresentingAlert else {
            return
        }
        isPresentingAlert = true
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Nativ Could Not Insert Text"
        alert.informativeText = """
        The transcript is on the clipboard. macOS denied Nativ permission to \
        paste it at the cursor. Enable Nativ in System Settings to insert future \
        transcripts automatically.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        isPresentingAlert = false
        shortcutMonitor.resynchronizeAfterModalInteraction()

        if response == .alertFirstButtonReturn {
            NativSystemPermissionController.openAccessibilitySettings()
        }
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }
}
