import Foundation

public enum NativChatError: Error, LocalizedError, CustomStringConvertible {
    case invalidResponse
    case httpStatus(Int, String)
    case missingAssistantContent
    case malformedStreamEvent(String)

    public var description: String {
        switch self {
        case .invalidResponse:
            return "Invalid chat response"
        case .httpStatus(let statusCode, let body):
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBody.isEmpty {
                return "Chat endpoint returned HTTP \(statusCode)"
            }
            return "Chat endpoint returned HTTP \(statusCode): \(trimmedBody)"
        case .missingAssistantContent:
            return "Chat response did not include assistant content"
        case .malformedStreamEvent(let event):
            return "Malformed chat stream event: \(event)"
        }
    }

    public var errorDescription: String? {
        description
    }
}

public struct MLXChatMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: MLXChatMessageContent?
    public var reasoningContent: String?
    public var toolCalls: [MLXChatToolCall]?
    public var toolCallID: String?
    public var name: String?

    public init(
        role: String,
        content: String?,
        reasoningContent: String? = nil,
        toolCalls: [MLXChatToolCall]? = nil,
        toolCallID: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content.map(MLXChatMessageContent.text)
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
    }

    public init(
        role: String,
        content: MLXChatMessageContent?,
        reasoningContent: String? = nil,
        toolCalls: [MLXChatToolCall]? = nil,
        toolCallID: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
    }

    public var textContent: String? {
        content?.textValue
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
        case reasoning
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
        content = try container.decodeIfPresent(MLXChatMessageContent.self, forKey: .content)
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
            ?? container.decodeIfPresent(String.self, forKey: .reasoning)
        toolCalls = try container.decodeIfPresent([MLXChatToolCall].self, forKey: .toolCalls)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(name, forKey: .name)
    }
}

public struct MLXChatFunctionCall: Codable, Equatable, Sendable {
    public var name: String?
    public var arguments: String?

    public init(name: String?, arguments: String?) {
        self.name = name
        self.arguments = arguments
    }

    enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        if let string = try? container.decodeIfPresent(String.self, forKey: .arguments) {
            arguments = string
        } else if let value = try container.decodeIfPresent(MLXJSONValue.self, forKey: .arguments) {
            let data = try JSONEncoder().encode(value)
            arguments = String(decoding: data, as: UTF8.self)
        } else {
            arguments = nil
        }
    }
}

public struct MLXChatToolCall: Codable, Equatable, Sendable {
    public var index: Int?
    public var id: String?
    public var type: String?
    public var function: MLXChatFunctionCall?

    public init(
        index: Int? = nil,
        id: String?,
        type: String? = "function",
        function: MLXChatFunctionCall?
    ) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct MLXChatFunctionDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var parameters: MLXJSONValue

