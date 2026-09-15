import AVFoundation
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

    private let inputSession = AudioInputEngineSession()
    private var realtimeMeter: RealtimeAudioMeter?
    private var meterPublisherTask: Task<Void, Never>?

    func start(deviceUniqueID: String?) async {
        stop()
        errorMessage = nil

        guard Self.hasMicrophoneAccess() else {
            errorMessage = "Microphone access is required to test this input."
            return
        }

        do {
            let realtimeMeter = RealtimeAudioMeter(profile: .inputMonitor)
            try inputSession.start(
                deviceUniqueID: deviceUniqueID,
                tap: Self.makeTap(realtimeMeter: realtimeMeter)
            ) { [weak self] error in
                self?.errorMessage = error.localizedDescription
                self?.stop(resetError: false)
            }
            isMonitoring = true
            startMeterPublisher(realtimeMeter: realtimeMeter)
        } catch {
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

@MainActor
protocol AudioInputEngineDriving: AnyObject {
    var isRunning: Bool { get }
    var onConfigurationChange: (() -> Void)? { get set }
    func start(
        deviceUniqueID: String?,
        tap: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws
    func stop()
}

@MainActor
final class AudioInputEngineSession {
    private let makeEngine: () -> any AudioInputEngineDriving
    private let retryDelays: [Duration]
    private var engine: (any AudioInputEngineDriving)?
    private var recoveryTask: Task<Void, Never>?
    private var generation = UUID()

    init(
        retryDelays: [Duration] = [.milliseconds(100), .milliseconds(250), .milliseconds(500)],
        makeEngine: @escaping () -> any AudioInputEngineDriving = { SystemAudioInputEngine() }
    ) {
        self.retryDelays = retryDelays
        self.makeEngine = makeEngine
    }

    func start(
        deviceUniqueID: String?,
        tap: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onFailure: @escaping (Error) -> Void
    ) throws {
        stop()
        try startEngine(deviceUniqueID: deviceUniqueID, tap: tap, onFailure: onFailure)
    }

    func stop() {
        generation = UUID()
        recoveryTask?.cancel()
        recoveryTask = nil
        engine?.onConfigurationChange = nil
        engine?.stop()
        engine = nil
    }

    isolated deinit {
        recoveryTask?.cancel()
        engine?.stop()
    }

    private func startEngine(
        deviceUniqueID: String?,
        tap: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onFailure: @escaping (Error) -> Void
    ) throws {
        let nextEngine = makeEngine()
        let expectedGeneration = generation
        nextEngine.onConfigurationChange = { [weak self, weak nextEngine] in
            guard let self, let nextEngine,
                self.generation == expectedGeneration,
                self.engine === nextEngine,
                !nextEngine.isRunning,
                self.recoveryTask == nil
            else { return }
            nextEngine.onConfigurationChange = nil
            nextEngine.stop()
            self.engine = nil
            self.recoveryTask = Task { [weak self] in
                var failure: Error = VoiceAudioRecorderError.couldNotStart
                for delay in self?.retryDelays ?? [] {
                    do { try await Task.sleep(for: delay) }
                    catch { return }
                    guard !Task.isCancelled, let self,
                        self.generation == expectedGeneration
                    else { return }
                    do {
                        try self.startEngine(
                            deviceUniqueID: deviceUniqueID, tap: tap, onFailure: onFailure
                        )
                        self.recoveryTask = nil
                        return
                    } catch {
                        failure = error
                    }
                }
                guard let self, self.generation == expectedGeneration,
                    !Task.isCancelled
                else { return }
                self.stop()
                onFailure(failure)
            }
        }
        engine = nextEngine
        do {
            try nextEngine.start(deviceUniqueID: deviceUniqueID, tap: tap)
        } catch {
            nextEngine.onConfigurationChange = nil
            nextEngine.stop()
            engine = nil
            throw error
        }
    }
}

@MainActor
private final class SystemAudioInputEngine: AudioInputEngineDriving {
    var onConfigurationChange: (() -> Void)?
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var hasTap = false

    var isRunning: Bool { engine.isRunning }

    func start(
        deviceUniqueID: String?,
        tap: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        let input = engine.inputNode
        // An unavailable selected device falls back to the current system default.
        if let deviceUniqueID,
            let deviceID = AudioInputDeviceResolver.coreAudioDeviceID(for: deviceUniqueID)
        {
            try input.auAudioUnit.setDeviceID(deviceID)
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceAudioRecorderError.couldNotStart
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil, block: tap)
        hasTap = true
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // Engine teardown must happen outside AVFAudio's notification queue.
            Task { @MainActor [weak self] in
                guard let self, self.observer != nil else { return }
                self.onConfigurationChange?()
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if hasTap { engine.inputNode.removeTap(onBus: 0) }
        hasTap = false
        engine.stop()
    }

    isolated deinit { stop() }
}
