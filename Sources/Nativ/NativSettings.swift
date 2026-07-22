import Foundation
import NativServerKit

struct NativSettings: Codable, Equatable {
    /// Default hub cache location, resolved from the environment.
    /// See `HuggingFaceCache.defaultHubPath`.
    static var defaultModelSearchPath: String {
        HuggingFaceCache.defaultHubPath()
    }

    var modelSearchPath: String
    var additionalModelSearchPaths: [String]
    var languageModelID: String?
    var imageGenerationModelID: String?
    var textToSpeechModelID: String?
    var speechToTextModelID: String?
    var serverAPIKey: String?
    var serverPort: Int
    var maxTokens: Int
    var maxKVSize: Int
    var systemPrompt: String
    var temperature: Double
    var topK: Int
    var topP: Double
    var minP: Double
    var repetitionPenaltyEnabled: Bool
    var repetitionPenalty: Double
    var kvQuantizationEnabled: Bool
    var kvBits: Double
    var kvGroupSize: Int
    var quantizedKVStart: Int
    var turboQuantEnabled: Bool
    var thinkingEnabled: Bool
    var thinkingBudgetEnabled: Bool
    var thinkingBudget: Int
    var thinkingStartToken: String
    var thinkingEndToken: String
    var speculativeDecodingEnabled: Bool
    var draftModelID: String
    var draftKind: String
    var draftBlockSize: Int
    var structuredOutputEnabled: Bool
    var structuredOutputName: String
    var structuredOutputSchema: String
    var prefixCachingEnabled: Bool
    var prefixCacheBlocks: Int
    var prefixCacheBlockSize: Int

    init(
        modelSearchPath: String = Self.defaultModelSearchPath,
        additionalModelSearchPaths: [String] = [],
        languageModelID: String? = nil,
        imageGenerationModelID: String? = nil,
        textToSpeechModelID: String? = nil,
        speechToTextModelID: String? = nil,
        serverAPIKey: String? = nil,
        serverPort: Int = 8080,
        maxTokens: Int = 2048,
        maxKVSize: Int = 0,
        systemPrompt: String = "",
        temperature: Double = 0,
        topK: Int = 0,
        topP: Double = 1,
        minP: Double = 0,
        repetitionPenaltyEnabled: Bool = false,
        repetitionPenalty: Double = 1.1,
        kvQuantizationEnabled: Bool = false,
        kvBits: Double = 8,
        kvGroupSize: Int = 64,
        quantizedKVStart: Int = 0,
        turboQuantEnabled: Bool = false,
        thinkingEnabled: Bool = false,
        thinkingBudgetEnabled: Bool = false,
        thinkingBudget: Int = 512,
        thinkingStartToken: String = "<think>",
        thinkingEndToken: String = "</think>",
        speculativeDecodingEnabled: Bool = false,
        draftModelID: String = "",
        draftKind: String = "auto",
        draftBlockSize: Int = 0,
        structuredOutputEnabled: Bool = false,
        structuredOutputName: String = "Response",
        structuredOutputSchema: String = Self.defaultStructuredOutputSchema,
        prefixCachingEnabled: Bool = false,
        prefixCacheBlocks: Int = 2048,
        prefixCacheBlockSize: Int = 16
    ) {
        self.modelSearchPath = modelSearchPath
        self.additionalModelSearchPaths = additionalModelSearchPaths
        self.languageModelID = languageModelID
        self.imageGenerationModelID = imageGenerationModelID
        self.textToSpeechModelID = textToSpeechModelID
        self.speechToTextModelID = speechToTextModelID
        self.serverAPIKey = serverAPIKey
        self.serverPort = serverPort
        self.maxTokens = maxTokens
        self.maxKVSize = maxKVSize
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repetitionPenaltyEnabled = repetitionPenaltyEnabled
        self.repetitionPenalty = repetitionPenalty
        self.kvQuantizationEnabled = kvQuantizationEnabled
        self.kvBits = kvBits
        self.kvGroupSize = kvGroupSize
        self.quantizedKVStart = quantizedKVStart
        self.turboQuantEnabled = turboQuantEnabled
        self.thinkingEnabled = thinkingEnabled
        self.thinkingBudgetEnabled = thinkingBudgetEnabled
        self.thinkingBudget = thinkingBudget
        self.thinkingStartToken = thinkingStartToken
        self.thinkingEndToken = thinkingEndToken
        self.speculativeDecodingEnabled = speculativeDecodingEnabled
        self.draftModelID = draftModelID
        self.draftKind = draftKind
        self.draftBlockSize = draftBlockSize
        self.structuredOutputEnabled = structuredOutputEnabled
        self.structuredOutputName = structuredOutputName
        self.structuredOutputSchema = structuredOutputSchema
        self.prefixCachingEnabled = prefixCachingEnabled
        self.prefixCacheBlocks = prefixCacheBlocks
        self.prefixCacheBlockSize = prefixCacheBlockSize
    }

