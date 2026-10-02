import XCTest

final class VoiceDictationTranscriptTests: XCTestCase {
    func testWakePhraseIsRemovedBeforeTheReturnCommand() {
        let result = VoiceDictationTranscript("Earlier audio. Hey, NATIV! Send the document enter.", wakeWord: true)
        XCTAssertEqual(result.text, "Send the document")
        XCTAssertTrue(result.pressReturn)
        XCTAssertEqual(VoiceDictationTranscript("Hey native, hello there.", wakeWord: true).text, "hello there.")
        for text in ["Hey David hello", "Hey natives hello", "They native hello", "hello there", "Hey native!"] {
            XCTAssertTrue(VoiceDictationTranscript(text, wakeWord: true).isEmpty, text)
        }
        // Keyboard dictation must keep deliberately spoken wake words.
        XCTAssertEqual(VoiceDictationTranscript("Hey native hello.").text, "Hey native hello.")
    }

    func testTrailingEnterBecomesReturnWithoutAppearingInText() {
        let result = VoiceDictationTranscript("Send me the details enter")

        XCTAssertEqual(result.text, "Send me the details")
        XCTAssertTrue(result.pressReturn)
        XCTAssertFalse(result.isEmpty)
    }

    func testRecognizerCapitalizationPunctuationAndWhitespace() {
        for transcript in [
            "  Send me the details ENTER. \n",
            "Send me the details\nEnter!",
            "Send me the details, enter.",
            "Send me the details\tenter…",
            "Send me the details enter?!",
        ] {
            let result = VoiceDictationTranscript(transcript)

            XCTAssertEqual(result.text, "Send me the details", transcript)
            XCTAssertTrue(result.pressReturn, transcript)
        }
    }

    func testKeepsPunctuationBelongingToTheDictatedText() {
        for text in ["All done.", "Are you ready?", "Great!", "Hello 👋", "Dziękuję"] {
            let result = VoiceDictationTranscript("\(text) Enter.")

            XCTAssertEqual(result.text, text)
            XCTAssertTrue(result.pressReturn)
        }
    }

    func testEnterAloneIsAnActionRatherThanEmptySpeech() {
        for transcript in ["enter", "Enter.", " \nENTER!\n "] {
            let result = VoiceDictationTranscript(transcript)

            XCTAssertEqual(result.text, "")
            XCTAssertTrue(result.pressReturn)
            XCTAssertFalse(result.isEmpty)
        }
    }

    func testOnlyTheFinalStandaloneEnterTriggersReturn() {
        for transcript in [
            "Enter the room.",
            "Press enter to continue.",
            "Meet at the center.",
            "Please re-enter.",
            "An event handler named on_enter",
            "enter123",
            "“enter”",
            "Hello there!",
        ] {
            let result = VoiceDictationTranscript(transcript)

            XCTAssertEqual(result.text, transcript)
            XCTAssertFalse(result.pressReturn, transcript)
        }

        let result = VoiceDictationTranscript("Enter the room enter")
        XCTAssertEqual(result.text, "Enter the room")
        XCTAssertTrue(result.pressReturn)
    }

    func testEmptySpeechDoesNotTriggerReturn() {
        for transcript in ["", " \n\t "] {
            let result = VoiceDictationTranscript(transcript)

            XCTAssertEqual(result.text, "")
            XCTAssertFalse(result.pressReturn)
            XCTAssertTrue(result.isEmpty)
        }
    }

    func testDisabledCommandKeepsTheTriggerInTheTranscript() {
        for transcript in ["Send me the details enter.", "Enter."] {
            let result = VoiceDictationTranscript(transcript, returnCommandTrigger: nil)

            XCTAssertEqual(result.text, transcript)
            XCTAssertFalse(result.pressReturn)
        }
    }

    func testCustomTriggerReplacesEnter() {
        let result = VoiceDictationTranscript("All done submit.", returnCommandTrigger: "submit")
        XCTAssertEqual(result.text, "All done")
        XCTAssertTrue(result.pressReturn)

        for transcript in ["All done enter.", "Submit the form.", "Please resubmit."] {
            let result = VoiceDictationTranscript(transcript, returnCommandTrigger: "submit")
            XCTAssertEqual(result.text, transcript)
            XCTAssertFalse(result.pressReturn)
        }
    }

