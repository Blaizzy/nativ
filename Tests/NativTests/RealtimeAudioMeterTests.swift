import AVFoundation
import Foundation
import Synchronization
import XCTest

final class RealtimeAudioMeterTests: XCTestCase {
    func testInputMonitorProfilePreservesPerBufferSmoothing() throws {
        let meter = RealtimeAudioMeter(profile: .inputMonitor)

        meter.submit(level: 1, elapsed: 0)
        let first = try XCTUnwrap(meter.snapshot(after: 0))
        XCTAssertEqual(first.level, 0.35, accuracy: 0.0001)

        meter.submit(level: 1, elapsed: 0)
        let second = try XCTUnwrap(meter.snapshot(after: first.revision))
        XCTAssertEqual(second.level, 0.5775, accuracy: 0.0001)
    }

    func testRecordingProfilePreservesShapingAndSmoothing() throws {
        let meter = RealtimeAudioMeter(profile: .recording)

        meter.submit(level: 0.5, elapsed: 0.1)
        let snapshot = try XCTUnwrap(meter.snapshot(after: 0))
        let expected = pow(Float(0.5), 0.72) * 0.32

        XCTAssertEqual(snapshot.level, expected, accuracy: 0.0001)
        XCTAssertEqual(snapshot.elapsed, 0.1, accuracy: 0.0001)
    }

    func testLatestReadingReplacesIntermediateReadings() throws {
        let meter = RealtimeAudioMeter(profile: .inputMonitor)

        for index in 1 ... 100 {
            meter.submit(
                level: Float(index) / 100,
                elapsed: TimeInterval(index) / 100
            )
        }

        let snapshot = try XCTUnwrap(meter.snapshot(after: 0))
        XCTAssertEqual(snapshot.elapsed, 1, accuracy: 0.0001)
        XCTAssertNil(meter.snapshot(after: snapshot.revision))
    }

    func testInputMonitorTapRunsFromNonMainQueue() async throws {
        let meter = RealtimeAudioMeter(profile: .inputMonitor)
        let tap = AudioInputLevelMonitor.makeTap(realtimeMeter: meter)

        let ranOnMainThread = await invokeOffMain(tap, amplitude: 0.1)

        XCTAssertFalse(ranOnMainThread)
        XCTAssertGreaterThan(try XCTUnwrap(meter.snapshot(after: 0)).level, 0)
    }

    func testRecorderTapWritesFromNonMainQueue() async throws {
        let writer = VoiceAudioWriterProbe()
        let meter = RealtimeAudioMeter(profile: .recording)
        let tap = VoiceAudioRecorder.makeTap(
            writer: writer,
            realtimeMeter: meter
        )

        let ranOnMainThread = await invokeOffMain(tap, amplitude: 0.25)

        XCTAssertFalse(ranOnMainThread)
        XCTAssertEqual(writer.wasCalledOnMainThread, false)
        let snapshot = try XCTUnwrap(meter.snapshot(after: 0))
        XCTAssertGreaterThan(snapshot.level, 0)
        XCTAssertEqual(snapshot.elapsed, 0.25, accuracy: 0.0001)
    }

    func testRecordingWriterPersistsFramesFromNonMainQueue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("recording.wav")
        let writer = VoiceAudioRecordingWriter(outputURL: outputURL)
        let meter = RealtimeAudioMeter(profile: .recording)
        let tap = VoiceAudioRecorder.makeTap(
            writer: writer,
            realtimeMeter: meter
        )

        let ranOnMainThread = await invokeOffMain(tap, amplitude: 0.25)

