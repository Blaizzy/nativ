import AppKit
import AVFoundation
import CoreAudio
import Darwin
import Foundation
import NativServerKit
import ScreenCaptureKit

enum AudioCapturePreferences {
    static let automaticallySummarizeKey = "audio.capture.automaticallySummarize"
    static let includeSystemAudioKey = "audio.capture.includeSystemAudio"
    static let suggestMeetingTranscriptionKey = "audio.capture.suggestMeetingTranscription"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            automaticallySummarizeKey: true,
            includeSystemAudioKey: true,
            suggestMeetingTranscriptionKey: false,
        ])
    }

    static var automaticallySummarize: Bool {
        UserDefaults.standard.bool(forKey: automaticallySummarizeKey)
    }

    static var includeSystemAudio: Bool {
        UserDefaults.standard.bool(forKey: includeSystemAudioKey)
    }

    static var suggestMeetingTranscription: Bool {
        UserDefaults.standard.bool(forKey: suggestMeetingTranscriptionKey)
    }
}

enum AudioCapturePhase: Equatable {
    case idle
    case preparing
    case recording
    case processing
}

private enum ActiveAudioCaptureBackend {
    case microphone
    case systemAndMicrophone
}

enum AudioCaptureLibraryError: LocalizedError {
    case microphonePermissionRequired
    case screenCapturePermissionRequired
    case serverNotRunning
    case missingSpeechModel
    case missingLanguageModel
    case recordingUnavailable
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .microphonePermissionRequired:
            "Microphone access is required to record audio."
        case .screenCapturePermissionRequired:
            "Screen & System Audio Recording access is required to capture audio from other apps."
        case .serverNotRunning:
            "Start the Nativ server before transcribing or summarizing a recording."
        case .missingSpeechModel:
            "Install a speech-to-text model before transcribing recordings."
        case .missingLanguageModel:
            "Select a language model before generating a summary."
        case .recordingUnavailable:
            "The saved audio file is no longer available."
        case .emptyTranscript:
            "The recording was saved, but the speech model did not produce a transcript."
        }
    }
}

private final class AudioPlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: ((AVAudioPlayer) -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?(player)
    }
}

@MainActor
final class AudioCaptureLibrary: ObservableObject {
    @Published private(set) var phase: AudioCapturePhase = .idle
    @Published private(set) var activeKind: AudioRecordKind?
    @Published private(set) var elapsed: TimeInterval = 0
    let meterState = AudioInputLevelState()
    @Published private(set) var activeIncludesSystemAudio = false
    @Published private(set) var processingRecordIDs = Set<String>()
    @Published var lastErrorMessage: String?
    @Published private(set) var shouldOfferScreenCaptureSettings = false
    @Published private(set) var playingRecordID: String?
    @Published private(set) var isPlaybackPaused = false

    var transcriptionConfigurationProvider: (() -> VoiceTranscriptionConfiguration?)?

    private var audioPlayer: AVAudioPlayer?
    private lazy var playbackDelegate: AudioPlaybackDelegate = {
        let delegate = AudioPlaybackDelegate()
        delegate.onFinish = { [weak self] player in
            Task { @MainActor in self?.playbackDidFinish(player) }
        }
        return delegate
    }()
    private let voiceRecorder = VoiceAudioRecorder()
    private let meetingRecorder = SystemAudioMeetingRecorder()
    private let recordingOverlay = VoiceCaptureOverlayController()
    private let meetingJoinMonitor = MeetingJoinMonitor()
    private let meetingSuggestion = MeetingTranscriptionSuggestionController()
    private let analytics: AudioAnalyticsStore
    private var elapsedTimer: Timer?
    private var captureStartedAt: Date?
    private var shouldSummarizeCurrentCapture = false
    private var activeBackend: ActiveAudioCaptureBackend?
    private var activeTask: Task<Void, Never>?
    private var lastMeterPublishAt = Date.distantPast

