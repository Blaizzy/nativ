import AVFoundation
import Foundation
import Testing

struct VoiceWakeWordTests {
    @Test func testWindowSkipsSilenceAndExpiresSpeechAfterHangover() {
        var window = VoiceWakeWordWindow()
        var scoringBoundaries = 0
        for _ in 0..<32_000 {
            if window.append(0) { scoringBoundaries += 1 }
        }
        #expect(scoringBoundaries == 0)
        for _ in 0..<3_200 {
            if window.append(0.1) { scoringBoundaries += 1 }
        }
        #expect(scoringBoundaries == 9)
        for _ in 0..<9_600 {
            if window.append(0) { scoringBoundaries += 1 }
        }
        #expect(scoringBoundaries == 33)
        let audio = window.snapshot()
        #expect(audio.count == 32_000)
        #expect(audio.suffix(9_600).allSatisfy { $0 == 0 })
        #expect(audio.dropLast(9_600).suffix(3_200).allSatisfy { $0 == 0.1 })
    }

    @Test func testWindowDoesNotOpenForASingleEnergyFrame() {
        var window = VoiceWakeWordWindow()
        var scoringBoundaries = 0
        for _ in 0..<320 {
            if window.append(0.1) { scoringBoundaries += 1 }
        }
        for _ in 0..<32_000 {
            if window.append(0) { scoringBoundaries += 1 }
        }
        #expect(scoringBoundaries == 0)
    }

    private func expectGate(_ gate: inout VoiceWakeWordEnergyGate, power: Double, open: Bool) {
        let active = gate.consume(power: power)
        #expect(active == open)
    }

    @Test func testGateLearnsSteadyBackgroundAboveTheOldThreshold() {
        var gate = VoiceWakeWordEnergyGate()
        let background = pow(10.0, -4.5) // -45 dBFS would keep the old gate open.
        for _ in 0..<250 { _ = gate.consume(power: background) }
        for _ in 0..<250 { expectGate(&gate, power: background, open: false) }

        // A speech burst above the learned floor still gets the 40 ms attack.
        expectGate(&gate, power: background * 9, open: false)
        expectGate(&gate, power: background * 9, open: true)
        for _ in 0..<18 { expectGate(&gate, power: background * 9, open: true) }
        for _ in 0..<24 { expectGate(&gate, power: background, open: true) }
        expectGate(&gate, power: background, open: false)
    }

    @Test func testGateRecoversQuietSpeechAfterBackgroundStops() {
        var gate = VoiceWakeWordEnergyGate()
        for _ in 0..<300 { _ = gate.consume(power: 1e-4) }
        for _ in 0..<30 { _ = gate.consume(power: 1e-8) }
        expectGate(&gate, power: 2e-5, open: false)
        for _ in 0..<90 { expectGate(&gate, power: 2e-5, open: true) }
    }

    @Test func testGateAllowsImmediateSpeechWithoutWaitingForCalibration() {
        var gate = VoiceWakeWordEnergyGate()
        expectGate(&gate, power: 2e-5, open: false)
        for _ in 0..<98 { expectGate(&gate, power: 2e-5, open: true) }
    }

    @Test func testGateSettlesAfterTheBackgroundGetsLouder() {
        var gate = VoiceWakeWordEnergyGate()
        for _ in 0..<250 { _ = gate.consume(power: 1e-8) }
        for _ in 0..<300 { _ = gate.consume(power: 1e-4) }
        for _ in 0..<100 { expectGate(&gate, power: 1e-4, open: false) }
    }

