import Foundation
import XCTest

final class AudioLibraryFilterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_886_400)

    func testSearchCombinesTermsAcrossTranscriptSummaryAndCurrentSpeakerName() {
        let profile = AudioSpeakerProfile(id: "alex", name: "Álex Rivera", createdAt: now, updatedAt: now)
        let meeting = record("meeting", transcript: "Discuss the launch", summary: "Ship in November",
                             diarization: timing(profileID: profile.id))
        let records = [meeting, record("unrelated", transcript: "Discuss the launch")]
        var filter = AudioLibraryFilter(query: "  ALEX  November launch  ")
        XCTAssertEqual(filter.records(in: records, profiles: [profile]).map(\.id), ["meeting"])
        filter.query = "2026-10-25"
        XCTAssertEqual(filter.records(in: [meeting], profiles: []).map(\.id), ["meeting"])
        filter.query = "not present"
        XCTAssertTrue(filter.records(in: records, profiles: [profile]).isEmpty)
    }

    func testFiltersCombineAndSpeakerIdentitySpansDifferentLocalSpeakerNumbers() {
        let recent = record("recent", summary: "Summary", diarization: timing(profileID: "alex", speaker: 4))
        let otherMeeting = record("other-meeting", daysAgo: 2, summary: "Summary",
                                  diarization: timing(profileID: "alex", speaker: 0))
        let records = [recent, otherMeeting,
                       record("old", daysAgo: 40, summary: "Summary", diarization: timing(profileID: "alex")),
                       record("no-summary", diarization: timing(profileID: "alex")),
                       record("other-person", summary: "Summary", diarization: timing(profileID: "blair")),
                       record("note", kind: .voiceNote, summary: "Summary", diarization: timing(profileID: "alex"))]
        let filter = AudioLibraryFilter(kind: .meetings, period: .month, status: .summarized, speakerID: "alex")
        XCTAssertEqual(filter.records(in: records, profiles: [], now: now).map(\.id), ["recent", "other-meeting"])
    }

    func testUnlinkedSpeakerAndProcessingStatusesReflectActualSpeakerSlots() {
        var partial = AudioDiarization(modelID: "diarization", revision: "1", segments: [
            .init(start: 0, end: 5, speaker: 0), .init(start: 7, end: 12, speaker: 1),
        ], transcriptSegments: [
            .init(start: 0, end: 5, speakers: [0], text: "Hello"),
            .init(start: 7, end: 12, speakers: [1], text: "Another voice"),
        ])
        partial.speakerProfileIDs = ["0": "alex"]
        let records = [record("linked", diarization: timing(profileID: "alex")),
                       record("partial", diarization: partial), record("missing"),
                       record("note", kind: .voiceNote), record("dictation", kind: .dictation, transcript: "Words")]
        let unlinked = AudioLibraryFilter(speakerID: AudioLibraryFilter.unlinkedSpeakerID)
        XCTAssertEqual(unlinked.records(in: records, profiles: []).map(\.id), ["partial"])
        let needsSpeakers = AudioLibraryFilter(status: .needsSpeakers)
        XCTAssertEqual(needsSpeakers.records(in: records, profiles: []).map(\.id), ["missing", "partial"])
        let needsTranscript = AudioLibraryFilter(kind: .all, status: .needsTranscript)
        XCTAssertEqual(needsTranscript.records(in: records, profiles: []).map(\.id), ["missing", "note"])
    }

    func testTypesRetainAccessToDictationsAndVoiceNotes() {
        let records = [record("meeting"), record("note", kind: .voiceNote), record("dictation", kind: .dictation)]
        XCTAssertEqual(AudioLibraryFilter().records(in: records, profiles: []).map(\.id), ["meeting", "note"])
        XCTAssertEqual(AudioLibraryFilter(kind: .dictations).records(in: records, profiles: []).map(\.id), ["dictation"])
        XCTAssertEqual(AudioLibraryFilter(kind: .voiceNotes).records(in: records, profiles: []).map(\.id), ["note"])
        XCTAssertEqual(AudioLibraryFilter(kind: .all).records(in: records, profiles: []).count, 3)
    }

    func testProcessingExcludesLinkedMeetingsButKeepsMissingWorkAndInvalidLinks() {
        let profile = AudioSpeakerProfile(id: "alex", name: "Alex", createdAt: now, updatedAt: now)
        var partial = AudioDiarization(modelID: "diarization", revision: "1", segments: [
            .init(start: 0, end: 5, speaker: 0), .init(start: 7, end: 12, speaker: 1),
        ], transcriptSegments: [.init(start: 0, end: 5, speakers: [0], text: "Hello")])
        partial.speakerProfileIDs = ["0": profile.id]
        var unlinked = timing(profileID: profile.id)
        unlinked.speakerProfileIDs = nil
        var missingTranscript = timing(profileID: profile.id)
        missingTranscript.transcriptSegments = nil
        var obsoleteSlot = timing(profileID: profile.id)
        obsoleteSlot.speakerProfileIDs = ["99": profile.id]
        let records = [
            record("complete", diarization: timing(profileID: profile.id)),
            record("partial", diarization: partial),
            record("unlinked", diarization: unlinked),
            record("missing-diarization"),
            record("missing-transcript", diarization: missingTranscript),
            record("deleted-profile", diarization: timing(profileID: "deleted")),
            record("obsolete-slot", diarization: obsoleteSlot),
            record("note", kind: .voiceNote), record("dictation", kind: .dictation),
        ]
        let filter = AudioLibraryFilter(kind: .meetings, status: .needsProcessing)
        XCTAssertEqual(filter.records(in: records, profiles: [profile]).map(\.id),
                       ["deleted-profile", "missing-diarization", "missing-transcript", "obsolete-slot", "unlinked"])
        XCTAssertEqual(AudioLibraryFilter(kind: .meetings).records(in: records, profiles: [profile]).count, 7,
                       "Any status keeps previously processed meetings available")
        XCTAssertTrue(AudioLibraryFilter(status: .needsSpeakers).records(in: records, profiles: [profile])
            .contains { $0.id == "partial" }, "Unlinked speakers remain available for explicit matching")
    }

    func testFilteringPrecedesTenItemPagingWithNoDuplicatesOrGaps() {
        let records = (0..<46).map { index in
            record(String(format: "%02d", index), daysAgo: Double(index),
                   diarization: timing(profileID: index.isMultiple(of: 2) ? "alex" : "blair"))
        }.reversed()
        let matches = AudioLibraryFilter(speakerID: "alex").records(in: Array(records), profiles: [])
        let pages = (0..<3).map { AudioLibraryPage(records: matches, index: $0) }
        XCTAssertEqual(pages.map { $0.records.count }, [10, 10, 3])
        XCTAssertEqual(pages.map(\.first), [1, 11, 21])
        XCTAssertEqual(pages.map(\.last), [10, 20, 23])
        XCTAssertEqual(pages.flatMap { $0.records.map(\.id) }, (0..<23).map { String(format: "%02d", $0 * 2) })
        XCTAssertTrue(pages.allSatisfy { $0.count == 3 && $0.total == 23 })
    }

    func testPagingClampsAfterFilteringOrDeletionAndHandlesEmptyResults() {
        let reduced = AudioLibraryPage(records: [record("only")], index: 7)
        XCTAssertEqual(reduced.index, 0)
        XCTAssertEqual(reduced.first, 1)
        XCTAssertEqual(reduced.last, 1)
        let empty = AudioLibraryPage(records: [], index: -1)
        XCTAssertEqual(empty.index, 0)
        XCTAssertEqual(empty.count, 1)
        XCTAssertEqual(empty.first, 0)
        XCTAssertEqual(empty.last, 0)
        XCTAssertTrue(empty.records.isEmpty)
    }

    private func record(_ id: String, kind: AudioRecordKind = .meeting, daysAgo: Double = 0,
                        transcript: String = "", summary: String? = nil,
                        diarization: AudioDiarization? = nil) -> AudioTranscriptionRecord {
        AudioTranscriptionRecord(id: id, recordedAt: now.addingTimeInterval(-daysAgo * 86400), updatedAt: now,
            durationSeconds: 20, transcript: transcript, modelID: "speech-model", applicationName: "Nativ",
            kind: kind, title: id, audioFileName: "\(id).wav", summary: summary, diarization: diarization)
    }

    private func timing(profileID: String, speaker: Int = 0) -> AudioDiarization {
        var result = AudioDiarization(modelID: "diarization", revision: "1",
            segments: [.init(start: 0, end: 5, speaker: speaker)],
            transcriptSegments: [.init(start: 0, end: 5, speakers: [speaker], text: "Hello")])
        result.speakerProfileIDs = [String(speaker): profileID]
        return result
    }
}
