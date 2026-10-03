import Foundation

public enum NativAudioTranscriptionError: Error, LocalizedError, CustomStringConvertible {
    case invalidResponse
    case httpStatus(Int, String)
    case emptyTranscript
    case realtime(String)

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
        case .realtime(let message):
            message
        }
    }

    public var errorDescription: String? {
        description
    }
}

public actor NativRealtimeTranscriptionSession {
    public typealias TranscriptUpdate = @MainActor @Sendable (String) async throws -> Void

    private let request: URLRequest
    private let model: String
    private let onTranscriptUpdate: TranscriptUpdate
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var transcript = ""
    private var completion: CheckedContinuation<String, Error>?
    private var completedTranscript: String?
    private var firstError: Error?
    private var isCommitted = false

    public init(
        baseURL: URL,
        apiKey: String? = nil,
        model: String,
        onTranscriptUpdate: @escaping TranscriptUpdate
    ) throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw NativAudioTranscriptionError.invalidResponse
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [components.path, "v1/audio/realtime"]
            .filter { !$0.isEmpty && $0 != "/" }
            .joined(separator: "/")
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else {
            throw NativAudioTranscriptionError.invalidResponse
        }

        var request = URLRequest(url: url)
        NativServerAuthorization.authorize(&request, apiKey: apiKey)
        self.request = request
        self.model = model
        self.onTranscriptUpdate = onTranscriptUpdate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func append(pcm16: Data, sampleRate: Int) async throws {
        guard !pcm16.isEmpty else { return }
        do {
            try await connectIfNeeded(sampleRate: sampleRate)
            try await send([
                "type": "input_audio_buffer.append",
                "audio": pcm16.base64EncodedString(),
            ])
        } catch {
            fail(error)
            throw error
        }
    }

    public func finish() async throws -> String {
        if let firstError { throw firstError }
        guard let socket else { return transcript }
        if !isCommitted {
            isCommitted = true
            do {
                try await send(["type": "input_audio_buffer.commit"])
            } catch {
                fail(error)
                throw error
            }
        }
        if let completedTranscript { return completedTranscript }
        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            if let completedTranscript {
                completion = nil
                continuation.resume(returning: completedTranscript)
            } else if let firstError {
                completion = nil
                continuation.resume(throwing: firstError)
            }
        }
    }

    public func cancel() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        completion?.resume(throwing: CancellationError())
        completion = nil
        session.invalidateAndCancel()
    }

    private func connectIfNeeded(sampleRate: Int) async throws {
        if socket != nil { return }
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()

        let created = try await receiveJSON(from: socket)
        try Self.requireEvent(created, type: "session.created")
        try await send([
            "type": "session.update",
            "session": [
                "model": model,
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": sampleRate],
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ])
        let updated = try await receiveJSON(from: socket)
        try Self.requireEvent(updated, type: "session.updated")
        receiveTask = Task { [weak self, socket] in
            await self?.receiveEvents(from: socket)
        }
    }

    private func receiveEvents(from socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let event = try await receiveJSON(from: socket)
                guard let type = event["type"] as? String else { continue }
                switch type {
                case "conversation.item.input_audio_transcription.delta":
                    guard let delta = event["delta"] as? String else { continue }
                    transcript += delta
                    try await onTranscriptUpdate(transcript)
                case "conversation.item.input_audio_transcription.completed":
                    if let completed = event["transcript"] as? String {
                        transcript = completed
                        try await onTranscriptUpdate(transcript)
                    }
                    completedTranscript = transcript
                    completion?.resume(returning: transcript)
                    completion = nil
                    socket.cancel(with: .normalClosure, reason: nil)
                    self.socket = nil
                    receiveTask = nil
                    session.finishTasksAndInvalidate()
                    return
                case "error":
                    let error = Self.serverError(from: event)
                    fail(error)
                    return
                default:
                    continue
                }
            }
        } catch is CancellationError {
            fail(CancellationError())
        } catch {
            fail(error)
        }
    }

    private func send(_ object: [String: Any]) async throws {
        guard let socket else {
            throw NativAudioTranscriptionError.realtime("Realtime transcription is not connected.")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NativAudioTranscriptionError.invalidResponse
        }
        try await socket.send(.string(text))
    }

    private func receiveJSON(from socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data = switch message {
        case .data(let data): data
        case .string(let text): Data(text.utf8)
        @unknown default: throw NativAudioTranscriptionError.invalidResponse
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativAudioTranscriptionError.invalidResponse
        }
        if object["type"] as? String == "error" {
            throw Self.serverError(from: object)
        }
        return object
    }

    private func fail(_ error: Error) {
        guard firstError == nil else { return }
        firstError = error
        completion?.resume(throwing: error)
        completion = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        receiveTask = nil
        session.invalidateAndCancel()
    }

    private static func requireEvent(_ event: [String: Any], type: String) throws {
        guard event["type"] as? String == type else {
            throw NativAudioTranscriptionError.invalidResponse
        }
    }

    private static func serverError(from event: [String: Any]) -> Error {
        let error = event["error"] as? [String: Any]
        let message = error?["message"] as? String ?? "Realtime transcription failed."
        return NativAudioTranscriptionError.realtime(message)
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
