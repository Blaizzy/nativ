import Foundation
import NativServerKit
import Security

enum ServerAPICredentialPersistenceError: Error {
    case keychain(OSStatus)
    case invalidKeychainData
}

protocol ServerAPICredentialStoring {
    func load() throws -> String?
    func save(_ token: String?) throws
}

struct ServerAPIKeychain: ServerAPICredentialStoring {
    let service: String
    let account: String

    init(
        service: String = "dev.local.Nativ.server-api-key",
        account: String = "nativ-server"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw ServerAPICredentialPersistenceError.keychain(status)
        }
        guard let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw ServerAPICredentialPersistenceError.invalidKeychainData
        }
        return ServerAPIAuthentication.normalizedToken(token)
    }

    func save(_ token: String?) throws {
        guard let token = ServerAPIAuthentication.normalizedToken(token) else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ServerAPICredentialPersistenceError.keychain(status)
            }
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw ServerAPICredentialPersistenceError.keychain(updateStatus)
        }

        var item = baseQuery
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ServerAPICredentialPersistenceError.keychain(addStatus)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

struct ServerAPITokenInfo: Equatable, Sendable {
    let maskedValue: String
    let characterCount: Int
}

enum ServerAPIAuthentication {
    static func normalizedToken(_ token: String?) -> String? {
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func tokenInfo(_ token: String?) -> ServerAPITokenInfo? {
        guard let token = normalizedToken(token) else {
            return nil
        }

        let prefix = token.hasPrefix("nativ_") ? "nativ_" : ""
        let suffix = token.count > 8 ? String(token.suffix(4)) : ""
        return ServerAPITokenInfo(
            maskedValue: "\(prefix)••••••••\(suffix)",
            characterCount: token.count
        )
    }

    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return "nativ_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        }

        let token = Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "nativ_\(token)"
    }
}

enum ModelPreloadSlot: String, CaseIterable, Identifiable, Sendable {
    case language
    case imageGeneration
    case textToSpeech
    case speechToText
    case embeddings

    var id: Self { self }

    var displayName: String {
        switch self {
        case .language:
            "Language"
        case .imageGeneration:
            "Image Generation"
        case .textToSpeech:
            "Text to Speech"
        case .speechToText:
            "Speech to Text"
        case .embeddings:
            "Embeddings"
        }
    }

    var systemImage: String {
        switch self {
        case .language:
            "text.bubble"
        case .imageGeneration:
            "photo"
        case .textToSpeech:
            "speaker.wave.2"
        case .speechToText:
            "waveform"
        case .embeddings:
            "square.stack.3d.up"
        }
    }
}

struct ModelPreloadMemoryWarning: Equatable, Identifiable, Sendable {
    var id: String {
        "\(candidateSlot.rawValue):\(candidateModelID)"
    }

    let candidateModelID: String
    let candidateSlot: ModelPreloadSlot
    let existingSlots: [ModelPreloadSlot]
    let estimatedWorkingSetBytes: UInt64
    let memoryBudgetBytes: UInt64
    let totalMemoryBytes: UInt64

    var message: String {
        let candidateName = candidateModelID.split(separator: "/").last.map(String.init)
            ?? candidateModelID
        let estimated = Self.byteCount(estimatedWorkingSetBytes)
        let budget = Self.byteCount(memoryBudgetBytes)
        let total = Self.byteCount(totalMemoryBytes)
        let existingKinds = Self.joinedList(existingSlots.map(\.displayName))
        let existingDescription =
            existingSlots.count == 1
            ? "the selected \(existingKinds) model"
            : "the selected \(existingKinds) models"

        let selectionDescription =
            "Loading \(candidateName) for \(candidateSlot.displayName) alongside "
            + "\(existingDescription) is estimated to require \(estimated)."
        let budgetDescription =
            "That exceeds this Mac’s \(budget) usable unified-memory budget "
            + "(\(total) total), which reserves memory for KV cache and runtime headroom."
        return "\(selectionDescription) \(budgetDescription)"
    }

