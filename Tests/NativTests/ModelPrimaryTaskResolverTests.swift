import XCTest

final class ModelPrimaryTaskResolverTests: XCTestCase {
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

    func testQwenAudioRemainsLanguageCapable() {
        let task = resolve(
            model: "Qwen/Qwen2-Audio-7B-Instruct",
            modelType: "qwen2_audio",
            architecture: "Qwen2AudioForConditionalGeneration"
        )

        XCTAssertEqual(task, .audioLanguage)
        XCTAssertTrue(task.isLanguageCapable)
    }

    func testQwenOmniRemainsLanguageCapable() {
        let task = resolve(
            model: "mlx-community/Qwen3-Omni-30B-A3B-Instruct-4bit",
            modelType: "qwen3_omni_moe",
            architecture: "Qwen3OmniMoeForConditionalGeneration"
        )

        XCTAssertEqual(task, .audioLanguage)
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

    func testClassifiesModelConfigurations() {
        let cases: [(String, [String: Any], ModelPrimaryTask)] = [
            (
                "Mamba",
                ["model_type": "custom", "architectures": ["MambaForCausalLM"]],
                .language
            ),
            (
                "Phi-3V",
                ["model_type": "custom", "architectures": ["Phi3VForConditionalGeneration"]],
                .language
            ),
            (
                "GPT-2",
                ["model_type": "custom", "architectures": ["GPT2LMHeadModel"]],
                .language
            ),
            (
                "InternVL",
                [
                    "model_type": "internvl_chat",
                    "architectures": ["InternVLChatModel"],
                    "llm_config": [
                        "model_type": "qwen3",
                        "architectures": ["Qwen3ForCausalLM"],
                    ],
                ],
                .language
            ),
            (
                "DeepSeek-VL",
                [
                    "model_type": "deepseek_vl_v2",
                    "language_config": [
                        "model_type": "deepseek_v2",
                        "architectures": ["DeepseekV2ForCausalLM"],
                    ],
                ],
                .language
            ),
            (
                "custom nested Phi-3",
                [
                    "model_type": "custom_vlm",
                    "text_config": [
                        "model_type": "phi3",
                        "architectures": ["Phi3ForCausalLM"],
                    ],
                ],
                .language
            ),
            ("MiniCPM-O", ["model_type": "minicpmo"], .language),
            ("MiniCPM-V", ["model_type": "minicpmv"], .language),
            ("Moondream", ["model_type": "moondream"], .language),
            ("Moondream 1", ["model_type": "moondream1"], .language),
            ("Moondream 2", ["model_type": "moondream2"], .language),
            ("Moondream 3", ["model_type": "moondream3"], .language),
            (
                "CLIP",
                [
                    "model_type": "clip",
                    "architectures": ["CLIPModel"],
                    "text_config": ["model_type": "clip_text_model"],
                    "vision_config": ["model_type": "clip_vision_model"],
                ],
                .unknown
            ),
            (
                "SigLIP",
                [
                    "model_type": "siglip",
                    "architectures": ["SiglipModel"],
                    "text_config": ["model_type": "siglip_text_model"],
                    "vision_config": ["model_type": "siglip_vision_model"],
                ],
                .unknown
            ),
            (
                "SigLIP 2",
                [
                    "model_type": "siglip",
                    "text_config": ["model_type": "siglip_text_model"],
                    "vision_config": ["model_type": "siglip_vision_model"],
                ],
                .unknown
            ),
            ("BERT", ["model_type": "bert", "architectures": ["BertModel"]], .unknown),
        ]

        for (name, config, expectedTask) in cases {
            XCTAssertEqual(
                ModelPrimaryTaskResolver.resolve(model: "org/\(name)", config: config),
                expectedTask,
                name
            )
        }
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
