import CoreML
import Foundation

enum VoiceWakeWordModelError: LocalizedError {
    case missingModel
    case invalidModel(String)

    var errorDescription: String? {
        switch self {
        case .missingModel: "The bundled Hey Nativ model is missing. Reinstall Nativ and try again."
        case let .invalidModel(message): message
        }
    }
}

/// Sample offsets expose dropped buffers so a discontinuity cannot join unrelated audio.
struct VoiceWakeWordAudioChunk: Sendable {
    let samples: [Float]
    let offset: Int64
}

/// Tracks the quietest fifth of recent 20 ms frames, rather than treating microphone
/// self-noise as speech. Only energy measurements are retained here, not audio.
struct VoiceWakeWordEnergyGate {
    private var history = [Double](repeating: 0, count: 250)
    private var index = 0
    private var count = 0
    private var noiseFloor = 0.0
    private var attackFrames = 0
    private var activeFrames = 0

    mutating func consume(power: Double) -> Bool {
        // A large drop starts a quieter environment; do not retain its old loud floor.
        if power < noiseFloor * 0.1 {
            count = 0
            index = 0
            noiseFloor = 0
        }
        history[index] = power
        index = (index + 1) % history.count
        count = min(count + 1, history.count)
        // Keep startup responsive; a two-second phrase can trigger before calibration.
        // Five seconds of history keeps short speech bursts out of the noise estimate.
        if count >= 100, index % 10 == 0 {
            let sorted = history.prefix(count).sorted()
            noiseFloor = sorted[(count - 1) / 5]
        }
        // Follow smaller decreases without waiting for the history to turn over.
        noiseFloor = min(noiseFloor, power)
        // Six dB above the noise floor; retain the existing -50 dBFS quiet-room floor.
        let threshold = max(1e-5, noiseFloor * 4)
        if power >= threshold {
            attackFrames = min(attackFrames + 1, 2)
            if attackFrames == 2 || activeFrames > 0 { activeFrames = 25 }
        } else {
            attackFrames = 0
        }
        let active = activeFrames > 0
        activeFrames = max(0, activeFrames - 1)
        return active
    }
}

/// Two seconds of mono audio, scored every 20 ms while the energy gate is open.
struct VoiceWakeWordWindow {
    private var samples = [Float](repeating: 0, count: 32_000)
    private var index = 0
    private var sampleCount: Int64 = 0
    private var frameEnergy = 0.0
    private var gate = VoiceWakeWordEnergyGate()

    mutating func append(_ sample: Float) -> Bool {
        samples[index] = sample
        index = (index + 1) % samples.count
        sampleCount += 1
        frameEnergy += Double(sample) * Double(sample)
        guard sampleCount % 320 == 0 else { return false }
        let active = gate.consume(power: frameEnergy / 320)
        frameEnergy = 0
        return active
    }

    func snapshot() -> [Float] {
        Array(samples[index...]) + Array(samples[..<index])
    }
}

/// Created and used only inside the listener's detached inference task.
/// The fixed HN-2 model and frontend require no server or third-party runtime.
final class VoiceWakeWordModel {
    static let threshold: Float = 0.3
    private let model: MLModel
    private let features: VoiceWakeWordFeatures
    private let input: MLMultiArray
    private let provider: MLDictionaryFeatureProvider
    private var window = VoiceWakeWordWindow()
    private var expectedOffset: Int64 = 0

    init(url: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: url, configuration: configuration)
        features = try VoiceWakeWordFeatures()
        guard let constraint = model.modelDescription.inputDescriptionsByName["mels"]?.multiArrayConstraint,
              constraint.shape.map(\.intValue) == [1, 128, 200],
              constraint.dataType == .float32,
              model.modelDescription.outputDescriptionsByName["probability"]?.multiArrayConstraint?.shape
                .map(\.intValue) == [1]
        else { throw VoiceWakeWordModelError.invalidModel("The Hey Nativ model has an incompatible audio format.") }
        input = try MLMultiArray(shape: [1, 128, 200], dataType: .float32)
        provider = try MLDictionaryFeatureProvider(dictionary: ["mels": MLFeatureValue(multiArray: input)])
    }

    func consume(_ chunk: VoiceWakeWordAudioChunk) throws -> Bool {
        if chunk.offset != expectedOffset { window = VoiceWakeWordWindow() }
        expectedOffset = chunk.offset + Int64(chunk.samples.count)
        var detected = false
        for sample in chunk.samples {
            let shouldScore = window.append(sample)
            guard shouldScore, !detected else { continue }
            try Task.checkCancellation()
            if try probability(audio: window.snapshot()) >= Self.threshold { detected = true }
        }
        return detected
    }

    func probability(audio: [Float]) throws -> Float {
        let mels = try features.compute(audio)
        let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: mels.count)
        let melStride = input.strides[1].intValue
        let frameStride = input.strides[2].intValue
        for mel in 0..<128 {
            for frame in 0..<200 {
                pointer[mel * melStride + frame * frameStride] = mels[mel * 200 + frame]
            }
        }
        let result = try model.prediction(from: provider)
        guard let score = result.featureValue(for: "probability")?.multiArrayValue?[0].floatValue,
              score.isFinite, (0...1).contains(score)
        else { throw VoiceWakeWordModelError.invalidModel("The Hey Nativ model returned an invalid score.") }
        return score
    }
}
