import Foundation
import NativServerKit
import XCTest

final class MLXImageModelResolverTests: XCTestCase {
    private let generationModelTypes: Set<String> = [
        "bonsai",
        "ernie_image",
        "flux2",
        "flux3",
        "ideogram4",
        "llada_image",
        "mage_flow",
        "moss_image",
        "qwen_image",
        "z_image",
    ]
    private let editingModelTypes: Set<String> = [
        "ernie_image",
        "flux2",
        "flux3",
        "llada_image",
        "mage_flow",
        "qwen_image",
        "z_image",
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
                model: "black-forest-labs/FLUX.2-klein-4B",
                at: temporaryRoot,
                fileManager: .default
            )
        )
        XCTAssertTrue(
            resolver().isImageEditingModel(
                model: "black-forest-labs/FLUX.2-klein-4B",
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

    func testFlux3RootPackageResolvesToGenerationAndEditing() throws {
        try makeCompleteFlux3Fixture()

        for model in [
            "black-forest-labs/flux-3-image-klein",
            "black-forest-labs/flux-3-image-klein-base",
            "black-forest-labs/FLUX.3-klein",
            "flux3-klein",
            "local/renamed-checkpoint",
        ] {
            XCTAssertTrue(
                resolver().isImageGenerationModel(
                    model: model, at: temporaryRoot, fileManager: .default),
                model
            )
            XCTAssertTrue(
                resolver().isImageEditingModel(
                    model: model, at: temporaryRoot, fileManager: .default),
                model
            )
        }
    }

    func testFlux3RequiresCompleteRootPackage() throws {
        for missingFile in [
            "config.json", "model.safetensors", "ae.safetensors",
            "text_encoder/config.json", "text_encoder/tokenizer.json",
            "text_encoder/model-00001-of-00001.safetensors",
        ] {
            try makeCompleteFlux3Fixture()
            try FileManager.default.removeItem(
                at: temporaryRoot.appendingPathComponent(missingFile))

            XCTAssertFalse(
                resolver().isSupportedImageModel(
                    model: "black-forest-labs/flux-3-image-klein",
                    at: temporaryRoot,
                    fileManager: .default
                ),
                missingFile
            )
        }
    }

    func testFlux3RejectsUnsupportedQuantizedPackage() throws {
        try makeCompleteFlux3Fixture()
        let configURL = temporaryRoot.appendingPathComponent("config.json")
        var metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        )
        metadata["quantization"] = ["mode": "nvfp4"]
        try writeJSON(metadata, to: "config.json")

        XCTAssertFalse(
            resolver().isSupportedImageModel(
                model: "black-forest-labs/flux-3-image-klein",
                at: temporaryRoot,
                fileManager: .default
            )
        )
    }

    func testFlux3DiffusersLayoutIsNotAcceptedByFlux2Backend() throws {
        try makeCompleteFlux2Fixture()
        try writeJSON(
            [
                "_class_name": "Flux3ModularPipeline",
                "transformer": ["diffusers", "Flux3Transformer2DModel"],
                "vae": ["diffusers", "AutoencoderKLFlux2"],
            ],
            to: "model_index.json"
        )
        try writeJSON(["_class_name": "AutoencoderKLFlux2"], to: "vae/config.json")

        XCTAssertFalse(
            resolver().isSupportedImageModel(
                model: "black-forest-labs/flux-3-image-klein",
                at: temporaryRoot,
                fileManager: .default
            )
        )
    }

    func testMOSSImagePipelineResolvesToGenerationOnly() throws {
        try makeCompleteMOSSImageFixture()

        for model in [
            "OpenMOSS-Team/MOSS-Image-Base",
            "OpenMOSS-Team/MOSS-Image-SFT",
            "mlx-community/MOSS-Image-SFT-bf16",
            "local/renamed-checkpoint",
        ] {
            XCTAssertTrue(
                resolver().isImageGenerationModel(
                    model: model, at: temporaryRoot, fileManager: .default),
                model
            )
            XCTAssertFalse(
                resolver().isImageEditingModel(
                    model: model, at: temporaryRoot, fileManager: .default),
                model
            )
        }
    }

    func testMOSSImageRequiresCompleteComponentLayout() throws {
        for missingFile in [
            "model_index.json", "scheduler/scheduler_config.json", "tokenizer/tokenizer.json",
            "transformer/config.json", "transformer/model.safetensors",
            "text_encoder/config.json", "text_encoder/model.safetensors",
            "vae/config.json", "vae/model.safetensors",
        ] {
            try makeCompleteMOSSImageFixture()
            try FileManager.default.removeItem(
                at: temporaryRoot.appendingPathComponent(missingFile))

            XCTAssertFalse(
                resolver().isSupportedImageModel(
                    model: "OpenMOSS-Team/MOSS-Image-SFT",
                    at: temporaryRoot,
                    fileManager: .default
                ),
                missingFile
            )
        }
    }

    func testMOSSImageNameDoesNotAcceptLanguageModelLayout() throws {
        try writeJSON(["model_type": "moss"], to: "config.json")
        try touch("model.safetensors")

        XCTAssertFalse(
            resolver().isSupportedImageModel(
                model: "OpenMOSS-Team/MOSS-Image-SFT",
                at: temporaryRoot,
                fileManager: .default
            )
        )
    }

    func testBundledManifestGatesNewImageBackends() throws {
        let resolver = MLXImageModelResolver(
            generationModelTypes: ["flux2"],
            editingModelTypes: ["flux2"]
        )
        try makeCompleteFlux3Fixture()
        XCTAssertFalse(
            resolver.isSupportedImageModel(
                model: "black-forest-labs/flux-3-image-klein",
                at: temporaryRoot,
                fileManager: .default
            )
        )
        try FileManager.default.removeItem(at: temporaryRoot)
        try makeCompleteMOSSImageFixture()
        XCTAssertFalse(
            resolver.isSupportedImageModel(
                model: "OpenMOSS-Team/MOSS-Image-SFT",
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

    func testQwenImagePipelineResolvesToImageGeneration() throws {
        try makeCompleteQwenImageFixture()

        XCTAssertTrue(
            resolver().isImageGenerationModel(
                model: "Qwen/Qwen-Image-2.1",
                at: temporaryRoot,
                fileManager: .default
            )
        )
        XCTAssertTrue(
            resolver().isImageEditingModel(
                model: "Qwen/Qwen-Image-2.1",
                at: temporaryRoot,
                fileManager: .default
            )
        )
    }

    func testLLaDAImagePipelineResolvesToGenerationAndEditing() throws {
        try makeCompleteLLaDAImageFixture()

        XCTAssertTrue(
            resolver().isImageGenerationModel(
                model: "inclusionAI/LLaDA-Image-Turbo",
                at: temporaryRoot,
                fileManager: .default
            )
        )
        XCTAssertTrue(
            resolver().isImageEditingModel(
                model: "inclusionAI/LLaDA-Image-Turbo",
                at: temporaryRoot,
                fileManager: .default
            )
        )
    }

    func testLLaDAImageRequiresLoadableLocalLayout() throws {
        try makeCompleteLLaDAImageFixture()
        try FileManager.default.removeItem(
            at: temporaryRoot.appendingPathComponent(
                "queryformer/model.safetensors"
            )
        )

        XCTAssertFalse(
            resolver().isImageGenerationModel(
                model: "inclusionAI/LLaDA-Image-Turbo",
                at: temporaryRoot,
                fileManager: .default
            )
        )
    }

    func testQwenImageRequiresLoadableLocalLayout() throws {
        try makeCompleteQwenImageFixture()
        try FileManager.default.removeItem(
            at: temporaryRoot.appendingPathComponent("processor/tokenizer.json")
        )

        XCTAssertFalse(
            resolver().isImageGenerationModel(
                model: "Qwen/Qwen-Image-2.1",
                at: temporaryRoot,
                fileManager: .default
            )
        )
    }

    func testQwenLanguageModelIsNotImageGenerationModel() throws {
        try writeJSON(
            [
                "architectures": ["QwenForCausalLM"],
                "model_type": "qwen",
            ],
            to: "config.json"
        )
        try touch("model.safetensors")

        XCTAssertFalse(
            resolver().isImageGenerationModel(
                model: "Qwen/Qwen-7B",
                at: temporaryRoot,
                fileManager: .default
            )
        )
    }

    func testQwenImageResolvesFromWeightsWhenRepositoryIsRenamed() throws {
        try makeCompleteQwenImageFixture()

        XCTAssertTrue(
            resolver().isImageGenerationModel(
                model: "local/my-custom-image-checkpoint",
                at: temporaryRoot,
                fileManager: .default
            ),
            "transformer weight markers identify Qwen-Image without its name"
        )
    }

    func testQuantizedQwenImageConversionResolvesWithoutPipelineMetadata()
        throws
    {
        for component in ["transformer", "text_encoder", "vae"] {
            try writeJSON(["mlx_format": true], to: "\(component)/config.json")
            try touch("\(component)/model.safetensors")
        }
        try touch("processor/tokenizer.json")

        XCTAssertTrue(
            resolver().isImageGenerationModel(
                model: "mlx-community/Qwen-Image-2.1-4bit",
                at: temporaryRoot,
                fileManager: .default
            ),
            "a quantized conversion has no model_index.json and no shard index"
        )
    }

    func testBundledManifestGatesMetadataCandidates() throws {
        try makeCompleteFlux2Fixture()
        let resolver = MLXImageModelResolver(
            generationModelTypes: [],
            editingModelTypes: []
        )

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
        let bundledEditingTypes = try Nativ.imageEditingModelTypes()

        XCTAssertTrue(generationModelTypes.isSubset(of: modelTypes))
        XCTAssertFalse(modelTypes.contains("diffusion_gemma"))
        XCTAssertTrue(editingModelTypes.isSubset(of: bundledEditingTypes))
    }

    private func resolver() -> MLXImageModelResolver {
        MLXImageModelResolver(
            generationModelTypes: generationModelTypes,
            editingModelTypes: editingModelTypes
        )
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

    private func makeCompleteFlux3Fixture() throws {
        try writeJSON(
            [
                "model": "flux-3-image-klein",
                "dit": ["in_channels": ["image": 128, "image_cond": 128, "text": 20480]],
                "text_encoder": ["layers": [4, 8, 12, 16, 20, 24, 28, 32]],
            ],
            to: "config.json"
        )
        try touch("model.safetensors")
        try touch("ae.safetensors")
        try writeJSON(["model_type": "qwen3_vl"], to: "text_encoder/config.json")
        try touch("text_encoder/model-00001-of-00001.safetensors")
        try touch("text_encoder/tokenizer.json")
    }

    private func makeCompleteMOSSImageFixture() throws {
        try writeJSON(
            [
                "_class_name": "MOSSImagePipeline",
                "transformer": ["pipeline_moss_image", "MOSSImageTransformer2DModel"],
                "text_encoder": ["transformers", "Qwen3_5Model"],
                "vae": ["diffusers", "AutoencoderKLFlux2"],
            ],
            to: "model_index.json"
        )
        try writeJSON([:], to: "scheduler/scheduler_config.json")
        try touch("tokenizer/tokenizer.json")
        for component in ["transformer", "text_encoder", "vae"] {
            try writeJSON([:], to: "\(component)/config.json")
            try touch("\(component)/model.safetensors")
        }
        try writeJSON(["_class_name": "AutoencoderKLFlux2"], to: "vae/config.json")
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

    private func makeCompleteQwenImageFixture() throws {
        try writeJSON(
            [
                "_class_name": "QwenImage21Pipeline",
                "processor": ["transformers", "Qwen3VLProcessor"],
                "scheduler": [
                    "diffusers",
                    "FlowMatchEulerDiscreteScheduler",
                ],
                "text_encoder": [
                    "transformers",
                    "Qwen3VLForConditionalGeneration",
                ],
                "transformer": ["diffusers", "QwenImage21Transformer2DModel"],
                "vae": ["diffusers", "AutoencoderKLQwenImage21"],
            ],
            to: "model_index.json"
        )
        try writeJSON(
            ["_class_name": "QwenImage21Transformer2DModel"],
            to: "transformer/config.json"
        )
        try writeJSON(
            ["_class_name": "AutoencoderKLQwenImage21"],
            to: "vae/config.json"
        )
        try writeJSON(["model_type": "qwen3_vl"], to: "text_encoder/config.json")
        try writeJSON(
            [
                "weight_map": [
                    "transformer_blocks.0.img_mlp.gate_layer.weight":
                        "diffusion_pytorch_model-00001-of-00002.safetensors",
                    "txt_in.text_norm.weight":
                        "diffusion_pytorch_model-00001-of-00002.safetensors",
                    "txt_in.in_layer.weight":
                        "diffusion_pytorch_model-00001-of-00002.safetensors",
                ]
            ],
            to: "transformer/diffusion_pytorch_model.safetensors.index.json"
        )
        for component in ["transformer", "text_encoder", "vae"] {
            try touch("\(component)/model.safetensors")
        }
        try touch("processor/tokenizer.json")
    }

    private func makeCompleteLLaDAImageFixture() throws {
        try writeJSON(
            ["_class_name": "LLaDAImagePipeline"],
            to: "model_index.json"
        )
        try writeJSON([:], to: "scheduler/scheduler_config.json")
        try touch("tokenizer/tokenizer.json")
        for component in [
            "queryformer", "sigvq", "text_encoder", "text_projection",
            "transformer",
        ] {
            try writeJSON([:], to: "\(component)/config.json")
            try touch("\(component)/model.safetensors")
        }
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
