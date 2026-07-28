import AVFoundation
import Foundation

enum VoiceAudioRecorderError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            "Nativ could not start audio recording."
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

@MainActor
final class VoiceAudioRecorder {
    var onMeterUpdate: ((Float, TimeInterval) -> Void)?

    private(set) var isRecording = false
    private(set) var lastRecordingDuration: TimeInterval?
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var smoothedLevel: Float = 0

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
    func start() throws -> URL {
        if let recorder, isRecording {
            return recorder.url
        }

        let outputURL = try Self.makeOutputURL()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        recorder.isMeteringEnabled = true

        guard recorder.prepareToRecord(), recorder.record() else {
            try? FileManager.default.removeItem(at: outputURL)
            throw VoiceAudioRecorderError.couldNotStart
        }

        self.recorder = recorder
        isRecording = true
        lastRecordingDuration = nil
        smoothedLevel = 0
        startMetering()
        return outputURL
    }

    @discardableResult
    func stop() -> URL? {
        guard let recorder else {
            return nil
        }

        meterTimer?.invalidate()
        meterTimer = nil
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        isRecording = false
        lastRecordingDuration = duration
        smoothedLevel = 0
        onMeterUpdate?(0, duration)

        let outputURL = recorder.url
        guard duration > 0 else {
            lastRecordingDuration = nil
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        return outputURL
    }

    private func startMetering() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateMeter()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func updateMeter() {
        guard let recorder, isRecording else {
            return
        }
        recorder.updateMeters()

        let decibels = recorder.peakPower(forChannel: 0)
        let linearLevel = max(0, min(1, (decibels + 60) / 60))
        let shapedLevel = pow(linearLevel, 1.65)
        smoothedLevel = (smoothedLevel * 0.68) + (shapedLevel * 0.32)
        onMeterUpdate?(smoothedLevel, recorder.currentTime)
    }

    private static func makeOutputURL() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        let filename = "Voice Recording \(formatter.string(from: Date())).wav"
        return try recordingsDirectory.appendingPathComponent(filename)
    }
}
