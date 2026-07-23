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
        let resolvedExecutableURL: URL?
        if let bundledURL = bundledExecutableURL(for: tool) {
            resolvedExecutableURL = bundledURL
        } else if tool == .conductor {
            resolvedExecutableURL = nil
        } else {
            resolvedExecutableURL = await executableURL(named: tool.commandName)
        }
        let version = resolvedExecutableURL.flatMap {
            tool == .conductor ? readApplicationVersion(applicationURL: $0) : readVersion(executableURL: $0)
        }
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
        case .conductor:
            guard let text = String(data: data, encoding: .utf8) else { return false }
            let environmentURL = conductorEnvironmentURL
            guard text.contains(tomlString(environmentURL.path)),
                  let environment = try? String(contentsOf: environmentURL, encoding: .utf8)
            else { return false }
            return environment.contains("OPENAI_BASE_URL=\(openAIBaseURL)")
                && environment.contains("ANTHROPIC_BASE_URL=\(anthropicBaseURL)")
                && environment.contains(
                    "OPENCODE_CONFIG=\(dotenvString(configurationURL(for: .openCode).path))"
                )
        case .openCode:
            guard
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let providers = root["provider"] as? [String: Any]
            else { return false }
            return providers[Self.providerID] != nil
        case .codex, .hermes:
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains(Self.providerID) && text.contains(openAIBaseURL)
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
        case .conductor:
            try configureConductor(
                selectedModelID: selectedModelID,
                models: models,
                maxOutputTokens: maxOutputTokens
            )
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
        if tool == .conductor {
            try launchConductor(applicationURL: executableURL, workingDirectory: workingDirectory)
            return
        }
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
        if tool == .conductor {
            return conductorLaunchCommand(
                applicationURL: executableURL,
                workingDirectory: workingDirectory
            )
        }
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
        case .conductor:
            return home.appendingPathComponent(".conductor/settings.toml")
        case .hermes:
            return home.appendingPathComponent(".hermes/profiles/nativ/config.yaml")
        case .openCode:
            return integrationsSupportURL.appendingPathComponent("opencode.json")
        }
    }

    private var integrationsSupportURL: URL {
        applicationSupportDirectory
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Integrations", isDirectory: true)
    }

    private func bundledExecutableURL(for tool: IntegrationTool) -> URL? {
        let home = homeDirectory
        if tool == .conductor {
            let candidates = [
                URL(fileURLWithPath: "/Applications/Conductor.app", isDirectory: true),
                home.appendingPathComponent("Applications/Conductor.app", isDirectory: true)
            ]
            return candidates.first { fileManager.fileExists(atPath: $0.path) }
        }
        guard tool == .codex else { return nil }
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

    private func readApplicationVersion(applicationURL: URL) -> String? {
        guard let bundle = Bundle(url: applicationURL) else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private func configureConductor(
        selectedModelID: String,
        models: [IntegrationModelDescriptor],
        maxOutputTokens: Int
    ) throws {
        try writeJSON(
            openCodeConfiguration(
                selectedModelID: selectedModelID,
                models: models,
                maxOutputTokens: maxOutputTokens
            ),
            to: configurationURL(for: .openCode)
        )

        let environment = """
        # Managed by Nativ. Referenced by ~/.conductor/settings.toml.
        OPENAI_BASE_URL=\(openAIBaseURL)
        OPENAI_API_KEY=nativ
        CODEX_API_KEY=nativ
        ANTHROPIC_AUTH_TOKEN=nativ
        ANTHROPIC_API_KEY=
        ANTHROPIC_BASE_URL=\(anthropicBaseURL)
        ANTHROPIC_MODEL=\(dotenvString(selectedModelID))
        ANTHROPIC_SMALL_FAST_MODEL=\(dotenvString(selectedModelID))
        OPENCODE_CONFIG=\(dotenvString(configurationURL(for: .openCode).path))
        """
        try writeText(environment + "\n", to: conductorEnvironmentURL)

        let settingsURL = configurationURL(for: .conductor)
        let existing = (try? String(contentsOf: settingsURL, encoding: .utf8)) ?? ""
        let updated = updatingConductorUserConfiguration(
            existing,
            models: models
        )
        try writeText(updated, to: settingsURL)
    }

    private var conductorEnvironmentURL: URL {
        integrationsSupportURL.appendingPathComponent("conductor.env")
    }

    private func updatingConductorUserConfiguration(
        _ configuration: String,
        models: [IntegrationModelDescriptor]
    ) -> String {
        var lines = configuration.components(separatedBy: .newlines)
        while lines.last?.isEmpty == true { lines.removeLast() }
        if lines.isEmpty {
            lines.append("\"$schema\" = \"https://conductor.build/schemas/settings.schema.json\"")
        }

        let firstTable = lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
        } ?? lines.endIndex

        if let assignmentStart = lines[..<firstTable].firstIndex(where: {
            tomlAssignmentKey($0) == "environment_variable_files"
        }) {
            var assignmentEnd = assignmentStart
            var bracketDepth = tomlBracketDepth(lines[assignmentStart])
            while bracketDepth > 0, assignmentEnd + 1 < firstTable {
                assignmentEnd += 1
                bracketDepth += tomlBracketDepth(lines[assignmentEnd])
            }
            let existingValue = lines[assignmentStart...assignmentEnd].joined(separator: "\n")
            var paths = tomlQuotedStrings(existingValue)
            paths.removeAll { $0 == "environment_variable_files" }
            if !paths.contains(conductorEnvironmentURL.path) {
                paths.append(conductorEnvironmentURL.path)
            }
            let value = paths.map(tomlString).joined(separator: ", ")
            lines.replaceSubrange(
                assignmentStart...assignmentEnd,
                with: ["environment_variable_files = [\(value)] # Nativ integration"]
            )
        } else {
            var insertion = firstTable
            if insertion > 0, !lines[insertion - 1].isEmpty {
                lines.insert("", at: insertion)
                insertion += 1
            }
            lines.insert(
                "environment_variable_files = [\(tomlString(conductorEnvironmentURL.path))] # Nativ integration",
                at: insertion
            )
            if insertion + 1 < lines.count, !lines[insertion + 1].isEmpty {
                lines.insert("", at: insertion + 1)
            }
        }
        updateConductorVisibleModels(in: &lines, models: models)
        return lines.joined(separator: "\n") + "\n"
    }

    private func updateConductorVisibleModels(
        in lines: inout [String],
        models: [IntegrationModelDescriptor]
    ) {
        let modelsHeader: Int
        if let existingHeader = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[models]"
        }) {
            modelsHeader = existingHeader
        } else {
            if lines.last?.isEmpty == false { lines.append("") }
            lines.append("[models]")
            modelsHeader = lines.count - 1
        }

        let sectionStart = modelsHeader + 1
        let sectionEnd = lines[sectionStart...].firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
        }) ?? lines.endIndex
        let existingAssignment = lines[sectionStart..<sectionEnd].firstIndex(where: {
            tomlAssignmentKey($0) == "visible_provider_models"
        })

        var visibleModels: [String: Any] = [
            "claude": [],
            "codex": [],
            "cursor": [],
            "opencode": [],
            "pi": []
        ]
        if let existingAssignment,
           let encodedJSON = tomlQuotedStrings(lines[existingAssignment]).last,
           let data = encodedJSON.data(using: .utf8),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            visibleModels = existing
        }

        let nativPrefix = "opencode:\(Self.providerID)/"
        let existingOpenCodeModels = visibleModels["opencode"] as? [String] ?? []
        let unrelatedOpenCodeModels = existingOpenCodeModels.filter { !$0.hasPrefix(nativPrefix) }
        let nativModels = Set(models.map { "\(nativPrefix)\($0.id)" }).sorted()
        visibleModels["opencode"] = unrelatedOpenCodeModels + nativModels

        guard let data = try? JSONSerialization.data(
            withJSONObject: visibleModels,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        let encodedJSON = String(decoding: data, as: UTF8.self)
        let assignment = "visible_provider_models = \(tomlString(encodedJSON)) # Managed by Nativ"
        if let existingAssignment {
            lines[existingAssignment] = assignment
        } else {
            lines.insert(assignment, at: sectionStart)
        }
    }

    private func tomlAssignmentKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              let equals = trimmed.firstIndex(of: "=")
        else {
            return nil
        }
        return String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
    }

    private func tomlBracketDepth(_ line: String) -> Int {
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == nil {
                    quote = character
                } else if quote == character {
                    quote = nil
                }
                continue
            }
            guard quote == nil else { continue }
            if character == "[" { depth += 1 }
            if character == "]" { depth -= 1 }
        }
        return depth
    }

    private func tomlQuotedStrings(_ value: String) -> [String] {
        var strings: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var inComment = false
        for character in value {
            if inComment {
                if character == "\n" { inComment = false }
                continue
            }
            guard let activeQuote = quote else {
                if character == "#" {
                    inComment = true
                    continue
                }
                if character == "\"" || character == "'" {
                    quote = character
                    current = ""
                }
                continue
            }
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", activeQuote == "\"" {
                escaped = true
            } else if character == activeQuote {
                strings.append(current)
                quote = nil
            } else {
                current.append(character)
            }
        }
        return strings
    }

    private func launchConductor(applicationURL: URL, workingDirectory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-a",
            applicationURL.path,
            conductorDeepLink(workingDirectory: workingDirectory)
        ]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw IntegrationServiceError.desktopLaunchFailed(.conductor, error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            throw IntegrationServiceError.desktopLaunchFailed(
                .conductor,
                "open exited with status \(process.terminationStatus)"
            )
        }
    }

    private func conductorLaunchCommand(applicationURL: URL, workingDirectory: URL) -> String {
        [
            "/usr/bin/open",
            "-a",
            shellQuote(applicationURL.path),
            shellQuote(conductorDeepLink(workingDirectory: workingDirectory))
        ].joined(separator: " ")
    }

    private func conductorDeepLink(workingDirectory: URL) -> String {
        "conductor://prompt=&path=\(percentEncodedConductorValue(workingDirectory.path))"
    }

    private func percentEncodedConductorValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
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
        case .conductor:
            return ([], [:])
        case .hermes:
            return (["-p", Self.providerID, "chat", "--provider", "custom", "--model", selectedModelID], [:])
        case .openCode:
            return (
                ["--model", "\(Self.providerID)/\(selectedModelID)"],
                ["OPENCODE_CONFIG": configurationURL(for: tool).path]
            )
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

    private func dotenvString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private func yamlString(_ value: String) -> String {
        tomlString(value)
    }
}
