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

final class AudioInputSampleReceiverTests: XCTestCase {
    func testNativePCMFormatsReachMeterAndRecordingWithoutChangingRateOrChannels() throws {
        for commonFormat in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16] {
            for interleaved in [false, true] {
                for rate in [24_000.0, 48_000.0] {
                    let format = try XCTUnwrap(AVAudioFormat(
                        commonFormat: commonFormat, sampleRate: rate, channels: 2, interleaved: interleaved
                    ))
                    let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
                    pcm.frameLength = 240
                    for channel in 0..<2 {
                        for frame in 0..<240 {
                            if commonFormat == .pcmFormatFloat32 {
                                pcm.floatChannelData![channel][frame * pcm.stride] = 0.25
                            } else {
                                pcm.int16ChannelData![channel][frame * pcm.stride] = 8_192
                            }
                        }
                    }
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
                    defer { try? FileManager.default.removeItem(at: url) }
                    let writer = VoiceAudioRecordingWriter(outputURL: url)
                    let meter = RealtimeAudioMeter(profile: .recording)
                    let delivery = AudioInputCaptureDelivery(tap: VoiceAudioRecorder.makeTap(writer: writer, realtimeMeter: meter))
                    let receiver = AudioInputSampleReceiver(delivery: delivery) { error in
                        XCTFail("Sample conversion failed: \(error)")
                    }
                    receiver.consume(try sampleBuffer(from: pcm))
                    delivery.stop()
                    receiver.consume(try sampleBuffer(from: pcm))
                    writer.finish()
                    let file = try AVAudioFile(forReading: url)
                    XCTAssertEqual(file.length, 240)
                    XCTAssertEqual(file.processingFormat.sampleRate, rate)
                    XCTAssertEqual(file.processingFormat.channelCount, 2)
                    let result = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 240))
                    try file.read(into: result)
                    XCTAssertEqual(result.floatChannelData![0][239], 0.25, accuracy: 0.00001)
                    XCTAssertEqual(result.floatChannelData![1][239], 0.25, accuracy: 0.00001)
                    XCTAssertGreaterThan(try XCTUnwrap(meter.snapshot(after: 0)).level, 0)
                }
            }
        }
    }

    private func sampleBuffer(from pcm: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid
        )
        XCTAssertEqual(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: pcm.format.formatDescription,
            sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        ), noErr)
        let result = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(
            result, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList
        ), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
        return result
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
final class AudioInputCaptureSessionTests: XCTestCase {
    func testSelectionReusesCaptureAndStopSuppressesLateAudioAndErrors() async throws {
        let capture = AudioInputCaptureProbe()
        var creations = 0
        let session = AudioInputCaptureSession {
            creations += 1
            return capture
        }
        let meter = RealtimeAudioMeter(profile: .inputMonitor)
        try await session.start(deviceUniqueID: "first", tap: AudioInputLevelMonitor.makeTap(realtimeMeter: meter)) { _ in
            XCTFail("A stopped capture reported a late failure")
        }
        try await session.select(deviceUniqueID: "second")
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(capture.deviceUniqueID, "second")
        XCTAssertEqual(capture.stopCount, 0)
        session.stop()
        capture.deliver(sampleRate: 48_000, channels: 1, frames: 1_024)
        capture.fail()
        await Task.yield()
        XCTAssertNil(meter.snapshot(after: 0))
    }

    func testFailedSelectionLeavesPreviousCaptureRunning() async throws {
        let capture = AudioInputCaptureProbe()
        let session = AudioInputCaptureSession { capture }
        try await session.start(deviceUniqueID: "first", tap: { _, _ in }) { _ in XCTFail() }
        defer { session.stop() }
        capture.failsSelection = true
        do {
            try await session.select(deviceUniqueID: "missing")
            XCTFail("Unavailable selection succeeded")
        } catch {}
        XCTAssertEqual(capture.deviceUniqueID, "first")
        XCTAssertTrue(capture.isRunning)
        XCTAssertEqual(capture.stopCount, 0)
    }

