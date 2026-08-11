import XCTest
import NativServerKit

final class ChatConversationBranchTests: XCTestCase {
    func testLatestUserMessageIDReturnsOnlyTheLastUserMessage() {
        let firstUser = message(.user, "First")
        let assistant = message(.assistant, "Response")
        let lastUser = message(.user, "Second")

        XCTAssertEqual(
            ChatConversationBranch.latestUserMessageID(in: [firstUser, assistant, lastUser]),
            lastUser.id
        )
    }

    func testEditingLatestPromptCreatesANewBranchAndPreservesTheSource() throws {
        let firstUser = message(.user, "First")
        let firstResponse = message(.assistant, "Response")
        let latestUser = message(.user, "Original")
        let latestResponse = message(.assistant, "Original response")
        let source = [firstUser, firstResponse, latestUser, latestResponse]
        let revisedID = UUID()
        let revisedAt = Date(timeIntervalSince1970: 1_000)

        let branch = try XCTUnwrap(ChatConversationBranch.replacingLatestUserMessage(
            latestUser.id,
            with: "  Revised prompt  ",
            attachments: [],
            modelID: "model",
            newMessageID: revisedID,
            createdAt: revisedAt,
            in: source
        ))

        XCTAssertEqual(branch.map(\.id), [firstUser.id, firstResponse.id, revisedID])
        XCTAssertEqual(branch.last?.content, "Revised prompt")
        XCTAssertEqual(branch.last?.modelID, "model")
        XCTAssertEqual(branch.last?.createdAt, revisedAt)
        XCTAssertEqual(source.map(\.content), ["First", "Response", "Original", "Original response"])
    }

    func testEditingAnOlderPromptIsRejected() {
        let olderUser = message(.user, "First")
        let latestUser = message(.user, "Second")

        XCTAssertNil(ChatConversationBranch.replacingLatestUserMessage(
            olderUser.id,
            with: "Revised",
            attachments: [],
            modelID: "model",
            in: [olderUser, message(.assistant, "Response"), latestUser]
        ))
    }

    func testForkingAssistantResponseIncludesTheCompleteToolTurn() throws {
        let firstUser = message(.user, "First")
        var response = message(.assistant, "I will check")
        response.toolCalls = [MLXChatToolCall(
            id: "call",
            function: MLXChatFunctionCall(name: "search", arguments: "{}")
        )]
        let tool = ChatTranscriptMessage(
            role: .tool,
            content: "Result",
            toolCallID: "call",
            toolName: "search"
        )
        let finalResponse = message(.assistant, "Done")
        let nextUser = message(.user, "Next")
        let source = [firstUser, response, tool, finalResponse, nextUser, message(.assistant, "Later")]

        let branch = try XCTUnwrap(
            ChatConversationBranch.throughAssistantResponse(response.id, in: source)
        )

        XCTAssertEqual(branch.map(\.id), [firstUser.id, response.id, tool.id, finalResponse.id])
    }

    func testStreamingAssistantResponseCannotBeForked() {
        let response = ChatTranscriptMessage(
            role: .assistant,
            content: "Partial",
            isStreaming: true
        )

        XCTAssertNil(ChatConversationBranch.throughAssistantResponse(response.id, in: [response]))
    }

    private func message(
        _ role: ChatTranscriptMessage.Role,
        _ content: String
    ) -> ChatTranscriptMessage {
        ChatTranscriptMessage(role: role, content: content)
    }
}
