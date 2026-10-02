@preconcurrency import AVFoundation
import ScreenCaptureKit
import XCTest

@MainActor
final class SystemAudioMeetingRecorderTests: XCTestCase {
    func testAlreadyStoppedStreamStillProducesPlayableAudio() async throws {
        try await verifySavedAudio(stopError: SCStreamError.Code.attemptToStopStreamState)
    }

    func testNormalStopStillProducesPlayableAudioWithoutInterruption() async throws {
        try await verifySavedAudio(stopError: nil)
    }

    func testMarkedInterruptionStillProducesPlayableAudioWhenStoppingFails() async throws {
        try await verifySavedAudio(stopError: .failedToStopAudioCapture, prepareForInterruption: true)
    }

    func testStreamDelegateInterruptionSavesWithoutStoppingStreamAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SystemAudioMeetingRecorder()
        let stream = StoppedMeetingTestStream(
            filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: recorder
        )
        let interrupted = expectation(description: "Recorder reports interrupted capture")
        recorder.onInterruption = { interrupted.fulfill() }
        try await recorder.start(stream: stream, outputURL: directory.appendingPathComponent("recording.wav"))
        try stream.deliverAudio()

        recorder.stream(stream, didStopWithError: NSError(domain: SCStreamError.errorDomain, code: -3805))
        await fulfillment(of: [interrupted], timeout: 1)
        XCTAssertFalse(recorder.isRecording)
        let savedURL = try await recorder.stop()

        XCTAssertEqual(stream.stopCallCount, 0)
        XCTAssertGreaterThan(try AVAudioFile(forReading: savedURL).length, 0)
    }

    func testInterruptionDuringStartupThrowsAndAllowsAnotherRecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SystemAudioMeetingRecorder()
        let stream = StoppedMeetingTestStream(
            filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: recorder
        )
        let failure = NSError(domain: SCStreamError.errorDomain, code: -3805)
        stream.beforeStartCompletion = { [weak stream] in
            guard let stream else { return }
            recorder.stream(stream, didStopWithError: failure)
            // Keep framework startup pending while the delegate's main-actor task runs.
            try? await Task.sleep(for: .milliseconds(50))
        }
        let outputURL = directory.appendingPathComponent("interrupted.wav")
        do {
            try await recorder.start(stream: stream, outputURL: outputURL)
            XCTFail("Startup must report the interruption instead of entering the recording state")
        } catch {
            XCTAssertEqual(error as NSError, failure)
        }
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("interrupted.audio.mov").path))
        XCTAssertEqual(stream.removedOutputTypes, [.audio, .microphone])

        let nextStream = StoppedMeetingTestStream(
            filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: recorder
        )
        try await recorder.start(stream: nextStream, outputURL: directory.appendingPathComponent("retry.wav"))
        XCTAssertTrue(recorder.isRecording)
        try nextStream.deliverAudio()
        let savedURL = try await recorder.stop()
        XCTAssertGreaterThan(try AVAudioFile(forReading: savedURL).length, 0)
    }

    private func verifySavedAudio(
        stopError: SCStreamError.Code?,
        prepareForInterruption: Bool = false
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("recording.wav")
        let recorder = SystemAudioMeetingRecorder()
        let stream = StoppedMeetingTestStream(
            filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: recorder
        )
        stream.stopError = stopError.map { NSError(domain: SCStreamError.errorDomain, code: $0.rawValue) }
        var interruptions = 0
        recorder.onInterruption = { interruptions += 1 }

        try await recorder.start(stream: stream, outputURL: outputURL)
        try stream.deliverAudio()
        if prepareForInterruption {
            recorder.prepareForInterruption()
        }
        let savedURL = try await recorder.stop()

        XCTAssertEqual(savedURL, outputURL)
        XCTAssertEqual(stream.stopCallCount, 1)
        XCTAssertEqual(interruptions, stopError == nil || prepareForInterruption ? 0 : 1)
        XCTAssertFalse(recorder.isRecording)
        let audio = try AVAudioFile(forReading: savedURL)
        XCTAssertGreaterThan(audio.length, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recording.audio.mov").path))
    }
}

/// Exercises the real writer/exporter without opening a display or microphone.
private final class StoppedMeetingTestStream: SCStream, @unchecked Sendable {
    var stopError: NSError?
    var beforeStartCompletion: (@Sendable () async -> Void)?
    private(set) var stopCallCount = 0
    private(set) var removedOutputTypes: [SCStreamOutputType] = []
    private var audioOutput: (any SCStreamOutput)?
    private var audioQueue: DispatchQueue?

    override func addStreamOutput(
        _ output: any SCStreamOutput,
        type: SCStreamOutputType,
        sampleHandlerQueue: DispatchQueue?
    ) throws {
        if type == .microphone {
            audioOutput = output
            audioQueue = sampleHandlerQueue
        }
    }

    override func removeStreamOutput(_ output: any SCStreamOutput, type: SCStreamOutputType) throws {
        removedOutputTypes.append(type)
    }

    override func startCapture(completionHandler: (@Sendable ((any Error)?) -> Void)? = nil) {
        if let beforeStartCompletion {
            Task {
                await beforeStartCompletion()
                completionHandler?(nil)
            }
            return
        }
        completionHandler?(nil)
    }

    override func stopCapture(completionHandler: (@Sendable ((any Error)?) -> Void)? = nil) {
        stopCallCount += 1
        completionHandler?(stopError)
    }

    func deliverAudio() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.2
        }
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        ), noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description,
            sampleCount: Int(buffer.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample
        ), noErr)
        let sampleBuffer = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList
        ), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(sampleBuffer), noErr)
        try XCTUnwrap(audioQueue).sync {
            audioOutput?.stream?(self, didOutputSampleBuffer: sampleBuffer, of: .microphone)
        }
    }
}