        XCTAssertFalse(ranOnMainThread)
        XCTAssertEqual(writer.duration, 1_024.0 / 48_000.0, accuracy: 0.0001)
        let snapshot = try XCTUnwrap(meter.snapshot(after: 0))
        XCTAssertEqual(snapshot.elapsed, writer.duration, accuracy: 0.0001)
        writer.finish()
        let fileSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]
                as? NSNumber
        )
        XCTAssertGreaterThan(fileSize.intValue, 44)
    }

    func testRecordingFileUsesDeliveredSampleRateAndChannelLayout() throws {
        let directory = try makeTemporaryDirectory()
        for sampleRate in [16_000.0, 22_050, 44_100, 48_000, 96_000] {
            for channels: AVAudioChannelCount in [1, 2] {
                for interleaved in [false, true] {
                    let format = try XCTUnwrap(AVAudioFormat(
                        commonFormat: .pcmFormatFloat32,
                        sampleRate: sampleRate,
                        channels: channels,
                        interleaved: interleaved
                    ))
                    let outputURL = directory.appendingPathComponent("\(UUID()).wav")
                    let writer = VoiceAudioRecordingWriter(outputURL: outputURL)
                    let buffer = Self.makeBuffer(amplitude: 0.25, format: format)

                    let measurement = writer.append(buffer)
                    writer.finish()

                    XCTAssertEqual(measurement.duration, 1_024 / sampleRate, accuracy: 0.000001)
                    let file = try AVAudioFile(forReading: outputURL)
                    XCTAssertEqual(file.processingFormat.sampleRate, sampleRate)
                    XCTAssertEqual(file.processingFormat.channelCount, channels)
                    XCTAssertEqual(file.length, 1_024)
                    let recorded = try XCTUnwrap(AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat,
                        frameCapacity: 1_024
                    ))
                    try file.read(into: recorded)
                    for channel in 0 ..< Int(channels) {
                        XCTAssertEqual(recorded.floatChannelData![channel][1_023], 0.25)
                    }
                }
            }
        }
    }

    func testRecordingWriterSkipsEmptyBuffersAndFinishesBeforeLateBuffers() throws {
        let directory = try makeTemporaryDirectory()
        let outputURL = directory.appendingPathComponent("recording.wav")
        let writer = VoiceAudioRecordingWriter(outputURL: outputURL)
        let buffer = Self.makeBuffer(amplitude: 0.25)
        buffer.frameLength = 0

        XCTAssertEqual(writer.append(buffer).duration, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        buffer.frameLength = 1_024
        _ = writer.append(buffer)
        writer.finish()
        let duration = writer.duration
        XCTAssertEqual(writer.append(buffer).duration, duration)
        XCTAssertEqual(try AVAudioFile(forReading: outputURL).length, 1_024)

        let unusedURL = directory.appendingPathComponent("unused.wav")
        let unusedWriter = VoiceAudioRecordingWriter(outputURL: unusedURL)
        unusedWriter.finish()
        XCTAssertEqual(unusedWriter.append(buffer).duration, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unusedURL.path))
    }

    func testRecordingWriterConvertsFormatChangesIntoOneFile() throws {
        let directory = try makeTemporaryDirectory()
        let outputURL = directory.appendingPathComponent("recording.wav")
        let writer = VoiceAudioRecordingWriter(outputURL: outputURL)
        let buffer = Self.makeBuffer(
            amplitude: 0.25,
            format: try XCTUnwrap(AVAudioFormat(
                standardFormatWithSampleRate: 48_000,
                channels: 2
            ))
        )
        let originalDuration = writer.append(buffer).duration

        let differentFormats = [
            AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: true
            ),
        ]
        for format in differentFormats {
            let changedBuffer = Self.makeBuffer(
                amplitude: 0.5,
                format: try XCTUnwrap(format)
            )
            _ = writer.append(changedBuffer)
        }
        writer.finish()
        let file = try AVAudioFile(forReading: outputURL)
        let expectedDuration = originalDuration + 1_024 / 44_100.0 + 2 * 1_024 / 48_000.0
        XCTAssertEqual(writer.duration, expectedDuration, accuracy: 0.001)
        XCTAssertEqual(Double(file.length) / 48_000, expectedDuration, accuracy: 0.001)
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
    }

    func testTapsMeasureAllFramesInInterleavedBuffers() throws {
        let directory = try makeTemporaryDirectory()
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: true
        ))
        let buffer = Self.makeBuffer(amplitude: 0, format: format)
        buffer.floatChannelData![0][1_023 * buffer.stride] = 0.2

        let inputMeter = RealtimeAudioMeter(profile: .inputMonitor)
        AudioInputLevelMonitor.makeTap(realtimeMeter: inputMeter)(
            buffer, AVAudioTime(hostTime: 0)
        )
        let expectedRMS = Float(0.2) / sqrt(Float(2 * 1_024))
        let expectedInputLevel = pow(expectedRMS * 8, 0.65)
        XCTAssertEqual(
            try XCTUnwrap(inputMeter.snapshot(after: 0)).level,
            expectedInputLevel * 0.35,
            accuracy: 0.000001
        )

        let writer = VoiceAudioRecordingWriter(
            outputURL: directory.appendingPathComponent("recording.wav")
        )
        XCTAssertEqual(writer.append(buffer).level, 0.7, accuracy: 0.000001)
        writer.finish()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func invokeOffMain(
        _ tap: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        amplitude: Float
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "com.nativ.tests.audio-tap").async {
                let ranOnMainThread = Thread.isMainThread
                let buffer = Self.makeBuffer(amplitude: amplitude)
                tap(buffer, AVAudioTime(hostTime: 0))
                continuation.resume(returning: ranOnMainThread)
            }
        }
    }

    private static func makeBuffer(
        amplitude: Float,
        format: AVAudioFormat = makeFormat()
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 1_024
        )!
        buffer.frameLength = 1_024
        for channel in 0 ..< Int(format.channelCount) {
            for frame in 0 ..< Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame * buffer.stride] = amplitude
            }
        }
        return buffer
    }

    private static func makeFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
    }
}

