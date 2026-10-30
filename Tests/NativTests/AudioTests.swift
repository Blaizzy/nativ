import AVFoundation
import Carbon.HIToolbox
import Foundation
import XCTest
@testable import NativServerKit

@MainActor
final class AudioPlaybackStateTests: XCTestCase {
    func testExcerptClampsToAvailableAudio() throws {
        let full = try XCTUnwrap(AudioPlaybackExcerpt(start: -1, end: 20, duration: 10))
        XCTAssertEqual(full.start, 0)
        XCTAssertEqual(full.end, 10)
        let tail = try XCTUnwrap(AudioPlaybackExcerpt(start: 9.5, end: 12, duration: 10))
        XCTAssertEqual(tail.start, 9.5)
        XCTAssertEqual(tail.end, 10)
    }

    func testInvalidOrEmptyExcerptsCannotStartPlayback() {
        for (start, end, duration): (Double, Double, Double) in [
            (0, 1, 0), (0, 1, -1), (1, 1, 10), (2, 1, 10),
            (10, 12, 10), (20, 22, 10), (-2, -1, 10),
            (.nan, 1, 10), (0, .infinity, 10), (0, 1, .infinity),
        ] {
            XCTAssertNil(AudioPlaybackExcerpt(start: start, end: end, duration: duration))
        }
    }

    func testStoppingPlaybackClearsExcerptAndPositionButKeepsPreferredRate() throws {
        let playback = AudioPlaybackState()
        playback.recordID = "meeting"
        playback.duration = 60
        playback.position = 23
        playback.rate = 1.5
        playback.excerpt = try XCTUnwrap(AudioPlaybackExcerpt(start: 20, end: 28, duration: 60))
        playback.reset()
        XCTAssertNil(playback.recordID)
        XCTAssertNil(playback.excerpt)
        XCTAssertEqual(playback.position, 0)
        XCTAssertEqual(playback.duration, 0)
        XCTAssertEqual(playback.rate, 1.5)
    }
}

@MainActor
final class NativSystemPermissionControllerTests: XCTestCase {
    func testAuthorizedMicrophoneAccessDoesNotRequestAgain() async {
        var requestCount = 0

        let granted = await NativSystemPermissionController.resolveMicrophoneAccess(
            status: .authorized
        ) {
            requestCount += 1
            return false
        }

        XCTAssertTrue(granted)
        XCTAssertEqual(requestCount, 0)
    }

    func testUndeterminedMicrophoneAccessRequestsAndReturnsGrant() async {
        var requestCount = 0

        let granted = await NativSystemPermissionController.resolveMicrophoneAccess(
            status: .notDetermined
        ) {
            requestCount += 1
            return true
        }

        XCTAssertTrue(granted)
        XCTAssertEqual(requestCount, 1)
    }

    func testUndeterminedMicrophoneAccessReturnsDenial() async {
        let granted = await NativSystemPermissionController.resolveMicrophoneAccess(
            status: .notDetermined
        ) {
            false
        }

        XCTAssertFalse(granted)
    }

    func testDeniedOrRestrictedMicrophoneAccessDoesNotRequestAgain() async {
        var requestCount = 0

        for status in [AVAuthorizationStatus.denied, .restricted] {
            let granted = await NativSystemPermissionController.resolveMicrophoneAccess(
                status: status
            ) {
                requestCount += 1
                return true
            }

            XCTAssertFalse(granted)
        }

        XCTAssertEqual(requestCount, 0)
    }
}

