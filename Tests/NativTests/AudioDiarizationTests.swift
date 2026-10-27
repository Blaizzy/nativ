import Foundation
import XCTest
@testable import NativServerKit

@MainActor
final class AudioDiarizationTests: XCTestCase {
    func testLinkedVoicesBecomeOneParticipantWithoutChangingWordsOrTiming() throws {
        let original = AudioDiarization(modelID: "model", revision: "test", segments: [
            .init(start: 0, end: 2, speaker: 0),
            .init(start: 2, end: 4, speaker: 1),
            .init(start: 3, end: 5, speaker: 2),
            .init(start: 6, end: 8, speaker: 3),
        ], transcriptSegments: [
            .init(start: 0, end: 2, speakers: [0], text: "Hello"),
            .init(start: 2, end: 3, speakers: [1], text: "Hi"),
            .init(start: 3, end: 4, speakers: [1, 2], text: "Still me"),
            .init(start: 4, end: 5, speakers: [2], text: "Another passage"),
            .init(start: 6, end: 8, speakers: [3], text: "A different person"),
        ], speakerNames: ["0": "Jordan", "1": "Me", "2": "Me", "3": "Me"],
           speakerProfileIDs: ["0": "nnenna", "1": "me", "2": "me", "3": "different-profile"])

        let grouped = original.groupedByProfile
        XCTAssertEqual(grouped.speakerIDs, [0, 1, 3], "Identity is the profile ID, not its display name")
        XCTAssertEqual(grouped.resolvedTranscriptSegments.map(\.speakers), [[0], [1], [1], [1], [3]])
        XCTAssertEqual(grouped.resolvedTranscriptSegments.map(\.text), original.resolvedTranscriptSegments.map(\.text))
        XCTAssertEqual(grouped.resolvedTranscriptSegments.map(\.start), original.resolvedTranscriptSegments.map(\.start))
        XCTAssertEqual(grouped.resolvedTranscriptSegments.map(\.end), original.resolvedTranscriptSegments.map(\.end))
        XCTAssertTrue(original.formattedTranscript?.contains("[00:03] Me: Still me") == true)
        XCTAssertFalse(original.formattedTranscript?.contains("Me + Me") == true)
        XCTAssertEqual(grouped.groupedByProfile, grouped)
        XCTAssertEqual(original.speakerIDs, [0, 1, 2, 3])
        XCTAssertEqual(try JSONDecoder().decode(AudioDiarization.self, from: JSONEncoder().encode(original)), original)
        let merged = try original.mergingSpeakers([1, 2], into: 1)
        XCTAssertEqual(merged.speakerIDs, [0, 1, 3])
        XCTAssertEqual(merged.transcriptSegments, grouped.transcriptSegments)
        XCTAssertNil(merged.speakerProfileIDs?["2"])
        XCTAssertNil(merged.speakerNames?["2"])
        XCTAssertFalse(merged.speakerTranscript?.contains("Speaker 3") == true)
        XCTAssertEqual(try JSONDecoder().decode(AudioDiarization.self, from: JSONEncoder().encode(merged)), merged)
    }

    func testMatchingLabelsWithoutAProfileStaySeparate() {
        let original = AudioDiarization(modelID: "model", revision: "test", segments: [
            .init(start: 0, end: 2, speaker: 0), .init(start: 2, end: 4, speaker: 1),
        ], speakerNames: ["0": "Alex", "1": "Alex"])
        XCTAssertEqual(original.groupedByProfile, original)
    }

    func testLegacyTranscriptIsRecoveredBeforeGroupingLinkedVoices() throws {
        let original = AudioDiarization(modelID: "model", revision: "test", segments: [
            .init(start: 0, end: 2, speaker: 0), .init(start: 2, end: 4, speaker: 1),
        ], speakerTranscript: "[00:00] Speaker 1: Hello\n\n[00:02] Speaker 2: Again",
           speakerNames: ["0": "Me", "1": "Me"], speakerProfileIDs: ["0": "me", "1": "me"])
        XCTAssertEqual(original.groupedByProfile.resolvedTranscriptSegments, [
            .init(start: 0, end: 2, speakers: [0], text: "Hello"),
            .init(start: 2, end: 4, speakers: [0], text: "Again"),
        ])
        XCTAssertEqual(original.formattedTranscript, "[00:00] Me: Hello\n\n[00:02] Me: Again")
        XCTAssertNil(original.transcriptSegments)
        XCTAssertEqual(try original.mergingSpeakers([0, 1], into: 0).transcriptSegments,
                       original.groupedByProfile.transcriptSegments)
    }

