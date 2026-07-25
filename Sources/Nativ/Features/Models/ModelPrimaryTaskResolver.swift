import Foundation

enum ModelPrimaryTask: Equatable, Sendable {
    case language
    case audioLanguage
    case textToSpeech
    case speechToText
    case unknown

    var isLanguageCapable: Bool {
        switch self {
        case .language, .audioLanguage:
            true
        case .textToSpeech, .speechToText, .unknown:
            false
        }
    }

    var isExclusiveSpeech: Bool {
        switch self {
        case .textToSpeech, .speechToText:
            true
        case .language, .audioLanguage, .unknown:
            false
        }
    }

    func includesLanguageCapability(fallbackMatch: Bool) -> Bool {
        isLanguageCapable || (!isExclusiveSpeech && fallbackMatch)
    }
}

enum ModelPrimaryTaskResolver {
    static func resolve(model: String, config: [String: Any]) -> ModelPrimaryTask {
        let modelType = normalized(config["model_type"] as? String)
        let architectures = (config["architectures"] as? [String] ?? [])
            .map(normalized)
        let modelName = normalized(
            model.split(separator: "/").last.map(String.init)
        )

        if isSpeechToText(
            modelType: modelType,
            architectures: architectures,
            modelName: modelName
        ) {
            return .speechToText
        }
        if isTextToSpeech(
            modelType: modelType,
            architectures: architectures,
            modelName: modelName
        ) {
            return .textToSpeech
        }
        if audioLanguageModelTypes.contains(modelType) {
            return .audioLanguage
        }
        if languageModelTypes.contains(modelType)
            || languageFamilyPrefixes.contains(where: {
                modelType.hasPrefix("\($0)_")
            })
        {
            return .language
        }
        return .unknown
    }

    private static func isTextToSpeech(
        modelType: String,
        architectures: [String],
        modelName: String
    ) -> Bool {
        if textToSpeechModelTypes.contains(modelType)
            || modelType.contains("_tts")
            || modelType.hasPrefix("tts_")
            || modelType.hasPrefix("higgs_")
        {
            return true
        }

        let architecture = architectures.joined(separator: " ")
        if architecture.contains("texttospeech")
            || architecture.contains("speechsynthesis")
            || architecture.contains("tts")
        {
            return true
        }

        // A few converted checkpoints retain their backbone model_type.
        // Use the repository/path only as a final, task-specific fallback.
        return modelName.contains("tts")
    }

    private static func isSpeechToText(
        modelType: String,
        architectures: [String],
        modelName: String
    ) -> Bool {
        if speechToTextModelTypes.contains(modelType)
            || modelType.contains("_asr")
            || modelType.hasPrefix("asr_")
            || modelType.contains("transcribe")
            || modelType.contains("forced_aligner")
        {
            return true
        }

        let architecture = architectures.joined(separator: " ")
        if architecture.contains("speechrecognition")
            || architecture.contains("transcribe")
            || architecture.contains("asr")
        {
            return true
        }

        return ["asr", "transcribe", "whisper", "forcedaligner"]
            .contains(where: modelName.contains)
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private static let textToSpeechModelTypes: Set<String> = [
        "bailingmm",
        "bark",
        "chatterbox",
        "chatterbox_turbo",
        "csm",
        "dia",
        "fish_qwen3_omni",
        "higgs_audio",
        "higgs_multimodal_qwen3",
        "indextts",
        "kitten",
        "kitten_tts",
        "kokoro",
        "marvis",
        "melotts",
        "moss_tts_nano",
        "omnivoice",
        "outetts",
        "pocket_tts",
        "qwen3_tts",
        "sesame",
        "soprano",
        "spark",
        "vibevoice",
        "vibevoice_streaming",
        "voxcpm",
        "voxtral_tts",
    ]

    private static let speechToTextModelTypes: Set<String> = [
        "canary",
        "cohere_asr",
        "fireredasr2",
        "glmasr",
        "granite_speech",
        "lasr",
        "lasr_ctc",
        "moonshine",
        "moss_transcribe_diarize",
        "nemotron_asr",
        "parakeet",
        "qwen3_asr",
        "sensevoice",
        "vibevoice_asr",
        "voxtral",
        "voxtral_realtime",
        "wav2vec",
        "wav2vec2",
        "whisper",
    ]

    private static let audioLanguageModelTypes: Set<String> = [
        "gemma4",
        "gemma4_unified",
        "gemma4_unified_assistant",
        "lfm_audio",
        "qwen2_audio",
        "qwen3_omni_moe",
    ]

    private static let languageModelTypes: Set<String> = [
        "diffusion_gemma",
        "hrm_text",
        "llama",
        "mistral",
        "mistral3",
        "qwen2",
        "qwen3",
        "qwen3_5",
        "qwen3_5_moe",
        "qwen3_5_mtp",
        "smollm3",
    ]

    private static let languageFamilyPrefixes = [
        "cohere",
        "deepseek",
        "gemma",
        "granite",
        "llama",
        "mistral",
        "qwen",
    ]
}