@MainActor
final class RealtimeAudioMeterPublisherTests: XCTestCase {
    func testPublisherCoalescesAndDeliversOnlyOnMainActor() async throws {
        let meter = RealtimeAudioMeter(profile: .inputMonitor)
        var deliveries: [RealtimeAudioMeterSnapshot] = []
        var deliveredOffMain = false
        let publisher = Task {
            await RealtimeAudioMeterPublisher.run(
                meter: meter,
                interval: .milliseconds(20)
            ) { snapshot in
                deliveredOffMain = deliveredOffMain || !Thread.isMainThread
                deliveries.append(snapshot)
            }
        }

        await Task.detached {
            for index in 1 ... 100 {
                meter.submit(
                    level: Float(index) / 100,
                    elapsed: TimeInterval(index) / 100
                )
            }
        }.value
        try await Task.sleep(for: .milliseconds(75))
        publisher.cancel()
        await publisher.value

        XCTAssertFalse(deliveredOffMain)
        XCTAssertFalse(deliveries.isEmpty)
        XCTAssertLessThanOrEqual(deliveries.count, 4)
        XCTAssertEqual(deliveries.last?.elapsed ?? 0, 1, accuracy: 0.0001)
    }

    func testCancelledPublisherDoesNotDeliverLateReadings() async throws {
        let meter = RealtimeAudioMeter(profile: .recording)
        var deliveryCount = 0
        let publisher = Task {
            await RealtimeAudioMeterPublisher.run(
                meter: meter,
                interval: .milliseconds(5)
            ) { _ in
                deliveryCount += 1
            }
        }

        publisher.cancel()
        await publisher.value
        meter.submit(level: 1, elapsed: 1)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(deliveryCount, 0)
    }

    func testRepeatedPublisherStartStopDropsLateReadings() async throws {
        var deliveryCount = 0

        for _ in 0 ..< 25 {
            let meter = RealtimeAudioMeter(profile: .inputMonitor)
            let publisher = Task {
                await RealtimeAudioMeterPublisher.run(
                    meter: meter,
                    interval: .milliseconds(2)
                ) { _ in
                    deliveryCount += 1
                }
            }
            publisher.cancel()
            await publisher.value
            meter.submit(level: 1, elapsed: 1)
        }

        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(deliveryCount, 0)
    }

    func testProductionPublishIntervalCapsUpdatesAtFifteenHertz() {
        XCTAssertEqual(
            RealtimeAudioMeterPublisher.publishInterval,
            .nanoseconds(66_666_667)
        )
    }
}

private final class VoiceAudioWriterProbe: VoiceAudioBufferWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var calledOnMainThread: Bool?

    var wasCalledOnMainThread: Bool? {
        lock.withLock { calledOnMainThread }
    }

    func append(_ buffer: AVAudioPCMBuffer) -> VoiceAudioBufferMeasurement {
        lock.withLock {
            calledOnMainThread = Thread.isMainThread
        }
        return VoiceAudioBufferMeasurement(level: 0.75, duration: 0.25)
    }
}

@MainActor
final class AudioInputEngineSessionTests: XCTestCase {
    func testConfigurationChangeRebuildsEngineAndIgnoresOldNotifications() async {
        let first = AudioInputEngineProbe()
        let second = AudioInputEngineProbe()
        let restarted = expectation(description: "Engine restarted")
        second.onStart = { restarted.fulfill() }
        var creations = 0
        let session = AudioInputEngineSession(retryDelays: [.zero]) {
            creations += 1
            return creations == 1 ? first : second
        }
        addTeardownBlock { await session.stop() }
        do {
            try await session.start(deviceUniqueID: "selected-input", tap: { _, _ in }) { error in
                XCTFail("Unexpected recovery failure: \(error)")
            }
        } catch {
            XCTFail("Unexpected start failure: \(error)")
            return
        }
        let staleNotification = first.onConfigurationChange
        first.changeConfiguration()
        staleNotification?()
        await fulfillment(of: [restarted], timeout: 2)
        XCTAssertEqual(creations, 2)
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(second.deviceUniqueID, "selected-input")
        XCTAssertTrue(second.isRunning)
        staleNotification?()
        XCTAssertEqual(creations, 2)
    }

