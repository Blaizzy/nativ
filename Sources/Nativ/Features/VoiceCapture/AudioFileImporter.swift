import AVFoundation
import Foundation
import UniformTypeIdentifiers

struct ImportedAudioFile: Equatable, Sendable {
    let url: URL
    let title: String
    let duration: TimeInterval
    let wasTranscoded: Bool
}

enum AudioFileImportError: LocalizedError, Equatable {
    case unreadable
    case empty
    case tooLong(maximumMinutes: Int)
    case unsupportedFormat(String)
    case transcodeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "Nativ could not read this audio file."
        case .empty:
            "This audio file does not contain any playable audio."
        case .tooLong(let maximumMinutes):
            "This audio is longer than \(maximumMinutes) minutes. Import a shorter file."
        case .unsupportedFormat(let name):
            "Nativ cannot read \(name) files. Convert it to M4A, MP3, or WAV first."
        case .transcodeFailed:
            "Nativ could not prepare this audio file for transcription."
        }
    }
}

struct AudioFileImporter: Sendable {
    static let maximumDuration: TimeInterval = 50 * 60

    static let transcriptionSampleRate: Double = 16_000

    static let supportedContentTypes: [UTType] = [.audio]

    enum Plan: Equatable {
        case passthrough(fileExtension: String)
        case transcode
        case reject(format: String)
    }

    private enum Signature {
        static let riff = Data("RIFF".utf8)
        static let wave = Data("WAVE".utf8)
        static let flac = Data("fLaC".utf8)
        static let id3 = Data("ID3".utf8)
        static let ogg = Data("OggS".utf8)
        static let opus = Data("OpusHead".utf8)
        static let matroska = Data([0x1A, 0x45, 0xDF, 0xA3])
    }

    static func plan(for source: URL) -> Plan {
        guard let header = header(of: source) else { return .transcode }

        if header.starts(with: Signature.matroska) {
            return .reject(format: "WebM")
        }
        if header.starts(with: Signature.ogg) {
            return header.range(of: Signature.opus) == nil
                ? .passthrough(fileExtension: "ogg")
                : .reject(format: "Opus")
        }
        if header.starts(with: Signature.riff), header.dropFirst(8).starts(with: Signature.wave) {
            return .passthrough(fileExtension: "wav")
        }
        if header.starts(with: Signature.flac) {
            return .passthrough(fileExtension: "flac")
        }
        if header.starts(with: Signature.id3) || isMPEGAudioFrame(header) {
            return .passthrough(fileExtension: "mp3")
        }
        return .transcode
    }

    private static func header(of source: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: source) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 64), header.count >= 4 else { return nil }
        return header
    }

    private static func isMPEGAudioFrame(_ header: Data) -> Bool {
        var bytes = header.makeIterator()
        guard let first = bytes.next(), let second = bytes.next() else { return false }
        return first == 0xFF && second & 0xE0 == 0xE0
    }

    func importFile(from source: URL, into directory: URL) async throws -> ImportedAudioFile {
        try await withThrowingTaskGroup(of: ImportedAudioFile.self) { group in
            group.addTask(priority: .userInitiated) {
                try Self.importSynchronously(from: source, into: directory)
            }
            guard let result = try await group.next() else {
                throw AudioFileImportError.unreadable
            }
            return result
        }
    }

    private static func importSynchronously(
        from source: URL,
        into directory: URL
    ) throws -> ImportedAudioFile {
        try Task.checkCancellation()

        let plan = plan(for: source)
        if case .reject(let format) = plan {
            throw AudioFileImportError.unsupportedFormat(format)
        }

        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw AudioFileImportError.unreadable
        }

        let duration = TimeInterval(input.length) / input.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else {
            throw AudioFileImportError.empty
        }
        guard duration <= maximumDuration else {
            throw AudioFileImportError.tooLong(maximumMinutes: Int(maximumDuration / 60))
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let identifier = UUID().uuidString
        let title = source.deletingPathExtension().lastPathComponent
        let name = "Imported \(identifier)"

        if case .passthrough(let fileExtension) = plan {
            let destination = directory
                .appendingPathComponent(name)
                .appendingPathExtension(fileExtension)
            try FileManager.default.copyItem(at: source, to: destination)
            return ImportedAudioFile(
                url: destination,
                title: title,
                duration: duration,
                wasTranscoded: false
            )
        }

        let destination = directory
            .appendingPathComponent(name)
            .appendingPathExtension("wav")
        let staging = directory
            .appendingPathComponent(".audio-import-\(identifier)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try transcodeForTranscription(input: input, destination: staging)
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AudioFileImportError {
            throw error
        } catch {
            throw AudioFileImportError.transcodeFailed
        }

        return ImportedAudioFile(
            url: destination,
            title: title,
            duration: duration,
            wasTranscoded: true
        )
    }

    private static func transcodeForTranscription(
        input: AVAudioFile,
        destination: URL
    ) throws {
        let inputFormat = input.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: transcriptionSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioFileImportError.transcodeFailed
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioFileImportError.transcodeFailed
        }
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: transcriptionSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        )

        let inputCapacity: AVAudioFrameCount = 16_384
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputCapacity) * max(ratio, 1)) + 1_024
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: inputCapacity
        ), let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw AudioFileImportError.transcodeFailed
        }

        var readFailure: Error?
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, status in
                guard input.framePosition < input.length else {
                    status.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: inputBuffer)
                } catch {
                    readFailure = error
                    status.pointee = .endOfStream
                    return nil
                }
                guard inputBuffer.frameLength > 0 else {
                    status.pointee = .endOfStream
                    return nil
                }
                status.pointee = .haveData
                return inputBuffer
            }
            if let readFailure {
                throw readFailure
            }
            if case .error = status {
                if let conversionError {
                    throw conversionError
                }
                throw AudioFileImportError.transcodeFailed
            }
            if outputBuffer.frameLength > 0 {
                try output.write(from: outputBuffer)
            }
            if status != .haveData {
                return
            }
        }
    }
}

struct AudioImportProgress {
    let title: String
    let task: Task<Void, Never>
}
