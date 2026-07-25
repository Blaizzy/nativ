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
        XCTAssertFalse(task.includesLanguageCapability(fallbackMatch: true))
    }

    func testCohereASRIsSpeechToTextDespiteConditionalGenerationArchitecture() {
        let task = resolve(
            model: "CohereLabs/cohere-transcribe-03-2026",
            modelType: "cohere_asr",
            architecture: "CohereAsrForConditionalGeneration"
        )

        XCTAssertEqual(task, .speechToText)
        XCTAssertFalse(task.isLanguageCapable)
        XCTAssertFalse(task.includesLanguageCapability(fallbackMatch: true))
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
