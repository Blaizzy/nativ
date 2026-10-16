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
    case decision
}

public enum NativModelTypeRegistryError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case missingPackageVersion(String)
    case unexpectedCapability(String)
    case missingCapability(NativModelCapability)
    case emptyCapability(NativModelCapability)
    case invalidModelType(String, NativModelCapability)
    case invalidAlias(String, String, NativModelCapability)
    case invalidConfigurationAlias
    case invalidModelKinds(NativModelCapability)
    case invalidModelKind(String, String, NativModelCapability)
}

/// A validated view of the loaders shipped inside Nativ's bundled MLX runtime.
public struct NativModelTypeRegistry: Equatable, Sendable {
    private let entries: [NativModelCapability: Entry]
    private let configurationAliases: [ConfigurationAlias]

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

            if let manifestKinds = manifestEntry.kinds {
                guard capability == .speculativeDrafters,
                      Set(manifestKinds.keys) == modelTypes
                else {
                    throw NativModelTypeRegistryError.invalidModelKinds(capability)
                }
            }

            var kinds: [String: String] = [:]
            for (modelType, kind) in manifestEntry.kinds ?? [:] {
                guard let normalizedModelType = Self.normalized(modelType),
                    let normalizedKind = Self.normalized(kind),
                    normalizedModelType == modelType,
                    normalizedKind == kind,
                    modelTypes.contains(normalizedModelType),
                    Self.knownDrafterKinds.contains(normalizedKind)
                else {
                    throw NativModelTypeRegistryError.invalidModelKind(
                        modelType,
                        kind,
                        capability
                    )
                }
                kinds[normalizedModelType] = normalizedKind
            }

            validatedEntries[capability] = Entry(
                modelTypes: modelTypes,
                aliases: aliases,
                kinds: kinds
            )
        }

        let aliases = manifest.configurationAliases ?? []
        let knownLoaders = Set(validatedEntries.values.flatMap(\.modelTypes))
        guard aliases.allSatisfy({ Self.normalized($0.modelType) == $0.modelType
            && !$0.autoModelSuffix.isEmpty && knownLoaders.contains($0.loader) }) else {
            throw NativModelTypeRegistryError.invalidConfigurationAlias
        }
        configurationAliases = aliases
        entries = validatedEntries
    }

    public func canonicalModelTypes(
        for capability: NativModelCapability
    ) -> Set<String> {
        entries[capability]?.modelTypes ?? []
    }

    public func loader(
        for modelType: String,
        capability: NativModelCapability,
        autoModel: String? = nil
    ) -> String? {
        guard let normalized = resolvedModelType(for: modelType, autoModel: autoModel),
              let entry = entries[capability]
        else {
            return nil
        }
        if entry.modelTypes.contains(normalized) {
            return normalized
        }
        return entry.aliases[normalized]
    }

    public func resolvedModelType(for modelType: String, autoModel: String? = nil) -> String? {
        guard let normalized = Self.normalized(modelType) else { return nil }
        return configurationAliases.first { alias in
            let matchesType = alias.modelType == normalized
                || entries.values.contains { $0.aliases[normalized] == alias.modelType }
            return matchesType && autoModel?.hasSuffix(alias.autoModelSuffix) == true
        }?.loader ?? normalized
    }

    public func capabilities(for modelType: String, autoModel: String? = nil) -> Set<NativModelCapability> {
        Set(
            NativModelCapability.allCases.filter {
                loader(for: modelType, capability: $0, autoModel: autoModel) != nil
            }
        )
    }

    /// The speculative round-loop kind assigned by the bundled mlx-vlm
    /// runtime. Aliases are resolved through the same loader table first.
    public func drafterKind(for modelType: String) -> String? {
        guard
            let loader = loader(
                for: modelType,
                capability: .speculativeDrafters
            )
        else {
            return nil
        }
        return entries[.speculativeDrafters]?.kinds[loader]
    }

    private static func normalized(_ modelType: String) -> String? {
        let value = modelType.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value.isEmpty ? nil : value
    }

    private static let knownDrafterKinds: Set<String> = ["dflash", "eagle3", "mtp"]
}

private extension NativModelTypeRegistry {
    struct ConfigurationAlias: Decodable, Equatable, Sendable {
        let modelType: String
        let autoModelSuffix: String
        let loader: String
        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
            case autoModelSuffix = "auto_model_suffix"
            case loader
        }
    }

    struct Entry: Equatable, Sendable {
        let modelTypes: Set<String>
        let aliases: [String: String]
        let kinds: [String: String]
    }

    struct Manifest: Decodable {
        let configurationAliases: [ConfigurationAlias]?
        let schemaVersion: Int
        let packageVersions: [String: String]
        let capabilities: [String: ManifestEntry]

        enum CodingKeys: String, CodingKey {
            case configurationAliases = "configuration_aliases"
            case schemaVersion = "schema_version"
            case packageVersions = "package_versions"
            case capabilities
        }
    }

    struct ManifestEntry: Decodable {
        let modelTypes: [String]
        let aliases: [String: String]
        let kinds: [String: String]?

        enum CodingKeys: String, CodingKey {
            case modelTypes = "model_types"
            case aliases
            case kinds
        }
    }
}