    @Test func testFeatureExtractionHandlesSilenceAndRejectsInvalidSamples() throws {
        let features = try VoiceWakeWordFeatures()
        let silence = try features.compute([Float](repeating: 0, count: 32_000))
        #expect(silence.count == 128 * 200)
        #expect(silence.allSatisfy { $0 == 0 })
        #expect(throws: VoiceWakeWordModelError.self) { try features.compute([0]) }
        #expect(throws: VoiceWakeWordModelError.self) {
            try features.compute([Float](repeating: .nan, count: 32_000))
        }
    }

    @Test func testBundledModelDetectsIsolatedAndContinuousWakePhrases() throws {
        let bundle = Bundle(for: WakeWordTestBundle.self)
        let url = try #require(bundle.url(forResource: "HeyNativ", withExtension: "mlmodelc"))
        for name in ["hey-native", "hey-native-continuous-short", "hey-native-continuous-long"] {
            let detector = try VoiceWakeWordModel(url: url)
            let audioURL = try #require(bundle.url(forResource: name, withExtension: "wav", subdirectory: "WakeWord"))
            let file = try AVAudioFile(forReading: audioURL)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_600))
            var offset: Int64 = 0
            var detected = false
            while file.framePosition < file.length {
                try file.read(into: buffer)
                let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                if try detector.consume(.init(samples: samples, offset: offset)) { detected = true; break }
                offset += Int64(samples.count)
            }
            #expect(detected, "Missed wake candidate for \(name)")
        }
    }

    @Test(arguments: [false, true])
    func testBundledModelRetainsQuietAndDistantLikeWakePhrases(reverberant: Bool) throws {
        let bundle = Bundle(for: WakeWordTestBundle.self)
        let modelURL = try #require(bundle.url(forResource: "HeyNativ", withExtension: "mlmodelc"))
        let audioURL = try #require(bundle.url(forResource: "hey-native-continuous-short", withExtension: "wav", subdirectory: "WakeWord"))
        let file = try AVAudioFile(forReading: audioURL)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        var audio = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        if reverberant {
            // A repeatable acoustic stress case, not a physical distance measurement.
            var filtered: Float = 0
            for i in audio.indices {
                filtered += 0.6 * (audio[i] - filtered)
                audio[i] = filtered
            }
            let direct = audio
            for i in 1_120..<audio.count { audio[i] += 0.3 * direct[i - 1_120] }
        }
        audio = audio.map { $0 * 0.1 } // 20 dB quieter than the source fixture.
        let detector = try VoiceWakeWordModel(url: modelURL)
        var detected = false
        for offset in stride(from: 0, to: audio.count, by: 1_600) {
            let samples = Array(audio[offset..<min(audio.count, offset + 1_600)])
            if try detector.consume(.init(samples: samples, offset: Int64(offset))) { detected = true; break }
        }
        #expect(detected)
    }

    @Test func testPreRollAndSpeechDuringConfirmationRemainContiguous() throws {
        var capture = VoiceWakeWordCapture()
        let before = (0..<112_000).map { Float($0) / 200_000 }
        _ = try capture.append(.init(samples: before, offset: 0), detected: true)
        let tail = [Float](repeating: 0.1, count: 9_600)
        let event = try capture.append(.init(samples: tail, offset: 112_000), detected: false)
        guard case let .confirm(id, snapshot) = event else { Issue.record("Missing confirmation"); return }
        #expect(snapshot.samples == Array(before.suffix(36_000)) + tail)
        #expect(!capture.canDetect)
        let during = [Float](repeating: 0.2, count: 32_000)
        let pending = try capture.append(.init(samples: during, offset: 121_600), detected: true)
        #expect(pending == nil)
        let accepted = capture.resolve(id: id, transcription: .init(text: "Hey native, hello", modelID: "test"))
        #expect(accepted == true)
        let silence = [Float](repeating: 0, count: 32_000)
        let finished = try capture.append(.init(samples: silence, offset: 153_600), detected: false)
        guard case let .finished(result) = finished else { Issue.record("Capture did not finish"); return }
        #expect(result.audio.samples == snapshot.samples + during + silence)
        #expect(!result.canReuseConfirmation)
        #expect(capture.finish() == nil)
    }

    @Test func testRejectsConfusableCandidateAndIgnoresStaleConfirmation() throws {
        var capture = VoiceWakeWordCapture()
        _ = try capture.append(.init(samples: [Float](repeating: 0.1, count: 16_000), offset: 0), detected: true)
        let event = try capture.append(.init(samples: [Float](repeating: 0.1, count: 9_600), offset: 16_000), detected: false)
        guard case let .confirm(id, _) = event else { Issue.record("Missing confirmation"); return }
        let rejected = capture.resolve(id: id, transcription: .init(text: "Hey David.", modelID: "test"))
        #expect(rejected == false)
        #expect(!capture.canDetect)
        let stale = capture.resolve(id: id, transcription: .init(text: "Hey native", modelID: "test"))
        #expect(stale == nil)
        #expect(capture.finish() == nil)
        _ = try capture.append(.init(samples: [Float](repeating: 0, count: 32_000), offset: 25_600), detected: false)
        #expect(capture.canDetect)
    }

    @Test func testReusesConfirmationWhenNoSpeechFollowsAndFinishesOnce() throws {
        var capture = VoiceWakeWordCapture()
        _ = try capture.append(.init(samples: [Float](repeating: 0.1, count: 16_000), offset: 0), detected: true)
        let event = try capture.append(.init(samples: [Float](repeating: 0, count: 9_600), offset: 16_000), detected: false)
        guard case let .confirm(id, _) = event else { Issue.record("Missing confirmation"); return }
        _ = capture.resolve(id: id, transcription: .init(text: "Hey nativ, hello there.", modelID: "test"))
        let finishedCapture = capture.finish()
        let result = try #require(finishedCapture)
        #expect(result.canReuseConfirmation)
        #expect(result.confirmation.text == "Hey nativ, hello there.")
        #expect(capture.finish() == nil)
        #expect(!capture.canDetect)
    }

    @Test func testDroppedAudioCannotBeJoinedIntoACandidate() throws {
        var capture = VoiceWakeWordCapture()
        _ = try capture.append(.init(samples: [0.1], offset: 0), detected: true)
        #expect(throws: VoiceWakeWordCapture.Failure.self) {
            try capture.append(.init(samples: [0.1], offset: 10), detected: false)
        }
    }

    @Test func testPendingConfirmationTimesOutAndContinuousCaptureIsCapped() throws {
        for confirmed in [false, true] {
            var capture = VoiceWakeWordCapture()
            _ = try capture.append(.init(samples: [Float](repeating: 0.1, count: 16_000), offset: 0), detected: true)
            let event = try capture.append(.init(samples: [Float](repeating: 0.1, count: 9_600), offset: 16_000), detected: false)
            guard case let .confirm(id, _) = event else { Issue.record("Missing confirmation"); return }
            if confirmed {
                _ = capture.resolve(id: id, transcription: .init(text: "Hey native hello", modelID: "test"))
                let finish = try capture.append(.init(samples: [Float](repeating: 0.1, count: 120 * 16_000), offset: 25_600), detected: false)
                guard case let .finished(result) = finish else { Issue.record("Duration cap failed"); return }
                #expect(result.audio.samples.count <= 36_000 + 120 * 16_000)
            } else {
                #expect(throws: VoiceWakeWordCapture.Failure.self) {
                    try capture.append(.init(samples: [Float](repeating: 0.1, count: 30 * 16_000), offset: 25_600), detected: false)
                }
            }
        }
    }

    @Test func testWavEncodingProducesReadableMonoAudio() throws {
        let audio = VoiceWakeWordAudio(samples: [0, 0.5, -0.5, 1, -1])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wake-test-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try audio.wavData.write(to: url)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 5)
        #expect(file.processingFormat.sampleRate == 16_000)
        #expect(file.processingFormat.channelCount == 1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 5))
        try file.read(into: buffer)
        for i in 0..<5 { #expect(abs(buffer.floatChannelData![0][i] - audio.samples[i]) < 0.0001) }
    }

    @Test func testAudioBridgeConvertsAndOwnsBuffersAcrossDeviceChanges() async throws {
        let outputFormat = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 16_000, channels: 1
        ))
        let (stream, continuation) = AsyncStream<VoiceWakeWordAudioChunk>.makeStream()
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
        var expectedOffset: Int64 = 0
        for await input in stream {
            #expect(!input.samples.isEmpty)
            #expect(input.offset == expectedOffset)
            #expect(abs(input.samples[input.samples.count / 2] - 0.25) <= 0.01)
            expectedOffset += Int64(input.samples.count)
            count += 1
        }
        #expect(count >= 3)
    }
}

private final class WakeWordTestBundle: NSObject {}

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
