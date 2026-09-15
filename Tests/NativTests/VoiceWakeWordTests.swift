import AVFoundation
import Foundation
import Speech
import Testing

struct VoiceWakeWordTests {
    @Test func testPhraseMatchesWholeWordsAndCommonSpelling() {
        for phrase in ["hey nativ", "Hey, Nativ!", "HEY NATIVE.", "Okay, hey nativ"] {
            for isFinal in [false, true] {
                var detector = VoiceWakeWordDetection()
                #expect(detector.consume(phrase, start: 0, end: 1, isFinal: isFinal) == true)
            }
        }
        for phrase in ["nativ", "hey", "hey naturally", "they nativ", "hey nativeborn", "hey my nativ"] {
            var detector = VoiceWakeWordDetection()
            #expect(detector.consume(phrase, start: 0, end: 1, isFinal: true) == false)
        }
    }

    @Test func testPartialRevisionsDoNotAccumulateIntoAPhrase() {
        var detector = VoiceWakeWordDetection()
        #expect(detector.consume("hey", start: 0, end: 1, isFinal: false) == false)
        #expect(detector.consume("native", start: 0, end: 1, isFinal: false) == false)
        #expect(detector.consume("hey native", start: 0, end: 1, isFinal: false) == true)
    }

    @Test func testPhraseCanSpanAdjacentFinalizedSegments() {
        var detector = VoiceWakeWordDetection()
        #expect(detector.consume("hey", start: 0, end: 0.5, isFinal: true) == false)
        #expect(detector.consume("nativ", start: 0.6, end: 1, isFinal: false) == true)
    }

    @Test func testUnrelatedSegmentsDoNotFormPhrase() {
        var detector = VoiceWakeWordDetection()
        #expect(detector.consume("hey", start: 0, end: 0.5, isFinal: true) == false)
        #expect(detector.consume("nativ", start: 4, end: 5, isFinal: true) == false)
        #expect(detector.consume("hey", start: 5, end: 6, isFinal: true) == false)
        #expect(detector.consume("there", start: 6, end: 7, isFinal: true) == false)
        #expect(detector.consume("nativ", start: 7, end: 8, isFinal: true) == false)
    }

    @Test func testSilenceFinishesOnlyAfterSpeechAndResetsWhenSpeakingResumes() {
        var endpoint = VoiceWakeWordEndpoint()
        #expect(endpoint.update(level: 0, elapsed: 2) == nil)
        #expect(endpoint.update(level: 0.4, elapsed: 3) == nil)
        #expect(endpoint.update(level: 0, elapsed: 4.9) == nil)
        #expect(endpoint.update(level: 0.4, elapsed: 5) == nil)
        #expect(endpoint.update(level: 0, elapsed: 6.9) == nil)
        #expect(endpoint.update(level: 0, elapsed: 7) == .finish)
    }

    @Test func testEmptyCaptureCancelsAndIgnoresStartChime() {
        var endpoint = VoiceWakeWordEndpoint()
        #expect(endpoint.update(level: 1, elapsed: 0.3) == nil)
        #expect(endpoint.update(level: 0, elapsed: 9.9) == nil)
        #expect(endpoint.update(level: 0, elapsed: 10) == .cancel)
    }

    @Test func testContinuousNoiseCannotRecordIndefinitely() {
        var endpoint = VoiceWakeWordEndpoint()
        #expect(endpoint.update(level: 0.4, elapsed: 119) == nil)
        #expect(endpoint.update(level: 0.4, elapsed: 120) == .finish)
    }

    @Test func testAudioBridgeConvertsAndOwnsBuffersAcrossDeviceChanges() async throws {
        let outputFormat = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 16_000, channels: 1
        ))
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let bridge = VoiceWakeWordAudioBridge(format: outputFormat, continuation: continuation) {
            Issue.record("Audio conversion failed")
        }
        for rate in [48_000.0, 44_100, 16_000] {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
            buffer.frameLength = 4_096
            for channel in 0..<2 {
                for frame in 0..<4_096 { buffer.floatChannelData![channel][frame] = 0.25 }
            }
            bridge.append(buffer)
            // The microphone reuses its buffers immediately after returning from the tap.
            for channel in 0..<2 {
                for frame in 0..<4_096 { buffer.floatChannelData![channel][frame] = 0 }
            }
        }
        continuation.finish()
        var count = 0
        for await input in stream {
            #expect(input.buffer.format == outputFormat)
            #expect(input.buffer.frameLength > 0)
            let middle = Int(input.buffer.frameLength / 2)
            #expect(abs(input.buffer.floatChannelData![0][middle] - 0.25) <= 0.01)
            count += 1
        }
        #expect(count >= 3)
    }
}

@MainActor
struct VoiceWakeWordPreferencesTests {
    @Test func testWakeWordIsOptInAndPersistsWithoutChangingKeyboardMode() throws {
        let suite = "VoiceWakeWordPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = VoiceShortcutPreferences(defaults: defaults)
        #expect(!preferences.isWakeWordEnabled)
        preferences.isHandsFreeEnabled = false
        preferences.isWakeWordEnabled = true
        let restored = VoiceShortcutPreferences(defaults: defaults)
        #expect(restored.isWakeWordEnabled)
        #expect(!restored.isHandsFreeEnabled)
        #expect(restored.recordShortcut == .recordDefault)
        restored.isWakeWordEnabled = false
        #expect(!VoiceShortcutPreferences(defaults: defaults).isWakeWordEnabled)
    }

    @Test func testLegacyPreferencesKeepListeningOff() throws {
        let suite = "VoiceWakeWordPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy: [String: Any] = [
            "recordShortcut": ["modifiers": VoiceShortcut.recordDefault.modifiers.rawValue],
            "retryShortcut": ["keyCode": 15, "keyDisplay": "R", "modifiers": 16],
            "isHandsFreeEnabled": false,
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "voiceShortcutPreferences.v1")
        let preferences = VoiceShortcutPreferences(defaults: defaults)
        #expect(!preferences.isWakeWordEnabled)
        #expect(!preferences.isHandsFreeEnabled)
    }

    @Test func testDisablingOrSuspendingCancelsPendingListenerStartup() async throws {
        let monitor = VoiceWakeWordMonitor()
        monitor.configure(enabled: true, suspended: false, deviceID: nil)
        #expect(monitor.state == .preparing)
        monitor.configure(enabled: true, suspended: true, deviceID: nil)
        #expect(monitor.state == .paused)
        monitor.configure(enabled: false, suspended: false, deviceID: nil)
        try await Task.sleep(for: .milliseconds(800))
        #expect(monitor.state == .off)
    }
}
