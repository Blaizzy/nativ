import Foundation

public struct MLXResponseCompletion: Sendable {
    public let completion: MLXChatCompletion
    public let compaction: MLXJSONValue?
    public let inputTokensBeforeCompaction: Int?
}

public final class NativResponsesClient: @unchecked Sendable {
    private let baseURL: URL
    private let apiKey: String?
    private let tenant: String
    private let session: URLSession
    private let idleTimeout: TimeInterval
    private let ownsSession: Bool

    public init(
        baseURL: URL,
        apiKey: String? = nil,
        tenant: String,
        idleTimeout: TimeInterval = NativChatClient.defaultIdleTimeout,
        resourceTimeout: TimeInterval = NativChatClient.defaultResourceTimeout,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.tenant = tenant
        self.idleTimeout = idleTimeout
        self.ownsSession = session == nil
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = idleTimeout
            configuration.timeoutIntervalForResource = resourceTimeout
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    deinit {
        if ownsSession {
            session.finishTasksAndInvalidate()
        }
    }

    public func contextLimit(for model: String) async throws -> Int? {
        let (data, response) = try await session.data(for: makeRequest(path: "health"))
        try validate(response, body: String(decoding: data, as: UTF8.self))
        let health = try MLXJSONValue(jsonData: data)
        guard health["loaded_model"]?.stringValue == model else { return nil }
        return health["effective_context_limit"]?.intValue
    }

    /// Count the same capsule, conversation tail, and current context used for generation.
    public func countInputTokens(
        for request: MLXChatCompletionRequest, input: [MLXJSONValue]
    ) async throws -> Int? {
        try await countInputTokens(makeResponseRequest(request, input: input, compactThreshold: 1))
    }

    public static func inputItems(_ messages: [MLXChatMessage]) throws -> [MLXJSONValue] {
        try conversationMessages(messages).map { message in
            // Preserve the server's chat-message extensions for reasoning and grouped tool calls.
            var item = try JSONDecoder().decode(
                [String: MLXJSONValue].self, from: JSONEncoder().encode(message)
            )
            item["type"] = .string("message")
            return .object(item)
        }
    }

    public static func conversationMessages(_ messages: [MLXChatMessage]) -> [MLXChatMessage] {
        messages.filter { !isInstruction($0) }
    }

    private static func isInstruction(_ message: MLXChatMessage) -> Bool {
        message.role == "system" || message.role == "developer"
    }

    func makeResponseRequest(
        _ request: MLXChatCompletionRequest,
        input: [MLXJSONValue],
        compactThreshold: Int
    ) throws -> URLRequest {
        var payload = try JSONDecoder().decode(
            [String: MLXJSONValue].self, from: JSONEncoder().encode(request)
        )
        payload.removeValue(forKey: "messages")
        payload.removeValue(forKey: "stream_options")
        payload["max_output_tokens"] = payload.removeValue(forKey: "max_tokens")
        let instructions = request.messages.filter(Self.isInstruction)
            .compactMap(\.textContent).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !instructions.isEmpty {
            payload["instructions"] = .string(instructions)
        }
        payload["input"] = .array(input + (try Self.inputItems(request.contextMessages)))
        payload["stream"] = .bool(true)
        payload["store"] = .bool(false)
        payload["context_management"] = .array([.object([
            "type": .string("compaction"),
            "compact_threshold": .number(Double(compactThreshold)),
        ])])
        var urlRequest = makeRequest(path: "v1/responses")
        urlRequest.timeoutInterval = idleTimeout
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONEncoder().encode(payload)
        return urlRequest
    }

    public func streamResponse(
        _ request: MLXChatCompletionRequest,
        input: [MLXJSONValue],
        compactThreshold: Int,
        onCompaction: (@Sendable (Int) async -> Void)? = nil,
        onEvent: @escaping @Sendable (MLXChatStreamDelta) async -> Void
    ) async throws -> MLXResponseCompletion {
        let startedAt = Date()
        let urlRequest = try makeResponseRequest(request, input: input, compactThreshold: compactThreshold)
        var inputTokens: Int?
        if let onCompaction {
            // Token counts are presentation data; an unavailable count must not block generation.
            inputTokens = try? await countInputTokens(urlRequest)
            try Task.checkCancellation()
            if let inputTokens, inputTokens >= compactThreshold {
                await onCompaction(inputTokens)
            }
        }
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NativChatError.invalidResponse
        }
        if !(200..<300).contains(httpResponse.statusCode) {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw NativChatError.httpStatus(httpResponse.statusCode, String(decoding: body, as: UTF8.self))
        }

        var stream = MLXResponseStream()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            // MLX emits one JSON event per data line; AsyncBytes.lines omits blank separators.
            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if let delta = try stream.consume(data) {
                await onEvent(delta)
            }
            if stream.response != nil { break }
        }
        try Task.checkCancellation()
        return try stream.result(
            elapsed: Date().timeIntervalSince(startedAt), inputTokensBeforeCompaction: inputTokens
        )
    }

    private func countInputTokens(_ request: URLRequest) async throws -> Int? {
        var request = request
        request.url = baseURL.appendingPathComponent("v1/responses/input_tokens")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        try validate(response, body: String(decoding: data, as: UTF8.self))
        return try MLXJSONValue(jsonData: data)["input_tokens"]?.intValue
    }

    private func makeRequest(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(tenant, forHTTPHeaderField: "X-APC-Tenant")
        NativServerAuthorization.authorize(&request, apiKey: apiKey)
        return request
    }

    private func validate(_ response: URLResponse, body: String) throws {
        guard let response = response as? HTTPURLResponse else { throw NativChatError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw NativChatError.httpStatus(response.statusCode, body)
        }
    }
}