@MainActor
final class AudioAnalyticsStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var store: AudioAnalyticsStore!

    override func setUp() async throws {
        try await super.setUp()
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

    override func tearDown() async throws {
        store = nil
        try FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
        try await super.tearDown()
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

    func testAggregatesTranscriptionUsageByModel() throws {
        let localModelID = "mlx-community/parakeet"
        let appleModelID = "apple-speech (on-device)"
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(60)
        let thirdDate = secondDate.addingTimeInterval(60)

        store.upsertTranscription(
            recordingURL: temporaryDirectory.appendingPathComponent("dictation.wav"),
            transcript: "one two three four",
            durationSeconds: 10,
            modelID: localModelID,
            applicationName: "Notes",
            recordedAt: firstDate
        )
        store.upsertTranscription(
            recordingURL: temporaryDirectory.appendingPathComponent("meeting.wav"),
            transcript: "five six seven",
            durationSeconds: 20,
            modelID: localModelID,
            applicationName: nil,
            kind: .meeting,
            recordedAt: secondDate
        )
        store.upsertTranscription(
            recordingURL: temporaryDirectory.appendingPathComponent("apple.wav"),
            transcript: "eight nine",
            durationSeconds: nil,
            modelID: appleModelID,
            applicationName: nil,
            recordedAt: thirdDate
        )
        store.upsertTranscription(
            recordingURL: temporaryDirectory.appendingPathComponent("legacy.wav"),
            transcript: "legacy transcript",
            durationSeconds: nil,
            modelID: nil,
            applicationName: nil,
            recordedAt: firstDate
        )
        store.addCapture(
            recordingURL: temporaryDirectory.appendingPathComponent("untranscribed.wav"),
            kind: .voiceNote,
            title: "Untranscribed",
            durationSeconds: 30
        )

        let usages = store.modelUsage()

        XCTAssertEqual(usages.map(\.modelID), [localModelID, appleModelID, nil])
        let localUsage = try XCTUnwrap(usages.first)
        XCTAssertEqual(localUsage.transcriptions, 2)
        XCTAssertEqual(localUsage.dictations, 1)
        XCTAssertEqual(localUsage.recordings, 1)
        XCTAssertEqual(localUsage.words, 7)
        XCTAssertEqual(localUsage.durationSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(localUsage.timedTranscriptions, 2)
        XCTAssertEqual(localUsage.lastUsedAt, secondDate)

        let appleUsage = try XCTUnwrap(usages.first { $0.modelID == appleModelID })
        XCTAssertEqual(appleUsage.transcriptions, 1)
        XCTAssertEqual(appleUsage.dictations, 1)
        XCTAssertEqual(appleUsage.recordings, 0)
        XCTAssertEqual(appleUsage.words, 2)
        XCTAssertEqual(appleUsage.timedTranscriptions, 0)

        let unknownUsage = try XCTUnwrap(usages.first { $0.modelID == nil })
        XCTAssertEqual(unknownUsage.transcriptions, 1)
        XCTAssertEqual(unknownUsage.words, 2)

        let recentUsages = store.modelUsage(since: secondDate)
        XCTAssertEqual(recentUsages.map(\.modelID), [localModelID, appleModelID])
        XCTAssertEqual(recentUsages[0].transcriptions, 1)
        XCTAssertEqual(recentUsages[0].dictations, 0)
        XCTAssertEqual(recentUsages[0].recordings, 1)
        XCTAssertEqual(recentUsages[0].words, 3)
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

    func testRegeneratedTranscriptCanInvalidateExistingSummary() {
        let recordingURL = temporaryDirectory.appendingPathComponent("recording.wav")

        store.upsertTranscription(
            recordingURL: recordingURL,
            transcript: "first transcript",
            durationSeconds: 4,
            modelID: "first-model",
            applicationName: nil,
            summary: "Summary of the first transcript"
        )
        store.upsertTranscription(
            recordingURL: recordingURL,
            transcript: "replacement transcript",
            durationSeconds: 4,
            modelID: "second-model",
            applicationName: nil,
            preserveExistingSummary: false
        )

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records[0].transcript, "replacement transcript")
        XCTAssertEqual(store.records[0].modelID, "second-model")
        XCTAssertNil(store.records[0].summary)
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

    func testDeletesDictationFilesAndPersistedRecord() throws {
        let recordingURL = temporaryDirectory.appendingPathComponent("dictation.wav")
        let transcriptURL = temporaryDirectory.appendingPathComponent("dictation.txt")
        try Data([0x00]).write(to: recordingURL)
        try "Delete this transcript".write(
            to: transcriptURL,
            atomically: true,
            encoding: .utf8
        )
        store.upsertTranscription(
            recordingURL: recordingURL,
            transcript: "Delete this transcript",
            durationSeconds: 2,
            modelID: "local-asr",
            applicationName: "Notes"
        )

        store.deleteDictation(
            withID: "dictation",
            recordingsDirectory: temporaryDirectory
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: recordingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptURL.path))
        XCTAssertTrue(store.records.isEmpty)
        store.importTranscripts(in: temporaryDirectory)
        XCTAssertTrue(store.records.isEmpty)
        let reloaded = AudioAnalyticsStore(
            storageURL: temporaryDirectory.appendingPathComponent("analytics.json")
        )
        XCTAssertTrue(reloaded.records.isEmpty)
    }

    func testDeletesAllDictationsWithoutDeletingSavedRecordings() throws {
        let dictationURL = temporaryDirectory.appendingPathComponent("dictation.wav")
        let dictationTranscriptURL = temporaryDirectory
            .appendingPathComponent("dictation.txt")
        try Data([0x00]).write(to: dictationURL)
        try "Delete this dictation".write(
            to: dictationTranscriptURL,
            atomically: true,
            encoding: .utf8
        )
        store.upsertTranscription(
            recordingURL: dictationURL,
            transcript: "Delete this dictation",
            durationSeconds: 2,
            modelID: "local-asr",
            applicationName: nil
        )

        let meetingURL = temporaryDirectory.appendingPathComponent("meeting.m4a")
        let meetingTranscriptURL = temporaryDirectory
            .appendingPathComponent("meeting.txt")
        try Data([0x00]).write(to: meetingURL)
        try "Keep this recording".write(
            to: meetingTranscriptURL,
            atomically: true,
            encoding: .utf8
        )
        store.upsertTranscription(
            recordingURL: meetingURL,
            transcript: "Keep this recording",
            durationSeconds: 30,
            modelID: "local-asr",
            applicationName: nil,
            kind: .meeting,
            title: "Planning",
            persistAudioReference: true
        )

        store.deleteAllDictations(recordingsDirectory: temporaryDirectory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dictationURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dictationTranscriptURL.path)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: meetingURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: meetingTranscriptURL.path)
        )
        XCTAssertEqual(store.records.map(\.id), ["meeting"])
        let reloaded = AudioAnalyticsStore(
            storageURL: temporaryDirectory.appendingPathComponent("analytics.json")
        )
        XCTAssertEqual(reloaded.records.map(\.id), ["meeting"])
    }

    func testUntranscribedMeetingSurvivesReloadAndCanBeTranscribedInPlace() throws {
        let recordingURL = temporaryDirectory.appendingPathComponent("sleep-meeting.wav")
        try Data([0x00]).write(to: recordingURL)
        store.addCapture(
            recordingURL: recordingURL,
            kind: .meeting,
            title: "Interrupted meeting",
            durationSeconds: 60
        )

        let reloaded = AudioAnalyticsStore(
            storageURL: temporaryDirectory.appendingPathComponent("analytics.json")
        )
        let saved = try XCTUnwrap(reloaded.records.first)
        XCTAssertEqual(saved.transcript, "")
        XCTAssertEqual(saved.audioFileName, recordingURL.lastPathComponent)
        XCTAssertEqual(saved.resolvedKind, .meeting)
        XCTAssertNil(saved.summary)

        reloaded.upsertTranscription(
            recordingURL: recordingURL,
            transcript: "Audio captured before sleep.",
            durationSeconds: 60,
            modelID: "local-asr",
            applicationName: nil
        )
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records.first?.id, saved.id)
        XCTAssertEqual(reloaded.records.first?.audioFileName, saved.audioFileName)
        XCTAssertEqual(reloaded.records.first?.transcript, "Audio captured before sleep.")
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

    func testPersistsEditedRecordingTitle() throws {
        let recordingURL = temporaryDirectory.appendingPathComponent("voice-note.wav")
        store.upsertTranscription(
            recordingURL: recordingURL,
            transcript: "A note worth naming",
            durationSeconds: 4,
            modelID: "local-asr",
            applicationName: nil,
            kind: .voiceNote,
            title: "Voice note",
            persistAudioReference: true
        )

        store.updateTitle("  Product launch idea  ", for: "voice-note")

        let reloaded = AudioAnalyticsStore(
            storageURL: temporaryDirectory.appendingPathComponent("analytics.json")
        )
        XCTAssertEqual(reloaded.records.first?.displayTitle, "Product launch idea")
    }

    func testImportedCaptureUsesImportDateAndPreservesItAfterTranscription() throws {
        let earlierRecordingURL = temporaryDirectory.appendingPathComponent("earlier.wav")
        let uploadedAudioURL = temporaryDirectory.appendingPathComponent("uploaded.m4a")
        let earlierDate = Date(timeIntervalSince1970: 1_700_000_000)
        let importedAt = earlierDate.addingTimeInterval(3_600)

        store.addCapture(
            recordingURL: earlierRecordingURL,
            kind: .voiceNote,
            title: "Earlier recording",
            durationSeconds: 30,
            recordedAt: earlierDate
        )
        store.addCapture(
            recordingURL: uploadedAudioURL,
            kind: .voiceNote,
            title: "Uploaded audio",
            durationSeconds: 60,
            recordedAt: importedAt
        )

        XCTAssertEqual(store.records.map(\.id), ["uploaded", "earlier"])

        store.upsertTranscription(
            recordingURL: uploadedAudioURL,
            transcript: "A completed uploaded audio transcript.",
            durationSeconds: 60,
            modelID: "local-asr",
            applicationName: nil,
            kind: .voiceNote,
            title: "Uploaded audio",
            persistAudioReference: true
        )

        XCTAssertEqual(store.records.map(\.id), ["uploaded", "earlier"])
        XCTAssertEqual(store.records.first?.recordedAt, importedAt)
    }

    func testMigratesExistingImportedCaptureDateFromUTCManagedFileName() throws {
        let legacyDate = Date(timeIntervalSince1970: 1_700_000_000)
        let importedAudioURL = temporaryDirectory.appendingPathComponent(
            "Imported Audio 2026-08-20 at 02.18.18.000 ABCD1234.m4a"
        )
        store.addCapture(
            recordingURL: importedAudioURL,
            kind: .voiceNote,
            title: "Existing upload",
            durationSeconds: 60,
            recordedAt: legacyDate
        )

        let reloaded = AudioAnalyticsStore(
            storageURL: temporaryDirectory.appendingPathComponent("analytics.json")
        )
        let migratedDate = try XCTUnwrap(reloaded.records.first?.recordedAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: migratedDate
        )

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 20)
        XCTAssertEqual(components.hour, 2)
        XCTAssertEqual(components.minute, 18)
        XCTAssertEqual(components.second, 18)
    }
}

