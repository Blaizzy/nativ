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
