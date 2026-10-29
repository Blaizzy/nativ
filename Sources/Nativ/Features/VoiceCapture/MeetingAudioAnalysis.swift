import AVFoundation
import Foundation
import NativServerKit

enum MeetingDiarizer {
    static let defaultModelID = "nativ-community/Nemotron-3-Diarization"
    static let defaultTranscriptionModelID = "mlx-community/parakeet-tdt-0.6b-v3"

    @MainActor
    static func transcribe(
        _ recordingURL: URL, client: NativAudioClient, model: String,
        diarizationFinished: @escaping @MainActor @Sendable () -> Void = {},
        segmentFinished: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws -> Transcription {
        let pcmURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".f32")
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        try await MeetingAudioBuffer.write(recordingURL, to: pcmURL)
        let response = try await client.transcribeDiarized(
            pcmURL: pcmURL, model: model, diarizationModel: defaultModelID,
            onDiarization: { await diarizationFinished() }, onSegment: { await segmentFinished($0.end) }
        )
        return try Transcription(response)
    }

    struct Transcription {
        let text: String
        let diarization: AudioDiarization

        init(_ response: NativDiarizedTranscription) throws {
            let detected = response.diarization
            guard detected.model == defaultModelID, let ids = detected.speaker_ids else {
                throw MeetingDiarizationError.invalidOutput
            }
            let turns: [AudioDiarization.TranscriptSegment] = try response.segments.map { segment in
                let labels = segment.speakers ?? (segment.speaker == "unknown" ? [] : [segment.speaker])
                let speakers = try labels.map { label in
                    guard let id = ids[label] else { throw MeetingDiarizationError.invalidOutput }
                    return id
                }
                return .init(start: segment.start, end: segment.end, speakers: speakers, text: segment.text)
            }
            var diarization = AudioDiarization(modelID: detected.model, revision: detected.revision,
                segments: detected.segments.map { .init(start: $0.start, end: $0.end, speaker: $0.speaker) }, transcriptSegments: turns)
            try diarization.validate()
            diarization.speakerTranscript = diarization.formattedTranscript
            self.text = response.text
            self.diarization = diarization
        }
    }
}

/// AVFoundation conversion stays off the main actor. Inference belongs to the
/// server; cancellation here only stops decoding/copying the source recording.
final class MeetingAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    private func checkCancellation() throws {
        try lock.withLock { if cancelled { throw CancellationError() } }
    }

    static func write(_ recordingURL: URL, to pcmURL: URL, ranges: [Range<Int64>]? = nil) async throws {
        try Task.checkCancellation()
        let buffer = MeetingAudioBuffer()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try buffer.convert(recordingURL, to: pcmURL, ranges: ranges) })
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            buffer.lock.withLock { buffer.cancelled = true }
        }
    }

    private func convert(_ recordingURL: URL, to pcmURL: URL, ranges: [Range<Int64>]?) throws {
        enum ConversionControl: Error { case finished }
        try checkCancellation()
        FileManager.default.createFile(atPath: pcmURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: pcmURL)
        defer { try? output.close() }
        var position: Int64 = 0
        var written: Int64 = 0
        do {
            try ParakeetAudio.readBuffers(contentsOf: recordingURL, checkCancellation: checkCancellation) { samples in
                let end = position + Int64(samples.count)
                for range in ranges ?? [position..<end] {
                    let first = max(position, range.lowerBound), last = min(end, range.upperBound)
                    guard last > first else { continue }
                    let selected = UnsafeBufferPointer(rebasing: samples[Int(first - position)..<Int(last - position)])
                    try output.write(contentsOf: Data(buffer: selected))
                    written += last - first
                }
                position = end
                if let finalSample = ranges?.last?.upperBound, position >= finalSample { throw ConversionControl.finished }
            }
        } catch ConversionControl.finished {}
        if let ranges, written != ranges.reduce(Int64(0), { $0 + Int64($1.count) }) {
            throw SpeakerVoiceEmbeddingError.invalidAudio
        }
    }
}

struct SpeakerVoiceEmbedding: Codable, Equatable, Sendable {
    let modelID: String
    let revision: String?
    let vector: [Float]
    let durationSeconds: Double

    func validate() throws {
        guard SpeakerVoiceEmbeddingExtractor.supports(modelID: modelID, revision: revision),
              vector.count == SpeakerVoiceEmbeddingExtractor.dimensions, vector.allSatisfy(\.isFinite),
              durationSeconds.isFinite, (3...30).contains(durationSeconds) else {
            throw SpeakerVoiceEmbeddingError.invalidEmbedding
        }
        let normSquared = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard (0.99...1.01).contains(normSquared) else {
            throw SpeakerVoiceEmbeddingError.invalidEmbedding
        }
    }
}

enum SpeakerVoiceEmbeddingError: LocalizedError {
    case insufficientSpeech
    case invalidEmbedding
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .insufficientSpeech:
            "Voice matching needs at least three seconds of clear speech without another speaker talking."
        case .invalidEmbedding:
            "The voice model returned an invalid speaker embedding. Try another recording."
        case .invalidAudio:
            "The selected speaker audio could not be read from this recording."
        }
    }
}

