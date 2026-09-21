import Synchronization
import XCTest

@MainActor
final class ArtifactIndexFingerprintTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testIndexRoundTripsTheFingerprintItWasBuiltFrom() {
        let artifact = makeArtifact()

        ArtifactStore.writeIndex([artifact], fingerprint: "unified-v2#abc", to: indexURL)
        let loaded = ArtifactStore.loadIndex(indexURL)

        XCTAssertEqual(loaded.fingerprint, "unified-v2#abc")
        XCTAssertEqual(loaded.artifacts.map(\.id), [artifact.id])
    }

    func testIndexWrittenBeforeTheEnvelopeStillLoadsWithNoFingerprint() throws {
        let artifact = makeArtifact()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([artifact]).write(to: indexURL)

        let loaded = ArtifactStore.loadIndex(indexURL)

        XCTAssertNil(loaded.fingerprint)
        XCTAssertEqual(loaded.artifacts.map(\.id), [artifact.id])
    }

    func testMissingIndexLoadsEmpty() {
        let loaded = ArtifactStore.loadIndex(directory.appendingPathComponent("absent.json"))

        XCTAssertNil(loaded.fingerprint)
        XCTAssertTrue(loaded.artifacts.isEmpty)
    }

    func testRebuildIsToldTheFingerprintTheCatalogWasBuiltFrom() async {
        ArtifactStore.writeIndex([makeArtifact()], fingerprint: "stale", to: indexURL)
        let seen = Recorder()
        let store = makeStore(recording: seen)

        store.refresh()
        await settle(store)

        XCTAssertEqual(seen.fingerprints, ["stale"])
    }

    func testDeletionClearsTheFingerprintSoTheNextRebuildCannotReuseTheCatalog() async {
        let artifact = makeArtifact()
        ArtifactStore.writeIndex([artifact], fingerprint: "stale", to: indexURL)
        let seen = Recorder()
        let store = makeStore(recording: seen)

        store.delete(artifact)
        store.refresh()
        await settle(store)

        XCTAssertEqual(seen.fingerprints, [nil])
        XCTAssertNil(ArtifactStore.loadIndex(indexURL).fingerprint)
    }

    private final class Recorder: Sendable {
        private let state = Mutex<[String?]>([])

        var fingerprints: [String?] { state.withLock { $0 } }

        func record(_ fingerprint: String?) {
            state.withLock { $0.append(fingerprint) }
        }
    }

    private func makeStore(recording seen: Recorder) -> ArtifactStore {
        ArtifactStore(
            storage: locations(),
            refreshesAutomatically: false,
            rebuild: { _, _, known in
                seen.record(known.fingerprint)
                return known
            }
        )
    }

    private func settle(_ store: ArtifactStore) async {
        for _ in 0..<200 where store.isRefreshing {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private var indexURL: URL {
        directory.appendingPathComponent("Artifacts Index.json")
    }

    private func locations() -> ArtifactStore.StorageLocations {
        ArtifactStore.StorageLocations(
            indexURL: indexURL,
            cacheDirectory: directory.appendingPathComponent("Artifacts", isDirectory: true),
            favoritesURL: directory.appendingPathComponent("Artifact Favorites.json"),
            displayNamesURL: directory.appendingPathComponent("Artifact Names.json")
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
}