@MainActor
final class FnControlShortcutMonitorTests: XCTestCase {
    func testShortcutCaptureSuppressesPollingAndWaitsForReleaseBeforeResuming() async throws {
        let preferences = makePreferences()
        var modifiers: VoiceShortcutModifiers = []
        var changes: [Bool] = []
        var retries = 0
        let monitor = FnControlShortcutMonitor(preferences: preferences) { modifiers }
        monitor.onChange = { changes.append($0) }
        monitor.onRetry = { retries += 1 }
        monitor.start()
        defer { monitor.stop() }

        for handsFree in [false, true] {
            preferences.isHandsFreeEnabled = handsFree
            preferences.isCapturingShortcut = true
            modifiers = [.function, .control, .option]
            try await Task.sleep(for: .milliseconds(75))
            modifiers = []
            try await Task.sleep(for: .milliseconds(75))
            XCTAssertEqual(changes, [])
            XCTAssertEqual(retries, 0)
        }

        preferences.isHandsFreeEnabled = false
        modifiers = [.function, .control, .option]
        preferences.isCapturingShortcut = false
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(changes, [])
        XCTAssertEqual(retries, 0)

        modifiers = []
        try await Task.sleep(for: .milliseconds(75))
        let resumed = expectation(description: "A fresh dictation shortcut works after setup")
        monitor.onChange = { held in
            changes.append(held)
            if held { resumed.fulfill() }
        }
        modifiers = [.function, .control]
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertEqual(changes, [true])

        let retried = expectation(description: "Retry works after setup")
        monitor.onRetry = { retried.fulfill() }
        modifiers = [.option]
        await fulfillment(of: [retried], timeout: 2)
    }

