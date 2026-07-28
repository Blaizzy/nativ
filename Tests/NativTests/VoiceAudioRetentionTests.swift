import Foundation
import XCTest

final class VoiceAudioRetentionTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testRemovesOnlyAudioOlderThanFiveMinutes() throws {
        let now = Date()
        let expiredAudio = try makeFile(
            named: "expired.wav",
            modifiedAt: now.addingTimeInterval(-(VoiceAudioRetention.duration + 1))
        )
        let recentAudio = try makeFile(
            named: "recent.wav",
            modifiedAt: now.addingTimeInterval(-(VoiceAudioRetention.duration - 1))
        )
        let oldTranscript = try makeFile(
            named: "expired.txt",
            modifiedAt: now.addingTimeInterval(-(VoiceAudioRetention.duration + 1))
        )

        let removed = VoiceAudioRetention.removeExpiredAudioFiles(
            in: temporaryDirectory,
            now: now
        )

        XCTAssertEqual(removed.map(\.lastPathComponent), [expiredAudio.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldTranscript.path))
    }

    func testDeletionDelayUsesRemainingRetentionWindow() throws {
        let now = Date()
        let audioURL = try makeFile(
            named: "recording.wav",
            modifiedAt: now.addingTimeInterval(-120)
        )

        XCTAssertEqual(
            VoiceAudioRetention.deletionDelay(for: audioURL, now: now),
            180,
            accuracy: 0.1
        )
    }

    func testLatestAudioFileUsesMostRecentRecording() throws {
        let now = Date()
        _ = try makeFile(
            named: "older.wav",
            modifiedAt: now.addingTimeInterval(-30)
        )
        let latestAudio = try makeFile(
            named: "latest.wav",
            modifiedAt: now.addingTimeInterval(-10)
        )
        _ = try makeFile(
            named: "newer-transcript.txt",
            modifiedAt: now
        )

        XCTAssertEqual(
            VoiceAudioRetention.latestAudioFile(in: temporaryDirectory)?.lastPathComponent,
            latestAudio.lastPathComponent
        )
    }

    func testRemoveAllAudioLeavesTranscriptsUntouched() throws {
        let audioURL = try makeFile(named: "recording.wav", modifiedAt: Date())
        let transcriptURL = try makeFile(named: "recording.txt", modifiedAt: Date())

        VoiceAudioRetention.removeAllAudioFiles(in: temporaryDirectory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptURL.path))
    }

    private func makeFile(named name: String, modifiedAt: Date) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try Data("test".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: url.path
        )
        return url
    }
}