struct MLXResponseStream {
    private(set) var response: MLXJSONValue?
    private var decodeRate: Double?
    private var prefillRate: Double?
    private var peakMemoryGB: Double?
    private var toolCalls = MLXChatToolCallAccumulator()

    mutating func consume(_ data: String) throws -> MLXChatStreamDelta? {
        if data == "[DONE]" { return nil }
        let event = try MLXJSONValue(jsonData: Data(data.utf8))
        let type = event["type"]?.stringValue
        if type == "error" || type == "response.failed" || event["error"] != nil {
            throw NativChatError.serverError(
                event["error"]?["message"]?.stringValue
                    ?? event["response"]?["error"]?["message"]?.stringValue
                    ?? event["message"]?.stringValue ?? "Response generation failed."
            )
        }
        decodeRate = event["timings"]?["predicted_per_second"]?.numberValue ?? decodeRate
        prefillRate = event["timings"]?["prompt_per_second"]?.numberValue ?? prefillRate
        peakMemoryGB = event["timings"]?["peak_memory"]?.numberValue ?? peakMemoryGB
        switch type {
        case "response.output_text.delta":
            return MLXChatStreamDelta(content: event["delta"]?.stringValue, decodeTokensPerSecond: decodeRate)
        case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
            return MLXChatStreamDelta(reasoningContent: event["delta"]?.stringValue, decodeTokensPerSecond: decodeRate)
        case "response.output_item.added", "response.output_item.done":
            if let item = event["item"], var call = Self.toolCall(item) {
                call.index = event["output_index"]?.intValue
                if type == "response.output_item.added", item["arguments"] == nil {
                    call.function?.arguments = ""
                }
                if let previous = toolCalls.toolCalls.first(where: { $0.id == call.id }) {
                    let arguments = call.function?.arguments ?? ""
                    let sent = previous.function?.arguments ?? ""
                    guard arguments.utf8.starts(with: sent.utf8) else { return nil }
                    call.function?.name = nil
                    call.function?.arguments = String(decoding: arguments.utf8.dropFirst(sent.utf8.count), as: UTF8.self)
                }
                return toolDelta(call)
            }
        case "response.function_call_arguments.delta":
            guard let index = event["output_index"]?.intValue,
                  let arguments = event["delta"]?.stringValue else { return nil }
            return toolDelta(MLXChatToolCall(
                index: index, id: nil, type: nil,
                function: MLXChatFunctionCall(name: nil, arguments: arguments)
            ))
        case "response.completed", "response.incomplete":
            response = event["response"]
            guard response != nil else { throw NativChatError.invalidResponse }
        default:
            break
        }
        return nil
    }

    private mutating func toolDelta(_ call: MLXChatToolCall) -> MLXChatStreamDelta {
        toolCalls.merge([call])
        return MLXChatStreamDelta(toolCalls: [call], decodeTokensPerSecond: decodeRate)
    }

    func result(elapsed: TimeInterval, inputTokensBeforeCompaction: Int? = nil) throws -> MLXResponseCompletion {
        guard let response, let output = response["output"]?.arrayValue else {
            throw NativChatError.invalidResponse
        }
        let messages = output.filter { $0["type"]?.stringValue == "message" }
        let text = messages.flatMap { $0["content"]?.arrayValue ?? [] }
            .filter { $0["type"]?.stringValue == "output_text" }
            .compactMap { $0["text"]?.stringValue }.joined()
        let reasoning = output.filter { $0["type"]?.stringValue == "reasoning" }
            .flatMap { $0["summary"]?.arrayValue ?? [] }
            .compactMap { $0["text"]?.stringValue }.joined()
        let calls = output.compactMap(Self.toolCall)
        guard !text.isEmpty || !reasoning.isEmpty || !calls.isEmpty else {
            throw NativChatError.missingAssistantContent
        }
        let usage = response["usage"].map {
            MLXChatUsage(
                promptTokens: $0["input_tokens"]?.intValue,
                completionTokens: $0["output_tokens"]?.intValue,
                totalTokens: $0["total_tokens"]?.intValue,
                promptTokensPerSecond: prefillRate,
                decodeTokensPerSecond: decodeRate,
                peakMemoryGB: peakMemoryGB
            )
        }
        return MLXResponseCompletion(
            completion: MLXChatCompletion(
                model: response["model"]?.stringValue,
                content: text,
                reasoningContent: reasoning.isEmpty ? nil : reasoning,
                toolCalls: calls,
                finishReason: response["status"]?.stringValue == "incomplete" ? "length" : (calls.isEmpty ? "stop" : "tool_calls"),
                usage: usage,
                requestElapsedSeconds: elapsed
            ),
            compaction: output.last { $0["type"]?.stringValue == "compaction" },
            inputTokensBeforeCompaction: inputTokensBeforeCompaction
        )
    }

    private static func toolCall(_ item: MLXJSONValue) -> MLXChatToolCall? {
        guard item["type"]?.stringValue == "function_call",
              let id = item["call_id"]?.stringValue,
              let name = item["name"]?.stringValue else { return nil }
        return MLXChatToolCall(id: id, function: MLXChatFunctionCall(
            name: name, arguments: item["arguments"]?.stringValue ?? "{}"
        ))
    }
}

extension MLXJSONValue {
    subscript(key: String) -> MLXJSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var arrayValue: [MLXJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var intValue: Int? { numberValue.flatMap { Int(exactly: $0) } }
}
