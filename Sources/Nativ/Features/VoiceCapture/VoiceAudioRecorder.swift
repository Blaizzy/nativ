import AVFoundation
import CoreAudio
import Foundation

enum VoiceAudioRecorderError: LocalizedError {
    case couldNotStart
    case inputDeviceUnavailable
    case couldNotConvert

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            "Nativ could not start audio recording."
        case .inputDeviceUnavailable:
            "The selected microphone is no longer available. Choose another input device or use System Default."
        case .couldNotConvert:
            "Nativ could not convert audio from the microphone’s current format."
        }
    }
}

enum VoiceAudioRetention {
    static let duration: TimeInterval = 5 * 60

    static func audioFiles(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files.filter { url in
            guard url.pathExtension.localizedCaseInsensitiveCompare("wav") == .orderedSame,
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  )
            else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }

    static func deletionDelay(
        for audioURL: URL,
        now: Date = Date()
    ) -> TimeInterval {
        let values = try? audioURL.resourceValues(
            forKeys: [.contentModificationDateKey, .creationDateKey]
        )
        guard let recordedAt = values?.contentModificationDate ?? values?.creationDate else {
            return duration
        }
        return max(0, recordedAt.addingTimeInterval(duration).timeIntervalSince(now))
    }

    static func latestAudioFile(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        audioFiles(in: directory, fileManager: fileManager).max { lhs, rhs in
            recordingDate(for: lhs) < recordingDate(for: rhs)
        }
    }

    @discardableResult
    static func removeAudioFile(
        at audioURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard audioURL.pathExtension.localizedCaseInsensitiveCompare("wav") == .orderedSame else {
            return false
        }
        do {
            try fileManager.removeItem(at: audioURL)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return true
        } catch {
            NSLog(
                "Nativ could not remove temporary voice recording at %@: %@",
                audioURL.path,
                error.localizedDescription
            )
            return false
        }
    }

    @discardableResult
    static func removeExpiredAudioFiles(
        in directory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [URL] {
        audioFiles(in: directory, fileManager: fileManager).filter { audioURL in
            guard deletionDelay(for: audioURL, now: now) <= 0 else {
                return false
            }
            return removeAudioFile(at: audioURL, fileManager: fileManager)
        }
    }

    static func removeAllAudioFiles(
        in directory: URL,
        fileManager: FileManager = .default
    ) {
        for audioURL in audioFiles(in: directory, fileManager: fileManager) {
            removeAudioFile(at: audioURL, fileManager: fileManager)
        }
    }

    private static func recordingDate(for audioURL: URL) -> Date {
        let values = try? audioURL.resourceValues(
            forKeys: [.contentModificationDateKey, .creationDateKey]
        )
        return values?.contentModificationDate ?? values?.creationDate ?? .distantPast
    }
}

struct VoiceAudioBufferMeasurement: Sendable {
    let level: Float
    let duration: TimeInterval
}

protocol VoiceAudioBufferWriting: Sendable {
    func append(_ buffer: AVAudioPCMBuffer) -> VoiceAudioBufferMeasurement
}

@MainActor
final class VoiceAudioRecorder {
    var onMeterUpdate: (@MainActor @Sendable (Float, TimeInterval) -> Void)?
    var onRecordingFailure: (@MainActor @Sendable (Error, URL?) -> Void)?

    private(set) var isRecording = false
    private(set) var lastRecordingDuration: TimeInterval?
    private(set) var lastRecordingError: Error?

    private let inputSession: AudioInputEngineSession
    private var recordingID: UUID?
    private var recordingWriter: VoiceAudioRecordingWriter?
    private var recordingURL: URL?
    private var realtimeMeter: RealtimeAudioMeter?
    private var meterPublisherTask: Task<Void, Never>?

    init(inputSession: AudioInputEngineSession = AudioInputEngineSession()) {
        self.inputSession = inputSession
    }

