import AppKit
import Combine
import NativServerKit

struct VoiceTranscriptionConfiguration: Sendable {
    let modelSearchPath: String
    let additionalModelSearchPaths: [String]
    let selectedModelID: String?
    let languageModelID: String?
    let maxTokens: Int
    let serverBaseURL: URL
    let serverAPIKey: String?
    let serverIsRunning: Bool
}

@MainActor
final class VoiceCaptureCoordinator {
    var transcriptionConfigurationProvider:
        (@MainActor @Sendable () -> VoiceTranscriptionConfiguration?)?
    var onOpenSpeechModels: (() -> Void)?

    private let shortcutMonitor = FnControlShortcutMonitor()
    private let recorder = VoiceAudioRecorder()
    private let overlay = VoiceCaptureOverlayController()
    private let analytics = AudioAnalyticsStore.shared
    private let wakeWordMonitor = VoiceWakeWordMonitor.shared
    private var isWakeWordCapture = false
    private var wakeWordInsertionTarget: VoiceTranscriptInsertionTarget?
    private var observations = Set<AnyCancellable>()
    private var isActive = false
    private var isOtherAudioBusy = false
    private var isSystemSleeping = false
    private var isSessionInactive = false
    private var permissionTask: Task<Void, Never>?
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    private var audioDeletionTasks: [URL: Task<Void, Never>] = [:]
    private var insertionTarget: VoiceTranscriptInsertionTarget?
    private var activeOverlayTranscriptionID: UUID?
    private var isShortcutHeld = false
    private var isHandsFreeMode = false
    private var isPresentingAlert = false {
        didSet { updateWakeWordListening() }
    }
    private var hasShownInsertionPermissionAlert = false

