import XCTest

final class ArtifactCatalogTests: XCTestCase {
    func testLegacyChatGenerationKeepsOriginAndChatOwnership() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let attachment = try fixture.attachment(filename: "generated.png", mimeType: "image/png")
        let message = ChatTranscriptMessage(
            role: .tool, content: "{}", imageAttachments: [attachment],
            toolName: "generate_image", toolArguments: #"{"prompt":"A red fox"}"#
        )
        let session = fixture.chat(messages: [message])
        XCTAssertTrue(fixture.chats.saveSession(session))
        let loaded = try XCTUnwrap(fixture.chats.loadSession(id: session.id))
        XCTAssertEqual(loaded.messages[0].imageAttachments[0].generation?.prompt, "A red fox")
        let artifact = try XCTUnwrap(ArtifactCatalog.artifacts(chats: [loaded], images: []).first)
        XCTAssertEqual(artifact.source, .generated)
        XCTAssertEqual(artifact.workspace, .chat)
        XCTAssertEqual(artifact.sessionID, session.id)
        XCTAssertEqual(artifact.messageID, message.id)
        XCTAssertEqual(artifact.prompt, "A red fox")
    }

    func testReferenceUploadsAndOutputsShareOneCatalogWithoutDuplicates() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let upload = try fixture.attachment(filename: "reference.png", mimeType: "image/png")
        let output = fixture.output()
        let turn = fixture.turn(references: [upload], outputs: [output])
        let session = fixture.image(turns: [turn], active: output.attachment)
        XCTAssertTrue(fixture.images.saveSession(session))
        let artifacts = ArtifactCatalog.artifacts(chats: [], images: fixture.images.loadSessions())
        XCTAssertEqual(artifacts.count, 2)
        let uploaded = try XCTUnwrap(artifacts.first { $0.id == upload.assetID })
        XCTAssertEqual(uploaded.source, .uploaded)
        XCTAssertEqual(uploaded.workspace, .imageGeneration)
        let generated = try XCTUnwrap(artifacts.first { $0.id == output.id })
        XCTAssertEqual(generated.source, .generated)
        XCTAssertEqual(generated.locations.count, 2)
        XCTAssertEqual(generated.messageID, turn.id)
        XCTAssertEqual(generated.generation?.modelID, "test/image-model")
        XCTAssertEqual(generated.generation?.prompt, "A fox")
    }

    func testActiveReferenceWithoutTurnsIsIncluded() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let upload = try fixture.attachment(filename: "reference.png", mimeType: "image/png")
        let session = fixture.image(turns: [], active: upload)
        let artifacts = ArtifactCatalog.artifacts(chats: [], images: [session])
        XCTAssertEqual(artifacts.map(\.id), [upload.assetID])
        XCTAssertNil(artifacts.first?.locations.first?.messageID)
    }

    @MainActor
    func testReusePreservesFileIdentityMetadataAndFavoritesAfterReload() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let output = fixture.output()
        let session = fixture.image(turns: [fixture.turn(references: [], outputs: [output])])
        let artifact = try XCTUnwrap(ArtifactCatalog.artifacts(chats: [], images: [session]).first)
        try fixture.writeIndex([artifact])
        let store = ArtifactStore(storage: fixture.storage, refreshesAutomatically: false, mediaStore: fixture.media)
        store.toggleFavorite(artifact)
        store.rename(artifact, to: "Fox")
        let attachment = try XCTUnwrap(store.chatAttachment(for: artifact))
        XCTAssertEqual(attachment.id, artifact.id)
        XCTAssertEqual(attachment.asset, output.asset)
        XCTAssertEqual(attachment.generation, artifact.generation)
        XCTAssertEqual(store.fileURL(for: artifact), fixture.media.fileURL(for: try XCTUnwrap(output.asset)))
        let chat = fixture.chat(messages: [ChatTranscriptMessage(role: .user, content: "reuse", imageAttachments: [attachment])])
        XCTAssertTrue(fixture.chats.saveSession(chat))
        XCTAssertTrue(fixture.images.saveSession(session))
        let rebuilt = ArtifactCatalog.artifacts(chats: fixture.chats.loadSessions(), images: fixture.images.loadSessions())
        XCTAssertEqual(rebuilt.count, 1)
        XCTAssertEqual(rebuilt.first?.locations.count, 2)
        XCTAssertEqual(rebuilt.first?.source, .generated)
        XCTAssertEqual(rebuilt.first?.workspace, .imageGeneration)
        try fixture.writeIndex(rebuilt)
        let reloaded = ArtifactStore(storage: fixture.storage, refreshesAutomatically: false, mediaStore: fixture.media)
        XCTAssertTrue(reloaded.isFavorite(artifact))
        XCTAssertEqual(reloaded.displayName(for: artifact), "Fox")
        XCTAssertEqual(reloaded.artifacts.first?.asset, output.asset)
    }

    func testPDFReferencesUseAssetIdentityEvenWhenAttachmentIDsDiffer() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let attachment = try fixture.attachment(filename: "report.pdf", mimeType: "application/pdf")
        let reused = ChatImageAttachment(id: UUID(), filename: "report.pdf", mimeType: "application/pdf", asset: try XCTUnwrap(attachment.asset))
        let chats = [attachment, reused].map {
            fixture.chat(messages: [ChatTranscriptMessage(role: .user, content: "read", imageAttachments: [$0])])
        }
        let artifacts = ArtifactCatalog.artifacts(chats: chats, images: [])
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts.first?.kind, .document)
        XCTAssertEqual(artifacts.first?.locations.count, 2)
        XCTAssertEqual(artifacts.first?.id, attachment.assetID)
    }

    func testUnlinkingSharedAssetPreservesOtherFilesAndOwners() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let output = fixture.output()
        let other = try fixture.attachment(filename: "keep.pdf", mimeType: "application/pdf")
        var chat = fixture.chat(messages: [ChatTranscriptMessage(role: .user, content: "reuse", imageAttachments: [output.attachment, other])])
        var image = fixture.image(turns: [fixture.turn(references: [output.attachment], outputs: [output])], active: output.attachment)
        XCTAssertTrue(fixture.chats.saveSession(chat))
        XCTAssertTrue(fixture.images.saveSession(image))
        chat.removeArtifact(output.id)
        XCTAssertTrue(fixture.chats.saveSession(chat))
        fixture.media.removeOwner("chat:\(chat.id.uuidString)", orphanGracePeriod: 0)
        XCTAssertNotNil(fixture.media.fileURL(for: try XCTUnwrap(output.asset)))
        image.removeArtifact(output.id)
        XCTAssertNil(image.activeReference)
        XCTAssertTrue(image.turns[0].referenceImages.isEmpty)
        XCTAssertTrue(image.turns[0].outputs.isEmpty)
        XCTAssertEqual(chat.messages[0].imageAttachments.map(\.id), [other.id])
        XCTAssertEqual(ArtifactCatalog.artifacts(chats: [chat], images: [image]).map(\.id), [other.id])
    }

    @MainActor
    func testGalleryDeletionDoesNotUnlinkSharedMediaBytes() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let output = fixture.output()
        let artifact = try XCTUnwrap(ArtifactCatalog.artifacts(chats: [], images: [fixture.image(turns: [fixture.turn(references: [], outputs: [output])])]).first)
        try fixture.writeIndex([artifact])
        let store = ArtifactStore(storage: fixture.storage, refreshesAutomatically: false, mediaStore: fixture.media)
        XCTAssertTrue(store.delete(artifact))
        XCTAssertTrue(store.artifacts.isEmpty)
        XCTAssertNotNil(fixture.media.fileURL(for: try XCTUnwrap(output.asset)))
    }

    func testDeletionPreflightsEveryOwnerBeforeChangingAnyHistory() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let output = fixture.output()
        let chat = fixture.chat(messages: [ChatTranscriptMessage(role: .user, content: "reuse", imageAttachments: [output.attachment])])
        let image = fixture.image(turns: [fixture.turn(references: [output.attachment], outputs: [output])])
        let artifact = try XCTUnwrap(ArtifactCatalog.artifacts(chats: [chat], images: [image]).first)
        var removed: [UUID] = []
        XCTAssertFalse(ArtifactDeletion.removeReferences(
            to: artifact,
            isActive: { workspace, _ in workspace == .imageGeneration },
            remove: { _, id in removed.append(id); return true }
        ))
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(ArtifactDeletion.removeReferences(
            to: artifact, isActive: { _, _ in false },
            remove: { _, id in removed.append(id); return true }
        ))
        XCTAssertEqual(removed, [chat.id, image.id])
    }

    func testDeletionReportsPersistenceFailure() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let output = fixture.output()
        let artifact = try XCTUnwrap(ArtifactCatalog.artifacts(chats: [], images: [fixture.image(turns: [fixture.turn(references: [], outputs: [output])])]).first)
        XCTAssertFalse(ArtifactDeletion.removeReferences(
            to: artifact, isActive: { _, _ in false }, remove: { _, _ in false }
        ))
    }

    func testLegacyIndexDecodesForRebuild() throws {
        let id = UUID()
        let data = Data("""
        [{"id":"\(id)","kind":"image","source":"generated","sessionID":"\(UUID())","messageID":"\(UUID())","filename":"old.png","mimeType":"image/png","relativePath":"image/old.png","byteSize":1,"createdAt":"2026-09-01T00:00:00Z","sessionTitle":"Old"}]
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let artifact = try XCTUnwrap(decoder.decode([Artifact].self, from: data).first)
        XCTAssertEqual(artifact.id, id)
        XCTAssertNil(artifact.asset)
        XCTAssertEqual(artifact.workspace, .imageGeneration)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var media: MediaAssetStore { MediaAssetStore(rootDirectory: root.appendingPathComponent("Media")) }
        var chats: ChatSessionStore { ChatSessionStore(chatDirectory: root.appendingPathComponent("Chat"), mediaStore: media) }
        var images: ImageGenerationSessionStore { ImageGenerationSessionStore(imageDirectory: root.appendingPathComponent("Images"), mediaStore: media) }
        var storage: ArtifactStore.StorageLocations {
            .init(indexURL: root.appendingPathComponent("index.json"), cacheDirectory: root.appendingPathComponent("Cache"), favoritesURL: root.appendingPathComponent("favorites.json"), displayNamesURL: root.appendingPathComponent("names.json"))
        }

        func attachment(filename: String, mimeType: String) throws -> ChatImageAttachment {
            let id = UUID()
            let asset = try media.store(Data([1, 2, 3]), id: id, mimeType: mimeType, filename: filename)
            return ChatImageAttachment(id: id, filename: filename, mimeType: mimeType, asset: asset)
        }

        func output() -> GeneratedImage {
            GeneratedImage(imageData: Data([4, 5, 6]), mimeType: "image/png", width: 64, height: 64, seed: 42, path: nil, revisedPrompt: nil, mediaStore: media)
        }

        func chat(messages: [ChatTranscriptMessage]) -> ChatSession {
            ChatSession(id: UUID(), title: "Chat", createdAt: .now, updatedAt: .now, messages: messages)
        }

        func turn(references: [ChatImageAttachment], outputs: [GeneratedImage]) -> ImageGenerationTurn {
            ImageGenerationTurn(id: UUID(), prompt: "A fox", referenceImages: references, modelID: "test/image-model", settings: ImageRequestSettings(), createdAt: .now, outputs: outputs, status: .completed)
        }

        func image(turns: [ImageGenerationTurn], active: ChatImageAttachment? = nil) -> ImageGenerationSession {
            ImageGenerationSession(id: UUID(), title: "Images", createdAt: .now, updatedAt: .now, modelKind: .imageGeneration, modelID: "test/image-model", draftSettings: ImageRequestSettings(), activeReference: active, turns: turns)
        }

        func writeIndex(_ artifacts: [Artifact]) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(artifacts).write(to: storage.indexURL)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