    static var recordingsDirectory: URL {
        get throws {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = applicationSupport
                .appendingPathComponent("Nativ", isDirectory: true)
                .appendingPathComponent("Voice Recordings", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return directory
        }
    }

    @discardableResult
    func start(
        outputURL requestedOutputURL: URL? = nil,
        deviceUniqueID: String? = nil
    ) throws -> URL {
        if let recordingURL, isRecording {
            return recordingURL
        }

        let outputURL = try requestedOutputURL ?? Self.makeOutputURL()
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        let id = UUID()
        recordingID = id
        lastRecordingError = nil
        let writer = VoiceAudioRecordingWriter(outputURL: outputURL) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.recordingID == id else { return }
                self.recordingFailed(error)
            }
        }
        let realtimeMeter = RealtimeAudioMeter(profile: .recording)
        do {
            try inputSession.start(
                deviceUniqueID: deviceUniqueID,
                tap: Self.makeTap(writer: writer, realtimeMeter: realtimeMeter)
            ) { [weak self] error in
                guard let self, self.recordingID == id else { return }
                self.recordingFailed(error)
            }
        } catch {
            recordingID = nil
            inputSession.stop()
            writer.finish()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        recordingWriter = writer
        recordingURL = outputURL
        isRecording = true
        lastRecordingDuration = nil
        startMeterPublisher(realtimeMeter: realtimeMeter)
        return outputURL
    }

    @discardableResult
    func stop() -> URL? {
        guard let recordingWriter, let recordingURL else {
            return nil
        }

        recordingID = nil
        inputSession.stop()
        recordingWriter.finish()
        lastRecordingError = recordingWriter.error
        let duration = recordingWriter.duration
        stopMeterPublisher()
        self.recordingWriter = nil
        self.recordingURL = nil
        isRecording = false
        lastRecordingDuration = duration
        onMeterUpdate?(0, duration)

        guard duration > 0 else {
            lastRecordingDuration = nil
            try? FileManager.default.removeItem(at: recordingURL)
            return nil
        }
        return recordingURL
    }

    func discard() {
        if let recordingURL = stop() {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        lastRecordingDuration = nil
    }

    private func recordingFailed(_ error: Error) {
        let savedURL = stop()
        lastRecordingError = error
        onRecordingFailure?(error, savedURL)
    }

    private func startMeterPublisher(realtimeMeter: RealtimeAudioMeter) {
        self.realtimeMeter = realtimeMeter
        meterPublisherTask = Task { [weak self, realtimeMeter] in
            await RealtimeAudioMeterPublisher.run(meter: realtimeMeter) {
                [weak self, realtimeMeter] snapshot in
                guard
                    let self,
                    self.realtimeMeter === realtimeMeter,
                    self.isRecording
                else {
                    return
                }
                self.onMeterUpdate?(snapshot.level, snapshot.elapsed)
            }
        }
    }

    private func stopMeterPublisher() {
        realtimeMeter = nil
        meterPublisherTask?.cancel()
        meterPublisherTask = nil
    }

    nonisolated static func makeTap(
        writer: any VoiceAudioBufferWriting,
        realtimeMeter: RealtimeAudioMeter
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            let measurement = writer.append(buffer)
            realtimeMeter.submit(
                level: measurement.level,
                elapsed: measurement.duration
            )
        }
    }

    private static func makeOutputURL() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        let filename = "Voice Recording \(formatter.string(from: Date())).wav"
        return try recordingsDirectory.appendingPathComponent(filename)
    }
}

final class VoiceAudioRecordingWriter: VoiceAudioBufferWriting, @unchecked Sendable {
    private let outputURL: URL
    private var audioFile: AVAudioFile?
    private let lock = NSLock()
    private var writtenFrames: AVAudioFramePosition = 0
    private var isFinished = false
    private let onFailure: @Sendable (Error) -> Void
    private var failure: Error?
    private var converter: AVAudioConverter?
    private var conversionOutput: AVAudioPCMBuffer?
    private var pendingConversionBuffer: AVAudioPCMBuffer?

