import NativServerKit
import XCTest

final class ChatPromptAssemblyTests: XCTestCase {
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
