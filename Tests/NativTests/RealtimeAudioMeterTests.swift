import AVFoundation
import Foundation
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
        defer { session.stop() }
        do {
            try session.start(deviceUniqueID: "selected-input", tap: { _, _ in }) { error in
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
        try session.start(deviceUniqueID: nil, tap: { _, _ in }) { error in
            XCTFail("Stopped session reported a failure: \(error)")
        }
        first.changeConfiguration()
        session.stop()
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
        defer { session.stop() }
        try session.start(deviceUniqueID: nil, tap: { _, _ in }) { _ in failed.fulfill() }
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
        defer { recorder.stop() }
        try recorder.start(outputURL: outputURL)
        first.deliver(sampleRate: 48_000, channels: 1, frames: 4_800)
        first.changeConfiguration()
        await fulfillment(of: [restarted], timeout: 2)
        second.deliver(sampleRate: 44_100, channels: 2, frames: 4_410)
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(recorder.stop(), outputURL)
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
        try recorder.start(outputURL: outputURL)
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
        try recorder.start(outputURL: directory.appendingPathComponent("missing/recording.wav"))
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
        try recorder.start(outputURL: directory.appendingPathComponent("missing/recording.wav"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("missing"))
        first.deliver(sampleRate: 48_000, channels: 1, frames: 1_024)
        XCTAssertNil(recorder.stop())
        XCTAssertNotNil(recorder.lastRecordingError)

        let newURL = directory.appendingPathComponent("new.wav")
        try recorder.start(outputURL: newURL)
        defer { recorder.stop() }
        second.deliver(sampleRate: 48_000, channels: 1, frames: 1_024)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(recorder.isRecording)
        XCTAssertNil(recorder.lastRecordingError)
        XCTAssertEqual(recorder.stop(), newURL)
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
    var stopCount = 0
    var deviceUniqueID: String?
    private let failsToStart: Bool
    private var tap: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

    init(failsToStart: Bool = false) { self.failsToStart = failsToStart }

    func start(
        deviceUniqueID: String?,
        tap: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        if failsToStart { throw VoiceAudioRecorderError.inputDeviceUnavailable }
        self.deviceUniqueID = deviceUniqueID
        self.tap = tap
        isRunning = true
        onStart?()
    }

    func stop() {
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
