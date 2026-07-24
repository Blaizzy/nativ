import XCTest

final class IntegrationServicesTests: XCTestCase {
    private static let coveredTools: Set<IntegrationTool> = [
        .pi,
        .codex,
        .claudeCode,
        .hermes,
        .openCode,
        .aider,
        .goose,
        .crush,
        .qwenCode,
        .openClaw,
        .zed
    ]

    private var temporaryRoot: URL!
    private var homeDirectory: URL!
    private var applicationSupportDirectory: URL!
    private var manager: IntegrationProfileManager!
    private let serverBaseURL = URL(string: "http://127.0.0.1:49152")!

    private let selectedModel = IntegrationModelDescriptor(
        id: "org/local-model",
        displayName: "Local Model",
        contextWindow: 32_768,
        supportsVision: true,
        supportsReasoning: true,
        supportsTools: true
    )
    private let basicModel = IntegrationModelDescriptor(
        id: "org/basic-model",
        displayName: "Basic Model",
        contextWindow: nil,
        supportsVision: false,
        supportsReasoning: false,
        supportsTools: false
    )

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativIntegrationServicesTests-\(UUID().uuidString)", isDirectory: true)
        homeDirectory = temporaryRoot.appendingPathComponent("home", isDirectory: true)
        applicationSupportDirectory = temporaryRoot.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        manager = IntegrationProfileManager(
            serverBaseURL: serverBaseURL,
            homeDirectory: homeDirectory,
            applicationSupportDirectory: applicationSupportDirectory
        )
    }

    override func tearDownWithError() throws {
        manager = nil
        if let temporaryRoot {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        homeDirectory = nil
        applicationSupportDirectory = nil
    }

    func testEveryIntegrationHasCoverage() {
        XCTAssertEqual(Set(IntegrationTool.allCases), Self.coveredTools)
    }

    func testPiConfigurationAndLaunchCommand() throws {
        let configurationURL = manager.configurationURL(for: .pi)
        try FileManager.default.createDirectory(
            at: configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"theme\":\"dark\",\"providers\":{\"existing\":{}}}".utf8).write(to: configurationURL)

        try configure(.pi)

        let root = try json(at: configurationURL)
        XCTAssertEqual(root["theme"] as? String, "dark")
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        XCTAssertNotNil(providers["existing"])
        let provider = try XCTUnwrap(providers["nativ"] as? [String: Any])
        XCTAssertEqual(provider["baseUrl"] as? String, "http://127.0.0.1:49152/v1")
        XCTAssertEqual(provider["api"] as? String, "openai-completions")
        let models = try XCTUnwrap(provider["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0]["id"] as? String, selectedModel.id)
        XCTAssertEqual(models[0]["contextWindow"] as? Int, selectedModel.contextWindow)
        XCTAssertEqual(models[0]["input"] as? [String], ["text", "image"])
        XCTAssertNil(models[1]["contextWindow"])

        XCTAssertEqual(
            launchCommand(for: .pi),
            "cd '/tmp/Nativ Project'\n'/tools/pi' '--provider' 'nativ' '--model' 'org/local-model'"
        )
    }

    func testCodexCLIConfigurationDoesNotChangeBaseConfiguration() throws {
        let codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let baseConfigurationURL = codexDirectory.appendingPathComponent("config.toml")
        let baseConfiguration = "model_provider = \"openai\"\n[features]\nfast_mode = true\n"
        try Data(baseConfiguration.utf8).write(to: baseConfigurationURL)

        try configure(.codex)
        try manager.configure(
            tool: .codex,
            selectedModelID: basicModel.id,
            models: [selectedModel, basicModel],
            maxOutputTokens: 65_536
        )

        let profileURL = manager.configurationURL(for: .codex)
        let profile = try String(contentsOf: profileURL, encoding: .utf8)
        XCTAssertEqual(profileURL, codexDirectory.appendingPathComponent("nativ.config.toml"))
        XCTAssertEqual(try String(contentsOf: baseConfigurationURL, encoding: .utf8), baseConfiguration)
        XCTAssertEqual(
            profile,
            CodexCLIProfile.contents(selectedModelID: basicModel.id, baseURL: "http://127.0.0.1:49152/v1")
        )
        XCTAssertFalse(profile.contains(selectedModel.id))
        XCTAssertEqual(profile.components(separatedBy: "# Managed by Nativ.").count - 1, 1)
        XCTAssertEqual(
            launchCommand(for: .codex),
            "cd '/tmp/Nativ Project'\n'/tools/codex' '--profile' 'nativ' '--model' 'org/local-model'"
        )
    }

    func testClaudeCodeConfigurationAndLaunchCommand() throws {
        try configure(.claudeCode)

        let configurationURL = manager.configurationURL(for: .claudeCode)
        let root = try json(at: configurationURL)
        let environment = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"] as? String, "nativ")
        XCTAssertEqual(environment["ANTHROPIC_API_KEY"] as? String, "")
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"] as? String, "http://127.0.0.1:49152")
        XCTAssertEqual(environment["ANTHROPIC_MODEL"] as? String, selectedModel.id)
        XCTAssertEqual(environment["ANTHROPIC_SMALL_FAST_MODEL"] as? String, selectedModel.id)
        XCTAssertEqual(
            launchCommand(for: .claudeCode),
            """
            cd '/tmp/Nativ Project'
            export ANTHROPIC_API_KEY=''
            export ANTHROPIC_AUTH_TOKEN='nativ'
            export ANTHROPIC_BASE_URL='http://127.0.0.1:49152'
            '/tools/claude' '--settings' '\(configurationURL.path)' '--model' 'org/local-model'
            """
        )
    }

    func testHermesConfigurationAndLaunchCommand() throws {
        try configure(.hermes)

        let configurationURL = manager.configurationURL(for: .hermes)
        let configuration = try String(contentsOf: configurationURL, encoding: .utf8)
        XCTAssertTrue(configuration.contains("default: \"org/local-model\""))
        XCTAssertTrue(configuration.contains("base_url: \"http://127.0.0.1:49152/v1\""))
        XCTAssertTrue(configuration.contains("\"org/local-model\":\n        context_length: 32768\n        supports_vision: true"))
        XCTAssertTrue(configuration.contains("\"org/basic-model\":\n        context_length: 131072"))
        XCTAssertEqual(
            try String(
                contentsOf: configurationURL.deletingLastPathComponent().appendingPathComponent("profile.yaml"),
                encoding: .utf8
            ),
            "name: nativ\ndescription: Local models from Nativ\n"
        )
        XCTAssertEqual(
            launchCommand(for: .hermes),
            "cd '/tmp/Nativ Project'\n'/tools/hermes' '-p' 'nativ' 'chat' '--provider' 'custom' '--model' 'org/local-model'"
        )
    }

    func testOpenCodeConfigurationAndLaunchCommand() throws {
        try configure(.openCode)

        let configurationURL = manager.configurationURL(for: .openCode)
        let root = try json(at: configurationURL)
        XCTAssertEqual(root["model"] as? String, "nativ/\(selectedModel.id)")
        let providers = try XCTUnwrap(root["provider"] as? [String: Any])
        let provider = try XCTUnwrap(providers["nativ"] as? [String: Any])
        XCTAssertEqual(provider["npm"] as? String, "@ai-sdk/openai-compatible")
        let options = try XCTUnwrap(provider["options"] as? [String: Any])
        XCTAssertEqual(options["baseURL"] as? String, "http://127.0.0.1:49152/v1")
        let models = try XCTUnwrap(provider["models"] as? [String: Any])
        let selected = try XCTUnwrap(models[selectedModel.id] as? [String: Any])
        XCTAssertEqual(selected["attachment"] as? Bool, true)
        XCTAssertEqual(selected["tool_call"] as? Bool, true)
        XCTAssertEqual(selected["interleaved"] as? [String: String], ["field": "reasoning_content"])
        let selectedLimit = try XCTUnwrap(selected["limit"] as? [String: Int])
        XCTAssertEqual(selectedLimit, ["context": 32_768, "output": 32_768])
        let basic = try XCTUnwrap(models[basicModel.id] as? [String: Any])
        let basicLimit = try XCTUnwrap(basic["limit"] as? [String: Int])
        XCTAssertEqual(basicLimit, ["context": 131_072, "output": 65_536])
        XCTAssertEqual(
            launchCommand(for: .openCode),
            """
            cd '/tmp/Nativ Project'
            export OPENCODE_CONFIG='\(configurationURL.path)'
            '/tools/opencode' '--model' 'nativ/org/local-model'
            """
        )
    }

    func testAiderConfigurationAndLaunchCommand() throws {
        try configure(.aider)

        let configurationURL = manager.configurationURL(for: .aider)
        let contents = try String(contentsOf: configurationURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("OPENAI_API_BASE=http://127.0.0.1:49152/v1"))
        XCTAssertTrue(contents.contains("OPENAI_API_KEY=nativ"))
        XCTAssertEqual(
            launchCommand(for: .aider),
            "cd '/tmp/Nativ Project'\n'/tools/aider' '--env-file' '\(configurationURL.path)' '--model' 'openai/org/local-model'"
        )
    }

    func testGooseConfigurationAndLaunchCommand() throws {
        try configure(.goose)

        let configurationURL = manager.configurationURL(for: .goose)
        let root = try json(at: configurationURL)
        XCTAssertEqual(root["name"] as? String, "nativ")
        XCTAssertEqual(root["engine"] as? String, "openai")
        XCTAssertEqual(root["api_key_env"] as? String, "NATIV_API_KEY")
        XCTAssertEqual(root["base_url"] as? String, "http://127.0.0.1:49152/v1/chat/completions")
        let models = try XCTUnwrap(root["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0]["name"] as? String, selectedModel.id)
        XCTAssertEqual(models[0]["context_limit"] as? Int, selectedModel.contextWindow)
        XCTAssertEqual(models[1]["context_limit"] as? Int, 131_072)
        XCTAssertEqual(
            launchCommand(for: .goose),
            """
            cd '/tmp/Nativ Project'
            export GOOSE_MODEL='org/local-model'
            export NATIV_API_KEY='nativ'
            '/tools/goose' 'session' 'start' '--provider' 'nativ'
            """
        )
    }

    func testCrushConfigurationAndLaunchCommand() throws {
        try configure(.crush)

        let configurationURL = manager.configurationURL(for: .crush)
        let root = try json(at: configurationURL)
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        let provider = try XCTUnwrap(providers["nativ"] as? [String: Any])
        XCTAssertEqual(provider["type"] as? String, "openai-compat")
        XCTAssertEqual(provider["base_url"] as? String, "http://127.0.0.1:49152/v1")
        XCTAssertEqual(provider["api_key"] as? String, "nativ")
        let models = try XCTUnwrap(provider["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0]["id"] as? String, selectedModel.id)
        XCTAssertEqual(models[0]["context_window"] as? Int, selectedModel.contextWindow)
        XCTAssertNil(models[1]["context_window"])
        let selection = try XCTUnwrap(root["models"] as? [String: Any])
        let large = try XCTUnwrap(selection["large"] as? [String: Any])
        XCTAssertEqual(large["model"] as? String, selectedModel.id)
        XCTAssertEqual(large["provider"] as? String, "nativ")
        XCTAssertEqual(large["max_tokens"] as? Int, 65_536)
        XCTAssertEqual(
            launchCommand(for: .crush),
            """
            cd '/tmp/Nativ Project'
            export CRUSH_GLOBAL_CONFIG='\(configurationURL.path)'
            '/tools/crush'
            """
        )
    }

    func testQwenCodeConfigurationAndLaunchCommand() throws {
        try configure(.qwenCode)

        let configurationURL = manager.configurationURL(for: .qwenCode)
        let contents = try String(contentsOf: configurationURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("OPENAI_API_KEY=nativ"))
        XCTAssertTrue(contents.contains("OPENAI_BASE_URL=http://127.0.0.1:49152/v1"))
        XCTAssertTrue(contents.contains("OPENAI_MODEL=org/local-model"))
        XCTAssertEqual(
            launchCommand(for: .qwenCode),
            """
            cd '/tmp/Nativ Project'
            export OPENAI_API_KEY='nativ'
            export OPENAI_BASE_URL='http://127.0.0.1:49152/v1'
            export OPENAI_MODEL='org/local-model'
            '/tools/qwen'
            """
        )
    }

    func testOpenClawConfigurationAndLaunchCommand() throws {
        try configure(.openClaw)

        let configurationURL = manager.configurationURL(for: .openClaw)
        let root = try json(at: configurationURL)
        let modelsRoot = try XCTUnwrap(root["models"] as? [String: Any])
        let providers = try XCTUnwrap(modelsRoot["providers"] as? [String: Any])
        let provider = try XCTUnwrap(providers["nativ"] as? [String: Any])
        XCTAssertEqual(provider["baseUrl"] as? String, "http://127.0.0.1:49152/v1")
        XCTAssertEqual(provider["api"] as? String, "openai-completions")
        XCTAssertEqual(provider["apiKey"] as? String, "nativ")
        let models = try XCTUnwrap(provider["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0]["id"] as? String, selectedModel.id)
        XCTAssertEqual(models[0]["contextWindow"] as? Int, selectedModel.contextWindow)
        XCTAssertNil(models[1]["contextWindow"])
        XCTAssertEqual(
            launchCommand(for: .openClaw),
            "cd '/tmp/Nativ Project'\n'/tools/openclaw' 'agent' '--model' 'nativ/org/local-model'"
        )
    }

    func testZedConfigurationAndLaunchCommand() throws {
        try configure(.zed)

        let configurationURL = manager.configurationURL(for: .zed)
        let root = try json(at: configurationURL)
        let languageModels = try XCTUnwrap(root["language_models"] as? [String: Any])
        let openAICompatible = try XCTUnwrap(languageModels["openai_compatible"] as? [String: Any])
        let provider = try XCTUnwrap(openAICompatible["nativ"] as? [String: Any])
        XCTAssertEqual(provider["api_url"] as? String, "http://127.0.0.1:49152/v1")
        let models = try XCTUnwrap(provider["available_models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0]["name"] as? String, selectedModel.id)
        XCTAssertEqual(models[0]["display_name"] as? String, selectedModel.displayName)
        XCTAssertEqual(models[0]["max_tokens"] as? Int, selectedModel.contextWindow)
        XCTAssertEqual(models[1]["max_tokens"] as? Int, 131_072)
        XCTAssertEqual(
            launchCommand(for: .zed),
            """
            cd '/tmp/Nativ Project'
            export NATIV_API_KEY='nativ'
            '/tools/zed' '.'
            """
        )
    }

    private func configure(_ tool: IntegrationTool) throws {
        try manager.configure(
            tool: tool,
            selectedModelID: selectedModel.id,
            models: [selectedModel, basicModel],
            maxOutputTokens: 65_536
        )
    }

    private func launchCommand(for tool: IntegrationTool) -> String {
        manager.launchCommand(
            tool: tool,
            executableURL: URL(fileURLWithPath: "/tools/\(tool.commandName)"),
            selectedModelID: selectedModel.id,
            workingDirectory: URL(fileURLWithPath: "/tmp/Nativ Project")
        )
    }

    private func json(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
