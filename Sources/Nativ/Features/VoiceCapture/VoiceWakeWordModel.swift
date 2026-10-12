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
    private(set) var sampleCount: Int64 = 0
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
        var result = [Float](repeating: 0, count: samples.count)
        copySamples(into: &result)
        return result
    }

    func copySamples(into output: inout [Float]) {
        precondition(output.count == samples.count)
        samples.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!.update(from: source.baseAddress! + index, count: samples.count - index)
                (destination.baseAddress! + samples.count - index).update(from: source.baseAddress!, count: index)
            }
        }
    }
}

/// Created and used only inside the listener's detached inference task.
/// The fixed HN-2 model and frontend require no server or third-party runtime.
final class VoiceWakeWordModel {
    let threshold: Float
    private let model: MLModel
    private let features: VoiceWakeWordFeatures
    private let input: MLMultiArray
    private let provider: MLDictionaryFeatureProvider
    private var window = VoiceWakeWordWindow()
    private var audio = [Float](repeating: 0, count: VoiceWakeWordFeatures.windowSamples)
    private var expectedOffset: Int64 = 0

    init(url: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: configuration)
        threshold = try Self.detectionThreshold(
            metadata: model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        )
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
        if chunk.offset != expectedOffset {
            window = VoiceWakeWordWindow()
            features.reset()
        }
        expectedOffset = chunk.offset + Int64(chunk.samples.count)
        var detected = false
        for sample in chunk.samples {
            let shouldScore = window.append(sample)
            guard shouldScore, !detected else { continue }
            try Task.checkCancellation()
            window.copySamples(into: &audio)
            if try probability(audio: audio, windowEnd: window.sampleCount) >= threshold { detected = true }
        }
        return detected
    }

    static func detectionThreshold(metadata: [String: String]) throws -> Float {
        guard let value = metadata["default_threshold"],
              let threshold = Float(value), threshold.isFinite, (0...1).contains(threshold)
        else {
            throw VoiceWakeWordModelError.invalidModel("The Hey Nativ model has a missing or invalid detection threshold.")
        }
        return threshold
    }

    func probability(audio: [Float], windowEnd: Int64? = nil) throws -> Float {
        try features.compute(
            audio, windowEnd: windowEnd,
            into: input.dataPointer.assumingMemoryBound(to: Float.self),
            melStride: input.strides[1].intValue, frameStride: input.strides[2].intValue
        )
        let result = try model.prediction(from: provider)
        guard let score = result.featureValue(for: "probability")?.multiArrayValue?[0].floatValue,
              score.isFinite, (0...1).contains(score)
        else { throw VoiceWakeWordModelError.invalidModel("The Hey Nativ model returned an invalid score.") }
        return score
    }
}
