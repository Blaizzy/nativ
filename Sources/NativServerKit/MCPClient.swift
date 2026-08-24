import Foundation
import MCP
import Synchronization

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

public struct MCPConnectionFailure: LocalizedError, Equatable, Sendable {
    public let message: String
    public let details: String?

    public init(message: String, details: String? = nil) {
        self.message = message
        self.details = details
    }

    public var errorDescription: String? { message }
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

private final class MCPStderrCapture: Sendable {
    private struct State: Sendable {
        var data = Data()
        var wasTruncated = false
    }

    private let limit: Int
    private let state = Mutex(State())

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        state.withLock { state in
            state.data.append(chunk)
            guard state.data.count > limit else { return }
            state.data.removeFirst(state.data.count - limit)
            state.wasTruncated = true
        }
    }

    func snapshot() -> (text: String, wasTruncated: Bool) {
        state.withLock { state in
            (String(decoding: state.data, as: UTF8.self), state.wasTruncated)
        }
    }
}

public actor MCPClient {
    private struct Connection {
        let id: UUID
        let process: Process
        let inputPipe: Pipe
        let outputPipe: Pipe
        let errorPipe: Pipe
        let stderr: MCPStderrCapture
        let transport: StdioTransport
        let client: Client
    }

    private static let stderrLimit = 16_384
    private static let diagnosticLineLimit = 12

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: URL?
    private let clientName: String
    private let clientVersion: String

    private var connection: Connection?
    private var isReady = false
    private var startupFailure: MCPConnectionFailure?

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL? = nil,
        clientName: String = "Nativ",
        clientVersion: String = "1.0.0"
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    public var isConnected: Bool {
        connection != nil && isReady
    }

    public func connect() async throws {
        guard !isReady else { return }
        do {
            try await startConnection()
            isReady = true
            startupFailure = nil
        } catch {
            let failure = startupFailure ?? connectionFailure(for: error)
            await tearDownConnection()
            throw failure
        }
    }

    /// Connects and lists tools under a single deadline, so a server that hangs
    /// during startup or the handshake fails fast instead of blocking forever.
    public func connectAndListTools(timeout: TimeInterval = 60) async throws -> [MCPToolInfo] {
        if isReady {
            return try await listTools()
        }

        return try await withTaskCancellationHandler {
            do {
                let tools = try await withThrowingTaskGroup(of: [MCPToolInfo].self) { group in
                    group.addTask {
                        try await self.startConnection()
                        return try await self.listTools()
                    }
                    group.addTask {
                        let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
                        try await Task.sleep(nanoseconds: nanoseconds)
                        let failure = await self.failStartupAfterTimeout(timeout)
                        throw failure
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else {
                        throw MCPConnectionFailure(message: "Failed to connect to the MCP server.")
                    }
                    return result
                }

                guard connection != nil else {
                    throw startupFailure ?? MCPConnectionFailure(
                        message: "Failed to connect to the MCP server."
                    )
                }
                isReady = true
                startupFailure = nil
                return tools
            } catch {
                if Task.isCancelled {
                    await tearDownConnection()
                    throw CancellationError()
                }

                let failure = startupFailure ?? connectionFailure(for: error)
                await tearDownConnection()
                throw failure
            }
        } onCancel: {
            Task { await self.tearDownConnection() }
        }
    }

    private func startConnection() async throws {
        guard connection == nil else { return }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let stderrCapture = MCPStderrCapture(limit: Self.stderrLimit)
        let process = Process()
        let connectionID = UUID()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        if let workingDirectory {
            try FileManager.default.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: true
            )
            process.currentDirectoryURL = workingDirectory
        }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: outputPipe.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: inputPipe.fileHandleForWriting.fileDescriptor)
        )
        let client = Client(name: clientName, version: clientVersion)

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrCapture.append(handle.availableData)
        }
        process.terminationHandler = { [weak self, errorPipe, stderrCapture] process in
            let handle = errorPipe.fileHandleForReading
            handle.readabilityHandler = nil
            stderrCapture.append(handle.readDataToEndOfFile())
            let processSummary: String
            switch process.terminationReason {
            case .exit:
                processSummary = "Process exited with status \(process.terminationStatus)."
            case .uncaughtSignal:
                processSummary = "Process ended from signal \(process.terminationStatus)."
            @unknown default:
                processSummary = "Process ended with status \(process.terminationStatus)."
            }
            Task {
                await self?.processDidTerminate(
                    connectionID: connectionID,
                    processSummary: processSummary
                )
            }
        }

        connection = Connection(
            id: connectionID,
            process: process,
            inputPipe: inputPipe,
            outputPipe: outputPipe,
            errorPipe: errorPipe,
            stderr: stderrCapture,
            transport: transport,
            client: client
        )
        isReady = false
        startupFailure = nil

        try process.run()
        try await client.connect(transport: transport)
    }

    public func listTools() async throws -> [MCPToolInfo] {
        guard let client = connection?.client else { throw MCPClientError.notConnected }

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
        guard let client = connection?.client else { throw MCPClientError.notConnected }

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
        await tearDownConnection()
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

    private func failStartupAfterTimeout(_ timeout: TimeInterval) async -> MCPConnectionFailure {
        let seconds = max(0, Int(timeout.rounded(.up)))
        let failure = MCPConnectionFailure(
            message: "MCP server didn’t connect within \(seconds) second\(seconds == 1 ? "" : "s").",
            details: diagnosticDetails()
        )
        startupFailure = failure
        await tearDownConnection(preservingFailure: true)
        return failure
    }

    private func processDidTerminate(
        connectionID: UUID,
        processSummary: String
    ) async {
        guard connection?.id == connectionID else { return }

        if !isReady {
            startupFailure = MCPConnectionFailure(
                message: "MCP server exited before connecting.",
                details: diagnosticDetails(processSummary: processSummary)
            )
        }
        await tearDownConnection(preservingFailure: !isReady)
    }

    private func connectionFailure(for error: Error) -> MCPConnectionFailure {
        if let failure = error as? MCPConnectionFailure {
            return failure
        }

        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return MCPConnectionFailure(
            message: "Failed to connect to the MCP server.",
            details: diagnosticDetails(leading: description.isEmpty ? nil : description)
        )
    }

    private func diagnosticDetails(
        leading: String? = nil,
        processSummary: String? = nil
    ) -> String? {
        var sections = [leading, processSummary].compactMap { output -> String? in
            guard let output, !output.isEmpty else { return nil }
            let redacted = Self.redactedDiagnosticOutput(
                output,
                arguments: arguments,
                environment: environment
            )
            return redacted.isEmpty ? nil : redacted
        }

        if let capture = connection?.stderr {
            let snapshot = capture.snapshot()
            let output = Self.redactedDiagnosticOutput(
                snapshot.text,
                arguments: arguments,
                environment: environment
            )
            if !output.isEmpty {
                let prefix = snapshot.wasTruncated ? "Earlier server output was truncated.\n" : ""
                sections.append(prefix + output)
            }
        }

        let details = sections.joined(separator: "\n\n")
        return details.isEmpty ? nil : details
    }

    static func redactedDiagnosticOutput(
        _ output: String,
        arguments: [String],
        environment: [String: String]
    ) -> String {
        var result = output
        let sensitiveKeyFragments = [
            "TOKEN", "KEY", "SECRET", "PASSWORD", "AUTH", "CREDENTIAL", "PRIVATE",
        ]
        var secretValues = environment.compactMap { key, value -> String? in
            guard value.count >= 4 else { return nil }
            let normalized = key.uppercased()
            return sensitiveKeyFragments.contains(where: normalized.contains) ? value : nil
        }

        for argument in arguments {
            let lowercased = argument.lowercased()
            guard let bearerRange = lowercased.range(of: "bearer ") else { continue }
            if let value = argument[bearerRange.upperBound...]
                .split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
                .first,
                value.count >= 4 {
                secretValues.append(String(value))
            }
        }

        for secret in Set(secretValues).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }

        let lines = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        result = lines.suffix(Self.diagnosticLineLimit).joined(separator: "\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tearDownConnection(preservingFailure: Bool = false) async {
        let connection = self.connection
        self.connection = nil
        isReady = false
        if !preservingFailure {
            startupFailure = nil
        }

        connection?.process.terminationHandler = nil
        connection?.errorPipe.fileHandleForReading.readabilityHandler = nil
        if let process = connection?.process, process.isRunning {
            process.terminate()
        }
        try? connection?.inputPipe.fileHandleForWriting.close()
        await connection?.client.disconnect()
        try? connection?.outputPipe.fileHandleForReading.close()
        try? connection?.errorPipe.fileHandleForReading.close()
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
