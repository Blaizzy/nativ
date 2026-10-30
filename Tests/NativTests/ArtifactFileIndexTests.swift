import XCTest

final class ArtifactFileIndexTests: XCTestCase {
    private struct Fixture {
        let root: URL
        var chatRoot: URL { root.appending(path: "Chat") }
        var database: URL { root.appending(path: "Index.sqlite") }
        var chats: ChatSessionStore { .init(chatDirectory: chatRoot, mediaStore: .init(rootDirectory: root.appending(path: "Media"))) }
        func worker() -> ArtifactFileIndexer { .init(root: chatRoot, indexURL: database) }
        func file(_ item: ChatWorkItem, in session: ChatSession) -> URL {
            chats.workFiles.fileURL(for: item, sessionID: session.id)!
        }
        func manifest(_ session: ChatSession) -> ArtifactFileManifest {
            .init(root: chatRoot, session: session,
                  stamp: ArtifactFileIndexer.stamp(chatRoot.appending(path: "Sessions/\(session.id).json"))!)
        }
        func session() -> ChatSession {
            .init(id: UUID(), title: "Project", createdAt: .now, updatedAt: .now, messages: [],
                  workState: .init(items: [
                    .init(title: "Notes.md", kind: .document, content: "quokka notes"),
                    .init(title: "app.swift", kind: .code, content: "let wombat = 42")]))
        }
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return Fixture(root: root)
    }

    @MainActor
    func testSearchStateUsesIndexWithoutReadingFilesAndRejectsStaleQueries() async throws {
        let fixture = try fixture(), session = fixture.session()
        XCTAssertTrue(fixture.chats.saveSession(session))
        let worker = fixture.worker()
        try await worker.discover()
        try await worker.drain()
        let state = ArtifactFileSearch()
        await state.update("quokka", using: worker)
        XCTAssertEqual(state.matches(for: "quokka").count, 1)
        XCTAssertTrue(state.matches(for: "wombat").isEmpty)
        let obsolete = Task { await state.update("quokka", using: worker) }
        await Task.yield()
        obsolete.cancel()
        await state.update("wombat", using: worker)
        await obsolete.value
        XCTAssertEqual(state.matches(for: "wombat"),
            [ArtifactFileManifest.artifactID(session: session.id, item: session.workState!.items[1].id)])
        XCTAssertTrue(state.matches(for: "quokka").isEmpty)
        await state.update("   ", using: worker)
        XCTAssertTrue(state.matches.isEmpty)
        XCTAssertFalse(state.isSearching)
        let reads = await worker.contentReads
        XCTAssertEqual(reads, 2)
    }

    @MainActor
    func testFilesystemChangesRefreshOpenCatalogWithoutReloadingSessions() async throws {
        let fixture = try fixture(), session = fixture.session()
        XCTAssertTrue(fixture.chats.saveSession(session))
        let coordinator = ArtifactFileIndexCoordinator(root: fixture.chatRoot, indexURL: fixture.database)
        let candidates = ArtifactCatalog.artifacts(chats: [session], images: [], chatStore: fixture.chats,
                                                   includeUnavailableWorkFiles: true)
        let store = ArtifactStore(storage: .init(indexURL: fixture.root.appending(path: "catalog.json"),
            cacheDirectory: fixture.root.appending(path: "Cache"), favoritesURL: fixture.root.appending(path: "favorites.json"),
            displayNamesURL: fixture.root.appending(path: "names.json")), fileIndex: coordinator,
            rebuild: { _, _, known in
                ArtifactStore.catalogSnapshot(fingerprint: "unchanged", known: known) {
                    XCTAssertNil(known.candidates, "Filesystem changes must reuse cached session metadata")
                    return candidates
                }
            })
        for _ in 0..<100 where store.artifacts.count != 2 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(store.artifacts.count, 2)
        let item = session.workState!.items[0], url = fixture.file(item, in: session)
        try FileManager.default.removeItem(at: url)
        for _ in 0..<100 where store.artifacts.count != 1 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(store.artifacts.count, 1, "An open gallery must drop externally deleted files")
        XCTAssertTrue(store.searchResults(in: store.artifacts, query: "Notes.md", semanticMatches: nil).isEmpty)
        try "restoredwallaby".write(to: url, atomically: true, encoding: .utf8)
        for _ in 0..<100 where store.artifacts.count != 2 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(store.artifacts.count, 2)
        let hits = try await coordinator.worker.search("restoredwallaby").compactMap(UUID.init(uuidString:))
        XCTAssertEqual(store.searchResults(in: store.artifacts, query: "restoredwallaby", semanticMatches: nil,
                                          contentMatches: hits).count, 1)
    }

