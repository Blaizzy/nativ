import AppKit
import AVFoundation
import NativServerKit

struct VoiceTranscriptionConfiguration {
    let modelSearchPath: String
    let additionalModelSearchPaths: [String]
    let selectedModelID: String?
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
    private var permissionTask: Task<Void, Never>?
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    private var audioDeletionTasks: [URL: Task<Void, Never>] = [:]
    private var insertionTarget: VoiceTranscriptInsertionTarget?
    private var isShortcutHeld = false
    private var isPresentingAlert = false
    private var hasShownInsertionPermissionAlert = false

    init() {
        shortcutMonitor.onChange = { [weak self] isHeld in
            self?.handleShortcutChange(isHeld)
        }
        recorder.onMeterUpdate = { [weak self] level, elapsed in
            self?.overlay.update(level: level, elapsed: elapsed)
        }
    }

    func start() {
        scheduleExistingAudioDeletion()
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
        insertionTarget = nil
        isShortcutHeld = false
    }

    func showRecordingsInFinder() {
        guard let directory = try? VoiceAudioRecorder.recordingsDirectory else {
            return
        }
        NSWorkspace.shared.open(directory)
    }

    private func handleShortcutChange(_ isHeld: Bool) {
        isShortcutHeld = isHeld
        if isHeld {
            beginCapture()
        } else {
            endCapture()
        }
    }

    private func beginCapture() {
        permissionTask?.cancel()
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
                try self.recorder.start()
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
            transcribe(recordingURL, target: target)
        }
        overlay.hide()
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
        target: VoiceTranscriptInsertionTarget?
    ) {
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.transcriptionTasks[taskID] = nil
            }
            guard let configuration = self.transcriptionConfigurationProvider?() else {
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
                self.showMissingSpeechModelAlert()
                return
            }

            guard !Task.isCancelled else {
                return
            }
            guard let requestConfiguration = self.transcriptionConfigurationProvider?() else {
                return
            }
            guard let modelID = LocalModelDiscovery.speechToTextModelID(
                in: installedModels,
                selectedModelID: requestConfiguration.selectedModelID
            ) else {
                self.showMissingSpeechModelAlert()
                return
            }
            guard requestConfiguration.serverIsRunning else {
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
                    fileURL: recordingURL,
                    model: modelID
                )
                guard !Task.isCancelled else {
                    return
                }

                let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let transcriptURL = recordingURL
                    .deletingPathExtension()
                    .appendingPathExtension("txt")
                try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

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
                if !insertedAtCursor {
                    self.showInsertionPermissionAlertIfNeeded()
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self.showTranscriptionError(
                    title: "Transcription Failed",
                    message: error.localizedDescription
                )
            }
        }
        transcriptionTasks[taskID] = task
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
    }

    private func showInsertionPermissionAlertIfNeeded() {
        guard !hasShownInsertionPermissionAlert else {
            return
        }
        hasShownInsertionPermissionAlert = true
        showTranscriptionError(
            title: "Transcript Copied, but Not Inserted",
            message: """
            The transcript is on the clipboard. Allow Nativ to control your Mac \
            in System Settings → Privacy & Security → Accessibility to insert it \
            at the cursor automatically.
            """
        )
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