    func testShortcutCaptureSuppressesHotKeysThroughPreferenceChanges() {
        let preferences = makePreferences()
        var modifiers: VoiceShortcutModifiers = []
        var changes: [Bool] = []
        var retries = 0
        let monitor = FnControlShortcutMonitor(preferences: preferences) { modifiers }
        monitor.onChange = { changes.append($0) }
        monitor.onRetry = { retries += 1 }
        monitor.start()
        defer { monitor.stop() }

        preferences.isCapturingShortcut = true
        preferences.isHandsFreeEnabled = true
        for id: UInt32 in [1, 2] {
            monitor.consumeHotKeyEvent(id: id, kind: UInt32(kEventHotKeyPressed))
            monitor.consumeHotKeyEvent(id: id, kind: UInt32(kEventHotKeyReleased))
        }
        XCTAssertEqual(changes, [])
        XCTAssertEqual(retries, 0)

        modifiers = [.command]
        preferences.isCapturingShortcut = false
        monitor.consumeHotKeyEvent(id: 1, kind: UInt32(kEventHotKeyPressed))
        monitor.consumeHotKeyEvent(id: 2, kind: UInt32(kEventHotKeyPressed))
        XCTAssertEqual(changes, [])
        XCTAssertEqual(retries, 0)

        modifiers = []
        monitor.resynchronizeAfterModalInteraction()
        monitor.consumeHotKeyEvent(id: 1, kind: UInt32(kEventHotKeyPressed))
        monitor.consumeHotKeyEvent(id: 2, kind: UInt32(kEventHotKeyPressed))
        XCTAssertEqual(changes, [true])
        XCTAssertEqual(retries, 1)
    }

    func testMonitorStartedDuringShortcutCaptureWaitsForRelease() {
        let preferences = makePreferences()
        preferences.isCapturingShortcut = true
        var modifiers: VoiceShortcutModifiers = [.function, .control]
        var changes: [Bool] = []
        let monitor = FnControlShortcutMonitor(preferences: preferences) { modifiers }
        monitor.onChange = { changes.append($0) }
        monitor.start()
        defer { monitor.stop() }

        preferences.isCapturingShortcut = false
        XCTAssertEqual(changes, [])
        modifiers = []
        monitor.resynchronizeAfterModalInteraction()
        modifiers = [.function, .control]
        monitor.resynchronizeAfterModalInteraction()
        XCTAssertEqual(changes, [true])
    }

    func testPollingDeliversPressAndReleaseThenStops() async throws {
        let preferences = makePreferences()
        var modifiers: VoiceShortcutModifiers = [.function, .control]
        var samples = 0
        var changes: [Bool] = []
        let released = expectation(description: "Polling observes modifier release")
        let monitor = FnControlShortcutMonitor(preferences: preferences) {
            samples += 1
            return modifiers
        }
        monitor.onChange = { held in
            XCTAssertTrue(Thread.isMainThread)
            changes.append(held)
            if !held { released.fulfill() }
        }
        monitor.start()
        defer { monitor.stop() }

        // The first sample is synchronous, before the polling task starts.
        XCTAssertEqual(changes, [true])
        modifiers = []
        await fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(changes, [true, false])

        monitor.stop()
        let samplesAtStop = samples
        modifiers = [.function, .control]
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(samples, samplesAtStop)
        XCTAssertEqual(changes, [true, false])
    }

    func testImmediateStopAndRestartDoNotLeaveOldPollersRunning() async throws {
        let preferences = makePreferences()
        var samples = 0
        var retryEnabled = false
        let polled = expectation(description: "Restarted monitor polls")
        let monitor = FnControlShortcutMonitor(preferences: preferences) {
            samples += 1
            return retryEnabled && samples > 21 ? [.option] : []
        }

        for _ in 0 ..< 20 {
            monitor.start()
            monitor.stop()
        }
        XCTAssertEqual(samples, 20)
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(samples, 20)

        monitor.onRetry = { polled.fulfill() }
        retryEnabled = true
        monitor.start()
        defer { monitor.stop() }
        await fulfillment(of: [polled], timeout: 2)
        monitor.stop()
        let samplesAtStop = samples
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(samples, samplesAtStop)
    }

    private func makePreferences() -> VoiceShortcutPreferences {
        let suiteName = "FnControlShortcutMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = VoiceShortcutPreferences(defaults: defaults)
        preferences.isHandsFreeEnabled = false
        preferences.retryShortcut = VoiceShortcut(
            keyCode: nil,
            keyDisplay: nil,
            modifiers: [.option]
        )
        return preferences
    }
}

final class FnControlShortcutStateTests: XCTestCase {
    func testActivatesOnlyWhenFnAndControlAreBothHeld() {
        var state = FnControlShortcutState()

        XCTAssertNil(state.update(functionIsDown: true, controlIsDown: false))
        XCTAssertEqual(state.update(functionIsDown: true, controlIsDown: true), true)
        XCTAssertNil(state.update(functionIsDown: true, controlIsDown: true))
    }

    func testReleasesWhenEitherModifierIsReleased() {
        var state = FnControlShortcutState()
        XCTAssertEqual(state.update(functionIsDown: true, controlIsDown: true), true)

        XCTAssertEqual(state.update(functionIsDown: false, controlIsDown: true), false)
        XCTAssertNil(state.update(functionIsDown: false, controlIsDown: false))
    }

