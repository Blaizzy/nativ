import XCTest

final class ChatConversationBranchTests: XCTestCase {
    func testPersonalizationSnapshotIsFrozenAcrossEditsReloadAndBranching() throws {
        var personalization = NativPersonalization()
        personalization.profile.preferredName = "Alex"
        personalization.profile.conversationStyle = .concise
        personalization.profile.emojiUsage = .none
        personalization.profile.markdownUsage = .minimal
        personalization.profile.aboutYou = "Lives in Paris"
        var session = ChatSession(id: UUID(), title: "New chat", createdAt: .now, updatedAt: .now, messages: [])
        session.capturePersonalization(personalization)
        let snapshot = try XCTUnwrap(session.personalizationSnapshot)
        XCTAssertTrue(snapshot.contains("Alex"))
        XCTAssertTrue(snapshot.contains(NativPersonalization.ConversationStyle.concise.systemPrompt))
        XCTAssertTrue(snapshot.contains(NativPersonalization.EmojiUsage.none.systemPrompt))
        XCTAssertTrue(snapshot.contains(NativPersonalization.MarkdownUsage.minimal.systemPrompt))
        XCTAssertTrue(snapshot.contains("Lives in Paris"))
        session.messages.append(ChatTranscriptMessage(role: .user, content: "Hello"))

        personalization.profile.preferredName = "Sam"
        personalization.profile.conversationStyle = .detailed
        personalization.profile.emojiUsage = .more
        personalization.profile.markdownUsage = .structured
        personalization.profile.aboutYou = ""
        session = try JSONDecoder().decode(ChatSession.self, from: JSONEncoder().encode(session))
        session.capturePersonalization(personalization)
        XCTAssertEqual(session.personalizationSnapshot, snapshot)
        let branch = ChatConversationBranch.make(from: session, messages: session.messages)
        XCTAssertEqual(branch.personalizationSnapshot, snapshot)

        var newSession = ChatSession(id: UUID(), title: "New chat", createdAt: .now, updatedAt: .now, messages: [])
        newSession.capturePersonalization(personalization)
        XCTAssertTrue(try XCTUnwrap(newSession.personalizationSnapshot).contains("Sam"))
        XCTAssertTrue(try XCTUnwrap(newSession.personalizationSnapshot).contains(NativPersonalization.ConversationStyle.detailed.systemPrompt))
        XCTAssertTrue(try XCTUnwrap(newSession.personalizationSnapshot).contains(NativPersonalization.EmojiUsage.more.systemPrompt))
        XCTAssertTrue(try XCTUnwrap(newSession.personalizationSnapshot).contains(NativPersonalization.MarkdownUsage.structured.systemPrompt))
        XCTAssertFalse(try XCTUnwrap(newSession.personalizationSnapshot).contains("Paris"))
    }

    func testEmptySnapshotStaysEmptyAndLegacyHistoryDoesNotGainPersonalization() throws {
        var session = ChatSession(id: UUID(), title: "New chat", createdAt: .now, updatedAt: .now, messages: [])
        session.capturePersonalization(NativPersonalization())
        var personalization = NativPersonalization()
        personalization.profile.preferredName = "Alex"
        session.capturePersonalization(personalization)
        XCTAssertEqual(session.personalizationSnapshot, "")

        session.personalizationSnapshot = nil
        session.messages = [ChatTranscriptMessage(role: .user, content: "Existing history")]
        let data = try JSONEncoder().encode(session)
        var legacy = try JSONDecoder().decode(ChatSession.self, from: data)
        XCTAssertNil(legacy.personalizationSnapshot)
        legacy.capturePersonalization(personalization)
        XCTAssertEqual(legacy.personalizationSnapshot, "")
    }

    func testRevisingLatestPromptReplacesItsResponseHistoryWithoutChangingSession() throws {
        let firstUser = ChatTranscriptMessage(role: .user, content: "First prompt")
        let firstAssistant = ChatTranscriptMessage(role: .assistant, content: "First response")
        let latestUser = ChatTranscriptMessage(role: .user, content: "Original prompt")
        let latestAssistant = ChatTranscriptMessage(role: .assistant, content: "Old response")
        let sessionID = UUID()
        var session = ChatSession(
            id: sessionID,
            title: "First prompt",
            createdAt: .now,
            updatedAt: .now,
            messages: [firstUser, firstAssistant, latestUser, latestAssistant]
        )

        let revision = try XCTUnwrap(
            ChatPromptRevision.make(
                messageID: latestUser.id,
                content: "Edited prompt",
                attachments: [],
                modelID: "test/model",
                in: session.messages
            )
        )
        session.messages = revision.messages

        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.messages.map(\.id), [firstUser.id, firstAssistant.id, latestUser.id])
        XCTAssertEqual(session.messages.last?.content, "Edited prompt")
        XCTAssertEqual(session.messages.last?.modelID, "test/model")
        XCTAssertFalse(session.messages.contains(where: { $0.id == latestAssistant.id }))
    }

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