    public init(name: String, description: String, parameters: MLXJSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct MLXChatToolDefinition: Codable, Equatable, Sendable {
    public var type: String
    public var function: MLXChatFunctionDefinition

    public init(function: MLXChatFunctionDefinition) {
        self.type = "function"
        self.function = function
    }
}

public enum MLXChatMessageContent: Codable, Equatable, Sendable {
    case text(String)
    case parts([MLXChatContentPart])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }

        self = .parts(try container.decode([MLXChatContentPart].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }

    public var textValue: String? {
        switch self {
        case .text(let text):
            return text
        case .parts(let parts):
            let text = parts.compactMap(\.text).joined(separator: " ")
            return text.isEmpty ? nil : text
        }
    }
}

public struct MLXChatContentPart: Codable, Equatable, Sendable {
    public var type: String
    public var text: String?
    public var imageURL: MLXChatImageURL?

    public init(text: String) {
        self.type = "text"
        self.text = text
        self.imageURL = nil
    }

    public init(imageURL: String) {
        self.type = "image_url"
        self.text = nil
        self.imageURL = MLXChatImageURL(url: imageURL)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }
}

public struct MLXChatImageURL: Codable, Equatable, Sendable {
    public var url: String

    public init(url: String) {
        self.url = url
    }
}

public struct MLXChatUsage: Decodable, Equatable, Sendable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
    public let promptTokensPerSecond: Double?
    public let decodeTokensPerSecond: Double?
    public let peakMemoryGB: Double?

    init(
        promptTokens: Int?,
        completionTokens: Int?,
        totalTokens: Int?,
        promptTokensPerSecond: Double?,
        decodeTokensPerSecond: Double?,
        peakMemoryGB: Double?
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.promptTokensPerSecond = promptTokensPerSecond
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.peakMemoryGB = peakMemoryGB
    }

    public var resolvedTotalTokens: Int? {
        if let totalTokens {
            return totalTokens
        }
        if let promptTokens, let completionTokens {
            return promptTokens + completionTokens
        }
        return completionTokens
    }

    public func resolvedDecodeTokensPerSecond(
        requestElapsedSeconds: Double?
    ) -> Double? {
        if let decodeTokensPerSecond,
           decodeTokensPerSecond > 0,
           decodeTokensPerSecond.isFinite {
            return decodeTokensPerSecond
        }

        guard let completionTokens,
              completionTokens > 0,
              let requestElapsedSeconds,
              requestElapsedSeconds > 0,
              requestElapsedSeconds.isFinite
        else {
            return nil
        }

        return Double(completionTokens) / requestElapsedSeconds
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptTokensPerSecond = "prompt_tps"
        case decodeTokensPerSecond = "generation_tps"
        case peakMemoryGB = "peak_memory"
    }

    fileprivate func resolvingTimings(from timings: MLXChatTimings?) -> MLXChatUsage {
        MLXChatUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            promptTokensPerSecond: promptTokensPerSecond,
            decodeTokensPerSecond: timings?.resolvedDecodeTokensPerSecond
                ?? decodeTokensPerSecond,
            peakMemoryGB: timings?.peakMemoryGB ?? peakMemoryGB
        )
    }
}

public struct MLXChatCompletion: Equatable, Sendable {
    public let model: String?
    public let content: String
    public let reasoningContent: String?
    public let toolCalls: [MLXChatToolCall]
    public let finishReason: String?
    public let usage: MLXChatUsage?
    public let requestElapsedSeconds: Double?

    public var resolvedDecodeTokensPerSecond: Double? {
        usage?.resolvedDecodeTokensPerSecond(
            requestElapsedSeconds: requestElapsedSeconds
        )
    }
}

public struct MLXChatStreamDelta: Equatable, Sendable {
    public let content: String?
    public let reasoningContent: String?
    public let toolCalls: [MLXChatToolCall]?
    public let decodeTokensPerSecond: Double?
    public let generatedTokens: Int?

    public init(
        content: String? = nil,
        reasoningContent: String? = nil,
        toolCalls: [MLXChatToolCall]? = nil,
        decodeTokensPerSecond: Double? = nil,
        generatedTokens: Int? = nil
    ) {
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.generatedTokens = generatedTokens
    }
}

public struct MLXChatStreamOptions: Encodable, Equatable, Sendable {
    public var includeUsage: Bool

