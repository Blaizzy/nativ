import Foundation
import NativServerKit

enum HuggingFaceModelSupport: Equatable, Sendable {
    case supported
    case unsupported
    case unknown
}

struct HuggingFaceModelConfiguration: Decodable, Equatable, Sendable {
    let modelType: String?
    let speculatorsModelType: String?
    let architectures: [String]
    let hasVisionConfig: Bool
    let hasAudioConfig: Bool
    let hasDFlashConfig: Bool
    let usesCustomCode: Bool

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case speculatorsModelType = "speculators_model_type"
        case architectures
        case visionConfig = "vision_config"
        case audioConfig = "audio_config"
        case dFlashConfig = "dflash_config"
        case modelFile = "model_file"
        case autoMap = "auto_map"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try container.decodeIfPresent(String.self, forKey: .modelType)
        speculatorsModelType = try container.decodeIfPresent(
            String.self,
            forKey: .speculatorsModelType
        )
        architectures = try container.decodeIfPresent(
            [String].self,
            forKey: .architectures
        ) ?? []
        hasVisionConfig = try container.hasValue(forKey: .visionConfig)
        hasAudioConfig = try container.hasValue(forKey: .audioConfig)
        hasDFlashConfig = try container.hasValue(forKey: .dFlashConfig)
        let modelFile = try container.decodeIfPresent(String.self, forKey: .modelFile)
        let hasAutoMap = try container.hasValue(forKey: .autoMap)
        usesCustomCode = modelFile?.isEmpty == false || hasAutoMap
    }
}

struct HuggingFaceModelSupportClassifier: Sendable {
    private let registry: NativModelTypeRegistry

    init(registry: NativModelTypeRegistry) {
        self.registry = registry
    }

    func classify(
        configuration: HuggingFaceModelConfiguration?,
        pipelineTag: String?,
        tags: [String]
    ) -> HuggingFaceModelSupport {
        guard let configuration else {
            return .unknown
        }

        let architectures = Set(configuration.architectures.map { $0.lowercased() })
        if architectures.contains("boundaryextractor")
            || architectures.contains("dflash2draftmodel") {
            return .supported
        }

        let normalizedTags = Set(tags.map { $0.lowercased() })
        if configuration.usesCustomCode
            || normalizedTags.contains("custom_code")
            || normalizedTags.contains("trust_remote_code") {
            return .unknown
        }

        // DFlash changes the effective loader derived from model_type. Unless
        // the explicit DFlash2 architecture above identifies it, the public
        // config does not provide enough information for a conclusive result.
        if configuration.hasDFlashConfig {
            return .unknown
        }

        let candidateTypes = [
            configuration.modelType,
            configuration.speculatorsModelType,
        ].compactMap { $0 }
        if candidateTypes.contains(where: {
            !registry.capabilities(for: $0).isEmpty
        }) {
            return .supported
        }

        // A standard repository with an explicit Hub task and a model type
        // absent from every bundled backend has no remaining loader path.
        // This also covers clearly unrelated tasks such as classification and
        // object detection instead of silently treating them as uncertain.
        let normalizedPipelineTag = pipelineTag?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalizedPipelineTag?.isEmpty == false,
              configuration.modelType?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty == false,
              configuration.speculatorsModelType == nil,
              !configuration.hasVisionConfig,
              !configuration.hasAudioConfig
        else {
            return .unknown
        }
        return .unsupported
    }
}

private extension KeyedDecodingContainer {
    func hasValue(forKey key: Key) throws -> Bool {
        guard contains(key) else {
            return false
        }
        return try !decodeNil(forKey: key)
    }
}