    func testSearchReturnsAllMatchesAndTreatsQueryAsLiteralText() throws {
        let fixture = try fixture()
        let database = try ArtifactFileIndexStore(url: fixture.database)
        let files = (0..<150).map { index in
            ArtifactFileIndexStore.File(id: UUID().uuidString, session: "session", path: "/file/\(index)",
                name: "notes-\(index).md", title: "Project", revision: "0")
        }
        try database.synchronize(session: "session", stamp: "stamp", files: files)
        for file in files {
            try database.finish(file.id, stamp: "stamp", hash: "hash", body: "quokka café")
        }
        XCTAssertEqual(try database.search("quokka").count, 150)
        XCTAssertEqual(try database.search("café").count, 150)
        XCTAssertTrue(try database.search("quokka OR missing").isEmpty)
        XCTAssertTrue(try database.search("\"").isEmpty)
    }

    func testBackfillAndUnchangedRestartPerformNoContentRereads() async throws {
        let fixture = try fixture(), session = fixture.session()
        XCTAssertTrue(fixture.chats.saveSession(session))
        let first = fixture.worker()
        try await first.discover()
        try await first.drain()
        let initialReads = await first.contentReads
        XCTAssertEqual(initialReads, 2)
        let hits = try await first.search("quokka")
        XCTAssertEqual(hits, [ArtifactFileManifest.artifactID(session: session.id, item: session.workState!.items[0].id).uuidString])
        let restarted = fixture.worker()
        try await restarted.discover()
        try await restarted.drain()
        let contentReads = await restarted.contentReads, sessionReads = await restarted.sessionReads
        XCTAssertEqual(contentReads, 0)
        XCTAssertEqual(sessionReads, 0)
        let persisted = try await restarted.search("wombat")
        XCTAssertEqual(persisted.count, 1)
    }

    func testSaveUpdatesOnlyEditedFileAndTitleDoesNotReadBodies() async throws {
        let fixture = try fixture()
        var session = fixture.session()
        XCTAssertTrue(fixture.chats.saveSession(session))
        let worker = fixture.worker()
        try await worker.discover(); try await worker.drain()
        session.workState!.items[0].content = "platypus revision"
        session.workState!.items[0].revision += 1
        XCTAssertTrue(fixture.chats.saveSession(session))
        try await worker.receive(fixture.manifest(session)); try await worker.drain()
        let reads = await worker.contentReads
        XCTAssertEqual(reads, 3)
        let old = try await worker.search("quokka"), updated = try await worker.search("platypus")
        XCTAssertTrue(old.isEmpty); XCTAssertEqual(updated.count, 1)
        session.customTitle = "Wildlife"
        XCTAssertTrue(fixture.chats.saveSession(session))
        try await worker.receive(fixture.manifest(session)); try await worker.drain()
        let titleReads = await worker.contentReads
        XCTAssertEqual(titleReads, 3)
        let titleHits = try await worker.search("Wildlife")
        XCTAssertEqual(titleHits.count, 2)
    }

    func testRenameDeletionAndStaleSaveCannotResurrectOldContent() async throws {
        let fixture = try fixture()
        var session = fixture.session()
        XCTAssertTrue(fixture.chats.saveSession(session))
        let stale = fixture.manifest(session), worker = fixture.worker()
        try await worker.discover(); try await worker.drain()
        session.workState!.items[0].title = "Renamed.md"
        XCTAssertTrue(fixture.chats.saveSession(session))
        try await worker.receive(fixture.manifest(session))
        try await worker.receive(stale)
        try await worker.drain()
        let renamed = try await worker.search("Renamed"), old = try await worker.search("Notes.md")
        XCTAssertEqual(renamed.count, 1); XCTAssertTrue(old.isEmpty)
        session.workState!.items.removeFirst()
        XCTAssertTrue(fixture.chats.saveSession(session))
        try await worker.receive(fixture.manifest(session)); try await worker.drain()
        let removed = try await worker.search("quokka")
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(fixture.chats.deleteSession(id: session.id))
        try await worker.discover()
        let deleted = try await worker.search("wombat")
        XCTAssertTrue(deleted.isEmpty)
    }

    func testExternalEditsMissingFilesAndReappearance() async throws {
        let fixture = try fixture(), session = fixture.session(), worker = fixture.worker()
        XCTAssertTrue(fixture.chats.saveSession(session))
        try await worker.discover(); try await worker.drain()
        let url = fixture.file(session.workState!.items[0], in: session)
        try "external koala".write(to: url, atomically: true, encoding: .utf8)
        try await worker.changed(paths: [url.path]); try await worker.drain()
        let changed = try await worker.search("koala")
        XCTAssertEqual(changed.count, 1)
        try FileManager.default.removeItem(at: url)
        try await worker.changed(paths: [url.path]); try await worker.drain()
        let missing = try await worker.search("koala"), pending = try await worker.hasPending()
        XCTAssertTrue(missing.isEmpty); XCTAssertTrue(pending)
        try "returned echidna".write(to: url, atomically: true, encoding: .utf8)
        try await worker.changed(paths: [url.path]); try await worker.drain()
        let restored = try await worker.search("echidna")
        XCTAssertEqual(restored.count, 1)
    }

