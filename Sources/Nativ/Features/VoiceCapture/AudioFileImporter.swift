import AVFoundation
import Foundation
import UniformTypeIdentifiers

struct ImportedAudioFile: Equatable, Sendable {
    let url: URL
    let title: String
    let duration: TimeInterval
}

enum AudioFileImportError: LocalizedError {
    case unreadable
    case empty
    case tooLong(maximumMinutes: Int)
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "Nativ could not read this audio file."
        case .empty:
            "This audio file does not contain any playable audio."
        case .tooLong(let maximumMinutes):
            "This audio is longer than \(maximumMinutes) minutes. Import a shorter file."
        case .conversionFailed:
            "Nativ could not prepare this audio file for transcription."
        }
    }
}

struct AudioFileImporter: Sendable {
    static let supportedContentTypes: [UTType] = [.audio]
    static let maximumDuration: TimeInterval = 50 * 60

    func importFile(from source: URL, into directory: URL) async throws -> ImportedAudioFile {
        try await Task.detached(priority: .userInitiated) {
            try Self.importFileSynchronously(from: source, into: directory)
        }.value
    }

    private static func importFileSynchronously(
        from source: URL,
        into directory: URL
    ) throws -> ImportedAudioFile {
        try Task.checkCancellation()

        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw AudioFileImportError.unreadable
        }

        let inputFormat = input.processingFormat
        guard input.length > 0, inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioFileImportError.empty
        }
        let duration = TimeInterval(input.length) / inputFormat.sampleRate
        guard duration.isFinite, duration > 0 else {
            throw AudioFileImportError.empty
        }
        guard duration <= maximumDuration else {
            throw AudioFileImportError.tooLong(
                maximumMinutes: Int(maximumDuration / 60)
            )
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let identifier = UUID().uuidString
        let stagingURL = directory
            .appendingPathComponent(".audio-import-\(identifier)")
            .appendingPathExtension("wav")
        let destination = directory
            .appendingPathComponent("Imported \(identifier)")
            .appendingPathExtension("wav")
        var shouldRemoveStagingFile = true
        defer {
            if shouldRemoveStagingFile {
                try? FileManager.default.removeItem(at: stagingURL)
            }
        }

        do {
            try convertToPCM(
                input: input,
                inputFormat: inputFormat,
                destination: stagingURL
            )
            try validatePCMFile(
                at: stagingURL,
                sampleRate: inputFormat.sampleRate,
                channelCount: inputFormat.channelCount
            )
            try FileManager.default.moveItem(at: stagingURL, to: destination)
            shouldRemoveStagingFile = false
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AudioFileImportError.conversionFailed
        }

        return ImportedAudioFile(
            url: destination,
            title: source.deletingPathExtension().lastPathComponent,
            duration: duration
        )
    }

    private static func convertToPCM(
        input: AVAudioFile,
        inputFormat: AVAudioFormat,
        destination: URL
    ) throws {
        guard let fileFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: inputFormat.sampleRate,
            channels: inputFormat.channelCount,
            interleaved: true
        ) else {
            throw AudioFileImportError.conversionFailed
        }
        let output = try AVAudioFile(
            forWriting: destination,
            settings: fileFormat.settings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )
        guard output.processingFormat == inputFormat else {
            throw AudioFileImportError.conversionFailed
        }

        let frameCapacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: frameCapacity
        ) else {
            throw AudioFileImportError.conversionFailed
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            let remainingFrames = input.length - input.framePosition
            let framesToRead = min(AVAudioFramePosition(frameCapacity), remainingFrames)
            try input.read(
                into: buffer,
                frameCount: AVAudioFrameCount(framesToRead)
            )
            guard buffer.frameLength > 0 else {
                break
            }
            try output.write(from: buffer)
        }
    }

    private static func validatePCMFile(
        at url: URL,
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0,
              file.fileFormat.commonFormat == .pcmFormatInt16,
              file.fileFormat.sampleRate == sampleRate,
              file.fileFormat.channelCount == channelCount
        else {
            throw AudioFileImportError.conversionFailed
        }
    }
}
