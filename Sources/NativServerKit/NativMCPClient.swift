import Foundation

public struct MCPServerConfiguration: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]
    public var consentExemptTools: Set<String>

    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        arguments: [String],
        environment: [String: String] = [:],
        consentExemptTools: Set<String> = []
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.consentExemptTools = consentExemptTools
    }
}

public struct MCPToolDescriptor: Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: MLXJSONValue

    public init(name: String, description: String, inputSchema: MLXJSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum MCPServerState: Equatable, Sendable {
    case stopped
    case starting
    case running(toolCount: Int)
    case crashed(exitCode: Int32)
}

public enum MCPClientError: LocalizedError, Sendable {
    case processUnavailable
    case malformedResponse(String)
    case serverError(code: Int, message: String)
    case callTimedOut
    case invalidToolResult

    public var errorDescription: String? {
        switch self {
        case .processUnavailable:
            "The MCP server is not running."
        case .malformedResponse(let raw):
            "Malformed MCP response: \(raw)"
        case .serverError(let code, let message):
            "MCP server error \(code): \(message)"
        case .callTimedOut:
            "The MCP tool call timed out."
        case .invalidToolResult:
            "The MCP tool result did not contain usable text content."
        }
    }
}

public enum MCPToolNameQualifier {
    private static let prefix = "mcp__"
    private static let separator = "__"

    public static func isValidServerName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains(separator)
    }

    public static func qualify(server: String, tool: String) -> String {
        "\(prefix)\(server)\(separator)\(tool)"
    }

    public static func unqualify(_ name: String) -> (server: String, tool: String)? {
        guard name.hasPrefix(prefix) else { return nil }
        let remainder = name.dropFirst(prefix.count)
        guard let separatorRange = remainder.range(of: separator) else { return nil }
        let server = String(remainder[..<separatorRange.lowerBound])
        let tool = String(remainder[separatorRange.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }

    public static func hasPrefix(_ name: String) -> Bool {
        name.hasPrefix(prefix)
    }
}

public enum MCPLineFramer {
    public static func extractLines(appending chunk: String, to buffer: inout String) -> [String] {
        buffer += chunk
        var lines: [String] = []
        while let newlineRange = buffer.range(of: "\n") {
            let line = String(buffer[..<newlineRange.lowerBound])
            buffer.removeSubrange(..<newlineRange.upperBound)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append(trimmed)
            }
        }
        return lines
    }
}

public enum MCPJSONRPCCodec {
    public enum DecodedResponse: Equatable {
        case result(id: Int, value: MLXJSONValue)
        case error(id: Int, code: Int, message: String)
        case malformedEnvelope(id: Int)
        case unrecognized
    }

    public static func decodeResponse(_ line: String) -> DecodedResponse {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(MLXJSONValue.self, from: data),
              case .object(let object) = value,
              case .number(let rawID)? = object["id"]
        else {
            return .unrecognized
        }
        let id = Int(rawID)

        if case .object(let errorObject)? = object["error"] {
            return .error(
                id: id,
                code: numericValue(errorObject["code"]),
                message: stringValue(errorObject["message"]) ?? "Unknown MCP error"
            )
        }
        if let result = object["result"] {
            return .result(id: id, value: result)
        }
        return .malformedEnvelope(id: id)
    }

    public static func encodeRequest(id: Int, method: String, params: MLXJSONValue) throws -> Data {
        let payload: MLXJSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params
        ])
        var data = try JSONEncoder().encode(payload)
        data.append(0x0A)
        return data
    }

    public static func encodeNotification(method: String) throws -> Data {
        let payload: MLXJSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": .object([:])
        ])
        var data = try JSONEncoder().encode(payload)
        data.append(0x0A)
        return data
    }

    public static func toolDescriptors(fromToolsListResult result: MLXJSONValue) throws -> [MCPToolDescriptor] {
        guard case .object(let object) = result,
              case .array(let toolValues)? = object["tools"]
        else {
            throw MCPClientError.malformedResponse("tools/list result missing a \"tools\" array")
        }
        return try toolValues.map(toolDescriptor)
    }

    public static func parseArguments(_ argumentsJSON: String?) throws -> MLXJSONValue {
        guard let argumentsJSON, let data = argumentsJSON.data(using: .utf8), !argumentsJSON.isEmpty else {
            return .object([:])
        }
        return try MLXJSONValue(jsonData: data)
    }

    public static func extractText(fromToolCallResult result: MLXJSONValue) throws -> String {
        guard case .object(let object) = result,
              case .array(let contentValues)? = object["content"]
        else {
            throw MCPClientError.invalidToolResult
        }
        let texts = contentValues.compactMap { value -> String? in
            guard case .object(let part) = value,
                  case .string("text")? = part["type"],
                  case .string(let text)? = part["text"]
            else {
                return nil
            }
            return text
        }
        guard !texts.isEmpty else {
            throw MCPClientError.invalidToolResult
        }
        let combined = texts.joined(separator: "\n")
        if case .bool(true)? = object["isError"] {
            throw MCPClientError.serverError(code: -32000, message: combined)
        }
        return combined
    }

    private static func toolDescriptor(_ value: MLXJSONValue) throws -> MCPToolDescriptor {
        guard case .object(let object) = value,
              case .string(let name)? = object["name"]
        else {
            throw MCPClientError.malformedResponse("tool descriptor missing a \"name\"")
        }
        let description = stringValue(object["description"]) ?? ""
        let inputSchema = object["inputSchema"] ?? .object([
            "type": .string("object"),
            "properties": .object([:])
        ])
        return MCPToolDescriptor(name: name, description: description, inputSchema: inputSchema)
    }

    private static func numericValue(_ value: MLXJSONValue?) -> Int {
        guard case .number(let value)? = value else { return -1 }
        return Int(value)
    }

    private static func stringValue(_ value: MLXJSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }
}

