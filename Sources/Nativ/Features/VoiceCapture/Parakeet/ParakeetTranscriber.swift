import Foundation
#if canImport(CoreAI)
import CoreAI
#endif

/// Default model selection is independent of server availability and model-directory scans.
enum DefaultSpeechModel {
    static let identifier = "parakeet-redux-coreai"
    static var isSupported: Bool {
        #if canImport(CoreAI)
        if #available(macOS 27.0, *) { return true }
        #endif
        return false
    }
    static func isPreferred(selectedModelID: String?) -> Bool {
        isSupported && (selectedModelID == nil || selectedModelID == identifier)
    }
}

#if canImport(CoreAI)
@available(macOS 27.0, *)
actor ParakeetTranscriber {
    static let shared = ParakeetTranscriber()
    private let directory: URL?
    private var session: Session?
    private var isPrepared = false
    // Actors are reentrant at CoreAI awaits. Explicitly serialize whole utterances.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// An explicit directory is useful for local model validation and benchmarks.
    /// Normal app use resolves/downloads the model through the cache store.
    init(directory: URL? = nil) {
        self.directory = directory
    }

    /// Run the encoder and decoder once to prepare their execution resources,
    /// and retain this session for subsequent utterances.
    func prepare() async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard !isPrepared else { return }
        try await loadSessionIfNeeded()
        try await session!.warmUp()
        try Task.checkCancellation()
        isPrepared = true
    }

    func transcribe(contentsOf url: URL) async throws -> ParakeetTranscript {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let samples = try ParakeetAudio.read(contentsOf: url)
        let mel = try ParakeetAudio.preprocess(samples)
        try await loadSessionIfNeeded()
        try Task.checkCancellation()
        let result = try await session!.transcribe(mel)
        isPrepared = true
        return result
    }

    private func loadSessionIfNeeded() async throws {
        if session == nil {
            let directory: URL
            if let override = self.directory { directory = override }
            else { directory = try await ParakeetModelStore.shared.directory() }
            session = try await Session.load(directory: directory)
        }
    }

    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }
    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }

    private struct Session {
        let model: AIModel
        let encoder: InferenceFunction
        let decoder: InferenceFunction
        let config: ParakeetConfiguration
        let vocabulary: [String]
        let positions: NDArray
        let positionalEmbeddings: NDArray

        static func load(directory: URL) async throws -> Self {
            let config = try ParakeetConfiguration.load(from: directory)
            let vocabulary = try JSONDecoder().decode([String].self, from: Data(contentsOf: directory.appendingPathComponent("vocabulary.json")))
            guard vocabulary.count == config.metadata.blankId else { throw ParakeetError.invalidBundle }
            let model = try await ParakeetModelLoader.load(from: directory, sourceName: config.model)
            guard let encoder = try model.loadFunction(named: config.components["encoder"]!.entrypoint),
                  let decoder = try model.loadFunction(named: config.components["decoder_step"]!.entrypoint) else {
                throw ParakeetError.invalidBundle
            }
            let frames = ParakeetChunkPlan.tensorFrames
            let count = (frames + config.metadata.subsamplingFactor - 1) / config.metadata.subsamplingFactor
            return Self(
                model: model, encoder: encoder, decoder: decoder, config: config, vocabulary: vocabulary,
                positions: NDArray(scalars: (0..<frames).map(Float16.init), shape: [1, frames]),
                positionalEmbeddings: NDArray(
                    scalars: ParakeetDecoder.positionalEmbeddings(totalFrames: frames, metadata: config.metadata).map(Float16.init),
                    shape: [1, 2 * count - 1, config.metadata.encoderDim]
                )
            )
        }

        func warmUp() async throws {
            let encodeStart = DispatchTime.now().uptimeNanoseconds
            let m = config.metadata
            _ = try await encode(
                [Float](repeating: 0, count: ParakeetChunkPlan.tensorFrames * m.melBins),
                validFrames: ParakeetChunkPlan.windowFrames
            )
            NSLog("Nativ Parakeet first encoder call: %.6f seconds", Double(DispatchTime.now().uptimeNanoseconds - encodeStart) / 1e9)
            try Task.checkCancellation()
            let state = [Float](repeating: 0, count: m.decoderLayers * m.decoderHidden)
            _ = try await decodeStep(
                feature: [Float](repeating: 0, count: m.encoderDim),
                previous: m.blankId, hidden: state, cell: state
            )
        }

        func transcribe(_ mel: ParakeetMel) async throws -> ParakeetTranscript {
            let m = config.metadata
            let valid = (mel.validFrames + m.subsamplingFactor - 1) / m.subsamplingFactor
            var features = [Float]()
            features.reserveCapacity(valid * m.encoderDim)
            // Preprocessing/normalization happens once over the whole recording. Only
            // the encoder is windowed. Overlapping context is discarded before a single
            // continuous TDT decode, preserving decoder state and global timestamps.
            for window in try ParakeetChunkPlan.windows(validFrames: mel.validFrames) {
                try Task.checkCancellation()
                let encoded = try await encode(
                    ParakeetChunkPlan.paddedFeatures(mel, window: window), validFrames: window.validFrames
                )
                let first = window.keptEncodedFrames.lowerBound * m.encoderDim
                let last = window.keptEncodedFrames.upperBound * m.encoderDim
                features.append(contentsOf: encoded[first..<last])
            }
            guard features.count == valid * m.encoderDim else { throw ParakeetError.invalidOutput("chunk lengths") }
            return try await ParakeetDecoder.decode(validFrames: valid, metadata: m, vocabulary: vocabulary) { frame, previous, hidden, cell in
                let start = frame * m.encoderDim
                return try await decodeStep(
                    feature: Array(features[start..<(start + m.encoderDim)]),
                    previous: previous, hidden: hidden, cell: cell
                )
            }
        }

        private func encode(_ features: [Float], validFrames: Int) async throws -> [Float] {
            let m = config.metadata
            let frames = ParakeetChunkPlan.tensorFrames
            let count = (frames + m.subsamplingFactor - 1) / m.subsamplingFactor
            var encoded = try await encoder.run(inputs: [
                "mel": NDArray(scalars: features.map(Float16.init), shape: [1, frames, m.melBins]),
                "lengths": NDArray(scalars: ParakeetChunkPlan.subsampledLengths(validFrames: validFrames), shape: [1, 3]),
                "pos_emb": positionalEmbeddings,
                "positions": positions,
            ])
            try Task.checkCancellation()
            let names = config.components["encoder"]!.outputs
            let values = try Self.floats(&encoded, name: names["features"]!, shape: [1, count, m.encoderDim], type: .float16)
            let lengths = try Self.take(&encoded, name: names["lengths"]!, shape: [1], type: .float16)
            guard lengths.view(as: Float16.self)[scalarAt: [0]] == Float16((validFrames + m.subsamplingFactor - 1) / m.subsamplingFactor) else {
                throw ParakeetError.invalidOutput("encoder length")
            }
            return values
        }

        private func decodeStep(feature: [Float], previous: Int, hidden: [Float], cell: [Float]) async throws -> ParakeetDecoder.Step {
            let m = config.metadata
            let stateShape = [m.decoderLayers, 1, m.decoderHidden]
            let names = config.components["decoder_step"]!.outputs
            var output = try await decoder.run(inputs: [
                "feature": NDArray(scalars: feature, shape: [1, 1, m.encoderDim]),
                "current_token": NDArray(scalars: [Int32(previous)], shape: [1, 1]),
                "hidden": NDArray(scalars: hidden, shape: stateShape),
                "cell": NDArray(scalars: cell, shape: stateShape),
            ])
            return try ParakeetDecoder.Step(
                tokenLogits: Self.floats(&output, name: names["token_logits"]!, shape: [m.blankId + 1]),
                durationLogits: Self.floats(&output, name: names["duration_logits"]!, shape: [m.durations.count]),
                hidden: Self.floats(&output, name: names["hidden"]!, shape: stateShape),
                cell: Self.floats(&output, name: names["cell"]!, shape: stateShape)
            )
        }

        private static func take(_ outputs: inout InferenceFunction.Outputs, name: String, shape: [Int], type: NDArray.ScalarType) throws -> NDArray {
            guard let value = outputs.remove(name), let array = value.ndArray,
                  array.shape == shape, array.scalarType == type, array.interleaveLayout == nil else {
                throw ParakeetError.invalidOutput(name)
            }
            return array
        }

        private static func floats(_ outputs: inout InferenceFunction.Outputs, name: String, shape: [Int], type: NDArray.ScalarType = .float32) throws -> [Float] {
            let array = try take(&outputs, name: name, shape: shape, type: type)
            // Read strides explicitly: CoreAI does not promise contiguous output storage.
            func read(_ scalar: (Int) -> Float, strides: Span<Int>) -> [Float] {
                (0..<shape.reduce(1, *)).map { flat -> Float in
                    var remainder = flat
                    var offset = 0
                    for dimension in shape.indices.reversed() {
                        offset += (remainder % shape[dimension]) * strides[dimension]
                        remainder /= shape[dimension]
                    }
                    return scalar(offset)
                }
            }
            let values: [Float]
            if type == .float16 {
                // The decoder and host decoding state remain FP32.
                values = array.view(as: Float16.self).withUnsafePointer { pointer, _, strides in
                    read({ Float(pointer[$0]) }, strides: strides)
                }
            } else {
                values = array.view(as: Float.self).withUnsafePointer { pointer, _, strides in
                    read({ pointer[$0] }, strides: strides)
                }
            }
            guard values.allSatisfy(\.isFinite) else { throw ParakeetError.invalidOutput(name) }
            return values
        }
    }
}
#else
/// Keeps the shared API available to older-SDK builds. Model selection routes
/// those builds to server STT, including when they run on macOS 27 or later.
@available(macOS 27.0, *)
actor ParakeetTranscriber {
    static let shared = ParakeetTranscriber()

    init(directory: URL? = nil) {}

    func prepare() async throws {
        throw ParakeetError.runtimeUnavailable
    }

    func transcribe(contentsOf url: URL) async throws -> ParakeetTranscript {
        throw ParakeetError.runtimeUnavailable
    }
}
#endif
