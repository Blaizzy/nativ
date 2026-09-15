import Foundation

public struct PromptSectionOrigin: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let userSystemPrompt = PromptSectionOrigin(rawValue: "user_system_prompt")
    public static let project = PromptSectionOrigin(rawValue: "project")
    public static let toolGuide = PromptSectionOrigin(rawValue: "tool_guide")
    public static let skill = PromptSectionOrigin(rawValue: "skill")
    public static let opaque = PromptSectionOrigin(rawValue: "opaque")
}

public struct PromptSection: Sendable, Hashable, Codable {
    public var origin: PromptSectionOrigin
    public var label: String
    public var body: String

    public init(origin: PromptSectionOrigin, label: String, body: String) {
        self.origin = origin
        self.label = label
        self.body = body
    }
}

public struct ToolOrigin: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let builtIn = ToolOrigin(rawValue: "built_in")
    public static let custom = ToolOrigin(rawValue: "custom")
    public static let mcp = ToolOrigin(rawValue: "mcp")
}

public struct ToolDescriptor: Sendable, Hashable, Codable {
    public var name: String
    public var origin: ToolOrigin
    public var originDetail: String?
    public var summary: String?
    public var parameters: TraceJSON?

    public init(
        name: String,
        origin: ToolOrigin,
        originDetail: String? = nil,
        summary: String? = nil,
        parameters: TraceJSON? = nil
    ) {
        self.name = name
        self.origin = origin
        self.originDetail = originDetail
        self.summary = summary
        self.parameters = parameters
    }
}

public struct SamplingParameters: Sendable, Hashable, Codable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var minP: Double?
    public var maxTokens: Int?
    public var repetitionPenalty: Double?
    public var thinkingEnabled: Bool?
    public var thinkingBudget: Int?
    public var toolChoice: String?
    public var responseFormat: TraceJSON?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        minP: Double? = nil,
        maxTokens: Int? = nil,
        repetitionPenalty: Double? = nil,
        thinkingEnabled: Bool? = nil,
        thinkingBudget: Int? = nil,
        toolChoice: String? = nil,
        responseFormat: TraceJSON? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.maxTokens = maxTokens
        self.repetitionPenalty = repetitionPenalty
        self.thinkingEnabled = thinkingEnabled
        self.thinkingBudget = thinkingBudget
        self.toolChoice = toolChoice
        self.responseFormat = responseFormat
    }
}

public struct TraceRole: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let system = TraceRole(rawValue: "system")
    public static let user = TraceRole(rawValue: "user")
    public static let assistant = TraceRole(rawValue: "assistant")
    public static let tool = TraceRole(rawValue: "tool")
}

public struct TraceMessageRef: Sendable, Hashable, Codable, Identifiable {
    public var role: TraceRole
    public var messageID: String
    public var body: String
    public var attachments: [TraceAttachmentRef]

    public var id: String { messageID }

    public init(
        role: TraceRole,
        messageID: String,
        body: String,
        attachments: [TraceAttachmentRef] = []
    ) {
        self.role = role
        self.messageID = messageID
        self.body = body
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case role, messageID, body, attachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(TraceRole.self, forKey: .role)
        messageID = try container.decode(String.self, forKey: .messageID)
        body = try container.decode(String.self, forKey: .body)
        attachments = try container.decodeIfPresent([TraceAttachmentRef].self, forKey: .attachments) ?? []
    }
}

public struct TraceAttachmentRef: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var filename: String
    public var mimeType: String

    public init(id: UUID, filename: String, mimeType: String) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
    }

    public var fileExtension: String {
        URL(fileURLWithPath: filename).pathExtension
    }
}

public struct TraceOmission: Sendable, Hashable, Codable {
    public var subject: String
    public var reason: String

    public init(subject: String, reason: String) {
        self.subject = subject
        self.reason = reason
    }
}
