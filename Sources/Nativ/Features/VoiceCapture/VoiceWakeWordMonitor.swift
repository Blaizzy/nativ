import AVFoundation
import Combine
import Foundation
import Speech

/// An opt-in, on-device listener. Background audio is streamed in memory and never saved.
@MainActor
final class VoiceWakeWordMonitor: ObservableObject {
    enum State: Equatable {
        case off, paused, preparing, listening
        case unavailable(String)

        var description: String {
            switch self {
            case .off: "Wake word is off."
            case .paused: "Wake word is paused while audio is busy."
            case .preparing: "Preparing on-device wake word…"
            case .listening: "Listening for “hey nativ”."
            case let .unavailable(message): message
            }
        }
    }

    static let shared = VoiceWakeWordMonitor()
    @Published private(set) var state: State = .off
    var onWake: (() -> Void)?

    private struct Configuration: Equatable {
        var enabled: Bool
        var suspended: Bool
        var deviceID: String?
    }

    private var configuration = Configuration(enabled: false, suspended: false)
    private let inputSession = AudioInputEngineSession()
    private var sessionID = UUID()
    private var task: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    func configure(enabled: Bool, suspended: Bool, deviceID: String?) {
        let next = Configuration(enabled: enabled, suspended: suspended, deviceID: deviceID)
        guard next != configuration else { return }
        configuration = next
        restart()
    }

    func restart() {
        stopSession()
        guard configuration.enabled else { state = .off; return }
        guard !configuration.suspended else { state = .paused; return }
        state = .preparing
        let id = sessionID
        let deviceID = configuration.deviceID
        task = Task { [weak self] in
            // Let the previous recording's feedback finish before rearming the mic.
            do { try await Task.sleep(for: .milliseconds(750)) }
            catch { return }
            await self?.listen(id: id, deviceID: deviceID)
        }
    }

    private func listen(id: UUID, deviceID: String?) async {
        do {
            let granted = await NativSystemPermissionController.requestMicrophone()
            guard isCurrent(id) else { return }
            guard granted else {
                fail("Allow microphone access in System Settings, then try again.", id: id, retry: false)
                return
            }
            // The fixed English phrase works independently of the dictation language.
            guard SpeechTranscriber.isAvailable,
                  let locale = await SpeechTranscriber.supportedLocale(
                    equivalentTo: Locale(identifier: "en-US")
                  )
            else {
                fail("The on-device English speech recognizer is unavailable.", id: id, retry: false)
                return
            }
            guard isCurrent(id) else { return }
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: []
            )
            if await AssetInventory.status(forModules: [transcriber]) != .installed {
                _ = try? await AssetInventory.reserve(locale: locale)
                guard isCurrent(id) else { return }
                if let installation = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber]
                ) {
                    try await installation.downloadAndInstall()
                }
            }
            guard isCurrent(id) else { return }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]
            ) else { throw VoiceAudioRecorderError.couldNotConvert }
            guard isCurrent(id) else { return }

            let analyzer = SpeechAnalyzer(
                modules: [transcriber],
                options: .init(priority: .utility, modelRetention: .whileInUse)
            )
            self.analyzer = analyzer
            let context = AnalysisContext()
            context.contextualStrings[.general] = ["hey nativ", "hey native"]
            try await analyzer.setContext(context)
            try await analyzer.prepareToAnalyze(in: format)
            guard isCurrent(id) else { return }

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
                bufferingPolicy: .bufferingNewest(32)
            )
            self.continuation = continuation
            let bridge = VoiceWakeWordAudioBridge(format: format, continuation: continuation) {
                [weak self] in
                Task { @MainActor [weak self] in
                    self?.fail("Could not read microphone audio. Retrying…", id: id)
                }
            }
            resultsTask = Task { [weak self] in
                var detector = VoiceWakeWordDetection()
                do {
                    for try await result in transcriber.results {
                        guard let self, self.isCurrent(id) else { return }
                        if detector.consume(
                            String(result.text.characters),
                            start: result.range.start.seconds,
                            end: result.range.end.seconds,
                            isFinal: result.isFinal
                        ) {
                            self.stopSession()
                            self.state = .paused
                            self.onWake?()
                            return
                        }
                    }
                    self?.fail("Wake-word recognition stopped. Retrying…", id: id)
                } catch {
                    self?.fail("Wake-word recognition was interrupted. Retrying…", id: id)
                }
            }
            try inputSession.start(deviceUniqueID: deviceID, tap: { buffer, _ in
                bridge.append(buffer)
            }) { [weak self] error in
                self?.fail(error.localizedDescription, id: id)
            }
            state = .listening
            // Bound the recognizer's session history during all-day listening.
            renewalTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(300)) }
                catch { return }
                guard let self, self.isCurrent(id) else { return }
                self.restart()
            }
            _ = try await analyzer.analyzeSequence(stream)
            fail("Wake-word recognition stopped. Retrying…", id: id)
        } catch {
            fail("Wake word is unavailable: \(error.localizedDescription)", id: id)
        }
    }

    private func isCurrent(_ id: UUID) -> Bool {
        id == sessionID && !Task.isCancelled
    }

    private func fail(_ message: String, id: UUID, retry: Bool = true) {
        guard isCurrent(id) else { return }
        stopSession()
        state = .unavailable(message)
        guard retry else { return }
        let retryID = sessionID
        task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
            guard let self, self.isCurrent(retryID) else { return }
            self.restart()
        }
    }

    private func stopSession() {
        sessionID = UUID()
        inputSession.stop()
        continuation?.finish()
        continuation = nil
        task?.cancel()
        task = nil
        resultsTask?.cancel()
        resultsTask = nil
        renewalTask?.cancel()
        renewalTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
    }
}

/// Converts and owns each buffer before the audio callback returns. The converter is
/// protected across engine restarts; the bounded stream cannot accumulate ambient audio.
final class VoiceWakeWordAudioBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onFailure: @Sendable () -> Void
    private var converter: AVAudioConverter?
    private var pendingBuffer: AVAudioPCMBuffer?
    private var failed = false

    init(
        format: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        onFailure: @escaping @Sendable () -> Void
    ) {
        self.format = format
        self.continuation = continuation
        self.onFailure = onFailure
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let shouldReport = lock.withLock { () -> Bool in
            guard !failed, buffer.frameLength > 0 else { return false }
            do {
                if converter?.inputFormat != buffer.format {
                    converter = AVAudioConverter(from: buffer.format, to: format)
                    converter?.downmix = true
                }
                guard let converter else { throw VoiceAudioRecorderError.couldNotConvert }
                pendingBuffer = buffer
                defer { pendingBuffer = nil }
                while true {
                    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)
                    else { throw VoiceAudioRecorderError.couldNotConvert }
                    var error: NSError?
                    let status = converter.convert(to: output, error: &error) { [self] _, status in
                        if let buffer = pendingBuffer {
                            pendingBuffer = nil
                            status.pointee = .haveData
                            return buffer
                        }
                        status.pointee = .noDataNow
                        return nil
                    }
                    if status == .error { throw VoiceAudioRecorderError.couldNotConvert }
                    if output.frameLength > 0 {
                        continuation.yield(AnalyzerInput(buffer: output))
                    }
                    if status != .haveData { break }
                }
                return false
            } catch {
                failed = true
                return true
            }
        }
        if shouldReport { onFailure() }
    }
}
