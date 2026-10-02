@preconcurrency import AVFoundation
import Foundation

@MainActor
final class AudioInputLevelState: ObservableObject {
    @Published private(set) var level: Float = 0

    func update(_ level: Float) {
        self.level = max(0, min(1, level))
    }
}

@MainActor
final class AudioInputLevelMonitor: ObservableObject {
    let meterState = AudioInputLevelState()
    @Published private(set) var isMonitoring = false
    @Published private(set) var errorMessage: String?

    private let inputSession = AudioInputCaptureSession()
    private var requestID = UUID()
    private var realtimeMeter: RealtimeAudioMeter?
    private var meterPublisherTask: Task<Void, Never>?

    func start(deviceUniqueID: String?) async {
        let id = UUID()
        requestID = id
        errorMessage = nil
        if isMonitoring {
            do { try await inputSession.select(deviceUniqueID: deviceUniqueID) }
            catch {
                guard requestID == id else { return }
                errorMessage = error.localizedDescription
            }
            return
        }
        stopMeterPublisher()

        guard Self.hasMicrophoneAccess() else {
            errorMessage = "Microphone access is required to test this input."
            return
        }

        do {
            let realtimeMeter = RealtimeAudioMeter(profile: .inputMonitor)
            try await inputSession.start(
                deviceUniqueID: deviceUniqueID,
                tap: Self.makeTap(realtimeMeter: realtimeMeter)
            ) { [weak self] error in
                self?.errorMessage = error.localizedDescription
                self?.stop(resetError: false)
            }
            guard requestID == id else { return }
            isMonitoring = true
            startMeterPublisher(realtimeMeter: realtimeMeter)
        } catch {
            guard requestID == id else { return }
            errorMessage = error.localizedDescription
            stop(resetError: false)
        }
    }

    func restart(deviceUniqueID: String?) async {
        guard isMonitoring else {
            return
        }
        await start(deviceUniqueID: deviceUniqueID)
    }

    func stop() {
        stop(resetError: true)
    }

    private func stop(resetError: Bool) {
        requestID = UUID()
        inputSession.stop()
        isMonitoring = false
        stopMeterPublisher()
        meterState.update(0)
        if resetError {
            errorMessage = nil
        }
    }

    private func startMeterPublisher(realtimeMeter: RealtimeAudioMeter) {
        self.realtimeMeter = realtimeMeter
        meterPublisherTask = Task { [weak self, realtimeMeter] in
            await RealtimeAudioMeterPublisher.run(meter: realtimeMeter) {
                [weak self, realtimeMeter] snapshot in
                guard
                    let self,
                    self.realtimeMeter === realtimeMeter,
                    self.isMonitoring
                else {
                    return
                }
                self.meterState.update(snapshot.level)
            }
        }
    }

    private func stopMeterPublisher() {
        realtimeMeter = nil
        meterPublisherTask?.cancel()
        meterPublisherTask = nil
    }

    nonisolated static func makeTap(
        realtimeMeter: RealtimeAudioMeter
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            realtimeMeter.submit(
                level: normalizedLevel(from: buffer),
                elapsed: 0
            )
        }
    }

    private nonisolated static func normalizedLevel(
        from buffer: AVAudioPCMBuffer
    ) -> Float {
        guard let channelData = buffer.floatChannelData else {
            return 0
        }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else {
            return 0
        }

        var sum: Float = 0
        let sampleCount = channelCount * frameCount
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                let sample = samples[frame * buffer.stride]
                sum += sample * sample
            }
        }
        let rootMeanSquare = sqrt(sum / Float(sampleCount))
        return pow(min(1, rootMeanSquare * 8), 0.65)
    }

    private static func hasMicrophoneAccess() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}

protocol AudioInputCaptureDriving: Sendable {
    func start(
        deviceUniqueID: String?,
        delivery: AudioInputCaptureDelivery,
        onFailure: @escaping @Sendable (Error) -> Void
    ) async throws
    func select(deviceUniqueID: String?) async throws
    func stop() async
}

@MainActor
final class AudioInputCaptureSession {
    private let makeCapture: () -> any AudioInputCaptureDriving
    private var capture: (any AudioInputCaptureDriving)?
    private var delivery: AudioInputCaptureDelivery?
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    init(makeCapture: @escaping () -> any AudioInputCaptureDriving = { SystemAudioInputCapture() }) {
        self.makeCapture = makeCapture
    }

    func start(
        deviceUniqueID: String?,
        tap: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onFailure: @escaping @MainActor @Sendable (Error) -> Void
    ) async throws {
        stop()
        let id = generation
        let capture = makeCapture()
        let delivery = AudioInputCaptureDelivery(tap: tap)
        self.capture = capture
        self.delivery = delivery
        let previous = operation
        let start = Task {
            await previous?.value
            guard generation == id, !Task.isCancelled else { throw CancellationError() }
            try await capture.start(deviceUniqueID: deviceUniqueID, delivery: delivery) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id else { return }
                    self.stop()
                    onFailure(error)
                }
            }
        }
        operation = Task { _ = await start.result }
        do {
            try await start.value
            guard generation == id else { throw CancellationError() }
            try Task.checkCancellation()
        } catch {
            guard generation == id else { throw CancellationError() }
            stop()
            throw error
        }
    }

    func select(deviceUniqueID: String?) async throws {
        guard let capture else { throw VoiceAudioRecorderError.couldNotStart }
        let id = generation
        let previous = operation
        let selection = Task {
            await previous?.value
            guard generation == id, !Task.isCancelled else { throw CancellationError() }
            try await capture.select(deviceUniqueID: deviceUniqueID)
        }
        operation = Task { _ = await selection.result }
        try await selection.value
        guard generation == id else { throw CancellationError() }
    }

    func stop() {
        generation = UUID()
        delivery?.stop()
        delivery = nil
        guard let capture else { return }
        self.capture = nil
        let previous = operation
        operation = Task {
            await previous?.value
            await capture.stop()
        }
    }

    isolated deinit {
        delivery?.stop()
        let capture = capture
        let previous = operation
        Task {
            await previous?.value
            await capture?.stop()
        }
    }
}

