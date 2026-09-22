import Combine
import Synchronization
import XCTest

@MainActor
final class ArtifactRefreshTests: XCTestCase {
    func testSavedSessionsRefreshExistingStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = PersistedDataChangeHub()
        let source = Source()
        let store = makeStore(directory: directory, hub: hub, source: source)

        for kind in [PersistedDataChange.Kind.imageGenerationSession(UUID()), .chatSession(UUID())] {
            let artifact = makeArtifact()
            source.state.withLock { $0.artifacts.append(artifact) }
            let updated = expectation(description: "Saved artifact published")
            let subscription = store.$artifacts.sink { artifacts in
                if artifacts.contains(where: { $0.id == artifact.id }) {
                    updated.fulfill()
                }
            }
            hub.send(kind, originWindowID: UUID())
            await fulfillment(of: [updated], timeout: 5)
            subscription.cancel()
        }
        XCTAssertEqual(store.artifacts.count, 2)
        XCTAssertEqual(Set(store.artifacts.map(\.id)).count, 2)
    }

    func testChangesDuringScanTriggerOneFollowUpScan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = PersistedDataChangeHub()
        let started = expectation(description: "Initial scan started")
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let source = Source(firstScanStarted: started, resumeFirstScan: resume)
        let store = makeStore(directory: directory, hub: hub, source: source)
        store.refresh()
        await fulfillment(of: [started], timeout: 5)

        let artifact = makeArtifact()
        source.state.withLock { $0.artifacts = [artifact] }
        hub.send(.imageGenerationSession(UUID()), originWindowID: UUID())
        hub.send(.imageGenerationSession(UUID()), originWindowID: UUID())
        let updated = expectation(description: "Follow-up publishes new artifact")
        let subscription = store.$artifacts.sink { artifacts in
            if artifacts.map(\.id) == [artifact.id] {
                updated.fulfill()
            }
        }
        resume.signal()
        await fulfillment(of: [updated], timeout: 5)
        subscription.cancel()
        XCTAssertEqual(source.state.withLock { $0.scans }, 2)
        XCTAssertEqual(store.artifacts.map(\.id), [artifact.id])
    }

    func testDeletionDuringScanDoesNotRepublishDeletedArtifact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = PersistedDataChangeHub()
        let artifact = makeArtifact()
        let started = expectation(description: "Stale scan started")
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let source = Source(firstScanStarted: started, resumeFirstScan: resume)
        source.state.withLock { $0.artifacts = [artifact] }
        let store = makeStore(directory: directory, hub: hub, source: source)
        store.refresh()
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(store.delete(artifact))
        source.state.withLock { $0.artifacts = [] }
        let updated = expectation(description: "Follow-up publishes remaining artifacts")
        let subscription = store.$artifacts.dropFirst().sink { artifacts in
            XCTAssertTrue(artifacts.isEmpty)
            updated.fulfill()
        }
        resume.signal()
        await fulfillment(of: [updated], timeout: 5)
        subscription.cancel()
        XCTAssertEqual(source.state.withLock { $0.scans }, 2)
    }

    func testFolderChangesDoNotScanArtifacts() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = PersistedDataChangeHub()
        let source = Source()
        let store = makeStore(directory: directory, hub: hub, source: source)
        hub.send(.chatFolders, originWindowID: UUID())
        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(source.state.withLock { $0.scans }, 0)
    }

    func testRenamePersistsAndSearchIncludesNamesOutsideSemanticResults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = PersistedDataChangeHub()
        let source = Source()
        let store = makeStore(directory: directory, hub: hub, source: source)
        let renamed = makeArtifact()
        let semantic = makeArtifact()
        let excluded = makeArtifact()
        let originalURL = store.fileURL(for: renamed)
        let originalBytes = Data("Original file content".utf8)
        try FileManager.default.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try originalBytes.write(to: originalURL)
        store.rename(renamed, to: "  Amber cube  ")
        store.rename(semantic, to: "Zebra")

        let reloaded = makeStore(directory: directory, hub: hub, source: source)
        XCTAssertEqual(reloaded.displayName(for: renamed), "Amber cube")
        XCTAssertEqual(renamed.filename, "image.png")
        XCTAssertEqual(reloaded.sortedByName([semantic, renamed]).map(\.id), [renamed.id, semantic.id])
        XCTAssertEqual(reloaded.searchResults(in: [renamed], query: "AMBER", semanticMatches: nil).map(\.id), [renamed.id])
        XCTAssertEqual(reloaded.searchResults(in: [renamed], query: "image.png", semanticMatches: nil).map(\.id), [renamed.id])
        XCTAssertEqual(reloaded.searchResults(in: [renamed, semantic], query: "  ", semanticMatches: []).map(\.id), [renamed.id, semantic.id])
        XCTAssertEqual(
            reloaded.searchResults(
                in: [semantic, renamed], query: "amber",
                semanticMatches: [excluded.id, semantic.id, renamed.id, semantic.id]
            ).map(\.id),
            [renamed.id, semantic.id]
        )
        reloaded.rename(renamed, to: " ")
        XCTAssertEqual(reloaded.displayName(for: renamed), renamed.filename)
        XCTAssertTrue(reloaded.searchResults(in: [renamed], query: "amber", semanticMatches: []).isEmpty)
        XCTAssertEqual(makeStore(directory: directory, hub: hub, source: source).displayName(for: renamed), renamed.filename)
        XCTAssertEqual(reloaded.fileURL(for: renamed), originalURL)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
    }

    private func makeStore(directory: URL, hub: PersistedDataChangeHub, source: Source) -> ArtifactStore {
        ArtifactStore(
            storage: .init(
                indexURL: directory.appendingPathComponent("index.json"),
                cacheDirectory: directory.appendingPathComponent("cache"),
                favoritesURL: directory.appendingPathComponent("favorites.json"),
                displayNamesURL: directory.appendingPathComponent("names.json")
            ),
            refreshesAutomatically: false,
            persistedDataChanges: hub,
            rebuild: { _, _, _ in ArtifactStore.CatalogSnapshot(fingerprint: nil, artifacts: source.scan()) },
            deletionHandler: { _ in true }
        )
    }

    private func makeArtifact() -> Artifact {
        let id = UUID()
        return Artifact(
            id: id, kind: .image, source: .generated,
            sessionID: UUID(), messageID: UUID(), filename: "image.png",
            mimeType: "image/png", relativePath: "image/\(id).png", byteSize: 1,
            createdAt: .now, prompt: nil, sessionTitle: "Test"
        )
    }

    private final class Source: Sendable {
        struct State {
            var artifacts: [Artifact] = []
            var scans = 0
        }

        let state = Mutex(State())
        let firstScanStarted: XCTestExpectation?
        let resumeFirstScan: DispatchSemaphore?

        init(firstScanStarted: XCTestExpectation? = nil, resumeFirstScan: DispatchSemaphore? = nil) {
            self.firstScanStarted = firstScanStarted
            self.resumeFirstScan = resumeFirstScan
        }

        func scan() -> [Artifact] {
            let (artifacts, count) = state.withLock {
                $0.scans += 1
                return ($0.artifacts, $0.scans)
            }
            if count == 1, let resumeFirstScan {
                firstScanStarted?.fulfill()
                _ = resumeFirstScan.wait(timeout: .now() + 5)
            }
            return artifacts
        }
    }
}