    func testStoppingCancelsPendingRecovery() async throws {
        let first = AudioInputEngineProbe()
        var creations = 0
        let session = AudioInputEngineSession(retryDelays: [.milliseconds(20)]) {
            creations += 1
            return first
        }
        try await session.start(deviceUniqueID: nil, tap: { _, _ in }) { error in
            XCTFail("Stopped session reported a failure: \(error)")
        }
        first.changeConfiguration()
        await session.stop()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(creations, 1)
        XCTAssertFalse(first.isRunning)
    }

    func testRecoveryRetriesThenReportsOneFailure() async throws {
        let first = AudioInputEngineProbe()
        var attempts: [AudioInputEngineProbe] = []
        let failed = expectation(description: "Recovery failure reported")
        let session = AudioInputEngineSession(retryDelays: [.zero, .zero, .zero]) {
            let engine = attempts.isEmpty ? first : AudioInputEngineProbe(failsToStart: true)
            attempts.append(engine)
            return engine
        }
        addTeardownBlock { await session.stop() }
        try await session.start(deviceUniqueID: nil, tap: { _, _ in }) { _ in failed.fulfill() }
        first.changeConfiguration()
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(attempts.count, 4)
        XCTAssertTrue(attempts.allSatisfy { !$0.isRunning && $0.stopCount == 1 })
    }