    func testCanStartAgainAfterRelease() {
        var state = FnControlShortcutState()
        XCTAssertEqual(state.update(functionIsDown: true, controlIsDown: true), true)
        XCTAssertEqual(state.update(functionIsDown: true, controlIsDown: false), false)
        XCTAssertEqual(state.update(functionIsDown: true, controlIsDown: true), true)
    }
}

final class FnRetryShortcutStateTests: XCTestCase {
    func testTriggersOnlyOnInitialPress() {
        var state = FnRetryShortcutState()

        XCTAssertTrue(state.update(isPressed: true))
        XCTAssertFalse(state.update(isPressed: true))
        XCTAssertFalse(state.update(isPressed: true))
    }

    func testCanTriggerAgainAfterRelease() {
        var state = FnRetryShortcutState()

        XCTAssertTrue(state.update(isPressed: true))
        XCTAssertFalse(state.update(isPressed: false))
        XCTAssertTrue(state.update(isPressed: true))
    }
}

final class VoiceModifierToggleShortcutStateTests: XCTestCase {
    @discardableResult
    private func tap(
        _ state: inout VoiceModifierToggleShortcutState,
        shortcut: VoiceShortcutModifiers = [.option]
    ) -> Bool {
        _ = state.update(activeModifiers: shortcut, shortcutModifiers: shortcut)
        return state.update(activeModifiers: [], shortcutModifiers: shortcut)
    }

    func testSingleTapToggles() {
        var state = VoiceModifierToggleShortcutState()
        XCTAssertTrue(tap(&state))
        XCTAssertFalse(state.isHeld)
    }

    func testEachCleanTapToggles() {
        var state = VoiceModifierToggleShortcutState()
        XCTAssertTrue(tap(&state))
        XCTAssertTrue(tap(&state))
    }

    func testExtraModifierDoesNotInvalidateTap() {
        var state = VoiceModifierToggleShortcutState()

        XCTAssertFalse(
            state.update(
                activeModifiers: [.option],
                shortcutModifiers: [.option]
            )
        )
        XCTAssertFalse(
            state.update(
                activeModifiers: [.option, .shift],
                shortcutModifiers: [.option]
            )
        )
        XCTAssertTrue(
            state.update(
                activeModifiers: [],
                shortcutModifiers: [.option]
            )
        )
    }

    func testKeyPressDoesNotToggle() {
        var state = VoiceModifierToggleShortcutState()

        XCTAssertFalse(
            state.update(
                activeModifiers: [.option],
                shortcutModifiers: [.option]
            )
        )
        state.noteKeyDown()
        XCTAssertTrue(state.wasUsedAsChord)
        XCTAssertFalse(
            state.update(
                activeModifiers: [],
                shortcutModifiers: [.option]
            )
        )
        XCTAssertTrue(tap(&state))
    }

    func testEntersHeldWithExtraModifier() {
        var state = VoiceModifierToggleShortcutState()
        let shortcut: VoiceShortcutModifiers = [.control, .option, .command]
        XCTAssertFalse(
            state.update(
                activeModifiers: [.control, .option, .command, .shift],
                shortcutModifiers: shortcut
            )
        )
        XCTAssertTrue(state.isHeld)
        XCTAssertTrue(
            state.update(activeModifiers: [], shortcutModifiers: shortcut)
        )
        XCTAssertTrue(tap(&state, shortcut: shortcut))
    }

    func testPartialReleaseCannotRearmFromStaleModifierSample() {
        var state = VoiceModifierToggleShortcutState()
        let shortcut: VoiceShortcutModifiers = [.function, .control]

        XCTAssertFalse(
            state.update(activeModifiers: shortcut, shortcutModifiers: shortcut)
        )
        XCTAssertTrue(
            state.update(activeModifiers: [.function], shortcutModifiers: shortcut)
        )
        XCTAssertTrue(state.isAwaitingFullRelease)

        // A polling sample can briefly report the old fully-held state after
        // the release event. It must not arm a second toggle.
        XCTAssertFalse(
            state.update(activeModifiers: shortcut, shortcutModifiers: shortcut)
        )
        XCTAssertFalse(state.isHeld)

        XCTAssertFalse(
            state.update(activeModifiers: [], shortcutModifiers: shortcut)
        )
        XCTAssertFalse(state.isAwaitingFullRelease)
        XCTAssertTrue(tap(&state, shortcut: shortcut))
    }
}

final class PushToTalkHoldStateTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 0)

    func testRisingEdgeStartsAndSustainedIsNoChange() {
        var state = PushToTalkHoldState()
        XCTAssertEqual(state.update(rawHeld: true, now: origin), true)
        XCTAssertNil(state.update(rawHeld: true, now: origin.addingTimeInterval(0.05)))
        XCTAssertTrue(state.isHeld)
    }

    func testTransientDropWithinGraceKeepsHeld() {
        var state = PushToTalkHoldState()
        XCTAssertEqual(state.update(rawHeld: true, now: origin), true)
        XCTAssertNil(state.update(rawHeld: false, now: origin.addingTimeInterval(0.05)))
        XCTAssertTrue(state.isHeld)
        XCTAssertNil(state.update(rawHeld: true, now: origin.addingTimeInterval(0.08)))
        XCTAssertTrue(state.isHeld)
    }

    func testSustainedReleaseAfterGraceStops() {
        var state = PushToTalkHoldState()
        XCTAssertEqual(state.update(rawHeld: true, now: origin), true)
        XCTAssertNil(state.update(rawHeld: false, now: origin.addingTimeInterval(0.05)))
        XCTAssertEqual(
            state.update(rawHeld: false, now: origin.addingTimeInterval(0.2)),
            false
        )
        XCTAssertFalse(state.isHeld)
    }
}

