import XCTest

@MainActor
final class ArtifactDeletionTests: XCTestCase {
    func testLockedImageSessionRejectsOutputRemoval() {
        let inferenceActivity = InferenceActivityCoordinator()
        let sessionID = UUID()
        let operationID = UUID()
        let viewModel = ImageGenerationViewModel(
            windowID: UUID(),
            inferenceActivity: inferenceActivity
        )

        XCTAssertTrue(inferenceActivity.begin(
            resource: .imageGeneration(sessionID),
            windowID: UUID(),
            operationID: operationID
        ))

        XCTAssertFalse(viewModel.removeOutput(
            sessionID: sessionID,
            turnID: UUID(),
            outputID: UUID()
        ))
    }

    func testBatchDeletionPreservesArtifactsRejectedByHistory() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let storage = ArtifactStore.StorageLocations(
            indexURL: temporaryDirectory.appendingPathComponent("Artifacts Index.json"),
            cacheDirectory: temporaryDirectory.appendingPathComponent(
                "Artifacts",
                isDirectory: true
            ),
            favoritesURL: temporaryDirectory.appendingPathComponent("Artifact Favorites.json"),
            displayNamesURL: temporaryDirectory.appendingPathComponent("Artifact Names.json")
        )
        let allowed = makeArtifact(filename: "allowed.png")
        let rejected = makeArtifact(filename: "rejected.png")
        try writeArtifacts([allowed, rejected], to: storage.indexURL)
        try writeArtifactFile(allowed, storage: storage)
        try writeArtifactFile(rejected, storage: storage)

        let store = ArtifactStore(
            storage: storage,
            refreshesAutomatically: false,
            deletionHandler: { $0.id == allowed.id }
        )

        let deletedIDs = store.delete([allowed, rejected])

        XCTAssertEqual(deletedIDs, Set([allowed.id]))
        XCTAssertEqual(store.artifacts.map(\.id), [rejected.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: allowed).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: rejected).path))
        XCTAssertEqual(try loadArtifacts(from: storage.indexURL).map(\.id), [rejected.id])
    }

    private func makeArtifact(filename: String) -> Artifact {
        let id = UUID()
        return Artifact(
            id: id,
            kind: .image,
            source: .generated,
            sessionID: UUID(),
            messageID: UUID(),
            filename: filename,
            mimeType: "image/png",
            relativePath: "image/\(id.uuidString).png",
            byteSize: 1,
            createdAt: .now,
            prompt: nil,
            sessionTitle: "Test session"
        )
    }

    private func writeArtifactFile(
        _ artifact: Artifact,
        storage: ArtifactStore.StorageLocations
    ) throws {
        let url = storage.cacheDirectory.appendingPathComponent(artifact.relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0]).write(to: url)
    }

    private func writeArtifacts(_ artifacts: [Artifact], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(artifacts).write(to: url)
    }

    private func loadArtifacts(from url: URL) throws -> [Artifact] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Artifact].self, from: Data(contentsOf: url))
    }
}
