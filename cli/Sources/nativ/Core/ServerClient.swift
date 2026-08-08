import Foundation

/// Thin client over the local server's OpenAI-compatible API. This is the
/// durable contract — nothing here depends on Nativ's Swift internals.
struct ServerClient {
    let config: NativConfig

    /// A session that aborts if the server goes silent mid-stream. The interval
    /// is "time to wait for *more* data" and resets on every chunk, so a healthy
    /// stream (data flowing, even slowly) is never cut — only a hung server is.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 3600
        return URLSession(configuration: cfg)
    }()

    private func makeRequest(_ path: String, method: String = "GET", jsonBody: [String: Any]? = nil) throws -> URLRequest {
        let url = config.baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let key = config.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if let jsonBody {
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// True if the server answers at all (any HTTP status).
    func isUp() async -> Bool {
        guard var req = try? makeRequest("v1/models") else { return false }
        req.timeoutInterval = 3
        guard let (_, resp) = try? await Self.session.data(for: req) else { return false }
        return resp is HTTPURLResponse
    }

    /// Poll until the server answers or `timeout` seconds elapse. Returns whether
    /// it came up, so callers (e.g. `serve`) can report readiness honestly.
    func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await isUp() { return true }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }

    /// Model ids the server reports at `/v1/models`.
    func models() async throws -> [String] {
        let (data, resp) = try await Self.session.data(for: try makeRequest("v1/models"))
        try Self.checkOK(resp, data)
        struct Response: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        let decoded = try? JSONDecoder().decode(Response.self, from: data)
        return decoded?.data.map(\.id) ?? []
    }

    /// Stream a chat completion, invoking `onDelta` for each content chunk.
    func streamChat(model: String, messages: [[String: Any]], onDelta: (String) -> Void) async throws {
        let body: [String: Any] = ["model": model, "messages": messages, "stream": true]
        let req = try makeRequest("v1/chat/completions", method: "POST", jsonBody: body)
        let (bytes, resp) = try await Self.session.bytes(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var detail = ""
            for try await line in bytes.lines {
                detail += line
                if detail.count > 400 { break }
            }
            throw CLIError.server("chat request failed (HTTP \(http.statusCode)) \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        for try await line in bytes.lines {
            switch Self.parseSSE(line) {
            case .done: return
            case .content(let text): onDelta(text)
            case .ignore: continue
            }
        }
    }

    /// One non-streamed completion, returned as pretty-printed JSON (`--json`).
    func chatJSON(model: String, messages: [[String: Any]]) async throws -> String {
        let body: [String: Any] = ["model": model, "messages": messages, "stream": false]
        let (data, resp) = try await Self.session.data(for: try makeRequest("v1/chat/completions", method: "POST", jsonBody: body))
        try Self.checkOK(resp, data)
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else {
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        return str
    }

    /// A parsed line of an OpenAI SSE stream. Pure + static so it's unit-testable.
    enum SSEEvent: Equatable { case content(String), done, ignore }

    static func parseSSE(_ line: String) -> SSEEvent {
        guard line.hasPrefix("data:") else { return .ignore }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String
        else { return .ignore }
        return .content(content)
    }

    /// Embeddings via `/v1/embeddings`; returns one vector per input.
    func embeddings(model: String, input: [String]) async throws -> [[Double]] {
        let body: [String: Any] = ["model": model, "input": input]
        let (data, resp) = try await Self.session.data(for: try makeRequest("v1/embeddings", method: "POST", jsonBody: body))
        try Self.checkOK(resp, data)
        struct Response: Decodable { struct Entry: Decodable { let embedding: [Double] }; let data: [Entry] }
        return try JSONDecoder().decode(Response.self, from: data).data.map(\.embedding)
    }

    /// Generate an image via `/v1/images/generations`; returns the decoded bytes.
    func generateImage(model: String, prompt: String, size: String?) async throws -> Data {
        var body: [String: Any] = ["model": model, "prompt": prompt, "response_format": "b64_json", "n": 1]
        if let size { body["size"] = size }
        let (data, resp) = try await Self.session.data(for: try makeRequest("v1/images/generations", method: "POST", jsonBody: body))
        try Self.checkOK(resp, data)
        struct Response: Decodable {
            struct Item: Decodable { let b64JSON: String?; enum CodingKeys: String, CodingKey { case b64JSON = "b64_json" } }
            let data: [Item]
        }
        guard let b64 = try JSONDecoder().decode(Response.self, from: data).data.first?.b64JSON,
              let image = Data(base64Encoded: b64) else {
            throw CLIError.server("no image data in response")
        }
        return image
    }

    /// Synthesize speech via `/v1/audio/speech`; returns the encoded audio bytes.
    func speak(model: String, input: String, voice: String?, speed: Double?, format: String) async throws -> Data {
        var body: [String: Any] = ["model": model, "input": input, "response_format": format]
        if let voice { body["voice"] = voice }
        if let speed { body["speed"] = speed }
        let (data, resp) = try await Self.session.data(for: try makeRequest("v1/audio/speech", method: "POST", jsonBody: body))
        try Self.checkOK(resp, data)
        return data
    }

    /// Transcribe an audio file via multipart `/v1/audio/transcriptions`.
    func transcribe(fileURL: URL, model: String) async throws -> String {
        let boundary = "nativ-\(UUID().uuidString)"
        var req = try makeRequest("v1/audio/transcriptions", method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.multipartBody(boundary: boundary, model: model, fileURL: fileURL)

        let (data, resp) = try await Self.session.data(for: req)
        try Self.checkOK(resp, data)
        struct Response: Decodable { let text: String }
        return (try? JSONDecoder().decode(Response.self, from: data))?.text
            ?? String(data: data, encoding: .utf8) ?? ""
    }

    /// Build the transcription multipart body (model field + file). Static so the
    /// framing is unit-testable without a live server.
    static func multipartBody(boundary: String, model: String, fileURL: URL) throws -> Data {
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func checkOK(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw CLIError.server("no response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CLIError.server("HTTP \(http.statusCode) \(body.prefix(200))")
        }
    }
}
