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

    func testClassifiesEncoderWithPoolingAsEmbeddingModel() async throws {
        try makeTextModelSnapshot(
            repoID: "org/xlm-roberta-embed",
            modelType: "xlm_roberta",
            architectures: ["XLMRobertaModel"],
            sentenceTransformer: true
        )

        let models = try await LocalModelDiscovery.scan(path: temporaryCache.path)
        let model = try XCTUnwrap(models.first)
        XCTAssertTrue(model.capabilities.contains(.embeddings))
    }

    func testDoesNotClassifyCausalLanguageModelAsEmbeddingModel() async throws {
        try makeTextModelSnapshot(
            repoID: "org/qwen3-chat",
            modelType: "qwen3",
            architectures: ["Qwen3ForCausalLM"],
            sentenceTransformer: false
        )

        let models = try await LocalModelDiscovery.scan(path: temporaryCache.path)
        let model = try XCTUnwrap(models.first)
        XCTAssertFalse(model.capabilities.contains(.embeddings))
        XCTAssertTrue(model.capabilities.contains(.text))
    }

    func testClassifiesLLMBasedEmbedderWithPoolingAsEmbeddingModel() async throws {
        try makeTextModelSnapshot(
            repoID: "org/qwen3-embedding",
            modelType: "qwen3",
            architectures: ["Qwen3ForCausalLM"],
            sentenceTransformer: true
        )

        let models = try await LocalModelDiscovery.scan(path: temporaryCache.path)
        let model = try XCTUnwrap(models.first)
        XCTAssertTrue(model.capabilities.contains(.embeddings))
    }

    func testClassifiesStampedModelAsEmbeddingModel() async throws {
        try makeTextModelSnapshot(
            repoID: "org/stamped-embedding",
            modelType: "qwen3",
            architectures: ["Qwen3ForCausalLM"],
            sentenceTransformer: false,
            stamp: ["kind": "embedding", "modality": "text"]
        )

        let models = try await LocalModelDiscovery.scan(path: temporaryCache.path)
        let model = try XCTUnwrap(models.first)
        XCTAssertTrue(model.capabilities.contains(.embeddings))
    }

    func testSelectsAnyInstalledSpeechToTextModelWithoutKnownModelNames() {
        let models = [
            makeModel(repoID: "owner/text-only", capabilities: [.text]),
            makeModel(repoID: "owner/zeta-custom-listener", capabilities: [.speechToText]),
            makeModel(repoID: "owner/alpha-custom-listener", capabilities: [.speechToText]),
        ]

        XCTAssertEqual(
            LocalModelDiscovery.speechToTextModelID(
                in: models,
                selectedModelID: nil
            ),
            "owner/alpha-custom-listener"
        )
    }

    func testUsesSelectedSpeechModelOnlyWhenItIsInstalledAndCompatible() {
        let models = [
            makeModel(repoID: "owner/alpha-listener", capabilities: [.speechToText]),
            makeModel(repoID: "owner/user-choice", capabilities: [.speechToText]),
        ]

        XCTAssertEqual(
            LocalModelDiscovery.speechToTextModelID(
                in: models,
                selectedModelID: "owner/user-choice"
            ),
            "owner/user-choice"
        )
        XCTAssertEqual(
            LocalModelDiscovery.speechToTextModelID(
                in: models,
                selectedModelID: "owner/not-installed"
            ),
            "owner/alpha-listener"
        )
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

    private func makeTextModelSnapshot(
        repoID: String,
        modelType: String,
        architectures: [String],
        sentenceTransformer: Bool,
        stamp: [String: String]? = nil
    ) throws {
        let repository = temporaryCache.appendingPathComponent(
            "models--" + repoID.replacingOccurrences(of: "/", with: "--"),
            isDirectory: true
        )
        let revision = "text-model-test-revision"
        let snapshot =
            repository
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)

        try write(revision, to: repository.appendingPathComponent("refs/main"))
        var config: [String: Any] = [
            "model_type": modelType, "architectures": architectures,
        ]
        if let stamp {
            config["mlx_embeddings"] = stamp
        }
        try writeJSON(config, to: snapshot.appendingPathComponent("config.json"))
        try write("", to: snapshot.appendingPathComponent("model.safetensors"))
        if sentenceTransformer {
            try writeJSON(
                ["pooling_mode_mean_tokens": true, "word_embedding_dimension": 768],
                to: snapshot.appendingPathComponent("1_Pooling/config.json")
            )
        }
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

    private func makeModel(
        repoID: String,
        capabilities: Set<LocalModelCapability>
    ) -> LocalModel {
        LocalModel(
            repoID: repoID,
            snapshotURL: nil,
            modifiedAt: nil,
            sizeBytes: nil,
            parameterCount: nil,
            quantizationBits: nil,
            quantizationGroupSize: nil,
            contextSize: nil,
            provider: nil,
            capabilities: capabilities
        )
    }
}