    func testCustomPhrasesTolerateWhitespaceAndCapitalization() {
        for transcript in ["All done, SEND IT!", "All done send\nit.", "All done send   it"] {
            let result = VoiceDictationTranscript(transcript, returnCommandTrigger: "  send  it \n")
            XCTAssertEqual(result.text, "All done")
            XCTAssertTrue(result.pressReturn)
        }

        let commandOnly = VoiceDictationTranscript("Send it.", returnCommandTrigger: "send it")
        XCTAssertEqual(commandOnly.text, "")
        XCTAssertTrue(commandOnly.pressReturn)
        XCTAssertFalse(commandOnly.isEmpty)

        let earlierPhrase = VoiceDictationTranscript("Send it tomorrow.", returnCommandTrigger: "send it")
        XCTAssertEqual(earlierPhrase.text, "Send it tomorrow.")
        XCTAssertFalse(earlierPhrase.pressReturn)
    }

    func testCustomTriggerIsLiteralRatherThanARegularExpression() {
        for trigger in ["send (now)", "go.*", "wyślij"] {
            let result = VoiceDictationTranscript("All done \(trigger).", returnCommandTrigger: trigger)
            XCTAssertEqual(result.text, "All done")
            XCTAssertTrue(result.pressReturn)
        }

        let result = VoiceDictationTranscript("All done goodbye.", returnCommandTrigger: "go.*")
        XCTAssertEqual(result.text, "All done goodbye.")
        XCTAssertFalse(result.pressReturn)
    }

    func testBlankTriggerDoesNotRemoveTextOrPressReturn() {
        for trigger in ["", " \n\t "] {
            let result = VoiceDictationTranscript("All done enter.", returnCommandTrigger: trigger)
            XCTAssertEqual(result.text, "All done enter.")
            XCTAssertFalse(result.pressReturn)
        }
    }
}

@MainActor
final class VoiceReturnCommandPreferencesTests: XCTestCase {
    func testSpokenReturnDefaultsToEnabledWithEnter() async throws {
        let suiteName = "VoiceReturnCommandPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = VoiceShortcutPreferences(defaults: defaults)
        XCTAssertTrue(preferences.isReturnCommandEnabled)
        XCTAssertEqual(preferences.returnCommandTrigger, "enter")
        XCTAssertEqual(preferences.activeReturnCommandTrigger, "enter")
    }

    func testLegacyPreferencesKeepExistingShortcutsAndGainReturnDefaults() async throws {
        struct LegacyPayload: Codable {
            let recordShortcut: VoiceShortcut
            let retryShortcut: VoiceShortcut
            let isHandsFreeEnabled: Bool
        }

        let suiteName = "VoiceReturnCommandPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let customRecord = VoiceShortcut(keyCode: 11, keyDisplay: "B", modifiers: [.command, .shift])
        let payload = LegacyPayload(
            recordShortcut: customRecord,
            retryShortcut: .retryDefault,
            isHandsFreeEnabled: false
        )
        defaults.set(try JSONEncoder().encode(payload), forKey: "voiceShortcutPreferences.v1")

        let preferences = VoiceShortcutPreferences(defaults: defaults)
        XCTAssertEqual(preferences.recordShortcut, customRecord)
        XCTAssertEqual(preferences.retryShortcut, .retryDefault)
        XCTAssertFalse(preferences.isHandsFreeEnabled)
        XCTAssertTrue(preferences.isReturnCommandEnabled)
        XCTAssertEqual(preferences.activeReturnCommandTrigger, "enter")
    }

    func testCustomTriggerAndDisabledStateSurviveReloadAndCanBeReenabled() async throws {
        let suiteName = "VoiceReturnCommandPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = VoiceShortcutPreferences(defaults: defaults)
        preferences.returnCommandTrigger = "send it"
        preferences.isReturnCommandEnabled = false

        let restored = VoiceShortcutPreferences(defaults: defaults)
        XCTAssertEqual(restored.returnCommandTrigger, "send it")
        XCTAssertFalse(restored.isReturnCommandEnabled)
        let disabled = VoiceDictationTranscript(
            "All done send it.",
            returnCommandTrigger: restored.activeReturnCommandTrigger
        )
        XCTAssertEqual(disabled.text, "All done send it.")
        XCTAssertFalse(disabled.pressReturn)

        restored.isReturnCommandEnabled = true
        let enabled = VoiceDictationTranscript(
            "All done send it.",
            returnCommandTrigger: VoiceShortcutPreferences(defaults: defaults).activeReturnCommandTrigger
        )
        XCTAssertEqual(enabled.text, "All done")
        XCTAssertTrue(enabled.pressReturn)
    }

    func testBlankTriggerStaysInactiveAfterReload() async throws {
        let suiteName = "VoiceReturnCommandPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = VoiceShortcutPreferences(defaults: defaults)
        preferences.returnCommandTrigger = "  "

        let restored = VoiceShortcutPreferences(defaults: defaults)
        XCTAssertTrue(restored.isReturnCommandEnabled)
        XCTAssertEqual(restored.returnCommandTrigger, "  ")
        XCTAssertNil(restored.activeReturnCommandTrigger)
    }
}
