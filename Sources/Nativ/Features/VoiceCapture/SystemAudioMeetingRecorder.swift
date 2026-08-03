import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum SystemAudioMeetingRecorderError: LocalizedError {
    case noDisplayAvailable
    case recordingDidNotFinish
    case noAudioCaptured
    case couldNotCreateAudioFile

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            "Nativ could not find a display to use for system-audio capture."
        case .recordingDidNotFinish:
            "The meeting recording did not finish correctly."
        case .noAudioCaptured:
            "The meeting recording did not contain any audio."
        case .couldNotCreateAudioFile:
            "Nativ could not create the meeting audio file."
        }
    }
}

private enum MeetingAudioTrack {
    case system
    case microphone
}

/// Records only system and microphone audio through ScreenCaptureKit.
/// No screen frames are requested, encoded, or written to disk.
@MainActor
final class SystemAudioMeetingRecorder: NSObject {
    var onMicrophoneLevelUpdate: ((Float) -> Void)?

    private var stream: SCStream?
    private var temporaryAudioURL: URL?
    private var destinationAudioURL: URL?
    private nonisolated let audioWriter = MeetingAudioWriter()
    private nonisolated let captureFailure = MeetingCaptureFailure()

    private(set) var isRecording = false

    func start(
        outputURL: URL,
        microphoneDeviceID: String? = nil
    ) async throws {
        guard !isRecording else {
            return
        }

        let availableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = availableContent.displays.first else {
            throw SystemAudioMeetingRecorderError.noDisplayAvailable
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let temporaryURL = outputURL
            .deletingPathExtension()
            .appendingPathExtension("audio.mov")
        try? FileManager.default.removeItem(at: temporaryURL)
        try? FileManager.default.removeItem(at: outputURL)

        let excludedApplications = availableContent.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = microphoneDeviceID
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )
        try audioWriter.prepare(outputURL: temporaryURL)
        captureFailure.clear()
        do {
            try stream.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: audioWriter.sampleQueue
            )
            try stream.addStreamOutput(
                self,
                type: .microphone,
                sampleHandlerQueue: audioWriter.sampleQueue
            )
            try await stream.startCapture()
        } catch {
            audioWriter.cancel()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }

