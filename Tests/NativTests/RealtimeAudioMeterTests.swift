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
        let format = Self.makeFormat()
        let audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let writer = VoiceAudioRecordingWriter(
            audioFile: audioFile,
            sampleRate: format.sampleRate
        )
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
        let fileSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]
                as? NSNumber
        )
        XCTAssertGreaterThan(fileSize.intValue, 44)
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

    private static func makeBuffer(amplitude: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: makeFormat(),
            frameCapacity: 1_024
        )!
        buffer.frameLength = 1_024
        for frame in 0 ..< Int(buffer.frameLength) {
            buffer.floatChannelData![0][frame] = amplitude
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
