import Foundation

enum CodexCLIProfile {
    static let name = "nativ"
    static let providerID = "nativ"
    static let baseURL = "http://127.0.0.1:8080/v1"

    static func configurationURL(in homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".codex/\(name).config.toml")
    }

    static func write(
        selectedModelID: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        let url = configurationURL(in: homeDirectory)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents(selectedModelID: selectedModelID).utf8).write(to: url, options: .atomic)
    }

    static func contents(selectedModelID: String) -> String {
        """
        # Managed by Nativ. Loaded only by `codex --profile nativ`.
        model = \(tomlString(selectedModelID))
        model_provider = \(tomlString(providerID))

        [model_providers.\(tomlString(providerID))]
        name = "Nativ"
        base_url = \(tomlString(baseURL))
        wire_api = "responses"

        """
    }

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