    static func evaluate(
        candidateModelID: String,
        candidateSlot: ModelPreloadSlot,
        currentSelections: [ModelPreloadSlot: String],
        workingSetBytesByModelID: [String: UInt64],
        memoryBudgetBytes: UInt64,
        totalMemoryBytes: UInt64
    ) -> Self? {
        guard currentSelections[candidateSlot] != candidateModelID,
              workingSetBytesByModelID[candidateModelID] != nil
        else {
            return nil
        }

        let existingSlots = ModelPreloadSlot.allCases.filter {
            $0 != candidateSlot && currentSelections[$0] != nil
        }
        guard !existingSlots.isEmpty else {
            return nil
        }

        var modelIDs = Set(
            existingSlots.compactMap {
                currentSelections[$0]
            })
        modelIDs.insert(candidateModelID)

        let estimatedWorkingSetBytes = modelIDs.reduce(UInt64(0)) { total, modelID in
            guard let modelBytes = workingSetBytesByModelID[modelID] else {
                return total
            }
            let sum = total.addingReportingOverflow(modelBytes)
            return sum.overflow ? UInt64.max : sum.partialValue
        }
        guard estimatedWorkingSetBytes > memoryBudgetBytes else {
            return nil
        }

        return Self(
            candidateModelID: candidateModelID,
            candidateSlot: candidateSlot,
            existingSlots: existingSlots,
            estimatedWorkingSetBytes: estimatedWorkingSetBytes,
            memoryBudgetBytes: memoryBudgetBytes,
            totalMemoryBytes: totalMemoryBytes
        )
    }

    private static func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .memory
        )
    }

    private static func joinedList(_ values: [String]) -> String {
        switch values.count {
        case 0:
            ""
        case 1:
            values[0]
        case 2:
            values.joined(separator: " and ")
        default:
            values.dropLast().joined(separator: ", ") + ", and " + (values.last ?? "")
        }
    }
}

struct ModelConfigProfile: Codable, Equatable {
    var thinkingEnabled: Bool
    var thinkingBudgetEnabled: Bool
    var thinkingBudget: Int
    var speculativeDecodingEnabled: Bool
    var draftModelID: String
    var draftKind: String

    init(
        thinkingEnabled: Bool = false,
        thinkingBudgetEnabled: Bool = false,
        thinkingBudget: Int = 512,
        speculativeDecodingEnabled: Bool = false,
        draftModelID: String = "",
        draftKind: String = "auto"
    ) {
        self.thinkingEnabled = thinkingEnabled
        self.thinkingBudgetEnabled = thinkingBudgetEnabled
        self.thinkingBudget = thinkingBudget
        self.speculativeDecodingEnabled = speculativeDecodingEnabled
        self.draftModelID = draftModelID
        self.draftKind = draftKind
    }

    enum CodingKeys: String, CodingKey {
        case thinkingEnabled, thinkingBudgetEnabled, thinkingBudget
        case speculativeDecodingEnabled, draftModelID, draftKind
    }

    init(from decoder: Decoder) throws {
        let defaults = ModelConfigProfile()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? defaults.thinkingEnabled
        thinkingBudgetEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingBudgetEnabled) ?? defaults.thinkingBudgetEnabled
        thinkingBudget = try container.decodeIfPresent(Int.self, forKey: .thinkingBudget) ?? defaults.thinkingBudget
        speculativeDecodingEnabled = try container.decodeIfPresent(Bool.self, forKey: .speculativeDecodingEnabled) ?? defaults.speculativeDecodingEnabled
        draftModelID = try container.decodeIfPresent(String.self, forKey: .draftModelID) ?? defaults.draftModelID
        draftKind = try container.decodeIfPresent(String.self, forKey: .draftKind) ?? defaults.draftKind
    }
}

struct NativSettings: Codable, Equatable {
    /// Default hub cache location, resolved from the environment.
    /// See `HuggingFaceCache.defaultHubPath`.
    static var defaultModelSearchPath: String {
        HuggingFaceCache.defaultHubPath()
    }

    static let defaultServerHost = "127.0.0.1"

    static let serverSupportsEmbeddingModelArgument = false

    var modelSearchPath: String
    var additionalModelSearchPaths: [String]
    var languageModelID: String?
    var mcpServers: [MCPServerConfig]
    var disabledToolNames: [String]
    var skills: [NativSkill]
    var imageGenerationModelID: String?
    var textToSpeechModelID: String?
    var speechToTextModelID: String?
    var embeddingModelID: String?
    var serverAPIKey: String?
    var huggingFaceToken: String?
    var serverHost: String
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
    var chatFontScale: Double
    var sidebarPinnedCollapsed: Bool
    var sidebarFoldersCollapsed: Bool
    var sidebarSessionsCollapsed: Bool
    var modelConfigs: [String: ModelConfigProfile]

