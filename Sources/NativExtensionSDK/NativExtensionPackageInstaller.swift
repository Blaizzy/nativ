import Foundation

public enum NativExtensionPackageError: LocalizedError, Equatable {
    case packageMustBeDirectory
    case missingManifest
    case duplicateIdentifier(String)
    case externalPackageClaimsIncluded
    case unsupportedExternalRuntime
    case missingWorkflowDocument
    case unsupportedDashboard
    case documentTooLarge(String)
    case runtimeUnavailable
    case olderVersionRejected(identifier: String, installed: String, candidate: String)
    case malformedManifest(String)

    public var errorDescription: String? {
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
            "Only extensions shipped inside Nativ can use the builtIn runtime."
        case .unsupportedDashboard:
            "Declarative dashboards are not supported by this version of Nativ."
        case .documentTooLarge(let name):
            "\(name) exceeds the 1 MiB document limit."
        case .missingWorkflowDocument:
            "The extension package does not contain Workflow.json."
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
public struct NativExtensionInstalledPackage: Sendable {
    public let manifest: NativExtensionManifest
    public let packageURL: URL
    /// Present only for the declarative runtime, and only once validated.
    public let workflow: NativExtensionWorkflow?

    public init(
        manifest: NativExtensionManifest,
        packageURL: URL,
        workflow: NativExtensionWorkflow?
    ) {
        self.manifest = manifest
        self.packageURL = packageURL
        self.workflow = workflow
    }
}

/// A package that could not be loaded, kept so the Extensions page can explain
/// the failure instead of leaving the package silently absent.
public struct NativExtensionPackageIssue: Identifiable, Hashable, Sendable {
    public let packageURL: URL
    public let message: String

    public init(packageURL: URL, message: String) {
        self.packageURL = packageURL
        self.message = message
    }

    public var id: URL { packageURL }
    public var packageName: String { packageURL.lastPathComponent }
}

/// Filesystem half of the extension platform: reading, validating, installing,
/// and removing `.nativextension` packages.
///
/// Deliberately free of AppKit, ExtensionFoundation, and `@MainActor` so the
/// install rules can be exercised directly in tests.
public struct NativExtensionPackageInstaller {
    /// Staging directories are hidden so a partially copied package is never
    /// mistaken for an installed one; they are swept on load.
    public static let stagingPrefix = ".install-"
    public static let packageExtension = "nativextension"
    public static let maximumDocumentBytes = 1_048_576

    public let fileManager: FileManager
    public let extensionsDirectory: URL
    public let hostVersion: String

    public init(fileManager: FileManager, extensionsDirectory: URL, hostVersion: String) {
        self.fileManager = fileManager
        self.extensionsDirectory = extensionsDirectory
        self.hostVersion = hostVersion
    }

    public struct LoadResult {
        public let manifests: [String: NativExtensionInstalledPackage]
        public let issues: [NativExtensionPackageIssue]
    }

    public struct InstallResult {
        public let manifest: NativExtensionManifest
        public let replaced: NativExtensionManifest?

        /// A package asking for more than the previous version has to be
        /// reviewed again. Asking for the same or less inherits the state the
        /// user already chose, so a strictly safer update does not disable it.
        public var requiresReconsent: Bool {
            guard let replaced else { return true }
            return !Set(manifest.permissions).isSubset(of: Set(replaced.permissions))
        }
    }

    private func readDocument(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumDocumentBytes + 1) ?? Data()
        guard data.count <= Self.maximumDocumentBytes else {
            throw NativExtensionPackageError.documentTooLarge(url.lastPathComponent)
        }
        return data
    }

    public func loadManifest(at packageURL: URL) throws -> NativExtensionManifest {
        let manifestURL = packageURL.appendingPathComponent("Manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw NativExtensionPackageError.missingManifest
        }
        let manifest: NativExtensionManifest
        do {
            manifest = try JSONDecoder().decode(
                NativExtensionManifest.self,
                from: readDocument(at: manifestURL)
            )
        } catch let error as DecodingError {
            throw NativExtensionPackageError.malformedManifest(Self.describe(error))
        }
        try NativExtensionManifestValidator.validate(manifest, hostVersion: hostVersion)
        return manifest
    }

    /// `DecodingError`'s own description does not name the offending field, which
    /// is the only thing an extension author needs in order to fix the file.
    private static func describe(
        _ error: DecodingError,
        document: String = "Manifest.json"
    ) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            let parent = path(context)
            let location = parent.isEmpty ? "" : " in “\(parent)”"
            return "\(document) is missing the required field “\(key.stringValue)”\(location)."
        case .typeMismatch(_, let context),
             .valueNotFound(_, let context),
             .dataCorrupted(let context):
            let field = path(context)
            return field.isEmpty
                ? "\(document) is not valid JSON."
                : "\(document) has an unexpected value for “\(field)”."
        @unknown default:
            return "\(document) could not be read."
        }
    }

    /// Reads and validates `Workflow.json`, or returns nil for a runtime that
    /// does not use one.
    public func loadWorkflow(
        at packageURL: URL,
        manifest: NativExtensionManifest
    ) throws -> NativExtensionWorkflow? {
        guard manifest.runtime == .declarative else {
            return nil
        }
        guard manifest.dashboard == nil, manifest.contributions.sidebar.isEmpty else {
            throw NativExtensionPackageError.unsupportedDashboard
        }
        let workflowURL = packageURL.appendingPathComponent(
            NativExtensionManifest.workflowDocumentName
        )
        guard fileManager.fileExists(atPath: workflowURL.path) else {
            throw NativExtensionPackageError.missingWorkflowDocument
        }
        let workflow: NativExtensionWorkflow
        do {
            workflow = try JSONDecoder().decode(
                NativExtensionWorkflow.self,
                from: readDocument(at: workflowURL)
            )
        } catch let error as DecodingError {
            throw NativExtensionPackageError.malformedManifest(
                Self.describe(error, document: NativExtensionManifest.workflowDocumentName)
            )
        }
        try NativExtensionWorkflowValidator.validate(workflow, manifest: manifest)
        return workflow
    }

    public func loadInstalledPackages(
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
                    packageURL: entry,
                    workflow: try loadWorkflow(at: entry, manifest: manifest)
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

    /// Everything that decides whether a package may be installed, and nothing
    /// that changes the disk.
    ///
    /// Split out so the same rules can be run somewhere there is no Nativ to
    /// install into — a submission checked in a catalog's CI reaches exactly
    /// the verdict the app would.
    @discardableResult
    public func validate(
        packageAt sourceURL: URL,
        reservedIdentifiers: Set<String> = []
    ) throws -> NativExtensionManifest {
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
        guard manifest.runtime != .builtIn else {
            throw NativExtensionPackageError.unsupportedExternalRuntime
        }
        _ = try loadWorkflow(at: sourceURL, manifest: manifest)
        return manifest
    }

    @discardableResult
    public func install(
        from sourceURL: URL,
        reservedIdentifiers: Set<String>
    ) throws -> InstallResult {
        // Refuse before copying, so a package that could never run is never
        // half-installed.
        let manifest = try validate(
            packageAt: sourceURL,
            reservedIdentifiers: reservedIdentifiers
        )

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

    public func removePackage(at packageURL: URL) throws {
        try fileManager.removeItem(at: packageURL)
    }

    public func packageURL(for identifier: String) -> URL {
        extensionsDirectory.appendingPathComponent(
            "\(identifier).\(Self.packageExtension)",
            isDirectory: true
        )
    }
}
