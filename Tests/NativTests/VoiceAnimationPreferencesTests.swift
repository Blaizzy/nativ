import XCTest

@MainActor
final class VoiceAnimationPreferencesTests: XCTestCase {
    func testDefaultsToCursorWaveform() throws {
        let suiteName = "VoiceAnimationPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = VoiceAnimationPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedStyle, .cursorWaveform)
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
}