actor MCPStdioTransport {
    private let process: NativProcessController
    private let requestTimeoutSeconds: Double
    private var buffer = ""
    private var pending: [Int: CheckedContinuation<MLXJSONValue, Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var nextRequestID = 0
    private let outputContinuation: AsyncStream<String>.Continuation

    init(process: NativProcessController, requestTimeoutSeconds: Double = 30) {
        self.process = process
        self.requestTimeoutSeconds = requestTimeoutSeconds
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.outputContinuation = continuation
        process.onOutput = { chunk in
            continuation.yield(chunk)
        }
        Task { [weak self] in
            for await chunk in stream {
                await self?.consume(chunk)
            }
        }
    }

    func start(executableURL: URL, arguments: [String], environment: [String: String]) throws {
        try process.start(executableURL: executableURL, arguments: arguments, environment: environment)
    }

    func stop() {
        failAllPending(with: MCPClientError.processUnavailable)
        outputContinuation.finish()
        try? process.stop()
    }

    func initialize() async throws {
        _ = try await request(method: "initialize", params: .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("Nativ"),
                "version": .string("1.0")
            ])
        ]))
        try send(MCPJSONRPCCodec.encodeNotification(method: "notifications/initialized"))
    }

    func listTools() async throws -> [MCPToolDescriptor] {
        let result = try await request(method: "tools/list", params: .object([:]))
        return try MCPJSONRPCCodec.toolDescriptors(fromToolsListResult: result)
    }

    func callTool(name: String, argumentsJSON: String?) async throws -> String {
        let arguments = try MCPJSONRPCCodec.parseArguments(argumentsJSON)
        let result = try await request(
            method: "tools/call",
            params: .object(["name": .string(name), "arguments": arguments])
        )
        return try MCPJSONRPCCodec.extractText(fromToolCallResult: result)
    }

    private func request(method: String, params: MLXJSONValue) async throws -> MLXJSONValue {
        let id = nextRequestID
        nextRequestID += 1
        try send(MCPJSONRPCCodec.encodeRequest(id: id, method: method, params: params))

        let timeoutSeconds = requestTimeoutSeconds
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeoutTasks[id] = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                await self.timeoutIfStillPending(id: id)
            }
        }
    }

    private func send(_ data: Data) throws {
        try process.write(data)
    }

    private func resolvePending(id: Int, result: Result<MLXJSONValue, Error>) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func timeoutIfStillPending(id: Int) {
        timeoutTasks.removeValue(forKey: id)
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: MCPClientError.callTimedOut)
    }

    private func failAllPending(with error: Error) {
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
    }

    private func consume(_ chunk: String) {
        for line in MCPLineFramer.extractLines(appending: chunk, to: &buffer) {
            handle(decoded: MCPJSONRPCCodec.decodeResponse(line), rawLine: line)
        }
    }

    private func handle(decoded: MCPJSONRPCCodec.DecodedResponse, rawLine: String) {
        switch decoded {
        case .result(let id, let value):
            resolvePending(id: id, result: .success(value))
        case .error(let id, let code, let message):
            resolvePending(id: id, result: .failure(MCPClientError.serverError(code: code, message: message)))
        case .malformedEnvelope(let id):
            resolvePending(id: id, result: .failure(MCPClientError.malformedResponse(rawLine)))
        case .unrecognized:
            break
        }
    }
}

