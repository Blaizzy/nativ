import CryptoKit
import Foundation

/// Locates the Hugging Face hub cache using the same environment variables
/// as the `huggingface_hub` Python library: `HF_HUB_CACHE` takes precedence,
/// then `HF_HOME` (with `/hub` appended), then a per-user default.
enum HuggingFaceCache {
    /// Cache location used when neither environment variable is set.
    static let fallbackHubPath = "~/.cache/huggingface/hub"

    /// Environment variables that locate the hub cache, in priority order.
    static let environmentVariableNames = ["HF_HUB_CACHE", "HF_HOME"]

    /// Whether the given environment already configures the hub cache.
    static func isConfigured(
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environmentVariableNames.contains { nonEmpty(environment[$0]) != nil }
    }

    /// The default hub cache path for the given environment.
    static func defaultHubPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let cachePath = nonEmpty(environment["HF_HUB_CACHE"]) {
            return cachePath
        }
        if let homePath = nonEmpty(environment["HF_HOME"]) {
            return (homePath as NSString).appendingPathComponent("hub")
        }
        return fallbackHubPath
    }

    /// The effective model search path given a persisted setting.
    ///
    /// Installations that never customized the search path still have the
    /// legacy hardcoded default persisted; re-resolve those against the
    /// environment so `HF_HOME` and `HF_HUB_CACHE` are honored.
    static func resolvedSearchPath(
        stored: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let defaultPath = defaultHubPath(environment: environment)
        guard let stored, nonEmpty(stored) != nil else {
            return defaultPath
        }
        let legacyPaths = [
            fallbackHubPath,
            (fallbackHubPath as NSString).expandingTildeInPath
        ]
        if legacyPaths.contains(stored), !legacyPaths.contains(defaultPath) {
            return defaultPath
        }
        return stored
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Resolves and applies Hugging Face authentication without persisting tokens
/// discovered in the process, login-shell environment, or local Hub login.
enum HuggingFaceTokenSource: Equatable, Sendable {
    case environment
    case credentialFile
}

struct HuggingFaceCredential: Equatable, Sendable {
    let token: String
    let source: HuggingFaceTokenSource
    let filePath: String?

    init(token: String, source: HuggingFaceTokenSource, filePath: String? = nil) {
        self.token = token
        self.source = source
        self.filePath = filePath
    }
}

struct HuggingFaceTokenInfo: Equatable, Sendable {
    let maskedValue: String
    let characterCount: Int
}

struct HuggingFaceTokenMetadata: Codable, Equatable, Sendable {
    let name: String?
    let permission: String?
}

enum HuggingFaceTokenMetadataCache {
    static func load(
        for token: String,
        from url: URL = storageURL
    ) -> HuggingFaceTokenMetadata? {
        guard let token = HuggingFaceAuthentication.normalizedToken(token),
              let data = try? Data(contentsOf: url),
              let record = try? PropertyListDecoder().decode(CacheRecord.self, from: data),
              record.tokenFingerprint == fingerprint(for: token) else {
            return nil
        }
        return record.metadata
    }

    static func save(
        _ metadata: HuggingFaceTokenMetadata,
        for token: String,
        to url: URL = storageURL
    ) throws {
        guard let token = HuggingFaceAuthentication.normalizedToken(token) else {
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let record = CacheRecord(
            tokenFingerprint: fingerprint(for: token),
            metadata: metadata
        )
        let data = try PropertyListEncoder().encode(record)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private struct CacheRecord: Codable {
        let tokenFingerprint: String
        let metadata: HuggingFaceTokenMetadata
    }

    private static func fingerprint(for token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static var storageURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        let baseURL = applicationSupport ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("HuggingFaceTokenMetadata.plist")
    }
}

enum HuggingFaceAuthenticationError: LocalizedError, Equatable {
    case environmentTokenCannotBeRemoved
    case missingCredentialFile
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .environmentTokenCannotBeRemoved:
            "HF_TOKEN is managed by your environment. Remove it from your shell configuration, then restart Nativ."
        case .missingCredentialFile:
            "Nativ could not locate the Hugging Face login file."
        case .invalidResponse:
            "Hugging Face returned an invalid authentication response."
        case .requestFailed(let statusCode):
            "Hugging Face rejected the authentication request (HTTP \(statusCode))."
        }
    }
}

enum HuggingFaceAuthentication {
    static let environmentVariableName = "HF_TOKEN"
    static let discoveryEnvironmentVariableNames = [
        environmentVariableName,
        "HF_TOKEN_PATH",
        "HF_HOME",
        "XDG_CACHE_HOME"
    ]
    private static let whoAmIURL = URL(string: "https://huggingface.co/api/whoami-v2")!
    private static let metadataSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func token(
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        normalizedToken(environment[environmentVariableName])
    }

    static func systemCredential(
        in environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        readTokenFile: (String) -> String? = {
            try? String(contentsOfFile: $0, encoding: .utf8)
        }
    ) -> HuggingFaceCredential? {
        if let token = token(in: environment) {
            return HuggingFaceCredential(token: token, source: .environment)
        }

        let path = credentialFilePath(
            environment: environment,
            homeDirectory: homeDirectory
        )
        guard let token = normalizedToken(readTokenFile(path)) else {
            return nil
        }
        return HuggingFaceCredential(
            token: token,
            source: .credentialFile,
            filePath: path
        )
    }

    static func credentialFilePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if let tokenPath = normalizedToken(environment["HF_TOKEN_PATH"]) {
            return expandHome(in: tokenPath, homeDirectory: homeDirectory)
        }
        if let huggingFaceHome = normalizedToken(environment["HF_HOME"]) {
            return (expandHome(in: huggingFaceHome, homeDirectory: homeDirectory) as NSString)
                .appendingPathComponent("token")
        }
        if let cacheHome = normalizedToken(environment["XDG_CACHE_HOME"]) {
            return (expandHome(in: cacheHome, homeDirectory: homeDirectory) as NSString)
                .appendingPathComponent("huggingface/token")
        }
        return (homeDirectory as NSString).appendingPathComponent(".cache/huggingface/token")
    }

    static func effectiveToken(customToken: String?, environmentToken: String?) -> String? {
        normalizedToken(customToken) ?? normalizedToken(environmentToken)
    }

    static func authorize(_ request: inout URLRequest, token: String?) {
        guard let token = normalizedToken(token) else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    static func normalizedToken(_ token: String?) -> String? {
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func tokenInfo(_ token: String?) -> HuggingFaceTokenInfo? {
        guard let token = normalizedToken(token) else {
            return nil
        }

        let prefix = token.hasPrefix("hf_") ? "hf_" : ""
        let suffix = token.count > 8 ? String(token.suffix(4)) : ""
        return HuggingFaceTokenInfo(
            maskedValue: "\(prefix)••••••••\(suffix)",
            characterCount: token.count
        )
    }

    static func tokenMetadata(for token: String) async throws -> HuggingFaceTokenMetadata {
        guard let token = normalizedToken(token) else {
            throw HuggingFaceAuthenticationError.invalidResponse
        }

        var request = URLRequest(
            url: whoAmIURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Nativ/1.0", forHTTPHeaderField: "User-Agent")
        authorize(&request, token: token)

        let (data, response) = try await metadataSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HuggingFaceAuthenticationError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw HuggingFaceAuthenticationError.requestFailed(httpResponse.statusCode)
        }
        return try decodeTokenMetadata(from: data)
    }

    static func logIn(
        token: String,
        tokenName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) throws -> HuggingFaceCredential {
        guard let token = normalizedToken(token),
              let tokenName = normalizedToken(tokenName),
              !tokenName.contains("\n"),
              !tokenName.contains("\r"),
              !tokenName.contains("["),
              !tokenName.contains("]") else {
            throw HuggingFaceAuthenticationError.invalidResponse
        }

        let activeTokenPath = credentialFilePath(
            environment: environment,
            homeDirectory: homeDirectory
        )
        let storedTokensPath = (activeTokenPath as NSString)
            .deletingLastPathComponent
            .appending("/stored_tokens")

        var storedTokens = try readStoredTokens(
            at: storedTokensPath,
            fileManager: fileManager
        )
        storedTokens[tokenName] = token
        try writeSecret(
            serializeStoredTokens(storedTokens),
            to: storedTokensPath,
            fileManager: fileManager
        )
        try writeSecret(
            token,
            to: activeTokenPath,
            fileManager: fileManager
        )

        return HuggingFaceCredential(
            token: token,
            source: .credentialFile,
            filePath: activeTokenPath
        )
    }

    static func decodeTokenMetadata(from data: Data) throws -> HuggingFaceTokenMetadata {
        let response = try JSONDecoder().decode(HuggingFaceWhoAmIResponse.self, from: data)
        return HuggingFaceTokenMetadata(
            name: normalizedToken(response.auth?.accessToken?.displayName),
            permission: normalizedToken(response.auth?.accessToken?.role)
        )
    }

    static func logOut(
        credential: HuggingFaceCredential,
        removeCredentialFile: (String) throws -> Void = {
            try FileManager.default.removeItem(atPath: $0)
        }
    ) throws {
        guard credential.source == .credentialFile else {
            throw HuggingFaceAuthenticationError.environmentTokenCannotBeRemoved
        }
        guard let filePath = credential.filePath else {
            throw HuggingFaceAuthenticationError.missingCredentialFile
        }
        try removeCredentialFile(filePath)
    }

    private static func readStoredTokens(
        at path: String,
        fileManager: FileManager
    ) throws -> [String: String] {
        guard fileManager.fileExists(atPath: path) else {
            return [:]
        }

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        var storedTokens: [String: String] = [:]
        var currentSection: String?

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("["), line.hasSuffix("]"), line.count > 2 {
                currentSection = String(line.dropFirst().dropLast())
                continue
            }
            guard let currentSection,
                  let separator = line.firstIndex(of: "=") else {
                continue
            }

            let key = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard key == "hf_token" else {
                continue
            }

            let value = String(line[line.index(after: separator)...])
            if let token = normalizedToken(value) {
                storedTokens[currentSection] = token
            }
        }
        return storedTokens
    }

    private static func serializeStoredTokens(_ storedTokens: [String: String]) -> String {
        storedTokens.keys.sorted().map { tokenName in
            """
            [\(tokenName)]
            hf_token = \(storedTokens[tokenName] ?? "")
            """
        }
        .joined(separator: "\n\n")
        + "\n"
    }

    private static func writeSecret(
        _ contents: String,
        to path: String,
        fileManager: FileManager
    ) throws {
        let url = URL(fileURLWithPath: path)
        let directoryURL = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(contents.utf8).write(to: url, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    private static func expandHome(in path: String, homeDirectory: String) -> String {
        if path == "~" {
            return homeDirectory
        }
        guard path.hasPrefix("~/") else {
            return path
        }
        return (homeDirectory as NSString).appendingPathComponent(String(path.dropFirst(2)))
    }
}

private struct HuggingFaceWhoAmIResponse: Decodable {
    let auth: Authentication?

    struct Authentication: Decodable {
        let accessToken: AccessToken?
    }

    struct AccessToken: Decodable {
        let displayName: String?
        let role: String?
    }
}
