import Foundation
import XCTest
@testable import NativServerKit

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