        self.stream = stream
        temporaryAudioURL = temporaryURL
        destinationAudioURL = outputURL
        isRecording = true
    }

    func stop() async throws -> URL {
        guard let stream,
              let temporaryAudioURL,
              let destinationAudioURL
        else {
            throw SystemAudioMeetingRecorderError.recordingDidNotFinish
        }

        isRecording = false
        do {
            try await stream.stopCapture()
        } catch {
            audioWriter.cancel()
            reset()
            try? FileManager.default.removeItem(at: temporaryAudioURL)
            throw error
        }
        try? stream.removeStreamOutput(self, type: .audio)
        try? stream.removeStreamOutput(self, type: .microphone)

        if let failure = captureFailure.value {
            audioWriter.cancel()
            reset()
            try? FileManager.default.removeItem(at: temporaryAudioURL)
            throw failure
        }

        do {
            try await audioWriter.finish()
            try await Self.exportMixedAudio(
                from: temporaryAudioURL,
                to: destinationAudioURL
            )
            try? FileManager.default.removeItem(at: temporaryAudioURL)
            reset()
            return destinationAudioURL
        } catch {
            audioWriter.cancel()
            try? FileManager.default.removeItem(at: temporaryAudioURL)
            try? FileManager.default.removeItem(at: destinationAudioURL)
            reset()
            throw error
        }
    }

    func cancel() async {
        if let stream {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .audio)
            try? stream.removeStreamOutput(self, type: .microphone)
        }
        audioWriter.cancel()
        if let temporaryAudioURL {
            try? FileManager.default.removeItem(at: temporaryAudioURL)
        }
        if let destinationAudioURL {
            try? FileManager.default.removeItem(at: destinationAudioURL)
        }
        reset()
    }

    private func reset() {
        stream = nil
        temporaryAudioURL = nil
        destinationAudioURL = nil
        captureFailure.clear()
        isRecording = false
    }

    private static func exportMixedAudio(
        from sourceURL: URL,
        to destinationURL: URL
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw SystemAudioMeetingRecorderError.noAudioCaptured
        }

        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []
        var destinationTracks: [AVAssetTrack] = []
        for sourceTrack in audioTracks {
            let sourceTimeRange = try await sourceTrack.load(.timeRange)
            guard let destinationTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                continue
            }
            try destinationTrack.insertTimeRange(
                sourceTimeRange,
                of: sourceTrack,
                at: sourceTimeRange.start
            )
            let inputParameters = AVMutableAudioMixInputParameters(
                track: destinationTrack
            )
            inputParameters.setVolume(1, at: .zero)
            parameters.append(inputParameters)
            destinationTracks.append(destinationTrack)
        }
        guard !parameters.isEmpty else {
            throw SystemAudioMeetingRecorderError.couldNotCreateAudioFile
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = parameters

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader = try AVAssetReader(asset: composition)
        let readerOutput = AVAssetReaderAudioMixOutput(
            audioTracks: destinationTracks,
            audioSettings: outputSettings
        )
        readerOutput.audioMix = audioMix
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw SystemAudioMeetingRecorderError.couldNotCreateAudioFile
        }
        reader.add(readerOutput)

        try? FileManager.default.removeItem(at: destinationURL)
        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .wav)
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: outputSettings
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw SystemAudioMeetingRecorderError.couldNotCreateAudioFile
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw writer.error ?? SystemAudioMeetingRecorderError.couldNotCreateAudioFile
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? SystemAudioMeetingRecorderError.couldNotCreateAudioFile
        }
        writer.startSession(atSourceTime: .zero)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.nativ.meeting-audio-export")
            var completed = false
            writerInput.requestMediaDataWhenReady(on: queue) {
                guard !completed else {
                    return
                }
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        guard writerInput.append(sampleBuffer) else {
                            completed = true
                            reader.cancelReading()
                            writer.cancelWriting()
                            continuation.resume(
                                throwing: writer.error
                                    ?? SystemAudioMeetingRecorderError.couldNotCreateAudioFile
                            )
                            return
                        }
                        continue
                    }

                    completed = true
                    writerInput.markAsFinished()
                    writer.finishWriting {
                        if writer.status == .completed,
                           reader.status == .completed
                        {
                            continuation.resume()
                        } else {
                            continuation.resume(
                                throwing: writer.error
                                    ?? reader.error
                                    ?? SystemAudioMeetingRecorderError.couldNotCreateAudioFile
                            )
                        }
                    }
                    return
                }
            }
        }
    }
}

extension SystemAudioMeetingRecorder: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else {
            return
        }
        switch outputType {
        case .audio:
            audioWriter.append(sampleBuffer, track: .system)
        case .microphone:
            audioWriter.append(sampleBuffer, track: .microphone)
            let level = MeetingAudioLevelMeter.normalizedLevel(from: sampleBuffer)
            Task { @MainActor [weak self] in
                self?.onMicrophoneLevelUpdate?(level)
            }
        case .screen:
            break
        @unknown default:
            break
        }
    }
}

private enum MeetingAudioLevelMeter {
    static func normalizedLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
              )
        else {
            return 0
        }

        let format = streamDescription.pointee
        guard format.mFormatID == kAudioFormatLinearPCM else {
            return 0
        }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: format.mChannelsPerFrame,
                mDataByteSize: 0,
                mData: nil
            )
        )
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr,
              let data = bufferList.mBuffers.mData
        else {
            return 0
        }

        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let byteCount = Int(bufferList.mBuffers.mDataByteSize)
        let rootMeanSquare: Float

        if isFloat, format.mBitsPerChannel == 32 {
            let samples = data.assumingMemoryBound(to: Float.self)
            rootMeanSquare = rms(samples, count: byteCount / MemoryLayout<Float>.size)
        } else if isSignedInteger, format.mBitsPerChannel == 16 {
            let samples = data.assumingMemoryBound(to: Int16.self)
            rootMeanSquare = rms(
                samples,
                count: byteCount / MemoryLayout<Int16>.size,
                scale: Float(Int16.max)
            )
        } else if isSignedInteger, format.mBitsPerChannel == 32 {
            let samples = data.assumingMemoryBound(to: Int32.self)
            rootMeanSquare = rms(
                samples,
                count: byteCount / MemoryLayout<Int32>.size,
                scale: Float(Int32.max)
            )
        } else {
            return 0
        }

        return pow(min(1, rootMeanSquare * 8), 0.65)
    }

    private static func rms(
        _ samples: UnsafePointer<Float>,
        count: Int
    ) -> Float {
        guard count > 0 else {
            return 0
        }
        var sum: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sum += sample * sample
        }
        return sqrt(sum / Float(count))
    }

    private static func rms<T: BinaryInteger>(
        _ samples: UnsafePointer<T>,
        count: Int,
        scale: Float
    ) -> Float {
        guard count > 0, scale > 0 else {
            return 0
        }
        var sum: Float = 0
        for index in 0..<count {
            let sample = Float(Int64(samples[index])) / scale
            sum += sample * sample
        }
        return sqrt(sum / Float(count))
    }
}

