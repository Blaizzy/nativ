import XCTest

@MainActor
final class VoiceShortcutPreferencesTests: XCTestCase {
    func testDefaultsMatchExistingVoiceCommands() {
        XCTAssertEqual(VoiceShortcut.recordDefault.displayName, "Fn + Control")
        XCTAssertEqual(VoiceShortcut.retryDefault.displayName, "Fn + R")
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
        preferences = nil

        let restored = VoiceShortcutPreferences(defaults: defaults)
        XCTAssertEqual(restored.recordShortcut, shortcut)
        XCTAssertEqual(restored.retryShortcut, .retryDefault)
    }
}