    func testInterruptedBackfillResumesRemainingFile() async throws {
        let fixture = try fixture(), session = fixture.session(), worker = fixture.worker()
        XCTAssertTrue(fixture.chats.saveSession(session))
        try await worker.discover()
        let task = Task { try await worker.drain() }
        for _ in 0..<1000 where await worker.contentReads == 0 { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        _ = await task.result
        let completed = await worker.contentReads
        let restarted = fixture.worker()
        try await restarted.discover(); try await restarted.drain()
        let remainingReads = await restarted.contentReads
        XCTAssertEqual(completed + remainingReads, 2)
        let pending = try await restarted.hasPending()
        XCTAssertFalse(pending)
    }

    func testOfflineChangesReadOnlyChangedFile() async throws {
        let fixture = try fixture(), session = fixture.session(), worker = fixture.worker()
        XCTAssertTrue(fixture.chats.saveSession(session))
        try await worker.discover(); try await worker.drain()
        let url = fixture.file(session.workState!.items[1], in: session)
        try "let kangaroo = 1".write(to: url, atomically: true, encoding: .utf8)
        let restarted = fixture.worker()
        try await restarted.discover(); try await restarted.drain()
        let reads = await restarted.contentReads, sessionReads = await restarted.sessionReads
        XCTAssertEqual(reads, 1); XCTAssertEqual(sessionReads, 0)
        let hits = try await restarted.search("kangaroo")
        XCTAssertEqual(hits.count, 1)
    }
    func testCorruptIndexRebuildsFromSavedFiles() async throws {
        let fixture = try fixture(), session = fixture.session()
        XCTAssertTrue(fixture.chats.saveSession(session))
        try Data("not a sqlite database".utf8).write(to: fixture.database)
        let worker = fixture.worker()
        try await worker.discover(); try await worker.drain()
        let hits = try await worker.search("quokka")
        XCTAssertEqual(hits.count, 1)
    }

    @MainActor
    func testCoordinatorIndexesOnLaunchAndTracksSavesWithoutOpeningArtifacts() async throws {
        let fixture = try fixture()
        var session = fixture.session()
        XCTAssertTrue(fixture.chats.saveSession(session))
        let coordinator = ArtifactFileIndexCoordinator(root: fixture.chatRoot, indexURL: fixture.database)
        for _ in 0..<100 {
            if try await !coordinator.worker.search("quokka").isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let initial = try await coordinator.worker.search("quokka")
        XCTAssertEqual(initial.count, 1)
        session.workState!.items[0].content = "silent incremental tasmanian"
        session.workState!.items[0].revision += 1
        XCTAssertTrue(fixture.chats.saveSession(session))
        for _ in 0..<100 {
            if try await !coordinator.worker.search("tasmanian").isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let updated = try await coordinator.worker.search("tasmanian")
        XCTAssertEqual(updated.count, 1)
        let url = fixture.file(session.workState!.items[0], in: session)
        try "filesystem wallaby".write(to: url, atomically: true, encoding: .utf8)
        for _ in 0..<100 {
            if try await !coordinator.worker.search("wallaby").isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let external = try await coordinator.worker.search("wallaby")
        XCTAssertEqual(external.count, 1)
        let reads = await coordinator.worker.contentReads
        XCTAssertEqual(reads, 4, "Watcher notifications must not duplicate content reads after saves")
    }

    func testUnreadableSessionRemainsRetryableAndRepairIsIndexed() async throws {
        let fixture = try fixture(), session = fixture.session(), worker = fixture.worker()
        XCTAssertTrue(fixture.chats.saveSession(session))
        let url = fixture.chatRoot.appending(path: "Sessions/\(session.id).json")
        let original = try Data(contentsOf: url)
        try Data("interrupted JSON".utf8).write(to: url, options: .atomic)
        try await worker.discover(); try await worker.drain()
        let pending = try await worker.hasPending()
        XCTAssertTrue(pending)
        try original.write(to: url, options: .atomic)
        try await worker.changed(paths: [url.path]); try await worker.drain()
        let hits = try await worker.search("quokka"), finished = try await worker.hasPending()
        XCTAssertEqual(hits.count, 1); XCTAssertFalse(finished)
    }

    func testBinaryAndLargeReplacementsKeepMetadataWithoutIndexingPartialBodies() async throws {
        let fixture = try fixture(), session = fixture.session(), worker = fixture.worker()
        XCTAssertTrue(fixture.chats.saveSession(session))
        let first = fixture.file(session.workState!.items[0], in: session)
        let second = fixture.file(session.workState!.items[1], in: session)
        try Data([0, 1, 2, 3]).write(to: first)
        try Data(repeating: 65, count: 2_000_002).write(to: second)
        try await worker.discover(); try await worker.drain()
        let names = try await worker.search("Notes"), body = try await worker.search("quokka")
        let pending = try await worker.hasPending()
        XCTAssertEqual(names.count, 1); XCTAssertTrue(body.isEmpty); XCTAssertFalse(pending)
    }

}
