import AppKit
import Foundation

struct IntegrationProfileManager {
    static let providerID = CodexCLIProfile.providerID

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let applicationSupportDirectory: URL
    let serverBaseURL: URL

    var openAIBaseURL: String {
        serverBaseURL.appendingPathComponent("v1").absoluteString
    }

    var anthropicBaseURL: String {
        serverBaseURL.absoluteString
    }

    init(
        serverBaseURL: URL,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        applicationSupportDirectory: URL? = nil
    ) {
        let resolvedHomeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        self.fileManager = fileManager
        self.homeDirectory = resolvedHomeDirectory
        self.serverBaseURL = serverBaseURL
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? resolvedHomeDirectory
    }

    func status(for tool: IntegrationTool) async -> IntegrationToolStatus {
        if tool.isGuidedSetup {
            return IntegrationToolStatus(executableURL: nil, version: nil, isConfigured: false)
        }
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
            return environment["ANTHROPIC_BASE_URL"] as? String == anthropicBaseURL
        case .openCode:
            guard
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let providers = root["provider"] as? [String: Any]
            else { return false }
            return providers[Self.providerID] != nil
        case .codex, .hermes:
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains(Self.providerID) && text.contains(openAIBaseURL)
        case .vscode:
            return false
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
            try CodexCLIProfile.write(
                selectedModelID: selectedModelID,
                baseURL: openAIBaseURL,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
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
        case .vscode:
            break
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

    func configurationURL(for tool: IntegrationTool) -> URL {
        let home = homeDirectory
        switch tool {
        case .pi:
            return home.appendingPathComponent(".pi/agent/models.json")
        case .codex:
            return CodexCLIProfile.configurationURL(in: home)
        case .claudeCode:
            return integrationsSupportURL.appendingPathComponent("claude-settings.json")
        case .hermes:
            return home.appendingPathComponent(".hermes/profiles/nativ/config.yaml")
        case .openCode:
            return integrationsSupportURL.appendingPathComponent("opencode.json")
        case .vscode:
            return integrationsSupportURL.appendingPathComponent("vscode-guided.json")
        }
    }

    private var integrationsSupportURL: URL {
        applicationSupportDirectory
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Integrations", isDirectory: true)
    }

    private func bundledExecutableURL(for tool: IntegrationTool) -> URL? {
        guard tool == .codex else { return nil }
        let home = homeDirectory
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
            "baseUrl": openAIBaseURL,
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

    private func claudeSettings(selectedModelID: String) -> [String: Any] {
        [
            "env": [
                "ANTHROPIC_AUTH_TOKEN": "nativ",
                "ANTHROPIC_API_KEY": "",
                "ANTHROPIC_BASE_URL": anthropicBaseURL,
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
          base_url: \(yamlString(openAIBaseURL))
          api_key: nativ
        display:
          streaming: true
        custom_providers:
          - name: nativ
            base_url: \(yamlString(openAIBaseURL))
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
                        "baseURL": openAIBaseURL,
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
                    "ANTHROPIC_BASE_URL": anthropicBaseURL
                ]
            )
        case .hermes:
            return (["-p", Self.providerID, "chat", "--provider", "custom", "--model", selectedModelID], [:])
        case .openCode:
            return (
                ["--model", "\(Self.providerID)/\(selectedModelID)"],
                ["OPENCODE_CONFIG": configurationURL(for: tool).path]
            )
        case .vscode:
            return ([], [:])
        }
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
