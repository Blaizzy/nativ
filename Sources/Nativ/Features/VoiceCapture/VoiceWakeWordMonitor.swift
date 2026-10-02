import AVFoundation
import Combine
import Foundation

/// Opt-in listener. Ambient history stays in memory; only confirmed dictation is saved.
@MainActor
final class VoiceWakeWordMonitor: ObservableObject {
    enum State: Equatable {
        case off, paused, preparing, listening, confirming, capturing
        case unavailable(String)

        var description: String {
            switch self {
            case .off: "Wake word is off."
            case .paused: "Wake word is paused while audio is busy."
            case .preparing: "Preparing on-device wake word…"
            case .listening: "Listening for “hey nativ”."
            case .confirming: "Confirming “hey nativ”…"
            case .capturing: "Recording dictation…"
            case let .unavailable(message): message
            }
        }
    }

    static let shared = VoiceWakeWordMonitor()
    @Published private(set) var state: State = .off
    var onCandidate: (() -> Void)?
    var confirm: ((Data) async throws -> VoiceWakeWordTranscription)?
    var onConfirmed: (() -> Void)?
    var onFinished: ((VoiceWakeWordCapture.Result) -> Void)?
    var onCancelled: (() -> Void)?
    var onMeterUpdate: ((Float, TimeInterval) -> Void)?

    private struct Configuration: Equatable {
        var enabled: Bool
        var suspended: Bool
        var deviceID: String?
    }

    private var configuration = Configuration(enabled: false, suspended: false)
    private let inputSession = AudioInputEngineSession()
    private var sessionID = UUID()
    private var task: Task<Void, Never>?
    private var inferenceTask: Task<Void, Never>?
    private var confirmationTask: Task<Void, Never>?
    private var processor: VoiceWakeWordProcessor?
    private var continuation: AsyncStream<VoiceWakeWordAudioChunk>.Continuation?

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
            guard let modelURL = Bundle.main.url(forResource: "HeyNativ", withExtension: "mlmodelc")
            else { throw VoiceWakeWordModelError.missingModel }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
            else { throw VoiceAudioRecorderError.couldNotConvert }
            let (stream, continuation) = AsyncStream<VoiceWakeWordAudioChunk>.makeStream(
                bufferingPolicy: .bufferingNewest(8)
            )
            self.continuation = continuation
            let bridge = VoiceWakeWordAudioBridge(format: format, continuation: continuation) {
                [weak self] in
                Task { @MainActor [weak self] in
                    self?.fail("Could not read microphone audio. Retrying…", id: id)
                }
            }
            inferenceTask = Task.detached(priority: .utility) { [weak self] in
                do {
                    let processor = try VoiceWakeWordProcessor(url: modelURL)
                    try Task.checkCancellation()
                    guard try await self?.startInput(bridge: bridge, processor: processor, deviceID: deviceID, id: id) == true
                    else { return }
                    for await chunk in stream {
                        try Task.checkCancellation()
                        let output = try await processor.consume(chunk)
                        if output.event != nil || output.isConfirmed {
                            await self?.handle(output, processor: processor, id: id)
                        }
                    }
                    await self?.fail("Wake-word recognition stopped. Retrying…", id: id)
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.fail("Wake word is unavailable: \(error.localizedDescription)", id: id)
                }
            }
        } catch {
            fail("Wake word is unavailable: \(error.localizedDescription)", id: id)
        }
    }

    private func startInput(bridge: VoiceWakeWordAudioBridge, processor: VoiceWakeWordProcessor, deviceID: String?, id: UUID) throws -> Bool {
        guard isCurrent(id) else { return false }
        self.processor = processor
        try inputSession.start(deviceUniqueID: deviceID, tap: { buffer, _ in
            bridge.append(buffer)
        }) { [weak self] error in
            self?.fail(error.localizedDescription, id: id)
        }
        state = .listening
        return true
    }

    private func handle(_ output: VoiceWakeWordProcessor.Output, processor: VoiceWakeWordProcessor, id: UUID) {
        guard isCurrent(id) else { return }
        if state == .capturing { onMeterUpdate?(output.level, output.elapsed) }
        switch output.event {
        case .candidate:
            state = .confirming
            onCandidate?()
        case let .confirm(candidateID, audio):
            guard let confirm else {
                fail("Wake-word confirmation is unavailable.", id: id, retry: false)
                return
            }
            confirmationTask = Task { [weak self] in
                do {
                    // WAV encoding and inference stay off the audio callback/main actor.
                    let data = await processor.encode(audio)
                    let transcription = try await confirm(data)
                    guard let self, self.isCurrent(id) else { return }
                    guard let accepted = await processor.resolve(id: candidateID, transcription: transcription),
                          self.isCurrent(id) else { return }
                    self.confirmationTask = nil
                    self.state = accepted ? .capturing : .listening
                    if accepted { self.onConfirmed?() } else { self.onCancelled?() }
                } catch {
                    guard let self, self.isCurrent(id) else { return }
                    self.fail("Wake-word confirmation failed: \(error.localizedDescription)", id: id)
                }
            }
        case let .finished(result):
            complete(result, id: id)
        case nil:
            break
        }
    }

    func finishCapture() {
        guard state == .capturing, let processor else { return }
        let id = sessionID
        Task { [weak self] in
            if let result = await processor.finish() { self?.complete(result, id: id) }
        }
    }

    private func complete(_ result: VoiceWakeWordCapture.Result, id: UUID) {
        guard isCurrent(id) else { return }
        stopSession(notify: false)
        state = .paused
        onFinished?(result)
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

    private func stopSession(notify: Bool = true) {
        sessionID = UUID()
        inputSession.stop()
        continuation?.finish()
        continuation = nil
        task?.cancel()
        task = nil
        inferenceTask?.cancel()
        inferenceTask = nil
        confirmationTask?.cancel()
        confirmationTask = nil
        processor = nil
        if notify { onCancelled?() }
    }
}

