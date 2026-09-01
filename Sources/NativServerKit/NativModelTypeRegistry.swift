import Foundation

public enum NativModelCapability: String, CaseIterable, Codable, Sendable {
    case language
    case speculativeDrafters = "speculative_drafters"
    case imageGeneration = "image_generation"
    case imageEditing = "image_editing"
    case speechToText = "speech_to_text"
    case textToSpeech = "text_to_speech"
    case embeddings
    case reranking
}

public enum NativModelTypeRegistryError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case missingPackageVersion(String)
    case unexpectedCapability(String)
    case missingCapability(NativModelCapability)
    case emptyCapability(NativModelCapability)
    case invalidModelType(String, NativModelCapability)
    case invalidAlias(String, String, NativModelCapability)
}

/// A validated view of the loaders shipped inside Nativ's bundled MLX runtime.
public struct NativModelTypeRegistry: Equatable, Sendable {
    private let entries: [NativModelCapability: Entry]

    public init(data: Data) throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 1 else {
            throw NativModelTypeRegistryError.unsupportedSchemaVersion(
                manifest.schemaVersion
            )
        }

        for package in ["mlx-vlm", "mlx-audio"] {
            guard let version = manifest.packageVersions[package],
                  !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw NativModelTypeRegistryError.missingPackageVersion(package)
            }
        }

        let capabilityNames = Set(NativModelCapability.allCases.map(\.rawValue))
        if let unexpectedCapability = manifest.capabilities.keys.first(
            where: { capabilityNames.contains($0) == false }
        ) {
            throw NativModelTypeRegistryError.unexpectedCapability(
                unexpectedCapability
            )
        }

        var validatedEntries: [NativModelCapability: Entry] = [:]
        for capability in NativModelCapability.allCases {
            guard let manifestEntry = manifest.capabilities[capability.rawValue] else {
                throw NativModelTypeRegistryError.missingCapability(capability)
            }
            guard !manifestEntry.modelTypes.isEmpty else {
                throw NativModelTypeRegistryError.emptyCapability(capability)
            }

            var modelTypes: Set<String> = []
            for modelType in manifestEntry.modelTypes {
                guard let normalized = Self.normalized(modelType),
                      normalized == modelType,
                      modelTypes.insert(normalized).inserted
                else {
                    throw NativModelTypeRegistryError.invalidModelType(
                        modelType,
                        capability
                    )
                }
            }

            var aliases: [String: String] = [:]
            for (alias, loader) in manifestEntry.aliases {
                guard let normalizedAlias = Self.normalized(alias),
                      let normalizedLoader = Self.normalized(loader),
                      normalizedAlias == alias,
                      normalizedLoader == loader,
                      normalizedAlias != normalizedLoader,
                      modelTypes.contains(normalizedLoader),
                      modelTypes.contains(normalizedAlias) == false
                else {
                    throw NativModelTypeRegistryError.invalidAlias(
                        alias,
                        loader,
                        capability
                    )
                }
                aliases[normalizedAlias] = normalizedLoader
            }

            validatedEntries[capability] = Entry(
                modelTypes: modelTypes,
                aliases: aliases
            )
        }

        entries = validatedEntries
    }

    public func canonicalModelTypes(
        for capability: NativModelCapability
    ) -> Set<String> {
        entries[capability]?.modelTypes ?? []
    }

    public func loader(
        for modelType: String,
        capability: NativModelCapability
    ) -> String? {
        guard let normalized = Self.normalized(modelType),
              let entry = entries[capability]
        else {
            return nil
        }
        if entry.modelTypes.contains(normalized) {
            return normalized
        }
        return entry.aliases[normalized]
    }

    public func capabilities(for modelType: String) -> Set<NativModelCapability> {
        Set(
            NativModelCapability.allCases.filter {
                loader(for: modelType, capability: $0) != nil
            }
        )
    }

    private static func normalized(_ modelType: String) -> String? {
        let value = modelType.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value.isEmpty ? nil : value
    }
}

private extension NativModelTypeRegistry {
    struct Entry: Equatable, Sendable {
        let modelTypes: Set<String>
        let aliases: [String: String]
    }

    struct Manifest: Decodable {
        let schemaVersion: Int
        let packageVersions: [String: String]
        let capabilities: [String: ManifestEntry]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case packageVersions = "package_versions"
            case capabilities
        }
    }

    struct ManifestEntry: Decodable {
        let modelTypes: [String]
        let aliases: [String: String]

        enum CodingKeys: String, CodingKey {
            case modelTypes = "model_types"
            case aliases
        }
    }
}
