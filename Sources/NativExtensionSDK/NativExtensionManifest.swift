import Foundation

public enum NativExtensionRuntimeKind: String, Codable, Hashable, Sendable {
    case builtIn
    case extensionFoundation
}

public enum NativExtensionPermission: String, Codable, CaseIterable, Hashable, Sendable {
    case microphone
    case systemAudioCapture = "audio.systemCapture"
    case accessibilityInsertText = "accessibility.insertText"
    case modelsSpeechToText = "models.speechToText"
    case overlay
    case notifications
    case namespacedStorage = "storage.namespaced"

    public var displayName: String {
        switch self {
        case .microphone:
            "Microphone"
        case .systemAudioCapture:
            "System audio"
        case .accessibilityInsertText:
            "Insert text"
        case .modelsSpeechToText:
            "Speech-to-text models"
        case .overlay:
            "Screen overlay"
        case .notifications:
            "Notifications"
        case .namespacedStorage:
            "Extension storage"
        }
    }
}

public struct NativSidebarContribution: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let order: Int

    public init(id: String, title: String, systemImage: String, order: Int = 500) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.order = order
    }
}

public struct NativCommandContribution: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String?

    public init(id: String, title: String, systemImage: String? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }
}

public struct NativShortcutContribution: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let defaultShortcut: String?

    public init(id: String, title: String, defaultShortcut: String? = nil) {
        self.id = id
        self.title = title
        self.defaultShortcut = defaultShortcut
    }
}

public struct NativSettingsContribution: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct NativExtensionContributions: Codable, Hashable, Sendable {
    public let sidebar: [NativSidebarContribution]
    public let commands: [NativCommandContribution]
    public let shortcuts: [NativShortcutContribution]
    public let settings: [NativSettingsContribution]

    public init(
        sidebar: [NativSidebarContribution] = [],
        commands: [NativCommandContribution] = [],
        shortcuts: [NativShortcutContribution] = [],
        settings: [NativSettingsContribution] = []
    ) {
        self.sidebar = sidebar
        self.commands = commands
        self.shortcuts = shortcuts
        self.settings = settings
    }
}

public struct NativExtensionManifest: Codable, Hashable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let version: String
    public let minimumNativVersion: String
    public let displayName: String
    public let summary: String
    public let developer: String
    public let systemImage: String
    public let included: Bool
    public let runtime: NativExtensionRuntimeKind
    public let extensionPoint: String
    public let runtimeBundleIdentifier: String?
    public let contributions: NativExtensionContributions
    public let permissions: [NativExtensionPermission]

    public init(
        schemaVersion: Int = NativExtensionManifest.currentSchemaVersion,
        id: String,
        version: String,
        minimumNativVersion: String,
        displayName: String,
        summary: String,
        developer: String,
        systemImage: String,
        included: Bool,
        runtime: NativExtensionRuntimeKind,
        extensionPoint: String = "com.nativ.extension",
        runtimeBundleIdentifier: String? = nil,
        contributions: NativExtensionContributions = .init(),
        permissions: [NativExtensionPermission] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.minimumNativVersion = minimumNativVersion
        self.displayName = displayName
        self.summary = summary
        self.developer = developer
        self.systemImage = systemImage
        self.included = included
        self.runtime = runtime
        self.extensionPoint = extensionPoint
        self.runtimeBundleIdentifier = runtimeBundleIdentifier
        self.contributions = contributions
        self.permissions = permissions
    }
}

public enum NativExtensionManifestError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case invalidIdentifier(String)
    case invalidVersion(String)
    case missingRuntimeBundleIdentifier
    case incompatibleHost(required: String, current: String)
    case invalidContributionIdentifier(String)
    case duplicateContribution(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "Extension manifest schema \(version) is not supported."
        case .invalidIdentifier(let identifier):
            "“\(identifier)” is not a valid extension identifier."
        case .invalidVersion(let version):
            "“\(version)” is not a valid semantic version."
        case .missingRuntimeBundleIdentifier:
            "An ExtensionFoundation extension must declare a runtime bundle identifier."
        case .incompatibleHost(let required, let current):
            "This extension requires Nativ \(required) or later. This copy is \(current)."
        case .invalidContributionIdentifier(let identifier):
            "The contribution identifier “\(identifier)” must belong to the extension."
        case .duplicateContribution(let identifier):
            "The extension declares “\(identifier)” more than once."
        }
    }
}

public enum NativExtensionManifestValidator {
    public static func validate(
        _ manifest: NativExtensionManifest,
        hostVersion: String
    ) throws {
        guard manifest.schemaVersion == NativExtensionManifest.currentSchemaVersion else {
            throw NativExtensionManifestError.unsupportedSchema(manifest.schemaVersion)
        }
        guard isValidIdentifier(manifest.id) else {
            throw NativExtensionManifestError.invalidIdentifier(manifest.id)
        }
        guard isValidIdentifier(manifest.extensionPoint) else {
            throw NativExtensionManifestError.invalidIdentifier(manifest.extensionPoint)
        }
        if manifest.runtime == .extensionFoundation {
            guard let runtimeBundleIdentifier = manifest.runtimeBundleIdentifier,
                  isValidIdentifier(runtimeBundleIdentifier) else {
                throw NativExtensionManifestError.missingRuntimeBundleIdentifier
            }
        }
        guard let extensionVersion = NativSemanticVersion(manifest.version) else {
            throw NativExtensionManifestError.invalidVersion(manifest.version)
        }
        guard let requiredVersion = NativSemanticVersion(manifest.minimumNativVersion) else {
            throw NativExtensionManifestError.invalidVersion(manifest.minimumNativVersion)
        }
        guard let currentVersion = NativSemanticVersion(hostVersion) else {
            throw NativExtensionManifestError.invalidVersion(hostVersion)
        }
        guard currentVersion >= requiredVersion else {
            throw NativExtensionManifestError.incompatibleHost(
                required: requiredVersion.description,
                current: currentVersion.description
            )
        }
        _ = extensionVersion

        let identifiers =
            manifest.contributions.sidebar.map(\.id)
            + manifest.contributions.commands.map(\.id)
            + manifest.contributions.shortcuts.map(\.id)
            + manifest.contributions.settings.map(\.id)
        var seen = Set<String>()
        for identifier in identifiers {
            guard identifier.hasPrefix("\(manifest.id)."),
                  isValidIdentifier(identifier) else {
                throw NativExtensionManifestError.invalidContributionIdentifier(identifier)
            }
            guard seen.insert(identifier).inserted else {
                throw NativExtensionManifestError.duplicateContribution(identifier)
            }
        }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return components.allSatisfy { component in
            !component.isEmpty
                && component.unicodeScalars.allSatisfy { allowed.contains($0) }
                && component.first?.isNumber == false
        }
    }
}

public struct NativSemanticVersion: Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ value: String) {
        let core = value.split(separator: "-", maxSplits: 1).first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              let major = Int(parts[0]),
              let minor = parts.count > 1 ? Int(parts[1]) : 0,
              let patch = parts.count > 2 ? Int(parts[2]) : 0,
              major >= 0,
              minor >= 0,
              patch >= 0 else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
