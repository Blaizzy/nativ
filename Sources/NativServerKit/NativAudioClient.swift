import Foundation

public enum NativAudioTranscriptionError: Error, LocalizedError, CustomStringConvertible {
    case invalidResponse
    case httpStatus(Int, String)
    case emptyTranscript

    public var description: String {
        switch self {
        case .invalidResponse:
            "Invalid transcription response"
        case .httpStatus(let statusCode, let body):
            NativServerErrorMessage.endpointFailure(
                endpoint: "Transcription endpoint",
                statusCode: statusCode,
                responseBody: body
            )
        case .emptyTranscript:
            "The transcription response did not include any text."
        }
    }

    public var errorDescription: String? {
        description
    }
}

public struct NativAudioTranscription: Decodable, Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public enum NativAudioSpeechError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int, String)
    case emptyAudio

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid speech response"
        case .httpStatus(let statusCode, let body):
            NativServerErrorMessage.endpointFailure(
                endpoint: "Speech endpoint",
                statusCode: statusCode,
                responseBody: body
            )
        case .emptyAudio:
            "The speech response did not include any audio."
        }
    }
}

public final class NativAudioClient: Sendable {
    private let baseURL: URL
    private let apiKey: String?
    private let session: URLSession
    private let timeout: TimeInterval
    private let decoder = JSONDecoder()

    public init(
        baseURL: URL,
        apiKey: String? = nil,
        timeout: TimeInterval = 1_800,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout

        let configuration = sessionConfiguration
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func transcribe(
        fileURL: URL,
        model: String
    ) async throws -> NativAudioTranscription {
        let audioData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return try await transcribe(
            audioData: audioData,
            fileName: fileURL.lastPathComponent,
            model: model
        )
    }

    public func transcribe(
        audioData: Data,
        fileName: String,
        model: String
    ) async throws -> NativAudioTranscription {
        let request = makeURLRequest(
            audioData: audioData,
            fileName: fileName,
            model: model
        )
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NativAudioTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NativAudioTranscriptionError.httpStatus(
                httpResponse.statusCode,
                String(decoding: data, as: UTF8.self)
            )
        }

        let transcription = try decoder.decode(NativAudioTranscription.self, from: data)
        guard !transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativAudioTranscriptionError.emptyTranscript
        }
        return transcription
    }

    public func synthesize(text: String, model: String) async throws -> Data {
        let request = try makeSpeechURLRequest(text: text, model: model)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NativAudioSpeechError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NativAudioSpeechError.httpStatus(
                httpResponse.statusCode,
                String(decoding: data, as: UTF8.self)
            )
        }
        guard !data.isEmpty else {
            throw NativAudioSpeechError.emptyAudio
        }
        return data
    }

    func makeSpeechURLRequest(text: String, model: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/audio/speech"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")
        NativServerAuthorization.authorize(&request, apiKey: apiKey)
        request.httpBody = try JSONEncoder().encode(SpeechRequest(model: model, input: text))
        return request
    }

    private struct SpeechRequest: Encodable {
        let model: String
        let input: String
        let response_format = "wav"
        let stream = false
    }

    func makeURLRequest(
        audioData: Data,
        fileName: String,
        model: String,
        boundary: String = "NativBoundary-\(UUID().uuidString)"
    ) -> URLRequest {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/audio/transcriptions")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        NativServerAuthorization.authorize(&request, apiKey: apiKey)
        request.httpBody = Self.multipartBody(
            audioData: audioData,
            fileName: fileName,
            model: model,
            boundary: boundary
        )
        return request
    }

    private static func multipartBody(
        audioData: Data,
        fileName: String,
        model: String,
        boundary: String
    ) -> Data {
        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendUTF8("\(model)\r\n")
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.appendUTF8("json\r\n")
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFileName(fileName))\"\r\n"
        )
        body.appendUTF8("Content-Type: \(mimeType(for: fileName))\r\n\r\n")
        body.append(audioData)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func safeFileName(_ fileName: String) -> String {
        fileName
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
    }

    private static func mimeType(for fileName: String) -> String {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "wav", "wave":
            "audio/wav"
        case "m4a", "mp4":
            "audio/mp4"
        case "mp3":
            "audio/mpeg"
        case "flac":
            "audio/flac"
        default:
            "application/octet-stream"
        }
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(contentsOf: string.utf8)
    }
}


public struct NativAudioDiarization: Decodable, Sendable {
    public struct Segment: Decodable, Sendable {
        public let start: Double
        public let end: Double
        public let speaker: Int
    }
    public let model: String
    public let revision: String?
    public let segments: [Segment]
    public let speaker_ids: [String: Int]?
}

public struct NativDiarizedSegment: Decodable, Sendable {
    public let id: String
    public let start: Double
    public let end: Double
    public let text: String
    public let speaker: String
    /// Extension preserving simultaneous voices, whose IDs come from diarization.speaker_ids.
    public let speakers: [String]?
}

public struct NativDiarizedTranscription: Sendable {
    public let text: String
    public let duration: Double
    public let segments: [NativDiarizedSegment]
    public let diarization: NativAudioDiarization
}

public struct NativSpeakerEmbedding: Decodable, Sendable {
    public let model: String
    public let revision: String?
    public let embedding: [Float]
    public let duration: Double
}

public struct NativSpeakerWindow: Codable, Equatable, Sendable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

public enum NativAudioAnalysisError: LocalizedError {
    case serverNotRunning
    case unavailable
    case invalidResponse
    case httpStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            "The Nativ server could not start. Check the server status and retry."
        case .unavailable:
            "This server does not support speaker analysis. Update the Nativ server to a release with diarization and speaker embedding endpoints."
        case .invalidResponse:
            "The server returned an invalid speaker analysis response."
        case .httpStatus(let status, let body):
            NativServerErrorMessage.endpointFailure(endpoint: "Speaker analysis endpoint", statusCode: status, responseBody: body)
        }
    }
}

