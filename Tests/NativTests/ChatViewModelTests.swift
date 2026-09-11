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
