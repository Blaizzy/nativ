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
}

enum HuggingFaceAuthentication {
    static let environmentVariableName = "HF_TOKEN"
    static let discoveryEnvironmentVariableNames = [
        environmentVariableName,
        "HF_TOKEN_PATH",
        "HF_HOME",
        "XDG_CACHE_HOME"
    ]

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
        return HuggingFaceCredential(token: token, source: .credentialFile)
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

    static func tokenSummary(_ token: String?) -> String? {
        guard let token = normalizedToken(token) else {
            return nil
        }

        let prefix = token.hasPrefix("hf_") ? "hf_" : ""
        let suffix = token.count > 8 ? String(token.suffix(4)) : ""
        let characterLabel = token.count == 1 ? "character" : "characters"
        return "\(prefix)••••••••\(suffix) · \(token.count) \(characterLabel)"
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