    enum CodingKeys: String, CodingKey {
        case modelSearchPath
        case additionalModelSearchPaths
        case languageModelID
        case imageGenerationModelID
        case textToSpeechModelID
        case speechToTextModelID
        case serverAPIKey
        case serverPort
        case selectedModelID
        case maxTokens
        case maxKVSize
        case systemPrompt
        case temperature
        case topK
        case topP
        case minP
        case repetitionPenaltyEnabled
        case repetitionPenalty
        case kvQuantizationEnabled
        case kvBits
        case kvGroupSize
        case quantizedKVStart
        case turboQuantEnabled
        case thinkingEnabled
        case thinkingBudgetEnabled
        case thinkingBudget
        case thinkingStartToken
        case thinkingEndToken
        case speculativeDecodingEnabled
        case draftModelID
        case draftKind
        case draftBlockSize
        case structuredOutputEnabled
        case structuredOutputName
        case structuredOutputSchema
        case prefixCachingEnabled
        case prefixCacheBlocks
        case prefixCacheBlockSize
    }

    init(from decoder: Decoder) throws {
        let defaults = Self()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacySelectedModelID = try container.decodeIfPresent(String.self, forKey: .selectedModelID)
        let storedModelSearchPath = try container.decodeIfPresent(String.self, forKey: .modelSearchPath)
        modelSearchPath = HuggingFaceCache.resolvedSearchPath(stored: storedModelSearchPath)
        additionalModelSearchPaths = try container.decodeIfPresent([String].self, forKey: .additionalModelSearchPaths) ?? defaults.additionalModelSearchPaths
        languageModelID = try container.decodeIfPresent(String.self, forKey: .languageModelID) ?? legacySelectedModelID ?? defaults.languageModelID
        imageGenerationModelID = try container.decodeIfPresent(String.self, forKey: .imageGenerationModelID) ?? defaults.imageGenerationModelID
        textToSpeechModelID = try container.decodeIfPresent(String.self, forKey: .textToSpeechModelID) ?? defaults.textToSpeechModelID
        speechToTextModelID = try container.decodeIfPresent(String.self, forKey: .speechToTextModelID) ?? defaults.speechToTextModelID
        serverAPIKey = try container.decodeIfPresent(String.self, forKey: .serverAPIKey) ?? defaults.serverAPIKey
        serverPort = try container.decodeIfPresent(Int.self, forKey: .serverPort) ?? defaults.serverPort
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? defaults.maxTokens
        maxKVSize = try container.decodeIfPresent(Int.self, forKey: .maxKVSize) ?? defaults.maxKVSize
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? defaults.systemPrompt
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature
        topK = try container.decodeIfPresent(Int.self, forKey: .topK) ?? defaults.topK
        topP = try container.decodeIfPresent(Double.self, forKey: .topP) ?? defaults.topP
        minP = try container.decodeIfPresent(Double.self, forKey: .minP) ?? defaults.minP
        repetitionPenaltyEnabled = try container.decodeIfPresent(Bool.self, forKey: .repetitionPenaltyEnabled) ?? defaults.repetitionPenaltyEnabled
        repetitionPenalty = try container.decodeIfPresent(Double.self, forKey: .repetitionPenalty) ?? defaults.repetitionPenalty
        kvQuantizationEnabled = try container.decodeIfPresent(Bool.self, forKey: .kvQuantizationEnabled) ?? defaults.kvQuantizationEnabled
        kvBits = try container.decodeIfPresent(Double.self, forKey: .kvBits) ?? defaults.kvBits
        kvGroupSize = try container.decodeIfPresent(Int.self, forKey: .kvGroupSize) ?? defaults.kvGroupSize
        quantizedKVStart = try container.decodeIfPresent(Int.self, forKey: .quantizedKVStart) ?? defaults.quantizedKVStart
        turboQuantEnabled = try container.decodeIfPresent(Bool.self, forKey: .turboQuantEnabled) ?? defaults.turboQuantEnabled
        thinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? defaults.thinkingEnabled
        thinkingBudgetEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingBudgetEnabled) ?? defaults.thinkingBudgetEnabled
        thinkingBudget = try container.decodeIfPresent(Int.self, forKey: .thinkingBudget) ?? defaults.thinkingBudget
        thinkingStartToken = try container.decodeIfPresent(String.self, forKey: .thinkingStartToken) ?? defaults.thinkingStartToken
        thinkingEndToken = try container.decodeIfPresent(String.self, forKey: .thinkingEndToken) ?? defaults.thinkingEndToken
        speculativeDecodingEnabled = try container.decodeIfPresent(Bool.self, forKey: .speculativeDecodingEnabled) ?? defaults.speculativeDecodingEnabled
        draftModelID = try container.decodeIfPresent(String.self, forKey: .draftModelID) ?? defaults.draftModelID
        draftKind = try container.decodeIfPresent(String.self, forKey: .draftKind) ?? defaults.draftKind
        draftBlockSize = try container.decodeIfPresent(Int.self, forKey: .draftBlockSize) ?? defaults.draftBlockSize
        structuredOutputEnabled = try container.decodeIfPresent(Bool.self, forKey: .structuredOutputEnabled) ?? defaults.structuredOutputEnabled
        structuredOutputName = try container.decodeIfPresent(String.self, forKey: .structuredOutputName) ?? defaults.structuredOutputName
        structuredOutputSchema = try container.decodeIfPresent(String.self, forKey: .structuredOutputSchema) ?? defaults.structuredOutputSchema
        prefixCachingEnabled = try container.decodeIfPresent(Bool.self, forKey: .prefixCachingEnabled) ?? defaults.prefixCachingEnabled
        prefixCacheBlocks = try container.decodeIfPresent(Int.self, forKey: .prefixCacheBlocks) ?? defaults.prefixCacheBlocks
        prefixCacheBlockSize = try container.decodeIfPresent(Int.self, forKey: .prefixCacheBlockSize) ?? defaults.prefixCacheBlockSize
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelSearchPath, forKey: .modelSearchPath)
        try container.encode(additionalModelSearchPaths, forKey: .additionalModelSearchPaths)
        try container.encodeIfPresent(languageModelID, forKey: .languageModelID)
        try container.encodeIfPresent(imageGenerationModelID, forKey: .imageGenerationModelID)
        try container.encodeIfPresent(textToSpeechModelID, forKey: .textToSpeechModelID)
        try container.encodeIfPresent(speechToTextModelID, forKey: .speechToTextModelID)
        try container.encodeIfPresent(serverAPIKey, forKey: .serverAPIKey)
        try container.encode(serverPort, forKey: .serverPort)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(maxKVSize, forKey: .maxKVSize)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(topK, forKey: .topK)
        try container.encode(topP, forKey: .topP)
        try container.encode(minP, forKey: .minP)
        try container.encode(repetitionPenaltyEnabled, forKey: .repetitionPenaltyEnabled)
        try container.encode(repetitionPenalty, forKey: .repetitionPenalty)
        try container.encode(kvQuantizationEnabled, forKey: .kvQuantizationEnabled)
        try container.encode(kvBits, forKey: .kvBits)
        try container.encode(kvGroupSize, forKey: .kvGroupSize)
        try container.encode(quantizedKVStart, forKey: .quantizedKVStart)
        try container.encode(turboQuantEnabled, forKey: .turboQuantEnabled)
        try container.encode(thinkingEnabled, forKey: .thinkingEnabled)
        try container.encode(thinkingBudgetEnabled, forKey: .thinkingBudgetEnabled)
        try container.encode(thinkingBudget, forKey: .thinkingBudget)
        try container.encode(thinkingStartToken, forKey: .thinkingStartToken)
        try container.encode(thinkingEndToken, forKey: .thinkingEndToken)
        try container.encode(speculativeDecodingEnabled, forKey: .speculativeDecodingEnabled)
        try container.encode(draftModelID, forKey: .draftModelID)
        try container.encode(draftKind, forKey: .draftKind)
        try container.encode(draftBlockSize, forKey: .draftBlockSize)
        try container.encode(structuredOutputEnabled, forKey: .structuredOutputEnabled)
        try container.encode(structuredOutputName, forKey: .structuredOutputName)
        try container.encode(structuredOutputSchema, forKey: .structuredOutputSchema)
        try container.encode(prefixCachingEnabled, forKey: .prefixCachingEnabled)
        try container.encode(prefixCacheBlocks, forKey: .prefixCacheBlocks)
        try container.encode(prefixCacheBlockSize, forKey: .prefixCacheBlockSize)
    }

    static func load() -> Self {
        guard let data = try? Data(contentsOf: storageURL) else {
            return Self()
        }
        return (try? PropertyListDecoder().decode(Self.self, from: data)) ?? Self()
    }

    func save() {
        do {
            let url = Self.storageURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListEncoder().encode(normalized())
            try data.write(to: url, options: .atomic)
        } catch {
            // Settings should not prevent the server from running.
        }
    }

    func normalized() -> Self {
        var settings = self
        let trimmedPath = settings.modelSearchPath.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.modelSearchPath = trimmedPath.isEmpty ? Self.defaultModelSearchPath : trimmedPath
        var seenAdditionalPaths = Set<String>()
        settings.additionalModelSearchPaths = settings.additionalModelSearchPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenAdditionalPaths.insert($0).inserted }
        settings.languageModelID = Self.normalizedModelID(settings.languageModelID)
        settings.imageGenerationModelID = Self.normalizedModelID(settings.imageGenerationModelID)
        settings.textToSpeechModelID = Self.normalizedModelID(settings.textToSpeechModelID)
        settings.speechToTextModelID = Self.normalizedModelID(settings.speechToTextModelID)
        settings.serverAPIKey = Self.normalizedModelID(settings.serverAPIKey)
        settings.serverPort = min(max(settings.serverPort, 1), 65_535)
        settings.maxTokens = min(max(settings.maxTokens, 1), 262_144)
        settings.maxKVSize = min(max(settings.maxKVSize, 0), 1_048_576)
        settings.systemPrompt = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.temperature = min(max(settings.temperature, 0), 2)
        settings.topK = min(max(settings.topK, 0), 10_000)
        settings.topP = min(max(settings.topP, 0), 1)
        settings.minP = min(max(settings.minP, 0), 1)
        settings.repetitionPenalty = min(max(settings.repetitionPenalty, 0), 4)
        settings.kvBits = min(max(settings.kvBits, 2), 16)
        settings.kvGroupSize = min(max(settings.kvGroupSize, 1), 1024)
        settings.quantizedKVStart = min(max(settings.quantizedKVStart, 0), 1_048_576)
        settings.thinkingBudget = min(max(settings.thinkingBudget, 1), 262_144)
        settings.thinkingStartToken = Self.nonEmpty(settings.thinkingStartToken, fallback: "<think>")
        settings.thinkingEndToken = Self.nonEmpty(settings.thinkingEndToken, fallback: "</think>")
        settings.draftModelID = settings.draftModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !["auto", "dflash", "eagle3", "mtp"].contains(settings.draftKind) {
            settings.draftKind = "auto"
        }
        settings.draftBlockSize = min(max(settings.draftBlockSize, 0), 1024)
        settings.structuredOutputName = Self.nonEmpty(settings.structuredOutputName, fallback: "Response")
        settings.prefixCacheBlocks = min(max(settings.prefixCacheBlocks, 1), 1_048_576)
        settings.prefixCacheBlockSize = min(max(settings.prefixCacheBlockSize, 1), 4096)
        return settings
    }

    func hasSameLaunchConfiguration(as other: Self) -> Bool {
        let lhs = normalized()
        let rhs = other.normalized()
        let lhsSpeculativeDecodingActive = lhs.speculativeDecodingEnabled && !lhs.draftModelID.isEmpty
        let rhsSpeculativeDecodingActive = rhs.speculativeDecodingEnabled && !rhs.draftModelID.isEmpty
        return lhs.modelSearchPath == rhs.modelSearchPath
            && lhs.languageModelID == rhs.languageModelID
            && lhs.serverAPIKey == rhs.serverAPIKey
            && lhs.serverPort == rhs.serverPort
            && lhs.maxTokens == rhs.maxTokens
            && lhs.maxKVSize == rhs.maxKVSize
            && lhs.kvQuantizationEnabled == rhs.kvQuantizationEnabled
            && (!lhs.kvQuantizationEnabled || (
                lhs.kvBits == rhs.kvBits
                    && lhs.kvGroupSize == rhs.kvGroupSize
                    && lhs.quantizedKVStart == rhs.quantizedKVStart
                    && lhs.turboQuantEnabled == rhs.turboQuantEnabled
            ))
            && lhsSpeculativeDecodingActive == rhsSpeculativeDecodingActive
            && (!lhsSpeculativeDecodingActive || (
                lhs.draftModelID == rhs.draftModelID
                    && lhs.draftKind == rhs.draftKind
                    && lhs.draftBlockSize == rhs.draftBlockSize
            ))
            && lhs.prefixCachingEnabled == rhs.prefixCachingEnabled
            && (!lhs.prefixCachingEnabled || (
                lhs.prefixCacheBlocks == rhs.prefixCacheBlocks
                    && lhs.prefixCacheBlockSize == rhs.prefixCacheBlockSize
            ))
    }

    var serverBaseURL: URL {
        URL(string: "http://127.0.0.1:\(min(max(serverPort, 1), 65_535))")!
    }

    var launchEnvironment: [String: String] {
        let settings = normalized()
        var environment = [
            "HF_HUB_CACHE": settings.expandedModelSearchPath
        ]

        environment["APC_ENABLED"] = settings.prefixCachingEnabled ? "1" : "0"
        if let serverAPIKey = settings.serverAPIKey {
            environment["MLX_VLM_SERVER_API_KEY"] = serverAPIKey
        }
        if settings.prefixCachingEnabled {
            environment["APC_NUM_BLOCKS"] = "\(settings.prefixCacheBlocks)"
            environment["APC_BLOCK_SIZE"] = "\(settings.prefixCacheBlockSize)"
        }
        return environment
    }

    var launchArguments: [String] {
        let settings = normalized()
        var arguments = [
            "--port", "\(settings.serverPort)",
            "--max-tokens", "\(settings.maxTokens)"
        ]

        if let languageModelID = settings.languageModelID {
            arguments.append(contentsOf: ["--model", languageModelID])
        }

        if settings.maxKVSize > 0 {
            arguments.append(contentsOf: ["--max-kv-size", "\(settings.maxKVSize)"])
        }

        if settings.kvQuantizationEnabled {
            arguments.append(contentsOf: ["--kv-bits", Self.numberString(settings.kvBits)])
            arguments.append(contentsOf: [
                "--kv-quant-scheme", settings.turboQuantEnabled ? "turboquant" : "uniform",
                "--kv-group-size", "\(settings.kvGroupSize)",
                "--quantized-kv-start", "\(settings.quantizedKVStart)"
            ])
        }

        if settings.speculativeDecodingEnabled, !settings.draftModelID.isEmpty {
            arguments.append(contentsOf: ["--draft-model", settings.draftModelID])
            if settings.draftKind != "auto" {
                arguments.append(contentsOf: ["--draft-kind", settings.draftKind])
            }
            if settings.draftBlockSize > 0 {
                arguments.append(contentsOf: ["--draft-block-size", "\(settings.draftBlockSize)"])
            }
        }

        return arguments
    }

    var structuredOutputValidationError: String? {
        guard structuredOutputEnabled else {
            return nil
        }
        guard let data = structuredOutputSchema.data(using: .utf8) else {
            return "Schema must be valid UTF-8 JSON."
        }
        do {
            let value = try JSONSerialization.jsonObject(with: data)
            guard value is [String: Any] else {
                return "Schema must be a JSON object."
            }
            return nil
        } catch {
            return "Schema is not valid JSON."
        }
    }

    var chatResponseFormat: MLXChatResponseFormat? {
        let settings = normalized()
        guard settings.structuredOutputEnabled,
              settings.structuredOutputValidationError == nil,
              let data = settings.structuredOutputSchema.data(using: .utf8),
              let schema = try? MLXJSONValue(jsonData: data)
        else {
            return nil
        }
        return MLXChatResponseFormat(
            name: settings.structuredOutputName,
            schema: schema,
            strict: true
        )
    }

    var expandedModelSearchPath: String {
        NSString(string: modelSearchPath).expandingTildeInPath
    }

    private static func normalizedModelID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func nonEmpty(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func numberString(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    static let defaultStructuredOutputSchema = """
    {
      "type": "object",
      "properties": {},
      "additionalProperties": true
    }
    """

    private static var storageURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let baseURL = applicationSupport ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Settings.plist")
    }
}
