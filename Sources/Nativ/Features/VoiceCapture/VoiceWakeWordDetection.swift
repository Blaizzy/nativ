import Foundation

enum VoiceWakeWordTranscript {
    /// Drop the pre-roll and wake phrase before parsing spoken dictation commands.
    static func dictation(from text: String) -> String? {
        guard let range = text.range(
            of: #"(?<!\w)hey[\W_]+(?:native|nativ)(?!\w)"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let suffix = text[range.upperBound...].drop(while: { $0.isWhitespace || ",.!?:;".contains($0) })
        return String(suffix).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct VoiceWakeWordTranscription: Sendable {
    let text: String
    let modelID: String
}

struct VoiceWakeWordAudio: Sendable {
    static let sampleRate = 16_000
    let samples: [Float]
    var duration: TimeInterval { Double(samples.count) / Double(Self.sampleRate) }

    /// Mono PCM16 WAV, accepted by the normal transcription endpoint.
    var wavData: Data {
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        word(UInt32(36 + samples.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(Self.sampleRate)); word(UInt32(Self.sampleRate * 2))
        word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8)
        word(UInt32(samples.count * 2))
        for sample in samples {
            word(Int16((max(-1, min(1, sample.isFinite ? sample : 0)) * 32_767).rounded()))
        }
        return data
    }
}

/// Audio-clock state machine, owned by the inference actor. Ambient history is bounded;
/// candidate audio stays in memory while the asynchronous ASR request is in flight.
struct VoiceWakeWordCapture {
    enum Failure: LocalizedError {
        case discontinuity, confirmationTimeout
        var errorDescription: String? {
            switch self {
            case .discontinuity: "Wake-word audio was interrupted. Retrying…"
            case .confirmationTimeout: "Wake-word confirmation timed out. Check the speech model and server."
            }
        }
    }

    struct Result: Sendable {
        let audio: VoiceWakeWordAudio
        let confirmation: VoiceWakeWordTranscription
        let canReuseConfirmation: Bool
    }

    enum Event: Sendable {
        case candidate
        case confirm(UUID, VoiceWakeWordAudio)
        case finished(Result)
    }

    private struct Candidate {
        let id = UUID()
        let trigger: Int64
        var samples: [Float]
        var lastSpeech: Int64
        var confirmationEnd: Int64?
        var confirmation: VoiceWakeWordTranscription?
    }

    private var history = [Float](repeating: 0, count: 80_000)
    private var historyIndex = 0
    private var historyCount = 0
    private var end: Int64?
    private var cooldownUntil: Int64 = 0
    private var candidate: Candidate?
    private var completed = false
    private(set) var level: Float = 0

    var isConfirmed: Bool { candidate?.confirmation != nil }
    var canDetect: Bool { !completed && candidate == nil && (end ?? 0) >= cooldownUntil }
    var elapsed: TimeInterval { candidate.map { Double((end ?? 0) - $0.trigger) / 16_000 } ?? 0 }

    mutating func append(_ chunk: VoiceWakeWordAudioChunk, detected: Bool) throws -> Event? {
        if let end, end != chunk.offset { throw Failure.discontinuity }
        end = chunk.offset + Int64(chunk.samples.count)
        guard !completed else { return nil }
        let energy = chunk.samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = sqrt(energy / Double(max(1, chunk.samples.count)))
        level = min(1, Float(rms) * 8)
        for sample in chunk.samples {
            history[historyIndex] = sample
            historyIndex = (historyIndex + 1) % history.count
            historyCount = min(historyCount + 1, history.count)
        }
        let current = end!
        if candidate != nil {
            // Include pre-roll plus at most two minutes after the trigger.
            let remaining = 36_000 + 120 * 16_000 - candidate!.samples.count
            candidate!.samples.append(contentsOf: chunk.samples.prefix(max(0, remaining)))
            if rms >= sqrt(1e-5) { candidate!.lastSpeech = current }
            if candidate!.confirmationEnd == nil, current - candidate!.trigger >= 9_600 {
                candidate!.confirmationEnd = current
                return .confirm(candidate!.id, VoiceWakeWordAudio(samples: candidate!.samples))
            }
            if candidate!.confirmation != nil {
                if current - candidate!.lastSpeech >= 32_000 || current - candidate!.trigger >= 120 * 16_000 {
                    return finish().map(Event.finished)
                }
            } else if current - candidate!.trigger >= 30 * 16_000 {
                throw Failure.confirmationTimeout
            }
        } else if detected, current >= cooldownUntil {
            let count = min(historyCount, 36_000)
            let start = (historyIndex - count + history.count) % history.count
            let audio = (0..<count).map { history[(start + $0) % history.count] }
            candidate = Candidate(trigger: current, samples: audio, lastSpeech: current)
            return .candidate
        }
        return nil
    }

    /// Nil means the request belongs to a capture that has already been cancelled.
    mutating func resolve(id: UUID, transcription: VoiceWakeWordTranscription) -> Bool? {
        guard candidate?.id == id else { return nil }
        guard VoiceWakeWordTranscript.dictation(from: transcription.text) != nil else {
            candidate = nil
            cooldownUntil = (end ?? 0) + 32_000
            return false
        }
        candidate!.confirmation = transcription
        return true
    }

    mutating func finish() -> Result? {
        guard let candidate, let confirmation = candidate.confirmation else { return nil }
        completed = true
        self.candidate = nil
        return Result(
            audio: VoiceWakeWordAudio(samples: candidate.samples),
            confirmation: confirmation,
            canReuseConfirmation: candidate.lastSpeech <= (candidate.confirmationEnd ?? 0)
        )
    }
}
