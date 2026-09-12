import Foundation
import SQLite3
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

    func testIncrementalSynchronizationKeepsUnchangedChatsAndUpdatesOrdering() async throws {
        let older = session("Older", updatedAt: .distantPast, messages: [message("notification")])
        let newer = session("Newer", messages: [message("notification")])
        let worker = ChatLibrarySearchWorker()
        try await worker.synchronize([older, newer], summaries: [older.summary, newer.summary])
        let initial = try await worker.search("notification")
        XCTAssertEqual(initial.messages.map(\.sessionID), [newer.id, older.id])
        let edited = session("Renamed", id: older.id, updatedAt: .distantFuture,
                             messages: [message("notification permissions")])
        try await worker.synchronize([edited], summaries: [edited.summary, newer.summary])
        let updated = try await worker.search("notification")
        XCTAssertEqual(updated.messages.map(\.sessionID), [older.id, newer.id])
        XCTAssertEqual(updated.messages.first?.title, "Renamed")
        try await worker.synchronize([], summaries: [newer.summary])
        let deleted = try await worker.search("notification")
        XCTAssertEqual(deleted.messages.map(\.sessionID), [newer.id])
    }

    func testPersistentIndexRestoresGlobalAndInChatResults() async throws {
        let url = try databaseURL()
        let messages = [message("👋 cafe\u{301} notification"), message("We ran yesterday."), message("mice")]
        let chat = session("Stored", messages: messages)
        let worker = ChatLibrarySearchWorker(storageURL: url)
        try await worker.synchronize([chat], summaries: [chat.summary])
        for query in ["café", "notificaiton", "running", "mouse"] {
            let before = try await worker.search(query)
            let restored = ChatLibrarySearchWorker(storageURL: url)
            let after = try await restored.search(query)
            XCTAssertEqual(after.messages, before.messages, query)
            let local = try await restored.search(query, sessionID: chat.id)
            XCTAssertEqual(Set(local.occurrences.map(\.messageID)), Set(before.messages.map { $0.occurrence.messageID }))
        }
    }

    func testPersistentIndexReconcilesEditsDeletionsAndNewMessages() async throws {
        let url = try databaseURL()
        let first = session("First", messages: [message("notification")])
        let removed = session("Removed", messages: [message("obsolete")])
        let worker = ChatLibrarySearchWorker(storageURL: url)
        try await worker.synchronize([first, removed], summaries: [first.summary, removed.summary])
        let updated = session("Renamed", id: first.id, messages: [
            message("permission", id: first.inputs[0].messageID), message("notification newest"),
        ])
        let relaunched = ChatLibrarySearchWorker(storageURL: url)
        try await relaunched.synchronize([updated], summaries: [updated.summary])
        let restored = ChatLibrarySearchWorker(storageURL: url)
        let obsolete = try await restored.search("obsolete")
        XCTAssertTrue(obsolete.messages.isEmpty)
        let notification = try await restored.search("notification")
        XCTAssertEqual(notification.messages.map { $0.occurrence.messageID }, [updated.inputs[1].messageID])
        XCTAssertEqual(notification.messages.first?.title, "Renamed")
        let permission = try await restored.search("permission")
        XCTAssertEqual(permission.messages.map { $0.occurrence.messageID }, [updated.inputs[0].messageID])
    }

    func testPersistentIndexPreservesForkNamespacesAndMessageOrder() async throws {
        let url = try databaseURL()
        let sharedID = UUID()
        let first = session("Original", messages: [message("notification", id: sharedID), message("notification later")])
        let fork = session("Fork", messages: [message("permissions", id: sharedID)])
        let worker = ChatLibrarySearchWorker(storageURL: url)
        try await worker.synchronize([first, fork], summaries: [first.summary, fork.summary])
        let restored = ChatLibrarySearchWorker(storageURL: url)
        let global = try await restored.search("notification")
        XCTAssertEqual(global.messages.map { $0.occurrence.messageID }, first.inputs.reversed().map(\.messageID))
        let local = try await restored.search("notification", sessionID: first.id)
        XCTAssertEqual(local.occurrences.map(\.messageID), first.inputs.map(\.messageID))
        let other = try await restored.search("permission", sessionID: fork.id)
        XCTAssertEqual(other.occurrences.map(\.messageID), [sharedID])
    }

    func testSharedIndexSurvivesSearchDismissalAndQueryClearing() async throws {
        let url = try databaseURL()
        let library = ChatSearchLibrary(storageURL: url)
        let chat = session("Shared", messages: [message("notification")])
        try await library.worker.synchronize([chat], summaries: [chat.summary])
        let local = ChatSearchState()
        local.reset(sessionID: chat.id, library: library)
        local.query = "notification"
        local.update(items: [.message(message("notification", id: chat.inputs[0].messageID))])
        try await waitForSearch(local)
        local.dismiss()
        let popup = ChatLibrarySearchState()
        popup.present()
        popup.dismiss()
        let remaining = try await library.worker.search("notification")
        XCTAssertEqual(remaining.messages.count, 1)
    }

    func testDamagedAndIncompatibleCachesAreRebuilt() async throws {
        let url = try databaseURL()
        try Data("damaged cache".utf8).write(to: url)
        let chat = session("Rebuilt", messages: [message("notification")])
        var worker: ChatLibrarySearchWorker? = ChatLibrarySearchWorker(storageURL: url)
        try await worker?.synchronize([chat], summaries: [chat.summary])
        let first = try await worker?.search("notification")
        XCTAssertEqual(first?.messages.count, 1)
        worker = nil
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "UPDATE metadata SET version = 'obsolete'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let rebuilt = ChatLibrarySearchWorker(storageURL: url)
        try await rebuilt.synchronize([chat], summaries: [chat.summary])
        let result = try await rebuilt.search("notification")
        XCTAssertEqual(result.messages.count, 1)
    }

    func testMessageEventsUpdateThePersistentIndexWithoutOpeningSearch() async throws {
        let url = try databaseURL()
        let library = ChatSearchLibrary(storageURL: url)
        library.start([])
        let id = UUID()
        var snapshot = session("Live", id: id, messages: [message("notification")])
        library.enqueue(id) { snapshot }
        try await library.ready()
        let initial = try await library.worker.search("notification")
        XCTAssertEqual(initial.messages.count, 1)
        snapshot = session("Edited", id: id, messages: [message("permission", id: snapshot.inputs[0].messageID)])
        library.enqueue(id) { snapshot }
        try await library.ready()
        let restored = ChatLibrarySearchWorker(storageURL: url)
        let old = try await restored.search("notification")
        XCTAssertTrue(old.messages.isEmpty)
        let updated = try await restored.search("permission")
        XCTAssertEqual(updated.messages.first?.title, "Edited")
        library.remove(id)
        try await library.ready()
        let deleted = try await ChatLibrarySearchWorker(storageURL: url).search("permission")
        XCTAssertTrue(deleted.messages.isEmpty)
    }

    func testBurstUpdatesReadOnlyTheLatestSnapshot() async throws {
        let library = ChatSearchLibrary(storageURL: try databaseURL())
        library.start([])
        let id = UUID()
        var reads = 0
        var snapshot = session("Streaming", id: id, messages: [message("Initial")])
        for index in 0..<100 {
            snapshot = session("Streaming", id: id, messages: [message("notification revision \(index)")])
            library.enqueue(id) { reads += 1; return snapshot }
        }
        try await library.ready()
        XCTAssertEqual(reads, 1)
        let result = try await library.worker.search("\"revision 99\"")
        XCTAssertEqual(result.messages.count, 1)
    }

    func testStreamingUpdatesMakeProgressAndPersistTheFinalMessage() async throws {
        let url = try databaseURL()
        let library = ChatSearchLibrary(storageURL: url)
        library.start([])
        let id = UUID()
        let messageID = UUID()
        var reads = 0
        var text = "notification"
        for index in 0..<12 {
            text += " update\(index)"
            library.enqueue(id) {
                reads += 1
                return self.session("Streaming", id: id, messages: [self.message(text, id: messageID)])
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertGreaterThan(reads, 0)
        try await library.ready()
        XCTAssertLessThan(reads, 12)
        let restored = ChatLibrarySearchWorker(storageURL: url)
        let result = try await restored.search("\"update11\"")
        XCTAssertEqual(result.messages.map { $0.occurrence.messageID }, [messageID])
    }

    func testDeletionSupersedesAnUnprocessedSnapshot() async throws {
        let url = try databaseURL()
        let library = ChatSearchLibrary(storageURL: url)
        library.start([])
        let chat = session("Deleted", messages: [message("notification")])
        library.enqueue(chat.id) { chat }
        library.remove(chat.id)
        try await library.ready()
        let result = try await ChatLibrarySearchWorker(storageURL: url).search("notification")
        XCTAssertTrue(result.messages.isEmpty)
    }

    func testSharedInChatSearchDoesNotRequestTranscriptSnapshots() async throws {
        let library = ChatSearchLibrary(storageURL: try databaseURL())
        library.start([])
        let chat = session("Shared", messages: [message("notification permission")])
        library.enqueue(chat.id) { chat }
        try await library.ready()
        let state = ChatSearchState()
        state.reset(sessionID: chat.id, library: library)
        var reads = 0
        func items() -> [ChatTranscriptItem] { reads += 1; return [] }
        for query in ["notification", "permission"] {
            state.query = query
            state.update(items: items(), queryChanged: true)
            try await waitForSearch(state)
            XCTAssertEqual(state.occurrences.count, 1)
        }
        XCTAssertEqual(reads, 0)
    }

    func testTwoSearchViewsShareMessageUpdates() async throws {
        let library = ChatSearchLibrary(storageURL: try databaseURL())
        library.start([])
        let id = UUID()
        let messageID = UUID()
        var snapshot = session("Shared", id: id, messages: [message("notification", id: messageID)])
        library.enqueue(id) { snapshot }
        try await library.ready()
        let views = [ChatSearchState(), ChatSearchState()]
        for view in views {
            view.reset(sessionID: id, library: library)
            view.query = "notification"
            view.update(items: [], queryChanged: true)
            try await waitForSearch(view)
            XCTAssertEqual(view.occurrences.count, 1)
        }
        snapshot = session("Shared", id: id, messages: [message("replacement", id: messageID)])
        library.enqueue(id) { snapshot }
        try await library.ready()
        for view in views {
            view.update(items: [])
            try await waitForSearch(view)
            XCTAssertTrue(view.occurrences.isEmpty)
        }
    }

    func testStartupStorageFailureIsReported() async throws {
        let url = try databaseURL().deletingLastPathComponent()
        let library = ChatSearchLibrary(storageURL: url)
        library.start([])
        do {
            try await library.ready()
            XCTFail("Expected the directory to be rejected as a database")
        } catch {
            XCTAssertNotNil(library.error)
            XCTAssertGreaterThan(library.revision, 0)
        }
    }

    private func databaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ChatSearchTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appending(path: "Search.sqlite")
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
