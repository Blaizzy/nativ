import XCTest
import Darwin
import SQLite3

final class ArtifactCatalogTests: XCTestCase {
    func testConcurrentRootReplacementNeverReadsOutsideWorkFiles() async throws {
        let fm = FileManager.default
        let base = ChatWorkFileStore.canonicalRoot(fm.temporaryDirectory)
            .appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("Files")
        let outside = base.appendingPathComponent("Outside")
        let swap = base.appendingPathComponent("Swap")
        for directory in [root, outside] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try (directory == root ? "safe" : "outside").write(
                to: directory.appendingPathComponent("Notes.md"), atomically: true, encoding: .utf8)
        }
        try fm.createSymbolicLink(at: swap, withDestinationURL: outside)
        let replacement = Task.detached {
            for _ in 0..<10_000 {
                _ = renameatx_np(AT_FDCWD, root.path, AT_FDCWD, swap.path, UInt32(RENAME_SWAP))
            }
        }
        defer { try? fm.removeItem(at: base) }
        let files = ChatWorkFileStore(root: root)
        let original = root.appendingPathComponent("Notes.md")
        for _ in 0..<2_000 {
            guard let validated = files.validatedURL(original) else { continue }
            XCTAssertEqual(validated.path, original.path)
            if let snapshot = try? await SafeLocalFileReader().read(url: validated) {
                XCTAssertEqual(String(decoding: snapshot.data, as: UTF8.self), "safe")
            }
        }
        await replacement.value
    }

    func testExportOntoSourceOrHardLinkPreservesContent() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("source.md")
        let alias = base.appendingPathComponent("alias.md")
        try "original".write(to: source, atomically: true, encoding: .utf8)
        try fm.linkItem(at: source, to: alias)
        try SafeLocalFileReader.exportCopy(from: source, to: source)
        try SafeLocalFileReader.exportCopy(from: source, to: alias)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: alias, encoding: .utf8), "original")
    }

    func testExportFailurePreservesDestinationAndRejectsReplacedSource() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("Files")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.md")
        let destination = base.appendingPathComponent("destination.md")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "destination".write(to: destination, atomically: true, encoding: .utf8)
        let validated = try XCTUnwrap(ChatWorkFileStore(root: root).validatedURL(source))
        let moved = base.appendingPathComponent("Moved")
        try fm.moveItem(at: root, to: moved)
        try fm.createSymbolicLink(at: root, withDestinationURL: moved)
        XCTAssertThrowsError(try SafeLocalFileReader.exportCopy(from: validated, to: destination))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "destination")
        try fm.removeItem(at: root)
        try fm.moveItem(at: moved, to: root)
        XCTAssertThrowsError(try SafeLocalFileReader.exportCopy(
            from: validated, to: destination, replaceExisting: false))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "destination")
        try SafeLocalFileReader.exportCopy(from: validated, to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "source")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "source")
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: base.path).contains { $0.hasPrefix(".nativ-export-") })
    }

    func testMissingProvenanceIsUnknownRegardlessOfRoleOrFilename() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        var attachment = try fixture.attachment(filename: "image-12345.png", mimeType: "image/png")
        attachment.origin = nil
        for role in [ChatTranscriptMessage.Role.user, .assistant, .tool] {
            let message = ChatTranscriptMessage(role: role, content: "", modelID: "some/model", imageAttachments: [attachment])
            let session = fixture.chat(messages: [message])
            XCTAssertTrue(fixture.chats.saveSession(session))
            let reloaded = try XCTUnwrap(fixture.chats.loadSession(id: session.id))
            let artifact = try XCTUnwrap(ArtifactCatalog.artifacts(chats: [reloaded], images: []).first)
            XCTAssertEqual(artifact.source, .unknown)
            XCTAssertNil(reloaded.messages[0].imageAttachments[0].origin)
        }
    }

    func testExplicitUploadOriginSurvivesPersistenceAndReuse() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let attachment = try fixture.attachment(filename: "image-12345.png", mimeType: "image/png")
        let session = fixture.chat(messages: [ChatTranscriptMessage(role: .user, content: "", imageAttachments: [attachment])])
        XCTAssertTrue(fixture.chats.saveSession(session))
        let reloaded = try XCTUnwrap(fixture.chats.loadSession(id: session.id))
        XCTAssertEqual(reloaded.messages[0].imageAttachments[0].origin, .uploaded)
        XCTAssertEqual(ArtifactCatalog.artifacts(chats: [reloaded], images: []).first?.source, .uploaded)
    }

    func testConflictingRecordedOriginsRemainUnknown() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let upload = try fixture.attachment(filename: "image.png", mimeType: "image/png")
        var generated = upload
        generated.origin = .generated
        let chats = [upload, generated].map {
            fixture.chat(messages: [ChatTranscriptMessage(role: .user, content: "", imageAttachments: [$0])])
        }
        let artifacts = ArtifactCatalog.artifacts(chats: chats, images: [])
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts.first?.source, .unknown)
    }

    @MainActor
    func testUnknownOriginSurvivesGalleryReuse() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        var attachment = try fixture.attachment(filename: "legacy.png", mimeType: "image/png")
        attachment.origin = nil
        let session = fixture.chat(messages: [ChatTranscriptMessage(role: .assistant, content: "", imageAttachments: [attachment])])
        let artifact = try XCTUnwrap(ArtifactCatalog.artifacts(chats: [session], images: []).first)
        let store = ArtifactStore(storage: fixture.storage, refreshesAutomatically: false, mediaStore: fixture.media)
        let reused = try XCTUnwrap(store.chatAttachment(for: artifact))
        XCTAssertEqual(reused.origin, .unknown)

    }

    func testLegacyChatGenerationKeepsOriginAndChatOwnership() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        var attachment = try fixture.attachment(filename: "generated.png", mimeType: "image/png")
        attachment.origin = nil
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
    func testGalleryDelegatesFileRemovalToDeletionHandler() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let output = fixture.output()
        let artifact = try XCTUnwrap(ArtifactCatalog.artifacts(chats: [], images: [fixture.image(turns: [fixture.turn(references: [], outputs: [output])])]).first)
        try fixture.writeIndex([artifact])
        let store = ArtifactStore(storage: fixture.storage, refreshesAutomatically: false, mediaStore: fixture.media, deletionHandler: { _ in true })
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

    func testPartialDeletionRetainsRemainingOwnerAndCanBeRetried() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let output = fixture.output()
        var chat = fixture.chat(messages: [ChatTranscriptMessage(role: .user, content: "reuse", imageAttachments: [output.attachment])])
        var image = fixture.image(turns: [fixture.turn(references: [], outputs: [output])])
        XCTAssertTrue(fixture.chats.saveSession(chat))
        XCTAssertTrue(fixture.images.saveSession(image))
        let artifact = try XCTUnwrap(ArtifactCatalog.artifacts(chats: [chat], images: [image]).first)

        XCTAssertFalse(ArtifactDeletion.removeReferences(
            to: artifact, isActive: { _, _ in false },
            remove: { workspace, _ in
                guard workspace == .chat else { return false }
                chat.removeArtifact(output.id)
                return fixture.chats.saveSession(chat)
            }
        ))

        let remaining = try XCTUnwrap(ArtifactCatalog.artifacts(chats: fixture.chats.loadSessions(), images: fixture.images.loadSessions()).first)
        XCTAssertEqual(remaining.locations.map(\.sessionID), [image.id])
        XCTAssertNotNil(fixture.media.fileURL(for: try XCTUnwrap(output.asset)))
        XCTAssertTrue(ArtifactDeletion.removeReferences(
            to: remaining, isActive: { _, _ in false },
            remove: { workspace, id in
                XCTAssertEqual(workspace, .imageGeneration)
                XCTAssertEqual(id, image.id)
                image.removeArtifact(output.id)
                return fixture.images.saveSession(image)
            }
        ))
        XCTAssertTrue(ArtifactCatalog.artifacts(chats: fixture.chats.loadSessions(), images: fixture.images.loadSessions()).isEmpty)
        XCTAssertNotNil(fixture.media.fileURL(for: try XCTUnwrap(output.asset)))
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

    @MainActor
    func testWorkDocumentsUseSavedFilesAndExistingArtifactActions() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let item = ChatWorkItem(title: "Trip notes", kind: .document, content: "# San Francisco")
        var session = fixture.chat(messages: [])
        session.workState = ChatWorkState(items: [item])
        // Stage a legacy chat file without creating a Git checkout in the test.
        try fixture.chats.workFiles.save(session.workState!, previous: nil, sessionID: session.id)
        let artifacts = ArtifactCatalog.artifacts(chats: [session], images: [], chatStore: fixture.chats)
        let artifact = try XCTUnwrap(artifacts.first)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifact.kind, .document)
        XCTAssertEqual(artifact.filename, "Trip notes.md")
        XCTAssertEqual(artifact.sessionID, session.id)
        XCTAssertEqual(artifact.locations.first?.attachmentID, item.id)
        XCTAssertNil(artifact.locations.first?.messageID)
        let store = ArtifactStore(storage: fixture.storage, refreshesAutomatically: false)
        XCTAssertEqual(store.fileURL(for: artifact), fixture.chats.workFiles.fileURL(for: item, sessionID: session.id).flatMap(fixture.chats.workFiles.validatedURL))
        let preview = await store.textPreview(for: artifact)
        XCTAssertEqual(preview, "# San Francisco")
        XCTAssertEqual(store.searchResults(in: artifacts, query: "trip", semanticMatches: nil).count, 1)
        XCTAssertFalse(store.delete(artifact))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store.fileURL(for: artifact)).path))
        let decoded = try JSONDecoder().decode(Artifact.self, from: JSONEncoder().encode(artifact))
        XCTAssertEqual(decoded, artifact)
    }

    func testWorkCatalogSkipsUnsavedFilesAndSeparatesForkedChats() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let item = ChatWorkItem(title: "Notes", kind: .document, content: "Saved")
        var first = fixture.chat(messages: [])
        first.workState = ChatWorkState(items: [item,
            ChatWorkItem(title: "Web", kind: .website, content: "", url: "https://example.com"),
            ChatWorkItem(title: "Terminal", kind: .terminal, content: "")])
        XCTAssertTrue(ArtifactCatalog.artifacts(chats: [first], images: [], chatStore: fixture.chats).isEmpty)
        try fixture.chats.workFiles.save(first.workState!, previous: nil, sessionID: first.id)
        var second = fixture.chat(messages: [])
        second.workState = first.workState
        try fixture.chats.workFiles.save(second.workState!, previous: nil, sessionID: second.id)
        let artifacts = ArtifactCatalog.artifacts(chats: [first, second], images: [], chatStore: fixture.chats)
        XCTAssertEqual(artifacts.count, 2)
        XCTAssertEqual(Set(artifacts.map(\.id)).count, 2)
        XCTAssertEqual(Set(artifacts.compactMap(\.workFileURL)).count, 2)
        let repeated = ArtifactCatalog.artifacts(chats: [first, second], images: [], chatStore: fixture.chats)
        XCTAssertEqual(artifacts.map(\.id), repeated.map(\.id))
        let url = try XCTUnwrap(fixture.chats.workFiles.fileURL(for: item, sessionID: first.id))
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(ArtifactCatalog.artifacts(chats: [first, second], images: [], chatStore: fixture.chats).count, 1)
    }

    func testWorkCatalogIncludesAllSavedFileTypesIncludingWebsites() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        var session = fixture.chat(messages: [])
        session.workState = ChatWorkState(items: [
            ChatWorkItem(title: "Notes.md", kind: .document, content: "Notes"),
            ChatWorkItem(title: "main.py", kind: .code, content: "print(1)"),
            ChatWorkItem(title: "data.json", kind: .code, content: "{}"),
            ChatWorkItem(title: "style.css", kind: .code, content: "body {}"),
            ChatWorkItem(title: "app.js", kind: .code, content: "const n = 1;"),
            ChatWorkItem(title: "Site", kind: .website, content: "<html></html>"),
            ChatWorkItem(title: "Page.html", kind: .document, content: "Page"),
            ChatWorkItem(title: "Mislabelled", kind: .code, content: "<html><body>Page</body></html>")
        ])
        try fixture.chats.workFiles.save(session.workState!, previous: nil, sessionID: session.id)
        let artifacts = ArtifactCatalog.artifacts(chats: [session], images: [], chatStore: fixture.chats)
        XCTAssertEqual(Set(artifacts.map(\.filename)), ["Notes.md", "main.py", "data.json", "style.css", "app.js",
                                                               "Site.html", "Page.html", "Mislabelled.html"])
    }

    @MainActor
    func testCatalogAndCachedActionsRejectSymlinkedWorkFiles() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let item = ChatWorkItem(title: "Notes.md", kind: .document, content: "Safe")
        var session = fixture.chat(messages: [])
        session.workState = ChatWorkState(items: [item])
        let files = fixture.chats.workFiles
        try files.save(session.workState!, previous: nil, sessionID: session.id)
        let artifact = try XCTUnwrap(ArtifactCatalog.artifacts(chats: [session], images: [], chatStore: fixture.chats).first)
        let store = ArtifactStore(storage: fixture.storage, refreshesAutomatically: false)
        let url = try XCTUnwrap(files.fileURL(for: item, sessionID: session.id))
        let outside = fixture.root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "Private".write(to: outside.appendingPathComponent(item.storedFilename), atomically: true, encoding: .utf8)
        for linkedURL in [url, url.deletingLastPathComponent()] {
            try FileManager.default.removeItem(at: linkedURL)
            let destination = linkedURL == url ? outside.appendingPathComponent(item.storedFilename) : outside
            try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: destination)
            XCTAssertNil(store.fileURL(for: artifact), "Cached actions must revalidate paths")
            XCTAssertTrue(ArtifactCatalog.artifacts(chats: [session], images: [], chatStore: fixture.chats).isEmpty)
            try FileManager.default.removeItem(at: linkedURL)
            try files.save(session.workState!, previous: nil, sessionID: session.id)
        }
    }

    func testUnchangedCatalogChecksFilesWithoutReloadingSessions() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let item = ChatWorkItem(title: "Notes.md", kind: .document, content: "Saved")
        var session = fixture.chat(messages: [])
        session.workState = ChatWorkState(items: [item])
        try fixture.chats.workFiles.save(session.workState!, previous: nil, sessionID: session.id)
        let url = try XCTUnwrap(fixture.chats.workFiles.fileURL(for: item, sessionID: session.id))
        var loads = 0
        func load() -> [Artifact] {
            loads += 1
            return ArtifactCatalog.artifacts(chats: [session], images: [], chatStore: fixture.chats,
                                             includeUnavailableWorkFiles: true)
        }
        var snapshot = ArtifactStore.catalogSnapshot(fingerprint: "saved", known: .init(fingerprint: nil, artifacts: []), load: load)
        XCTAssertEqual(snapshot.artifacts.count, 1)
        try FileManager.default.removeItem(at: url)
        snapshot = ArtifactStore.catalogSnapshot(fingerprint: "saved", known: snapshot, load: load)
        XCTAssertTrue(snapshot.artifacts.isEmpty)
        ArtifactStore.writeIndex(snapshot.artifacts, fingerprint: snapshot.fingerprint,
                                 to: fixture.storage.indexURL, candidates: snapshot.candidates)
        snapshot = ArtifactStore.loadIndex(fixture.storage.indexURL)
        try "Restored with more content".write(to: url, atomically: true, encoding: .utf8)
        snapshot = ArtifactStore.catalogSnapshot(fingerprint: "saved", known: snapshot, load: load)
        XCTAssertEqual(snapshot.artifacts.first?.byteSize, "Restored with more content".utf8.count)
        XCTAssertEqual(loads, 1, "Deletion, restoration and reload must reuse saved metadata")
        _ = ArtifactStore.catalogSnapshot(fingerprint: "changed", known: snapshot, load: load)
        XCTAssertEqual(loads, 2, "A changed session must invalidate cached metadata")
    }

    func testIndexRejectsSymlinksAndRecoversOriginalPath() async throws {
        for linkFilesRoot in [false, true] {
            let fixture = Fixture()
            defer { fixture.remove() }
            let item = ChatWorkItem(title: "Notes.md", kind: .document, content: "originalsentinel")
            var session = fixture.chat(messages: [])
            session.workState = ChatWorkState(items: [item])
            XCTAssertTrue(fixture.chats.saveSession(session))
            let root = fixture.root.appendingPathComponent("Chat")
            let worker = ArtifactFileIndexer(root: root, indexURL: fixture.root.appendingPathComponent("Index.sqlite"))
            try await worker.discover(); try await worker.drain()
            let initial = try await worker.search("originalsentinel")
            XCTAssertEqual(initial.count, 1)
            let url = try XCTUnwrap(fixture.chats.workFiles.fileURL(for: item, sessionID: session.id))
            let directory = linkFilesRoot ? fixture.chats.workFiles.root : url.deletingLastPathComponent()
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            let outside = fixture.root.appendingPathComponent("Outside")
            // Keep the inode and timestamps: path validation must run even when stamps match.
            try FileManager.default.moveItem(at: directory, to: outside)
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
            try await worker.discover(); try await worker.drain()
            let blocked = try await worker.search("originalsentinel")
            XCTAssertTrue(blocked.isEmpty)
            try "privatesentinel".write(to: outside.appendingPathComponent(relative), atomically: true, encoding: .utf8)
            try await worker.changed(paths: [url.path]); try await worker.drain()
            let leaked = try await worker.search("privatesentinel")
            XCTAssertTrue(leaked.isEmpty)
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "restoredsentinel".write(to: url, atomically: true, encoding: .utf8)
            try await worker.changed(paths: [url.path]); try await worker.drain()
            let restored = try await worker.search("restoredsentinel")
            XCTAssertEqual(restored.count, 1)
        }
    }

    func testOldIndexIsRebuiltWithoutRetainingUnsafeContent() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("Index.sqlite")
        do {
            let database = try ArtifactFileIndexStore(url: url)
            let file = ArtifactFileIndexStore.File(id: "file", session: "session", path: "/outside", name: "Notes.md", title: "Test", revision: "1")
            try database.synchronize(session: "session", stamp: "stamp", files: [file])
            try database.finish(file.id, stamp: "stamp", hash: "hash", body: "privatesentinel")
        }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "UPDATE metadata SET value='1' WHERE key='version'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let reopened = try ArtifactFileIndexStore(url: url)
        XCTAssertTrue(try reopened.search("privatesentinel").isEmpty)
        XCTAssertTrue(try reopened.sessionIDs().isEmpty, "Sessions must be discovered again using validated paths")
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
            let directory = root.appendingPathComponent("Inputs/\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(filename)
            try Data([1, 2, 3]).write(to: file)
            return try ChatImageAttachment(contentsOf: file, mediaStore: media)
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
