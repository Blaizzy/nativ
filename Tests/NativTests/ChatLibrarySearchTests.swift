import Foundation
import SwiftUI
import XCTest

@MainActor
final class ChatLibrarySearchTests: XCTestCase {
    func testSearchesMessagesAcrossChatsWithTyposAndWordForms() async throws {
        let first = session("One", messages: [message("Notification permissions were updated.")])
        let second = session("Two", messages: [message("A notification permission was requested.")])
        let worker = ChatLibrarySearchWorker()
        let result = try await worker.search("notificaiton permission", sessions: [first, second])
        XCTAssertEqual(Set(result.messages.map(\.sessionID)), [first.id, second.id])
        XCTAssertTrue(result.messages.allSatisfy { $0.occurrence.range.length > 0 })
        let semantic = try await worker.search("authorization", sessions: [first, second])
        XCTAssertTrue(semantic.messages.isEmpty)
    }

    func testResultsBelongToMessagesAndGroupedResponsesKeepTheirRow() async throws {
        let user = message("notification notification")
        let tool = ChatTranscriptMessage(role: .tool, content: "notification tool internals")
        let assistant = ChatTranscriptMessage(role: .assistant, content: "Final **notification** response.")
        let input = session("Chat", messages: [user, tool, assistant])
        let result = try await ChatLibrarySearchWorker().search("notification", sessions: [input])
        XCTAssertEqual(result.messages.count, 2)
        let answer = try XCTUnwrap(result.messages.first { $0.isAssistant })
        XCTAssertEqual(answer.occurrence.messageID, assistant.id)
        XCTAssertEqual(answer.occurrence.rowID, tool.id)
        XCTAssertEqual(result.messages.filter { $0.occurrence.messageID == user.id }.count, 1)
    }

    func testForkedChatsCanShareMessageIDsWithoutSharingCachedContents() async throws {
        let id = UUID()
        let first = session("Original", messages: [message("notification", id: id)])
        let second = session("Fork", messages: [message("permission", id: id)])
        let worker = ChatLibrarySearchWorker()
        for _ in 0..<2 {
            let result = try await worker.search("notification", sessions: [first, second])
            XCTAssertEqual(result.messages.map(\.sessionID), [first.id])
            let other = try await worker.search("permission", sessions: [first, second])
            XCTAssertEqual(other.messages.map(\.sessionID), [second.id])
        }
        let shared = session("Fork", id: second.id, messages: [message("notification", id: id)])
        let both = try await worker.search("notification", sessions: [first, shared])
        XCTAssertEqual(Set(both.messages.map(\.id)).count, 2)
    }

    func testEditsDeletionsAndRenamesRefreshResults() async throws {
        let original = session("Old title", messages: [message("notification")])
        let worker = ChatLibrarySearchWorker()
        _ = try await worker.search("notification", sessions: [original])
        let edited = session("New title", id: original.id,
                             messages: [message("permission", id: original.inputs[0].messageID)])
        let oldQuery = try await worker.search("notification", sessions: [edited])
        XCTAssertTrue(oldQuery.messages.isEmpty)
        let newQuery = try await worker.search("permission", sessions: [edited])
        XCTAssertEqual(newQuery.messages.first?.title, "New title")
        let deleted = try await worker.search("permission", sessions: [])
        XCTAssertTrue(deleted.messages.isEmpty)
    }

    func testChangedOrDeletedMessagesCannotOpenAStaleResult() async throws {
        let message = message("notification")
        let input = session("Chat", messages: [message])
        let result = try await ChatLibrarySearchWorker().search("notification", sessions: [input])
        let match = try XCTUnwrap(result.messages.first)
        XCTAssertTrue(match.isCurrent(in: [.message(message)]))
        var edited = message
        edited.content = "unrelated replacement"
        XCTAssertFalse(match.isCurrent(in: [.message(edited)]))
        XCTAssertFalse(match.isCurrent(in: []))
    }

    func testLimitCountsMessagesAndStillSearchesOldChats() async throws {
        let old = session("Old", updatedAt: .distantPast, messages: [message("unique notification")])
        let recent = (0..<205).map { session("Recent \($0)", messages: [message("notification notification")]) }
        let worker = ChatLibrarySearchWorker()
        let common = try await worker.search("notification", sessions: recent + [old])
        XCTAssertEqual(common.messages.count, 200)
        XCTAssertTrue(common.hasMore)
        let rare = try await worker.search("unique notification", sessions: recent + [old])
        XCTAssertEqual(rare.messages.map(\.sessionID), [old.id])
        XCTAssertFalse(rare.hasMore)
    }

