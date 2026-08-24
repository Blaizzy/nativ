import XCTest

@MainActor
final class InferenceActivityCoordinatorTests: XCTestCase {
    func testSameResourceAllowsOnlyOneOperationAtATime() {
        let subject = InferenceActivityCoordinator()
        let resource = InferenceActivityCoordinator.Resource.chat(UUID())
        let windowID = UUID()
        let firstOperation = UUID()
        let secondOperation = UUID()

        XCTAssertTrue(subject.begin(
            resource: resource,
            windowID: windowID,
            operationID: firstOperation
        ))
        XCTAssertFalse(subject.begin(
            resource: resource,
            windowID: windowID,
            operationID: secondOperation
        ))

        subject.end(resource: resource, operationID: firstOperation)

        XCTAssertTrue(subject.begin(
            resource: resource,
            windowID: windowID,
            operationID: secondOperation
        ))
    }

    func testDifferentResourcesCanRunConcurrently() {
        let subject = InferenceActivityCoordinator()

        XCTAssertTrue(
            subject.begin(
                resource: .chat(UUID()),
                windowID: UUID(),
                operationID: UUID()
            )
        )
        XCTAssertTrue(
            subject.begin(
                resource: .imageGeneration(UUID()),
                windowID: UUID(),
                operationID: UUID()
            )
        )
    }

    func testOnlyOwningOperationCanReleaseResource() {
        let subject = InferenceActivityCoordinator()
        let resource = InferenceActivityCoordinator.Resource.chat(UUID())
        let owner = UUID()

        XCTAssertTrue(subject.begin(
            resource: resource,
            windowID: UUID(),
            operationID: owner
        ))
        subject.end(resource: resource, operationID: UUID())
        XCTAssertFalse(subject.begin(
            resource: resource,
            windowID: UUID(),
            operationID: UUID()
        ))

        subject.end(resource: resource, operationID: owner)
        XCTAssertTrue(subject.begin(
            resource: resource,
            windowID: UUID(),
            operationID: UUID()
        ))
    }

    func testReportsOwnershipOnlyToOtherWindows() {
        let subject = InferenceActivityCoordinator()
        let resource = InferenceActivityCoordinator.Resource.chat(UUID())
        let ownerWindowID = UUID()

        XCTAssertTrue(subject.begin(
            resource: resource,
            windowID: ownerWindowID,
            operationID: UUID()
        ))
        XCTAssertFalse(subject.isOwnedByAnotherWindow(resource, windowID: ownerWindowID))
        XCTAssertTrue(subject.isOwnedByAnotherWindow(resource, windowID: UUID()))
    }

    func testReportsWhetherAnyInferenceIsActive() {
        let subject = InferenceActivityCoordinator()
        let resource = InferenceActivityCoordinator.Resource.chat(UUID())
        let operationID = UUID()

        XCTAssertFalse(subject.hasActiveOperations)
        XCTAssertTrue(subject.begin(
            resource: resource,
            windowID: UUID(),
            operationID: operationID
        ))
        XCTAssertTrue(subject.hasActiveOperations)

        subject.end(resource: resource, operationID: operationID)

        XCTAssertFalse(subject.hasActiveOperations)
    }

    func testModelSwitchIsBlockedWhileInferenceIsActive() {
        let coordinator = InferenceActivityCoordinator()
        let model = NativModel()
        let originalModelID = model.settings.normalized().languageModelID
        let resource = InferenceActivityCoordinator.Resource.chat(UUID())
        let operationID = UUID()
        model.observeInferenceActivity(coordinator)

        XCTAssertTrue(coordinator.begin(
            resource: resource,
            windowID: UUID(),
            operationID: operationID
        ))
        XCTAssertTrue(model.inferenceActivityInProgress)

        model.switchLanguageModel(to: "nativ-tests/model-switch-must-stay-blocked")

        XCTAssertEqual(model.settings.normalized().languageModelID, originalModelID)

        coordinator.end(resource: resource, operationID: operationID)
        XCTAssertFalse(model.inferenceActivityInProgress)
    }
}

final class SystemMonitorObservationPolicyTests: XCTestCase {
    func testSamplingStartsForFirstObserverAndStopsAfterLastObserver() {
        var policy = SystemMonitorObservationPolicy()
        let first = UUID()
        let second = UUID()

        XCTAssertTrue(policy.begin(first))
        XCTAssertFalse(policy.begin(second))
        XCTAssertFalse(policy.end(first))
        XCTAssertTrue(policy.end(second))
    }

    func testDuplicateObservationEventsAreIdempotent() {
        var policy = SystemMonitorObservationPolicy()
        let observer = UUID()

        XCTAssertTrue(policy.begin(observer))
        XCTAssertFalse(policy.begin(observer))
        XCTAssertTrue(policy.end(observer))
        XCTAssertFalse(policy.end(observer))
    }

    func testPausedObservationRestartsOnlyWhenAnObserverRemains() {
        var policy = SystemMonitorObservationPolicy()
        let observer = UUID()

        XCTAssertTrue(policy.begin(observer))
        XCTAssertTrue(policy.pause())
        XCTAssertFalse(policy.pause())
        XCTAssertTrue(policy.resume())

        XCTAssertTrue(policy.pause())
        XCTAssertFalse(policy.end(observer))
        XCTAssertFalse(policy.resume())
    }
}

@MainActor
final class MultiWindowArtifactDeletionTests: XCTestCase {
    func testLockedImageSessionRejectsOutputRemoval() {
        let inferenceActivity = InferenceActivityCoordinator()
        let sessionID = UUID()
        let ownerWindowID = UUID()
        let operationID = UUID()
        let viewModel = ImageGenerationViewModel(
            windowID: UUID(),
            inferenceActivity: inferenceActivity
        )

        XCTAssertTrue(inferenceActivity.begin(
            resource: .imageGeneration(sessionID),
            windowID: ownerWindowID,
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
            cacheDirectory: temporaryDirectory.appendingPathComponent("Artifacts", isDirectory: true),
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
