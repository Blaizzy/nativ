import Foundation
import NativExtensionSDK

enum NativExtensionPackageError: LocalizedError, Equatable {
    case packageMustBeDirectory
    case missingManifest
    case duplicateIdentifier(String)
    case externalPackageClaimsIncluded
    case unsupportedExternalRuntime
    case runtimeUnavailable
    case olderVersionRejected(identifier: String, installed: String, candidate: String)
    case malformedManifest(String)

    var errorDescription: String? {
        switch self {
        case .packageMustBeDirectory:
            "Choose a .nativextension package."
        case .missingManifest:
            "The extension package does not contain Manifest.json."
        case .duplicateIdentifier(let identifier):
            "An extension with the identifier “\(identifier)” is already included with Nativ."
        case .externalPackageClaimsIncluded:
            "Only extensions shipped inside Nativ can declare themselves as included."
        case .unsupportedExternalRuntime:
            "An installed extension must declare the extensionFoundation runtime."
        case .runtimeUnavailable:
            "The extension was installed, but its ExtensionFoundation runtime is not available yet."
        case .olderVersionRejected(let identifier, let installed, let candidate):
            "“\(identifier)” \(installed) is already installed. Remove it before installing \(candidate)."
        case .malformedManifest(let detail):
            detail
        }
    }
}

/// An installed package and where it lives on disk.
struct NativExtensionInstalledPackage: Sendable {
    let manifest: NativExtensionManifest
    let packageURL: URL
}

/// A package that could not be loaded, kept so the Extensions page can explain
/// the failure instead of leaving the package silently absent.
struct NativExtensionPackageIssue: Identifiable, Hashable, Sendable {
    let packageURL: URL
    let message: String

    var id: URL { packageURL }
    var packageName: String { packageURL.lastPathComponent }
}

/// Filesystem half of the extension platform: reading, validating, installing,
/// and removing `.nativextension` packages.
///
/// Deliberately free of AppKit, ExtensionFoundation, and `@MainActor` so the
/// install rules can be exercised directly in tests.
struct NativExtensionPackageInstaller {
    /// Staging directories are hidden so a partially copied package is never
    /// mistaken for an installed one; they are swept on load.
    static let stagingPrefix = ".install-"
    static let packageExtension = "nativextension"

    let fileManager: FileManager
    let extensionsDirectory: URL
    let hostVersion: String

    struct LoadResult {
        let manifests: [String: NativExtensionInstalledPackage]
        let issues: [NativExtensionPackageIssue]
    }

    struct InstallResult {
        let manifest: NativExtensionManifest
        let replaced: NativExtensionManifest?

        /// A package asking for more than the previous version has to be
        /// reviewed again. Asking for the same or less inherits the state the
        /// user already chose, so a strictly safer update does not disable it.
        var requiresReconsent: Bool {
            guard let replaced else { return true }
            return !Set(manifest.permissions).isSubset(of: Set(replaced.permissions))
        }
    }

    func loadManifest(at packageURL: URL) throws -> NativExtensionManifest {
        let manifestURL = packageURL.appendingPathComponent("Manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw NativExtensionPackageError.missingManifest
        }
        let manifest: NativExtensionManifest
        do {
            manifest = try JSONDecoder().decode(
                NativExtensionManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch let error as DecodingError {
            throw NativExtensionPackageError.malformedManifest(Self.describe(error))
        }
        try NativExtensionManifestValidator.validate(manifest, hostVersion: hostVersion)
        return manifest
    }

    /// `DecodingError`'s own description does not name the offending field, which
    /// is the only thing an extension author needs in order to fix the file.
    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            let parent = path(context)
            let location = parent.isEmpty ? "" : " in “\(parent)”"
            return "Manifest.json is missing the required field “\(key.stringValue)”\(location)."
        case .typeMismatch(_, let context),
             .valueNotFound(_, let context),
             .dataCorrupted(let context):
            let field = path(context)
            return field.isEmpty
                ? "Manifest.json is not valid JSON."
                : "Manifest.json has an unexpected value for “\(field)”."
        @unknown default:
            return "Manifest.json could not be read."
        }
    }

    func loadInstalledPackages(
        reservedIdentifiers: Set<String>
    ) -> LoadResult {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: extensionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return LoadResult(manifests: [:], issues: [])
        }

        var manifests: [String: NativExtensionInstalledPackage] = [:]
        var issues: [NativExtensionPackageIssue] = []
        for entry in entries {
            // Staging directories are hidden, so this pass is the only thing
            // that ever sees one orphaned by an interrupted install.
            if entry.lastPathComponent.hasPrefix(Self.stagingPrefix) {
                try? fileManager.removeItem(at: entry)
                continue
            }
            guard entry.pathExtension == Self.packageExtension else {
                continue
            }
            do {
                let manifest = try loadManifest(at: entry)
                guard !reservedIdentifiers.contains(manifest.id) else {
                    continue
                }
                manifests[manifest.id] = NativExtensionInstalledPackage(
                    manifest: manifest,
                    packageURL: entry
                )
            } catch {
                issues.append(
                    NativExtensionPackageIssue(
                        packageURL: entry,
                        message: error.localizedDescription
                    )
                )
            }
        }
        return LoadResult(manifests: manifests, issues: issues)
    }

    @discardableResult
    func install(
        from sourceURL: URL,
        reservedIdentifiers: Set<String>
    ) throws -> InstallResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              sourceURL.pathExtension == Self.packageExtension else {
            throw NativExtensionPackageError.packageMustBeDirectory
        }

        let manifest = try loadManifest(at: sourceURL)
        guard !reservedIdentifiers.contains(manifest.id) else {
            throw NativExtensionPackageError.duplicateIdentifier(manifest.id)
        }
        guard !manifest.included else {
            throw NativExtensionPackageError.externalPackageClaimsIncluded
        }
        // The builtIn runtime means the code ships inside Nativ, so an installed
        // package declaring it has nothing to run and would otherwise sit in the
        // list forever reporting a missing runtime.
        guard manifest.runtime == .extensionFoundation else {
            throw NativExtensionPackageError.unsupportedExternalRuntime
        }

        let destinationURL = packageURL(for: manifest.id)
        let replaced = try? loadManifest(at: destinationURL)
        if let replaced,
           let candidateVersion = NativSemanticVersion(manifest.version),
           let installedVersion = NativSemanticVersion(replaced.version),
           candidateVersion < installedVersion {
            throw NativExtensionPackageError.olderVersionRejected(
                identifier: manifest.id,
                installed: installedVersion.description,
                candidate: candidateVersion.description
            )
        }

        try fileManager.createDirectory(
            at: extensionsDirectory,
            withIntermediateDirectories: true
        )
        let stagingURL = extensionsDirectory.appendingPathComponent(
            "\(Self.stagingPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
            } else {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        return InstallResult(manifest: manifest, replaced: replaced)
    }

    func removePackage(at packageURL: URL) throws {
        try fileManager.removeItem(at: packageURL)
    }

    func packageURL(for identifier: String) -> URL {
        extensionsDirectory.appendingPathComponent(
            "\(identifier).\(Self.packageExtension)",
            isDirectory: true
        )
    }
}
