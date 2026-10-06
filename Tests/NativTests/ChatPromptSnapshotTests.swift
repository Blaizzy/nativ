import NativServerKit
import XCTest

final class ChatPromptSnapshotTests: XCTestCase {
    private let terminal = ChatToolCapability(definition: ChatTerminalToolRegistry.definition, source: .native)
    private let toolSearch = ChatToolCapability(definition: ChatToolSearchToolRegistry.definition, source: .native)

    func testSnapshotsKeepFirstSubmissionValues() {
        var session = ChatSession(id: UUID(), title: "Chat", createdAt: .now, updatedAt: .now, messages: [])
        var settings = NativSettings()
        settings.systemPrompt = "Original"
        settings.skills = [NativSkill(instructions: "Skill"), NativSkill(instructions: "Off", isEnabled: false)]

        session.captureSnapshots(settings: settings)
        settings.systemPrompt = "Changed"
        settings.skills = []
        settings.setToolEnabled(false, toolName: ChatTerminalToolRegistry.toolName)
        session.captureSnapshots(settings: settings)

        XCTAssertEqual(session.sessionPromptSnapshot, "Original")
        XCTAssertEqual(session.capabilitySnapshot?.skills.map(\.instructions), ["Skill"])
        XCTAssertEqual(session.capabilitySnapshot?.exposurePolicy.disabledToolNames, [])
    }

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
        let snapshot = ChatCapabilitySnapshot(settings: settings)
        XCTAssertEqual(snapshot.exposure(for: terminal), .on)
        XCTAssertEqual(snapshot.exposure(for: custom), .automatic)
        XCTAssertEqual(snapshot.exposure(for: mcp), .automatic)

        settings.toolExposureModesMigrated = false
        let legacy = ChatCapabilitySnapshot(settings: settings)
        XCTAssertEqual(legacy.exposure(for: custom), .on)
        XCTAssertEqual(legacy.exposure(for: mcp), .on)
    }

    func testToolSearchRequiresADiscoverableCustomToolOrMCPServer() {
        var settings = NativSettings()
        XCTAssertEqual(ChatCapabilitySnapshot(settings: settings).exposure(for: toolSearch), .off)

        settings.mcpServers = [MCPServerConfig(name: "Server", command: "server")]
        XCTAssertEqual(ChatCapabilitySnapshot(settings: settings).exposure(for: toolSearch), .on)

        settings.setMCPServerExposureMode(.on, serverID: settings.mcpServers[0].id)
        XCTAssertEqual(ChatCapabilitySnapshot(settings: settings).exposure(for: toolSearch), .off)
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
