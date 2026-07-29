import XCTest

@MainActor
final class VoiceShortcutPreferencesTests: XCTestCase {
    func testDefaultsMatchExistingVoiceCommands() {
        XCTAssertEqual(VoiceShortcut.recordDefault.displayName, "Fn + Control")
        XCTAssertEqual(VoiceShortcut.retryDefault.displayName, "Fn + R")
        XCTAssertEqual(VoiceShortcut.handsFreeDefault.displayName, "Option")
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
        let handsFreeShortcut = VoiceShortcut(
            keyCode: 49,
            keyDisplay: "Space",
            modifiers: [.option]
        )
        preferences?.recordShortcut = shortcut
        preferences?.handsFreeShortcut = handsFreeShortcut
        preferences = nil

        let restored = VoiceShortcutPreferences(defaults: defaults)
        XCTAssertEqual(restored.recordShortcut, shortcut)
        XCTAssertEqual(restored.retryShortcut, .retryDefault)
        XCTAssertEqual(restored.handsFreeShortcut, handsFreeShortcut)
    }

    func testAddsHandsFreeDefaultToLegacyPreferences() throws {
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
        XCTAssertEqual(restored.handsFreeShortcut, .handsFreeDefault)
    }
}
