import Foundation
import XCTest

@testable import NativServerKit

final class ChatTranscriptPresentationTests: XCTestCase {
    func testToolTurnCoalescesToolsAndSumsReasoningDuration() throws {
        let user = ChatTranscriptMessage(role: .user, content: "Investigate this")
        let firstAssistant = assistantCalling(
            id: "read-1",
            toolName: ChatReadFileToolRegistry.toolName,
            reasoning: "I should inspect the first file.",
            duration: 1
        )
        let firstRead = toolResult(
            id: "read-1",
            toolName: ChatReadFileToolRegistry.toolName
        )
        let secondAssistant = assistantCalling(
            id: "read-2",
            toolName: ChatReadFileToolRegistry.toolName,
            reasoning: "The related file may contain the implementation.",
            duration: 2
        )
        let secondRead = toolResult(
            id: "read-2",
            toolName: ChatReadFileToolRegistry.toolName
        )
        let commandAssistant = assistantCalling(
            id: "terminal-1",
            toolName: ChatTerminalToolRegistry.toolName,
            reasoning: "I should verify the behavior.",
            duration: 3
        )
        let command = toolResult(
            id: "terminal-1",
            toolName: ChatTerminalToolRegistry.toolName
        )
        let searchAssistant = assistantCalling(
            id: "search-1",
            toolName: ChatWebSearchToolRegistry.toolName,
            reasoning: "One external detail still needs confirmation.",
            duration: 4
        )
        let search = toolResult(
            id: "search-1",
            toolName: ChatWebSearchToolRegistry.toolName
        )
        let finalAssistant = ChatTranscriptMessage(
            role: .assistant,
            content: "Here is what I found.",
            modelID: "org/model"
        )

        let items = ChatTranscriptPresentation.items(from: [
            user,
            firstAssistant, firstRead,
            secondAssistant, secondRead,
            commandAssistant, command,
            searchAssistant, search,
            finalAssistant,
        ])

        XCTAssertEqual(items.count, 2)
        guard case .agentTurn(let turn) = items[1] else {
            return XCTFail("Expected a coalesced agent turn")
        }
        XCTAssertEqual(turn.id, firstAssistant.id)
        XCTAssertEqual(turn.finalAssistantMessage?.id, finalAssistant.id)
        XCTAssertEqual(try XCTUnwrap(turn.thinkingDuration), 10, accuracy: 0.001)
        XCTAssertEqual(
            turn.reasoningContent,
            [
                firstAssistant.reasoningContent,
                secondAssistant.reasoningContent,
                commandAssistant.reasoningContent,
                searchAssistant.reasoningContent,
            ].joined(separator: "\n\n")
        )
        XCTAssertEqual(turn.toolUsage.groups.count, 3)
        XCTAssertEqual(
            turn.toolUsage.text,
            "Read files, ran a command, searched the web"
        )
    }

    func testResponseWithoutToolsKeepsIndividualMessageRows() {
        let user = ChatTranscriptMessage(role: .user, content: "Hello")
        let assistant = ChatTranscriptMessage(role: .assistant, content: "Hi")

        let items = ChatTranscriptPresentation.items(from: [user, assistant])

        XCTAssertEqual(items, [.message(user), .message(assistant)])
    }

    func testTurnIdentityRemainsStableWhenFirstAssistantAddsAToolCall() {
        let user = ChatTranscriptMessage(role: .user, content: "Inspect this")
        let assistantID = UUID()
        let streamingAssistant = ChatTranscriptMessage(
            id: assistantID,
            role: .assistant,
            content: "",
            isStreaming: true
        )
        let initialItems = ChatTranscriptPresentation.items(from: [user, streamingAssistant])

        let callingAssistant = ChatTranscriptMessage(
            id: assistantID,
            role: .assistant,
            content: "",
            toolCalls: [call(id: "read-1", toolName: ChatReadFileToolRegistry.toolName)]
        )
        let read = toolResult(
            id: "read-1",
            toolName: ChatReadFileToolRegistry.toolName,
            status: .running,
            isStreaming: true
        )
        let toolItems = ChatTranscriptPresentation.items(from: [user, callingAssistant, read])

        XCTAssertEqual(initialItems[1].id, assistantID)
        XCTAssertEqual(toolItems[1].id, assistantID)
        guard case .agentTurn = toolItems[1] else {
            return XCTFail("Expected the tool call to promote the row to an agent turn")
        }
    }

    func testSummaryKeepsFailureAndInteractionStatesTruthful() {
        let failedRead = toolResult(
            id: "read-1",
            toolName: ChatReadFileToolRegistry.toolName,
            status: .failed
        )
        let pendingCommand = toolResult(
            id: "terminal-1",
            toolName: ChatTerminalToolRegistry.toolName,
            status: .awaitingConsent
        )

        let summary = ChatToolUsageSummary(messages: [failedRead, pendingCommand])

        XCTAssertEqual(summary.text, "File read failed, waiting to run a command")
        XCTAssertTrue(summary.hasFailure)
        XCTAssertTrue(summary.requiresInteraction)
        XCTAssertFalse(summary.isActive)
    }

    func testFailureTakesPrecedenceWithinAnActiveToolGroup() {
        let failedRead = toolResult(
            id: "read-1",
            toolName: ChatReadFileToolRegistry.toolName,
            status: .failed
        )
        let runningRead = toolResult(
            id: "read-2",
            toolName: ChatReadFileToolRegistry.toolName,
            status: .running,
            isStreaming: true
        )

        let summary = ChatToolUsageSummary(messages: [failedRead, runningRead])

        XCTAssertEqual(summary.text, "File reads failed")
        XCTAssertTrue(summary.hasFailure)
        XCTAssertTrue(summary.isActive)
    }

    func testGenericMCPToolsUseBareReadableNames() {
        let first = toolResult(
            id: "mcp-1",
            toolName: "mcp__github__search_issues"
        )
        let second = toolResult(
            id: "mcp-2",
            toolName: "mcp__github__search_issues"
        )

        let summary = ChatToolUsageSummary(messages: [first, second])

        XCTAssertEqual(summary.text, "Used search issues 2 times")
    }

    private func assistantCalling(
        id: String,
        toolName: String,
        reasoning: String,
        duration: TimeInterval
    ) -> ChatTranscriptMessage {
        ChatTranscriptMessage(
            role: .assistant,
            content: "",
            reasoningContent: reasoning,
            modelID: "org/model",
            thinkingDuration: duration,
            toolCalls: [call(id: id, toolName: toolName)]
        )
    }

    private func toolResult(
        id: String,
        toolName: String,
        status: ChatTranscriptMessage.ToolStatus = .succeeded,
        isStreaming: Bool = false
    ) -> ChatTranscriptMessage {
        ChatTranscriptMessage(
            role: .tool,
            content: #"{"ok":true}"#,
            isStreaming: isStreaming,
            toolCallID: id,
            toolName: toolName,
            toolStatus: status,
            toolArguments: "{}"
        )
    }

    private func call(id: String, toolName: String) -> MLXChatToolCall {
        MLXChatToolCall(
            id: id,
            function: MLXChatFunctionCall(name: toolName, arguments: "{}")
        )
    }
}
