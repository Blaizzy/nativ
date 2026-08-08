import Foundation

/// The CLI's only coupling to the Nativ app: a small, documented handshake —
/// flags → env → a JSON file the app writes → defaults. All fields optional and
/// read defensively, so the app's internal settings can change freely without
/// breaking the CLI.
struct NativConfig {
    var baseURL: URL
    var apiKey: String?
    var defaultModel: String?
    var modelSearchPath: String?

    static let supportDir = ("~/Library/Application Support/Nativ" as NSString).expandingTildeInPath
    static var filePath: String { (supportDir as NSString).appendingPathComponent("cli.json") }

    private struct FileConfig: Codable {
        var baseURL: String?
        var apiKey: String?
        var defaultModel: String?
        var modelSearchPath: String?
    }

    static func resolve(baseURL flagBase: String?, apiKey flagKey: String?, model flagModel: String?) -> NativConfig {
        let file = loadFile()
        let env = ProcessInfo.processInfo.environment
        let baseStr = flagBase ?? env["NATIV_BASE_URL"] ?? file?.baseURL ?? "http://127.0.0.1:8080"
        return NativConfig(
            baseURL: URL(string: baseStr) ?? URL(string: "http://127.0.0.1:8080")!,
            apiKey: flagKey ?? env["NATIV_API_KEY"] ?? file?.apiKey,
            defaultModel: flagModel ?? env["NATIV_MODEL"] ?? file?.defaultModel,
            modelSearchPath: env["NATIV_MODEL_PATH"] ?? file?.modelSearchPath
        )
    }

    private static func loadFile() -> FileConfig? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return nil }
        return try? JSONDecoder().decode(FileConfig.self, from: data)
    }

    /// Persist the chosen default model into the handshake file (merge-write),
    /// so `nativ run` picks it up and the app can read it too.
    static func setDefaultModel(_ id: String) throws {
        try FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        var file = loadFile() ?? FileConfig()
        file.defaultModel = id
        let data = try JSONEncoder().encode(file)
        try data.write(to: URL(fileURLWithPath: filePath))
    }
}
