import Foundation

struct AudioDiarization: Codable, Equatable, Sendable {
    struct Segment: Codable, Equatable, Sendable {
        let start: Double
        let end: Double
        let speaker: Int
    }

    let modelID: String
    let revision: String?
    let segments: [Segment]
    var speakerTranscript: String?
    var transcriptSegments: [TranscriptSegment]? = nil
    var speakerNames: [String: String]? = nil
    var speakerProfileIDs: [String: String]? = nil
    var speakerSuggestions: [String: AudioSpeakerSuggestion]? = nil
    var dismissedSpeakerSuggestions: [String: [String]]? = nil

    struct TranscriptSegment: Codable, Equatable, Sendable {
        let start: Double
        let end: Double
        let speakers: [Int]
        let text: String
    }

    var speakerIDs: [Int] { Set(segments.map(\.speaker)).sorted() }

    func hasSameSegmentation(as other: Self) -> Bool {
        modelID == other.modelID && revision == other.revision && segments == other.segments
    }

    /// Update identity metadata while retaining recovered timings from older recordings.
    mutating func setProfile(_ profile: AudioSpeakerProfile?, for speakerID: Int) {
        let slot = String(speakerID)
        var links = speakerProfileIDs ?? [:], names = speakerNames ?? [:]
        links[slot] = profile?.id
        names[slot] = profile?.name
        speakerProfileIDs = links.isEmpty ? nil : links
        speakerNames = names.isEmpty ? nil : names
        speakerSuggestions?[slot] = nil
        if transcriptSegments == nil, !resolvedTranscriptSegments.isEmpty {
            transcriptSegments = resolvedTranscriptSegments
        }
    }

    /// Backward-compatible presentation for recordings linked before core merging.
    var groupedByProfile: Self {
        var firstSpeaker: [String: Int] = [:]
        var representatives: [Int: Int] = [:]
        for speaker in speakerIDs {
            guard let profileID = speakerProfileIDs?[String(speaker)] else { continue }
            let representative = firstSpeaker[profileID] ?? speaker
            firstSpeaker[profileID] = representative
            representatives[speaker] = representative
        }
        guard representatives.contains(where: { $0.key != $0.value }) else { return self }
        var result = Self(modelID: modelID, revision: revision, segments: segments.map {
            Segment(start: $0.start, end: $0.end, speaker: representatives[$0.speaker] ?? $0.speaker)
        }, speakerTranscript: speakerTranscript, speakerNames: speakerNames,
           speakerProfileIDs: speakerProfileIDs, speakerSuggestions: speakerSuggestions,
           dismissedSpeakerSuggestions: dismissedSpeakerSuggestions)
        let turns = resolvedTranscriptSegments
        if transcriptSegments != nil || !turns.isEmpty {
            result.transcriptSegments = turns.map {
                TranscriptSegment(start: $0.start, end: $0.end,
                    speakers: Array(Set($0.speakers.map { representatives[$0] ?? $0 })).sorted(), text: $0.text)
            }
        }
        return result
    }

    /// Reassign stored speech and transcript turns without changing their text,
    /// timing or order. The existing participant keeps its recording-wide ID.
    func mergingSpeakers(_ sources: Set<Int>, into target: Int) throws -> Self {
        let removed = sources.subtracting([target])
        guard !removed.isEmpty else { return self }
        guard speakerIDs.contains(target), removed.isSubset(of: Set(speakerIDs)) else {
            throw AudioSpeakerProfileError.missingSpeaker
        }
        let turns = resolvedTranscriptSegments
        // A legacy transcript that cannot be parsed must not silently retain
        // obsolete speaker IDs or lose its text during a merge.
        guard speakerTranscript?.isEmpty != false || !turns.isEmpty else {
            throw AudioSpeakerProfileError.invalidTranscriptForMerge
        }
        var result = Self(modelID: modelID, revision: revision, segments: segments.map {
            Segment(start: $0.start, end: $0.end, speaker: removed.contains($0.speaker) ? target : $0.speaker)
        }, speakerTranscript: speakerTranscript, transcriptSegments: transcriptSegments,
           speakerNames: speakerNames, speakerProfileIDs: speakerProfileIDs,
           speakerSuggestions: speakerSuggestions, dismissedSpeakerSuggestions: dismissedSpeakerSuggestions)
        if transcriptSegments != nil || !turns.isEmpty {
            result.transcriptSegments = turns.map {
                TranscriptSegment(start: $0.start, end: $0.end,
                    speakers: Array(Set($0.speakers.map { removed.contains($0) ? target : $0 })).sorted(), text: $0.text)
            }
            result.speakerTranscript = result.transcriptSegments?.map {
                Chunk(start: $0.start, end: $0.end, speakers: $0.speakers).labeled($0.text)
            }.joined(separator: "\n\n")
        }
        for source in removed {
            let key = String(source)
            result.speakerNames?[key] = nil
            result.speakerProfileIDs?[key] = nil
            result.speakerSuggestions?[key] = nil
            result.dismissedSpeakerSuggestions?[key] = nil
        }
        return result
    }

