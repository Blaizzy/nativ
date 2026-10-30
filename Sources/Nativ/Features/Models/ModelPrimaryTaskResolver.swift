import Foundation
import NativServerKit

enum ModelPrimaryTask: Equatable, Sendable {
    case language
    case textToSpeech
    case speechToText
    case embeddings
    case reranking
    case nonLanguage
    case unknown

    var isLanguageCapable: Bool { self == .language }
    var isKnownNonLanguage: Bool { self != .language && self != .unknown }
}

enum ModelPrimaryTaskResolver {
    static let bundledRegistryResult = Result { try Nativ.modelTypeRegistry() }
    static let bundledRegistry = try? bundledRegistryResult.get()

    static var runtimeConfigurationError: String? {
        guard case .failure = bundledRegistryResult else { return nil }
        return "Nativ couldn’t read model capabilities from its bundled runtime. Reinstall or rebuild Nativ to restore model support detection. Your downloaded models are unaffected."
    }

    static func resolve(
        model: String,
        config: [String: Any],
        hasEmbeddingLayout: Bool = false,
        registry: NativModelTypeRegistry? = bundledRegistry
    ) -> ModelPrimaryTask {
        guard let registry,
              let modelType = config["model_type"] as? String
        else {
            return .unknown
        }
        let capabilities = registry.capabilities(for: modelType)

        let architectures = (config["architectures"] as? [String] ?? [])
            .joined(separator: " ").lowercased()
        let name = model.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        let descriptors = [modelType.lowercased(), architectures, name].joined(separator: " ")
        let pipeline = (config["pipeline_tag"] as? String)?.lowercased() ?? ""

        // Preserve speech task hints for converted checkpoints that retain a
        // chat backbone or use an alias absent from the runtime manifest.
        if pipeline == "automatic-speech-recognition"
            || ["asr", "transcribe", "speechrecognition", "forcedaligner"]
                .contains(where: descriptors.contains) {
            return .speechToText
        }
        if pipeline == "text-to-speech"
            || ["tts", "texttospeech", "speechsynthesis"].contains(where: descriptors.contains) {
            return .textToSpeech
        }
        guard !capabilities.isEmpty else { return .unknown }
        if descriptors.contains("rerank") || architectures.contains("sequenceclassification") {
            return capabilities.contains(.reranking) ? .reranking : .nonLanguage
        }
        let embeddingStamp = config["mlx_embeddings"] as? [String: Any]
        if hasEmbeddingLayout || embeddingStamp?["kind"] as? String == "embedding"
            || descriptors.contains("embedding")
            || pipeline == "feature-extraction" || pipeline == "sentence-similarity" {
            return capabilities.contains(.embeddings) ? .embeddings : .nonLanguage
        }
        if !capabilities.isDisjoint(with: [
            .imageGeneration, .imageEditing, .speculativeDrafters, .voiceActivityDetection,
        ]) {
            return .nonLanguage
        }
        if registry.supportsTextGeneration(for: modelType) == true {
            return .language
        }
        if capabilities.contains(.embeddings) {
            return .embeddings
        }
        // Prefer a canonical speech loader over another task's fallback alias.
        if capabilities.contains(.textToSpeech),
           !capabilities.contains(.speechToText)
            || registry.canonicalModelTypes(for: .textToSpeech).contains(modelType.lowercased()) {
            return .textToSpeech
        }
        if capabilities.contains(.speechToText) {
            return .speechToText
        }
        if registry.supportsTextGeneration(for: modelType) == false {
            return .nonLanguage
        }
        return .unknown
    }
}
