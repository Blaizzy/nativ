import Foundation
import XCTest

final class LocalModelDiscoveryTests: XCTestCase {
    private var temporaryCache: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryCache = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryCache,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryCache)
        temporaryCache = nil
        try super.tearDownWithError()
    }

    func testDiscoversMageFlowComponentLayoutAsImageGenerationModel() async throws {
        try makeMageFlowSnapshot(repoID: "microsoft/Mage-Flow-Turbo")

        let models = try await LocalModelDiscovery.scan(
            path: temporaryCache.path
        )

        let model = try XCTUnwrap(models.first)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(model.repoID, "microsoft/Mage-Flow-Turbo")
        XCTAssertEqual(model.provider, .microsoft)
        XCTAssertTrue(model.capabilities.contains(.imageGeneration))
        XCTAssertFalse(model.capabilities.contains(.imageEditing))
    }

    func testDiscoversMageFlowEditComponentLayoutAsImageEditingModel() async throws {
        try makeMageFlowSnapshot(repoID: "microsoft/Mage-Flow-Edit-Turbo")

        let models = try await LocalModelDiscovery.scan(
            path: temporaryCache.path
        )

        let model = try XCTUnwrap(models.first)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(model.repoID, "microsoft/Mage-Flow-Edit-Turbo")
        XCTAssertEqual(model.provider, .microsoft)
        XCTAssertTrue(model.capabilities.contains(.imageEditing))
        XCTAssertFalse(model.capabilities.contains(.imageGeneration))
    }

    private func makeMageFlowSnapshot(repoID: String) throws {
        let repository = temporaryCache.appendingPathComponent(
            "models--" + repoID.replacingOccurrences(of: "/", with: "--"),
            isDirectory: true
        )
        let revision = "mage-flow-test-revision"
        let snapshot =
            repository
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)

        try write(revision, to: repository.appendingPathComponent("refs/main"))
        try writeJSON(
            [
                "_class_name": "MageFlowPipeline",
                "scheduler": [
                    "diffusers",
                    "FlowMatchEulerDiscreteScheduler",
                ],
                "text_encoder": [
                    "transformers",
                    "Qwen3VLForConditionalGeneration",
                ],
                "transformer": ["mage_flow", "MageFlow"],
                "vae": ["mage_flow", "MageVAE"],
            ],
            to: snapshot.appendingPathComponent("model_index.json")
        )
        for component in ["transformer", "text_encoder", "vae"] {
            try writeJSON(
                [:],
                to: snapshot.appendingPathComponent(
                    "\(component)/config.json"
                )
            )
            try write(
                "",
                to: snapshot.appendingPathComponent(
                    "\(component)/model.safetensors"
                )
            )
        }
        try write(
            "",
            to: snapshot.appendingPathComponent(
                "text_encoder/tokenizer.json"
            )
        )
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(string.utf8).write(to: url)
    }
}
