import AppKit
import XCTest

@MainActor
final class ArtifactTrashTests: XCTestCase {
    func testGalleryDeletionMovesToNativeBinThenWatcherRemovesRecoveryReferences() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let trash = ArtifactTrash(directory: fixture.root.appendingPathComponent("Recovery"),
                                  media: fixture.media, chats: fixture.chats, images: fixture.images)
        let store = ArtifactStore(
            storage: .init(indexURL: fixture.root.appendingPathComponent("index.json"), cacheDirectory: fixture.root,
                           favoritesURL: fixture.root.appendingPathComponent("favorites.json"),
                           displayNamesURL: fixture.root.appendingPathComponent("names.json")),
            refreshesAutomatically: false, rebuild: { _, _, _ in .init(fingerprint: nil, artifacts: []) },
            mediaStore: fixture.media, trash: trash
        )
        XCTAssertTrue(store.delete(fixture.artifact))
        let record = try XCTUnwrap(trash.records.first)
        let binURL = try XCTUnwrap(record.trashURL)
        defer { try? FileManager.default.removeItem(at: binURL) }
        let recordURL = fixture.root.appendingPathComponent("Recovery/\(record.id).json")
        XCTAssertEqual(try Data(contentsOf: binURL), fixture.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.originalURL.path))
        XCTAssertFalse(record.references.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path))
        let ownersURL = fixture.media.rootDirectory.appendingPathComponent("owners.json")
        let owners = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: ownersURL))
        XCTAssertNotNil(owners["trash:\(record.id)"])

        try FileManager.default.removeItem(at: binURL)
        for _ in 0..<200 where !trash.records.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertTrue(trash.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
        XCTAssertNil(try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: ownersURL))["trash:\(record.id)"])
        XCTAssertTrue(try XCTUnwrap(fixture.chats.loadSession(id: fixture.chat.id)).messages[0].imageAttachments.isEmpty)
        XCTAssertNil(trash.errorMessage)
        try await settle([store])
    }

    func testWatcherReconnectsAfterRestartAndFollowsRenames() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var trash: ArtifactTrash? = fixture.trash()
        try XCTUnwrap(trash).delete(fixture.artifact)
        let record = try XCTUnwrap(trash?.records.first)
        weak var released = trash
        trash = nil
        XCTAssertNil(released)
        let renamed = fixture.root.appendingPathComponent("Bin/Renamed.png")
        try FileManager.default.moveItem(at: XCTUnwrap(record.trashURL), to: renamed)
        let restarted = fixture.trash()
        let moved = fixture.root.appendingPathComponent("Bin/Moved.png")
        try FileManager.default.moveItem(at: renamed, to: moved)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(restarted.records.map(\.id), [record.id])
        XCTAssertEqual(try Data(contentsOf: moved), fixture.bytes)
        try FileManager.default.removeItem(at: moved)
        for _ in 0..<200 where !restarted.records.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(restarted.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Recovery/\(record.id).json").path))
    }

    func testDeletionWhileStoppedDoesNotPurgeOnLaunchOrActivation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var trash: ArtifactTrash? = fixture.trash()
        try XCTUnwrap(trash).delete(fixture.artifact)
        let record = try XCTUnwrap(trash?.records.first)
        trash = nil
        try FileManager.default.removeItem(at: XCTUnwrap(record.trashURL))
        let restarted = fixture.trash()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(restarted.records.map(\.id), [record.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Recovery/\(record.id).json").path))
    }

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

    func testDeletionAndRestorationUpdateTwoOpenWindowsAndRejectStaleScans() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let hub = PersistedDataChangeHub()
        let trash = fixture.trash(didChange: { hub.send($0, originWindowID: UUID()) })
        let artifact = fixture.artifact
        let windows = (0..<2).map { _ in
            ChatViewModel(persistedDataChanges: hub, sessionDirectory: fixture.root.appendingPathComponent("Chat"))
        }
        for window in windows {
            for _ in 0..<200 where window.isLoadingSessions { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(window.isLoadingSessions)
            window.selectSession(fixture.chat.id)
            window.draft = "Unsent draft"
            window.stageAttachment(fixture.chat.messages[0].imageAttachments[0])
        }
        let stores = (0..<2).map { index in
            ArtifactStore(storage: .init(indexURL: fixture.root.appendingPathComponent("index-\(index).json"),
                                         cacheDirectory: fixture.root, favoritesURL: fixture.root.appendingPathComponent("favorites.json"),
                                         displayNamesURL: fixture.root.appendingPathComponent("names.json")),
                          refreshesAutomatically: false, persistedDataChanges: hub,
                          // Deliberately stale: a scan finishing after deletion must still be filtered.
                          rebuild: { _, _, _ in .init(fingerprint: nil, artifacts: [artifact]) },
                          mediaStore: fixture.media, trash: trash)
        }
        for store in stores { store.refresh() }
        try await settle(stores)
        XCTAssertTrue(stores.allSatisfy { $0.artifacts.count == 1 })
        stores[0].toggleFavorite(artifact)
        stores[0].rename(artifact, to: "My favorite image")
        XCTAssertTrue(stores[0].delete(artifact))
        try await settle(stores)
        XCTAssertTrue(stores.allSatisfy { $0.artifacts.isEmpty })
        for window in windows {
            XCTAssertTrue(window.messages[0].imageAttachments.isEmpty)
            XCTAssertTrue(window.pendingImageAttachments.isEmpty)
            XCTAssertEqual(window.draft, "Unsent draft")
        }
        let record = try XCTUnwrap(trash.records.first)
        try FileManager.default.moveItem(at: XCTUnwrap(record.trashURL), to: fixture.originalURL)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await settle(stores)
        XCTAssertTrue(stores.allSatisfy { $0.artifacts.map(\.id) == [artifact.id] })
        XCTAssertTrue(stores[0].isFavorite(artifact))
        XCTAssertEqual(stores[0].displayName(for: artifact), "My favorite image")
        for window in windows {
            XCTAssertEqual(window.messages[0].imageAttachments, fixture.chat.messages[0].imageAttachments)
            XCTAssertEqual(window.draft, "Unsent draft")
        }
    }

    func testFinderPutBackReconcilesOnRestart() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let trash = fixture.trash()
        try trash.delete(fixture.artifact)
        let record = try XCTUnwrap(trash.records.first)
        try FileManager.default.moveItem(at: XCTUnwrap(record.trashURL), to: fixture.originalURL)
        let restarted = fixture.trash()
        XCTAssertTrue(restarted.records.isEmpty)
        XCTAssertEqual(fixture.chats.loadSession(id: fixture.chat.id)?.messages, fixture.chat.messages)
    }

    func testInterruptedDeletionRecoversThroughBookmarkWithoutSavedBinURL() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let trash = fixture.trash()
        try trash.delete(fixture.artifact)
        var record = try XCTUnwrap(trash.records.first)
        record.trashURL = nil
        record.deletionCompleted = false
        try JSONEncoder().encode(record).write(to: fixture.root.appendingPathComponent("Recovery/\(record.id).json"))
        let restarted = fixture.trash()
        XCTAssertTrue(restarted.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.originalURL), fixture.bytes)
        XCTAssertEqual(fixture.chats.loadSession(id: fixture.chat.id)?.messages, fixture.chat.messages)
    }

    func testRenamedBinFileCanStillBeRestored() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let trash = fixture.trash()
        try trash.delete(fixture.artifact)
        let record = try XCTUnwrap(trash.records.first)
        let renamed = fixture.root.appendingPathComponent("Bin/Renamed.png")
        try FileManager.default.moveItem(at: XCTUnwrap(record.trashURL), to: renamed)
        try trash.restore(record)
        XCTAssertEqual(try Data(contentsOf: fixture.originalURL), fixture.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
    }

    func testEmptyBinStaysDeletedAndConflictingPutBackIsNeverAccepted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let trash = fixture.trash()
        try trash.delete(fixture.artifact)
        let record = try XCTUnwrap(trash.records.first)
        try FileManager.default.removeItem(at: XCTUnwrap(record.trashURL))
        trash.reconcile()
        XCTAssertEqual(trash.records.map(\.id), [record.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.originalURL.path))
        let replacement = Data("Unrelated replacement".utf8)
        try replacement.write(to: fixture.originalURL)
        trash.reconcile()
        XCTAssertEqual(trash.records.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.originalURL), replacement)
        XCTAssertTrue(try XCTUnwrap(fixture.chats.loadSession(id: fixture.chat.id)).messages[0].imageAttachments.isEmpty)
    }

    func testFinderRecoveryAutomaticallyRetriesWhenGenerationFinishes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let activity = InferenceActivityCoordinator()
        let operationID = UUID()
        let trash = fixture.trash(isActive: { _, id in activity.isActive(.chat(id)) })
        try trash.delete(fixture.artifact)
        let record = try XCTUnwrap(trash.records.first)
        try FileManager.default.moveItem(at: XCTUnwrap(record.trashURL), to: fixture.originalURL)
        XCTAssertTrue(activity.begin(resource: .chat(fixture.chat.id), windowID: UUID(), operationID: operationID))
        trash.reconcile()
        XCTAssertEqual(trash.records.count, 1)
        activity.end(resource: .chat(fixture.chat.id), operationID: operationID)
        for _ in 0..<200 where !trash.records.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(trash.records.isEmpty)
        XCTAssertEqual(fixture.chats.loadSession(id: fixture.chat.id)?.messages, fixture.chat.messages)
    }

    func testCorruptRecordDoesNotPreventLoadingOtherDeletedArtifacts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let trash = fixture.trash()
        try trash.delete(fixture.artifact)
        try Data("not JSON".utf8).write(to: fixture.root.appendingPathComponent("Recovery/broken.json"))
        let restarted = fixture.trash()
        XCTAssertEqual(restarted.records.map(\.id), [fixture.artifact.id])
        XCTAssertNotNil(restarted.errorMessage)
    }

    func testNativeMacOSBinRoundTrip() throws {
        let fixture = try Fixture()
        let trash = ArtifactTrash(directory: fixture.root.appendingPathComponent("Recovery"),
                                  media: fixture.media, chats: fixture.chats, images: fixture.images)
        defer {
            if let url = trash.records.first?.trashURL { try? FileManager.default.removeItem(at: url) }
            fixture.remove()
        }
        try trash.delete(fixture.artifact)
        let record = try XCTUnwrap(trash.records.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.originalURL.path))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(record.trashURL)), fixture.bytes)
        try FileManager.default.moveItem(at: XCTUnwrap(record.trashURL), to: fixture.originalURL)
        trash.reconcile()
        trash.reconcile()
        XCTAssertEqual(try Data(contentsOf: fixture.originalURL), fixture.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(record.trashURL).path))
    }

    func testSharedChatAndImageArtifactSurvivesPartialHistorySaveFailure() throws {
        let manager = FailingFileManager()
        let fixture = try Fixture(imageFileManager: manager)
        defer { fixture.remove() }
        let output = GeneratedImage(id: fixture.artifact.id, mimeType: "image/png", width: 640, height: 480,
                                    seed: 42, path: nil, revisedPrompt: "A fox", asset: try XCTUnwrap(fixture.artifact.asset))
        let turn = ImageGenerationTurn(id: UUID(), prompt: "Fox", referenceImages: [output.attachment], modelID: "test",
                                       settings: ImageRequestSettings(), createdAt: fixture.chat.createdAt,
                                       outputs: [output], status: .completed)
        let image = ImageGenerationSession(id: UUID(), title: "Images", createdAt: fixture.chat.createdAt,
                                           updatedAt: fixture.chat.updatedAt, modelKind: .imageGeneration, modelID: "test",
                                           draftSettings: ImageRequestSettings(), activeReference: output.attachment, turns: [turn])
        XCTAssertTrue(fixture.images.saveSession(image))
        let saved = try XCTUnwrap(fixture.images.loadSession(id: image.id))
        let trash = fixture.trash()
        try trash.delete(fixture.artifact)
        let deleted = try XCTUnwrap(fixture.images.loadSession(id: image.id))
        XCTAssertTrue(deleted.turns[0].outputs.isEmpty)
        XCTAssertTrue(deleted.turns[0].referenceImages.isEmpty)
        XCTAssertNil(deleted.activeReference)
        XCTAssertTrue(try XCTUnwrap(fixture.chats.loadSession(id: fixture.chat.id)).messages[0].imageAttachments.isEmpty)
        try trash.restore(XCTUnwrap(trash.records.first))
        XCTAssertEqual(fixture.images.loadSession(id: image.id), saved)

        let failing = fixture.trash(trashFile: { url in
            let destination = fixture.root.appendingPathComponent("Trashed.png")
            try FileManager.default.moveItem(at: url, to: destination)
            manager.refusesWrites = true
            return destination
        })
        XCTAssertThrowsError(try failing.delete(fixture.artifact))
        XCTAssertEqual(try Data(contentsOf: fixture.originalURL), fixture.bytes)
        XCTAssertEqual(fixture.chats.loadSession(id: fixture.chat.id)?.messages, fixture.chat.messages)
        XCTAssertEqual(failing.records.count, 1)
        manager.refusesWrites = false
        try failing.restore(XCTUnwrap(failing.records.first))
        XCTAssertTrue(failing.records.isEmpty)
        XCTAssertEqual(fixture.images.loadSession(id: image.id), saved)
    }

    private func settle(_ stores: [ArtifactStore]) async throws {
        for _ in 0..<200 where stores.contains(where: { $0.isRefreshing }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(stores.contains { $0.isRefreshing })
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

        init(fileManager: FileManager = .default, imageFileManager: FileManager = .default) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            media = MediaAssetStore(rootDirectory: root.appendingPathComponent("Media"))
            chats = ChatSessionStore(chatDirectory: root.appendingPathComponent("Chat"), mediaStore: media, fileManager: fileManager)
            images = ImageGenerationSessionStore(imageDirectory: root.appendingPathComponent("Images"), mediaStore: media, fileManager: imageFileManager)
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
                   didChange: @escaping (PersistedDataChange.Kind) -> Void = { _ in },
                   trashFile: ((URL) throws -> URL)? = nil) -> ArtifactTrash {
            ArtifactTrash(directory: root.appendingPathComponent("Recovery"), media: media, chats: chats, images: images,
                          isActive: isActive, didChange: didChange, trashFile: trashFile ?? { url in
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
