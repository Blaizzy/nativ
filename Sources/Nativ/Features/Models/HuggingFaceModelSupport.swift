import Foundation
import NativServerKit

enum HuggingFaceModelSupport: Equatable, Sendable {
    case supported
    case unsupported
    case unknown
}

struct HuggingFaceModelSupportConfiguration: Decodable, Equatable, Sendable {
    let modelType: String?
    let speculatorsModelType: String?
    let architectures: [String]
    let hasMalformedMetadata: Bool
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
        modelType = try? container.decode(String.self, forKey: .modelType)
        speculatorsModelType = try? container.decode(
            String.self,
            forKey: .speculatorsModelType
        )
        let decodedArchitectures = try? container.decode(
            [String].self,
            forKey: .architectures
        )
        architectures = decodedArchitectures ?? []
        // Missing or null fields are optional; invalid types are not evidence
        // that the runtime does (or does not) support this model.
        hasMalformedMetadata = try (
            (container.hasNonNullValue(forKey: .modelType) && modelType == nil)
                || (container.hasNonNullValue(forKey: .speculatorsModelType)
                    && speculatorsModelType == nil)
                || (container.hasNonNullValue(forKey: .architectures)
                    && decodedArchitectures == nil)
        )
        hasVisionConfig = try container.hasNonNullValue(forKey: .visionConfig)
        hasAudioConfig = try container.hasNonNullValue(forKey: .audioConfig)
        hasDFlashConfig = try container.hasNonNullValue(forKey: .dFlashConfig)
        let modelFile = try? container.decode(String.self, forKey: .modelFile)
        let hasAutoMap = try container.hasNonNullValue(forKey: .autoMap)
        usesCustomCode = modelFile?.isEmpty == false || hasAutoMap
    }
}

struct HuggingFaceModelSupportClassifier: Sendable {
    private let registry: NativModelTypeRegistry

    init(registry: NativModelTypeRegistry) {
        self.registry = registry
    }

    func classify(
        configuration: HuggingFaceModelSupportConfiguration?,
        pipelineTag: String?,
        tags: [String]
    ) -> HuggingFaceModelSupport {
        guard let configuration, !configuration.hasMalformedMetadata else {
            return .unknown
        }

        let architectures = Set(configuration.architectures.map { $0.lowercased() })
        if architectures.contains("boundaryextractor")
            || architectures.contains("dflash2draftmodel")
        {
            return .supported
        }

        let normalizedTags = Set(tags.map { $0.lowercased() })
        if configuration.usesCustomCode
            || normalizedTags.contains("custom_code")
            || normalizedTags.contains("trust_remote_code")
        {
            return .unknown
        }

        if configuration.hasDFlashConfig {
            return .unknown
        }

        // Match the runtime's primary type, using the speculator type only
        // when model_type is absent or empty.
        let modelType: String?
        if let primaryType = configuration.modelType, !primaryType.isEmpty {
            modelType = primaryType
        } else {
            modelType = configuration.speculatorsModelType
        }
        if let modelType, !registry.capabilities(for: modelType).isEmpty {
            return .supported
        }

        let normalizedPipelineTag = pipelineTag?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalizedPipelineTag?.isEmpty == false,
              configuration.modelType?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty == false,
              !configuration.hasVisionConfig,
              !configuration.hasAudioConfig
        else {
            return .unknown
        }
        return .unsupported
    }
}

private extension KeyedDecodingContainer {
    func hasNonNullValue(forKey key: Key) throws -> Bool {
        guard contains(key) else {
            return false
        }
        return try !decodeNil(forKey: key)
    }
}