    init(
        modelSearchPath: String = Self.defaultModelSearchPath,
        additionalModelSearchPaths: [String] = [],
        languageModelID: String? = nil,
        mcpServers: [MCPServerConfig] = [],
        disabledToolNames: [String] = [],
        skills: [NativSkill] = [],
        imageGenerationModelID: String? = nil,
        textToSpeechModelID: String? = nil,
        speechToTextModelID: String? = nil,
        embeddingModelID: String? = nil,
        serverAPIKey: String? = nil,
        huggingFaceToken: String? = nil,
        serverHost: String = Self.defaultServerHost,
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
        prefixCacheBlockSize: Int = 16,
        chatFontScale: Double = Self.defaultChatFontScale,
        sidebarPinnedCollapsed: Bool = false,
        sidebarFoldersCollapsed: Bool = false,
        sidebarSessionsCollapsed: Bool = false,
        modelConfigs: [String: ModelConfigProfile] = [:]
    ) {
        self.modelSearchPath = modelSearchPath
        self.additionalModelSearchPaths = additionalModelSearchPaths
        self.languageModelID = languageModelID
        self.mcpServers = mcpServers
        self.disabledToolNames = disabledToolNames
        self.skills = skills
        self.imageGenerationModelID = imageGenerationModelID
        self.textToSpeechModelID = textToSpeechModelID
        self.speechToTextModelID = speechToTextModelID
        self.embeddingModelID = embeddingModelID
        self.serverAPIKey = serverAPIKey
        self.huggingFaceToken = huggingFaceToken
        self.serverHost = serverHost
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
        self.chatFontScale = chatFontScale
        self.sidebarPinnedCollapsed = sidebarPinnedCollapsed
        self.sidebarFoldersCollapsed = sidebarFoldersCollapsed
        self.sidebarSessionsCollapsed = sidebarSessionsCollapsed
        self.modelConfigs = modelConfigs
    }

    enum CodingKeys: String, CodingKey {
        case modelSearchPath
        case additionalModelSearchPaths
        case languageModelID
        case mcpServers
        case disabledToolNames
        case skills
        case imageGenerationModelID
        case textToSpeechModelID
        case speechToTextModelID
        case embeddingModelID
        case serverAPIKey
        case huggingFaceToken
        case serverHost
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
        case chatFontScale
        case sidebarPinnedCollapsed
        case sidebarFoldersCollapsed
        case sidebarSessionsCollapsed
        case modelConfigs
    }