    func testRecordingContinuesAcrossDeviceFormatChange() async throws {
        let directory = try temporaryDirectory()
        let outputURL = directory.appendingPathComponent("recording.wav")
        let first = AudioInputEngineProbe()
        let second = AudioInputEngineProbe()
        let restarted = expectation(description: "Recording input restarted")
        second.onStart = { restarted.fulfill() }
        var creations = 0
        let session = AudioInputEngineSession(retryDelays: [.zero]) {
            creations += 1
            return creations == 1 ? first : second
        }
        let recorder = VoiceAudioRecorder(inputSession: session)
        recorder.onRecordingFailure = { error, _ in XCTFail("Unexpected failure: \(error)") }
        addTeardownBlock { await recorder.discard() }
        try await recorder.start(outputURL: outputURL)
        first.deliver(sampleRate: 48_000, channels: 1, frames: 4_800)
        first.changeConfiguration()
        await fulfillment(of: [restarted], timeout: 2)
        second.deliver(sampleRate: 44_100, channels: 2, frames: 4_410)
        XCTAssertTrue(recorder.isRecording)
        let savedURL = await recorder.stop()
        XCTAssertEqual(savedURL, outputURL)
        XCTAssertEqual(recorder.lastRecordingDuration ?? 0, 0.2, accuracy: 0.001)
        let file = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length) / 48_000, 0.2, accuracy: 0.001)
    }

    func testRecordingRecoveryFailurePreservesCapturedAudio() async throws {
        let directory = try temporaryDirectory()
        let outputURL = directory.appendingPathComponent("recording.wav")
        let first = AudioInputEngineProbe()
        var creations = 0
        let session = AudioInputEngineSession(retryDelays: [.zero]) {
            creations += 1
            return creations == 1 ? first : AudioInputEngineProbe(failsToStart: true)
        }
        let recorder = VoiceAudioRecorder(inputSession: session)
        let failed = expectation(description: "Recorder stopped with partial audio")
        recorder.onRecordingFailure = { _, savedURL in
            XCTAssertEqual(savedURL, outputURL)
            failed.fulfill()
        }
        try await recorder.start(outputURL: outputURL)
        first.deliver(sampleRate: 48_000, channels: 1, frames: 4_800)
        first.changeConfiguration()
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.lastRecordingDuration ?? 0, 0.1, accuracy: 0.000001)
        XCTAssertEqual(try AVAudioFile(forReading: outputURL).length, 4_800)
    }

    func testWriteFailureStopsRecordingAndNotifiesOnce() async throws {
        let directory = try temporaryDirectory()
        let first = AudioInputEngineProbe()
        let session = AudioInputEngineSession { first }
        let recorder = VoiceAudioRecorder(inputSession: session)
        let failed = expectation(description: "Write failure delivered")
        var failures = 0
        recorder.onRecordingFailure = { _, savedURL in
            failures += 1
            XCTAssertNil(savedURL)
            failed.fulfill()
        }
        try await recorder.start(outputURL: directory.appendingPathComponent("missing/recording.wav"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("missing"))
        first.deliver(sampleRate: 48_000, channels: 1, frames: 1_024)
        first.deliver(sampleRate: 48_000, channels: 1, frames: 1_024)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNotNil(recorder.lastRecordingError)
        XCTAssertEqual(failures, 1)
    }

    func testStoppingExposesWriteFailureAndOldFailureCannotStopNewRecording() async throws {
        let directory = try temporaryDirectory()
        let first = AudioInputEngineProbe()
        let second = AudioInputEngineProbe()
        var creations = 0
        let session = AudioInputEngineSession {
            creations += 1
            return creations == 1 ? first : second
        }
        let recorder = VoiceAudioRecorder(inputSession: session)
        recorder.onRecordingFailure = { error, _ in
            XCTFail("A stopped recording delivered a stale failure: \(error)")
        }
        try await recorder.start(outputURL: directory.appendingPathComponent("missing/recording.wav"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("missing"))
        first.deliver(sampleRate: 48_000, channels: 1, frames: 1_024)
        let failedURL = await recorder.stop()
        XCTAssertNil(failedURL)
        XCTAssertNotNil(recorder.lastRecordingError)

        let newURL = directory.appendingPathComponent("new.wav")
        try await recorder.start(outputURL: newURL)
        addTeardownBlock { await recorder.discard() }
        second.deliver(sampleRate: 48_000, channels: 1, frames: 1_024)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(recorder.isRecording)
        XCTAssertNil(recorder.lastRecordingError)
        let savedURL = await recorder.stop()
        XCTAssertEqual(savedURL, newURL)
    }

    func testStartupRetriesReleaseEachFailedEngine() async throws {
        var attempts: [AudioInputEngineProbe] = []
        let session = AudioInputEngineSession(retryDelays: [.zero, .zero]) {
            let engine = AudioInputEngineProbe(failsToStart: attempts.count < 2)
            attempts.append(engine)
            return engine
        }
        try await session.start(deviceUniqueID: nil, tap: { _, _ in }) { _ in XCTFail() }
        XCTAssertEqual(attempts.count, 3)
        XCTAssertEqual(attempts.map(\.stopCount), [1, 1, 0])
        await session.stop()
        XCTAssertEqual(attempts.map(\.stopCount), [1, 1, 1])
    }

    func testCancelPendingStartCannotAffectReplacement() async throws {
        let gate = AudioInputTestGate()
        let entered = expectation(description: "First start pending")
        let first = AudioInputEngineProbe()
        first.beforeStart = { entered.fulfill(); await gate.wait() }
        let second = AudioInputEngineProbe()
        var creations = 0
        let session = AudioInputEngineSession(retryDelays: []) {
            creations += 1
            return creations == 1 ? first : second
        }
        let pending = Task {
            try await session.start(deviceUniqueID: nil, tap: { _, _ in }) { _ in XCTFail() }
        }
        await fulfillment(of: [entered], timeout: 2)
        await session.stop()
        try await session.start(deviceUniqueID: nil, tap: { _, _ in }) { _ in XCTFail() }
        gate.open()
        do { try await pending.value; XCTFail("Canceled start succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(second.isRunning)
        XCTAssertEqual(first.stopCount, 1)
        await session.stop()
    }

    func testReplacementWaitsForHardwareReleaseAndFileFinalization() async throws {
        let gate = AudioInputTestGate()
        let stopping = expectation(description: "Old hardware stopping")
        let first = AudioInputEngineProbe()
        first.beforeStop = { stopping.fulfill(); await gate.wait() }
        let second = AudioInputEngineProbe()
        var creations = 0
        let session = AudioInputEngineSession(retryDelays: []) {
            creations += 1
            return creations == 1 ? first : second
        }
        let recorder = VoiceAudioRecorder(inputSession: session)
        let folder = try temporaryDirectory()
        let firstURL = folder.appendingPathComponent("first.wav")
        let secondURL = folder.appendingPathComponent("second.wav")
        try await recorder.start(outputURL: firstURL)
        first.deliver(sampleRate: 48_000, channels: 1, frames: 480)
        let finishing = Task { await recorder.stop() }
        await fulfillment(of: [stopping], timeout: 2)
        let starting = Task { try await recorder.start(outputURL: secondURL) }
        await Task.yield()
        XCTAssertEqual(creations, 1)
        XCTAssertTrue(MicrophoneCaptureActivity.shared.isRecording)
        gate.open()
        let savedURL = await finishing.value
        XCTAssertEqual(savedURL, firstURL)
        _ = try await starting.value
        XCTAssertEqual(try AVAudioFile(forReading: firstURL).length, 480)
        XCTAssertTrue(second.isRunning)
        second.deliver(sampleRate: 24_000, channels: 1, frames: 240)
        await recorder.discard()
        XCTAssertFalse(MicrophoneCaptureActivity.shared.isRecording)
    }

    func testStopAlsoCancelsAStartWaitingForPreviousRecordingToFinish() async throws {
        let gate = AudioInputTestGate()
        let stopping = expectation(description: "Hardware release pending")
        let first = AudioInputEngineProbe()
        first.beforeStop = { stopping.fulfill(); await gate.wait() }
        var creations = 0
        let recorder = VoiceAudioRecorder(inputSession: AudioInputEngineSession(retryDelays: []) {
            creations += 1
            return first
        })
        let folder = try temporaryDirectory()
        try await recorder.start(outputURL: folder.appendingPathComponent("first.wav"))
        first.deliver(sampleRate: 48_000, channels: 1, frames: 480)
        let finishing = Task { await recorder.stop() }
        await fulfillment(of: [stopping], timeout: 2)
        let queuedStart = expectation(description: "Replacement requested")
        let starting = Task {
            queuedStart.fulfill()
            return try await recorder.start(outputURL: folder.appendingPathComponent("second.wav"))
        }
        await fulfillment(of: [queuedStart], timeout: 2)
        let queuedStop = expectation(description: "Replacement canceled")
        let stopAgain = Task { queuedStop.fulfill(); return await recorder.stop() }
        await fulfillment(of: [queuedStop], timeout: 2)
        gate.open()
        _ = await finishing.value
        _ = await stopAgain.value
        do { _ = try await starting.value; XCTFail("Stop did not cancel waiting start") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(creations, 1)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.lastRecordingDuration ?? 0, 0.01, accuracy: 0.0001)
    }

    func testBriefRecoveriesHaveABoundedRetryBudget() async throws {
        var engines: [AudioInputEngineProbe] = []
        let failed = expectation(description: "Flapping input eventually fails")
        let session = AudioInputEngineSession(retryDelays: [.zero, .zero]) {
            let engine = AudioInputEngineProbe()
            engines.append(engine)
            return engine
        }
        try await session.start(deviceUniqueID: nil, tap: { _, _ in }) { _ in failed.fulfill() }
        for index in 0..<3 {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while engines.count <= index || engines[index].onConfigurationChange == nil {
                guard ContinuousClock.now < deadline else { XCTFail("Recovery stalled"); return }
                await Task.yield()
            }
            engines[index].changeConfiguration()
        }
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(engines.count, 3)
        XCTAssertTrue(engines.allSatisfy { !$0.isRunning && $0.stopCount == 1 })
        await session.stop()
    }

    func testCancelDuringStartupReleasesRecordingActivity() async throws {
        let gate = AudioInputTestGate()
        let entered = expectation(description: "Recorder starting")
        let engine = AudioInputEngineProbe()
        engine.beforeStart = { entered.fulfill(); await gate.wait() }
        let recorder = VoiceAudioRecorder(inputSession: AudioInputEngineSession(retryDelays: []) { engine })
        let folder = try temporaryDirectory()
        let url = folder.appendingPathComponent("canceled.wav")
        let start = Task { try await recorder.start(outputURL: url) }
        await fulfillment(of: [entered], timeout: 2)
        await recorder.discard()
        gate.open()
        do { _ = try await start.value; XCTFail("Canceled recording started") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(MicrophoneCaptureActivity.shared.isRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCanceledStartupKeepsCapturedAudioForStop() async throws {
        for stopFirst in [false, true] {
            for lateDeviceError in [false, true] {
                let directory = try temporaryDirectory()
                let url = directory.appendingPathComponent("recording.wav")
                let entered = expectation(description: "Audio arrived during startup")
                let gate = AudioInputTestGate()
                let engine = AudioInputEngineProbe()
                engine.beforeReady = { [weak engine] in
                    engine?.deliver(sampleRate: 48_000, channels: 1, frames: 480)
                    entered.fulfill()
                    await gate.wait()
                    if lateDeviceError { throw VoiceAudioRecorderError.inputDeviceUnavailable }
                    try Task.checkCancellation()
                }
                let recorder = VoiceAudioRecorder(inputSession: AudioInputEngineSession(retryDelays: []) { engine })
                recorder.onRecordingFailure = { _, _ in XCTFail("Cancellation reported a recording failure") }
                let startup = Task { try await recorder.start(outputURL: url) }
                await fulfillment(of: [entered], timeout: 2)
                startup.cancel()
                let savedURL: URL?
                if stopFirst {
                    savedURL = await recorder.stop()
                    gate.open()
                } else {
                    gate.open()
                    _ = await startup.result
                    XCTAssertFalse(engine.isRunning)
                    savedURL = await recorder.stop()
                }
                do { _ = try await startup.value; XCTFail("Canceled startup succeeded") }
                catch { XCTAssertTrue(error is CancellationError) }
                XCTAssertEqual(savedURL, url)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                if FileManager.default.fileExists(atPath: url.path) {
                    XCTAssertEqual(try AVAudioFile(forReading: url).length, 480)
                }
                XCTAssertNil(recorder.lastRecordingError)
                XCTAssertEqual(recorder.lastRecordingDuration ?? 0, 0.01, accuracy: 0.0001)
                XCTAssertFalse(recorder.isRecording)
                XCTAssertEqual(engine.stopCount, 1)
                XCTAssertFalse(MicrophoneCaptureActivity.shared.isRecording)
            }
        }
    }

    func testFinishingCanceledEmptyStartupReturnsNoRecording() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("empty.wav")
        let entered = expectation(description: "Startup has no audio yet")
        let gate = AudioInputTestGate()
        let engine = AudioInputEngineProbe()
        engine.beforeReady = {
            entered.fulfill()
            await gate.wait()
            try Task.checkCancellation()
        }
        let recorder = VoiceAudioRecorder(inputSession: AudioInputEngineSession(retryDelays: []) { engine })
        recorder.onRecordingFailure = { _, _ in XCTFail("Empty cancellation reported a failure") }
        let startup = Task { try await recorder.start(outputURL: url) }
        await fulfillment(of: [entered], timeout: 2)
        startup.cancel()
        gate.open()
        _ = await startup.result
        let savedURL = await recorder.stop()
        XCTAssertNil(savedURL)
        XCTAssertNil(recorder.lastRecordingError)
        XCTAssertNil(recorder.lastRecordingDuration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(engine.isRunning)
        XCTAssertFalse(MicrophoneCaptureActivity.shared.isRecording)
    }

    func testExplicitDiscardRemovesAudioFromCanceledStartup() async throws {
        for discardFirst in [false, true] {
            let directory = try temporaryDirectory()
            let url = directory.appendingPathComponent("discarded.wav")
            let entered = expectation(description: "Audio arrived before discard")
            let gate = AudioInputTestGate()
            let engine = AudioInputEngineProbe()
            engine.beforeReady = { [weak engine] in
                engine?.deliver(sampleRate: 48_000, channels: 1, frames: 480)
                entered.fulfill()
                await gate.wait()
                try Task.checkCancellation()
            }
            let recorder = VoiceAudioRecorder(inputSession: AudioInputEngineSession(retryDelays: []) { engine })
            let startup = Task { try await recorder.start(outputURL: url) }
            await fulfillment(of: [entered], timeout: 2)
            startup.cancel()
            if discardFirst {
                await recorder.discard()
                gate.open()
            } else {
                gate.open()
                _ = await startup.result
                await recorder.discard()
            }
            _ = await startup.result
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertFalse(engine.isRunning)
            XCTAssertFalse(MicrophoneCaptureActivity.shared.isRecording)
        }
    }

    func testRecordingActivityRequiresAllOwnersToRelease() async {
        let activity = MicrophoneCaptureActivity()
        let first = UUID(), second = UUID()
        await activity.acquire(first)
        await activity.acquire(second)
        activity.release(first)
        XCTAssertTrue(activity.isRecording)
        activity.release(first)
        XCTAssertTrue(activity.isRecording)
        activity.release(second)
        XCTAssertFalse(activity.isRecording)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}

@MainActor
private final class AudioInputEngineProbe: AudioInputEngineDriving {
    var isRunning = false
    var onConfigurationChange: (() -> Void)?
    var onStart: (() -> Void)?
    var beforeStart: (() async -> Void)?
    var beforeReady: (() async throws -> Void)?
    var beforeStop: (() async -> Void)?
    private var generation = UUID()
    var stopCount = 0
    var deviceUniqueID: String?
    private let failsToStart: Bool
    private var tap: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

    init(failsToStart: Bool = false) { self.failsToStart = failsToStart }

    func start(
        deviceUniqueID: String?,
        tap: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) async throws {
        let request = UUID()
        generation = request
        await beforeStart?()
        guard generation == request else { throw CancellationError() }
        if failsToStart { throw VoiceAudioRecorderError.inputDeviceUnavailable }
        self.deviceUniqueID = deviceUniqueID
        self.tap = tap
        try await beforeReady?()
        guard generation == request else { throw CancellationError() }
        isRunning = true
        onStart?()
    }

    func stop() async {
        generation = UUID()
        await beforeStop?()
        stopCount += 1
        isRunning = false
        tap = nil
    }

    func changeConfiguration() {
        isRunning = false
        onConfigurationChange?()
    }

    func deliver(sampleRate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount) {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0 ..< Int(channels) {
            for frame in 0 ..< Int(frames) {
                buffer.floatChannelData![channel][frame] = 0.25
            }
        }
        tap?(buffer, AVAudioTime(hostTime: 0))
    }
}

@MainActor
private final class AudioInputTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

final class MicrophoneBufferRingTests: XCTestCase {
    func testRingPreservesChannelsFramesAndTimestampsAcrossWraparound() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let ring = try MicrophoneBufferRing(format: format, frameCapacity: 16, capacity: 2)
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        let received = Mutex<[Int]>([])
        for batch in 0..<100 {
            for offset in 0..<2 {
                let index = batch * 2 + offset
                source.frameLength = AVAudioFrameCount(index % 16 + 1)
                for channel in 0..<2 {
                    for frame in 0..<Int(source.frameLength) {
                        source.floatChannelData![channel][frame] = Float(index * 100 + channel * 20 + frame)
                    }
                }
                var timestamp = AudioTimeStamp()
                timestamp.mSampleTime = Double(index)
                timestamp.mFlags = .sampleTimeValid
                ring.push(source, timestamp: timestamp)
            }
            XCTAssertTrue(ring.drain { buffer, time in
                let index = Int(time.sampleTime)
                XCTAssertEqual(buffer.frameLength, AVAudioFrameCount(index % 16 + 1))
                for channel in 0..<2 {
                    for frame in 0..<Int(buffer.frameLength) {
                        XCTAssertEqual(buffer.floatChannelData![channel][frame], Float(index * 100 + channel * 20 + frame))
                    }
                }
                received.withLock { $0.append(index) }
            })
        }
        XCTAssertEqual(received.withLock { $0 }, Array(0..<200))
        XCTAssertFalse(ring.hasOverflowed)
        XCTAssertFalse(ring.drain { _, _ in XCTFail("Drained a buffer twice") })
    }

    func testOverflowDoesNotOverwriteUndeliveredAudio() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let ring = try MicrophoneBufferRing(format: format, frameCapacity: 1, capacity: 2)
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        source.frameLength = 1
        for value in [Float(1), 2, 3] {
            source.floatChannelData![0][0] = value
            ring.push(source, timestamp: AudioTimeStamp())
        }
        XCTAssertTrue(ring.hasOverflowed)
        let samples = Mutex<[Float]>([])
        ring.drain { buffer, _ in samples.withLock { $0.append(buffer.floatChannelData![0][0]) } }
        XCTAssertEqual(samples.withLock { $0 }, [1, 2])
    }

    func testConcurrentProducerAndConsumerDeliverEachBufferOnce() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let count = 10_000
        let ring = try MicrophoneBufferRing(format: format, frameCapacity: 1, capacity: count)
        let producer = Task.detached {
            let source = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!, frameCapacity: 1)!
            source.frameLength = 1
            for index in 0..<count {
                source.floatChannelData![0][0] = Float(index)
                ring.push(source, timestamp: AudioTimeStamp())
            }
        }
        let consumer = Task.detached {
            let samples = Mutex<[Float]>([])
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while samples.withLock({ $0.count }) < count, ContinuousClock.now < deadline {
                ring.drain { buffer, _ in samples.withLock { $0.append(buffer.floatChannelData![0][0]) } }
                await Task.yield()
            }
            return samples.withLock { $0 }
        }
        await producer.value
        let samples = await consumer.value
        XCTAssertEqual(samples, (0..<count).map(Float.init))
        XCTAssertFalse(ring.hasOverflowed)
    }

    func testUnexpectedBufferShapeIsRejectedWithoutPublishing() throws {
        let mono = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let ring = try MicrophoneBufferRing(format: mono, frameCapacity: 16)
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 16))
        source.frameLength = 16
        ring.push(source, timestamp: AudioTimeStamp())
        XCTAssertTrue(ring.hasOverflowed)
        XCTAssertFalse(ring.drain { _, _ in XCTFail("Invalid layout reached receiver") })
    }
}