final class NativAudioClientTests: XCTestCase {
    func testDiarizedStreamKeepsSpeakerMappingAndRejectsIncompleteResults() async throws {
        let pcm = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0, count: 2048).write(to: pcm)
        defer { try? FileManager.default.removeItem(at: pcm) }
        for host in ["success", "truncated", "failed", "duplicate", "invalid-time"] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DiarizedURLProtocol.self]
            let client = NativAudioClient(baseURL: URL(string: "http://\(host)")!, sessionConfiguration: configuration)
            do {
                let response = try await client.transcribeDiarized(pcmURL: pcm, model: "asr", diarizationModel: "diarizer")
                XCTAssertEqual(host, "success")
                XCTAssertNil(response.diarization.revision)
                XCTAssertEqual(response.text, "Hello")
                XCTAssertEqual(response.diarization.speaker_ids, ["A": 7])
                XCTAssertEqual(response.segments.first?.speakers, ["A"])
            } catch {
                XCTAssertNotEqual(host, "success", "\(error)")
            }
        }
    }

    func testSpeakerEndpointsWithRealServer() async throws {
        guard let address = ProcessInfo.processInfo.environment["NATIV_AUDIO_TEST_SERVER"],
              let path = ProcessInfo.processInfo.environment["NATIV_AUDIO_TEST_PCM"] else {
            throw XCTSkip("Set NATIV_AUDIO_TEST_SERVER and NATIV_AUDIO_TEST_PCM for real-model HTTP validation.")
        }
        let client = NativAudioClient(baseURL: try XCTUnwrap(URL(string: address)), timeout: 300)
        let result = try await client.diarize(pcmURL: URL(fileURLWithPath: path),
            model: MeetingDiarizer.defaultModelID)
        XCTAssertEqual(Set(result.segments.map(\.speaker)), Set(0..<8))
        XCTAssertEqual(result.segments.count, 31)
        let span = try XCTUnwrap(result.segments.first { $0.end - $0.start > 3.3 })
        let start = Int(((span.start + 0.15) * 16000).rounded())
        let end = min(Int(((span.end - 0.15) * 16000).rounded()), start + 10 * 16000)
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(start * 4))
        let pcm = try XCTUnwrap(file.read(upToCount: (end - start) * 4))
        let excerpt = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: excerpt) }
        try pcm.write(to: excerpt)
        let duration = Double(end - start) / 16000
        let response = try await client.speakerEmbedding(pcmURL: excerpt, windows: [.init(start: 0, end: duration)],
            model: SpeakerVoiceEmbeddingExtractor.modelID)
        try SpeakerVoiceEmbedding(modelID: response.model, revision: response.revision,
            vector: response.embedding, durationSeconds: response.duration).validate()
        XCTAssertEqual(response.duration, duration, accuracy: 1 / 16000)
    }

    func testSpeakerAnalysisUploadPreservesPCMAndUsesConfiguredServer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pcm = directory.appendingPathComponent("voice.f32")
        let data = Data(repeating: 0x5a, count: 1_048_580)
        try data.write(to: pcm)
        let original = try FileManager.default.attributesOfItem(atPath: pcm.path)
        let body = directory.appendingPathComponent("request")
        let client = NativAudioClient(baseURL: URL(string: "http://localhost:49444")!, apiKey: "speaker-test", timeout: 7200)
        let request = try client.makeAnalysisRequest(pcmURL: pcm, endpoint: "speaker_embeddings",
            fields: ["model": "ecapa", "revision": "revision", "windows": "[{\"start\":0,\"end\":3}]"],
            bodyURL: body, boundary: "TestBoundary")
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:49444/v1/audio/speaker_embeddings")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer speaker-test")
        XCTAssertEqual(request.timeoutInterval, 7200)
        XCTAssertNil(request.httpBody, "Large uploads must be sent from disk")
        let uploaded = try Data(contentsOf: body)
        XCTAssertTrue(uploaded.range(of: Data("name=\"input_format\"\r\n\r\npcm_f32le".utf8)) != nil)
        XCTAssertTrue(uploaded.range(of: Data("name=\"windows\"\r\n\r\n[{\"start\":0,\"end\":3}]".utf8)) != nil)
        XCTAssertTrue(uploaded.range(of: data) != nil)
        XCTAssertTrue(uploaded.suffix(20).elementsEqual(Data("\r\n--TestBoundary--\r\n".utf8)))
        XCTAssertEqual(try Data(contentsOf: pcm), data)
        let after = try FileManager.default.attributesOfItem(atPath: pcm.path)
        XCTAssertEqual(original[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }

    func testServerAnalysisResponsesPreserveModelRevisionAndSpeakerIDs() throws {
        for revision in ["", #","revision":null"#] {
            let diarization = try JSONDecoder().decode(NativAudioDiarization.self,
                from: Data("{\"model\":\"nemotron\",\"segments\":[]\(revision)}".utf8))
            XCTAssertNil(diarization.revision)
            let embedding = try JSONDecoder().decode(NativSpeakerEmbedding.self,
                from: Data("{\"model\":\"ecapa\",\"embedding\":[1],\"duration\":3\(revision)}".utf8))
            XCTAssertNil(embedding.revision)
        }
        let diarization = try JSONDecoder().decode(NativAudioDiarization.self,
            from: Data(#"{"model":"nemotron","revision":"pinned","segments":[{"start":61.5,"end":64,"speaker":7}]}"#.utf8))
        XCTAssertEqual(diarization.revision, "pinned")
        XCTAssertEqual(diarization.segments.first?.speaker, 7)
        XCTAssertEqual(diarization.segments.first?.start, 61.5)
        let embedding = try JSONDecoder().decode(NativSpeakerEmbedding.self,
            from: Data(#"{"model":"ecapa","revision":"pinned","embedding":[0.6,0.8],"duration":7}"#.utf8))
        XCTAssertEqual(embedding.model, "ecapa")
        XCTAssertEqual(embedding.embedding, [0.6, 0.8])
        XCTAssertEqual(embedding.duration, 7)
    }

    func testCancelledSpeakerRequestDoesNotReadOrUploadAudio() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NativAudioClient(baseURL: URL(string: "http://127.0.0.1:1")!).diarize(
                pcmURL: URL(fileURLWithPath: "/nonexistent.f32"), model: "model", revision: "revision")
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled analysis must fail before reading audio")
        } catch is CancellationError {}
    }


    func testTranscriptionRequestUsesExpectedMultipartFields() throws {
        let serverURL = try XCTUnwrap(URL(string: "http://speech-runtime.local:49152"))
        let client = NativAudioClient(
            baseURL: serverURL,
            apiKey: "test-token"
        )
        let request = client.makeURLRequest(
            audioData: Data([0x00, 0x01, 0x02]),
            fileName: "Voice Recording.wav",
            model: "local-owner/custom-speech-model",
            boundary: "TestBoundary"
        )

        XCTAssertEqual(request.url?.host, "speech-runtime.local")
        XCTAssertEqual(request.url?.port, 49_152)
        XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "multipart/form-data; boundary=TestBoundary"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-token"
        )

        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nlocal-owner/custom-speech-model"))
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\njson"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"Voice Recording.wav\""))
        XCTAssertTrue(body.contains("Content-Type: audio/wav"))
        XCTAssertTrue(body.hasSuffix("\r\n--TestBoundary--\r\n"))
    }

    func testTranscriptionRequestSanitizesMultipartFileName() throws {
        let client = NativAudioClient(
            baseURL: try XCTUnwrap(URL(string: "http://dynamic-host.test:32001"))
        )
        let request = client.makeURLRequest(
            audioData: Data(),
            fileName: "bad\"\r\nname.m4a",
            model: "speech-model",
            boundary: "TestBoundary"
        )

        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("filename=\"bad___name.m4a\""))
        XCTAssertFalse(body.contains("filename=\"bad\"\r\n"))
    }
}