final class AudioInputCaptureDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var tap: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

    init(tap: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        self.tap = tap
    }

    func submit(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.withLock { tap?(buffer, time) }
    }

    func stop() {
        lock.withLock { tap = nil }
    }
}

private actor SystemAudioInputCapture: AudioInputCaptureDriving {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(label: "dev.nativ.microphone.samples")
    private var input: AVCaptureDeviceInput?
    private var receiver: AudioInputSampleReceiver?
    private var observers: [NSObjectProtocol] = []

    func start(
        deviceUniqueID: String?,
        delivery: AudioInputCaptureDelivery,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        let receiver = AudioInputSampleReceiver(delivery: delivery, onFailure: onFailure)
        self.receiver = receiver
        output.setSampleBufferDelegate(receiver, queue: sampleQueue)
        session.beginConfiguration()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw VoiceAudioRecorderError.couldNotStart
        }
        session.addOutput(output)
        session.commitConfiguration()
        try select(deviceUniqueID: deviceUniqueID)
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { notification in
            onFailure(notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                ?? VoiceAudioRecorderError.couldNotStart)
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let deviceID = (notification.object as? AVCaptureDevice)?.uniqueID else { return }
            Task { await self?.disconnected(deviceID: deviceID, onFailure: onFailure) }
        })
        session.startRunning()
        guard session.isRunning else {
            throw VoiceAudioRecorderError.couldNotStart
        }
    }

    func select(deviceUniqueID: String?) throws {
        let device: AVCaptureDevice?
        if let deviceUniqueID, !deviceUniqueID.isEmpty {
            device = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
            ).devices.first { $0.uniqueID == deviceUniqueID }
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device else { throw VoiceAudioRecorderError.inputDeviceUnavailable }
        guard input?.device.uniqueID != device.uniqueID else { return }
        let replacement = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let previous = input
        if let previous { session.removeInput(previous) }
        guard session.canAddInput(replacement) else {
            if let previous { session.addInput(previous) }
            throw VoiceAudioRecorderError.couldNotStart
        }
        session.addInput(replacement)
        input = replacement
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        session.stopRunning()
        output.setSampleBufferDelegate(nil, queue: nil)
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        if session.outputs.contains(output) { session.removeOutput(output) }
        session.commitConfiguration()
        input = nil
        receiver = nil
    }

    private func disconnected(deviceID: String, onFailure: @Sendable (Error) -> Void) {
        guard input?.device.uniqueID == deviceID else { return }
        onFailure(VoiceAudioRecorderError.inputDeviceUnavailable)
    }
}

final class AudioInputSampleReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let delivery: AudioInputCaptureDelivery
    private let onFailure: @Sendable (Error) -> Void
    private var buffer: AVAudioPCMBuffer?
    private var converter: AVAudioConverter?
    private var converted: AVAudioPCMBuffer?
    private var failed = false

    init(delivery: AudioInputCaptureDelivery, onFailure: @escaping @Sendable (Error) -> Void) {
        self.delivery = delivery
        self.onFailure = onFailure
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        consume(sampleBuffer)
    }

    func consume(_ sampleBuffer: CMSampleBuffer) {
        guard !failed, sampleBuffer.numSamples > 0 else { return }
        do {
            guard let description = sampleBuffer.formatDescription else {
                throw VoiceAudioRecorderError.couldNotConvert
            }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            let frames = AVAudioFrameCount(sampleBuffer.numSamples)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoiceAudioRecorderError.couldNotConvert
            }
            if buffer?.format != format || (buffer?.frameCapacity ?? 0) < frames {
                buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
                converter = nil
                converted = nil
            }
            guard let buffer else { throw VoiceAudioRecorderError.couldNotConvert }
            buffer.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
            )
            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            let pcm: AVAudioPCMBuffer
            if format.commonFormat == .pcmFormatFloat32 {
                pcm = buffer
            } else {
                if converter == nil {
                    guard let floatFormat = AVAudioFormat(
                        standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount
                    ) else { throw VoiceAudioRecorderError.couldNotConvert }
                    converter = AVAudioConverter(from: format, to: floatFormat)
                    converted = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: buffer.frameCapacity)
                }
                guard let converter, let converted else { throw VoiceAudioRecorderError.couldNotConvert }
                try converter.convert(to: converted, from: buffer)
                pcm = converted
            }
            let seconds = sampleBuffer.presentationTimeStamp.seconds
            let time = AVAudioTime(
                sampleTime: seconds.isFinite ? AVAudioFramePosition(seconds * format.sampleRate) : 0,
                atRate: format.sampleRate
            )
            delivery.submit(pcm, at: time)
        } catch {
            failed = true
            onFailure(error)
        }
    }
}