    public init(includeUsage: Bool) {
        self.includeUsage = includeUsage
    }

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

public enum MLXJSONValue: Codable, Equatable, Sendable {
    case object([String: MLXJSONValue])
    case array([MLXJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: jsonData)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MLXJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: MLXJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct MLXChatResponseFormat: Encodable, Equatable, Sendable {
    public var type: String
    public var jsonSchema: MLXChatJSONSchema

    public init(name: String, schema: MLXJSONValue, strict: Bool = true) {
        self.type = "json_schema"
        self.jsonSchema = MLXChatJSONSchema(name: name, strict: strict, schema: schema)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

public struct MLXChatJSONSchema: Encodable, Equatable, Sendable {
    public var name: String
    public var strict: Bool
    public var schema: MLXJSONValue

    public init(name: String, strict: Bool, schema: MLXJSONValue) {
        self.name = name
        self.strict = strict
        self.schema = schema
    }
}

public struct MLXChatCompletionRequest: Encodable, Equatable, Sendable {
    public var model: String
    public var messages: [MLXChatMessage]
    public var maxTokens: Int
    public var temperature: Double
    public var topK: Int
    public var topP: Double
    public var minP: Double
    public var repetitionPenalty: Double?
    public var enableThinking: Bool?
    public var thinkingBudget: Int?
    public var thinkingStartToken: String?
    public var thinkingEndToken: String?
    public var responseFormat: MLXChatResponseFormat?
    public var tools: [MLXChatToolDefinition]?
    public var toolChoice: String?
    public var stream: Bool
    public var streamOptions: MLXChatStreamOptions?

    public init(
        model: String,
        messages: [MLXChatMessage],
        maxTokens: Int,
        temperature: Double,
        topK: Int,
        topP: Double,
        minP: Double,
        repetitionPenalty: Double? = nil,
        enableThinking: Bool? = nil,
        thinkingBudget: Int? = nil,
        thinkingStartToken: String? = nil,
        thinkingEndToken: String? = nil,
        responseFormat: MLXChatResponseFormat? = nil,
        tools: [MLXChatToolDefinition]? = nil,
        toolChoice: String? = nil,
        stream: Bool = false,
        streamOptions: MLXChatStreamOptions? = nil
    ) {
        self.model = model
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.enableThinking = enableThinking
        self.thinkingBudget = thinkingBudget
        self.thinkingStartToken = thinkingStartToken
        self.thinkingEndToken = thinkingEndToken
        self.responseFormat = responseFormat
        self.tools = tools
        self.toolChoice = toolChoice
        self.stream = stream
        self.streamOptions = streamOptions
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case temperature
        case topK = "top_k"
        case topP = "top_p"
        case minP = "min_p"
        case repetitionPenalty = "repetition_penalty"
        case enableThinking = "enable_thinking"
        case thinkingBudget = "thinking_budget"
        case thinkingStartToken = "thinking_start_token"
        case thinkingEndToken = "thinking_end_token"
        case responseFormat = "response_format"
        case tools
        case toolChoice = "tool_choice"
        case stream
        case streamOptions = "stream_options"
    }
}

public final class NativChatClient {
    private let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8080")!,
        timeout: TimeInterval = 600
    ) {
        self.baseURL = baseURL
        self.timeout = timeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func completeChat(_ request: MLXChatCompletionRequest) async throws -> MLXChatCompletion {
        var payload = request
        payload.stream = false
        payload.streamOptions = nil

        let requestStartedAt = Date()
        let urlRequest = try makeURLRequest(payload: payload, accepts: "application/json")
        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NativChatError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NativChatError.httpStatus(httpResponse.statusCode, String(decoding: data, as: UTF8.self))
        }

        let decoded = try decoder.decode(ChatCompletionResponse.self, from: data)
        guard let choice = decoded.choices.first else {
            throw NativChatError.missingAssistantContent
        }
        let resolvedContent = try validatedAssistantContent(
            content: choice.message.textContent ?? "",
            reasoningContent: choice.message.reasoningContent,
            toolCalls: choice.message.toolCalls
        )

        return MLXChatCompletion(
            model: decoded.model,
            content: resolvedContent.content,
            reasoningContent: resolvedContent.reasoningContent,
            toolCalls: choice.message.toolCalls ?? [],
            finishReason: choice.finishReason,
            usage: decoded.resolvedUsage,
            requestElapsedSeconds: Date().timeIntervalSince(requestStartedAt)
        )
    }

    public func streamChat(
        _ request: MLXChatCompletionRequest,
        onDelta: @escaping (String) async -> Void
    ) async throws -> MLXChatCompletion {
        try await streamChat(request, onEvent: { event in
            if let content = event.content, !content.isEmpty {
                await onDelta(content)
            }
        })
    }

    public func streamChat(
        _ request: MLXChatCompletionRequest,
        onEvent: @escaping (MLXChatStreamDelta) async -> Void
    ) async throws -> MLXChatCompletion {
        var payload = request
        payload.stream = true
        payload.streamOptions = MLXChatStreamOptions(includeUsage: true)

        let requestStartedAt = Date()
        let urlRequest = try makeURLRequest(payload: payload, accepts: "text/event-stream")
        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NativChatError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NativChatError.httpStatus(httpResponse.statusCode, await readErrorBody(from: bytes))
        }

        var content = ""
        var reasoningContent = ""
        var finishReason: String?
        var usage: MLXChatUsage?
        var timings: MLXChatTimings?
        var responseModel: String?
        var streamedGeneratedTokens = 0
        var toolCallAccumulator = MLXChatToolCallAccumulator()

        for try await line in bytes.lines {
            try Task.checkCancellation()

            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.hasPrefix("data:") else {
                continue
            }

            let dataString = trimmedLine
                .dropFirst("data:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if dataString == "[DONE]" {
                break
            }
            guard let data = dataString.data(using: .utf8) else {
                throw NativChatError.malformedStreamEvent(dataString)
            }

            let chunk = try decoder.decode(ChatStreamChunk.self, from: data)
            responseModel = chunk.model ?? responseModel
            usage = chunk.usage ?? usage
            timings = chunk.timings ?? timings
            let decodeTokensPerSecond = chunk.timings?.resolvedDecodeTokensPerSecond

            if let choice = chunk.choices.first {
                finishReason = choice.finishReason ?? finishReason
                let contentDelta = choice.delta.textContent
                let reasoningDelta = choice.delta.reasoningContent
                let toolCallDeltas = choice.delta.toolCalls
                if let contentDelta, !contentDelta.isEmpty {
                    content += contentDelta
                }
                if let reasoningDelta, !reasoningDelta.isEmpty {
                    reasoningContent += reasoningDelta
                }
                let hasGeneratedToken = contentDelta?.isEmpty == false
                    || reasoningDelta?.isEmpty == false
                if hasGeneratedToken {
                    streamedGeneratedTokens += 1
                }
                if let toolCallDeltas, !toolCallDeltas.isEmpty {
                    toolCallAccumulator.merge(toolCallDeltas)
                }
                if contentDelta?.isEmpty == false
                    || reasoningDelta?.isEmpty == false
                    || toolCallDeltas?.isEmpty == false
                    || decodeTokensPerSecond != nil {
                    await onEvent(
                        MLXChatStreamDelta(
                            content: contentDelta,
                            reasoningContent: reasoningDelta,
                            toolCalls: toolCallDeltas,
                            decodeTokensPerSecond: decodeTokensPerSecond,
                            generatedTokens: chunk.usage?.completionTokens
                                ?? streamedGeneratedTokens
                        )
                    )
                }
            } else if chunk.usage?.completionTokens != nil || decodeTokensPerSecond != nil {
                await onEvent(
                    MLXChatStreamDelta(
                        decodeTokensPerSecond: decodeTokensPerSecond,
                        generatedTokens: chunk.usage?.completionTokens
                            ?? streamedGeneratedTokens
                    )
                )
            }
        }

        let resolvedContent = try validatedAssistantContent(
            content: content,
            reasoningContent: reasoningContent.isEmpty ? nil : reasoningContent,
            toolCalls: toolCallAccumulator.toolCalls
        )

        return MLXChatCompletion(
            model: responseModel,
            content: resolvedContent.content,
            reasoningContent: resolvedContent.reasoningContent,
            toolCalls: toolCallAccumulator.toolCalls,
            finishReason: finishReason,
            usage: resolvedUsage(usage: usage, timings: timings),
            requestElapsedSeconds: Date().timeIntervalSince(requestStartedAt)
        )
    }

    private func validatedAssistantContent(
        content: String,
        reasoningContent: String?,
        toolCalls: [MLXChatToolCall]?
    ) throws -> (content: String, reasoningContent: String?) {
        if !content.isEmpty || reasoningContent?.isEmpty == false || toolCalls?.isEmpty == false {
            return (content, reasoningContent)
        }
        throw NativChatError.missingAssistantContent
    }

    private func makeURLRequest(payload: MLXChatCompletionRequest, accepts: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accepts, forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(payload)
        return request
    }

    private func resolvedUsage(
        usage: MLXChatUsage?,
        timings: MLXChatTimings?
    ) -> MLXChatUsage? {
        if let usage {
            return usage.resolvingTimings(from: timings)
        }
        guard let timings,
              timings.resolvedDecodeTokensPerSecond != nil || timings.peakMemoryGB != nil
        else {
            return nil
        }
        return MLXChatUsage(
            promptTokens: nil,
            completionTokens: nil,
            totalTokens: nil,
            promptTokensPerSecond: nil,
            decodeTokensPerSecond: timings.resolvedDecodeTokensPerSecond,
            peakMemoryGB: timings.peakMemoryGB
        )
    }

    private func readErrorBody(from bytes: URLSession.AsyncBytes) async -> String {
        var body = ""

        do {
            for try await line in bytes.lines {
                if !body.isEmpty {
                    body.append("\n")
                }
                body.append(line)

                if body.count > 4096 {
                    body = String(body.prefix(4096))
                    break
                }
            }
        } catch {
            return body
        }

        return body
    }
}

private struct ChatCompletionResponse: Decodable {
    let model: String?
    let choices: [Choice]
    let usage: MLXChatUsage?
    let timings: MLXChatTimings?

    var resolvedUsage: MLXChatUsage? {
        if let usage {
            return usage.resolvingTimings(from: timings)
        }
        guard let timings,
              timings.resolvedDecodeTokensPerSecond != nil || timings.peakMemoryGB != nil
        else {
            return nil
        }
        return MLXChatUsage(
            promptTokens: nil,
            completionTokens: nil,
            totalTokens: nil,
            promptTokensPerSecond: nil,
            decodeTokensPerSecond: timings.resolvedDecodeTokensPerSecond,
            peakMemoryGB: timings.peakMemoryGB
        )
    }

    struct Choice: Decodable {
        let finishReason: String?
        let message: MLXChatMessage

        enum CodingKeys: String, CodingKey {
            case finishReason = "finish_reason"
            case message
        }
    }
}

private struct ChatStreamChunk: Decodable {
    let model: String?
    let choices: [Choice]
    let usage: MLXChatUsage?
    let timings: MLXChatTimings?

    struct Choice: Decodable {
        let finishReason: String?
        let delta: MLXChatMessage

        enum CodingKeys: String, CodingKey {
            case finishReason = "finish_reason"
            case delta
        }
    }
}

struct MLXChatToolCallAccumulator {
    private var callsByIndex: [Int: MLXChatToolCall] = [:]

    var toolCalls: [MLXChatToolCall] {
        callsByIndex.keys.sorted().compactMap { callsByIndex[$0] }
    }

    mutating func merge(_ deltas: [MLXChatToolCall]) {
        for (position, delta) in deltas.enumerated() {
            let index = delta.index
                ?? callsByIndex.first(where: { $0.value.id == delta.id && delta.id != nil })?.key
                ?? position
            var call = callsByIndex[index]
                ?? MLXChatToolCall(index: index, id: nil, type: nil, function: nil)

            if let id = delta.id, !id.isEmpty {
                call.id = id
            }
            if let type = delta.type, !type.isEmpty {
                call.type = type
            }
            if let functionDelta = delta.function {
                var function = call.function ?? MLXChatFunctionCall(name: nil, arguments: nil)
                function.name = mergedFragment(current: function.name, incoming: functionDelta.name)
                function.arguments = mergedFragment(
                    current: function.arguments,
                    incoming: functionDelta.arguments
                )
                call.function = function
            }
            callsByIndex[index] = call
        }
    }

    private func mergedFragment(current: String?, incoming: String?) -> String? {
        guard let incoming, !incoming.isEmpty else {
            return current
        }
        guard let current, !current.isEmpty else {
            return incoming
        }
        if current == incoming {
            return current
        }
        return current + incoming
    }
}

private struct MLXChatTimings: Decodable {
    let predictedTokensPerSecond: Double?
    let peakMemoryGB: Double?

    var resolvedDecodeTokensPerSecond: Double? {
        guard let predictedTokensPerSecond,
              predictedTokensPerSecond > 0,
              predictedTokensPerSecond.isFinite
        else {
            return nil
        }
        return predictedTokensPerSecond
    }

    enum CodingKeys: String, CodingKey {
        case predictedTokensPerSecond = "predicted_per_second"
        case peakMemoryGB = "peak_memory"
    }
}
