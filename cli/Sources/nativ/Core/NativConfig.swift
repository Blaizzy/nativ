import Foundation

/// The CLI's only coupling to the Nativ app: a small, documented handshake —
/// flags → env → a JSON file (the app writes it, or `nativ config set`) →
/// defaults. All fields optional and read defensively, so the app's internal
/// settings can change freely without breaking the CLI.
struct NativConfig {
    var baseURL: URL
    var apiKey: String?
    var defaultModel: String?
    var embeddingModel: String?
    var imageModel: String?
    var sttModel: String?
    var ttsModel: String?
    var modelSearchPath: String?

    static let supportDir = ("~/Library/Application Support/Nativ" as NSString).expandingTildeInPath
    static var filePath: String { (supportDir as NSString).appendingPathComponent("cli.json") }

    struct FileConfig: Codable {
        var baseURL: String?
        var apiKey: String?
        var defaultModel: String?
        var embeddingModel: String?
        var imageModel: String?
        var sttModel: String?
        var ttsModel: String?
        var modelSearchPath: String?
    }

    static func resolve(baseURL flagBase: String? = nil, apiKey flagKey: String? = nil, model flagModel: String? = nil) -> NativConfig {
        let file = loadFile()
        let env = ProcessInfo.processInfo.environment
        let baseStr = flagBase ?? env["NATIV_BASE_URL"] ?? file?.baseURL ?? "http://127.0.0.1:8080"
        return NativConfig(
            baseURL: URL(string: baseStr) ?? URL(string: "http://127.0.0.1:8080")!,
            apiKey: flagKey ?? env["NATIV_API_KEY"] ?? file?.apiKey,
            defaultModel: flagModel ?? env["NATIV_MODEL"] ?? file?.defaultModel,
            embeddingModel: env["NATIV_EMBEDDING_MODEL"] ?? file?.embeddingModel,
            imageModel: env["NATIV_IMAGE_MODEL"] ?? file?.imageModel,
            sttModel: env["NATIV_STT_MODEL"] ?? file?.sttModel,
            ttsModel: env["NATIV_TTS_MODEL"] ?? file?.ttsModel,
            modelSearchPath: env["NATIV_MODEL_PATH"] ?? file?.modelSearchPath
        )
    }

    /// The model to use for a capability, falling back to the general default.
    var chatModel: String? { defaultModel }
    var resolvedEmbeddingModel: String? { embeddingModel ?? defaultModel }
    var resolvedImageModel: String? { imageModel ?? defaultModel }
    var resolvedSTTModel: String? { sttModel ?? defaultModel }
    var resolvedTTSModel: String? { ttsModel ?? defaultModel }

    static func loadFile() -> FileConfig? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return nil }
        return try? JSONDecoder().decode(FileConfig.self, from: data)
    }

    /// Merge-write only the provided fields into `cli.json`, preserving the rest.
    static func write(
        baseURL: String? = nil,
        apiKey: String? = nil,
        defaultModel: String? = nil,
        embeddingModel: String? = nil,
        imageModel: String? = nil,
        sttModel: String? = nil,
        ttsModel: String? = nil,
        modelSearchPath: String? = nil
    ) throws {
        try FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        var file = loadFile() ?? FileConfig()
        if let baseURL { file.baseURL = baseURL }
        if let apiKey { file.apiKey = apiKey }
        if let defaultModel { file.defaultModel = defaultModel }
        if let embeddingModel { file.embeddingModel = embeddingModel }
        if let imageModel { file.imageModel = imageModel }
        if let sttModel { file.sttModel = sttModel }
        if let ttsModel { file.ttsModel = ttsModel }
        if let modelSearchPath { file.modelSearchPath = modelSearchPath }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: URL(fileURLWithPath: filePath))
    }

    static func setDefaultModel(_ id: String) throws { try write(defaultModel: id) }
}