    init(outputURL: URL, onFailure: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.outputURL = outputURL
        self.onFailure = onFailure
    }

    var duration: TimeInterval {
        lock.withLock {
            guard let sampleRate = audioFile?.processingFormat.sampleRate,
                sampleRate > 0
            else {
                return 0
            }
            return Double(writtenFrames) / sampleRate
        }
    }

    var error: Error? {
        lock.withLock { failure }
    }

    func finish() {
        let newFailure = lock.withLock { () -> Error? in
            guard !isFinished else { return nil }
            let hadFailure = failure != nil
            isFinished = true
            if failure == nil {
                do { try flushConverter() }
                catch { reportFailure(error) }
            }
            audioFile?.close()
            return hadFailure ? nil : failure
        }
        if let newFailure { onFailure(newFailure) }
    }

    func append(_ buffer: AVAudioPCMBuffer) -> VoiceAudioBufferMeasurement {
        let (measurement, newFailure) = lock.withLock {
            let hadFailure = failure != nil
            if !isFinished, failure == nil, buffer.frameLength > 0 {
                do { try write(buffer) }
                catch { reportFailure(error) }
            }

            var peak: Float = 0
            if let channelData = buffer.floatChannelData {
                let channelCount = Int(buffer.format.channelCount)
                let frameCount = Int(buffer.frameLength)
                for channel in 0..<channelCount {
                    let samples = channelData[channel]
                    for frame in 0..<frameCount {
                        peak = max(peak, abs(samples[frame * buffer.stride]))
                    }
                }
            }
            let sampleRate = audioFile?.processingFormat.sampleRate ?? 0
            let elapsed = sampleRate > 0 ? Double(writtenFrames) / sampleRate : 0
            return (
                VoiceAudioBufferMeasurement(level: min(1, peak * 3.5), duration: elapsed),
                hadFailure ? nil : failure
            )
        }
        if let newFailure { onFailure(newFailure) }
        return measurement
    }

    private func reportFailure(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        NSLog("Nativ could not write microphone audio: %@", error.localizedDescription)
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        if audioFile == nil {
            // The first delivered buffer establishes the recording's file format.
            let format = buffer.format
            audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        }
        guard let audioFile else { return }
        if converter?.inputFormat != buffer.format {
            try flushConverter()
        }
        if buffer.format == audioFile.processingFormat {
            try audioFile.write(from: buffer)
            writtenFrames += AVAudioFramePosition(buffer.frameLength)
            return
        }
        if converter == nil {
            guard let converter = AVAudioConverter(
                from: buffer.format, to: audioFile.processingFormat
            ), let output = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat, frameCapacity: 4_096
            ) else {
                throw VoiceAudioRecorderError.couldNotConvert
            }
            converter.downmix = true
            self.converter = converter
            conversionOutput = output
        }
        try convertAndWrite(buffer)
    }

    private func flushConverter() throws {
        guard converter != nil else { return }
        defer {
            converter = nil
            conversionOutput = nil
        }
        try convertAndWrite(nil)
    }

    private func convertAndWrite(_ buffer: AVAudioPCMBuffer?) throws {
        guard let converter, let output = conversionOutput, let audioFile else { return }
        pendingConversionBuffer = buffer
        defer { pendingConversionBuffer = nil }
        let isEndOfStream = buffer == nil
        while true {
            output.frameLength = 0
            var error: NSError?
            // The converter calls its input block synchronously under the writer's lock.
            let status = converter.convert(to: output, error: &error) { [self] _, status in
                if let pending = pendingConversionBuffer {
                    pendingConversionBuffer = nil
                    status.pointee = .haveData
                    return pending
                }
                status.pointee = isEndOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error {
                throw error ?? VoiceAudioRecorderError.couldNotConvert as NSError
            }
            if output.frameLength > 0 {
                try audioFile.write(from: output)
                writtenFrames += AVAudioFramePosition(output.frameLength)
            }
            if status != .haveData { return }
        }
    }

}