    func testExcerptPreservesUnicodeAndHighlightsTheMatchedWord() async throws {
        let content = String(repeating: "👩🏽‍💻 Background. ", count: 80) + "notification\nsettings"
        let result = try await ChatLibrarySearchWorker().search("notificaiton", sessions: [session("Unicode", messages: [message(content)])])
        let excerpt = try XCTUnwrap(result.messages.first).excerpt
        let text = String(excerpt.characters)
        XCTAssertTrue(text.contains("notification settings"))
        XCTAssertFalse(text.contains("\u{FFFD}"))
        XCTAssertLessThan(text.count, 245)
        XCTAssertTrue(excerpt.runs.contains { $0.backgroundColor != nil })
    }

    func testCancelledSearchDoesNotReturnResults() async throws {
        let worker = ChatLibrarySearchWorker()
        let sessions = [session("Chat", messages: [message("notification")])]
        let task = Task { try await worker.search("notification", sessions: sessions) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testDestinationIsConsumedOnlyByItsChatAndPreservesTheQuery() async throws {
        let input = session("Target", messages: [message("notification")])
        let results = try await ChatLibrarySearchWorker().search("notificaiton", sessions: [input])
        let result = try XCTUnwrap(results.messages.first)
        let state = ChatLibrarySearchState()
        state.present()
        state.query = "notificaiton"
        state.select(result)
        XCTAssertFalse(state.isPresented)
        XCTAssertNil(state.takeDestination(for: UUID()))
        let destination = try XCTUnwrap(state.takeDestination(for: input.id))
        XCTAssertEqual(destination.query, "notificaiton")
        XCTAssertEqual(destination.result.occurrence, result.occurrence)
        XCTAssertNil(state.takeDestination(for: input.id))
    }

    func testOpeningResultSelectsItsMessageInsteadOfFirstMatchInChat() async throws {
        let messages = [message("notification earlier"), message("notification target")]
        let input = session("Target", messages: messages)
        let result = try await ChatLibrarySearchWorker().search("notification", sessions: [input])
        let target = try XCTUnwrap(result.messages.first)
        let state = ChatSearchState()
        state.reveal(target.occurrence, query: "notification", sessionID: input.id,
                     items: ChatTranscriptPresentation.items(from: messages))
        // The view also observes the query change when the destination opens.
        state.update(items: ChatTranscriptPresentation.items(from: messages), queryChanged: true)
        try await waitForSearch(state)
        XCTAssertEqual(state.selected?.messageID, messages.last?.id)
        XCTAssertTrue(state.isPresented)
    }

    func testOpeningResultBeyondInChatResultLimitStillSelectsIt() async throws {
        let messages = [message(String(repeating: "notification ", count: 10_010)), message("notification target")]
        let input = session("Long chat", messages: messages)
        let result = try await ChatLibrarySearchWorker().search("notification", sessions: [input])
        let target = try XCTUnwrap(result.messages.first)
        let state = ChatSearchState()
        state.reveal(target.occurrence, query: "notification", sessionID: input.id,
                     items: ChatTranscriptPresentation.items(from: messages))
        try await waitForSearch(state)
        XCTAssertEqual(state.selected?.messageID, messages.last?.id)
        XCTAssertTrue(state.hasMore)
        let navigation = state.navigationID
        state.update(items: ChatTranscriptPresentation.items(from: messages + [message("New background message")]))
        try await waitForSearch(state)
        XCTAssertEqual(state.selected?.messageID, messages.last?.id)
        XCTAssertEqual(state.navigationID, navigation)
    }

    private func waitForSearch(_ state: ChatSearchState) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while state.isSearching, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(state.isSearching)
        XCTAssertNil(state.error)
    }

    private func message(_ text: String, id: UUID = UUID()) -> ChatTranscriptMessage {
        ChatTranscriptMessage(id: id, role: .user, content: text)
    }

    private func session(_ title: String, id: UUID = UUID(), updatedAt: Date = Date(),
                         messages: [ChatTranscriptMessage]) -> ChatLibrarySearchSession {
        let session = ChatSession(id: id, title: title, customTitle: title, createdAt: updatedAt,
                                  updatedAt: updatedAt, messages: messages)
        return ChatLibrarySearchSession(summary: session.summary, items: ChatTranscriptPresentation.items(from: messages))
    }
}