    init() {
        shortcutMonitor.onChange = { [weak self] isHeld in
            self?.handleShortcutChange(isHeld)
        }
        shortcutMonitor.onRetry = { [weak self] in
            self?.retryLastTranscription()
        }
        overlay.setDictationCancelAction { [weak self] in
            self?.cancelCapture()
        }
        recorder.onMeterUpdate = { [weak self] level, elapsed in
            self?.overlay.update(level: level, elapsed: elapsed)
        }

        recorder.onRecordingFailure = { [weak self] error, savedURL in
            self?.recordingInterrupted(error, savedURL: savedURL)
        }
        wakeWordMonitor.onCandidate = { [weak self] in
            self?.wakeWordInsertionTarget = VoiceTranscriptInserter.captureTarget()
        }
        wakeWordMonitor.confirm = { [weak self] audio in
            guard let self else { throw CancellationError() }
            return try await self.confirmWakeWord(audio)
        }
        wakeWordMonitor.onConfirmed = { [weak self] in
            guard let self, self.canListenForWakeWord else { return }
            self.isWakeWordCapture = true
            self.isHandsFreeMode = true
            self.isShortcutHeld = true
            self.activeOverlayTranscriptionID = nil
            self.overlay.show(at: NSEvent.mouseLocation)
            // Speech is already in progress; avoid recording an activation chime.
        }
        wakeWordMonitor.onMeterUpdate = { [weak self] level, elapsed in
            self?.overlay.update(level: level, elapsed: elapsed)
        }
        wakeWordMonitor.onFinished = { [weak self] result in
            self?.finishWakeWordCapture(result)
        }
        wakeWordMonitor.onCancelled = { [weak self] in
            guard let self else { return }
            self.wakeWordInsertionTarget = nil
            if self.isWakeWordCapture {
                self.isWakeWordCapture = false
                self.isShortcutHeld = false
                self.isHandsFreeMode = false
                self.overlay.hide()
            }
        }
        VoiceShortcutPreferences.shared.$isWakeWordEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                // @Published emits before the stored preference changes.
                self?.updateWakeWordListening(enabled: enabled)
            }
            .store(in: &observations)
        AudioInputDevicePreferences.shared.$selectedDeviceID
            .combineLatest(AudioInputDevicePreferences.shared.$devices)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateWakeWordListening() }
            .store(in: &observations)
        let sessionEvents: [(Notification.Name, ReferenceWritableKeyPath<VoiceCaptureCoordinator, Bool>, Bool)] = [
            (NSWorkspace.willSleepNotification, \.isSystemSleeping, true),
            (NSWorkspace.didWakeNotification, \.isSystemSleeping, false),
            (NSWorkspace.sessionDidResignActiveNotification, \.isSessionInactive, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, \.isSessionInactive, false),
        ]
        for (name, flag, inactive) in sessionEvents {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self[keyPath: flag] = inactive
                    if inactive, self.isWakeWordCapture { self.cancelCapture() }
                    self.updateWakeWordListening()
                }
                .store(in: &observations)
        }
    }

    func start() {
        isActive = true
        scheduleExistingAudioDeletion()
        if let directory = try? VoiceAudioRecorder.recordingsDirectory {
            analytics.importTranscripts(in: directory)
        }
        shortcutMonitor.start()
        updateWakeWordListening()
    }

    func stop() {
        isActive = false
        isWakeWordCapture = false
        updateWakeWordListening()
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

    func setOtherAudioBusy(_ busy: Bool) {
        isOtherAudioBusy = busy
        if busy, isWakeWordCapture { cancelCapture() }
        updateWakeWordListening()
    }

    private var canUseWakeWordAudio: Bool {
        isActive && !isSystemSleeping && !isSessionInactive && !isOtherAudioBusy && !isPresentingAlert
    }

    private var canListenForWakeWord: Bool {
        canUseWakeWordAudio && !isShortcutHeld && !recorder.isRecording && transcriptionTasks.isEmpty
    }

    private func updateWakeWordListening(enabled: Bool? = nil) {
        wakeWordMonitor.configure(
            enabled: isActive && (enabled ?? VoiceShortcutPreferences.shared.isWakeWordEnabled),
            suspended: !canUseWakeWordAudio || (!canListenForWakeWord && !isWakeWordCapture),
            deviceID: AudioInputDevicePreferences.shared.effectiveDeviceID
        )
    }

    func showRecordingsInFinder() {
        guard let directory = try? VoiceAudioRecorder.recordingsDirectory else {
            return
        }
        NSWorkspace.shared.open(directory)
    }

    private func handleShortcutChange(_ isHeld: Bool) {
        if isHandsFreeMode || isWakeWordCapture {
            guard isHeld else {
                return
            }
            isHandsFreeMode = false
            isShortcutHeld = false
            endCapture()
            return
        }

        if isShortcutHeld {
            guard !isHeld else {
                return
            }
            isShortcutHeld = false
            endCapture()
            return
        }

        guard isHeld else {
            return
        }

        if VoiceShortcutPreferences.shared.isHandsFreeEnabled {
            isHandsFreeMode = true
        }
        isShortcutHeld = true
        beginCapture()
    }

    private func beginCapture() {
        updateWakeWordListening()
        permissionTask?.cancel()
        activeOverlayTranscriptionID = nil
        insertionTarget = VoiceTranscriptInserter.captureTarget()
        overlay.show(at: NSEvent.mouseLocation)
        permissionTask = Task { [weak self] in
            guard let self else {
                return
            }
            let granted = await NativSystemPermissionController.requestMicrophone()
            guard !Task.isCancelled, self.isShortcutHeld else {
                return
            }
            guard granted else {
                self.clearFailedCaptureState()
                self.overlay.showFailure()
                self.presentMicrophonePermissionAlert()
                self.updateWakeWordListening()
                return
            }

            do {
                try self.recorder.start(
                    deviceUniqueID: AudioInputDevicePreferences.shared.effectiveDeviceID
                )
                self.overlay.didStartRecording()
            } catch {
                NSLog("Nativ voice recording failed to start: %@", error.localizedDescription)
                self.clearFailedCaptureState()
                self.overlay.showFailure()
                self.updateWakeWordListening()
            }
        }
    }

    private func clearFailedCaptureState() {
        isWakeWordCapture = false
        isShortcutHeld = false
        isHandsFreeMode = false
        insertionTarget = nil
        activeOverlayTranscriptionID = nil
    }

    private func recordingInterrupted(_ error: Error, savedURL: URL?) {
        clearFailedCaptureState()
        if let savedURL { scheduleAudioDeletion(savedURL) }
        NSLog("Nativ voice recording interrupted: %@", error.localizedDescription)
        overlay.showFailure()
        updateWakeWordListening()
    }

    private func endCapture() {
        if isWakeWordCapture {
            wakeWordMonitor.finishCapture()
            return
        }
        defer { updateWakeWordListening() }
        permissionTask?.cancel()
        permissionTask = nil
        let target = insertionTarget
        insertionTarget = nil
        let savedURL = recorder.stop()
        if let error = recorder.lastRecordingError {
            recordingInterrupted(error, savedURL: savedURL)
            return
        }
        if let recordingURL = savedURL {
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

    private func cancelCapture() {
        let wasWakeWordCapture = isWakeWordCapture
        isWakeWordCapture = false
        wakeWordInsertionTarget = nil
        permissionTask?.cancel()
        permissionTask = nil
        recorder.discard()
        activeOverlayTranscriptionID = nil
        insertionTarget = nil
        isShortcutHeld = false
        isHandsFreeMode = false
        overlay.hide()
        if wasWakeWordCapture { wakeWordMonitor.restart() }
        updateWakeWordListening()
    }

    private func retryLastTranscription() {
        guard !recorder.isRecording, !isWakeWordCapture else {
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
        transcribe(recordingURL, target: target, durationSeconds: nil, wakeWord: recordingURL.lastPathComponent.hasPrefix("wake-"))
    }

    private func confirmWakeWord(_ audio: Data) async throws -> VoiceWakeWordTranscription {
        guard let configuration = transcriptionConfigurationProvider?(), configuration.serverIsRunning else {
            throw VoiceWakeWordModelError.invalidModel("Start the Nativ server to confirm wake words.")
        }
        let models = try await LocalModelDiscovery.scan(searchPaths: LocalModelSearchPaths(
            primary: configuration.modelSearchPath,
            additional: configuration.additionalModelSearchPaths
        ))
        try Task.checkCancellation()
        guard let modelID = LocalModelDiscovery.speechToTextModelID(in: models, selectedModelID: configuration.selectedModelID) else {
            throw VoiceWakeWordModelError.invalidModel("Install a speech-to-text model to confirm wake words.")
        }
        let client = NativAudioClient(baseURL: configuration.serverBaseURL, apiKey: configuration.serverAPIKey, timeout: 15)
        do {
            let result = try await client.transcribe(audioData: audio, fileName: "wake-candidate.wav", model: modelID)
            return VoiceWakeWordTranscription(text: result.text, modelID: modelID)
        } catch {
            if Self.isEmptyTranscriptionError(error) {
                return VoiceWakeWordTranscription(text: "", modelID: modelID)
            }
            throw error
        }
    }

    private func finishWakeWordCapture(_ result: VoiceWakeWordCapture.Result) {
        let target = wakeWordInsertionTarget
        wakeWordInsertionTarget = nil
        isWakeWordCapture = false
        isShortcutHeld = false
        isHandsFreeMode = false
        do {
            // The prefix also preserves wake-phrase stripping when Retry Recent Audio is used.
            let url = try VoiceAudioRecorder.recordingsDirectory.appendingPathComponent("wake-\(UUID().uuidString).wav")
            try result.audio.wavData.write(to: url, options: .atomic)
            scheduleAudioDeletion(url)
            let id = UUID()
            activeOverlayTranscriptionID = id
            overlay.waitForTranscription()
            transcribe(url, target: target, durationSeconds: result.audio.duration,
                       overlayTranscriptionID: id, wakeWord: true,
                       confirmation: result.canReuseConfirmation ? result.confirmation : nil,
                       wakeWordModelID: result.confirmation.modelID)
        } catch {
            overlay.showFailure()
            wakeWordMonitor.restart()
        }
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
        overlayTranscriptionID: UUID? = nil,
        wakeWord: Bool = false,
        confirmation: VoiceWakeWordTranscription? = nil,
        wakeWordModelID: String? = nil
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
                self.updateWakeWordListening()
            }
            guard let configuration = self.transcriptionConfigurationProvider?() else {
                self.finishOverlayTranscription(overlayTranscriptionID)
                return
            }

            let installedModels: [LocalModel]
            do {
                installedModels = try await LocalModelDiscovery.scan(
                    searchPaths: LocalModelSearchPaths(
                        primary: configuration.modelSearchPath,
                        additional: configuration.additionalModelSearchPaths
                    )
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
            // Both of these are dead ends for the server path. Rather than discarding the
            // recording, hand it to the on-device system recognizer when that is possible;
            // the alert is only shown when there is genuinely nothing that can transcribe.
            let modelID = wakeWordModelID ?? LocalModelDiscovery.speechToTextModelID(
                in: installedModels,
                selectedModelID: requestConfiguration.selectedModelID
            )
            guard let modelID, requestConfiguration.serverIsRunning || confirmation != nil else {
                await self.transcribeWithSystemRecognizer(
                    recordingURL,
                    target: target,
                    durationSeconds: durationSeconds,
                    overlayTranscriptionID: overlayTranscriptionID,
                    unavailableReason: modelID == nil ? .noSpeechModel : .serverStopped,
                    wakeWord: wakeWord
                )
                return
            }

            do {
                let client = NativAudioClient(
                    baseURL: requestConfiguration.serverBaseURL,
                    apiKey: requestConfiguration.serverAPIKey
                )
                let result: NativAudioTranscription
                if let confirmation {
                    result = NativAudioTranscription(text: confirmation.text)
                } else {
                    result = try await client.transcribe(
                        audioData: audioData,
                        fileName: recordingURL.lastPathComponent,
                        model: modelID
                    )
                }
                guard !Task.isCancelled else {
                    return
                }

                let dictation = VoiceDictationTranscript(
                    result.text,
                    wakeWord: wakeWord,
                    returnCommandTrigger: VoiceShortcutPreferences.shared.activeReturnCommandTrigger
                )
                guard !dictation.isEmpty else {
                    self.handleEmptyTranscription(
                        recordingURL,
                        overlayTranscriptionID: overlayTranscriptionID
                    )
                    return
                }
                let transcript = dictation.text
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
                    target: target,
                    pressReturn: dictation.pressReturn
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
                    title: "Transcription failed",
                    message: error.localizedDescription
                )
            }
        }
        transcriptionTasks[taskID] = task
        updateWakeWordListening()
    }

    /// Why the bundled server could not be used for this recording.
    private enum ServerUnavailableReason {
        case noSpeechModel
        case serverStopped
    }

    /// Last-resort transcription through macOS's on-device recognizer.
    ///
    /// Mirrors the server path exactly — same transcript file, same analytics row, same
    /// cursor insertion — so a fallback transcript behaves like any other. If the system
    /// recognizer cannot help either, the original alert is shown, leaving the previous
    /// behaviour intact for anyone it does not cover.
    private func transcribeWithSystemRecognizer(
        _ recordingURL: URL,
        target: VoiceTranscriptInsertionTarget?,
        durationSeconds: TimeInterval?,
        overlayTranscriptionID: UUID?,
        unavailableReason: ServerUnavailableReason,
        wakeWord: Bool
    ) async {
        guard await AppleSpeechTranscriber.isAvailable else {
            finishOverlayTranscription(overlayTranscriptionID)
            showServerUnavailableAlert(unavailableReason)
            return
        }

        let transcript: String
        do {
            transcript = try await AppleSpeechTranscriber.transcribe(contentsOf: recordingURL)
        } catch AppleSpeechTranscriber.Failure.empty {
            handleEmptyTranscription(recordingURL, overlayTranscriptionID: overlayTranscriptionID)
            return
        } catch let AppleSpeechTranscriber.Failure.modelInstalling(language) {
            // The one failure worth its own message: macOS has the language but not the
            // model yet, and is now fetching it. Saying so beats an alert about a server
            // the user may not have been trying to use.
            finishOverlayTranscription(overlayTranscriptionID)
            showTranscriptionError(
                title: "Preparing on-device dictation",
                message: """
                macOS is downloading its \(language) speech model. Your recording is saved \
                in Audio — dictate again once it has finished.
                """
            )
            return
        } catch {
            NSLog(
                "Nativ on-device transcription failed for %@: %@",
                recordingURL.lastPathComponent,
                error.localizedDescription
            )
            finishOverlayTranscription(overlayTranscriptionID)
            showServerUnavailableAlert(unavailableReason)
            return
        }

        guard !Task.isCancelled else {
            return
        }
        let dictation = VoiceDictationTranscript(
            transcript,
            wakeWord: wakeWord,
            returnCommandTrigger: VoiceShortcutPreferences.shared.activeReturnCommandTrigger
        )
        guard !dictation.isEmpty else {
            handleEmptyTranscription(recordingURL, overlayTranscriptionID: overlayTranscriptionID)
            return
        }
        let transcriptURL = recordingURL
            .deletingPathExtension()
            .appendingPathExtension("txt")
        try? dictation.text.write(to: transcriptURL, atomically: true, encoding: .utf8)
        analytics.upsertTranscription(
            recordingURL: recordingURL,
            transcript: dictation.text,
            durationSeconds: durationSeconds,
            modelID: AppleSpeechTranscriber.modelIdentifier,
            applicationName: target?.applicationName
        )

        let insertedAtCursor = await VoiceTranscriptInserter.insertAtCursor(
            dictation.text,
            target: target,
            pressReturn: dictation.pressReturn
        )
        guard !Task.isCancelled else {
            return
        }
        NSLog(
            "Nativ saved voice transcript to %@ using the on-device system recognizer",
            transcriptURL.path
        )
        finishOverlayTranscription(overlayTranscriptionID)
        if !insertedAtCursor {
            showInsertionPermissionAlertIfNeeded()
        }
    }

    private func showServerUnavailableAlert(_ reason: ServerUnavailableReason) {
        switch reason {
        case .noSpeechModel:
            showMissingSpeechModelAlert()
        case .serverStopped:
            showTranscriptionError(
                title: "Nativ server is not running",
                message: "Start the Nativ server, then record again to transcribe the audio."
            )
        }
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
        let preferences = VoiceShortcutPreferences.shared
        showTranscriptionError(
            title: "No recent recording",
            message: """
            Audio is available for five minutes after recording. Use \
            \(preferences.recordShortcut.displayName) to record again, then use \
            \(preferences.retryShortcut.displayName) before the audio expires.
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
        alert.messageText = "Speech-to-text model required"
        alert.informativeText = """
        Install a speech-to-text model such as Parakeet, Qwen3-ASR, or \
        MOSS-Transcribe from the Models table, then record again.
        """
        alert.addButton(withTitle: "Open Models")
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
        alert.messageText = "Nativ could not insert text"
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

    private func presentMicrophonePermissionAlert() {
        guard !isPresentingAlert else {
            return
        }
        isPresentingAlert = true
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Microphone access needed"
        alert.informativeText = """
        Nativ needs microphone access to record dictation. Enable Nativ under \
        Microphone in System Settings, then try the shortcut again.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        isPresentingAlert = false
        shortcutMonitor.resynchronizeAfterModalInteraction()

        if response == .alertFirstButtonReturn {
            NativSystemPermissionController.openMicrophoneSettings()
        }
    }
}