extension SystemAudioMeetingRecorder: SCStreamDelegate {
    nonisolated func stream(
        _ stream: SCStream,
        didStopWithError error: any Error
    ) {
        captureFailure.set(error)
    }
}

private final class MeetingCaptureFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var value: Error? {
        lock.withLock { storedError }
    }

    func set(_ error: Error) {
        lock.withLock {
            storedError = error
        }
    }

    func clear() {
        lock.withLock {
            storedError = nil
        }
    }
}

private final class MeetingAudioWriter: @unchecked Sendable {
    let sampleQueue = DispatchQueue(
        label: "com.nativ.audio.meeting-samples",
        qos: .userInitiated
    )

    private var writer: AVAssetWriter?
    private var systemInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var sessionStartTime: CMTime?
    private var appendedSampleCount = 0

    func prepare(outputURL: URL) throws {
        try sampleQueue.sync {
            resetLocked()
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let systemInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: Self.audioSettings(channels: 2, bitRate: 160_000)
            )
            let microphoneInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: Self.audioSettings(channels: 1, bitRate: 96_000)
            )
            systemInput.expectsMediaDataInRealTime = true
            microphoneInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(systemInput), writer.canAdd(microphoneInput) else {
                throw SystemAudioMeetingRecorderError.couldNotCreateAudioFile
            }
            writer.add(systemInput)
            writer.add(microphoneInput)
            guard writer.startWriting() else {
                throw writer.error
                    ?? SystemAudioMeetingRecorderError.couldNotCreateAudioFile
            }
            self.writer = writer
            self.systemInput = systemInput
            self.microphoneInput = microphoneInput
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer, track: MeetingAudioTrack) {
        appendLocked(sampleBuffer, track: track)
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            sampleQueue.async { [weak self] in
                guard let self, let writer = self.writer else {
                    continuation.resume(
                        throwing: SystemAudioMeetingRecorderError.recordingDidNotFinish
                    )
                    return
                }
                guard self.appendedSampleCount > 0 else {
                    writer.cancelWriting()
                    self.resetLocked()
                    continuation.resume(
                        throwing: SystemAudioMeetingRecorderError.noAudioCaptured
                    )
                    return
                }

                self.systemInput?.markAsFinished()
                self.microphoneInput?.markAsFinished()
                writer.finishWriting {
                    self.sampleQueue.async {
                        let error = writer.error
                        let succeeded = writer.status == .completed
                        self.resetLocked()
                        if succeeded {
                            continuation.resume()
                        } else {
                            continuation.resume(
                                throwing: error
                                    ?? SystemAudioMeetingRecorderError.recordingDidNotFinish
                            )
                        }
                    }
                }
            }
        }
    }

    func cancel() {
        sampleQueue.sync {
            writer?.cancelWriting()
            resetLocked()
        }
    }

    private func appendLocked(
        _ sampleBuffer: CMSampleBuffer,
        track: MeetingAudioTrack
    ) {
        guard let writer, writer.status == .writing else {
            return
        }
        let presentationTime = sampleBuffer.presentationTimeStamp
        if sessionStartTime == nil {
            writer.startSession(atSourceTime: presentationTime)
            sessionStartTime = presentationTime
        }
        guard let sessionStartTime,
              presentationTime >= sessionStartTime
        else {
            return
        }

        let input = track == .system ? systemInput : microphoneInput
        guard input?.isReadyForMoreMediaData == true,
              input?.append(sampleBuffer) == true
        else {
            return
        }
        appendedSampleCount += 1
    }

    private func resetLocked() {
        writer = nil
        systemInput = nil
        microphoneInput = nil
        sessionStartTime = nil
        appendedSampleCount = 0
    }

    private static func audioSettings(
        channels: Int,
        bitRate: Int
    ) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ]
    }
}
