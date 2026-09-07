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

    private var audioEngine: AVAudioEngine?
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
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            if let deviceUniqueID {
                guard let deviceID = AudioInputDeviceResolver.coreAudioDeviceID(
                    for: deviceUniqueID
                ) else {
                    throw VoiceAudioRecorderError.inputDeviceUnavailable
                }
                try inputNode.auAudioUnit.setDeviceID(deviceID)
            }

            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoiceAudioRecorderError.couldNotStart
            }

            let realtimeMeter = RealtimeAudioMeter(profile: .inputMonitor)
            let tap = Self.makeTap(realtimeMeter: realtimeMeter)
            inputNode.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: format,
                block: tap
            )
            engine.prepare()
            try engine.start()
            audioEngine = engine
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
        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        audioEngine = nil
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
                let sample = samples[frame]
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