@MainActor
final class VoiceAnimationPreferencesTests: XCTestCase {
    func testAnimationStyleOrderByPurpose() {
        XCTAssertEqual(
            VoiceAnimationPreferences.dictationStyles,
            [.cursorWaveform, .gradientIsland, .notchShelf]
        )
        XCTAssertEqual(
            VoiceAnimationPreferences.recordingStyles,
            [.verticalRecorder, .gradientIsland, .notchShelf]
        )
    }

    func testDefaultsToCursorWaveform() throws {
        let suiteName = "VoiceAnimationPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = VoiceAnimationPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedStyle, .cursorWaveform)
        XCTAssertEqual(preferences.recordingStyle, .gradientIsland)
    }

    func testPersistsGradientIslandSelection() throws {
        let suiteName = "VoiceAnimationPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var preferences: VoiceAnimationPreferences? = VoiceAnimationPreferences(
            defaults: defaults
        )
        preferences?.selectedStyle = .gradientIsland
        preferences = nil

        let restored = VoiceAnimationPreferences(defaults: defaults)
        XCTAssertEqual(restored.selectedStyle, .gradientIsland)
    }

    func testPersistsNotchShelfSelection() throws {
        let suiteName = "VoiceAnimationPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var preferences: VoiceAnimationPreferences? = VoiceAnimationPreferences(
            defaults: defaults
        )
        preferences?.selectedStyle = .notchShelf
        preferences = nil

        let restored = VoiceAnimationPreferences(defaults: defaults)
        XCTAssertEqual(restored.selectedStyle, .notchShelf)
    }

    func testPersistsRecordingSelectionSeparately() throws {
        let suiteName = "VoiceAnimationPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var preferences: VoiceAnimationPreferences? = VoiceAnimationPreferences(
            defaults: defaults
        )
        preferences?.selectedStyle = .cursorWaveform
        preferences?.recordingStyle = .notchShelf
        preferences = nil

        let restored = VoiceAnimationPreferences(defaults: defaults)
        XCTAssertEqual(restored.selectedStyle, .cursorWaveform)
        XCTAssertEqual(restored.recordingStyle, .notchShelf)
    }

    func testPersistsVerticalRecorderSelection() throws {
        let suiteName = "VoiceAnimationPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var preferences: VoiceAnimationPreferences? = VoiceAnimationPreferences(
            defaults: defaults
        )
        preferences?.recordingStyle = .verticalRecorder
        preferences = nil

        let restored = VoiceAnimationPreferences(defaults: defaults)
        XCTAssertEqual(restored.recordingStyle, .verticalRecorder)
    }
}

@MainActor
final class VoiceSoundPreferencesTests: XCTestCase {
    func testDefaultsToNativChime() throws {
        let suiteName = "VoiceSoundPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = VoiceSoundPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedStyle, .nativChime)
    }

    func testPersistsSharedCaptureSound() throws {
        let suiteName = "VoiceSoundPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var preferences: VoiceSoundPreferences? = VoiceSoundPreferences(
            defaults: defaults
        )
        preferences?.selectedStyle = .minimalPlay
        preferences = nil