    init(analytics: AudioAnalyticsStore? = nil) {
        AudioCapturePreferences.registerDefaults()
        self.analytics = analytics ?? .shared
        meetingJoinMonitor.onMeetingJoined = { [weak self] application in
            self?.offerMeetingTranscription(for: application) ?? false
        }
        meetingSuggestion.onStart = { [weak self] in
            guard let self else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                await self.start(
                    .meeting,
                    automaticallySummarize: AudioCapturePreferences.automaticallySummarize,
                    includeSystemAudio: AudioCapturePreferences.includeSystemAudio
                )
            }
        }
        recordingOverlay.setAudioCaptureActions(
            complete: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.stop()
                }
            },
            restart: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.restart()
                }
            },
            delete: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.deleteCurrentRecording()
                }
            }
        )
        voiceRecorder.onMeterUpdate = { [weak self] level, elapsed in
            guard let self else {
                return
            }
            self.publishMeter(level: level, elapsed: elapsed)
        }
        meetingRecorder.onMicrophoneLevelUpdate = { [weak self] level in
            guard let self else {
                return
            }
            self.publishMeter(level: level, elapsed: self.elapsed)
        }
    }

    func start() {
        meetingJoinMonitor.start()
    }

    static var recordingsDirectory: URL {
        get throws {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = applicationSupport
                .appendingPathComponent("Nativ", isDirectory: true)
                .appendingPathComponent("Audio Library", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return directory
        }
    }

    var isBusy: Bool {
        phase != .idle
    }

    var isRecording: Bool {
        phase == .recording
    }

    func start(
        _ kind: AudioRecordKind,
        automaticallySummarize: Bool,
        includeSystemAudio: Bool = true
    ) async {
        guard phase == .idle, kind != .dictation else {
            return
        }

        clearLastError()
        activeKind = kind
        phase = .preparing
        shouldSummarizeCurrentCapture = automaticallySummarize
        activeIncludesSystemAudio = kind == .meeting && includeSystemAudio
        meterState.update(0)
        lastMeterPublishAt = .distantPast

        guard Self.hasMicrophoneAccess() else {
            fail(AudioCaptureLibraryError.microphonePermissionRequired)
            return
        }
        if activeIncludesSystemAudio,
           !NativSystemPermissionController.requestScreenCaptureAccess()
        {
            fail(AudioCaptureLibraryError.screenCapturePermissionRequired)
            return
        }

        recordingOverlay.showAudioCapture(kind, at: NSEvent.mouseLocation)

        do {
            let outputURL = try Self.makeOutputURL(
                for: kind,
                includeSystemAudio: activeIncludesSystemAudio
            )
            let microphoneDeviceID = AudioInputDevicePreferences.shared.effectiveDeviceID
            switch kind {
            case .voiceNote:
                try voiceRecorder.start(
                    outputURL: outputURL,
                    deviceUniqueID: microphoneDeviceID
                )
                activeBackend = .microphone
            case .meeting:
                if activeIncludesSystemAudio {
                    try await meetingRecorder.start(
                        outputURL: outputURL,
                        microphoneDeviceID: microphoneDeviceID
                    )
                    activeBackend = .systemAndMicrophone
                } else {
                    try voiceRecorder.start(
                        outputURL: outputURL,
                        deviceUniqueID: microphoneDeviceID
                    )
                    activeBackend = .microphone
                }
            case .dictation:
                return
            }
            captureStartedAt = Date()
            elapsed = 0
            phase = .recording
            recordingOverlay.update(level: 0, elapsed: 0)
            recordingOverlay.didStartRecording()
            startElapsedTimer()
        } catch {
            if Self.isScreenCapturePermissionError(error) {
                // ScreenCaptureKit presents the native permission dialog itself.
                // Do not stack a second Nativ alert underneath it.
                resetCaptureState()
                return
            }
            fail(error)
        }
    }

    func clearLastError() {
        lastErrorMessage = nil
        shouldOfferScreenCaptureSettings = false
    }

    func stop() async {
        guard phase == .recording,
              let kind = activeKind,
              let activeBackend
        else {
            return
        }

        phase = .processing
        recordingOverlay.waitForTranscription()
        stopElapsedTimer()
        let duration = max(
            elapsed,
            captureStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        )

        do {
            let recordingURL: URL
            switch activeBackend {
            case .microphone:
                guard let url = voiceRecorder.stop() else {
                    throw AudioCaptureLibraryError.recordingUnavailable
                }
                recordingURL = url
            case .systemAndMicrophone:
                recordingURL = try await meetingRecorder.stop()
            }

            let title = Self.defaultTitle(for: kind, date: captureStartedAt ?? Date())
            analytics.addCapture(
                recordingURL: recordingURL,
                kind: kind,
                title: title,
                durationSeconds: duration
            )
            let recordID = recordingURL.deletingPathExtension().lastPathComponent
            processingRecordIDs.insert(recordID)
            let automaticallySummarize = shouldSummarizeCurrentCapture
            activeTask = Task { [weak self] in
                guard let self else {
                    return
                }
                await self.processRecording(
                    recordingURL,
                    kind: kind,
                    title: title,
                    duration: duration,
                    automaticallySummarize: automaticallySummarize
                )
            }
            await activeTask?.value
        } catch {
            fail(error)
            return
        }

        resetCaptureState()
    }

    func restart() async {
        guard phase == .recording,
              let kind = activeKind
        else {
            return
        }

        let automaticallySummarize = shouldSummarizeCurrentCapture
        let includeSystemAudio = activeIncludesSystemAudio
        await discardCurrentCapture(hideOverlay: false)
        await start(
            kind,
            automaticallySummarize: automaticallySummarize,
            includeSystemAudio: includeSystemAudio
        )
    }

    func deleteCurrentRecording() async {
        guard phase == .recording else {
            return
        }
        await discardCurrentCapture(hideOverlay: true)
    }

    func summarize(_ record: AudioTranscriptionRecord) {
        guard !record.transcript.isEmpty,
              !processingRecordIDs.contains(record.id)
        else {
            return
        }
        processingRecordIDs.insert(record.id)
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let summary = try await self.generateSummary(for: record.transcript)
                self.analytics.updateSummary(summary, for: record.id)
                try self.writeSummary(summary, recordID: record.id)
            } catch {
                self.lastErrorMessage = error.localizedDescription
            }
            self.processingRecordIDs.remove(record.id)
        }
    }

    func retryTranscription(_ record: AudioTranscriptionRecord) {
        guard record.resolvedKind != .dictation,
              !processingRecordIDs.contains(record.id),
              let recordingURL = audioURL(for: record)
        else {
            if audioURL(for: record) == nil {
                lastErrorMessage = AudioCaptureLibraryError.recordingUnavailable.localizedDescription
            }
            return
        }
        processingRecordIDs.insert(record.id)
        Task { [weak self] in
            guard let self else {
                return
            }
            await self.processRecording(
                recordingURL,
                kind: record.resolvedKind,
                title: record.displayTitle,
                duration: record.durationSeconds ?? 0,
                automaticallySummarize: false
            )
        }
    }

    func audioURL(for record: AudioTranscriptionRecord) -> URL? {
        guard let audioFileName = record.audioFileName,
              let directory = try? Self.recordingsDirectory
        else {
            return nil
        }
        let url = directory.appendingPathComponent(audioFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func revealAudio(for record: AudioTranscriptionRecord) {
        guard let url = audioURL(for: record) else {
            lastErrorMessage = AudioCaptureLibraryError.recordingUnavailable.localizedDescription
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func togglePlayback(for record: AudioTranscriptionRecord) {
        if playingRecordID == record.id {
            if isPlaybackPaused {
                if audioPlayer?.play() == true {
                    isPlaybackPaused = false
                } else {
                    lastErrorMessage = AudioCaptureLibraryError.recordingUnavailable.localizedDescription
                }
            } else {
                audioPlayer?.pause()
                isPlaybackPaused = true
            }
            return
        }
        startPlayback(for: record)
    }

    private func startPlayback(for record: AudioTranscriptionRecord) {
        stopPlayback()
        guard let url = audioURL(for: record) else {
            lastErrorMessage = AudioCaptureLibraryError.recordingUnavailable.localizedDescription
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = playbackDelegate
            guard player.play() else {
                lastErrorMessage = AudioCaptureLibraryError.recordingUnavailable.localizedDescription
                return
            }
            audioPlayer = player
            playingRecordID = record.id
            isPlaybackPaused = false
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingRecordID = nil
        isPlaybackPaused = false
    }

    func stopPlaybackIfPlaying(_ recordID: String) {
        if playingRecordID == recordID {
            stopPlayback()
        }
    }

    private func playbackDidFinish(_ player: AVAudioPlayer) {
        guard audioPlayer === player else {
            return
        }
        stopPlayback()
    }

    func revealLibrary() {
        guard let directory = try? Self.recordingsDirectory else {
            return
        }
        NSWorkspace.shared.open(directory)
    }

    func delete(_ record: AudioTranscriptionRecord) {
        guard record.resolvedKind != .dictation else {
            return
        }
        stopPlaybackIfPlaying(record.id)
        if let audioURL = audioURL(for: record) {
            try? FileManager.default.removeItem(at: audioURL)
        }
        guard let directory = try? Self.recordingsDirectory else {
            analytics.removeRecord(withID: record.id)
            return
        }
        for pathExtension in ["txt", "summary.txt"] {
            let url = directory
                .appendingPathComponent(record.id)
                .appendingPathExtension(pathExtension)
            try? FileManager.default.removeItem(at: url)
        }
        analytics.removeRecord(withID: record.id)
    }

    func shutdown() {
        meetingJoinMonitor.stop()
        meetingSuggestion.dismiss()
        activeTask?.cancel()
        activeTask = nil
        stopElapsedTimer()
        if let unfinishedVoiceNote = voiceRecorder.stop() {
            try? FileManager.default.removeItem(at: unfinishedVoiceNote)
        }
        Task { [meetingRecorder] in
            await meetingRecorder.cancel()
        }
        resetCaptureState()
    }

    private func offerMeetingTranscription(for application: MeetingApplication) -> Bool {
        guard AudioCapturePreferences.suggestMeetingTranscription,
              phase == .idle
        else {
            return false
        }
        meetingSuggestion.show(for: application.displayName)
        return true
    }

    private func processRecording(
        _ recordingURL: URL,
        kind: AudioRecordKind,
        title: String,
        duration: TimeInterval,
        automaticallySummarize: Bool
    ) async {
        let recordID = recordingURL.deletingPathExtension().lastPathComponent
        defer {
            processingRecordIDs.remove(recordID)
        }

        do {
            let (transcript, modelID) = try await transcribe(recordingURL)
            let transcriptURL = recordingURL
                .deletingPathExtension()
                .appendingPathExtension("txt")
            try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
            analytics.upsertTranscription(
                recordingURL: recordingURL,
                transcript: transcript,
                durationSeconds: duration,
                modelID: modelID,
                applicationName: nil,
                kind: kind,
                title: analytics.record(withID: recordID)?.title ?? title,
                persistAudioReference: true
            )

            if automaticallySummarize {
                do {
                    let summary = try await generateSummary(for: transcript)
                    analytics.updateSummary(summary, for: recordID)
                    try writeSummary(summary, recordID: recordID)
                } catch {
                    lastErrorMessage = "The transcript was saved, but the summary failed: \(error.localizedDescription)"
                }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func transcribe(_ recordingURL: URL) async throws -> (String, String) {
        guard let configuration = transcriptionConfigurationProvider?() else {
            throw AudioCaptureLibraryError.serverNotRunning
        }
        guard configuration.serverIsRunning else {
            throw AudioCaptureLibraryError.serverNotRunning
        }
        let installedModels = try await LocalModelDiscovery.scan(
            path: configuration.modelSearchPath,
            additionalPaths: configuration.additionalModelSearchPaths
        )
        guard let modelID = LocalModelDiscovery.speechToTextModelID(
            in: installedModels,
            selectedModelID: configuration.selectedModelID
        ) else {
            throw AudioCaptureLibraryError.missingSpeechModel
        }
        let client = NativAudioClient(
            baseURL: configuration.serverBaseURL,
            apiKey: configuration.serverAPIKey
        )
        let result = try await client.transcribe(fileURL: recordingURL, model: modelID)
        let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw AudioCaptureLibraryError.emptyTranscript
        }
        return (transcript, modelID)
    }

    private func generateSummary(for transcript: String) async throws -> String {
        guard let configuration = transcriptionConfigurationProvider?(),
              configuration.serverIsRunning
        else {
            throw AudioCaptureLibraryError.serverNotRunning
        }
        let installedModels = try await LocalModelDiscovery.scan(
            path: configuration.modelSearchPath,
            additionalPaths: configuration.additionalModelSearchPaths
        )
        let languageModels = installedModels.filter(\.isEligibleForLanguageModelPicker)
        let modelID = configuration.languageModelID.flatMap { selectedID in
            languageModels.first { $0.repoID == selectedID }?.repoID
        } ?? languageModels.first?.repoID
        guard let modelID else {
            throw AudioCaptureLibraryError.missingLanguageModel
        }

        let client = NativChatClient(
            baseURL: configuration.serverBaseURL,
            apiKey: configuration.serverAPIKey,
            timeout: 1_800
        )
        let chunks = Self.transcriptChunks(transcript, maximumCharacters: 14_000)
        var partialSummaries: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let prompt = """
                Summarize this \(chunks.count == 1 ? "audio transcript" : "section \(index + 1) of an audio transcript") into useful notes.
                Preserve decisions, action items, names, dates, and important context. Use concise Markdown headings and bullets. Do not invent information.

                TRANSCRIPT:
                \(chunk)
                """
            let completion = try await client.completeChat(
                Self.summaryRequest(
                    modelID: modelID,
                    prompt: prompt,
                    maxTokens: configuration.maxTokens
                )
            )
            partialSummaries.append(completion.content)
        }

        if partialSummaries.count == 1 {
            return partialSummaries[0].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let combinedPrompt = """
            Combine the following section summaries into one coherent set of notes. Remove repetition, preserve decisions and action items, and use concise Markdown headings and bullets. Do not invent information.

            \(partialSummaries.joined(separator: "\n\n---\n\n"))
            """
        let completion = try await client.completeChat(
            Self.summaryRequest(
                modelID: modelID,
                prompt: combinedPrompt,
                maxTokens: configuration.maxTokens
            )
        )
        return completion.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func summaryRequest(
        modelID: String,
        prompt: String,
        maxTokens: Int
    ) -> MLXChatCompletionRequest {
        MLXChatCompletionRequest(
            model: modelID,
            messages: [
                MLXChatMessage(
                    role: "system",
                    content: "You turn spoken transcripts into faithful, well-organized notes."
                ),
                MLXChatMessage(role: "user", content: prompt),
            ],
            maxTokens: maxTokens,
            temperature: 0.2,
            topK: 0,
            topP: 1,
            minP: 0,
            enableThinking: false
        )
    }

    private func writeSummary(_ summary: String, recordID: String) throws {
        let directory = try Self.recordingsDirectory
        let summaryURL = directory
            .appendingPathComponent(recordID)
            .appendingPathExtension("summary.txt")
        try summary.write(to: summaryURL, atomically: true, encoding: .utf8)
    }

    private func fail(_ error: Error) {
        lastErrorMessage = error.localizedDescription
        if let captureError = error as? AudioCaptureLibraryError,
           case .screenCapturePermissionRequired = captureError
        {
            shouldOfferScreenCaptureSettings = true
        } else {
            shouldOfferScreenCaptureSettings = false
        }
        resetCaptureState()
    }

    private static func isScreenCapturePermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == SCStreamError.errorDomain,
           error.code == SCStreamError.Code.userDeclined.rawValue
        {
            return true
        }

        // macOS 26 can surface this wording from shareable-content discovery
        // before returning the public ScreenCaptureKit error code.
        return error.localizedDescription.localizedCaseInsensitiveContains("declined TCC")
    }

    private func discardCurrentCapture(hideOverlay: Bool) async {
        guard let activeBackend else {
            resetCaptureState(hideOverlay: hideOverlay)
            return
        }

        phase = .preparing
        stopElapsedTimer()
        switch activeBackend {
        case .microphone:
            if let recordingURL = voiceRecorder.stop() {
                try? FileManager.default.removeItem(at: recordingURL)
            }
        case .systemAndMicrophone:
            await meetingRecorder.cancel()
        }
        resetCaptureState(hideOverlay: hideOverlay)
    }

    private func resetCaptureState(hideOverlay: Bool = true) {
        stopElapsedTimer()
        if hideOverlay {
            recordingOverlay.hide()
        }
        phase = .idle
        activeKind = nil
        elapsed = 0
        meterState.update(0)
        activeIncludesSystemAudio = false
        activeBackend = nil
        captureStartedAt = nil
        shouldSummarizeCurrentCapture = false
        lastMeterPublishAt = .distantPast
        activeTask = nil
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let captureStartedAt = self.captureStartedAt else {
                    return
                }
                self.elapsed = Date().timeIntervalSince(captureStartedAt)
                self.updateRecordingOverlay(
                    level: self.meterState.level,
                    elapsed: self.elapsed
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func updateRecordingOverlay(level: Float, elapsed: TimeInterval) {
        guard phase == .recording else {
            return
        }
        recordingOverlay.update(level: level, elapsed: elapsed)
    }

    private func publishMeter(level: Float, elapsed: TimeInterval) {
        let now = Date()
        guard now.timeIntervalSince(lastMeterPublishAt) >= 1.0 / 15.0 else {
            return
        }
        lastMeterPublishAt = now
        meterState.update(level)
        self.elapsed = elapsed
        updateRecordingOverlay(level: level, elapsed: elapsed)
    }

    private static func hasMicrophoneAccess() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private static func makeOutputURL(
        for kind: AudioRecordKind,
        includeSystemAudio: Bool
    ) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        let prefix = kind == .dictation ? "Dictation" : "Recording"
        return try recordingsDirectory
            .appendingPathComponent("\(prefix) \(formatter.string(from: Date()))")
            .appendingPathExtension("wav")
    }

    private static func defaultTitle(for kind: AudioRecordKind, date: Date) -> String {
        "\(kind.title) · \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private static func transcriptChunks(
        _ transcript: String,
        maximumCharacters: Int
    ) -> [String] {
        guard transcript.count > maximumCharacters else {
            return [transcript]
        }
        var chunks: [String] = []
        var start = transcript.startIndex
        while start < transcript.endIndex {
            let proposedEnd = transcript.index(
                start,
                offsetBy: maximumCharacters,
                limitedBy: transcript.endIndex
            ) ?? transcript.endIndex
            var end = proposedEnd
            if proposedEnd < transcript.endIndex,
               let newline = transcript[start..<proposedEnd].lastIndex(of: "\n")
            {
                end = transcript.index(after: newline)
            }
            chunks.append(String(transcript[start..<end]))
            start = end
        }
        return chunks
    }
}

struct MeetingApplication: Equatable {
    let processIdentifier: pid_t
    let displayName: String
}

@MainActor
final class MeetingJoinMonitor {
    var onMeetingJoined: ((MeetingApplication) -> Bool)?

    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var promptedProcessIdentifiers = Set<pid_t>()
    private var inputActivitySamples: [pid_t: Int] = [:]

    private static let pollingInterval: TimeInterval = 0.5
    private static let requiredInputActivitySamples = 2

    func start() {
        guard timer == nil else {
            return
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for notificationName in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
        ] {
            workspaceObservers.append(
                workspaceCenter.addObserver(
                    forName: notificationName,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.evaluate()
                    }
                }
            )
        }
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.resetState(for: application.processIdentifier)
                }
            }
        )

        let timer = Timer(timeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        evaluate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspaceCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        promptedProcessIdentifiers.removeAll()
        inputActivitySamples.removeAll()
    }

    private func evaluate() {
        guard AudioCapturePreferences.suggestMeetingTranscription else {
            promptedProcessIdentifiers.removeAll()
            inputActivitySamples.removeAll()
            return
        }

        clearInactiveMeetingStates()

        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier,
              Self.meetingApplicationNames[bundleIdentifier] != nil,
              application.activationPolicy == .regular
        else {
            return
        }

        let processIdentifier = application.processIdentifier
        guard Self.isInputRunning(forProcessIdentifier: processIdentifier) else {
            inputActivitySamples[processIdentifier] = 0
            promptedProcessIdentifiers.remove(processIdentifier)
            return
        }

        let sampleCount = min(
            Self.requiredInputActivitySamples,
            (inputActivitySamples[processIdentifier] ?? 0) + 1
        )
        inputActivitySamples[processIdentifier] = sampleCount
        guard sampleCount >= Self.requiredInputActivitySamples,
              !promptedProcessIdentifiers.contains(processIdentifier)
        else {
            return
        }

        let displayName = Self.meetingApplicationNames[bundleIdentifier]
            ?? application.localizedName
            ?? "the meeting app"
        let shouldRememberPrompt = onMeetingJoined?(
            MeetingApplication(
                processIdentifier: processIdentifier,
                displayName: displayName
            )
        ) ?? false
        if shouldRememberPrompt {
            promptedProcessIdentifiers.insert(processIdentifier)
        }
    }

    private func clearInactiveMeetingStates() {
        for processIdentifier in promptedProcessIdentifiers
            where !Self.isInputRunning(forProcessIdentifier: processIdentifier)
        {
            resetState(for: processIdentifier)
        }
    }

    private func resetState(for processIdentifier: pid_t) {
        promptedProcessIdentifiers.remove(processIdentifier)
        inputActivitySamples.removeValue(forKey: processIdentifier)
    }

    private static let meetingApplicationNames: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "com.apple.FaceTime": "FaceTime",
        "com.google.Chrome": "Google Meet",
        "com.apple.Safari": "Google Meet",
        "org.mozilla.firefox": "Google Meet",
        "com.microsoft.edgemac": "Google Meet",
        "company.thebrowser.Browser": "Google Meet",
        "com.brave.Browser": "Google Meet",
    ]

    private static func isInputRunning(forProcessIdentifier rootProcessIdentifier: pid_t) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return false
        }

        let processCount = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        guard processCount > 0 else {
            return false
        }
        var processObjects = [AudioObjectID](repeating: 0, count: processCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &processObjects
        ) == noErr else {
            return false
        }

        for processObject in processObjects {
            guard let processIdentifier = processIdentifier(for: processObject),
                  isDescendant(processIdentifier, of: rootProcessIdentifier),
                  isProcessInputRunning(processObject)
            else {
                continue
            }
            return true
        }
        return false
    }

    private static func processIdentifier(for processObject: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processIdentifier: pid_t = 0
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &dataSize,
            &processIdentifier
        ) == noErr else {
            return nil
        }
        return processIdentifier
    }

    private static func isProcessInputRunning(_ processObject: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &dataSize,
            &isRunning
        ) == noErr && isRunning != 0
    }

    private static func isDescendant(_ processIdentifier: pid_t, of rootProcessIdentifier: pid_t) -> Bool {
        var currentProcessIdentifier = processIdentifier
        var visited = Set<pid_t>()
        while currentProcessIdentifier > 1,
              visited.insert(currentProcessIdentifier).inserted
        {
            if currentProcessIdentifier == rootProcessIdentifier {
                return true
            }

            var processInfo = proc_bsdinfo()
            let result = withUnsafeMutablePointer(to: &processInfo) { pointer in
                proc_pidinfo(
                    currentProcessIdentifier,
                    PROC_PIDTBSDINFO,
                    0,
                    pointer,
                    Int32(MemoryLayout<proc_bsdinfo>.size)
                )
            }
            guard result == Int32(MemoryLayout<proc_bsdinfo>.size) else {
                return false
            }
            currentProcessIdentifier = pid_t(processInfo.pbi_ppid)
        }
        return false
    }
}
