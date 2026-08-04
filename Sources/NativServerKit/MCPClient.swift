import Foundation
import MCP

#if canImport(System)
import System
#else
import SystemPackage
#endif

public struct MCPToolInfo: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: MLXJSONValue

    public init(name: String, description: String, parameters: MLXJSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public enum MCPClientError: LocalizedError {
    case notConnected
    case timedOut
    case toolFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The MCP server is not connected."
        case .timedOut:
            return "The tool call timed out."
        case .toolFailed(let message):
            return message
        }
    }
}

public actor MCPClient {
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let clientName: String
    private let clientVersion: String

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var transport: StdioTransport?
    private var client: Client?

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        clientName: String = "Nativ",
        clientVersion: String = "1.0.0"
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    public var isConnected: Bool {
        client != nil
    }

    public func connect() async throws {
        guard client == nil else { return }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: outputPipe.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: inputPipe.fileHandleForWriting.fileDescriptor)
        )
        let client = Client(name: clientName, version: clientVersion)

        do {
            try await client.connect(transport: transport)
        } catch {
            if process.isRunning {
                process.terminate()
            }
            throw error
        }

        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.process = process
        self.transport = transport
        self.client = client
    }

    /// Connects and lists tools under a single deadline, so a server that hangs
    /// during startup or the handshake fails fast instead of blocking forever.
    public func connectAndListTools(timeout: TimeInterval = 60) async throws -> [MCPToolInfo] {
        try await Self.withTimeout(timeout) {
            try await self.connect()
            return try await self.listTools()
        }
    }

    public func listTools() async throws -> [MCPToolInfo] {
        guard let client else { throw MCPClientError.notConnected }

        var infos: [MCPToolInfo] = []
        var cursor: String?
        repeat {
            let (tools, next) = try await client.listTools(cursor: cursor)
            for tool in tools {
                infos.append(
                    MCPToolInfo(
                        name: tool.name,
                        description: tool.description ?? "",
                        parameters: try Self.schema(from: tool.inputSchema)
                    )
                )
            }
            cursor = next
        } while cursor != nil

        return infos
    }

    public func callTool(
        name: String,
        argumentsJSON: String?,
        timeout: TimeInterval = 120
    ) async throws -> String {
        guard let client else { throw MCPClientError.notConnected }

        let arguments = try Self.arguments(from: argumentsJSON)
        return try await Self.withTimeout(timeout) {
            let (content, isError) = try await client.callTool(name: name, arguments: arguments)
            let rendered = Self.render(content)
            if isError == true {
                throw MCPClientError.toolFailed(rendered)
            }
            return rendered
        }
    }

    public func disconnect() async {
        if let client {
            await client.disconnect()
        }
        client = nil
        transport = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        inputPipe = nil
        outputPipe = nil
    }

    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MCPClientError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw MCPClientError.timedOut
            }
            return result
        }
    }

    private static func schema(from value: Value?) throws -> MLXJSONValue {
        guard let value else {
            return .object(["type": .string("object"), "properties": .object([:])])
        }
        return try MLXJSONValue(jsonData: JSONEncoder().encode(value))
    }

    private static func arguments(from json: String?) throws -> [String: Value]? {
        guard let json, !json.isEmpty else { return nil }
        let value = try JSONDecoder().decode(Value.self, from: Data(json.utf8))
        return value.objectValue
    }

    private static func render(_ content: [Tool.Content]) -> String {
        content.map { item in
            switch item {
            case .text(let text, _, _):
                return text
            case .image(_, let mimeType, _, _):
                return "[image: \(mimeType)]"
            case .audio(_, let mimeType, _, _):
                return "[audio: \(mimeType)]"
            default:
                return "[unsupported content]"
            }
        }
        .joined(separator: "\n")
    }
}
