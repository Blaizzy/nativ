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
        case .goose:
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return root["name"] as? String == Self.providerID
        case .crush:
            guard
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let providers = root["providers"] as? [String: Any]
            else { return false }
            return providers[Self.providerID] != nil
        case .openClaw:
            guard
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let modelsRoot = root["models"] as? [String: Any],
                let providers = modelsRoot["providers"] as? [String: Any]
            else { return false }
            return providers[Self.providerID] != nil
        case .zed:
            guard
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let languageModels = root["language_models"] as? [String: Any],
                let openAICompatible = languageModels["openai_compatible"] as? [String: Any]
            else { return false }
            return openAICompatible[Self.providerID] != nil
        case .codex, .hermes, .aider, .qwenCode, .continueDev:
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains(Self.providerID) && text.contains(openAIBaseURL)
        case .vscode, .jetbrains:
            return false
        case .cline:
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
        case .aider:
            try configureAider()
        case .goose:
            try configureGoose(models: models)
        case .crush:
            try configureCrush(selectedModelID: selectedModelID, models: models, maxOutputTokens: maxOutputTokens)
        case .qwenCode:
            try configureQwenCode(selectedModelID: selectedModelID)
        case .openClaw:
            try configureOpenClaw(models: models)
        case .zed:
            try configureZed(models: models)
        case .continueDev:
            try configureContinue(selectedModelID: selectedModelID, models: models)
        case .vscode, .jetbrains:
            break
        case .cline:
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
        case .aider:
            return integrationsSupportURL.appendingPathComponent("aider.env")
        case .goose:
            return home.appendingPathComponent(".config/goose/custom_providers/nativ.json")
        case .crush:
            return integrationsSupportURL.appendingPathComponent("crush.json")
        case .qwenCode:
            return integrationsSupportURL.appendingPathComponent("qwen.env")
        case .openClaw:
            return home.appendingPathComponent(".openclaw/openclaw.json")
        case .zed:
            return home.appendingPathComponent(".config/zed/settings.json")
        case .continueDev:
            return integrationsSupportURL.appendingPathComponent("continue-config.yaml")
        case .vscode:
            return integrationsSupportURL.appendingPathComponent("vscode-guided.json")
        case .cline:
            return integrationsSupportURL.appendingPathComponent("cline-guided.json")
        case .jetbrains:
            return integrationsSupportURL.appendingPathComponent("jetbrains-guided.json")
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

    private func configureAider() throws {
        let contents = "OPENAI_API_BASE=\(openAIBaseURL)\nOPENAI_API_KEY=nativ\n"
        try writeText(contents, to: configurationURL(for: .aider))
    }

    private func configureGoose(models: [IntegrationModelDescriptor]) throws {
        let modelEntries = models.map { model -> [String: Any] in
            ["name": model.id, "context_limit": model.contextWindow ?? 131_072]
        }
        let provider: [String: Any] = [
            "name": Self.providerID,
            "engine": "openai",
            "display_name": "Nativ",
            "description": "Local models from Nativ",
            "api_key_env": "NATIV_API_KEY",
            "base_url": openAIBaseURL + "/chat/completions",
            "models": modelEntries,
            "supports_streaming": true,
            "requires_auth": true
        ]
        try writeJSON(provider, to: configurationURL(for: .goose))
    }

    private func configureCrush(
        selectedModelID: String,
        models: [IntegrationModelDescriptor],
        maxOutputTokens: Int
    ) throws {
        let providerModels = models.map { model -> [String: Any] in
            var entry: [String: Any] = ["id": model.id, "name": model.displayName]
            if let contextWindow = model.contextWindow {
                entry["context_window"] = contextWindow
            }
            return entry
        }
        let large: [String: Any] = [
            "model": selectedModelID,
            "provider": Self.providerID,
            "max_tokens": maxOutputTokens
        ]
        let small: [String: Any] = ["model": selectedModelID, "provider": Self.providerID]
        let configuration: [String: Any] = [
            "$schema": "https://charm.land/crush.json",
            "models": ["large": large, "small": small],
            "providers": [
                Self.providerID: [
                    "type": "openai-compat",
                    "base_url": openAIBaseURL,
                    "api_key": "nativ",
                    "models": providerModels
                ]
            ]
        ]
        try writeJSON(configuration, to: configurationURL(for: .crush))
    }

    private func configureQwenCode(selectedModelID: String) throws {
        let contents = "OPENAI_API_KEY=nativ\nOPENAI_BASE_URL=\(openAIBaseURL)\nOPENAI_MODEL=\(selectedModelID)\n"
        try writeText(contents, to: configurationURL(for: .qwenCode))
    }

    private func configureOpenClaw(models: [IntegrationModelDescriptor]) throws {
        let url = configurationURL(for: .openClaw)
        var root: [String: Any] = [:]
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw IntegrationServiceError.invalidConfiguration(url)
            }
            root = existing
        }
        var modelsRoot = root["models"] as? [String: Any] ?? [:]
        var providers = modelsRoot["providers"] as? [String: Any] ?? [:]
        providers[Self.providerID] = [
            "baseUrl": openAIBaseURL,
            "apiKey": "nativ",
            "api": "openai-completions",
            "models": models.map(openClawModel)
        ]
        modelsRoot["providers"] = providers
        root["models"] = modelsRoot
        try writeJSON(root, to: url)
    }

    private func openClawModel(_ model: IntegrationModelDescriptor) -> [String: Any] {
        var value: [String: Any] = ["id": model.id, "name": model.displayName]
        if let contextWindow = model.contextWindow {
            value["contextWindow"] = contextWindow
        }
        return value
    }

    private func configureZed(models: [IntegrationModelDescriptor]) throws {
        let url = configurationURL(for: .zed)
        var root: [String: Any] = [:]
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw IntegrationServiceError.invalidConfiguration(url)
            }
            root = existing
        }
        var languageModels = root["language_models"] as? [String: Any] ?? [:]
        var openAICompatible = languageModels["openai_compatible"] as? [String: Any] ?? [:]
        openAICompatible[Self.providerID] = [
            "api_url": openAIBaseURL,
            "available_models": models.map(zedModel)
        ]
        languageModels["openai_compatible"] = openAICompatible
        root["language_models"] = languageModels
        try writeJSON(root, to: url)
    }

    private func zedModel(_ model: IntegrationModelDescriptor) -> [String: Any] {
        [
            "name": model.id,
            "display_name": model.displayName,
            "max_tokens": model.contextWindow ?? 131_072
        ]
    }

    private func configureContinue(selectedModelID: String, models: [IntegrationModelDescriptor]) throws {
        let ordered = models.filter { $0.id == selectedModelID } + models.filter { $0.id != selectedModelID }
        var lines = ["name: nativ", "version: 0.0.1", "models:"]
        for model in ordered {
            lines.append("  - name: \(yamlString(model.displayName))")
            lines.append("    provider: openai")
            lines.append("    apiBase: \(yamlString(openAIBaseURL))")
            lines.append("    model: \(yamlString(model.id))")
            lines.append("    apiKey: nativ")
            lines.append("    roles:")
            lines.append("      - chat")
            lines.append("      - edit")
            lines.append("      - apply")
        }
        try writeText(lines.joined(separator: "\n") + "\n", to: configurationURL(for: .continueDev))
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
        case .aider:
            return (
                ["--env-file", configurationURL(for: tool).path, "--model", "openai/\(selectedModelID)"],
                [:]
            )
        case .goose:
            return (
                ["session", "start", "--provider", Self.providerID],
                ["NATIV_API_KEY": "nativ", "GOOSE_MODEL": selectedModelID]
            )
        case .crush:
            return ([], ["CRUSH_GLOBAL_CONFIG": configurationURL(for: tool).path])
        case .qwenCode:
            return (
                [],
                [
                    "OPENAI_API_KEY": "nativ",
                    "OPENAI_BASE_URL": openAIBaseURL,
                    "OPENAI_MODEL": selectedModelID
                ]
            )
        case .openClaw:
            return (["agent", "--model", "\(Self.providerID)/\(selectedModelID)"], [:])
        case .zed:
            return (["."], ["NATIV_API_KEY": "nativ"])
        case .continueDev:
            return (["--config", configurationURL(for: tool).path], [:])
        case .vscode, .jetbrains:
            return ([], [:])
        case .cline:
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
