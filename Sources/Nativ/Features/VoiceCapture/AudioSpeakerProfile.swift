import CryptoKit
import Foundation

struct AudioSpeakerProfile: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    let createdAt: Date
    var updatedAt: Date
    var voiceMatchingEnabled = false
    var voiceSamples: [AudioSpeakerVoiceSample]? = nil

    var hasCurrentVoiceSample: Bool {
        (voiceSamples ?? []).contains { (try? $0.embedding.validate()) != nil }
    }

    /// Keep a previous opt-in when upgrading encoders; confirmed meeting links
    /// supply fresh samples before any further voice comparison.
    var needsVoiceReenrollment: Bool { voiceMatchingEnabled && !hasCurrentVoiceSample }
}

struct AudioSpeakerVoiceSample: Codable, Equatable, Sendable {
    let recordID: String
    let speakerID: Int
    let embedding: SpeakerVoiceEmbedding
}

struct AudioSpeakerSuggestion: Codable, Equatable, Sendable {
    let profileID: String
    let similarity: Double
    let modelID: String?
    let revision: String?

    init(profileID: String, similarity: Double,
         modelID: String? = SpeakerVoiceEmbeddingExtractor.modelID,
         revision: String? = nil) {
        self.profileID = profileID
        self.similarity = similarity
        self.modelID = modelID
        self.revision = revision
    }

    var usesCurrentVoiceModel: Bool {
        SpeakerVoiceEmbeddingExtractor.supports(modelID: modelID, revision: revision)
            && similarity.isFinite && (-1...1).contains(similarity)
    }
}

enum AudioSpeakerProfileError: LocalizedError {
    case emptyName, missingProfile, missingSpeaker, recordingChanged, noVoiceSample
    case unsupportedStorage, transcriptionRequired, invalidTranscriptForMerge

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a name for the speaker profile."
        case .missingProfile: "This speaker profile is no longer available."
        case .missingSpeaker: "This speaker is no longer available in the recording."
        case .recordingChanged: "The recording changed while its voice was being analyzed. Please try again."
        case .noVoiceSample: "Link this person to a recording with at least three seconds of clear solo speech first."
        case .unsupportedStorage: "The audio library could not be read safely. Your saved library has not been changed."
        case .transcriptionRequired: "Finish diarizing and transcribing this meeting before updating its speaker profiles."
        case .invalidTranscriptForMerge: "This older transcript has no recoverable speaker timings. Regenerate its transcription before merging speakers."
        }
    }
}

enum AudioSpeakerMatcher {
    // Conservative candidate gates, not a calibrated identity probability.
    // Automatic linking uses these gates and leaves ambiguous voices unlinked.
    // Initial ECAPA gates favor abstaining on uncertain voices. They still need
    // calibration across separate meetings and microphones, not just one call.
    static let minimumSimilarity = 0.75
    static let minimumMargin = 0.15

    static func suggestion(
        for embedding: SpeakerVoiceEmbedding,
        profiles: [AudioSpeakerProfile],
        excludingRecordID: String,
        dismissedProfileIDs: Set<String> = []
    ) -> AudioSpeakerSuggestion? {
        guard (try? embedding.validate()) != nil else { return nil }
        let candidates = profiles.filter { $0.voiceMatchingEnabled }.compactMap { profile -> AudioSpeakerSuggestion? in
            let samples = (profile.voiceSamples ?? []).filter {
                $0.recordID != excludingRecordID
                    && (try? $0.embedding.validate()) != nil
            }
            let similarities = samples.compactMap { cosine(embedding.vector, $0.embedding.vector) }
            guard !similarities.isEmpty else { return nil }
            // Require agreement with the profile's confirmed samples, rather
            // than selecting a single unusually high comparison.
            return AudioSpeakerSuggestion(profileID: profile.id,
                similarity: similarities.reduce(0, +) / Double(similarities.count))
        }.sorted { $0.similarity > $1.similarity }
        guard let best = candidates.first,
              best.similarity >= minimumSimilarity,
              !dismissedProfileIDs.contains(best.profileID),
              candidates.count < 2 || best.similarity - candidates[1].similarity >= minimumMargin
        else { return nil }
        return best
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard !lhs.isEmpty, lhs.count == rhs.count,
              lhs.allSatisfy(\.isFinite), rhs.allSatisfy(\.isFinite) else { return nil }
        var dot = 0.0, left = 0.0, right = 0.0
        for (a, b) in zip(lhs, rhs) {
            dot += Double(a) * Double(b)
            left += Double(a) * Double(a)
            right += Double(b) * Double(b)
        }
        guard left > 0, right > 0 else { return nil }
        return max(-1, min(1, dot / sqrt(left * right)))
    }
}

struct AudioSpeakerReviewExcerpt: Equatable, Sendable {
    let start: Double
    let end: Double

    static func best(in diarization: AudioDiarization, speakerID: Int) -> Self? {
        let turns = (try? diarization.transcriptionChunks(maximumDuration: 10)) ?? []
        return best(in: turns.filter { $0.speakers == [speakerID] })
    }

    static func best(in soloTurns: [AudioDiarization.Chunk]) -> Self? {
        soloTurns.filter { $0.end - $0.start >= 0.2 }
            .sorted {
                let left = $0.end - $0.start, right = $1.end - $1.start
                return left == right ? $0.start < $1.start : left > right
            }.first.map { Self(start: $0.start, end: min($0.end, $0.start + 10)) }
    }