        let restored = VoiceSoundPreferences(defaults: defaults)
        XCTAssertEqual(restored.selectedStyle, .minimalPlay)
    }

    func testMigratesLegacyRecordingSoundWhenNoSharedChoiceExists() throws {
        let suiteName = "VoiceSoundPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("minimalPlay", forKey: "audioRecordingSoundStyle")

        let preferences = VoiceSoundPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedStyle, .minimalPlay)
    }

    func testUnknownStoredSoundFallsBackToNativChime() throws {
        let suiteName = "VoiceSoundPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("future-sound", forKey: "voiceCaptureSoundStyle")

        let preferences = VoiceSoundPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedStyle, .nativChime)
    }
}

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

private struct VoiceStoredPreferencesPayload: Codable {
    let recordShortcut: VoiceShortcut
    let retryShortcut: VoiceShortcut
    let isHandsFreeEnabled: Bool?
}

@MainActor
final class VoiceShortcutPreferencesTests: XCTestCase {
    func testDefaultsMatchExistingVoiceCommands() {
        XCTAssertEqual(VoiceShortcut.recordDefault.displayName, "Fn + Control")
        XCTAssertEqual(VoiceShortcut.retryDefault.displayName, "Fn + R")

        let suiteName = "VoiceShortcutPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(
            VoiceShortcutPreferences(defaults: defaults).isHandsFreeEnabled
        )
    }

    func testConvertsSystemModifierFlagsForGlobalPolling() {
        XCTAssertEqual(
            VoiceShortcutModifiers(
                cgEventFlags: [.maskSecondaryFn, .maskControl, .maskShift]
            ),
            [.function, .control, .shift]
        )
    }

    func testPersistsCustomShortcuts() throws {
        let suiteName = "VoiceShortcutPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var preferences: VoiceShortcutPreferences? = VoiceShortcutPreferences(
            defaults: defaults
        )
        let shortcut = VoiceShortcut(
            keyCode: 11,
            keyDisplay: "B",
            modifiers: [.command, .shift]
        )
        preferences?.recordShortcut = shortcut
        preferences?.isHandsFreeEnabled = false
        preferences = nil

        let restored = VoiceShortcutPreferences(defaults: defaults)
        XCTAssertEqual(restored.recordShortcut, shortcut)
        XCTAssertEqual(restored.retryShortcut, .retryDefault)
        XCTAssertFalse(restored.isHandsFreeEnabled)
    }

    func testRetiresLegacyHandsFreeShortcutAndDefaultsModeOn() throws {
        struct LegacyPayload: Codable {
            let recordShortcut: VoiceShortcut
            let retryShortcut: VoiceShortcut
            let handsFreeShortcut: VoiceShortcut
        }

        let suiteName = "VoiceShortcutPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let payload = LegacyPayload(
            recordShortcut: .recordDefault,
            retryShortcut: .retryDefault,
            handsFreeShortcut: VoiceShortcut(
                keyCode: 49,
                keyDisplay: "Space",
                modifiers: [.option]
            )
        )
        defaults.set(
            try JSONEncoder().encode(payload),
            forKey: "voiceShortcutPreferences.v1"
        )

        let restored = VoiceShortcutPreferences(defaults: defaults)
        XCTAssertEqual(restored.recordShortcut, .recordDefault)
        XCTAssertEqual(restored.retryShortcut, .retryDefault)
        XCTAssertTrue(restored.isHandsFreeEnabled)
    }




    func testAddsHandsFreeModeDefaultToLegacyPreferences() throws {
        struct LegacyPayload: Codable {
            let recordShortcut: VoiceShortcut
            let retryShortcut: VoiceShortcut
        }

        let suiteName = "VoiceShortcutPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let customRecord = VoiceShortcut(
            keyCode: 11,
            keyDisplay: "B",
            modifiers: [.command, .shift]
        )
        let payload = LegacyPayload(
            recordShortcut: customRecord,
            retryShortcut: .retryDefault
        )
        defaults.set(
            try JSONEncoder().encode(payload),
            forKey: "voiceShortcutPreferences.v1"
        )

        let restored = VoiceShortcutPreferences(defaults: defaults)
        XCTAssertEqual(restored.recordShortcut, customRecord)
        XCTAssertEqual(restored.retryShortcut, .retryDefault)
        XCTAssertTrue(restored.isHandsFreeEnabled)
    }
}


private final class DiarizedURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let metadata = #"{"model":"diarizer","revision":null,"segments":[{"start":0,"end":2,"speaker":7}],"speaker_ids":{"A":7}}"#
        let segment = #"{"type":"transcript.text.segment","id":"seg_0","start":0,"end":1,"text":"Hello","speaker":"A","speakers":["A"]}"#
        var events = ["{\"type\":\"diarization.completed\",\"diarization\":\(metadata)}", segment]
        switch request.url?.host {
        case "truncated": break
        case "failed": events.append(#"{"type":"error","error":{"message":"ASR failed"}}"#)
        case "duplicate": events.append(segment)
        case "invalid-time": events.append(segment.replacingOccurrences(of: #""id":"seg_0""#, with: #""id":"seg_1""#).replacingOccurrences(of: #""start":0"#, with: #""start":-1"#))
        default: events.append("{\"type\":\"transcript.text.done\",\"text\":\"Hello\",\"duration\":2,\"diarization\":\(metadata)}")
        }
        let data = Data(events.map { "data: \($0)\n\n" }.joined().utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: data.count, by: 17) {
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + 17, data.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
