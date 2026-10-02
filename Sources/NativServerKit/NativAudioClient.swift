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

public final class NativAudioClient {
    private let baseURL: URL
    private let apiKey: String?
    private let session: URLSession
    private let timeout: TimeInterval
    private let decoder = JSONDecoder()

    public init(
        baseURL: URL,
        apiKey: String? = nil,
        timeout: TimeInterval = 1_800
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout

        let configuration = URLSessionConfiguration.ephemeral
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
