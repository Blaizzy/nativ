import Foundation

struct ParakeetTranscript: Codable, Sendable {
    struct Token: Codable, Equatable, Sendable {
        let id: Int
        let text: String
        let start: Double
        let duration: Double
        var end: Double { start + duration }
    }
    let text: String
    let tokens: [Token]
}

/// Greedy TDT state machine, independent of CoreAI so its blank/state rules are testable.
struct ParakeetDecoder {
    struct Step: Sendable {
        let tokenLogits: [Float]
        let durationLogits: [Float]
        let hidden: [Float]
        let cell: [Float]
    }

    static func decode(
        validFrames: Int,
        metadata: ParakeetConfiguration.Metadata,
        vocabulary: [String],
        step: (Int, Int, [Float], [Float]) async throws -> Step
    ) async throws -> ParakeetTranscript {
        guard validFrames > 0, vocabulary.count == metadata.blankId else { throw ParakeetError.invalidBundle }
        let stateCount = metadata.decoderLayers * metadata.decoderHidden
        var hidden = [Float](repeating: 0, count: stateCount)
        var cell = hidden
        var previous = metadata.blankId
        var frame = 0
        var tokens = [ParakeetTranscript.Token]()
        for _ in 0..<(metadata.maxSymbols * validFrames) {
            try Task.checkCancellation()
            if frame >= validFrames { break }
            let output = try await step(frame, previous, hidden, cell)
            guard output.hidden.count == stateCount, output.cell.count == stateCount,
                  output.hidden.allSatisfy(\.isFinite), output.cell.allSatisfy(\.isFinite) else {
                throw ParakeetError.invalidOutput("decoder state")
            }
            let token = try argmax(output.tokenLogits, count: metadata.blankId + 1)
            var duration = metadata.durations[try argmax(output.durationLogits, count: metadata.durations.count)]
            if token == metadata.blankId {
                duration = max(duration, 1)
            } else {
                previous = token
                hidden = output.hidden
                cell = output.cell
                let piece = vocabulary[token]
                let special = (piece.hasPrefix("<|") && piece.hasSuffix("|>")) || piece == "<unk>" || piece == "<pad>"
                if !special {
                    tokens.append(.init(
                        id: token, text: piece.replacingOccurrences(of: "▁", with: " "),
                        start: Double(frame) * metadata.frameSeconds,
                        duration: Double(duration) * metadata.frameSeconds
                    ))
                }
            }
            frame += duration
        }
        try Task.checkCancellation()
        // Never save or insert a silently truncated transcript.
        guard frame >= validFrames else { throw ParakeetError.decodingIncomplete }
        return ParakeetTranscript(text: tokens.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines), tokens: tokens)
    }

    private static func argmax(_ values: [Float], count: Int) throws -> Int {
        guard values.count == count, !values.isEmpty, values.allSatisfy(\.isFinite) else {
            throw ParakeetError.invalidOutput("decoder logits")
        }
        var best = 0
        for index in 1..<values.count where values[index] > values[best] { best = index }
        return best
    }

    static func positionalEmbeddings(totalFrames: Int, metadata: ParakeetConfiguration.Metadata) -> [Float] {
        let count = (totalFrames + metadata.subsamplingFactor - 1) / metadata.subsamplingFactor
        let dim = metadata.encoderDim
        let scale = Float(-log(10000.0) / Double(dim))
        let rates = stride(from: 0, to: dim, by: 2).map { exp(Float($0) * scale) }
        var values = [Float](repeating: 0, count: (2 * count - 1) * dim)
        for index in 0..<(2 * count - 1) {
            let position = Float(count - 1 - index)
            for pair in rates.indices {
                let angle = position * rates[pair]
                values[index * dim + pair * 2] = sin(angle)
                values[index * dim + pair * 2 + 1] = cos(angle)
            }
        }
        return values
    }
}
