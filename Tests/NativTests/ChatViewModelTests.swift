import AppKit
import Observation
import XCTest

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testDraftChangesNotifyComposerReadersWithoutPublishingTranscriptChanges() {
        let subject = ChatViewModel()
        var transcriptNotifications = 0
        let subscription = subject.objectWillChange.sink { transcriptNotifications += 1 }
        defer { subscription.cancel() }
        let composerChange = expectation(description: "Composer observes the draft")
        withObservationTracking {
            _ = subject.draft
            _ = subject.canSend(isRunning: true, selectedModelID: "model")
        } onChange: {
            composerChange.fulfill()
        }

        subject.draft = "Hello"

        XCTAssertEqual(transcriptNotifications, 0, "Typing must not invalidate transcript observers")
        XCTAssertTrue(subject.canSend(isRunning: true, selectedModelID: "model"))
        wait(for: [composerChange], timeout: 0.1)
    }

    func testInitialComposerAndRequestStateIsIdle() {
        let subject = ChatViewModel()

        XCTAssertEqual(subject.draft, "")
        XCTAssertTrue(subject.pendingImageAttachments.isEmpty)
        XCTAssertFalse(subject.hasPendingRequests)
        XCTAssertFalse(subject.isCurrentSessionSending)
        XCTAssertTrue(subject.currentSessionQueuedPrompts.isEmpty)
    }

    func testCanSendRequiresRunningServerModelAndContent() {
        let subject = ChatViewModel()

        subject.draft = "Hello"

        XCTAssertFalse(subject.canSend(isRunning: false, selectedModelID: "model"))
        XCTAssertFalse(subject.canSend(isRunning: true, selectedModelID: nil))
        XCTAssertFalse(subject.canSend(isRunning: true, selectedModelID: ""))
        XCTAssertTrue(subject.canSend(isRunning: true, selectedModelID: "model"))

        subject.draft = "  \n  "

        XCTAssertFalse(subject.canSend(isRunning: true, selectedModelID: "model"))
    }

    func testPendingAttachmentEnablesSendAndCanBeRemoved() {
        let subject = ChatViewModel()
        let attachment = ChatImageAttachment(
            filename: "reference.png",
            mimeType: "image/png",
            base64Data: "AA=="
        )

        subject.stageAttachment(attachment)

        XCTAssertEqual(subject.pendingImageAttachments, [attachment])
        XCTAssertTrue(subject.canSend(isRunning: true, selectedModelID: "model"))

        subject.removePendingImageAttachment(attachment.id)

        XCTAssertTrue(subject.pendingImageAttachments.isEmpty)
        XCTAssertFalse(subject.canSend(isRunning: true, selectedModelID: "model"))
    }

    func testPastingTextDoesNotSetAttachmentImportError() {
        let subject = ChatViewModel()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setString("Plain text", forType: .string)

        XCTAssertFalse(subject.attachImages(from: pasteboard))
        XCTAssertNil(subject.attachmentImportError)
        XCTAssertTrue(subject.pendingImageAttachments.isEmpty)
    }

    func testUnavailableReasonUsesServerAndModelPreconditions() {
        let subject = ChatViewModel()

        XCTAssertEqual(
            subject.unavailableReason(isRunning: false, selectedModelID: "model"),
            "Server is stopped."
        )
        XCTAssertEqual(
            subject.unavailableReason(isRunning: true, selectedModelID: nil),
            "Choose a model in Models."
        )
        XCTAssertNil(subject.unavailableReason(isRunning: true, selectedModelID: "model"))
    }

    func testGeneratedChatTitlesUseTypographicEllipsis() {
        let title = ChatSession.defaultTitle(
            for: [ChatTranscriptMessage(role: .user, content: String(repeating: "a", count: 80))]
        )

        XCTAssertEqual(title.count, 56)
        XCTAssertTrue(title.hasSuffix("…"))
    }
}

final class MediaAssetPersistenceTests: XCTestCase {
    func testChatSessionStoresBinaryOutsideJSONAndLoadsSummaryLazily() throws {
        let fixture = try makeFixture()
        let payload = Data(repeating: 0xAB, count: 2 * 1_024 * 1_024)
        let attachment = ChatImageAttachment(
            filename: "large.png",
            mimeType: "image/png",
            base64Data: payload.base64EncodedString()
        )
        let now = Date()
        let session = ChatSession(
            id: UUID(),
            title: "Asset test",
            createdAt: now,
            updatedAt: now,
            messages: [ChatTranscriptMessage(role: .user, content: "hello", imageAttachments: [attachment])]
        )

        fixture.chatStore.saveSession(session)

        let json = try String(contentsOf: fixture.chatStore.sessionURL(for: session.id), encoding: .utf8)
        XCTAssertFalse(json.contains("base64Data"))
        XCTAssertTrue(json.contains("relativePath"))
        XCTAssertLessThan(json.utf8.count, 10_000)

        let loaded = try XCTUnwrap(fixture.chatStore.loadSessions().first)
        let migratedAsset = try XCTUnwrap(loaded.messages[0].imageAttachments[0].asset)
        XCTAssertEqual(fixture.mediaStore.data(for: migratedAsset), payload)
    }

