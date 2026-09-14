import Foundation

public struct NativExtensionCatalog: Decodable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let extensions: [NativExtensionCatalogEntry]
}

public struct NativExtensionCatalogEntry: Decodable, Equatable, Identifiable, Sendable {
    public enum Category: String, Decodable, Sendable {
        case writing = "Writing"
        case developer = "Developer"
        case productivity = "Productivity"
        case audio = "Audio"
        case vision = "Vision"
        case data = "Data"
        case other = "Other"
    }

    public enum Runtime: String, Decodable, Sendable {
        case declarative
    }

    public enum Status: String, Decodable, Sendable {
        case available
        case preview
    }

    public enum Trust: String, Decodable, Sendable {
        case firstParty
        case community
    }

    public struct Install: Decodable, Equatable, Sendable {
        public enum Kind: String, Decodable, Sendable {
            case package
        }

        public let kind: Kind
        public let url: String
        public let sha256: String
        public let bytes: UInt64
    }

    public let id: String
    public let displayName: String
    public let summary: String
    public let developer: String
    public let homepage: URL?
    public let version: String
    public let minimumNativVersion: String
    public let category: Category
    public let systemImage: String
    public let runtime: Runtime
    public let status: Status
    public let permissions: [String]
    public let trust: Trust
    public let featured: Bool?
    public let publishedAt: String
    public let install: Install

    public func isCompatible(with hostVersion: String) -> Bool {
        guard let host = NativSemanticVersion(hostVersion),
              let minimum = NativSemanticVersion(minimumNativVersion) else {
            return false
        }
        return host >= minimum
    }

    public func packageURL(relativeTo catalogURL: URL) throws -> URL {
        guard let components = URLComponents(string: install.url),
              components.scheme == nil,
              components.host == nil,
              !components.path.isEmpty,
              !components.path.hasPrefix("/") else {
            throw NativExtensionCatalogError.invalidInstallURL(extensionID: id)
        }

        guard let packageURL = URL(string: install.url, relativeTo: catalogURL)?.absoluteURL else {
            throw NativExtensionCatalogError.invalidInstallURL(extensionID: id)
        }
        return packageURL
    }
}

public enum NativExtensionCatalogError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case duplicateExtension(String)
    case invalidVersion(extensionID: String, version: String)
    case invalidHomepageURL(extensionID: String)
    case invalidChecksum(extensionID: String)
    case invalidInstallURL(extensionID: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "Extension catalog schema \(version) is not supported."
        case .duplicateExtension(let identifier):
            "The extension catalog contains \(identifier) more than once."
        case .invalidVersion(let identifier, let version):
            "The extension \(identifier) has an invalid version: \(version)."
        case .invalidHomepageURL(let identifier):
            "The extension \(identifier) has an invalid homepage URL."
        case .invalidChecksum(let identifier):
            "The extension \(identifier) has an invalid package checksum."
        case .invalidInstallURL(let identifier):
            "The extension \(identifier) has an invalid package URL."
        }
    }
}

public enum NativExtensionCatalogValidator {
    public static func validate(
        _ catalog: NativExtensionCatalog,
        sourceURL: URL
    ) throws {
        guard catalog.schemaVersion == NativExtensionCatalog.currentSchemaVersion else {
            throw NativExtensionCatalogError.unsupportedSchema(catalog.schemaVersion)
        }

        var identifiers = Set<String>()
        for entry in catalog.extensions {
            guard identifiers.insert(entry.id).inserted else {
                throw NativExtensionCatalogError.duplicateExtension(entry.id)
            }
            guard NativSemanticVersion(entry.version) != nil else {
                throw NativExtensionCatalogError.invalidVersion(
                    extensionID: entry.id,
                    version: entry.version
                )
            }
            guard NativSemanticVersion(entry.minimumNativVersion) != nil else {
                throw NativExtensionCatalogError.invalidVersion(
                    extensionID: entry.id,
                    version: entry.minimumNativVersion
                )
            }
            if let homepage = entry.homepage {
                guard let scheme = homepage.scheme?.lowercased(),
                      scheme == "https" || scheme == "http",
                      homepage.host != nil else {
                    throw NativExtensionCatalogError.invalidHomepageURL(extensionID: entry.id)
                }
            }
            guard entry.install.sha256.count == 64,
                  entry.install.sha256.unicodeScalars.allSatisfy({
                      (48...57).contains($0.value) || (97...102).contains($0.value)
                  }) else {
                throw NativExtensionCatalogError.invalidChecksum(extensionID: entry.id)
            }
            _ = try entry.packageURL(relativeTo: sourceURL)
        }
    }
}
