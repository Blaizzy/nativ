import AppKit
import Foundation

enum IntegrationTool: String, CaseIterable, Hashable, Identifiable, Sendable {
    case pi
    case codex
    case claudeCode
    case hermes
    case openCode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pi: "Pi"
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .hermes: "Hermes"
        case .openCode: "OpenCode"
        }
    }

    var commandName: String {
        switch self {
        case .pi: "pi"
        case .codex: "codex"
        case .claudeCode: "claude"
        case .hermes: "hermes"
        case .openCode: "opencode"
        }
    }

    var logoAssetName: String { "IntegrationLogo-\(rawValue)" }

    var summary: String {
        switch self {
        case .pi: "Minimal, extensible coding agent"
        case .codex: "OpenAI coding agent for terminal and desktop"
        case .claudeCode: "Anthropic's agentic coding tool"
        case .hermes: "Open agent with tools, skills, and memory"
        case .openCode: "Open-source coding agent"
        }
    }

    var installURL: URL {
        switch self {
        case .pi: URL(string: "https://pi.dev/docs/latest")!
        case .codex: URL(string: "https://developers.openai.com/codex/cli")!
        case .claudeCode: URL(string: "https://code.claude.com/docs/en/setup")!
        case .hermes: URL(string: "https://github.com/NousResearch/hermes-agent")!
        case .openCode: URL(string: "https://opencode.ai/docs")!
        }
    }
}

struct IntegrationModelDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let contextWindow: Int?
    let supportsVision: Bool
    let supportsReasoning: Bool
    let supportsTools: Bool

    init(localModel: LocalModel) {
        id = localModel.repoID
        displayName = localModel.repoID.split(separator: "/").last.map(String.init) ?? localModel.repoID
        contextWindow = localModel.contextSize
        supportsVision = localModel.capabilities.contains(.vision)
        supportsReasoning = localModel.capabilities.contains(.reasoning)
        supportsTools = localModel.capabilities.contains(.tools)
    }
}

struct IntegrationToolStatus: Equatable, Sendable {
    var executableURL: URL?
    var version: String?
    var isConfigured: Bool

    static let unavailable = IntegrationToolStatus(executableURL: nil, version: nil, isConfigured: false)
}

enum IntegrationServiceError: LocalizedError {
    case missingExecutable(IntegrationTool)
    case invalidConfiguration(URL)
    case noModel
    case serverUnavailable
    case modelLoadFailed(String, String)
    case modelLoadTimedOut(String)
    case terminalLaunchFailed(String)
    case desktopLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let tool):
            return "\(tool.displayName) is not installed or could not be found in the application bundle or shell PATH."
        case .invalidConfiguration(let url):
            return "The existing configuration at \(url.path) is not valid JSON. It was left unchanged."
        case .noModel:
            return "Choose an installed chat model first."
        case .serverUnavailable:
            return "The local model server did not become ready in time."
        case .modelLoadFailed(let model, let message):
            return "Couldn’t load \(model): \(message)"
        case .modelLoadTimedOut(let model):
            return "Loading \(model) took longer than five minutes. The coding tool was not opened."
        case .terminalLaunchFailed(let message):
            return "Couldn’t open Terminal: \(message)"
        case .desktopLaunchFailed(let message):
            return "Couldn’t open Codex Desktop: \(message)"
        }
    }
}

struct IntegrationProfileManager {
    static let providerID = "nativ"

    static var openAIBaseURL: String {
        NativSettings.load().serverBaseURL.absoluteString + "/v1"
    }

    static var anthropicBaseURL: String {
        NativSettings.load().serverBaseURL.absoluteString
    }

    private let fileManager = FileManager.default

    func status(for tool: IntegrationTool) async -> IntegrationToolStatus {
        let resolvedExecutableURL: URL?
        if let bundledURL = bundledExecutableURL(for: tool) {
            resolvedExecutableURL = bundledURL
        } else {
            resolvedExecutableURL = await executableURL(named: tool.commandName)
        }
        let version = resolvedExecutableURL.flatMap { readVersion(executableURL: $0) }
        return IntegrationToolStatus(
            executableURL: resolvedExecutableURL,
            version: version,
            isConfigured: hasManagedConfiguration(for: tool)
        )
    }

