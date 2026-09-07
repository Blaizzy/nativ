import Darwin
import Foundation

enum FileWriteAccessError: Error, Equatable, Sendable {
    case notConfigured
    case invalidPath
    case outsideAllowedRoot
    case sensitivePath
    case binaryDocument
}

enum FileWriteApprovalRequirement: String, Equatable, Sendable {
    case protectedInstructions
    case credentialConfiguration
}

struct ResolvedFileWritePath: Equatable, Sendable {
    let url: URL
    let displayPath: String
    let approvalRequirement: FileWriteApprovalRequirement?
}

struct FileWriteAccessPolicy: Sendable {
    static let binaryDocumentExtensions: Set<String> = [
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "pdf", "rtf",
    ]

    let rootURL: URL

    init(rootPath: String?) throws {
        guard let rootURL = Self.configuredRootURL(rootPath: rootPath) else {
            throw FileWriteAccessError.notConfigured
        }
        self.rootURL = rootURL
    }

    static func isConfigured(rootPath: String?) -> Bool {
        configuredRootURL(rootPath: rootPath) != nil
    }

    static func configuredRootURL(rootPath: String?) -> URL? {
        guard let root = FileReadAccessPolicy.configuredRootURL(rootPath: rootPath),
            FileManager.default.isWritableFile(atPath: root.path)
        else {
            return nil
        }
        return root
    }

    func resolve(path: String, permitsBinaryDocument: Bool = false) throws -> ResolvedFileWritePath
    {
        guard !path.isEmpty, !path.utf8.contains(0) else {
            throw FileWriteAccessError.invalidPath
        }

        let expanded =
            path == "~" || path.hasPrefix("~/")
            ? NSString(string: path).expandingTildeInPath
            : path
        let candidate =
            expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : rootURL.appendingPathComponent(expanded)
        let standardized = candidate.standardizedFileURL
        let resolved = Self.canonicalURL(standardized)

        guard contains(resolved) else {
            throw FileWriteAccessError.outsideAllowedRoot
        }
        try Self.rejectSensitivePath(standardized)
        try Self.rejectSensitivePath(resolved)
        if !permitsBinaryDocument,
            Self.binaryDocumentExtensions.contains(resolved.pathExtension.lowercased())
        {
            throw FileWriteAccessError.binaryDocument
        }

        return ResolvedFileWritePath(
            url: resolved,
            displayPath: displayPath(for: resolved),
            approvalRequirement: Self.approvalRequirement(for: standardized)
                ?? Self.approvalRequirement(for: resolved)
        )
    }

    func contains(_ url: URL) -> Bool {
        let rootComponents = rootURL.pathComponents
        let targetComponents = url.pathComponents
        guard targetComponents.count >= rootComponents.count else { return false }
        return zip(rootComponents, targetComponents).allSatisfy { $0 == $1 }
    }

    func displayPath(for url: URL) -> String {
        let rootComponents = rootURL.pathComponents
        let targetComponents = url.pathComponents
        guard targetComponents.count >= rootComponents.count,
            zip(rootComponents, targetComponents).allSatisfy({ $0 == $1 })
        else {
            return url.lastPathComponent
        }
        let relative = targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
        return relative.isEmpty ? "." : relative
    }

    private static func rejectSensitivePath(_ url: URL) throws {
        let path = url.path.lowercased()
        let blockedRoots = [
            "/boot", "/dev", "/etc", "/proc", "/sys", "/system", "/bin", "/sbin",
            "/usr", "/library", "/private/etc",
        ]
        if blockedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
            || path == "/var/run/docker.sock"
            || path == "/private/var/run/docker.sock"
        {
            throw FileWriteAccessError.sensitivePath
        }
        if path.contains("/library/application support/nativ/")
            || path.hasSuffix("/library/application support/nativ")
        {
            throw FileWriteAccessError.sensitivePath
        }

        let name = url.lastPathComponent.lowercased()
        let blockedNames: Set<String> = [
            "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials",
            "credentials.json", "application_default_credentials.json",
        ]
        let blockedExtensions: Set<String> = ["key", "pem", "p12", "pfx", "jks"]
        if blockedNames.contains(name) || blockedExtensions.contains(url.pathExtension.lowercased())
        {
            throw FileWriteAccessError.sensitivePath
        }
    }

    private static func approvalRequirement(for url: URL) -> FileWriteApprovalRequirement? {
        let name = url.lastPathComponent.lowercased()
        let protectedNames: Set<String> = [
            "agents.md", "claude.md", "gemini.md", ".cursorrules",
            "copilot-instructions.md", ".windsurfrules",
        ]
        if protectedNames.contains(name) {
            return .protectedInstructions
        }

        let components = url.pathComponents.map { $0.lowercased() }
        let credentialNames: Set<String> = [
            "config", "authorized_keys", ".netrc", ".npmrc", ".pypirc", ".gitconfig",
        ]
        if name == ".env" || name.hasPrefix(".env.")
            || credentialNames.contains(name)
            || components.contains(".ssh")
            || components.contains(".aws")
            || components.contains(".gnupg")
        {
            return .credentialConfiguration
        }
        return nil
    }

    private static func canonicalURL(_ url: URL) -> URL {
        var cursor = url.standardizedFileURL
        var unresolved: [String] = []
        while true {
            if let resolvedPath = resolvedPath(cursor.path) {
                return unresolved.reversed().reduce(URL(fileURLWithPath: resolvedPath)) {
                    $0.appendingPathComponent($1)
                }
            }
            guard cursor.path != "/" else { return url.standardizedFileURL }
            unresolved.append(cursor.lastPathComponent)
            cursor.deleteLastPathComponent()
        }
    }

    private static func resolvedPath(_ path: String) -> String? {
        guard let pointer = Darwin.realpath(path, nil) else { return nil }
        defer { Darwin.free(pointer) }
        return String(cString: pointer)
    }
}
