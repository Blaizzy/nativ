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

    static func write(_ recordingURL: URL, to pcmURL: URL) async throws {
        try Task.checkCancellation()
        let buffer = MeetingAudioBuffer()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try buffer.convert(recordingURL, to: pcmURL) })
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            buffer.lock.withLock { buffer.cancelled = true }
        }
    }

    private func convert(_ recordingURL: URL, to pcmURL: URL) throws {
        try checkCancellation()
        FileManager.default.createFile(atPath: pcmURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: pcmURL)
        defer { try? output.close() }
        try ParakeetAudio.readBuffers(contentsOf: recordingURL, checkCancellation: checkCancellation) { samples in
            try output.write(contentsOf: Data(buffer: samples))
        }
    }
}
