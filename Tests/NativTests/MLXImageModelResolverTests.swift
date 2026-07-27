import Foundation
import NativServerKit
import XCTest

final class MLXImageModelResolverTests: XCTestCase {
    private let supportedModelTypes: Set<String> = [
        "bonsai",
        "flux2",
        "ideogram4",
        "mage_flow",
    ]
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryRoot)
        temporaryRoot = nil
        try super.tearDownWithError()
    }

    func testDiffusionGemmaIsNotImageGenerationModel() throws {
        try writeJSON(
            [
                "architectures": ["DiffusionGemmaForBlockDiffusion"],
                "model_type": "diffusion_gemma",
                "text_config": ["model_type": "diffusion_gemma_text"],
                "vision_config": ["model_type": "gemma4_vision"],
            ],
            to: "config.json"
        )
        try touch("model.safetensors")

        XCTAssertFalse(
            resolver().isImageGenerationModel(
                model: "google/diffusion-gemma-2b-it",
                at: temporaryRoot,
                fileManager: .default
            )
        )
    }

    func testFlux2PipelineMetadataResolvesToImageGeneration() throws {
        try makeCompleteFlux2Fixture()

        XCTAssertTrue(
            resolver().isImageGenerationModel(
                model: "black-forest-labs/FLUX.2-klein-9B-kv",
                at: temporaryRoot,
                fileManager: .default
            )
        )
    }

    func testFlux2RequiresLoadableLocalLayout() throws {
        try makeCompleteFlux2Fixture()
        try FileManager.default.removeItem(
            at: temporaryRoot.appendingPathComponent(
                "text_encoder/model.safetensors"
            )
        )

        XCTAssertFalse(
            resolver().isImageGenerationModel(
                model: "black-forest-labs/FLUX.2-klein-9B-kv",
                at: temporaryRoot,
                fileManager: .default
            )
        )
    }

    func testFlux1IsNotAcceptedByFlux2Backend() throws {
        try writeJSON(
            [
                "_class_name": "FluxPipeline",
                "transformer": ["diffusers", "FluxTransformer2DModel"],
            ],
            to: "model_index.json"
        )
        try touch("model.safetensors")

        XCTAssertFalse(
            resolver().isImageGenerationModel(
                model: "black-forest-labs/FLUX.1-dev",
                at: temporaryRoot,
                fileManager: .default
            )
        )
    }

    func testMageFlowFamilyResolvesToImageGeneration() throws {
        try makeCompleteMageFlowFixture()

        for model in [
            "microsoft/Mage-Flow-Base",
            "microsoft/Mage-Flow",
            "microsoft/Mage-Flow-Turbo",
        ] {
            XCTAssertTrue(
                resolver().isImageGenerationModel(
                    model: model,
                    at: temporaryRoot,
                    fileManager: .default
                ),
                model
            )
            XCTAssertFalse(
                resolver().isImageEditingModel(
                    model: model,
                    at: temporaryRoot,
                    fileManager: .default
                ),
                model
            )
        }
    }

    func testMageFlowEditFamilyResolvesToImageEditingOnly() throws {
        try makeCompleteMageFlowFixture()

        for model in [
            "microsoft/Mage-Flow-Edit-Base",
            "microsoft/Mage-Flow-Edit",
            "microsoft/Mage-Flow-Edit-Turbo",
        ] {
            XCTAssertTrue(
                resolver().isSupportedImageModel(
                    model: model,
                    at: temporaryRoot,
                    fileManager: .default
                ),
                model
            )
            XCTAssertTrue(
                resolver().isImageEditingModel(
                    model: model,
                    at: temporaryRoot,
                    fileManager: .default
                ),
                model
            )
            XCTAssertFalse(
                resolver().isImageGenerationModel(
                    model: model,
                    at: temporaryRoot,
                    fileManager: .default
                ),
                model
            )
        }
    }

    func testMageFlowRequiresLoadableLocalLayout() throws {
        try makeCompleteMageFlowFixture()
        try FileManager.default.removeItem(
            at: temporaryRoot.appendingPathComponent(
                "text_encoder/tokenizer.json"
            )
        )

        XCTAssertFalse(
            resolver().isImageGenerationModel(
                model: "microsoft/Mage-Flow",
                at: temporaryRoot,
                fileManager: .default
            )
        )
    }

    func testBundledManifestGatesMetadataCandidates() throws {
        try makeCompleteFlux2Fixture()
        let resolver = MLXImageModelResolver(supportedModelTypes: [])

        XCTAssertFalse(
            resolver.isImageGenerationModel(
                model: "black-forest-labs/FLUX.2-klein-9B-kv",
                at: temporaryRoot,
                fileManager: .default
            )
        )
    }

    func testBundledManifestDescribesInstalledBackends() throws {
        let modelTypes = try Nativ.imageGenerationModelTypes()

        XCTAssertTrue(modelTypes.contains("flux2"))
        XCTAssertTrue(modelTypes.contains("mage_flow"))
        XCTAssertFalse(modelTypes.contains("diffusion_gemma"))
    }

    private func resolver() -> MLXImageModelResolver {
        MLXImageModelResolver(supportedModelTypes: supportedModelTypes)
    }

    private func makeCompleteFlux2Fixture() throws {
        try writeJSON(
            [
                "_class_name": "Flux2KleinPipeline",
                "scheduler": [
                    "diffusers",
                    "FlowMatchEulerDiscreteScheduler",
                ],
                "text_encoder": ["transformers", "Qwen3ForCausalLM"],
                "transformer": ["diffusers", "Flux2Transformer2DModel"],
                "vae": ["diffusers", "AutoencoderKLFlux2"],
            ],
            to: "model_index.json"
        )
        try touch("transformer/model.safetensors")
        try touch("text_encoder/model.safetensors")
        try touch("vae/model.safetensors")
        try touch("tokenizer/tokenizer.json")
    }

    private func makeCompleteMageFlowFixture() throws {
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
            to: "model_index.json"
        )
        for component in ["transformer", "text_encoder", "vae"] {
            try writeJSON([:], to: "\(component)/config.json")
            try touch("\(component)/model.safetensors")
        }
        try touch("text_encoder/tokenizer.json")
    }

    private func writeJSON(_ object: Any, to path: String) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        let url = temporaryRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func touch(_ path: String) throws {
        let url = temporaryRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
    }
}
