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
            rebuild: { _, _, _ in source.scan() }
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