enum SpeakerVoiceEmbeddingExtractor {
    static let modelID = "nativ-community/SpeechBrain-ECAPA-VoxCeleb-20M"
    static let dimensions = 192

    /// The maintained copy has identical weights. Keep saved upstream samples
    /// usable without rewriting profiles or extracting their embeddings again.
    static func supports(modelID: String?, revision: String?) -> Bool {
        (modelID == Self.modelID && revision == nil)
            || (modelID == "aufklarer/SpeechBrain-ECAPA-VoxCeleb-20M-MLX"
                && revision == "e749e6e08557f4a3ceb6ce3bf6f0b79efe592a77")
    }

    struct Window: Codable, Equatable, Sendable {
        let start: Double
        let end: Double
    }

    /// Keep each sample contiguous and exclude overlapping speakers and turn
    /// boundaries. Longer turns are split so memory stays bounded on long calls.
    static func windows(diarization: AudioDiarization, speakerID: Int) throws -> [Window] {
        try diarization.validate()
        guard diarization.segments.allSatisfy({ $0.end < Double(Int64.max / 16000) }) else {
            throw SpeakerVoiceEmbeddingError.invalidAudio
        }
        guard diarization.speakerIDs.contains(speakerID) else {
            throw SpeakerVoiceEmbeddingError.insufficientSpeech
        }
        let eligible = try diarization.transcriptionChunks(maximumDuration: 10.3)
            .filter {
                $0.speakers == [speakerID]
                    && ($0.end * 16000).rounded() - ($0.start * 16000).rounded() >= 52800
            }
            .map { chunk in
                let start = Int64((chunk.start * 16000).rounded()) + 2400
                let end = min(Int64((chunk.end * 16000).rounded()) - 2400, start + 160000)
                return Window(start: Double(start) / 16000, end: Double(end) / 16000)
            }
            .filter { (($0.end - $0.start) * 16000).rounded() >= 48000 }
            .sorted {
                let lhs = (($0.end - $0.start) * 16000).rounded()
                let rhs = (($1.end - $1.start) * 16000).rounded()
                return lhs == rhs ? $0.start < $1.start : lhs > rhs
            }
        let chosen = Array(eligible.prefix(3)).sorted { $0.start < $1.start }
        guard !chosen.isEmpty else { throw SpeakerVoiceEmbeddingError.insufficientSpeech }
        return chosen
    }

    static func extract(
        recordingURL: URL, diarization: AudioDiarization, speakerID: Int, client: NativAudioClient
    ) async throws -> SpeakerVoiceEmbedding {
        try Task.checkCancellation()
        let windows = try windows(diarization: diarization, speakerID: speakerID)
        let ranges = windows.map { Int64(($0.start * 16000).rounded())..<Int64(($0.end * 16000).rounded()) }
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("f32")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try await MeetingAudioBuffer.write(recordingURL, to: audioURL, ranges: ranges)
        var offset: Int64 = 0
        let selectedWindows = ranges.map { range in
            let start = offset
            offset += Int64(range.count)
            return NativSpeakerWindow(start: Double(start) / 16000, end: Double(offset) / 16000)
        }
        let response = try await client.speakerEmbedding(pcmURL: audioURL, windows: selectedWindows, model: modelID)
        let result = SpeakerVoiceEmbedding(modelID: response.model, revision: response.revision,
                                           vector: response.embedding, durationSeconds: response.duration)
        try result.validate()
        guard abs(result.durationSeconds - Double(offset) / 16000) <= 1 / 16000 else {
            throw SpeakerVoiceEmbeddingError.invalidEmbedding
        }
        return result
    }
}

/// The server's speaker encoder, tracked separately from language-model scans.
enum AudioSpeakerEmbeddingModel {
    static let repoID = SpeakerVoiceEmbeddingExtractor.modelID
    static let title = "ECAPA-TDNN"
    // Display estimate; download preflight resolves the current files and size.
    static let estimatedSizeBytes: Int64 = 42_000_000

    // Use the server's shared Hugging Face cache.
    static var cachePath: String { HuggingFaceCache.defaultHubPath() }

    static func weightsURL(cachePath: String) -> URL? {
        let repository = URL(fileURLWithPath: (cachePath as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("models--" + repoID.replacingOccurrences(of: "/", with: "--"))
        guard let reference = try? String(contentsOf: repository.appendingPathComponent("refs/main"), encoding: .utf8) else { return nil }
        let revision = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (40...64).contains(revision.count), revision.allSatisfy(\.isHexDigit) else { return nil }
        return repository
            .appendingPathComponent("snapshots")
            .appendingPathComponent(revision)
            .appendingPathComponent("model.safetensors")
    }

    static func isInstalled(cachePath: String) -> Bool {
        do {
            guard let url = weightsURL(cachePath: cachePath)?.resolvingSymlinksInPath() else { return false }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        } catch {
            return false
        }
    }
}
