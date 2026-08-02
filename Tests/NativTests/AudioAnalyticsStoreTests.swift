import Foundation
import XCTest

@MainActor
final class AudioAnalyticsStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var store: AudioAnalyticsStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        store = AudioAnalyticsStore(
            storageURL: temporaryDirectory.appendingPathComponent("analytics.json")
        )
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testCalculatesWordsSpeedAndEstimatedTimeSaved() {
        let recordingURL = temporaryDirectory.appendingPathComponent("recording.wav")
        let transcript = Array(repeating: "word", count: 100).joined(separator: " ")

        store.upsertTranscription(
            recordingURL: recordingURL,
            transcript: transcript,
            durationSeconds: 120,
            modelID: "mlx-community/parakeet",
            applicationName: "Notes"
        )

        XCTAssertEqual(store.totalWords, 100)
        XCTAssertEqual(store.averageWordsPerMinute ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(store.estimatedTimeSaved, 13.333, accuracy: 0.01)
        XCTAssertEqual(store.records.first?.applicationName, "Notes")
    }

    func testRetryPreservesOriginalDurationAndRecordedDate() {
        let recordingURL = temporaryDirectory.appendingPathComponent("recording.wav")
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.upsertTranscription(
            recordingURL: recordingURL,
            transcript: "first transcript",
            durationSeconds: 4,
            modelID: "first-model",
            applicationName: "Notes",
            recordedAt: recordedAt
        )
        store.upsertTranscription(
            recordingURL: recordingURL,
            transcript: "updated transcript",
            durationSeconds: nil,
            modelID: "second-model",
            applicationName: nil
        )

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records[0].recordedAt, recordedAt)
        XCTAssertEqual(store.records[0].durationSeconds, 4)
        XCTAssertEqual(store.records[0].applicationName, "Notes")
        XCTAssertEqual(store.records[0].modelID, "second-model")
    }

    func testImportsExistingTranscriptWithoutAudio() throws {
        let transcriptURL = temporaryDirectory.appendingPathComponent("older.txt")
        try "An older local transcript".write(
            to: transcriptURL,
            atomically: true,
            encoding: .utf8
        )

        store.importTranscripts(in: temporaryDirectory)

        XCTAssertEqual(store.records.map(\.id), ["older"])
        XCTAssertEqual(store.records.first?.wordCount, 4)
        XCTAssertNil(store.records.first?.durationSeconds)
    }

    func testPersistsMeetingAudioTranscriptAndSummaryMetadata() throws {
        let recordingURL = temporaryDirectory.appendingPathComponent("meeting.m4a")
        try Data([0x00]).write(to: recordingURL)

        store.addCapture(
            recordingURL: recordingURL,
            kind: .meeting,
            title: "Weekly planning",
            durationSeconds: 1_800
        )
        store.upsertTranscription(
            recordingURL: recordingURL,
            transcript: "We agreed to ship the audio library on Friday.",
            durationSeconds: 1_800,
            modelID: "local-asr",
            applicationName: nil,
            kind: .meeting,
            title: "Weekly planning",
            persistAudioReference: true
        )
        store.updateSummary("- Ship on Friday", for: "meeting")

        let reloaded = AudioAnalyticsStore(
            storageURL: temporaryDirectory.appendingPathComponent("analytics.json")
        )
        let record = try XCTUnwrap(reloaded.records.first)
        XCTAssertEqual(record.resolvedKind, .meeting)
        XCTAssertEqual(record.displayTitle, "Weekly planning")
        XCTAssertEqual(record.audioFileName, "meeting.m4a")
        XCTAssertEqual(record.summary, "- Ship on Friday")
        XCTAssertEqual(record.durationSeconds, 1_800)
    }
}