    private func hasManagedConfiguration(for tool: IntegrationTool) -> Bool {
        let url = configurationURL(for: tool)
        guard let data = try? Data(contentsOf: url) else { return false }

        switch tool {
        case .pi:
            guard
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let providers = root["providers"] as? [String: Any]
            else { return false }
            return providers[Self.providerID] != nil
        case .claudeCode:
            guard
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let environment = root["env"] as? [String: Any]
            else { return false }
            return environment["ANTHROPIC_BASE_URL"] as? String == Self.anthropicBaseURL
        case .openCode:
            guard
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let providers = root["provider"] as? [String: Any]
            else { return false }
            return providers[Self.providerID] != nil
        case .codex, .hermes:
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains(Self.providerID) && text.contains(Self.openAIBaseURL)
        }
    }

    func configure(
        tool: IntegrationTool,
        selectedModelID: String,
        models: [IntegrationModelDescriptor],
        maxOutputTokens: Int
    ) throws {
        switch tool {
        case .pi:
            try configurePi(selectedModelID: selectedModelID, models: models)
        case .codex:
            try writeText(codexProfile(selectedModelID: selectedModelID), to: configurationURL(for: tool))
        case .claudeCode:
            try writeJSON(claudeSettings(selectedModelID: selectedModelID), to: configurationURL(for: tool))
        case .hermes:
            try configureHermes(selectedModelID: selectedModelID, models: models)
        case .openCode:
            try writeJSON(
                openCodeConfiguration(
                    selectedModelID: selectedModelID,
                    models: models,
                    maxOutputTokens: maxOutputTokens
                ),
                to: configurationURL(for: tool)
            )
        }
    }

    func launch(
        tool: IntegrationTool,
        executableURL: URL,
        selectedModelID: String,
        workingDirectory: URL
    ) throws {
        let scriptURL = try terminalScriptURL(for: tool)
        let script = "#!/bin/zsh\n" + launchCommand(
            tool: tool,
            executableURL: executableURL,
            selectedModelID: selectedModelID,
            workingDirectory: workingDirectory,
            usesExec: true
        )
        try writeText(script, to: scriptURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", scriptURL.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw IntegrationServiceError.terminalLaunchFailed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            throw IntegrationServiceError.terminalLaunchFailed("open exited with status \(process.terminationStatus)")
        }
    }

    func launchCommand(
        tool: IntegrationTool,
        executableURL: URL,
        selectedModelID: String,
        workingDirectory: URL,
        usesExec: Bool = false
    ) -> String {
        let launch = launchConfiguration(tool: tool, selectedModelID: selectedModelID)
        let exports = launch.environment
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(shellQuote($0.value))" }
        let arguments = launch.arguments.map(shellQuote).joined(separator: " ")
        let executable = shellQuote(executableURL.path)
        let invocation = "\(usesExec ? "exec " : "")\(executable)\(arguments.isEmpty ? "" : " \(arguments)")"
        return (["cd \(shellQuote(workingDirectory.path))"] + exports + [invocation])
            .joined(separator: "\n")
    }

    func codexDesktopLaunchCommand(
        executableURL: URL,
        selectedModelID _: String,
        workingDirectory: URL
    ) -> String {
        ([shellQuote(executableURL.path)] + codexDesktopArguments(
            workingDirectory: workingDirectory
        ).map(shellQuote))
        .joined(separator: " ")
    }

    func configureCodexDesktop(selectedModelID: String) throws {
        let url = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = updatingCodexUserConfiguration(existing, selectedModelID: selectedModelID)
        try writeText(updated, to: url)
    }

