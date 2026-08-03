import AVFoundation
import Foundation

@MainActor
final class AudioInputLevelMonitor: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var isMonitoring = false
    @Published private(set) var errorMessage: String?

    private var audioEngine: AVAudioEngine?
    private var smoothedLevel: Float = 0

    func start(deviceUniqueID: String?) async {
        stop()
        errorMessage = nil

        guard await Self.requestMicrophoneAccess() else {
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

            inputNode.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: format
            ) { [weak self] buffer, _ in
                let level = Self.normalizedLevel(from: buffer)
                Task { @MainActor [weak self] in
                    self?.update(level: level)
                }
            }
            engine.prepare()
            try engine.start()
            audioEngine = engine
            isMonitoring = true
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
        smoothedLevel = 0
        level = 0
        if resetError {
            errorMessage = nil
        }
    }

    private func update(level newLevel: Float) {
        guard isMonitoring else {
            return
        }
        smoothedLevel = (smoothedLevel * 0.65) + (newLevel * 0.35)
        level = smoothedLevel
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

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .denied, .restricted:
            false
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default:
            false
        }
    }
}
