import Darwin
import Foundation
import NativServerKit
import Security

enum CustomToolKind: String, Codable, CaseIterable, Identifiable {
    case endpoint
    case script

    var id: Self { self }

    var title: String {
        switch self {
        case .endpoint: "Endpoint"
        case .script: "Script"
        }
    }
}

enum CustomToolScriptLanguage: String, Codable, CaseIterable, Identifiable {
    case python
    case javaScript
    case shell

    var id: Self { self }

    var title: String {
        switch self {
        case .python: "Python"
        case .javaScript: "JavaScript"
        case .shell: "Shell"
        }
    }

    var availabilityNote: String {
        switch self {
        case .python: "Uses Nativ’s bundled Python."
        case .javaScript: "Requires Node.js."
        case .shell: "Runs with macOS zsh."
        }
    }

    var template: String {
        switch self {
        case .python:
            #"""
            import json
            import sys

            arguments = json.load(sys.stdin)
            print(json.dumps({"result": arguments.get("query", "")}))
            """#
        case .javaScript:
            #"""
            const fs = require("fs");

            const arguments = JSON.parse(fs.readFileSync(0, "utf8"));
            console.log(JSON.stringify({ result: arguments.query ?? "" }));
            """#
        case .shell:
            #"""
            input=$(cat)
            printf '%s\n' "$input"
            """#
        }
    }
}

struct CustomTool: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var slug: String
    var summary: String
    var kind: CustomToolKind
    var endpoint: String
    var script: String
    var scriptLanguage: CustomToolScriptLanguage
    var parametersJSON: String
    var headerName: String?

    static let defaultParametersJSON = #"""
    {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "query": {
          "type": "string",
          "description": "The value to pass to the tool."
        }
      },
      "required": ["query"]
    }
    """#

    var toolName: String {
        "custom__\(slug)"
    }

    var displaySummary: String {
        if !summary.isEmpty { return summary }
        switch kind {
        case .endpoint:
            return "Sends model-provided JSON to \(endpoint)"
        case .script:
            return "Runs a local \(scriptLanguage.title) script"
        }
    }

    var executionHint: String {
        switch kind {
        case .endpoint:
            return "This custom tool sends model-provided JSON to \(endpoint) when it is called in chat."
        case .script:
            return "This custom tool runs a local \(scriptLanguage.title) script after you approve it in chat."
        }
    }

    func definition() throws -> MLXChatToolDefinition {
        let parameters = try MLXJSONValue(jsonData: Data(parametersJSON.utf8))
        guard case .object = parameters else {
            throw CustomToolError.invalidParameters
        }
        return MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName,
            description: displaySummary,
            parameters: parameters
        ))
    }

    static func make(
        name: String,
        summary: String,
        kind: CustomToolKind = .endpoint,
        endpoint: String = "",
        script: String = "",
        scriptLanguage: CustomToolScriptLanguage = .python,
        parametersJSON: String,
        headerName: String = "",
        id: UUID = UUID()
    ) throws -> Self {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slug = normalizedSlug(trimmedName) else {
            throw CustomToolError.invalidName
        }

        let trimmedParameters = parametersJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedScript = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHeaderName = headerName.trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedEndpoint: String
        let normalizedHeaderName: String?
        switch kind {
        case .endpoint:
            guard let url = URL(string: trimmedEndpoint),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host != nil else {
                throw CustomToolError.invalidEndpoint
            }
            guard trimmedHeaderName.isEmpty || isValidHeaderName(trimmedHeaderName) else {
                throw CustomToolError.invalidHeaderName
            }
            normalizedEndpoint = url.absoluteString
            normalizedHeaderName = trimmedHeaderName.isEmpty ? nil : trimmedHeaderName
        case .script:
            guard !trimmedScript.isEmpty else {
                throw CustomToolError.emptyScript
            }
            normalizedEndpoint = ""
            normalizedHeaderName = nil
        }

        let tool = Self(
            id: id,
            name: trimmedName,
            slug: slug,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            endpoint: normalizedEndpoint,
            script: kind == .script ? script : "",
            scriptLanguage: scriptLanguage,
            parametersJSON: trimmedParameters,
            headerName: normalizedHeaderName
        )
        _ = try tool.definition()
        return tool
    }

    private static func isValidHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }
    }

    private static func normalizedSlug(_ name: String) -> String? {
        let lowered = name.lowercased()
        let characters = lowered.unicodeScalars.map { character -> Character in
            CharacterSet.alphanumerics.contains(character) ? Character(String(character)) : "_"
        }
        let slug = String(characters).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !slug.isEmpty,
              slug.count <= 48,
              slug.unicodeScalars.first.map(CharacterSet.letters.contains) == true else {
            return nil
        }
        return slug
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, slug, summary, kind, endpoint, script, scriptLanguage, parametersJSON, headerName
    }

    init(
        id: UUID,
        name: String,
        slug: String,
        summary: String,
        kind: CustomToolKind,
        endpoint: String,
        script: String,
        scriptLanguage: CustomToolScriptLanguage,
        parametersJSON: String,
        headerName: String?
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.summary = summary
        self.kind = kind
        self.endpoint = endpoint
        self.script = script
        self.scriptLanguage = scriptLanguage
        self.parametersJSON = parametersJSON
        self.headerName = headerName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decode(String.self, forKey: .slug)
        summary = try container.decode(String.self, forKey: .summary)
        kind = try container.decodeIfPresent(CustomToolKind.self, forKey: .kind) ?? .endpoint
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        script = try container.decodeIfPresent(String.self, forKey: .script) ?? ""
        scriptLanguage = try container.decodeIfPresent(CustomToolScriptLanguage.self, forKey: .scriptLanguage) ?? .python
        parametersJSON = try container.decode(String.self, forKey: .parametersJSON)
        headerName = try container.decodeIfPresent(String.self, forKey: .headerName)
    }
}

enum CustomToolError: LocalizedError {
    case invalidName
    case invalidEndpoint
    case emptyScript
    case invalidParameters
    case invalidArguments
    case invalidHeaderName
    case missingCredential
    case missingRuntime(String)
    case scriptTimedOut
    case scriptFailed(String)
    case invalidResponse
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Use a short tool name that starts with a letter."
        case .invalidEndpoint:
            return "Enter a complete http or https URL."
        case .emptyScript:
            return "Enter a script to run."
        case .invalidParameters:
            return "Parameters must be a JSON object schema."
        case .invalidArguments:
            return "Test arguments must be valid JSON."
        case .invalidHeaderName:
            return "Header names can contain only letters, numbers, and hyphens."
        case .missingCredential:
            return "Enter a value for the configured request header."
        case let .missingRuntime(runtime):
            return "\(runtime) is not available on this Mac."
        case .scriptTimedOut:
            return "The script exceeded the 30-second time limit."
        case let .scriptFailed(output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "The script exited with an error." : detail
        case .invalidResponse:
            return "The service returned an unreadable response."
        case let .httpStatus(status, body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "The service returned HTTP \(status)." : "The service returned HTTP \(status): \(detail)"
        }
    }
}

enum CustomToolCredentialPersistenceError: Error {
    case keychain(OSStatus)
    case invalidKeychainData
}

protocol CustomToolCredentialStoring {
    func load(for toolID: UUID) throws -> String?
    func save(_ value: String?, for toolID: UUID) throws
}

struct CustomToolKeychain: CustomToolCredentialStoring {
    let service: String

    init(service: String = "dev.local.Nativ.custom-http-tool") {
        self.service = service
    }

    func load(for toolID: UUID) throws -> String? {
        var query = baseQuery(for: toolID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CustomToolCredentialPersistenceError.keychain(status)
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CustomToolCredentialPersistenceError.invalidKeychainData
        }
        return normalized(value)
    }

    func save(_ value: String?, for toolID: UUID) throws {
        guard let value = normalized(value) else {
            let status = SecItemDelete(baseQuery(for: toolID) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CustomToolCredentialPersistenceError.keychain(status)
            }
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let query = baseQuery(for: toolID)
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CustomToolCredentialPersistenceError.keychain(updateStatus)
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CustomToolCredentialPersistenceError.keychain(addStatus)
        }
    }

    private func baseQuery(for toolID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: toolID.uuidString,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum CustomToolExecutor {
    static func execute(
        _ tool: CustomTool,
        argumentsJSON: String?,
        headerValue: String? = nil,
        credentialStore: CustomToolCredentialStoring = CustomToolKeychain(),
        session: URLSession = .shared
    ) async throws -> String {
        switch tool.kind {
        case .endpoint:
            return try await executeEndpoint(
                tool,
                argumentsJSON: argumentsJSON,
                headerValue: headerValue,
                credentialStore: credentialStore,
                session: session
            )
        case .script:
            return try await CustomToolScriptRunner.execute(tool, argumentsJSON: argumentsJSON)
        }
    }

    private static func executeEndpoint(
        _ tool: CustomTool,
        argumentsJSON: String?,
        headerValue: String?,
        credentialStore: CustomToolCredentialStoring,
        session: URLSession
    ) async throws -> String {
        guard let endpoint = URL(string: tool.endpoint) else {
            throw CustomToolError.invalidEndpoint
        }
        let body = Data((argumentsJSON ?? "{}").utf8)
        guard (try? JSONSerialization.jsonObject(with: body)) != nil else {
            throw CustomToolError.invalidArguments
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        if let headerName = tool.headerName {
            let value: String?
            if let headerValue {
                value = headerValue
            } else {
                value = try credentialStore.load(for: tool.id)
            }
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                throw CustomToolError.missingCredential
            }
            request.setValue(value, forHTTPHeaderField: headerName)
        }

        let (data, response) = try await session.data(for: request)
        let text = String(decoding: data.prefix(128_000), as: UTF8.self)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CustomToolError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw CustomToolError.httpStatus(httpResponse.statusCode, text)
        }
        return text.isEmpty ? "{}" : text
    }
}

private enum CustomToolScriptRunner {
    private struct Command {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]
        let currentDirectoryURL: URL
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let limit: Int
        private var data = Data()
        private let lock = NSLock()

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            if data.count < limit {
                data.append(chunk.prefix(limit - data.count))
            }
            lock.unlock()
        }

        func text() -> String {
            lock.lock()
            let snapshot = data
            lock.unlock()
            return String(decoding: snapshot, as: UTF8.self)
        }
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func execute(_ tool: CustomTool, argumentsJSON: String?) async throws -> String {
        let input = Data((argumentsJSON ?? "{}").utf8)
        guard (try? JSONSerialization.jsonObject(with: input)) != nil else {
            throw CustomToolError.invalidArguments
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativTool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let (checkCommand, runCommand) = try commands(for: tool, in: directory)
        let check = try await run(checkCommand, input: Data(), timeout: 10)
        guard check.status == 0 else {
            throw CustomToolError.scriptFailed(check.stderr.isEmpty ? check.stdout : check.stderr)
        }

        let result = try await run(runCommand, input: input, timeout: 30)
        guard result.status == 0 else {
            throw CustomToolError.scriptFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result.stdout.isEmpty ? "{}" : result.stdout
    }

    private static func commands(for tool: CustomTool, in directory: URL) throws -> (Command, Command) {
        let environment = baseEnvironment()
        switch tool.scriptLanguage {
        case .python:
            let distributionURL = try Nativ.distributionURL()
            let pythonURL = distributionURL.appendingPathComponent("python/bin/python3")
            guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
                throw CustomToolError.missingRuntime("Python")
            }
            let scriptURL = directory.appendingPathComponent("tool.py")
            try tool.script.write(to: scriptURL, atomically: true, encoding: .utf8)
            var pythonEnvironment = environment
            pythonEnvironment["PYTHONHOME"] = distributionURL.appendingPathComponent("python").path
            pythonEnvironment["PYTHONNOUSERSITE"] = "1"
            pythonEnvironment["PYTHONUNBUFFERED"] = "1"
            return (
                Command(executableURL: pythonURL, arguments: ["-m", "py_compile", scriptURL.path], environment: pythonEnvironment, currentDirectoryURL: directory),
                Command(executableURL: pythonURL, arguments: [scriptURL.path], environment: pythonEnvironment, currentDirectoryURL: directory)
            )
        case .javaScript:
            let nodeURL = try executable(named: "node", displayName: "Node.js", environment: environment)
            let scriptURL = directory.appendingPathComponent("tool.js")
            try tool.script.write(to: scriptURL, atomically: true, encoding: .utf8)
            return (
                Command(executableURL: nodeURL, arguments: ["--check", scriptURL.path], environment: environment, currentDirectoryURL: directory),
                Command(executableURL: nodeURL, arguments: [scriptURL.path], environment: environment, currentDirectoryURL: directory)
            )
        case .shell:
            let zshURL = URL(fileURLWithPath: "/bin/zsh")
            let scriptURL = directory.appendingPathComponent("tool.zsh")
            try tool.script.write(to: scriptURL, atomically: true, encoding: .utf8)
            return (
                Command(executableURL: zshURL, arguments: ["-n", scriptURL.path], environment: environment, currentDirectoryURL: directory),
                Command(executableURL: zshURL, arguments: [scriptURL.path], environment: environment, currentDirectoryURL: directory)
            )
        }
    }

    private static func baseEnvironment() -> [String: String] {
        let processEnvironment = ProcessInfo.processInfo.environment
        let path = ShellEnvironment.resolveFromLoginShell(names: ["PATH"])["PATH"]
            ?? processEnvironment["PATH"]
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return [
            "PATH": path,
            "HOME": processEnvironment["HOME"] ?? NSHomeDirectory(),
            "LANG": processEnvironment["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory()
        ]
    }

    private static func executable(named name: String, displayName: String, environment: [String: String]) throws -> URL {
        for directory in environment["PATH", default: ""].split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw CustomToolError.missingRuntime(displayName)
    }

    private static func run(_ command: Command, input: Data, timeout: TimeInterval) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            try runSynchronously(command, input: input, timeout: timeout)
        }.value
    }

    private static func runSynchronously(
        _ command: Command,
        input: Data,
        timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let outputBuffer = OutputBuffer(limit: 128_000)
        let errorBuffer = OutputBuffer(limit: 32_000)

        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = command.currentDirectoryURL
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            outputBuffer.append(handle.availableData)
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            errorBuffer.append(handle.availableData)
        }

        do {
            try process.run()
            if !input.isEmpty {
                try standardInput.fileHandleForWriting.write(contentsOf: input)
            }
            try standardInput.fileHandleForWriting.close()

            let exited = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                exited.signal()
            }
            guard exited.wait(timeout: .now() + timeout) == .success else {
                process.terminate()
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
                throw CustomToolError.scriptTimedOut
            }

            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            outputBuffer.append(standardOutput.fileHandleForReading.readDataToEndOfFile())
            errorBuffer.append(standardError.fileHandleForReading.readDataToEndOfFile())
            return ProcessResult(
                status: process.terminationStatus,
                stdout: outputBuffer.text(),
                stderr: errorBuffer.text()
            )
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            throw error
        }
    }
}