extension NativAudioClient {
    /// OpenAI diarized SSE with an opt-in raw diarization extension for saved profiles.
    public func transcribeDiarized(
        pcmURL: URL, model: String, diarizationModel: String, diarizationRevision: String? = nil,
        onDiarization: @Sendable () async -> Void = {},
        onSegment: @Sendable (NativDiarizedSegment) async -> Void = { _ in }
    ) async throws -> NativDiarizedTranscription {
        try Task.checkCancellation()
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        var fields = [
            "model": model, "response_format": "diarized_json", "stream": "true", "chunking_strategy": "auto",
            "diarization_model": diarizationModel, "include[]": "diarization",
        ]
        fields["diarization_revision"] = diarizationRevision
        var request = try makeAnalysisRequest(pcmURL: pcmURL, endpoint: "transcriptions", fields: fields, bodyURL: bodyURL)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBodyStream = InputStream(url: bodyURL)
        request.setValue(String(try bodyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!), forHTTPHeaderField: "Content-Length")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw NativAudioAnalysisError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var message = ""
            for try await line in bytes.lines {
                message += line
                if message.utf8.count > 65536 { break }
            }
            throw NativAudioAnalysisError.httpStatus(http.statusCode, message)
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true else {
            throw NativAudioAnalysisError.invalidResponse
        }
        var segments: [NativDiarizedSegment] = []
        var identifiers: Set<String> = []
        var metadata: NativAudioDiarization?
        var completed: DiarizedEvent?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix("data:") {
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard payload.utf8.count < 16 * 1024 * 1024 else { throw NativAudioAnalysisError.invalidResponse }
                let data = Data(payload.utf8)
                let event = try decoder.decode(DiarizedEvent.self, from: data)
                switch event.type {
                case "diarization.completed":
                    guard metadata == nil, let detected = event.diarization else { throw NativAudioAnalysisError.invalidResponse }
                    metadata = detected
                    await onDiarization()
                case "transcript.text.segment":
                    let segment = try decoder.decode(NativDiarizedSegment.self, from: data)
                    guard completed == nil, segment.start.isFinite, segment.end.isFinite,
                          segment.start >= 0, segment.end > segment.start,
                          !segment.text.isEmpty, identifiers.insert(segment.id).inserted else {
                        throw NativAudioAnalysisError.invalidResponse
                    }
                    segments.append(segment)
                    await onSegment(segment)
                case "transcript.text.done":
                    guard completed == nil else { throw NativAudioAnalysisError.invalidResponse }
                    completed = event
                case "error":
                    throw NativAudioAnalysisError.httpStatus(500, event.error?.message ?? "Diarized transcription failed")
                default: break
                }
            }
        }
        try Task.checkCancellation()
        guard let done = completed, let text = done.text, let duration = done.duration,
              duration.isFinite, duration >= 0, let detected = done.diarization ?? metadata,
              segments.allSatisfy({ $0.end <= duration + 1 / 16000 }) else {
            throw NativAudioAnalysisError.invalidResponse
        }
        return NativDiarizedTranscription(text: text, duration: duration, segments: segments, diarization: detected)
    }

    private struct DiarizedEvent: Decodable {
        struct Failure: Decodable { let message: String }
        let type: String
        let text: String?
        let duration: Double?
        let diarization: NativAudioDiarization?
        let error: Failure?
    }

    public func diarize(pcmURL: URL, model: String, revision: String? = nil) async throws -> NativAudioDiarization {
        var fields = ["model": model]
        fields["revision"] = revision
        return try await analyze(pcmURL: pcmURL, endpoint: "diarizations", fields: fields)
    }

    public func speakerEmbedding(
        pcmURL: URL, windows: [NativSpeakerWindow], model: String, revision: String? = nil
    ) async throws -> NativSpeakerEmbedding {
        let manifest = String(decoding: try JSONEncoder().encode(windows), as: UTF8.self)
        var fields = ["model": model, "windows": manifest]
        fields["revision"] = revision
        return try await analyze(pcmURL: pcmURL, endpoint: "speaker_embeddings", fields: fields)
    }

    private func analyze<Result: Decodable>(pcmURL: URL, endpoint: String, fields: [String: String]) async throws -> Result {
        try Task.checkCancellation()
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let request = try makeAnalysisRequest(pcmURL: pcmURL, endpoint: endpoint, fields: fields, bodyURL: bodyURL)
        let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw NativAudioAnalysisError.invalidResponse }
        if response.statusCode == 404,
           (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["detail"] == "Not Found" {
            throw NativAudioAnalysisError.unavailable
        }
        guard (200..<300).contains(response.statusCode) else {
            throw NativAudioAnalysisError.httpStatus(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        return try decoder.decode(Result.self, from: data)
    }

    /// A disk-backed multipart upload keeps multi-hour PCM recordings out of RAM.
    func makeAnalysisRequest(pcmURL: URL, endpoint: String, fields: [String: String], bodyURL: URL,
                             boundary: String = "NativBoundary-\(UUID().uuidString)") throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/audio/\(endpoint)"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        NativServerAuthorization.authorize(&request, apiKey: apiKey)
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }
        for (key, value) in fields.merging(["input_format": "pcm_f32le", "sample_rate": "16000"], uniquingKeysWith: { _, rhs in rhs }).sorted(by: { $0.key < $1.key }) {
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.f32\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: pcmURL)
        defer { try? input.close() }
        while let block = try input.read(upToCount: 1_048_576), !block.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: block)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return request
    }
}
