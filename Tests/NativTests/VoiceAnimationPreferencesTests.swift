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
