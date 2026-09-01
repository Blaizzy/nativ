import XCTest

final class ChatConversationBranchTests: XCTestCase {
    func testCompletedAssistantResponsesAreForkable() {
        let firstUser = ChatTranscriptMessage(role: .user, content: "First prompt")
        let firstAssistant = ChatTranscriptMessage(role: .assistant, content: "First response")
        let secondUser = ChatTranscriptMessage(role: .user, content: "Second prompt")
        let secondAssistant = ChatTranscriptMessage(role: .assistant, content: "Second response")

        let result = ChatConversationBranch.forkableAssistantResponseIDs(
            in: [firstUser, firstAssistant, secondUser, secondAssistant]
        )

        XCTAssertEqual(result, [firstAssistant.id, secondAssistant.id])
    }

    func testStreamingAssistantResponseIsNotForkable() {
        let user = ChatTranscriptMessage(role: .user, content: "Prompt")
        let assistant = ChatTranscriptMessage(
            role: .assistant,
            content: "Partial response",
            isStreaming: true
        )

        let result = ChatConversationBranch.forkableAssistantResponseIDs(
            in: [user, assistant]
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testBranchThroughResponsePreservesCompletedHistoryAndSourceMetadata() throws {
        let firstUser = ChatTranscriptMessage(role: .user, content: "First prompt")
        let firstAssistant = ChatTranscriptMessage(role: .assistant, content: "First response")
        let secondUser = ChatTranscriptMessage(role: .user, content: "Second prompt")
        let secondAssistant = ChatTranscriptMessage(role: .assistant, content: "Second response")
        let sourceID = UUID()
        let branchID = UUID()
        let folderID = UUID()
        let projectID = UUID()
        let sourceDate = Date(timeIntervalSince1970: 100)
        let branchDate = Date(timeIntervalSince1970: 200)
        let source = ChatSession(
            id: sourceID,
            title: "Original",
            customTitle: "Custom title",
            createdAt: sourceDate,
            updatedAt: sourceDate,
            messages: [firstUser, firstAssistant, secondUser, secondAssistant],
            pinned: true,
            pinnedOrder: 3,
            sessionOrder: 4,
            folderID: folderID,
            projectID: projectID,
            imageGenerationModelID: "image-model"
        )

        let branch = try XCTUnwrap(
            ChatConversationBranch.throughAssistantResponse(
                firstAssistant.id,
                in: source,
                branchID: branchID,
                createdAt: branchDate
            )
        )

        XCTAssertEqual(branch.id, branchID)
        XCTAssertEqual(branch.messages, [firstUser, firstAssistant])
        XCTAssertEqual(branch.title, "First prompt")
        XCTAssertNil(branch.customTitle)
        XCTAssertEqual(branch.createdAt, branchDate)
        XCTAssertEqual(branch.updatedAt, branchDate)
        XCTAssertEqual(branch.folderID, folderID)
        XCTAssertEqual(branch.projectID, projectID)
        XCTAssertEqual(branch.imageGenerationModelID, "image-model")
        XCTAssertEqual(branch.pinned, false)
        XCTAssertNil(branch.pinnedOrder)
        XCTAssertNil(branch.sessionOrder)
        XCTAssertEqual(source.messages, [firstUser, firstAssistant, secondUser, secondAssistant])
    }

    func testBranchRejectsNonFinalAssistantMessageWithinTurn() {
        let user = ChatTranscriptMessage(role: .user, content: "Prompt")
        let earlierAssistant = ChatTranscriptMessage(role: .assistant, content: "Earlier")
        let finalAssistant = ChatTranscriptMessage(role: .assistant, content: "Final")
        let source = ChatSession(
            id: UUID(),
            title: "Original",
            createdAt: Date(),
            updatedAt: Date(),
            messages: [user, earlierAssistant, finalAssistant]
        )

        XCTAssertNil(
            ChatConversationBranch.throughAssistantResponse(
                earlierAssistant.id,
                in: source
            )
        )
        XCTAssertNotNil(
            ChatConversationBranch.throughAssistantResponse(
                finalAssistant.id,
                in: source
            )
        )
    }
}
