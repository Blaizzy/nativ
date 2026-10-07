import NativServerKit
import XCTest

final class ChatPromptAssemblyTests: XCTestCase {
    private let terminal = ChatToolCapability(definition: ChatTerminalToolRegistry.definition, source: .native)
    private let toolSearch = ChatToolCapability(definition: ChatToolSearchToolRegistry.definition, source: .native)

    func testExposureDefaultsAndLegacySettings() {
        let custom = ChatToolCapability(
            definition: MLXChatToolDefinition(
                function: MLXChatFunctionDefinition(name: "custom__weather", description: "", parameters: .object([:]))
            ),
            source: .custom("Weather")
        )
        let mcp = ChatToolCapability(
            definition: MLXChatToolDefinition(
                function: MLXChatFunctionDefinition(name: "mcp__git__status", description: "", parameters: .object([:]))
            ),
            source: .mcp(serverID: UUID(), name: "Git")
        )
        var settings = NativSettings()
        XCTAssertEqual(settings.exposure(for: terminal), .on)
        XCTAssertEqual(settings.exposure(for: custom), .automatic)
        XCTAssertEqual(settings.exposure(for: mcp), .automatic)

        settings.toolExposureModesMigrated = false
        XCTAssertEqual(settings.exposure(for: custom), .on)
        XCTAssertEqual(settings.exposure(for: mcp), .on)
    }

    func testToolSearchNeedsADiscoverableToolOrServer() {
        let serverID = UUID()
        let mcp = ChatToolCapability(
            definition: MLXChatToolDefinition(
                function: MLXChatFunctionDefinition(name: "mcp__git__status", description: "", parameters: .object([:]))
            ),
            source: .mcp(serverID: serverID, name: "Git")
        )
        var settings = NativSettings()
        XCTAssertFalse(settings.toolSearchIsNeeded(among: [terminal, toolSearch]))

        settings.mcpServers = [MCPServerConfig(id: serverID, name: "Git", command: "git-mcp")]
        XCTAssertTrue(settings.toolSearchIsNeeded(among: [terminal, toolSearch, mcp]))
        XCTAssertTrue(settings.sendsDirectly(toolSearch, among: [terminal, toolSearch, mcp]))
        XCTAssertFalse(settings.sendsDirectly(toolSearch, among: [terminal, toolSearch]), "server not connected")

        settings.setMCPServerExposureMode(.on, serverID: serverID)
        XCTAssertFalse(settings.toolSearchIsNeeded(among: [terminal, toolSearch, mcp]))
        XCTAssertFalse(settings.sendsDirectly(toolSearch, among: [terminal, toolSearch, mcp]))
    }

    @MainActor
    func testRenamingKeepsSavedToolChoices() {
        var settings = NativSettings()
        settings.setToolExposureMode(.on, toolName: "custom__weather")
        settings.setToolExposureMode(.off, toolName: "mcp__git__status")
        let previousPrefix = MCPHostManager.toolNamePrefix(for: MCPServerConfig(name: "git"))
        let prefix = MCPHostManager.toolNamePrefix(for: MCPServerConfig(name: "Git Work"))

        settings.renameToolKeys { $0 == "custom__weather" ? "custom__forecast" : nil }
        settings.renameToolKeys { $0.hasPrefix(previousPrefix) ? prefix + $0.dropFirst(previousPrefix.count) : nil }

        XCTAssertEqual(settings.toolExposureMode(for: "custom__forecast"), .on)
        XCTAssertEqual(settings.toolExposureMode(for: "custom__weather"), .automatic)
        XCTAssertEqual(settings.toolExposureMode(for: "mcp__Git_Work__status"), .off)
        XCTAssertEqual(settings.disabledToolNames, ["mcp__Git_Work__status"])
    }

    func testToolSearchIsNeverDiscoverable() {
        var settings = NativSettings()
        settings.toolExposureModes[ChatToolSearchToolRegistry.toolName] = .automatic

        XCTAssertEqual(settings.toolExposureMode(for: ChatToolSearchToolRegistry.toolName), .on)
        XCTAssertEqual(ToolExposureMode.options(forTool: ChatToolSearchToolRegistry.toolName), [.off, .on])
    }

    func testExposureModesRoundTripAndLegacyDecode() throws {
        var settings = NativSettings()
        settings.setToolExposureMode(.on, toolName: "custom__weather")
        let decoded = try PropertyListDecoder().decode(NativSettings.self, from: PropertyListEncoder().encode(settings))
        XCTAssertEqual(decoded.toolExposureMode(for: "custom__weather"), .on)
        XCTAssertTrue(decoded.toolExposureModesMigrated)

        settings.setToolExposureMode(.automatic, toolName: "custom__weather")
        XCTAssertNil(settings.toolExposureModes["custom__weather"])
        settings.setToolExposureMode(.off, toolName: "custom__weather")
        XCTAssertEqual(settings.disabledToolNames, ["custom__weather"])
    }

    @MainActor
    func testCompletionRequestOrdersSystemHistoryLatestTurnAndToolLoop() {
        let skill = NativSkill(name: "Skill", instructions: "Skill instructions")
        let systemPrompt = ChatViewModel.systemPrompt(
            sessionPrompt: "Session prompt",
            personalizationPrompt: "Personalization",
            projectPrompt: "Project context",
            includesChatWork: true,
            includesToolGuide: true,
            skills: [skill]
        )
        XCTAssertEqual(
            systemPrompt,
            [
                ChatViewModel.corePrompt,
                ChatWorkToolRegistry.sessionPrompt,
                "Session prompt",
                "Personalization",
                "Project context",
                NativSkill.builtInToolGuide.instructions,
                "Skill instructions",
            ].joined(separator: "\n\n")
        )

        let call = MLXChatToolCall(
            id: "call-1",
            function: MLXChatFunctionCall(name: "chat_work", arguments: "{}")
        )
        let latestUser = ChatTranscriptMessage(role: .user, content: "Latest question")
        let transcript = [
            ChatTranscriptMessage(role: .user, content: "First question"),
            ChatTranscriptMessage(role: .assistant, content: "First answer"),
            latestUser,
            ChatTranscriptMessage(role: .assistant, content: "", toolCalls: [call]),
            ChatTranscriptMessage(
                role: .tool,
                content: "[]",
                toolCallID: "call-1",
                toolName: "chat_work"
            ),
        ]

        let initial = ChatViewModel.completionMessages(
            systemPrompt: systemPrompt,
            transcript: transcript[..<3],
            documentContexts: [latestUser.id: "Attached document"],
            includesImages: true
        )
        XCTAssertEqual(
            initial,
            [
                MLXChatMessage(role: "system", content: systemPrompt),
                MLXChatMessage(role: "user", content: "First question"),
                MLXChatMessage(role: "assistant", content: "First answer"),
                MLXChatMessage(role: "user", content: "Latest question\n\nAttached document"),
            ]
        )

        let followUp = ChatViewModel.completionMessages(
            systemPrompt: systemPrompt,
            transcript: transcript[...],
            documentContexts: [latestUser.id: "Attached document"],
            includesImages: true
        )
        XCTAssertEqual(Array(followUp.prefix(4)), initial)
        XCTAssertEqual(
            Array(followUp.dropFirst(4)),
            [
                MLXChatMessage(role: "assistant", content: "", toolCalls: [call]),
                MLXChatMessage(role: "tool", content: "[]", toolCallID: "call-1", name: "chat_work"),
            ]
        )
        XCTAssertFalse(systemPrompt.contains("Latest question"))
        XCTAssertFalse(systemPrompt.contains("Attached document"))
    }
}
