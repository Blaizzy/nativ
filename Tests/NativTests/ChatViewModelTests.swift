import AppKit
import XCTest

@MainActor
final class ChatViewModelTests: XCTestCase {
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
            for: [ChatTranscriptMessage(role: .user, content: String(repeating: "a", count: 80))],
            createdAt: .now
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

    func testLegacyCacheMigrationIsIdempotentAndPreservesOriginal() throws {
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        let migratedJSON = try String(contentsOf: fixture.chatStore.sessionURL(for: session.id), encoding: .utf8)
        XCTAssertFalse(migratedJSON.contains("base64Data"))
        let migratedAsset = try XCTUnwrap(
            fixture.chatStore.loadSession(id: session.id)?.messages[0].imageAttachments[0].asset
        )
        XCTAssertEqual(fixture.mediaStore.data(for: migratedAsset), payload)
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
