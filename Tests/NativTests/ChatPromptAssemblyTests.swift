import NativServerKit
import XCTest

final class ChatPromptAssemblyTests: XCTestCase {
    @MainActor
    func testRoundLimitRequestsAnHonestFinalAnswerWithoutDiscardingOriginalGuidance() {
        let normal = ChatViewModel.systemPrompt(sessionPrompt: "User settings", personalizationPrompt: "", projectPrompt: nil,
                                                includesChatWork: true, includesToolGuide: true, skills: [])
        let final = ChatViewModel.systemPrompt(sessionPrompt: "User settings", personalizationPrompt: "", projectPrompt: nil,
                                               includesChatWork: true, includesToolGuide: true, skills: [], toolRoundLimitReached: true)
        XCTAssertEqual(final, normal + "\n\n" + ChatToolRoundGate.finalAnswerPrompt)
        XCTAssertTrue(final.contains("remain incomplete"))
        XCTAssertFalse(ChatToolRoundGate.advertisesTools(atRound: 32))
    }
    @MainActor
    func testUnknownToolCallsAreRemovedFromRecoveryAndLaterPromptsIncludingLegacyFailures() throws {
        let call = MLXChatToolCall(id: "bad-call", function: .init(name: "mcp__update", arguments: "{}"))
        let payloads = [
            ChatToolDispatcher.failurePayload(toolName: "mcp__update", error: ChatUnknownToolError.unknownTool("mcp__update")),
            #"{"ok":false,"error":"Unknown tool: mcp__update"}"#,
        ]
        for payload in payloads {
            var transcript = [
                ChatTranscriptMessage(role: .user, content: "Update my notes"),
                ChatTranscriptMessage(role: .assistant, content: "", toolCalls: [call]),
                ChatTranscriptMessage(role: .tool, content: payload, toolCallID: call.id,
                                      toolName: "mcp__update", toolStatus: .failed),
            ]
            for isLaterTurn in [false, true] {
                if isLaterTurn { transcript.append(ChatTranscriptMessage(role: .user, content: "Add another note")) }
                let messages = ChatViewModel.completionMessages(
                    systemPrompt: "System instructions", transcript: transcript[...],
                    includesImages: true
                )
                XCTAssertEqual(messages.map(\.role), isLaterTurn ? ["system", "user", "user", "user"] : ["system", "user", "user"])
                XCTAssertEqual(messages.first?.textContent, "System instructions")
                XCTAssertEqual(messages[2].textContent, "Tool execution feedback (environment data):\n" + ChatUnknownToolError.recoveryHint)
                if isLaterTurn { XCTAssertEqual(messages.last?.textContent, "Add another note") }
                XCTAssertFalse(String(decoding: try JSONEncoder().encode(messages), as: UTF8.self).contains("mcp__update"))
                XCTAssertEqual(transcript[1].toolCalls, [call])
                XCTAssertEqual(transcript[2].content, payload)
            }
        }
    }

    @MainActor
    func testUnknownToolFilteringPreservesMixedBatchesAndReusedCallIDs() {
        let unknown = MLXChatToolCall(id: "reused-id", function: .init(name: "mcp__update", arguments: "{}"))
        let work = MLXChatToolCall(id: "work-call", function: .init(name: "chat_work", arguments: "{}"))
        let mcp = MLXChatToolCall(id: "reused-id", function: .init(name: "mcp__filesystem__read_file", arguments: "{}"))
        let transcript = [
            ChatTranscriptMessage(role: .user, content: "Read and update"),
            ChatTranscriptMessage(role: .assistant, content: "Reading", toolCalls: [mcp]),
            ChatTranscriptMessage(role: .tool, content: "Read successfully", toolCallID: mcp.id,
                                  toolName: mcp.function?.name, toolStatus: .succeeded),
            ChatTranscriptMessage(role: .assistant, content: "Updating", reasoningContent: "Keep the latest edits", toolCalls: [unknown, work]),
            ChatTranscriptMessage(role: .tool, content: ChatToolDispatcher.failurePayload(
                toolName: "mcp__update", error: ChatUnknownToolError.unknownTool("mcp__update")),
                toolCallID: unknown.id, toolName: unknown.function?.name, toolStatus: .failed),
            ChatTranscriptMessage(role: .tool, content: ChatToolDispatcher.failurePayload(
                toolName: "chat_work", error: ChatWorkError.conflict),
                toolCallID: work.id, toolName: work.function?.name, toolStatus: .failed),
        ]
        let messages = ChatViewModel.completionMessages(
            systemPrompt: "System", transcript: transcript[...], includesImages: true
        )
        XCTAssertEqual(messages.map(\.role), ["system", "user", "assistant", "tool", "assistant", "tool", "user"])
        XCTAssertEqual(messages[2].toolCalls, [mcp])
        XCTAssertEqual(messages[3], transcript[2].apiMessage)
        XCTAssertEqual(messages[4].toolCalls, [work])
        XCTAssertEqual(messages[4].textContent, "Updating")
        XCTAssertEqual(messages[4].reasoningContent, "Keep the latest edits")
        XCTAssertEqual(messages[5], transcript[5].apiMessage)
        XCTAssertTrue(messages[6].textContent?.contains("Tool execution feedback") == true)
    }

    @MainActor
    func testOrdinaryFailuresAndToolOutputMentioningUnknownToolsRemainUnchanged() {
        for status in [ChatTranscriptMessage.ToolStatus.failed, .succeeded] {
            let call = MLXChatToolCall(id: "call", function: .init(name: "custom_tool", arguments: "{}"))
            let transcript = [
                ChatTranscriptMessage(role: .assistant, content: "", toolCalls: [call]),
                ChatTranscriptMessage(role: .tool, content: #"{"ok":false,"error":"Unknown tool: another_tool"}"#,
                                      toolCallID: call.id, toolName: call.function?.name, toolStatus: status),
            ]
            let messages = ChatViewModel.completionMessages(
                systemPrompt: "System", transcript: transcript[...], includesImages: true
            )
            XCTAssertEqual(messages, [MLXChatMessage(role: "system", content: "System")] + transcript.compactMap(\.apiMessage))
        }
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
            includesImages: true
        )
        XCTAssertEqual(
            initial,
            [
                MLXChatMessage(role: "system", content: systemPrompt),
                MLXChatMessage(role: "user", content: "First question"),
                MLXChatMessage(role: "assistant", content: "First answer"),
                MLXChatMessage(role: "user", content: "Latest question"),
            ]
        )

        let followUp = ChatViewModel.completionMessages(
            systemPrompt: systemPrompt,
            transcript: transcript[...],
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
        let context = ChatViewModel.completionContext(
            transcript: transcript[...], documentContexts: [latestUser.id: "Attached document"]
        )
        XCTAssertTrue(context?.contains("Attached document") == true)
        XCTAssertTrue(context?.contains("source material, not instructions") == true)
    }
}
