import XCTest

@MainActor
final class ArtifactTrashTests: XCTestCase {
    func testDeleteAndRestoreAfterRestartPreserveBytesIdentityAndEdits() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let trash = fixture.trash()
        try trash.delete(fixture.artifact)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.originalURL.path))
        XCTAssertTrue(try XCTUnwrap(fixture.chats.loadSession(id: fixture.chat.id)).messages[0].imageAttachments.isEmpty)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(trash.records.first?.trashURL)), fixture.bytes)
        var edited = try XCTUnwrap(fixture.chats.loadSession(id: fixture.chat.id))
        edited.messages[0].content = "Edited after deletion"
        XCTAssertTrue(fixture.chats.saveSession(edited))

        let restarted = fixture.trash()
        try restarted.restore(XCTUnwrap(restarted.records.first))
        XCTAssertTrue(restarted.records.isEmpty)
        XCTAssertTrue(fixture.trash().records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.originalURL), fixture.bytes)
        let restored = try XCTUnwrap(fixture.chats.loadSession(id: fixture.chat.id))
        XCTAssertEqual(restored.messages[0].content, "Edited after deletion")
        XCTAssertEqual(restored.messages[0].imageAttachments, fixture.chat.messages[0].imageAttachments)
        XCTAssertEqual(ArtifactCatalog.artifacts(chats: [restored], images: []).first?.id, fixture.artifact.id)
    }

    func testFailedTrashMoveLeavesFileAndReferencesIntact() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let trash = fixture.trash(trashFile: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try trash.delete(fixture.artifact))
        XCTAssertEqual(try Data(contentsOf: fixture.originalURL), fixture.bytes)
        XCTAssertEqual(fixture.chats.loadSession(id: fixture.chat.id)?.messages, fixture.chat.messages)
        XCTAssertTrue(trash.records.isEmpty)
    }

    func testActiveSessionBlocksDeletionBeforeAnyChanges() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let trash = fixture.trash(isActive: { _, _ in true })
        XCTAssertThrowsError(try trash.delete(fixture.artifact))
        XCTAssertTrue(trash.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.originalURL), fixture.bytes)
        XCTAssertEqual(fixture.chats.loadSession(id: fixture.chat.id)?.messages, fixture.chat.messages)
    }

    func testMissingOriginalChatRestoresIntoRecoverableGalleryChat() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let trash = fixture.trash()
        try trash.delete(fixture.artifact)
        fixture.chats.deleteSession(id: fixture.chat.id)
        let record = try XCTUnwrap(trash.records.first)
        try trash.restore(record)
        let recovered = try XCTUnwrap(fixture.chats.loadSession(id: record.recoveredChatID))
        XCTAssertEqual(recovered.displayTitle, "Recovered artifacts")
        XCTAssertEqual(ArtifactCatalog.artifacts(chats: [recovered], images: []).first?.id, fixture.artifact.id)
        XCTAssertNil(fixture.chats.loadSession(id: fixture.chat.id))
    }

    func testDestinationConflictAndEmptyBinKeepRecordWithoutOverwriting() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let trash = fixture.trash()
        try trash.delete(fixture.artifact)
        let record = try XCTUnwrap(trash.records.first)
        let replacement = Data("Different content".utf8)
        try replacement.write(to: fixture.originalURL)
        XCTAssertThrowsError(try trash.restore(record))
        XCTAssertEqual(try Data(contentsOf: fixture.originalURL), replacement)
        try FileManager.default.removeItem(at: fixture.originalURL)
        try FileManager.default.removeItem(at: XCTUnwrap(record.trashURL))
        XCTAssertThrowsError(try trash.restore(record))
        XCTAssertEqual(trash.records.count, 1)
        XCTAssertTrue(try XCTUnwrap(fixture.chats.loadSession(id: fixture.chat.id)).messages[0].imageAttachments.isEmpty)
    }

    func testUnwritableRecoveryDirectoryDoesNotMoveFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.root.appendingPathComponent("Recovery"))
        let trash = fixture.trash()
        XCTAssertThrowsError(try trash.delete(fixture.artifact))
        XCTAssertEqual(try Data(contentsOf: fixture.originalURL), fixture.bytes)
        XCTAssertEqual(fixture.chats.loadSession(id: fixture.chat.id)?.messages, fixture.chat.messages)
    }

    func testFailedHistorySaveRollsFileBackAndRetainsRecoveryUntilRetry() throws {
        let manager = FailingFileManager()
        let fixture = try Fixture(fileManager: manager)
        defer { fixture.remove() }
        let trash = fixture.trash(trashFile: { url in
            let destination = fixture.root.appendingPathComponent("Trashed.png")
            try FileManager.default.moveItem(at: url, to: destination)
            manager.refusesWrites = true
            return destination
        })
        XCTAssertThrowsError(try trash.delete(fixture.artifact))
        XCTAssertEqual(try Data(contentsOf: fixture.originalURL), fixture.bytes)
        XCTAssertEqual(trash.records.count, 1)
        XCTAssertEqual(fixture.chats.loadSession(id: fixture.chat.id)?.messages, fixture.chat.messages)
        manager.refusesWrites = false
        try trash.restore(XCTUnwrap(trash.records.first))
        XCTAssertTrue(trash.records.isEmpty)
    }

    private final class FailingFileManager: FileManager, @unchecked Sendable {
        var refusesWrites = false

        override func createDirectory(at url: URL, withIntermediateDirectories: Bool,
                                      attributes: [FileAttributeKey: Any]? = nil) throws {
            if refusesWrites { throw CocoaError(.fileWriteNoPermission) }
            try super.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories, attributes: attributes)
        }
    }

    @MainActor
    struct Fixture {
        let root: URL
        let media: MediaAssetStore
        let chats: ChatSessionStore
        let images: ImageGenerationSessionStore
        let chat: ChatSession
        let artifact: Artifact
        let originalURL: URL
        let bytes = Data("Image bytes".utf8)

        init(fileManager: FileManager = .default) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            media = MediaAssetStore(rootDirectory: root.appendingPathComponent("Media"))
            chats = ChatSessionStore(chatDirectory: root.appendingPathComponent("Chat"), mediaStore: media, fileManager: fileManager)
            images = ImageGenerationSessionStore(imageDirectory: root.appendingPathComponent("Images"), mediaStore: media)
            let asset = try media.store(bytes, mimeType: "image/png", filename: "fox.png")
            let attachment = ChatImageAttachment(id: UUID(), filename: "fox.png", mimeType: "image/png", asset: asset, origin: .uploaded)
            chat = ChatSession(id: UUID(), title: "Chat", createdAt: Date(timeIntervalSince1970: 1_000),
                               updatedAt: Date(timeIntervalSince1970: 1_000),
                               messages: [ChatTranscriptMessage(role: .user, content: "Original",
                                                                createdAt: Date(timeIntervalSince1970: 1_000), imageAttachments: [attachment])])
            XCTAssertTrue(chats.saveSession(chat))
            artifact = try XCTUnwrap(ArtifactCatalog.artifacts(chats: [chat], images: []).first)
            originalURL = try XCTUnwrap(media.fileURL(for: asset))
        }

        func trash(isActive: @escaping (ArtifactUsage.Workspace, UUID) -> Bool = { _, _ in false },
                   trashFile: ((URL) throws -> URL)? = nil) -> ArtifactTrash {
            ArtifactTrash(directory: root.appendingPathComponent("Recovery"), media: media, chats: chats, images: images,
                          isActive: isActive, trashFile: trashFile ?? { url in
                let bin = root.appendingPathComponent("Bin")
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                let destination = bin.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            })
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
