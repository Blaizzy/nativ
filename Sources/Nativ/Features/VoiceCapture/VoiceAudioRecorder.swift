import AVFoundation
import CoreAudio
import Foundation

enum VoiceAudioRecorderError: LocalizedError {
    case couldNotStart
    case inputDeviceUnavailable

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            "Nativ could not start audio recording."
        case .inputDeviceUnavailable:
            "The selected microphone is no longer available. Choose another input device or use System Default."
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

    private(set) var isRecording = false
    private(set) var lastRecordingDuration: TimeInterval?
    private var audioEngine: AVAudioEngine?
    private var recordingWriter: VoiceAudioRecordingWriter?
    private var recordingURL: URL?
    private var realtimeMeter: RealtimeAudioMeter?
    private var meterPublisherTask: Task<Void, Never>?

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

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        if let deviceUniqueID {
            guard let deviceID = AudioInputDeviceResolver.coreAudioDeviceID(
                for: deviceUniqueID
            ) else {
                throw VoiceAudioRecorderError.inputDeviceUnavailable
            }
            try inputNode.auAudioUnit.setDeviceID(deviceID)
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoiceAudioRecorderError.couldNotStart
        }
        let audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: inputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let writer = VoiceAudioRecordingWriter(
            audioFile: audioFile,
            sampleRate: inputFormat.sampleRate
        )
        let realtimeMeter = RealtimeAudioMeter(profile: .recording)
        let tap = Self.makeTap(writer: writer, realtimeMeter: realtimeMeter)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: inputFormat,
            block: tap
        )

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        self.audioEngine = audioEngine
        recordingWriter = writer
        recordingURL = outputURL
        isRecording = true
        lastRecordingDuration = nil
        startMeterPublisher(realtimeMeter: realtimeMeter)
        return outputURL
    }

    @discardableResult
    func stop() -> URL? {
        guard let audioEngine, let recordingWriter, let recordingURL else {
            return nil
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        let duration = recordingWriter.duration
        stopMeterPublisher()
        self.audioEngine = nil
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
    private let audioFile: AVAudioFile
    private let sampleRate: Double
    private let lock = NSLock()
    private var writtenFrames: AVAudioFramePosition = 0

    init(audioFile: AVAudioFile, sampleRate: Double) {
        self.audioFile = audioFile
        self.sampleRate = sampleRate
    }

    var duration: TimeInterval {
        lock.withLock {
            guard sampleRate > 0 else {
                return 0
            }
            return Double(writtenFrames) / sampleRate
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) -> VoiceAudioBufferMeasurement {
        lock.withLock {
            do {
                try audioFile.write(from: buffer)
                writtenFrames += AVAudioFramePosition(buffer.frameLength)
            } catch {
                NSLog("Nativ could not write microphone audio: %@", error.localizedDescription)
            }

            var peak: Float = 0
            if let channelData = buffer.floatChannelData {
                let channelCount = Int(buffer.format.channelCount)
                let frameCount = Int(buffer.frameLength)
                for channel in 0..<channelCount {
                    let samples = channelData[channel]
                    for frame in 0..<frameCount {
                        peak = max(peak, abs(samples[frame]))
                    }
                }
            }
            let elapsed = sampleRate > 0 ? Double(writtenFrames) / sampleRate : 0
            return VoiceAudioBufferMeasurement(
                level: min(1, peak * 3.5),
                duration: elapsed
            )
        }
    }
}
