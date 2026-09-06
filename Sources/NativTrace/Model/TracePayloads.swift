import Foundation

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

public struct TraceUsage: Sendable, Hashable, Codable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var generatedTokens: Int?
    public var timeToFirstTokenMilliseconds: Int?
    public var elapsedMilliseconds: Int?
    public var decodeTokensPerSecond: Double?
    public var peakMemoryBytes: Int64?

    public init(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        generatedTokens: Int? = nil,
        timeToFirstTokenMilliseconds: Int? = nil,
        elapsedMilliseconds: Int? = nil,
        decodeTokensPerSecond: Double? = nil,
        peakMemoryBytes: Int64? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.generatedTokens = generatedTokens
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.elapsedMilliseconds = elapsedMilliseconds
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.peakMemoryBytes = peakMemoryBytes
    }
}
