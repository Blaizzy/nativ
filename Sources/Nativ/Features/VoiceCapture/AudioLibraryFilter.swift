import Foundation

/// Shared by the Library and the explicit speaker-processing recording picker.
struct AudioLibraryFilter: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case recordings, meetings, voiceNotes, dictations, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .recordings: "Recordings"
            case .meetings: "Meetings"
            case .voiceNotes: "Voice notes"
            case .dictations: "Dictations"
            case .all: "All audio"
            }
        }
    }
    enum Period: String, CaseIterable, Identifiable {
        case all, week, month, year
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All dates"
            case .week: "Last 7 days"
            case .month: "Last 30 days"
            case .year: "Last year"
            }
        }
        var days: Int? {
            switch self { case .all: nil; case .week: 7; case .month: 30; case .year: 365 }
        }
    }
    enum Status: String, CaseIterable, Identifiable {
        case all, needsProcessing, needsTranscript, needsSpeakers, summarized
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "Any status"
            case .needsProcessing: "Needs processing"
            case .needsTranscript: "Needs transcription"
            case .needsSpeakers: "Needs speaker matching"
            case .summarized: "Has summary"
            }
        }
    }
    static let unlinkedSpeakerID = "__unlinked_speakers__"
    var query = ""
    var kind: Kind = .recordings
    var period: Period = .all
    var status: Status = .all
    var speakerID = ""

    func records(in records: [AudioTranscriptionRecord], profiles: [AudioSpeakerProfile],
                 now: Date = Date(), calendar: Calendar = .current) -> [AudioTranscriptionRecord] {
        let names = Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let since = period.days.flatMap { calendar.date(byAdding: .day, value: -$0, to: now) }
        return records.filter { record in
            switch kind {
            case .recordings: if record.resolvedKind == .dictation { return false }
            case .meetings: if record.resolvedKind != .meeting { return false }
            case .voiceNotes: if record.resolvedKind != .voiceNote { return false }
            case .dictations: if record.resolvedKind != .dictation { return false }
            case .all: break
            }
            if let since, record.recordedAt < since { return false }
            let diarization = record.diarization
            let unlinked = diarization?.speakerIDs.contains {
                diarization?.speakerProfileIDs?[String($0)] == nil
            } ?? false
            switch status {
            case .all: break
            case .needsProcessing:
                guard record.resolvedKind == .meeting else { return false }
                if diarization?.hasCompletedTranscription == true,
                   diarization?.speakerIDs.contains(where: {
                       guard let profileID = diarization?.speakerProfileIDs?[String($0)] else { return false }
                       return names[profileID] != nil
                   }) == true { return false }
            case .needsTranscript:
                if record.resolvedKind == .meeting {
                    if diarization?.hasCompletedTranscription == true { return false }
                } else if !record.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            case .needsSpeakers:
                if record.resolvedKind != .meeting || (diarization != nil && !unlinked) { return false }
            case .summarized:
                if (record.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            }
            if speakerID == Self.unlinkedSpeakerID {
                if !unlinked { return false }
            } else if !speakerID.isEmpty, diarization?.speakerProfileIDs?.values.contains(speakerID) != true {
                return false
            }
            guard !terms.isEmpty else { return true }
            let linkedNames = (diarization?.speakerProfileIDs ?? [:]).values.compactMap { names[$0] }
            let localNames = Array((diarization?.speakerNames ?? [:]).values)
            let text = ([record.displayTitle, record.transcript, record.summary ?? "", record.applicationName ?? "", record.modelID ?? "",
                         record.recordedAt.formatted(date: .abbreviated, time: .omitted),
                         record.recordedAt.formatted(.iso8601.year().month().day())] + linkedNames + localNames)
                .joined(separator: " ")
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }.sorted { $0.recordedAt == $1.recordedAt ? $0.id < $1.id : $0.recordedAt > $1.recordedAt }
    }
}

struct AudioLibraryPage {
    static let size = 10
    let records: [AudioTranscriptionRecord]
    let index: Int
    let count: Int
    let total: Int
    let first: Int
    let last: Int

    init(records: [AudioTranscriptionRecord], index: Int) {
        total = records.count
        count = max(1, (total + Self.size - 1) / Self.size)
        self.index = min(max(0, index), count - 1)
        let offset = self.index * Self.size
        self.records = Array(records.dropFirst(offset).prefix(Self.size))
        first = total == 0 ? 0 : offset + 1
        last = min(offset + Self.size, total)
    }
}