    func testUnrecoverableLegacyTranscriptCannotBeMerged() {
        let original = AudioDiarization(modelID: "model", revision: "test", segments: [
            .init(start: 0, end: 2, speaker: 0), .init(start: 2, end: 4, speaker: 1),
        ], speakerTranscript: "Saved text in an unknown legacy format")
        XCTAssertThrowsError(try original.mergingSpeakers([0, 1], into: 0))
    }

    func testServerWithRealModel() async throws {
        guard let path = ProcessInfo.processInfo.environment["NATIV_DIARIZATION_TEST_AUDIO"] else {
            throw XCTSkip("Set NATIV_DIARIZATION_TEST_AUDIO to NVIDIA's eight-voice sample WAV.")
        }
        var diarizationFinished = false
        var transcribedChunks = 0
        let client = NativAudioClient(baseURL: URL(string: ProcessInfo.processInfo.environment["NATIV_AUDIO_TEST_SERVER"] ?? "http://127.0.0.1:8080")!)
        let result = try await MeetingDiarizer.transcribe(URL(fileURLWithPath: path), client: client,
            model: MeetingDiarizer.defaultTranscriptionModelID) {
            diarizationFinished = true
        } segmentFinished: { _ in
            XCTAssertTrue(diarizationFinished, "No transcript may arrive before full-recording diarization completes")
            transcribedChunks += 1
        }
        XCTAssertEqual(result.diarization.modelID, MeetingDiarizer.defaultModelID)
        XCTAssertNil(result.diarization.revision)
        XCTAssertEqual(Set(result.diarization.segments.map(\.speaker)), Set(0..<8))
        XCTAssertGreaterThan(result.diarization.segments.map(\.end).max() ?? 0, 90)
        XCTAssertGreaterThan(transcribedChunks, 3)
        XCTAssertFalse(result.text.isEmpty)
        let text = try XCTUnwrap(result.diarization.speakerTranscript)
        for speaker in 1...8 { XCTAssertTrue(text.contains("Speaker \(speaker)")) }
        if let output = ProcessInfo.processInfo.environment["NATIV_DIARIZATION_TEST_OUTPUT"] {
            try text.write(toFile: output, atomically: true, encoding: .utf8)
        }
    }