    /// Timing alone is not a processed meeting. Older completed runs saved
    /// labeled text; current runs explicitly save their transcript segments.
    var hasCompletedTranscription: Bool {
        transcriptSegments?.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true
            || speakerTranscript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func speakerName(_ id: Int) -> String {
        let name = speakerNames?[String(id)]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Speaker \(id + 1)" : name
    }

    var formattedTranscript: String? {
        let turns = groupedByProfile.resolvedTranscriptSegments
        guard !turns.isEmpty else { return speakerTranscript }
        return turns.map { turn in
            let label = turn.speakers.isEmpty ? "Unassigned speaker" : turn.speakers.map(speakerName).joined(separator: " + ")
            return "[\(Self.timestamp(turn.start))] \(label): \(turn.text)"
        }.joined(separator: "\n\n")
    }

    static func timestamp(_ time: Double) -> String {
        let seconds = Int(max(0, time.isFinite ? time : 0))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// Older recordings stored labeled text. Recover their original chunk times
    /// in order, including overlaps and chunks omitted because ASR returned no text.
    var resolvedTranscriptSegments: [TranscriptSegment] {
        if let transcriptSegments { return transcriptSegments }
        guard let speakerTranscript,
              let pattern = try? NSRegularExpression(pattern: #"^\[(\d+):(\d{2})\] (Speaker \d+(?: \+ Speaker \d+)*): ([\s\S]*)$"#)
        else { return [] }
        let chunks = (try? transcriptionChunks()) ?? []
        var cursor = 0
        var result: [TranscriptSegment] = []
        for paragraph in speakerTranscript.components(separatedBy: "\n\n") {
            let value = paragraph as NSString
            guard let match = pattern.firstMatch(in: paragraph, range: NSRange(location: 0, length: value.length)),
                  let minutes = Double(value.substring(with: match.range(at: 1))),
                  let seconds = Double(value.substring(with: match.range(at: 2))) else { continue }
            let start = minutes * 60 + seconds
            let speakers = value.substring(with: match.range(at: 3)).components(separatedBy: " + ")
                .compactMap { Int($0.replacingOccurrences(of: "Speaker ", with: "")) }.map { $0 - 1 }
            guard let index = chunks.indices.dropFirst(cursor).first(where: {
                Int(chunks[$0].start) == Int(start) && chunks[$0].speakers == speakers
            }) else { continue }
            let chunk = chunks[index]
            result.append(TranscriptSegment(start: chunk.start, end: chunk.end, speakers: speakers,
                                            text: value.substring(with: match.range(at: 4))))
            cursor = index + 1
        }
        // Do not silently drop any saved text if a legacy format cannot be matched.
        let paragraphs = speakerTranscript.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        return result.count == paragraphs.count ? result : []
    }

    func validate() throws {
        guard !modelID.isEmpty, revision?.isEmpty != true,
              segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0
                  && $0.end > $0.start && (0..<8).contains($0.speaker) }) else {
            throw MeetingDiarizationError.invalidOutput
        }
    }

    struct Chunk: Equatable, Sendable {
        let start: Double
        var end: Double
        let speakers: [Int]

        func labeled(_ text: String) -> String {
            let label = speakers.map { "Speaker \($0 + 1)" }.joined(separator: " + ")
            let seconds = Int(start)
            return String(format: "[%02d:%02d] %@: %@", seconds / 60, seconds % 60, label, text)
        }
    }

    /// Partition speech once, preserving recording-wide IDs and absolute times.
    /// Overlap is transcribed once with all active speakers; silence is omitted.
    func transcriptionChunks(maximumDuration: Double = 30) throws -> [Chunk] {
        try validate()
        guard maximumDuration.isFinite, maximumDuration > 0 else {
            throw MeetingDiarizationError.invalidOutput
        }
        var events: [Double: [(speaker: Int, delta: Int)]] = [:]
        for segment in segments {
            // All cuts share the PCM sample grid. Floating-point offsets at
            // streaming boundaries must not create sub-sample overlap chunks.
            let rate = Double(ParakeetAudio.sampleRate)
            let start = (segment.start * rate).rounded() / rate
            let end = (segment.end * rate).rounded() / rate
            guard end > start else { continue }
            events[start, default: []].append((segment.speaker, 1))
            events[end, default: []].append((segment.speaker, -1))
        }
        var active: [Int: Int] = [:]
        var previous: Double?
        var turns: [Chunk] = []
        for time in events.keys.sorted() {
            let speakers = active.keys.sorted()
            if let start = previous, time > start, !speakers.isEmpty {
                if let last = turns.last, last.end == start, last.speakers == speakers {
                    turns[turns.count - 1].end = time
                } else {
                    turns.append(Chunk(start: start, end: time, speakers: speakers))
                }
            }
            for event in events[time]! {
                let count = active[event.speaker, default: 0] + event.delta
                active[event.speaker] = count == 0 ? nil : count
            }
            previous = time
        }
        return turns.flatMap { turn in
            var chunks: [Chunk] = []
            var start = turn.start
            while start < turn.end {
                let end = min(turn.end, start + maximumDuration)
                chunks.append(Chunk(start: start, end: end, speakers: turn.speakers))
                start = end
            }
            return chunks
        }
    }
}

enum MeetingDiarizationError: LocalizedError {
    case invalidOutput

    var errorDescription: String? { "Speaker detection returned invalid timings." }
}
