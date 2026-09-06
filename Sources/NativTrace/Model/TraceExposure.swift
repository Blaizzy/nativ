import Foundation

/// Where a piece of the system prompt came from.
///
/// Open for the same reason `TraceEventKind` is: a build that gains a new
/// prompt source must not break readers that predate it. Unknown origins render
/// under their `label`.
public struct PromptSectionOrigin: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The system prompt the user typed in settings.
    public static let userSystemPrompt = PromptSectionOrigin(rawValue: "user_system_prompt")
    /// A project's standing instructions.
    public static let project = PromptSectionOrigin(rawValue: "project")
    /// The built-in guidance Nativ injects whenever tools are advertised.
    public static let toolGuide = PromptSectionOrigin(rawValue: "tool_guide")
    /// An enabled skill's instructions.
    public static let skill = PromptSectionOrigin(rawValue: "skill")
    /// Text extracted from an attached document.
    public static let documentContext = PromptSectionOrigin(rawValue: "document_context")
    /// A system prompt recovered from the wire, whose composition is unknown.
    public static let opaque = PromptSectionOrigin(rawValue: "opaque")
}

/// One labelled span of the system prompt, recorded before the parts are joined.
///
/// Nativ composes the system prompt itself, so provenance is captured at the
/// source rather than parsed back out of the flattened string.
public struct PromptSection: Sendable, Hashable, Codable {
    public var origin: PromptSectionOrigin
    /// Human-facing name for this span — the skill or project it came from.
    public var label: String
    public var body: String

    public init(origin: PromptSectionOrigin, label: String, body: String) {
        self.origin = origin
        self.label = label
        self.body = body
    }
}

/// Where a tool advertised to the model came from.
public struct ToolOrigin: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Shipped with Nativ.
    public static let builtIn = ToolOrigin(rawValue: "built_in")
    /// Defined by the user in settings.
    public static let custom = ToolOrigin(rawValue: "custom")
    /// Provided by a connected MCP server; `originDetail` names the server.
    public static let mcp = ToolOrigin(rawValue: "mcp")
    /// Contributed by an installed extension.
    public static let extensionProvided = ToolOrigin(rawValue: "extension")
}

/// A tool as it was advertised to the model on one call.
public struct ToolDescriptor: Sendable, Hashable, Codable {
    public var name: String
    public var origin: ToolOrigin
    /// Qualifies `origin` — the MCP server or extension the tool came from.
    public var originDetail: String?
    public var summary: String?
    /// The parameter schema exactly as sent.
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

    /// Stable identity for diffing one call's tool set against the previous
    /// call's: a rename, a re-scoped MCP server, or an edited schema all count
    /// as a change the reader should see.
    public var fingerprint: String {
        let schema = parameters.flatMap { try? $0.canonicalString() } ?? ""
        return "\(name)|\(origin.rawValue)|\(originDetail ?? "")|\(schema)"
    }
}

/// Sampling and decoding settings for one call.
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

/// Role of a message in the conversation as the model received it.
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

/// A message included in one call, identified rather than duplicated.
///
/// The body already exists in the trace — it arrived as a `turn_started`,
/// `response_completed`, or `tool_result` event — so repeating it on every round
/// of a tool loop would make storage quadratic in turn length. `contentHash`
/// lets a reader confirm it resolved the reference to the same text that was
/// actually sent, which matters after an edit or a branch.
public struct TraceMessageRef: Sendable, Hashable, Codable {
    public var role: TraceRole
    /// Producer-assigned id of the message; resolvable within this trace.
    public var messageID: String
    public var contentHash: String
    public var byteCount: Int
    /// Present only when the body cannot be resolved from the trace, such as
    /// history imported from outside Nativ.
    public var inlineBody: String?

    public init(
        role: TraceRole,
        messageID: String,
        contentHash: String,
        byteCount: Int,
        inlineBody: String? = nil
    ) {
        self.role = role
        self.messageID = messageID
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.inlineBody = inlineBody
    }
}

/// Something Nativ deliberately left out of a call.
public struct TraceOmission: Sendable, Hashable, Codable {
    public var subject: String
    public var reason: String

    public init(subject: String, reason: String) {
        self.subject = subject
        self.reason = reason
    }
}
