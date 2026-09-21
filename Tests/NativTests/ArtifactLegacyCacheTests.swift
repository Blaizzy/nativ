import XCTest

final class ArtifactLegacyCacheTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRemovesTheLegacyCacheAndRecordsTheMarker() throws {
        let cache = try makeLegacyCache(containing: "stale.png")
        let index = directory.appendingPathComponent("Artifacts Index.json")

        XCTAssertTrue(ArtifactStore.removeLegacyCache(cacheDirectory: cache, indexURL: index))

        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: ArtifactStore.legacyCacheMarkerURL(indexURL: index).path
            )
        )
    }

    func testDoesNotRunAgainOnceTheMarkerExists() throws {
        let cache = try makeLegacyCache(containing: "stale.png")
        let index = directory.appendingPathComponent("Artifacts Index.json")
        XCTAssertTrue(ArtifactStore.removeLegacyCache(cacheDirectory: cache, indexURL: index))

        let recreated = try makeLegacyCache(containing: "written-after-migration.png")

        XCTAssertFalse(ArtifactStore.removeLegacyCache(cacheDirectory: recreated, indexURL: index))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recreated.path))
    }

    func testSucceedsWhenThereIsNoLegacyCache() throws {
        let index = directory.appendingPathComponent("Artifacts Index.json")
        let missing = directory.appendingPathComponent("Artifacts", isDirectory: true)

        XCTAssertTrue(ArtifactStore.removeLegacyCache(cacheDirectory: missing, indexURL: index))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: ArtifactStore.legacyCacheMarkerURL(indexURL: index).path
            )
        )
    }

    private func makeLegacyCache(containing filename: String) throws -> URL {
        let cache = directory.appendingPathComponent("Artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: cache.appendingPathComponent(filename))
        return cache
    }
}