    func testCancelledAnalysisDoesNotProduceResult() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MeetingDiarizer.transcribe(URL(fileURLWithPath: "/nonexistent.wav"), client: NativAudioClient(baseURL: URL(string: "http://127.0.0.1:1")!), model: MeetingDiarizer.defaultTranscriptionModelID)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled diarization must not return a result")
        } catch is CancellationError {}
    }

    func testLongTurnsKeepGlobalSpeakerIDsAndAbsoluteTime() throws {
        let result = AudioDiarization(modelID: "model", revision: "test", segments: [
            .init(start: 0, end: 65, speaker: 7),
            .init(start: 3600, end: 3603, speaker: 2),
            .init(start: 7200, end: 7232, speaker: 7),
        ])
        let chunks = try result.transcriptionChunks()
        XCTAssertEqual(chunks.map(\.start), [0, 30, 60, 3600, 7200, 7230])
        XCTAssertEqual(chunks.map(\.end), [30, 60, 65, 3603, 7230, 7232])
        XCTAssertEqual(chunks.map(\.speakers), [[7], [7], [7], [2], [7], [7]])
        XCTAssertEqual(chunks[4].labeled("Still the same voice"), "[120:00] Speaker 8: Still the same voice")
    }

    func testOverlapIsTranscribedOnceAndSilenceIsOmitted() throws {
        let result = AudioDiarization(modelID: "model", revision: "test", segments: [
            .init(start: 2, end: 5, speaker: 1),
            .init(start: 1, end: 3, speaker: 0),
            .init(start: 0, end: 4, speaker: 0),
            .init(start: 100, end: 101, speaker: 0),
        ])
        XCTAssertEqual(try result.transcriptionChunks(), [
            .init(start: 0, end: 2, speakers: [0]),
            .init(start: 2, end: 4, speakers: [0, 1]),
            .init(start: 4, end: 5, speakers: [1]),
            .init(start: 100, end: 101, speakers: [0]),
        ])
    }

    func testStreamBoundaryRoundingDoesNotInventTinyOverlaps() throws {
        let result = AudioDiarization(modelID: "model", revision: "test", segments: [
            .init(start: 0, end: 30.000000000000004, speaker: 0),
            .init(start: 30, end: 31, speaker: 1),
        ])
        XCTAssertEqual(try result.transcriptionChunks(), [
            .init(start: 0, end: 30, speakers: [0]), .init(start: 30, end: 31, speakers: [1]),
        ])
    }

    func testRejectsInvalidSpeakerOutput() {
        for segment: AudioDiarization.Segment in [
            .init(start: -1, end: 1, speaker: 0), .init(start: 0, end: .infinity, speaker: 0),
            .init(start: 0, end: 1, speaker: 8), .init(start: 1, end: 0, speaker: 0),
        ] {
            XCTAssertThrowsError(try AudioDiarization(modelID: "model", revision: "test", segments: [segment]).transcriptionChunks())
        }
    }

    func testLegacyTranscriptRecoversExactTimesAcrossHoursAndSkippedChunks() throws {
        let value = AudioDiarization(modelID: "test", revision: "test", segments: [
            .init(start: 0.25, end: 1.75, speaker: 7),
            .init(start: 2, end: 3, speaker: 0), // ASR returned no words.
            .init(start: 7200.25, end: 7201.75, speaker: 7),
            .init(start: 7200.25, end: 7201.75, speaker: 1),
        ], speakerTranscript: "[00:00] Speaker 8: Hello\n\n[120:00] Speaker 2 + Speaker 8: Together")
        XCTAssertEqual(value.resolvedTranscriptSegments, [
            .init(start: 0.25, end: 1.75, speakers: [7], text: "Hello"),
            .init(start: 7200.25, end: 7201.75, speakers: [1, 7], text: "Together"),
        ])
        var renamed = value
        renamed.speakerNames = ["7": "Casey"]
        XCTAssertEqual(renamed.formattedTranscript, "[00:00] Casey: Hello\n\n[120:00] Speaker 2 + Casey: Together")
        renamed.speakerTranscript = "Unexpected legacy text"
        XCTAssertEqual(renamed.formattedTranscript, "Unexpected legacy text")
        XCTAssertTrue(renamed.resolvedTranscriptSegments.isEmpty)
    }

    func testServerTranscriptPreservesGlobalIDsOverlapUnknownSpeechAndAbsoluteTime() throws {
        let response = try serverResponse(segments: """
            [{"id":"0","start":0.25,"end":1,"speaker":"A","text":"Hello"},
             {"id":"1","start":3600.25,"end":3601,"speaker":"B","speakers":["B","A"],"text":"Together"},
             {"id":"2","start":7200.25,"end":7201,"speaker":"unknown","text":"Unassigned"},
             {"id":"3","start":7202,"end":7203,"speaker":"A","text":"Again"}]
            """)
        let result = try MeetingDiarizer.Transcription(response)
        XCTAssertEqual(result.text, response.text)
        XCTAssertNil(result.diarization.revision)
        XCTAssertEqual(result.diarization.speakerIDs, [2, 7])
        XCTAssertEqual(result.diarization.transcriptSegments?.map(\.speakers), [[7], [2, 7], [], [7]])
        XCTAssertEqual(result.diarization.transcriptSegments?.map(\.start), response.segments.map(\.start))
        XCTAssertEqual(result.diarization.transcriptSegments?.map(\.end), response.segments.map(\.end))
        XCTAssertEqual(result.diarization.transcriptSegments?.map(\.text), response.segments.map(\.text))
        XCTAssertEqual(result.diarization.speakerTranscript,
            "[00:00] Speaker 8: Hello\n\n[60:00] Speaker 3 + Speaker 8: Together\n\n[120:00] Unassigned speaker: Unassigned\n\n[120:02] Speaker 8: Again")
    }

    func testServerTranscriptRejectsWrongModelMissingIDsAndUnmappedLabels() throws {
        let segment = #"[{"id":"0","start":0,"end":1,"speaker":"A","text":"Hello"}]"#
        for (model, ids) in [("wrong", #"{"A":7}"#), (MeetingDiarizer.defaultModelID, "null"),
                             (MeetingDiarizer.defaultModelID, #"{"B":2}"#)] {
            let response = try serverResponse(segments: segment, model: model, ids: ids)
            XCTAssertThrowsError(try MeetingDiarizer.Transcription(response))
        }
    }

    private func serverResponse(segments: String, model: String = MeetingDiarizer.defaultModelID,
                                ids: String = #"{"A":7,"B":2}"#) throws -> NativDiarizedTranscription {
        let detected = try JSONDecoder().decode(NativAudioDiarization.self, from: Data("""
            {"model":"\(model)","speaker_ids":\(ids),"segments":[
             {"start":0,"end":7203,"speaker":7},{"start":3600,"end":3601,"speaker":2}]}
            """.utf8))
        return NativDiarizedTranscription(text: "Hello Together Unassigned Again", duration: 7203,
            segments: try JSONDecoder().decode([NativDiarizedSegment].self, from: Data(segments.utf8)),
            diarization: detected)
    }

}

@MainActor
final class AudioDiarizationStorageTests: XCTestCase {
    func testSpeakerNamesPersistAndAffectExportWithoutChangingWordsOrIDs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AudioAnalyticsStore(storageURL: url)
        let diarization = AudioDiarization(modelID: "model", revision: "rev", segments: [
            .init(start: 3600.5, end: 3602, speaker: 2),
        ], speakerTranscript: "[60:00] Speaker 3: Hello")
        store.upsertTranscription(recordingURL: url.deletingPathExtension().appendingPathExtension("wav"),
                                  transcript: "Hello", durationSeconds: 3602, modelID: "stt", applicationName: nil,
                                  kind: .meeting, summary: "Summary", diarization: diarization)
        let id = try XCTUnwrap(store.records.first?.id)
        store.updateSpeakerName("  Casey\nTaylor  ", speakerID: 2, for: id)
        let record = try XCTUnwrap(AudioAnalyticsStore(storageURL: url).records.first)
        XCTAssertEqual(record.diarization?.speakerName(2), "Casey Taylor")
        XCTAssertEqual(record.diarization?.segments, diarization.segments)
        XCTAssertEqual(record.diarization?.transcriptSegments?.first?.start, 3600.5)
        XCTAssertEqual(record.transcript, "Hello")
        XCTAssertEqual(record.displayTranscript, "[60:00] Casey Taylor: Hello")
        let exported = String(decoding: try AudioRecordExport(record: record).data(format: .text), as: UTF8.self)
        XCTAssertTrue(exported.contains("[60:00] Casey Taylor: Hello"))
        store.updateSpeakerName("", speakerID: 2, for: id)
        XCTAssertEqual(AudioAnalyticsStore(storageURL: url).records.first?.displayTranscript, "[60:00] Speaker 3: Hello")
    }
    func testLegacyRecordsAndSpeakerMetadataSurviveEditsAndReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("records.json")
        let audio = directory.appendingPathComponent("meeting.wav")
        let store = AudioAnalyticsStore(storageURL: storage)
        store.upsertTranscription(recordingURL: audio, transcript: "Hello", durationSeconds: 1, modelID: "stt", applicationName: nil, kind: .meeting)
        XCTAssertEqual(AudioAnalyticsStore(storageURL: storage).records.first?.displayTranscript, "Hello")
        let speakers = AudioDiarization(modelID: MeetingDiarizer.defaultModelID, revision: "test", segments: [.init(start: 0, end: 1, speaker: 0)], speakerTranscript: "[00:00] Speaker 1: Hello")
        store.upsertTranscription(recordingURL: audio, transcript: "Hello", durationSeconds: 1, modelID: "stt", applicationName: nil, kind: .meeting, diarization: speakers)
        store.updateTitle("Team meeting", for: "meeting")
        store.updateSummary("Summary", for: "meeting")
        let record = try XCTUnwrap(AudioAnalyticsStore(storageURL: storage).records.first)
        XCTAssertEqual(record.diarization, speakers)
        XCTAssertEqual(record.displayTranscript, speakers.speakerTranscript)
        XCTAssertEqual(record.wordCount, 1)
        // A failed retry must not retain speaker labels from an older transcript.
        store.upsertTranscription(recordingURL: audio, transcript: "New text", durationSeconds: 1, modelID: "stt", applicationName: nil)
        XCTAssertNil(store.records.first?.diarization)
    }
}