    func testStopDuringStartupCannotReviveRecording() async throws {
        let capture = AudioInputCaptureProbe()
        capture.suspendsStart = true
        let session = AudioInputCaptureSession { capture }
        let recorder = VoiceAudioRecorder(inputSession: session)
        let url = try temporaryDirectory().appendingPathComponent("cancelled.wav")
        let start = Task { try await recorder.start(outputURL: url) }
        while capture.startContinuation == nil { await Task.yield() }
        XCTAssertNil(recorder.stop())
        capture.resumeStart()
        do {
            _ = try await start.value
            XCTFail("Cancelled recording started")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNewStartWaitsForPreviousCaptureToStop() async throws {
        let first = AudioInputCaptureProbe()
        first.suspendsStart = true
        let second = AudioInputCaptureProbe()
        var creations = 0
        let session = AudioInputCaptureSession {
            creations += 1
            return creations == 1 ? first : second
        }
        let start = Task { try await session.start(deviceUniqueID: "first", tap: { _, _ in }) { _ in XCTFail() } }
        while first.startContinuation == nil { await Task.yield() }
        session.stop()
        let replacement = Task { try await session.start(deviceUniqueID: "second", tap: { _, _ in }) { _ in XCTFail() } }
        await Task.yield()
        XCTAssertFalse(second.isRunning)
        first.resumeStart()
        _ = await start.result
        try await replacement.value
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertTrue(second.isRunning)
        session.stop()
    }

    func testRecordingContinuesAcrossDeviceFormatChange() async throws {
        let outputURL = try temporaryDirectory().appendingPathComponent("recording.wav")
        let capture = AudioInputCaptureProbe()
        let session = AudioInputCaptureSession { capture }
        let recorder = VoiceAudioRecorder(inputSession: session)
        recorder.onRecordingFailure = { error, _ in XCTFail("Unexpected failure: \(error)") }
        try await recorder.start(outputURL: outputURL)
        capture.deliver(sampleRate: 48_000, channels: 1, frames: 4_800)
        try await session.select(deviceUniqueID: "second")
        capture.deliver(sampleRate: 24_000, channels: 1, frames: 2_400)
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(capture.stopCount, 0)
        XCTAssertEqual(recorder.stop(), outputURL)
        XCTAssertEqual(recorder.lastRecordingDuration ?? 0, 0.2, accuracy: 0.001)
        let file = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length) / 48_000, 0.2, accuracy: 0.001)
    }

    func testCaptureFailurePreservesPartialRecordingWithoutRetrying() async throws {
        let outputURL = try temporaryDirectory().appendingPathComponent("recording.wav")
        let capture = AudioInputCaptureProbe()
        var creations = 0
        let session = AudioInputCaptureSession {
            creations += 1
            return capture
        }
        let recorder = VoiceAudioRecorder(inputSession: session)
        let failed = expectation(description: "Recorder stopped with partial audio")
        recorder.onRecordingFailure = { _, savedURL in
            XCTAssertEqual(savedURL, outputURL)
            failed.fulfill()
        }
        try await recorder.start(outputURL: outputURL)
        capture.deliver(sampleRate: 48_000, channels: 1, frames: 4_800)
        capture.fail()
        capture.fail()
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(creations, 1)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.lastRecordingDuration ?? 0, 0.1, accuracy: 0.000001)
        XCTAssertEqual(try AVAudioFile(forReading: outputURL).length, 4_800)
    }

    func testWriteFailureStopsRecordingAndNotifiesOnce() async throws {
        let directory = try temporaryDirectory()
        let first = AudioInputCaptureProbe()
        let session = AudioInputCaptureSession { first }
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
        let first = AudioInputCaptureProbe()
        let second = AudioInputCaptureProbe()
        var creations = 0
        let session = AudioInputCaptureSession {
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
        XCTAssertNil(recorder.stop())
        XCTAssertNotNil(recorder.lastRecordingError)

        let newURL = directory.appendingPathComponent("new.wav")
        try await recorder.start(outputURL: newURL)
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
private final class AudioInputCaptureProbe: AudioInputCaptureDriving {
    var isRunning = false
    var stopCount = 0
    var deviceUniqueID: String?
    var failsSelection = false
    var suspendsStart = false
    var startContinuation: CheckedContinuation<Void, Never>?
    private var delivery: AudioInputCaptureDelivery?
    private var onFailure: (@Sendable (Error) -> Void)?

    func start(
        deviceUniqueID: String?, delivery: AudioInputCaptureDelivery,
        onFailure: @escaping @Sendable (Error) -> Void
    ) async throws {
        self.deviceUniqueID = deviceUniqueID
        self.delivery = delivery
        self.onFailure = onFailure
        if suspendsStart {
            await withCheckedContinuation { startContinuation = $0 }
        }
        isRunning = true
    }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func select(deviceUniqueID: String?) async throws {
        if failsSelection { throw VoiceAudioRecorderError.inputDeviceUnavailable }
        self.deviceUniqueID = deviceUniqueID
    }

    func stop() async {
        stopCount += 1
        isRunning = false
    }

    func fail() {
        onFailure?(VoiceAudioRecorderError.inputDeviceUnavailable)
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
        delivery?.submit(buffer, at: AVAudioTime(hostTime: 0))
    }
}
