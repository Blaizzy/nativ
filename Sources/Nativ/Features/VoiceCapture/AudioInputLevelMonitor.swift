import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioInputLevelState: ObservableObject {
    @Published private(set) var level: Float = 0

    func update(_ level: Float) {
        self.level = max(0, min(1, level))
    }
}

@MainActor
final class MicrophoneCaptureActivity: ObservableObject {
    static let shared = MicrophoneCaptureActivity()
    @Published private(set) var isRecording = false
    private var recordings = Set<UUID>()
    weak var preview: AudioInputLevelMonitor?

    func acquire(_ id: UUID) async {
        recordings.insert(id)
        isRecording = true
        await preview?.stop()
    }

    func release(_ id: UUID) {
        recordings.remove(id)
        isRecording = !recordings.isEmpty
    }
}

@MainActor
final class AudioInputLevelMonitor: ObservableObject {
    let meterState = AudioInputLevelState()
    @Published private(set) var isMonitoring = false
    @Published private(set) var isStarting = false
    @Published private(set) var errorMessage: String?

    private let inputSession = AudioInputEngineSession()
    private var generation = UUID()
    private var realtimeMeter: RealtimeAudioMeter?
    private var meterPublisherTask: Task<Void, Never>?

    func start(deviceUniqueID: String?) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        generation = request
        await reset(resetError: true)
        guard generation == request, !Task.isCancelled,
              !MicrophoneCaptureActivity.shared.isRecording else { return }
        guard Self.hasMicrophoneAccess() else {
            errorMessage = "Microphone access is required to test this input."
            return
        }
        isStarting = true
        MicrophoneCaptureActivity.shared.preview = self
        do {
            let realtimeMeter = RealtimeAudioMeter(profile: .inputMonitor)
            try await inputSession.start(
                deviceUniqueID: deviceUniqueID,
                tap: Self.makeTap(realtimeMeter: realtimeMeter)
            ) { [weak self] error in
                Task { [weak self] in
                    guard let self, self.generation == request else { return }
                    self.errorMessage = error.localizedDescription
                    await self.reset(resetError: false)
                }
            }
            guard generation == request else { return }
            try Task.checkCancellation()
            isStarting = false
            isMonitoring = true
            startMeterPublisher(realtimeMeter: realtimeMeter)
        } catch {
            guard generation == request else { return }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            await reset(resetError: false)
        }
    }

    func stop() async {
        generation = UUID()
        await reset(resetError: true)
    }

    func cancel() {
        generation = UUID()
        isStarting = false
        isMonitoring = false
        errorMessage = nil
        stopMeterPublisher()
        meterState.update(0)
        let request = generation
        let retirement = inputSession.cancel()
        Task { [weak self] in
            await retirement.value
            guard let self, self.generation == request else { return }
            self.releasePreview()
        }
    }

    private func reset(resetError: Bool) async {
        isStarting = false
        isMonitoring = false
        stopMeterPublisher()
        meterState.update(0)
        if resetError { errorMessage = nil }
        let request = generation
        await inputSession.stop()
        if generation == request { releasePreview() }
    }

    private func releasePreview() {
        if MicrophoneCaptureActivity.shared.preview === self {
            MicrophoneCaptureActivity.shared.preview = nil
        }
    }

    isolated deinit { meterPublisherTask?.cancel() }

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
