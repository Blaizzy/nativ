import Foundation

/// One row of a rendered trace.
///
/// Produced only by `TraceReducer`, never written to disk. Common identity
/// fields sit on the struct so readers can sort, group, and key a list without
/// switching on the body; everything kind-specific lives in `body`.
public struct TraceItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let scope: TraceScope
    public var body: Body

    public init(id: String, timestamp: Date, scope: TraceScope, body: Body) {
        self.id = id
        self.timestamp = timestamp
        self.scope = scope
        self.body = body
    }

    public enum Body: Sendable, Hashable {
        /// Assistant reasoning lives on the message rather than in a case of
        /// its own: one fact, one representation.
        case message(TraceMessageBody)
        /// What Nativ composed for one call: system sections, tools, sampling.
        case exposure(RequestComposedPayload)
        /// A call Nativ did not compose, captured off the wire.
        case wireRequest(RequestSentPayload)
        case tool(TraceToolBody)
        case lifecycle(TraceLifecycleBody)
        /// An event this build does not recognise. Kept so a trace written by a
        /// newer Nativ still shows every row rather than silently shrinking.
        case unknown(kind: TraceEventKind, payload: TraceJSON)
    }
}

public struct TraceMessageBody: Sendable, Hashable {
    public var role: TraceRole
    public var messageID: String?
    public var text: String
    public var reasoning: String?
    public var isStreaming: Bool
    public var usage: TraceUsage?
    public var finishReason: String?
    public var attachmentSummaries: [String]

    public init(
        role: TraceRole,
        messageID: String? = nil,
        text: String = "",
        reasoning: String? = nil,
        isStreaming: Bool = false,
        usage: TraceUsage? = nil,
        finishReason: String? = nil,
        attachmentSummaries: [String] = []
    ) {
        self.role = role
        self.messageID = messageID
        self.text = text
        self.reasoning = reasoning
        self.isStreaming = isStreaming
        self.usage = usage
        self.finishReason = finishReason
        self.attachmentSummaries = attachmentSummaries
    }
}

public struct TraceToolBody: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        case awaitingConsent
        case running
        case completed
        case failed
        case denied
    }

    public var callID: String
    public var name: String
    public var origin: ToolOrigin?
    public var originDetail: String?
    public var arguments: TraceJSON?
    public var status: Status
    public var output: String?
    public var durationMilliseconds: Int?
    /// `nil` when the call was never gated on the user.
    public var consentDecision: String?

    public init(
        callID: String,
        name: String,
        origin: ToolOrigin? = nil,
        originDetail: String? = nil,
        arguments: TraceJSON? = nil,
        status: Status = .running,
        output: String? = nil,
        durationMilliseconds: Int? = nil,
        consentDecision: String? = nil
    ) {
        self.callID = callID
        self.name = name
        self.origin = origin
        self.originDetail = originDetail
        self.arguments = arguments
        self.status = status
        self.output = output
        self.durationMilliseconds = durationMilliseconds
        self.consentDecision = consentDecision
    }
}

public struct TraceLifecycleBody: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case sessionStarted
        case turnEnded
        case modelSwitched
        case failure
    }

    public var kind: Kind
    public var title: String
    public var detail: String?

    public init(kind: Kind, title: String, detail: String? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}