@MainActor
public final class MCPServerConnection: ObservableObject, Identifiable {
    public var id: MCPServerConfiguration.ID { configuration.id }
    public let configuration: MCPServerConfiguration
    @Published public private(set) var state: MCPServerState = .stopped
    @Published public private(set) var tools: [MCPToolDescriptor] = []
    @Published public private(set) var lastError: String?

    private let process = NativProcessController()
    private let transport: MCPStdioTransport
    private var isStopping = false

    public init(configuration: MCPServerConfiguration, requestTimeoutSeconds: Double = 30) {
        self.configuration = configuration
        self.transport = MCPStdioTransport(process: process, requestTimeoutSeconds: requestTimeoutSeconds)
        process.onTermination = { [weak self] exitCode in
            Task { @MainActor in
                self?.handleTermination(exitCode: exitCode)
            }
        }
    }

    public func start(additionalEnvironment: [String: String] = [:]) async {
        isStopping = false
        state = .starting
        tools = []
        lastError = nil
        let launchEnvironment = additionalEnvironment.merging(configuration.environment) { _, override in override }
        do {
            try await transport.start(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: [configuration.command] + configuration.arguments,
                environment: launchEnvironment
            )
            try await transport.initialize()
            let descriptors = try await transport.listTools()
            tools = descriptors
            state = .running(toolCount: descriptors.count)
        } catch {
            await transport.stop()
            lastError = error.localizedDescription
            state = .crashed(exitCode: -1)
        }
    }

    public func stop() async {
        isStopping = true
        await transport.stop()
        tools = []
        state = .stopped
    }

    public func stopSynchronously() {
        isStopping = true
        try? process.stop(timeout: 2)
        tools = []
        state = .stopped
    }

    public func callTool(name: String, argumentsJSON: String?) async throws -> String {
        guard case .running = state else {
            throw MCPClientError.processUnavailable
        }
        return try await transport.callTool(name: name, argumentsJSON: argumentsJSON)
    }

    private func handleTermination(exitCode: Int32) {
        guard !isStopping else { return }
        tools = []
        lastError = nil
        state = .crashed(exitCode: exitCode)
        Task { await transport.stop() }
    }
}

@MainActor
public final class MCPServerManager: ObservableObject {
    @Published public private(set) var connections: [MCPServerConnection] = []

    public init() {}

    public func configure(_ configurations: [MCPServerConfiguration]) {
        let existingByID = Dictionary(uniqueKeysWithValues: connections.map { ($0.configuration.id, $0) })
        var updated: [MCPServerConnection] = []
        for configuration in configurations {
            if let existing = existingByID[configuration.id], existing.configuration == configuration {
                updated.append(existing)
            } else {
                existingByID[configuration.id]?.stopSynchronously()
                updated.append(MCPServerConnection(configuration: configuration))
            }
        }
        let keptIDs = Set(configurations.map(\.id))
        for (id, connection) in existingByID where !keptIDs.contains(id) {
            connection.stopSynchronously()
        }
        connections = updated
    }

    public func startAll(additionalEnvironment: [String: String] = [:]) async {
        for connection in connections {
            await connection.start(additionalEnvironment: additionalEnvironment)
        }
    }

    public func start(_ configurationID: MCPServerConfiguration.ID, additionalEnvironment: [String: String] = [:]) async {
        guard let connection = connections.first(where: { $0.configuration.id == configurationID }) else { return }
        await connection.start(additionalEnvironment: additionalEnvironment)
    }

    public func stop(_ configurationID: MCPServerConfiguration.ID) async {
        guard let connection = connections.first(where: { $0.configuration.id == configurationID }) else { return }
        await connection.stop()
    }

    public func stopAllSynchronously() {
        connections.forEach { $0.stopSynchronously() }
    }
}