    /// Offer several distinct solo turns, rather than adjacent slices of the
    /// same sentence. Each preview stays short and preserves recording time.
    static func samples(in diarization: AudioDiarization, speakerID: Int, limit: Int = 3) -> [Self] {
        guard limit > 0 else { return [] }
        let turns = (try? diarization.transcriptionChunks(maximumDuration: 60)) ?? []
        return turns.filter { $0.speakers == [speakerID] && $0.end - $0.start >= 0.2 }
            .sorted {
                let left = $0.end - $0.start, right = $1.end - $1.start
                return left == right ? $0.start < $1.start : left > right
            }
            .prefix(limit)
            .map { Self(start: $0.start, end: min($0.end, $0.start + 10)) }
            .sorted { $0.start < $1.start }
    }

    static func soloSpeechDuration(in diarization: AudioDiarization, speakerID: Int) -> Double {
        ((try? diarization.transcriptionChunks()) ?? [])
            .filter { $0.speakers == [speakerID] }.reduce(0) { $0 + $1.end - $1.start }
    }

    static func transcriptQuote(in diarization: AudioDiarization, speakerID: Int,
                                excerpt: Self? = nil) -> String? {
        let turns = diarization.resolvedTranscriptSegments.filter {
            $0.speakers == [speakerID] && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return transcriptQuote(in: turns, excerpt: excerpt)
    }

    static func transcriptQuote(in soloTurns: [AudioDiarization.TranscriptSegment], excerpt: Self?) -> String? {
        let turns = soloTurns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let turn: AudioDiarization.TranscriptSegment?
        if let excerpt { turn = turns.first { $0.start < excerpt.end && $0.end > excerpt.start } }
        else { turn = turns.first }
        guard let turn else { return nil }
        return String(turn.text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(240))
    }
}

struct AudioSpeakerReviewItem: Identifiable, Equatable, Sendable {
    enum Reason: String, Equatable, Sendable { case possibleMatch, noMatch, insufficientSpeech }
    let recordID: String
    let speakerID: Int
    let recordingTitle: String
    let recordedAt: Date
    let speakerName: String
    let reason: Reason
    let suggestion: AudioSpeakerSuggestion?
    let suggestedProfileName: String?
    let excerpt: AudioSpeakerReviewExcerpt?
    let transcriptQuote: String?
    let soloSpeechDuration: Double
    let segmentationFingerprint: Data

    var id: String { "\(recordID):speaker:\(speakerID)" }
}

enum AudioSpeakerReviewUndoError: LocalizedError {
    case changed
    var errorDescription: String? {
        "This speaker or voice profile changed after that action. Undo is no longer available."
    }
}

/// Only the edited slot and removed voice samples are retained. Fingerprints
/// protect newer segmentation and voice changes without snapshotting the library.
struct AudioSpeakerReviewUndo: Sendable {
    let recordID: String
    let speakerID: Int
    let linkedProfileID: String
    let segmentationFingerprint: Data
    let before: Slot
    let after: Slot
    let voiceChanges: [VoiceChange]
    let expectedSlotSamples: [SlotSample]
    let createdProfile: AudioSpeakerProfile?
    var merge: Merge? = nil

    /// A merge changes segmentation, so retain this recording's before/after
    /// state and only affected voice data. Never snapshot the whole library.
    struct Merge: Sendable {
        let before: AudioDiarization
        let after: AudioDiarization
        let voices: [MergedVoice]
    }

    struct MergedVoice: Sendable {
        let profileID: String
        let beforeSamples: [AudioSpeakerVoiceSample]?
        let wasEnabled: Bool
        let expectedFingerprint: Data
    }

    struct Slot: Equatable, Sendable {
        let profileID: String?
        let name: String?
        let suggestion: AudioSpeakerSuggestion?
        let dismissed: [String]?

        init(_ diarization: AudioDiarization, speakerID: Int) {
            let slot = String(speakerID)
            profileID = diarization.speakerProfileIDs?[slot]
            name = diarization.speakerNames?[slot]
            suggestion = diarization.speakerSuggestions?[slot]
            dismissed = diarization.dismissedSpeakerSuggestions?[slot]
        }
    }

    struct VoiceChange: Sendable {
        let profileID: String
        let removedSamples: [AudioSpeakerVoiceSample]
        let wasEnabled: Bool
        let expectedFingerprint: Data
    }

    struct SlotSample: Equatable, Sendable {
        let profileID: String
        let sample: AudioSpeakerVoiceSample
    }

    static func segmentationFingerprint(_ diarization: AudioDiarization) throws -> Data {
        struct Segmentation: Encodable {
            let modelID: String
            let revision: String?
            let segments: [AudioDiarization.Segment]
        }
        return try fingerprint(Segmentation(modelID: diarization.modelID, revision: diarization.revision,
                                            segments: diarization.segments))
    }

    static func voiceFingerprint(_ profile: AudioSpeakerProfile) throws -> Data {
        struct Voice: Encodable {
            let enabled: Bool
            let samples: [AudioSpeakerVoiceSample]?
        }
        return try fingerprint(Voice(enabled: profile.voiceMatchingEnabled, samples: profile.voiceSamples))
    }

    static func slotSamples(_ profiles: [AudioSpeakerProfile], recordID: String, speakerID: Int) -> [SlotSample] {
        profiles.sorted { $0.id < $1.id }.flatMap { profile in
            (profile.voiceSamples ?? []).filter { $0.recordID == recordID && $0.speakerID == speakerID }
                .map { SlotSample(profileID: profile.id, sample: $0) }
        }
    }

    private static func fingerprint(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(value)))
    }
}