    func launchCodexDesktop(
        executableURL: URL,
        selectedModelID _: String,
        workingDirectory: URL
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = codexDesktopArguments(workingDirectory: workingDirectory)
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw IntegrationServiceError.desktopLaunchFailed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            throw IntegrationServiceError.desktopLaunchFailed(
                "codex app exited with status \(process.terminationStatus)"
            )
        }
    }

    func configurationURL(for tool: IntegrationTool) -> URL {
        let home = fileManager.homeDirectoryForCurrentUser
        switch tool {
        case .pi:
            return home.appendingPathComponent(".pi/agent/models.json")
        case .codex:
            return home.appendingPathComponent(".codex/nativ.config.toml")
        case .claudeCode:
            return integrationsSupportURL.appendingPathComponent("claude-settings.json")
        case .hermes:
            return home.appendingPathComponent(".hermes/profiles/nativ/config.yaml")
        case .openCode:
            return integrationsSupportURL.appendingPathComponent("opencode.json")
        }
    }

    private var integrationsSupportURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Integrations", isDirectory: true)
    }

    private func bundledExecutableURL(for tool: IntegrationTool) -> URL? {
        guard tool == .codex else { return nil }
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex")
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func executableURL(named command: String) async -> URL? {
        await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // Finder-launched apps do not inherit PATH entries configured in
            // .zshrc. Use an interactive login shell so tool managers and
            // user-installed Node bins are available, then resolve only an
            // external executable rather than an alias or shell function.
            process.arguments = [
                "-lic",
                "whence -p -- \"$1\"",
                "nativ-integration-detection",
                command
            ]
            process.standardOutput = output
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let paths = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let path = paths.last(where: {
                $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0)
            }) else { return nil }
            return URL(fileURLWithPath: path)
        }.value
    }

    private func readVersion(executableURL: URL) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let firstLine = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return firstLine?.isEmpty == false ? firstLine : nil
    }

    private func configurePi(selectedModelID: String, models: [IntegrationModelDescriptor]) throws {
        let url = configurationURL(for: .pi)
        var root: [String: Any] = [:]
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw IntegrationServiceError.invalidConfiguration(url)
            }
            root = existing
        }
        var providers = root["providers"] as? [String: Any] ?? [:]
        providers[Self.providerID] = [
            "baseUrl": Self.openAIBaseURL,
            "api": "openai-completions",
            "apiKey": "nativ",
            "compat": [
                "supportsDeveloperRole": false,
                "supportsReasoningEffort": false,
                "supportsUsageInStreaming": true
            ],
            "models": models.map(piModel)
        ]
        root["providers"] = providers
        try writeJSON(root, to: url)
    }

    private func piModel(_ model: IntegrationModelDescriptor) -> [String: Any] {
        var value: [String: Any] = [
            "id": model.id,
            "name": model.displayName,
            "reasoning": model.supportsReasoning,
            "input": model.supportsVision ? ["text", "image"] : ["text"],
            "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0]
        ]
        if let contextWindow = model.contextWindow {
            value["contextWindow"] = contextWindow
        }
        return value
    }

    private func codexProfile(selectedModelID: String) -> String {
        """
        # Managed by Nativ. Other Codex profiles are not modified.
        model = \(tomlString(selectedModelID))
        model_provider = \(tomlString(Self.providerID))

        [model_providers.\(tomlString(Self.providerID))]
        name = "Nativ"
        base_url = \(tomlString(Self.openAIBaseURL))
        wire_api = "responses"
        """
    }

    private func claudeSettings(selectedModelID: String) -> [String: Any] {
        [
            "env": [
                "ANTHROPIC_AUTH_TOKEN": "nativ",
                "ANTHROPIC_API_KEY": "",
                "ANTHROPIC_BASE_URL": Self.anthropicBaseURL,
                "ANTHROPIC_MODEL": selectedModelID,
                "ANTHROPIC_SMALL_FAST_MODEL": selectedModelID
            ]
        ]
    }

    private func configureHermes(selectedModelID: String, models: [IntegrationModelDescriptor]) throws {
        let url = configurationURL(for: .hermes)
        let modelLines = models.map { model in
            var lines = ["      \(yamlString(model.id)):"]
            if let contextWindow = model.contextWindow {
                lines.append("        context_length: \(contextWindow)")
            }
            if model.supportsVision {
                lines.append("        supports_vision: true")
            }
            if lines.count == 1 {
                lines.append("        context_length: 131072")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
        let yaml = """
        # Managed by Nativ in an isolated Hermes profile.
        model:
          default: \(yamlString(selectedModelID))
          provider: custom
          base_url: \(yamlString(Self.openAIBaseURL))
          api_key: nativ
        display:
          streaming: true
        custom_providers:
          - name: nativ
            base_url: \(yamlString(Self.openAIBaseURL))
            api_key: nativ
            api_mode: chat_completions
            models:
        \(modelLines)
        """
        try writeText(yaml, to: url)
        let profileURL = url.deletingLastPathComponent().appendingPathComponent("profile.yaml")
        if !fileManager.fileExists(atPath: profileURL.path) {
            try writeText("name: nativ\ndescription: Local models from Nativ\n", to: profileURL)
        }
    }

    private func openCodeConfiguration(
        selectedModelID: String,
        models: [IntegrationModelDescriptor],
        maxOutputTokens: Int
    ) -> [String: Any] {
        var modelCatalog: [String: Any] = [:]
        for model in models {
            var entry: [String: Any] = [
                "name": model.displayName,
                "attachment": model.supportsVision,
                "reasoning": model.supportsReasoning,
                "temperature": true,
                "tool_call": model.supportsTools,
                "modalities": [
                    "input": model.supportsVision ? ["text", "image"] : ["text"],
                    "output": ["text"]
                ]
            ]
            let contextWindow = model.contextWindow ?? 131_072
            entry["limit"] = [
                "context": contextWindow,
                "output": min(max(maxOutputTokens, 1), contextWindow)
            ]
            if model.supportsReasoning {
                entry["interleaved"] = ["field": "reasoning_content"]
                entry["options"] = ["enable_thinking": true]
            }
            modelCatalog[model.id] = entry
        }
        return [
            "$schema": "https://opencode.ai/config.json",
            "model": "\(Self.providerID)/\(selectedModelID)",
            "provider": [
                Self.providerID: [
                    "npm": "@ai-sdk/openai-compatible",
                    "name": "Nativ",
                    "options": [
                        "baseURL": Self.openAIBaseURL,
                        "apiKey": "nativ"
                    ],
                    "models": modelCatalog
                ]
            ]
        ]
    }

    private func launchConfiguration(
        tool: IntegrationTool,
        selectedModelID: String
    ) -> (arguments: [String], environment: [String: String]) {
        switch tool {
        case .pi:
            return (["--provider", Self.providerID, "--model", selectedModelID], [:])
        case .codex:
            return (["--profile", Self.providerID, "--model", selectedModelID], [:])
        case .claudeCode:
            return (
                ["--settings", configurationURL(for: tool).path, "--model", selectedModelID],
                [
                    "ANTHROPIC_AUTH_TOKEN": "nativ",
                    "ANTHROPIC_API_KEY": "",
                    "ANTHROPIC_BASE_URL": Self.anthropicBaseURL
                ]
            )
        case .hermes:
            return (["-p", Self.providerID, "chat", "--provider", "custom", "--model", selectedModelID], [:])
        case .openCode:
            return (
                ["--model", "\(Self.providerID)/\(selectedModelID)"],
                ["OPENCODE_CONFIG": configurationURL(for: tool).path]
            )
        }
    }

    private func codexDesktopArguments(workingDirectory: URL) -> [String] {
        ["app", workingDirectory.path]
    }

    private func updatingCodexUserConfiguration(
        _ configuration: String,
        selectedModelID: String
    ) -> String {
        let lines = configuration.components(separatedBy: .newlines)
        var output: [String] = []
        var reachedTable = false
        var skippingManagedProvider = false
        var wroteModel = false
        var wroteProvider = false

        func appendMissingRootValues() {
            guard !wroteModel || !wroteProvider else { return }
            output.append("# Model selection managed by Nativ.")
            if !wroteModel {
                output.append("model = \(tomlString(selectedModelID))")
                wroteModel = true
            }
            if !wroteProvider {
                output.append("model_provider = \(tomlString(Self.providerID))")
                wroteProvider = true
            }
            output.append("")
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isTable = trimmed.hasPrefix("[") && trimmed.hasSuffix("]")

            if isTable {
                if !reachedTable {
                    appendMissingRootValues()
                    reachedTable = true
                }
                if isCodexManagedProviderTable(trimmed) {
                    skippingManagedProvider = true
                    continue
                }
                skippingManagedProvider = false
            }

            if skippingManagedProvider { continue }

            if !reachedTable, let key = tomlAssignmentKey(line) {
                if key == "model" {
                    output.append("model = \(tomlString(selectedModelID)) # Managed by Nativ")
                    wroteModel = true
                    continue
                }
                if key == "model_provider" {
                    output.append("model_provider = \(tomlString(Self.providerID)) # Managed by Nativ")
                    wroteProvider = true
                    continue
                }
            }
            output.append(line)
        }

        if !reachedTable {
            appendMissingRootValues()
        }
        while output.last?.isEmpty == true { output.removeLast() }
        output.append("")
        output.append("# Provider managed by Nativ.")
        output.append("[model_providers.\(tomlString(Self.providerID))]")
        output.append("name = \(tomlString("Nativ"))")
        output.append("base_url = \(tomlString(Self.openAIBaseURL))")
        output.append("wire_api = \(tomlString("responses"))")
        output.append("")
        return output.joined(separator: "\n")
    }

    private func tomlAssignmentKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
            return nil
        }
        return String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
    }

    private func isCodexManagedProviderTable(_ line: String) -> Bool {
        line == "[model_providers.\(Self.providerID)]"
            || line == "[model_providers.\(tomlString(Self.providerID))]"
            || line == "[model_providers.'\(Self.providerID)']"
    }

    private func terminalScriptURL(for tool: IntegrationTool) throws -> URL {
        let url = integrationsSupportURL.appendingPathComponent("open-\(tool.rawValue).command")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try writeData(data + Data("\n".utf8), to: url)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try writeData(Data(text.utf8), to: url)
    }

    private func writeData(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func yamlString(_ value: String) -> String {
        tomlString(value)
    }
}
