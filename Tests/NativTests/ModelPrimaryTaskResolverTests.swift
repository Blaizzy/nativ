import NativServerKit
import XCTest

final class ModelPrimaryTaskResolverTests: XCTestCase {
    func testBundledDiarizationAndVADModelsAreKnownNonLanguage() {
        for modelType in ["nemotron_diarization", "sortformer", "silero_vad", "silero"] {
            let task = ModelPrimaryTaskResolver.resolve(
                model: "org/model", config: ["model_type": modelType]
            )
            XCTAssertEqual(task, .nonLanguage, modelType)
            XCTAssertTrue(task.isKnownNonLanguage, modelType)
            XCTAssertFalse(task.isLanguageCapable, modelType)
        }
    }

    func testHiggsAudioIsTextToSpeechDespiteQwenBackbone() {
        let task = resolve(
            model: "bosonai/higgs-audio-v3-tts-4b",
            modelType: "higgs_multimodal_qwen3",
            architecture: "HiggsMultimodalQwen3ForConditionalGeneration"
        )

        XCTAssertEqual(task, .textToSpeech)
        XCTAssertFalse(task.isLanguageCapable)
    }

    func testCohereASRIsSpeechToTextDespiteConditionalGenerationArchitecture() {
        let task = resolve(
            model: "CohereLabs/cohere-transcribe-03-2026",
            modelType: "cohere_asr",
            architecture: "CohereAsrForConditionalGeneration"
        )

        XCTAssertEqual(task, .speechToText)
        XCTAssertFalse(task.isLanguageCapable)
    }

    func testGraniteSpeech5CTCIsSpeechToText() {
        let task = resolve(
            model: "ibm-granite/granite-speech-5.0-470m-turboctc",
            modelType: "granite_speech5_ctc",
            architecture: "GraniteSpeech5ForCTC"
        )

        XCTAssertEqual(task, .speechToText)
        XCTAssertFalse(task.isLanguageCapable)
    }

    func testQwenTTSIsNotLanguageModel() {
        let task = resolve(
            model: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit",
            modelType: "qwen3_tts",
            architecture: "Qwen3TTSForConditionalGeneration"
        )

        XCTAssertEqual(task, .textToSpeech)
    }

    func testQwenAudioUsesBundledSpeechLoader() {
        let task = resolve(
            model: "Qwen/Qwen2-Audio-7B-Instruct",
            modelType: "qwen2_audio",
            architecture: "Qwen2AudioForConditionalGeneration"
        )

        XCTAssertEqual(task, .speechToText)
        XCTAssertFalse(task.isLanguageCapable)
    }

    func testQwenOmniRemainsLanguageCapable() {
        let task = resolve(
            model: "mlx-community/Qwen3-Omni-30B-A3B-Instruct-4bit",
            modelType: "qwen3_omni_moe",
            architecture: "Qwen3OmniMoeForConditionalGeneration"
        )

        XCTAssertEqual(task, .language)
        XCTAssertTrue(task.isLanguageCapable)
    }

    func testDiffusionGemmaRemainsLanguageModel() {
        let task = resolve(
            model: "google/diffusiongemma-26B-A4B-it",
            modelType: "diffusion_gemma",
            architecture: "DiffusionGemmaForBlockDiffusion"
        )

        XCTAssertEqual(task, .language)
        XCTAssertTrue(task.isLanguageCapable)
    }

    func testRepositoryNameDisambiguatesConvertedTTSBackbone() {
        let task = resolve(
            model: "mlx-community/VyvoTTS-EN-Beta-4bit",
            modelType: "qwen3",
            architecture: "Qwen3ForCausalLM"
        )

        XCTAssertEqual(task, .textToSpeech)
    }

    func testRepositoryNameDisambiguatesVibeVoiceASRVariant() {
        let task = resolve(
            model: "mlx-community/VibeVoice-ASR-4bit",
            modelType: "vibevoice",
            architecture: "VibeVoiceForConditionalGeneration"
        )

        XCTAssertEqual(task, .speechToText)
    }

    func testNewRuntimeTypesAndAliasesNeedNoArchitectureNameHeuristic() throws {
        let registry = try makeRegistry()
        for modelType in ["future_chat", "future-alias", " FUTURE-ALIAS "] {
            let task = ModelPrimaryTaskResolver.resolve(
                model: "org/new-checkpoint",
                config: ["model_type": modelType, "architectures": ["UnfamiliarArchitecture"]],
                registry: registry
            )
            XCTAssertEqual(task, .language, modelType)
            XCTAssertFalse(task.isKnownNonLanguage)
        }
    }

    func testEncoderIsExcludedEvenWhenRuntimeCanImportIt() throws {
        let task = ModelPrimaryTaskResolver.resolve(
            model: "org/encoder",
            config: ["model_type": "future_encoder"],
            registry: try makeRegistry()
        )
        XCTAssertEqual(task, .embeddings)
        XCTAssertTrue(task.isKnownNonLanguage)
    }

    func testMissingRegistryAndUnknownTypesDoNotClaimSupportOrBlockStartup() throws {
        let config: [String: Any] = ["model_type": "unregistered", "architectures": ["Qwen3ForCausalLM"]]
        for registry in [nil, try makeRegistry()] {
            let task = ModelPrimaryTaskResolver.resolve(model: "org/model", config: config, registry: registry)
            XCTAssertEqual(task, .unknown)
            XCTAssertFalse(task.isKnownNonLanguage)
        }
    }

    func testSpeechAliasesAndSharedBackbonesUseRuntimeCapabilities() throws {
        let registry = try makeRegistry()
        let cases: [(String, String, ModelPrimaryTask)] = [
            ("org/model", "future-speech-alias", .textToSpeech),
            ("org/chat", "future_chat", .language),
            ("org/converted-tts", "future_chat", .textToSpeech),
        ]
        for (model, modelType, expected) in cases {
            XCTAssertEqual(ModelPrimaryTaskResolver.resolve(
                model: model, config: ["model_type": modelType], registry: registry
            ), expected)
        }
    }

    func testGenerationMetadataMustReferenceCanonicalLanguageLoaders() throws {
        XCTAssertThrowsError(try makeRegistry(generationTypes: ["future-alias"]))
        XCTAssertThrowsError(try makeRegistry(generationTypes: ["future_chat", "future_chat"]))
    }

    private func makeRegistry(generationTypes: [String] = ["future_chat"]) throws -> NativModelTypeRegistry {
        var capabilities: [String: Any] = [:]
        for capability in NativModelCapability.allCases {
            capabilities[capability.rawValue] = ["model_types": ["test_\(capability.rawValue)"], "aliases": [:]]
        }
        capabilities["language"] = [
            "model_types": ["future_chat", "future_encoder"],
            "aliases": ["future-alias": "future_chat"],
            "generation_model_types": generationTypes,
        ]
        capabilities["embeddings"] = ["model_types": ["future_encoder"], "aliases": [:]]
        capabilities["text_to_speech"] = [
            "model_types": ["future_speech", "future_chat"],
            "aliases": ["future-speech-alias": "future_speech"],
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1,
            "package_versions": ["mlx-vlm": "test", "mlx-audio": "test"],
            "capabilities": capabilities,
        ])
        return try NativModelTypeRegistry(data: data)
    }

    private func resolve(
        model: String,
        modelType: String,
        architecture: String
    ) -> ModelPrimaryTask {
        ModelPrimaryTaskResolver.resolve(
            model: model,
            config: [
                "model_type": modelType,
                "architectures": [architecture],
            ]
        )
    }
}