    init(from decoder: Decoder) throws {
        let defaults = Self()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacySelectedModelID = try container.decodeIfPresent(String.self, forKey: .selectedModelID)
        let storedModelSearchPath = try container.decodeIfPresent(String.self, forKey: .modelSearchPath)
        modelSearchPath = HuggingFaceCache.resolvedSearchPath(stored: storedModelSearchPath)
        additionalModelSearchPaths = try container.decodeIfPresent([String].self, forKey: .additionalModelSearchPaths) ?? defaults.additionalModelSearchPaths
        languageModelID = try container.decodeIfPresent(String.self, forKey: .languageModelID) ?? legacySelectedModelID ?? defaults.languageModelID
        mcpServers = try container.decodeIfPresent([MCPServerConfig].self, forKey: .mcpServers) ?? defaults.mcpServers
        disabledToolNames = try container.decodeIfPresent([String].self, forKey: .disabledToolNames) ?? defaults.disabledToolNames
        skills = try container.decodeIfPresent([NativSkill].self, forKey: .skills) ?? defaults.skills
        imageGenerationModelID = try container.decodeIfPresent(String.self, forKey: .imageGenerationModelID) ?? defaults.imageGenerationModelID
        textToSpeechModelID = try container.decodeIfPresent(String.self, forKey: .textToSpeechModelID) ?? defaults.textToSpeechModelID
        speechToTextModelID = try container.decodeIfPresent(String.self, forKey: .speechToTextModelID) ?? defaults.speechToTextModelID
        embeddingModelID = try container.decodeIfPresent(String.self, forKey: .embeddingModelID) ?? defaults.embeddingModelID
        serverAPIKey = try container.decodeIfPresent(String.self, forKey: .serverAPIKey) ?? defaults.serverAPIKey
        huggingFaceToken = try container.decodeIfPresent(String.self, forKey: .huggingFaceToken) ?? defaults.huggingFaceToken
        serverHost = try container.decodeIfPresent(String.self, forKey: .serverHost) ?? defaults.serverHost
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
        chatFontScale = try container.decodeIfPresent(Double.self, forKey: .chatFontScale) ?? defaults.chatFontScale
        sidebarPinnedCollapsed = try container.decodeIfPresent(Bool.self, forKey: .sidebarPinnedCollapsed) ?? defaults.sidebarPinnedCollapsed
        sidebarFoldersCollapsed = try container.decodeIfPresent(Bool.self, forKey: .sidebarFoldersCollapsed) ?? defaults.sidebarFoldersCollapsed
        sidebarSessionsCollapsed = try container.decodeIfPresent(Bool.self, forKey: .sidebarSessionsCollapsed) ?? defaults.sidebarSessionsCollapsed
        modelConfigs = try container.decodeIfPresent([String: ModelConfigProfile].self, forKey: .modelConfigs) ?? defaults.modelConfigs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelSearchPath, forKey: .modelSearchPath)
        try container.encode(additionalModelSearchPaths, forKey: .additionalModelSearchPaths)
        try container.encodeIfPresent(languageModelID, forKey: .languageModelID)
        try container.encode(mcpServers, forKey: .mcpServers)
        try container.encode(disabledToolNames, forKey: .disabledToolNames)
        try container.encode(skills, forKey: .skills)
        try container.encodeIfPresent(imageGenerationModelID, forKey: .imageGenerationModelID)
        try container.encodeIfPresent(textToSpeechModelID, forKey: .textToSpeechModelID)
        try container.encodeIfPresent(speechToTextModelID, forKey: .speechToTextModelID)
        try container.encodeIfPresent(embeddingModelID, forKey: .embeddingModelID)
        try container.encodeIfPresent(huggingFaceToken, forKey: .huggingFaceToken)
        try container.encode(serverHost, forKey: .serverHost)
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
        try container.encode(chatFontScale, forKey: .chatFontScale)
        try container.encode(sidebarPinnedCollapsed, forKey: .sidebarPinnedCollapsed)
        try container.encode(sidebarFoldersCollapsed, forKey: .sidebarFoldersCollapsed)
        try container.encode(sidebarSessionsCollapsed, forKey: .sidebarSessionsCollapsed)
        try container.encode(modelConfigs, forKey: .modelConfigs)
    }

    var currentModelProfile: ModelConfigProfile {
        ModelConfigProfile(
            thinkingEnabled: thinkingEnabled,
            thinkingBudgetEnabled: thinkingBudgetEnabled,
            thinkingBudget: thinkingBudget,
            speculativeDecodingEnabled: speculativeDecodingEnabled,
            draftModelID: draftModelID,
            draftKind: draftKind
        )
    }

    func modelProfile(for modelID: String) -> ModelConfigProfile? {
        modelConfigs[modelID]
    }

    mutating func rememberProfile(forModel modelID: String) {
        guard !modelID.isEmpty else {
            return
        }
        modelConfigs[modelID] = currentModelProfile
    }

    mutating func applyProfile(_ profile: ModelConfigProfile) {
        thinkingEnabled = profile.thinkingEnabled
        thinkingBudgetEnabled = profile.thinkingBudgetEnabled
        thinkingBudget = profile.thinkingBudget
        speculativeDecodingEnabled = profile.speculativeDecodingEnabled
        draftModelID = profile.draftModelID
        draftKind = profile.draftKind
    }

    static func load(
        from url: URL = storageURL,
        credentialStore: ServerAPICredentialStoring = ServerAPIKeychain()
    ) -> Self {
        let storedSettings: Self
        if let data = try? Data(contentsOf: url),
           let decoded = try? PropertyListDecoder().decode(Self.self, from: data) {
            storedSettings = decoded
        } else {
            storedSettings = Self()
        }

        var settings = storedSettings
        let legacyToken = ServerAPIAuthentication.normalizedToken(
            storedSettings.serverAPIKey
        )

        do {
            if let keychainToken = try credentialStore.load() {
                settings.serverAPIKey = keychainToken
                if storedSettings.serverAPIKey != nil {
                    try? settings.writePropertyList(to: url)
                }
            } else if let legacyToken {
                try credentialStore.save(legacyToken)
                settings.serverAPIKey = legacyToken
                try? settings.writePropertyList(to: url)
            } else {
                settings.serverAPIKey = nil
                if storedSettings.serverAPIKey != nil {
                    try? settings.writePropertyList(to: url)
                }
            }
        } catch {
            // Keep the legacy value until it can be migrated without data loss.
            settings.serverAPIKey = legacyToken
        }

        return settings
    }

    func save(
        to url: URL = storageURL,
        credentialStore: ServerAPICredentialStoring = ServerAPIKeychain()
    ) {
        let settings = normalized()
        try? settings.writePropertyList(to: url)
        try? credentialStore.save(settings.serverAPIKey)
    }

    private func writePropertyList(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListEncoder().encode(normalized())
        try data.write(to: url, options: .atomic)
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
        if let imageModelID = settings.imageGenerationModelID,
           MLXImageModelResolver.isKnownImageEditOnlyModelID(imageModelID) {
            settings.imageGenerationModelID = nil
        }
        settings.textToSpeechModelID = Self.normalizedModelID(settings.textToSpeechModelID)
        settings.speechToTextModelID = Self.normalizedModelID(settings.speechToTextModelID)
        settings.embeddingModelID = Self.normalizedModelID(settings.embeddingModelID)
        settings.serverAPIKey = ServerAPIAuthentication.normalizedToken(settings.serverAPIKey)
        settings.huggingFaceToken = HuggingFaceAuthentication.normalizedToken(settings.huggingFaceToken)
        settings.serverHost = Self.normalizedServerHost(settings.serverHost)
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
        settings.chatFontScale = min(max(settings.chatFontScale, Self.minChatFontScale), Self.maxChatFontScale)
        return settings
    }

    static let chatFontScaleSteps: [Double] = [0.85, 1.0, 1.15, 1.3, 1.5]
    static let defaultChatFontScale: Double = 1.0
    static let minChatFontScale: Double = 0.85
    static let maxChatFontScale: Double = 1.5

    mutating func stepChatFontScale(by delta: Int) {
        let steps = Self.chatFontScaleSteps
        let current = steps.enumerated().min {
            abs($0.element - chatFontScale) < abs($1.element - chatFontScale)
        }?.offset ?? 0
        chatFontScale = steps[min(max(current + delta, 0), steps.count - 1)]
    }

    mutating func resetChatFontScale() {
        chatFontScale = Self.defaultChatFontScale
    }

    var allSidebarSectionsCollapsed: Bool {
        sidebarPinnedCollapsed && sidebarFoldersCollapsed && sidebarSessionsCollapsed
    }

    mutating func setAllSidebarSectionsCollapsed(_ collapsed: Bool) {
        sidebarPinnedCollapsed = collapsed
        sidebarFoldersCollapsed = collapsed
        sidebarSessionsCollapsed = collapsed
    }

    func hasSameLaunchConfiguration(as other: Self) -> Bool {
        let lhs = normalized()
        let rhs = other.normalized()
        let lhsSpeculativeDecodingActive = lhs.speculativeDecodingEnabled && !lhs.draftModelID.isEmpty
        let rhsSpeculativeDecodingActive = rhs.speculativeDecodingEnabled && !rhs.draftModelID.isEmpty
        return lhs.modelSearchPath == rhs.modelSearchPath
            && lhs.languageModelID == rhs.languageModelID
            && lhs.mcpServers == rhs.mcpServers
            && lhs.disabledToolNames == rhs.disabledToolNames
            && lhs.skills == rhs.skills
            && lhs.imageGenerationModelID == rhs.imageGenerationModelID
            && lhs.textToSpeechModelID == rhs.textToSpeechModelID
            && lhs.speechToTextModelID == rhs.speechToTextModelID
            && lhs.embeddingModelID == rhs.embeddingModelID
            && lhs.serverAPIKey == rhs.serverAPIKey
            && lhs.huggingFaceToken == rhs.huggingFaceToken
            && lhs.serverHost == rhs.serverHost
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
        let settings = normalized()
        let host = Self.urlHost(settings.serverHost)
        return URL(string: "http://\(host):\(settings.serverPort)")!
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
        if let huggingFaceToken = settings.huggingFaceToken {
            environment[HuggingFaceAuthentication.environmentVariableName] = huggingFaceToken
        }
        if settings.prefixCachingEnabled {
            environment["APC_NUM_BLOCKS"] = "\(settings.prefixCacheBlocks)"
            environment["APC_BLOCK_SIZE"] = "\(settings.prefixCacheBlockSize)"
        }
        if let modelConfigsJSON = encodedModelConfigs {
            environment["NATIV_MODEL_CONFIGS"] = modelConfigsJSON
        }
        return environment
    }

    var encodedModelConfigs: String? {
        guard !modelConfigs.isEmpty else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(modelConfigs) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    var launchArguments: [String] {
        let settings = normalized()
        var arguments = [
            "--host", settings.serverHost,
            "--port", "\(settings.serverPort)",
            "--max-tokens", "\(settings.maxTokens)"
        ]

        if let languageModelID = settings.languageModelID {
            arguments.append(contentsOf: ["--model", languageModelID])
        }
        if let imageGenerationModelID = settings.imageGenerationModelID {
            arguments.append(contentsOf: ["--image-model", imageGenerationModelID])
        }
        if let textToSpeechModelID = settings.textToSpeechModelID {
            arguments.append(contentsOf: ["--tts-model", textToSpeechModelID])
        }
        if let speechToTextModelID = settings.speechToTextModelID {
            arguments.append(contentsOf: ["--stt-model", speechToTextModelID])
        }
        if Self.serverSupportsEmbeddingModelArgument, let embeddingModelID = settings.embeddingModelID {
            arguments.append(contentsOf: ["--embedding-model", embeddingModelID])
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

    func modelID(for slot: ModelPreloadSlot) -> String? {
        switch slot {
        case .language:
            languageModelID
        case .imageGeneration:
            imageGenerationModelID
        case .textToSpeech:
            textToSpeechModelID
        case .speechToText:
            speechToTextModelID
        case .embeddings:
            embeddingModelID
        }
    }

    mutating func setModelID(_ modelID: String?, for slot: ModelPreloadSlot) {
        switch slot {
        case .language:
            languageModelID = modelID
        case .imageGeneration:
            imageGenerationModelID = modelID
        case .textToSpeech:
            textToSpeechModelID = modelID
        case .speechToText:
            speechToTextModelID = modelID
        case .embeddings:
            embeddingModelID = modelID
        }
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

    /// All directories to search for a locally-available model: the primary model
    /// folder, any user-added folders, and the Hugging Face hub cache. Consolidated
    /// here so callers don't each re-derive the roots (and each miss custom folders).
    var modelSearchRoots: [String] {
        var roots: [String] = []
        let primary = expandedModelSearchPath.trimmingCharacters(in: .whitespaces)
        if !primary.isEmpty {
            roots.append(primary)
        }
        for path in additionalModelSearchPaths {
            let expanded = NSString(string: path).expandingTildeInPath
                .trimmingCharacters(in: .whitespaces)
            if !expanded.isEmpty {
                roots.append(expanded)
            }
        }
        if let hubCache = ProcessInfo.processInfo.environment["HF_HUB_CACHE"], !hubCache.isEmpty {
            roots.append(hubCache)
        }
        roots.append(NSString(string: "~/.cache/huggingface/hub").expandingTildeInPath)
        var seen = Set<String>()
        return roots.filter { seen.insert($0).inserted }
    }

    private static func normalizedModelID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func normalizedServerHost(_ value: String) -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        guard !host.isEmpty else {
            return defaultServerHost
        }

        let candidate = "http://\(urlHost(host)):8080"
        guard let components = URLComponents(string: candidate),
              components.host != nil,
              components.port == 8080,
              components.path.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            return defaultServerHost
        }
        return host
    }

    private static func urlHost(_ host: String) -> String {
        guard host.contains(":") else {
            return host
        }
        return "[\(host.replacingOccurrences(of: "%", with: "%25"))]"
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
