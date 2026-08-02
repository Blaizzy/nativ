import XCTest

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
