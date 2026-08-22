import Foundation
import XCTest

final class LocalModelDiscoveryTests: XCTestCase {
    private var temporaryCache: URL!

    private var searchPaths: LocalModelSearchPaths {
        LocalModelSearchPaths(primary: temporaryCache.path)
    }

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

        let models = try await LocalModelDiscovery.scan(searchPaths: searchPaths)

        let model = try XCTUnwrap(models.first)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(model.repoID, "microsoft/Mage-Flow-Turbo")
        XCTAssertEqual(model.provider, .microsoft)
        XCTAssertTrue(model.capabilities.contains(.imageGeneration))
        XCTAssertFalse(model.capabilities.contains(.imageEditing))
    }

    func testDiscoversMageFlowEditComponentLayoutAsImageEditingModel() async throws {
        try makeMageFlowSnapshot(repoID: "microsoft/Mage-Flow-Edit-Turbo")

        let models = try await LocalModelDiscovery.scan(searchPaths: searchPaths)

        let model = try XCTUnwrap(models.first)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(model.repoID, "microsoft/Mage-Flow-Edit-Turbo")
        XCTAssertEqual(model.provider, .microsoft)
        XCTAssertTrue(model.capabilities.contains(.imageEditing))
        XCTAssertFalse(model.capabilities.contains(.imageGeneration))
    }

    func testDiscoversModelFromAdditionalSearchFolder() async throws {
        let externalModel = temporaryCache.appendingPathComponent(
            "external/owner/model",
            isDirectory: true
        )
        try writeJSON(
            ["model_type": "qwen3", "architectures": ["Qwen3ForCausalLM"]],
            to: externalModel.appendingPathComponent("config.json")
        )
        try write("weights", to: externalModel.appendingPathComponent("model.safetensors"))

        let models = try await LocalModelDiscovery.scan(
            searchPaths: LocalModelSearchPaths(
                primary: temporaryCache.path,
                additional: [externalModel.path]
            )
        )

        let model = try XCTUnwrap(models.first { $0.repoID == externalModel.standardizedFileURL.path })
        XCTAssertEqual(model.source, .external)
        XCTAssertTrue(model.capabilities.contains(.text))
    }

    func testClassifiesEncoderWithPoolingAsEmbeddingModel() async throws {
        try makeTextModelSnapshot(
            repoID: "org/xlm-roberta-embed",
            modelType: "xlm_roberta",
            architectures: ["XLMRobertaModel"],
            sentenceTransformer: true
        )

        let models = try await LocalModelDiscovery.scan(searchPaths: searchPaths)
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

        let models = try await LocalModelDiscovery.scan(searchPaths: searchPaths)
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

        let models = try await LocalModelDiscovery.scan(searchPaths: searchPaths)
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

        let models = try await LocalModelDiscovery.scan(searchPaths: searchPaths)
        let model = try XCTUnwrap(models.first)
        XCTAssertTrue(model.capabilities.contains(.embeddings))
    }

    func testRequiresEveryShardReferencedBySafetensorsIndex() async throws {
        try makeShardedTextModelSnapshot(
            repoID: "org/incomplete-sharded-model",
            shardFilenames: [
                "model-00001-of-00002.safetensors",
                "model-00002-of-00002.safetensors",
            ],
            availableShardFilenames: ["model-00001-of-00002.safetensors"]
        )
        try makeShardedTextModelSnapshot(
            repoID: "org/complete-sharded-model",
            shardFilenames: [
                "model-00001-of-00002.safetensors",
                "model-00002-of-00002.safetensors",
            ],
            availableShardFilenames: [
                "model-00001-of-00002.safetensors",
                "model-00002-of-00002.safetensors",
            ]
        )

        let models = try await LocalModelDiscovery.scan(searchPaths: searchPaths)

        XCTAssertFalse(models.contains { $0.repoID == "org/incomplete-sharded-model" })
        XCTAssertTrue(models.contains { $0.repoID == "org/complete-sharded-model" })
    }

    func testRejectsMalformedOrEmptySafetensorsIndex() async throws {
        try makeShardedTextModelSnapshot(
            repoID: "org/malformed-index",
            shardFilenames: ["model-00001-of-00001.safetensors"],
            availableShardFilenames: ["model-00001-of-00001.safetensors"]
        )
        try write(
            "{ not valid JSON",
            to: snapshotURL(repoID: "org/malformed-index")
                .appendingPathComponent("model.safetensors.index.json")
        )

        try makeShardedTextModelSnapshot(
            repoID: "org/empty-index",
            shardFilenames: ["model-00001-of-00001.safetensors"],
            availableShardFilenames: ["model-00001-of-00001.safetensors"]
        )
        let emptyIndex: [String: [String: String]] = ["weight_map": [:]]
        try writeJSON(
            emptyIndex,
            to: snapshotURL(repoID: "org/empty-index")
                .appendingPathComponent("model.safetensors.index.json")
        )

        let models = try await LocalModelDiscovery.scan(searchPaths: searchPaths)

        XCTAssertFalse(models.contains { $0.repoID == "org/malformed-index" })
        XCTAssertFalse(models.contains { $0.repoID == "org/empty-index" })
    }

    func testAcceptsCompletedHuggingFaceShardSymlinks() async throws {
        let repoID = "org/symlinked-sharded-model"
        let shardFilename = "model-00001-of-00001.safetensors"
        try makeShardedTextModelSnapshot(
            repoID: repoID,
            shardFilenames: [shardFilename],
            availableShardFilenames: []
        )

        let snapshot = snapshotURL(repoID: repoID)
        let repository = snapshot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let blobURL = repository.appendingPathComponent("blobs/completed-shard")
        try write("weights", to: blobURL)
        try FileManager.default.createSymbolicLink(
            at: snapshot.appendingPathComponent(shardFilename),
            withDestinationURL: blobURL
        )

        let models = try await LocalModelDiscovery.scan(searchPaths: searchPaths)

        XCTAssertTrue(models.contains { $0.repoID == repoID })
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

    func testSpeechToTextPreloadIssueFlagsMissingPreprocessorConfig() throws {
        let repoID = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
        try makeSpeechSnapshot(
            repoID: repoID,
            modelType: "qwen3_asr",
            includesPreprocessorConfig: false
        )

        let issue = LocalModelDiscovery.speechToTextPreloadIssue(
            repoID: repoID,
            path: temporaryCache.path
        )

        let message = try XCTUnwrap(issue)
        XCTAssertTrue(message.contains("preprocessor_config.json"))
        XCTAssertTrue(message.contains(repoID))
    }

    func testSpeechToTextPreloadIssueAcceptsCompleteSnapshot() throws {
        let repoID = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        try makeSpeechSnapshot(
            repoID: repoID,
            modelType: "qwen3_asr",
            includesPreprocessorConfig: true
        )

        XCTAssertNil(
            LocalModelDiscovery.speechToTextPreloadIssue(
                repoID: repoID,
                path: temporaryCache.path
            )
        )
    }

    func testSpeechToTextPreloadIssueIgnoresModelTypesWithoutPreprocessor() throws {
        let repoID = "mlx-community/whisper-tiny"
        try makeSpeechSnapshot(
            repoID: repoID,
            modelType: "whisper",
            includesPreprocessorConfig: false
        )

        XCTAssertNil(
            LocalModelDiscovery.speechToTextPreloadIssue(
                repoID: repoID,
                path: temporaryCache.path
            )
        )
    }

    func testSpeechToTextPreloadIssueIgnoresUnknownModel() {
        XCTAssertNil(
            LocalModelDiscovery.speechToTextPreloadIssue(
                repoID: "nobody/not-installed",
                path: temporaryCache.path
            )
        )
    }

    private func makeSpeechSnapshot(
        repoID: String,
        modelType: String,
        includesPreprocessorConfig: Bool
    ) throws {
        let repository = temporaryCache.appendingPathComponent(
            "models--" + repoID.replacingOccurrences(of: "/", with: "--"),
            isDirectory: true
        )
        let revision = "speech-test-revision"
        let snapshot =
            repository
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)

        try write(revision, to: repository.appendingPathComponent("refs/main"))
        try writeJSON(
            ["model_type": modelType, "architectures": ["Qwen3ASRForConditionalGeneration"]],
            to: snapshot.appendingPathComponent("config.json")
        )
        if includesPreprocessorConfig {
            try writeJSON(
                ["feature_extractor_type": "WhisperFeatureExtractor"],
                to: snapshot.appendingPathComponent("preprocessor_config.json")
            )
        }
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

    private func makeShardedTextModelSnapshot(
        repoID: String,
        shardFilenames: [String],
        availableShardFilenames: Set<String>
    ) throws {
        let snapshot = snapshotURL(repoID: repoID)
        let repository = snapshot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let revision = snapshot.lastPathComponent

        try write(revision, to: repository.appendingPathComponent("refs/main"))
        try writeJSON(
            ["model_type": "qwen3", "architectures": ["Qwen3ForCausalLM"]],
            to: snapshot.appendingPathComponent("config.json")
        )

        var weightMap: [String: String] = [:]
        for (index, filename) in shardFilenames.enumerated() {
            weightMap["model.layers.\(index).weight"] = filename
            if availableShardFilenames.contains(filename) {
                try write("weights", to: snapshot.appendingPathComponent(filename))
            }
        }
        try writeJSON(
            ["weight_map": weightMap],
            to: snapshot.appendingPathComponent("model.safetensors.index.json")
        )
    }

    private func snapshotURL(repoID: String) -> URL {
        temporaryCache
            .appendingPathComponent(
                "models--" + repoID.replacingOccurrences(of: "/", with: "--"),
                isDirectory: true
            )
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("test-revision", isDirectory: true)
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

    func testDrafterKindDetection() {
        XCTAssertEqual(LocalModelDiscovery.drafterKind(fromModelType: "qwen3_5_mtp"), "mtp")
        XCTAssertEqual(LocalModelDiscovery.drafterKind(fromModelType: "gemma4_assistant"), "mtp")
        XCTAssertEqual(LocalModelDiscovery.drafterKind(fromModelType: "eagle3"), "eagle3")
        XCTAssertEqual(LocalModelDiscovery.drafterKind(fromModelType: "qwen3_dflash"), "dflash")
        XCTAssertEqual(LocalModelDiscovery.drafterKind(fromModelType: "llama_eagle"), "eagle3")
        XCTAssertNil(LocalModelDiscovery.drafterKind(fromModelType: "qwen3_5"))
        XCTAssertNil(LocalModelDiscovery.drafterKind(fromModelType: nil))
        XCTAssertNil(LocalModelDiscovery.drafterKind(fromModelType: ""))
    }

    func testDrafterExcludedFromLanguageModelPicker() {
        let drafter = makeModel(
            repoID: "mlx-community/Qwen3.5-4B-MTP-4bit",
            capabilities: [.text, .drafter]
        )
        let chatModel = makeModel(
            repoID: "mlx-community/Qwen3.5-4B-MLX-4bit",
            capabilities: [.text]
        )
        XCTAssertFalse(drafter.isEligibleForLanguageModelPicker)
        XCTAssertTrue(chatModel.isEligibleForLanguageModelPicker)
    }

    func testMTPSnapshotScansAsIneligibleDrafter() async throws {
        // A real MTP checkpoint (model_type qwen3_5_mtp) must surface both the
        // .text and .drafter capabilities: it is a language-model family member,
        // but chat model pickers must keep it out via isEligibleForLanguageModelPicker.
        try makeTextModelSnapshot(
            repoID: "mlx-community/Qwen3.8-27B-MTP-8bit",
            modelType: "qwen3_5_mtp",
            architectures: ["Qwen3_5MTPDraftModel"],
            sentenceTransformer: false
        )

        let models = try await LocalModelDiscovery.scan(searchPaths: searchPaths)
        let mtp = try XCTUnwrap(models.first)
        XCTAssertTrue(mtp.capabilities.contains(.text))
        XCTAssertTrue(mtp.capabilities.contains(.drafter))
        XCTAssertEqual(mtp.drafterKind, "mtp")
        XCTAssertFalse(mtp.isEligibleForLanguageModelPicker)
    }

    func testRerankerIsClassifiedAndExcludedFromLanguageModelPicker() async throws {
        try makeTextModelSnapshot(
            repoID: "mlx-community/Qwen3-Reranker-0.6B-mxfp8",
            modelType: "qwen3",
            architectures: ["Qwen3ForCausalLM"],
            sentenceTransformer: false
        )

        let models = try await LocalModelDiscovery.scan(searchPaths: searchPaths)
        let reranker = try XCTUnwrap(models.first)
        XCTAssertTrue(reranker.capabilities.contains(.reranking))
        XCTAssertFalse(reranker.isEligibleForLanguageModelPicker)
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
            capabilities: capabilities,
            drafterKind: nil,
            hiddenSize: nil
        )
    }
}
