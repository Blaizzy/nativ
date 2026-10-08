import Foundation

enum ParakeetError: LocalizedError {
    case invalidBundle
    case invalidAudio
    case tooShort
    case invalidOutput(String)
    case decodingIncomplete
    case modelDownloadFailed(Int)
    case invalidModelArchive

    var errorDescription: String? {
        switch self {
        case .invalidBundle: "The Parakeet speech model is missing or incompatible. Try downloading it again."
        case .modelDownloadFailed(let status): "The Parakeet model download failed (HTTP \(status)). Try again later."
        case .invalidModelArchive: "The downloaded Parakeet model archive is invalid. Try again."
        case .invalidAudio: "The recording could not be read as finite PCM audio."
        case .tooShort: "The recording is too short to transcribe."
        case .invalidOutput(let name): "Parakeet returned invalid \(name)."
        case .decodingIncomplete: "Parakeet could not finish decoding this recording. Try a shorter recording."
        }
    }
}

/// Runtime contract distributed alongside the combined encoder/decoder asset.
struct ParakeetConfiguration: Decodable, Sendable {
    struct Processor: Decodable, Sendable {
        let sampleRate: Int
        let normalize: String
        let windowSize: Double
        let windowStride: Double
        let window: String
        let features: Int
        let nFft: Int
        let dither: Double
        let padTo: Int
        let padValue: Float
        let preemph: Float
        let logZeroGuardValue: Float
        let normalizeValidFrames: Bool
    }
    struct Metadata: Decodable, Sendable {
        let melBins: Int
        let encoderDim: Int
        let encoderFrames: Int
        let encoderDtype: String
        let subsamplingFactor: Int
        let decoderLayers: Int
        let decoderHidden: Int
        let blankId: Int
        let durations: [Int]
        let maxSymbols: Int
        let processor: Processor
        let frameSeconds: Double
    }
    struct Component: Decodable, Sendable {
        let entrypoint: String
        let outputs: [String: String]
    }
    let formatVersion: Int
    let recipe: String
    let model: String
    let metadata: Metadata
    let components: [String: Component]

    static func load(from directory: URL) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let config = try decoder.decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        try config.validate()
        return config
    }

    func validate() throws {
        let m = metadata
        let p = m.processor
        // This frontend implements the exported Redux contract, not arbitrary NeMo processors.
        guard formatVersion == 1, recipe == "parakeet_redux", model == "model.aimodel",
              m.melBins == 128, m.encoderDim == 1024, m.subsamplingFactor == 8,
              m.encoderFrames == ParakeetChunkPlan.tensorFrames, m.encoderDtype == "fp16",
              m.decoderLayers == 2, m.decoderHidden == 640, m.blankId == 8192,
              m.durations == [0, 1, 2, 3, 4], m.maxSymbols == 10, m.frameSeconds == 0.08,
              p.sampleRate == 16000, p.normalize == "per_feature", p.window == "hann",
              p.windowSize == 0.025, p.windowStride == 0.01, p.features == 128, p.nFft == 512,
              p.dither == 0, p.padTo == 0, p.padValue == 0, p.preemph == 0.97,
              p.logZeroGuardValue == Float(0x1p-24), p.normalizeValidFrames,
              let encoder = components["encoder"], !encoder.entrypoint.isEmpty,
              let decoder = components["decoder_step"], !decoder.entrypoint.isEmpty,
              ["features", "lengths"].allSatisfy({ encoder.outputs[$0]?.isEmpty == false }),
              ["token_logits", "duration_logits", "hidden", "cell"].allSatisfy({ decoder.outputs[$0]?.isEmpty == false })
        else { throw ParakeetError.invalidBundle }
    }
}