    func testLegacyCacheMigrationIsIdempotentAndRemovesOriginal() throws {
        let fixture = try makeFixture()
        let sessions = fixture.legacyChat.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let payload = Data(repeating: 0xCD, count: 512 * 1_024)
        let now = Date()
        let session = ChatSession(
            id: UUID(),
            title: "Legacy",
            createdAt: now,
            updatedAt: now,
            messages: [ChatTranscriptMessage(
                role: .user,
                content: "legacy",
                imageAttachments: [ChatImageAttachment(
                    filename: "legacy.png",
                    mimeType: "image/png",
                    base64Data: payload.base64EncodedString()
                )]
            )]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyURL = sessions.appendingPathComponent("\(session.id.uuidString).json")
        try encoder.encode(session).write(to: legacyURL)

        XCTAssertEqual(fixture.chatStore.loadSessions().map(\.id), [session.id])
        XCTAssertEqual(fixture.chatStore.loadSessions().map(\.id), [session.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyChat.path))
        let migratedJSON = try String(contentsOf: fixture.chatStore.sessionURL(for: session.id), encoding: .utf8)
        XCTAssertFalse(migratedJSON.contains("base64Data"))
        let migratedAsset = try XCTUnwrap(
            fixture.chatStore.loadSession(id: session.id)?.messages[0].imageAttachments[0].asset
        )
        XCTAssertEqual(fixture.mediaStore.data(for: migratedAsset), payload)
    }

    func testDeletedMigratedChatStaysDeletedAfterSaveAndRelaunch() throws {
        let fixture = try makeFixture()
        let legacySessions = fixture.legacyChat.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: legacySessions, withIntermediateDirectories: true)
        let now = Date()
        let session = ChatSession(
            id: UUID(), title: "Legacy", createdAt: now, updatedAt: now,
            messages: [ChatTranscriptMessage(role: .user, content: "legacy")]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyURL = legacySessions.appendingPathComponent("\(session.id.uuidString).json")
        try encoder.encode(session).write(to: legacyURL)
        XCTAssertEqual(fixture.chatStore.loadSessions().map(\.id), [session.id])

        fixture.chatStore.deleteSession(id: session.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.chatStore.sessionURL(for: session.id).path))
        let replacement = ChatSession(
            id: UUID(), title: "New chat", createdAt: now, updatedAt: now, messages: []
        )
        XCTAssertTrue(fixture.chatStore.saveSession(replacement))

        let relaunchedStore = ChatSessionStore(
            chatDirectory: fixture.root.appendingPathComponent("Chat", isDirectory: true),
            legacyChatDirectory: fixture.legacyChat,
            mediaStore: fixture.mediaStore
        )
        XCTAssertNil(relaunchedStore.loadSession(id: session.id))
        XCTAssertEqual(relaunchedStore.loadSessions().map(\.id), [replacement.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testDeletedLegacyTranscriptStaysDeletedAfterRelaunch() throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.legacyChat, withIntermediateDirectories: true)
        let legacyURL = fixture.legacyChat.appendingPathComponent("current.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([ChatTranscriptMessage(role: .user, content: "old transcript")])
            .write(to: legacyURL)
        let session = try XCTUnwrap(fixture.chatStore.loadSessions().first)

        fixture.chatStore.deleteSession(id: session.id)
        let relaunchedStore = ChatSessionStore(
            chatDirectory: fixture.root.appendingPathComponent("Chat", isDirectory: true),
            legacyChatDirectory: fixture.legacyChat,
            mediaStore: fixture.mediaStore
        )
        XCTAssertTrue(relaunchedStore.loadSessions().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testFailedLegacyChatMigrationRetriesBeforeMarkingComplete() throws {
        let fixture = try makeFixture()
        let legacySessions = fixture.legacyChat.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: legacySessions, withIntermediateDirectories: true)
        let now = Date()
        let session = ChatSession(
            id: UUID(), title: "Legacy", createdAt: now, updatedAt: now,
            messages: [ChatTranscriptMessage(role: .user, content: "legacy")]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: legacySessions.appendingPathComponent("\(session.id.uuidString).json"))

        let destination = fixture.chatStore.sessionURL(for: session.id).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A regular file prevents the session directory from being created on the first attempt.
        try Data().write(to: destination)
        XCTAssertTrue(fixture.chatStore.loadSessions().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacySessions.appendingPathComponent("\(session.id.uuidString).json").path))
        try FileManager.default.removeItem(at: destination)

        let relaunchedStore = ChatSessionStore(
            chatDirectory: fixture.root.appendingPathComponent("Chat", isDirectory: true),
            legacyChatDirectory: fixture.legacyChat,
            mediaStore: fixture.mediaStore
        )
        XCTAssertEqual(relaunchedStore.loadSessions().map(\.id), [session.id])
        relaunchedStore.deleteSession(id: session.id)
        XCTAssertTrue(relaunchedStore.loadSessions().isEmpty)
    }

    func testDeletedMigratedImageSessionStaysDeletedAfterRelaunch() throws {
        let fixture = try makeFixture()
        let legacyDirectory = fixture.root.appendingPathComponent("LegacyImages", isDirectory: true)
        let legacySessions = legacyDirectory.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: legacySessions, withIntermediateDirectories: true)
        let now = Date()
        let session = ImageGenerationSession(
            id: UUID(), title: "Legacy image", createdAt: now, updatedAt: now,
            modelKind: .imageGeneration, modelID: "test/model", draftSettings: ImageRequestSettings(),
            activeReference: nil, turns: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyURL = legacySessions.appendingPathComponent("\(session.id.uuidString).json")
        try encoder.encode(session).write(to: legacyURL)
        let store = ImageGenerationSessionStore(
            imageDirectory: fixture.root.appendingPathComponent("Images", isDirectory: true),
            legacyImageDirectory: legacyDirectory,
            mediaStore: fixture.mediaStore
        )
        XCTAssertEqual(store.loadSessions().map(\.id), [session.id])
        store.deleteSession(id: session.id)

        let relaunchedStore = ImageGenerationSessionStore(
            imageDirectory: fixture.root.appendingPathComponent("Images", isDirectory: true),
            legacyImageDirectory: legacyDirectory,
            mediaStore: fixture.mediaStore
        )
        XCTAssertNil(relaunchedStore.loadSession(id: session.id))
        XCTAssertTrue(relaunchedStore.loadSessions().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testCompletedMigrationCleansRemainingOriginalsWithoutRestoringDeletedSessions() throws {
        let fixture = try makeFixture()
        // Simulate a migration completed by an older build, with originals still present and destinations deleted.
        for (legacyName, destinationName) in [("LegacyChat", "Chat"), ("LegacyImages", "Images")] {
            let legacySessions = fixture.root.appendingPathComponent(legacyName).appendingPathComponent("Sessions")
            let destination = fixture.root.appendingPathComponent(destinationName)
            try FileManager.default.createDirectory(at: legacySessions, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: legacySessions.appendingPathComponent("deleted.json"))
            try Data().write(to: destination.appendingPathComponent(".legacy-cache-migration-complete"))
        }

        XCTAssertTrue(fixture.chatStore.loadSessions().isEmpty)
        let imageStore = ImageGenerationSessionStore(
            imageDirectory: fixture.root.appendingPathComponent("Images"),
            legacyImageDirectory: fixture.root.appendingPathComponent("LegacyImages"),
            mediaStore: fixture.mediaStore
        )
        XCTAssertTrue(imageStore.loadSessions().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyChat.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("LegacyImages").path))
    }

    func testLegacyCleanupPreservesCurrentVersionAndUnrelatedFiles() throws {
        let fixture = try makeFixture()
        let now = Date()
        var session = ChatSession(
            id: UUID(), title: "Current", createdAt: now, updatedAt: now,
            messages: [ChatTranscriptMessage(role: .user, content: "current content")]
        )
        XCTAssertTrue(fixture.chatStore.saveSession(session))
        let legacySessions = fixture.legacyChat.appendingPathComponent("Sessions")
        try FileManager.default.createDirectory(at: legacySessions, withIntermediateDirectories: true)
        session.messages = [ChatTranscriptMessage(role: .user, content: "outdated content")]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyURL = legacySessions.appendingPathComponent("\(session.id.uuidString).json")
        try encoder.encode(session).write(to: legacyURL)
        let unrelatedURL = fixture.legacyChat.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: unrelatedURL)

        XCTAssertEqual(fixture.chatStore.loadSessions().first?.messages.first?.content, "current content")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertEqual(try String(contentsOf: unrelatedURL, encoding: .utf8), "keep")
    }

    func testLegacyOriginalIsRetainedIfDestinationCannotBeDecoded() throws {
        let fixture = try makeFixture()
        let legacySessions = fixture.legacyChat.appendingPathComponent("Sessions")
        try FileManager.default.createDirectory(at: legacySessions, withIntermediateDirectories: true)
        let now = Date()
        let session = ChatSession(
            id: UUID(), title: "Legacy", createdAt: now, updatedAt: now,
            messages: [ChatTranscriptMessage(role: .user, content: "recoverable content")]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyURL = legacySessions.appendingPathComponent("\(session.id.uuidString).json")
        try encoder.encode(session).write(to: legacyURL)
        let destination = fixture.chatStore.sessionURL(for: session.id)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid JSON".utf8).write(to: destination)

        XCTAssertTrue(fixture.chatStore.loadSessions().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        try FileManager.default.removeItem(at: destination)
        XCTAssertEqual(fixture.chatStore.loadSessions().map(\.id), [session.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testSharedAssetIsDeletedOnlyAfterLastOwnerIsRemoved() throws {
        let fixture = try makeFixture()
        let reference = try fixture.mediaStore.store(
            Data([1, 2, 3]),
            mimeType: "image/png",
            filename: "shared.png"
        )
        let url = try XCTUnwrap(fixture.mediaStore.fileURL(for: reference))
        fixture.mediaStore.updateOwner("chat:a", assets: [reference])
        fixture.mediaStore.updateOwner("image:b", assets: [reference])

        fixture.mediaStore.removeOwner("chat:a", orphanGracePeriod: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        fixture.mediaStore.removeOwner("image:b", orphanGracePeriod: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testImageGenerationSessionPersistsAssetReference() throws {
        let fixture = try makeFixture()
        let payload = Data(repeating: 0xEF, count: 1_024 * 1_024)
        let generated = GeneratedImage(
            imageData: payload,
            mimeType: "image/png",
            width: 512,
            height: 512,
            seed: 42,
            path: nil,
            revisedPrompt: nil,
            mediaStore: fixture.mediaStore
        )
        let now = Date()
        let session = ImageGenerationSession(
            id: UUID(),
            title: "Generated",
            createdAt: now,
            updatedAt: now,
            modelKind: .imageGeneration,
            modelID: "test/model",
            draftSettings: ImageRequestSettings(),
            activeReference: nil,
            turns: [ImageGenerationTurn(
                id: UUID(),
                prompt: "a cat",
                referenceImages: [],
                modelID: "test/model",
                settings: ImageRequestSettings(),
                createdAt: now,
                outputs: [generated],
                status: .completed,
                errorMessage: nil
            )]
        )

        fixture.imageStore.saveSession(session)

        let json = try String(contentsOf: fixture.imageStore.sessionURL(for: session.id), encoding: .utf8)
        XCTAssertFalse(json.contains("imageData"))
        XCTAssertLessThan(json.utf8.count, 12_000)
        XCTAssertEqual(fixture.imageStore.loadSessions().first?.summary.resultCount, 1)
        let outputAsset = try XCTUnwrap(
            fixture.imageStore.loadSession(id: session.id)?.turns[0].outputs[0].asset
        )
        XCTAssertEqual(fixture.mediaStore.data(for: outputAsset), payload)
    }

    private func makeFixture() throws -> (
        root: URL,
        legacyChat: URL,
        mediaStore: MediaAssetStore,
        chatStore: ChatSessionStore,
        imageStore: ImageGenerationSessionStore
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativMediaTests-\(UUID().uuidString)", isDirectory: true)
        let legacyChat = root.appendingPathComponent("LegacyChat", isDirectory: true)
        let mediaStore = MediaAssetStore(rootDirectory: root.appendingPathComponent("Media", isDirectory: true))
        let chatStore = ChatSessionStore(
            chatDirectory: root.appendingPathComponent("Chat", isDirectory: true),
            legacyChatDirectory: legacyChat,
            mediaStore: mediaStore
        )
        let imageStore = ImageGenerationSessionStore(
            imageDirectory: root.appendingPathComponent("Images", isDirectory: true),
            mediaStore: mediaStore
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, legacyChat, mediaStore, chatStore, imageStore)
    }
}

@MainActor
final class ChatSessionSynchronizationTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let root: URL
        let store: ChatSessionStore
        let hub = PersistedDataChangeHub()
    }

    private func fixture(_ sessions: [ChatSession]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ChatSessionStore(
            chatDirectory: root.appendingPathComponent("Chat"),
            mediaStore: MediaAssetStore(rootDirectory: root.appendingPathComponent("Media"))
        )
        for session in sessions { XCTAssertTrue(store.saveSession(session)) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root, store: store)
    }

    private func session(_ title: String, age: TimeInterval = 0) -> ChatSession {
        let date = Date(timeIntervalSince1970: 1_700_000_000 + age)
        return ChatSession(id: UUID(), title: title, customTitle: title,
                           createdAt: date, updatedAt: date,
                           messages: [ChatTranscriptMessage(role: .user, content: title, createdAt: date)])
    }

    private func subject(_ fixture: Fixture, hub: PersistedDataChangeHub? = nil,
                         windowID: UUID = UUID(),
                         activity: InferenceActivityCoordinator = .init(),
                         search: ChatSearchLibrary = .init()) -> ChatViewModel {
        ChatViewModel(windowID: windowID, persistedDataChanges: hub ?? fixture.hub,
                      inferenceActivity: activity,
                      projectStore: ChatProjectStore(storageURL: fixture.root.appendingPathComponent("Projects.json")),
                      sessionDirectory: fixture.root.appendingPathComponent("Chat"),
                      searchLibrary: search)
    }

    private func loaded(_ subjects: ChatViewModel...) async throws {
        for _ in 0..<1_000 {
            if subjects.allSatisfy({ !$0.isLoadingSessions }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Conversation bootstrap did not finish")
        throw CancellationError()
    }

    private func notify(_ id: UUID, in fixture: Fixture) {
        fixture.hub.send(.chatSession(id), originWindowID: UUID())
    }

    func testNotificationUpdatesOnlyTheChangedConversation() async throws {
        let selected = session("Selected", age: 2)
        var changed = session("Before", age: 1)
        let unrelated = session("Unrelated")
        let fixture = try fixture([selected, changed, unrelated])
        let receiver = subject(fixture)
        try await loaded(receiver)
        // An unreadable unrelated file must not remove an already loaded conversation.
        try Data("invalid JSON".utf8).write(to: fixture.store.sessionURL(for: unrelated.id))
        changed.customTitle = "After"
        changed.messages[0].content = "Updated content"
        XCTAssertTrue(fixture.store.saveSession(changed))

        notify(changed.id, in: fixture)

        XCTAssertEqual(receiver.sessions.count, 3)
        XCTAssertEqual(receiver.sessions.first { $0.id == changed.id }?.title, "After")
        XCTAssertTrue(receiver.conversationText(for: changed.id)?.contains("Updated content") == true)
        XCTAssertTrue(receiver.conversationText(for: unrelated.id)?.contains("Unrelated") == true)
        XCTAssertEqual(receiver.currentSessionID, selected.id)
        XCTAssertEqual(receiver.messages, selected.messages)
    }

    func testPublicReloadStillReadsTheEntireLibrary() async throws {
        let current = session("Current", age: 2)
        var other = session("Before")
        let fixture = try fixture([current, other])
        let receiver = subject(fixture)
        try await loaded(receiver)
        other.customTitle = "After"
        XCTAssertTrue(fixture.store.saveSession(other))
        let added = session("Added", age: 3)
        XCTAssertTrue(fixture.store.saveSession(added))

        receiver.reloadPersistedSessions()

        XCTAssertEqual(receiver.sessions, fixture.store.loadSessions().map(\.summary).sorted(by: ChatSessionSummary.recencySort))
        XCTAssertEqual(receiver.currentSessionID, current.id)
    }

    func testNewConversationIsInsertedOnceAndSortedByRecency() async throws {
        let original = session("Original")
        let fixture = try fixture([original])
        let receiver = subject(fixture)
        try await loaded(receiver)
        let added = session("New", age: 10)
        XCTAssertTrue(fixture.store.saveSession(added))
        notify(added.id, in: fixture)
        notify(added.id, in: fixture)
        XCTAssertEqual(receiver.sessions.map(\.id), [added.id, original.id])
        XCTAssertEqual(receiver.currentSessionID, original.id)
    }

    func testCurrentConversationUpdatePreservesComposer() async throws {
        var current = session("Current")
        let fixture = try fixture([current])
        let receiver = subject(fixture)
        try await loaded(receiver)
        receiver.draft = "Unsent draft"
        let attachment = ChatImageAttachment(filename: "draft.png", mimeType: "image/png", base64Data: "AA==")
        receiver.stageAttachment(attachment)
        current.messages.append(ChatTranscriptMessage(role: .assistant, content: "New response", createdAt: current.createdAt))
        XCTAssertTrue(fixture.store.saveSession(current))
        notify(current.id, in: fixture)
        XCTAssertEqual(receiver.messages, current.messages)
        XCTAssertEqual(receiver.draft, "Unsent draft")
        XCTAssertEqual(receiver.pendingImageAttachments, [attachment])
    }

    func testDeletingBackgroundConversationPreservesCurrentAndDraft() async throws {
        let current = session("Current", age: 2)
        let background = session("Background")
        let fixture = try fixture([current, background])
        let receiver = subject(fixture)
        try await loaded(receiver)
        receiver.draft = "Keep this"
        fixture.store.deleteSession(id: background.id)
        notify(background.id, in: fixture)
        XCTAssertEqual(receiver.sessions.map(\.id), [current.id])
        XCTAssertEqual(receiver.currentSessionID, current.id)
        XCTAssertEqual(receiver.draft, "Keep this")
    }

    func testDeletingCurrentConversationSelectsNewestRemainingAndClearsComposer() async throws {
        let current = session("Current", age: 3)
        let next = session("Next", age: 2)
        let oldest = session("Oldest")
        let fixture = try fixture([current, next, oldest])
        let receiver = subject(fixture)
        try await loaded(receiver)
        receiver.draft = "Discard this"
        receiver.stageAttachment(ChatImageAttachment(filename: "draft.png", mimeType: "image/png", base64Data: "AA=="))
        fixture.store.deleteSession(id: current.id)
        notify(current.id, in: fixture)
        XCTAssertEqual(receiver.currentSessionID, next.id)
        XCTAssertEqual(receiver.messages, next.messages)
        XCTAssertTrue(receiver.draft.isEmpty)
        XCTAssertTrue(receiver.pendingImageAttachments.isEmpty)
        XCTAssertEqual(receiver.sessions.map(\.id), [next.id, oldest.id])
    }

    func testDeletingLastConversationCreatesOneReplacementAcrossWindows() async throws {
        let original = session("Only")
        let fixture = try fixture([original])
        let first = subject(fixture)
        let second = subject(fixture)
        try await loaded(first, second)
        fixture.store.deleteSession(id: original.id)
        notify(original.id, in: fixture)
        XCTAssertEqual(first.sessions.count, 1)
        XCTAssertEqual(first.sessions.map(\.id), second.sessions.map(\.id))
        XCTAssertEqual(first.sessions.map(\.title), second.sessions.map(\.title))
        XCTAssertEqual(first.sessions.map(\.messageCount), [0])
        XCTAssertEqual(second.sessions.map(\.messageCount), [0])
        XCTAssertEqual(first.currentSessionID, second.currentSessionID)
        XCTAssertNotEqual(first.currentSessionID, original.id)
        XCTAssertTrue(first.messages.isEmpty)
        XCTAssertTrue(second.messages.isEmpty)
    }

    func testMissingAndMalformedChangedFilesMatchFullReload() async throws {
        let current = session("Current", age: 3)
        let corrupt = session("Corrupt", age: 2)
        let removed = session("Removed")
        let fixture = try fixture([current, corrupt, removed])
        let receiver = subject(fixture)
        let reference = subject(fixture, hub: .init())
        try await loaded(receiver, reference)
        try Data("broken".utf8).write(to: fixture.store.sessionURL(for: corrupt.id))
        fixture.store.deleteSession(id: removed.id)
        notify(corrupt.id, in: fixture)
        notify(removed.id, in: fixture)
        notify(UUID(), in: fixture)
        reference.reloadPersistedSessions()
        XCTAssertEqual(receiver.sessions, reference.sessions)
        XCTAssertEqual(receiver.messages, reference.messages)
        XCTAssertEqual(receiver.currentSessionID, reference.currentSessionID)
    }

    func testOwnAndImageNotificationsDoNotReloadChats() async throws {
        var original = session("Before")
        let fixture = try fixture([original])
        let windowID = UUID()
        let receiver = subject(fixture, windowID: windowID)
        try await loaded(receiver)
        original.customTitle = "After"
        XCTAssertTrue(fixture.store.saveSession(original))
        fixture.hub.send(.chatSession(original.id), originWindowID: windowID)
        fixture.hub.send(.imageGenerationSession(original.id), originWindowID: UUID())
        XCTAssertEqual(receiver.sessions.first?.title, "Before")
        notify(original.id, in: fixture)
        XCTAssertEqual(receiver.sessions.first?.title, "After")
    }

    func testNotificationsDuringBootstrapReconcileMultipleIDs() async throws {
        var first = session("First")
        let removed = session("Removed", age: 1)
        let current = session("Current", age: 3)
        let fixture = try fixture([first, removed, current])
        let receiver = subject(fixture)
        XCTAssertTrue(receiver.isLoadingSessions)
        first.customTitle = "Updated during startup"
        XCTAssertTrue(fixture.store.saveSession(first))
        fixture.store.deleteSession(id: removed.id)
        let added = session("Added", age: 2)
        XCTAssertTrue(fixture.store.saveSession(added))
        for id in [first.id, removed.id, added.id, first.id] { notify(id, in: fixture) }
        try await loaded(receiver)
        XCTAssertEqual(receiver.sessions, fixture.store.loadSessions().map(\.summary).sorted(by: ChatSessionSummary.recencySort))
        XCTAssertEqual(receiver.currentSessionID, current.id)
    }

    func testMetadataAndBulkChangesMatchFullReloadAcrossFourWindows() async throws {
        let chats = (0..<5).map { session("Chat \($0)", age: Double($0)) }
        let fixture = try fixture(chats)
        let sender = subject(fixture)
        let receivers = (0..<3).map { _ in subject(fixture) }
        let reference = subject(fixture, hub: .init())
        try await loaded(sender, receivers[0], receivers[1], receivers[2], reference)
        let folderID = UUID()
        let operations: [() -> Void] = [
            { sender.renameSession(chats[0].id, to: "Renamed") },
            { sender.setPinned(chats[1].id, pinned: true) },
            { sender.moveSession(chats[2].id, toFolder: folderID) },
            { sender.applyPinnedOrder([chats[2].id, chats[1].id]) },
            { sender.applySessionOrder(chats.reversed().map(\.id)) },
            { sender.deleteFolder(folderID) },
        ]
        for operation in operations {
            operation()
            reference.reloadPersistedSessions()
            for receiver in receivers {
                XCTAssertEqual(receiver.sessions, reference.sessions)
                XCTAssertEqual(receiver.currentSessionID, reference.currentSessionID)
                XCTAssertEqual(receiver.messages, reference.messages)
                for chat in chats {
                    XCTAssertEqual(receiver.conversationText(for: chat.id), reference.conversationText(for: chat.id))
                }
            }
        }
    }

    func testSearchTracksChangedAddedAndDeletedConversations() async throws {
        var changed = session("Original")
        let current = session("Current", age: 2)
        let fixture = try fixture([current, changed])
        let receiver = subject(fixture)
        try await loaded(receiver)
        try await receiver.searchLibrary.ready()
        changed.messages[0].content = "zebrafish"
        XCTAssertTrue(fixture.store.saveSession(changed))
        notify(changed.id, in: fixture)
        try await receiver.searchLibrary.ready()
        try await receiver.searchLibrary.ready()
        let result = try await receiver.searchLibrary.worker.search("zebrafish")
        XCTAssertEqual(result.messages.map(\.sessionID), [changed.id])
        let old = try await receiver.searchLibrary.worker.search("Original")
        XCTAssertTrue(old.messages.isEmpty)
        fixture.store.deleteSession(id: changed.id)
        notify(changed.id, in: fixture)
        try await receiver.searchLibrary.ready()
        let deleted = try await receiver.searchLibrary.worker.search("zebrafish")
        XCTAssertTrue(deleted.messages.isEmpty)
        let added = session("platypus", age: 3)
        XCTAssertTrue(fixture.store.saveSession(added))
        notify(added.id, in: fixture)
        try await receiver.searchLibrary.ready()
        let inserted = try await receiver.searchLibrary.worker.search("platypus")
        XCTAssertEqual(inserted.messages.map(\.sessionID), [added.id])
    }

    func testUnrelatedChangePreservesPromptEditingAndRestoresOriginalDraft() async throws {
        let current = session("Current", age: 2)
        var other = session("Other")
        let fixture = try fixture([current, other])
        let receiver = subject(fixture)
        try await loaded(receiver)
        receiver.draft = "Original draft"
        receiver.beginEditingUserMessage(current.messages[0].id)
        receiver.draft = "Edited prompt"
        other.customTitle = "Renamed elsewhere"
        XCTAssertTrue(fixture.store.saveSession(other))
        notify(other.id, in: fixture)
        XCTAssertEqual(receiver.promptEditContext?.messageID, current.messages[0].id)
        XCTAssertEqual(receiver.draft, "Edited prompt")
        receiver.cancelPromptEditing()
        XCTAssertEqual(receiver.draft, "Original draft")
    }

    func testCurrentDeletionDiscardsPromptEditing() async throws {
        let current = session("Current", age: 2)
        let other = session("Other")
        let fixture = try fixture([current, other])
        let receiver = subject(fixture)
        try await loaded(receiver)
        receiver.beginEditingUserMessage(current.messages[0].id)
        receiver.draft = "Edited prompt"
        fixture.store.deleteSession(id: current.id)
        notify(current.id, in: fixture)
        XCTAssertNil(receiver.promptEditContext)
        XCTAssertTrue(receiver.draft.isEmpty)
        XCTAssertEqual(receiver.currentSessionID, other.id)
    }

    func testSharedSearchAndRemoteInferenceOwnershipRemainIntact() async throws {
        let current = session("Current", age: 2)
        let other = session("Other")
        let fixture = try fixture([current, other])
        let activity = InferenceActivityCoordinator()
        let search = ChatSearchLibrary()
        let senderID = UUID()
        let sender = subject(fixture, windowID: senderID, activity: activity, search: search)
        let receiver = subject(fixture, activity: activity, search: search)
        try await loaded(sender, receiver)
        try await search.ready()
        let operationID = UUID()
        XCTAssertTrue(activity.begin(resource: .chat(current.id), windowID: senderID, operationID: operationID))
        defer { activity.end(resource: .chat(current.id), operationID: operationID) }
        XCTAssertFalse(receiver.canModifySession(current.id))
        sender.renameSession(current.id, to: "Owned elsewhere")
        sender.renameSession(other.id, to: "Background update")
        XCTAssertEqual(receiver.sessions, sender.sessions)
        XCTAssertFalse(receiver.canModifySession(current.id))
        XCTAssertEqual(receiver.currentSessionID, current.id)
        try await search.ready()
        XCTAssertNil(search.error)
    }

    func testRepeatedMixedNotificationsMatchFullReload() async throws {
        let current = session("Current", age: 10_000)
        var background = (0..<20).map { session("Background \($0)", age: Double($0)) }
        let fixture = try fixture([current] + background)
        let receiver = subject(fixture)
        let reference = subject(fixture, hub: .init())
        try await loaded(receiver, reference)
        for step in 0..<60 {
            let id: UUID
            switch step % 3 {
            case 0:
                let added = session("Added \(step)", age: Double(step + 100))
                background.append(added)
                XCTAssertTrue(fixture.store.saveSession(added))
                id = added.id
            case 1:
                let index = step % background.count
                background[index].messages.append(ChatTranscriptMessage(role: .assistant, content: "Reply \(step)"))
                background[index].customTitle = "Updated \(step)"
                background[index].pinned = step.isMultiple(of: 2)
                background[index].updatedAt = Date(timeIntervalSince1970: 1_700_001_000 + Double(step))
                XCTAssertTrue(fixture.store.saveSession(background[index]))
                id = background[index].id
            default:
                id = background.removeFirst().id
                fixture.store.deleteSession(id: id)
            }
            notify(id, in: fixture)
            reference.reloadPersistedSessions()
            XCTAssertEqual(receiver.sessions, reference.sessions, "Step \(step)")
            XCTAssertEqual(receiver.currentSessionID, current.id)
            XCTAssertEqual(receiver.messages, reference.messages)
            for chat in background {
                XCTAssertEqual(receiver.conversationText(for: chat.id), reference.conversationText(for: chat.id))
            }
        }
    }

    func testTargetedLoadStillMigratesEmbeddedAttachments() async throws {
        var current = session("Current")
        let fixture = try fixture([current])
        let receiver = subject(fixture)
        try await loaded(receiver)
        let payload = Data([1, 2, 3, 4])
        current.messages[0].imageAttachments = [ChatImageAttachment(
            filename: "legacy.png", mimeType: "image/png", base64Data: payload.base64EncodedString())]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(current).write(to: fixture.store.sessionURL(for: current.id))
        notify(current.id, in: fixture)
        let attachment = try XCTUnwrap(receiver.messages.first?.imageAttachments.first)
        let asset = try XCTUnwrap(attachment.asset)
        XCTAssertEqual(MediaAssetStore.shared.data(for: asset), payload)
        let json = try String(contentsOf: fixture.store.sessionURL(for: current.id), encoding: .utf8)
        XCTAssertFalse(json.contains("base64Data"))
        XCTAssertTrue(json.contains("relativePath"))
    }
}