/// Serializes audio and confirmation results without blocking capture on network ASR.
private actor VoiceWakeWordProcessor {
    struct Output: Sendable {
        let event: VoiceWakeWordCapture.Event?
        let isConfirmed: Bool
        let level: Float
        let elapsed: TimeInterval
    }

    private let detector: VoiceWakeWordModel
    private var capture = VoiceWakeWordCapture()

    init(url: URL) throws { detector = try VoiceWakeWordModel(url: url) }

    func consume(_ chunk: VoiceWakeWordAudioChunk) throws -> Output {
        let detected = capture.canDetect ? try detector.consume(chunk) : false
        let event = try capture.append(chunk, detected: detected)
        return Output(event: event, isConfirmed: capture.isConfirmed, level: capture.level, elapsed: capture.elapsed)
    }

    func encode(_ audio: VoiceWakeWordAudio) -> Data { audio.wavData }
    func resolve(id: UUID, transcription: VoiceWakeWordTranscription) -> Bool? {
        capture.resolve(id: id, transcription: transcription)
    }
    func finish() -> VoiceWakeWordCapture.Result? { capture.finish() }
}

/// Converts and owns each buffer before the audio callback returns. The converter is
/// protected across engine restarts; the bounded stream cannot accumulate ambient audio.
final class VoiceWakeWordAudioBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let format: AVAudioFormat
    private let continuation: AsyncStream<VoiceWakeWordAudioChunk>.Continuation
    private let onFailure: @Sendable () -> Void
    private var converter: AVAudioConverter?
    private var pendingBuffer: AVAudioPCMBuffer?
    private var failed = false
    private var sampleOffset: Int64 = 0

    init(
        format: AVAudioFormat,
        continuation: AsyncStream<VoiceWakeWordAudioChunk>.Continuation,
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
                        guard let samples = output.floatChannelData?[0]
                        else { throw VoiceAudioRecorderError.couldNotConvert }
                        let count = Int(output.frameLength)
                        continuation.yield(VoiceWakeWordAudioChunk(
                            samples: Array(UnsafeBufferPointer(start: samples, count: count)),
                            offset: sampleOffset
                        ))
                        sampleOffset += Int64(count)
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
