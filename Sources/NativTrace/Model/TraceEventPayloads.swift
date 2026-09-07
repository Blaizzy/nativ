import Foundation

extension TracePayloadView where Self: Decodable {
    /// Tolerant decode: unrecognised fields are ignored, and a payload that
    /// cannot be read at all yields `nil` so the reducer can fall back to
    /// rendering the event opaquely instead of dropping it.
    public init?(payload: TraceJSON) {
        guard let data = try? payload.canonicalData(),
              let value = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self = value
    }
}

extension TracePayloadView where Self: Encodable {
    public func makePayload() throws -> TraceJSON {
        try TraceJSON(encoding: self)
    }
}

public struct SessionStartedPayload: TracePayloadView, Codable, Hashable {
    public static let kind = TraceEventKind.sessionStarted

    public var title: String?
    public var modelID: String?

    public init(title: String? = nil, modelID: String? = nil) {
        self.title = title
        self.modelID = modelID
    }
}

public struct TurnStartedPayload: TracePayloadView, Codable, Hashable {
    public static let kind = TraceEventKind.turnStarted

    public var messageID: String
    public var text: String
    public var attachmentSummaries: [String]?

    public init(messageID: String, text: String, attachmentSummaries: [String]? = nil) {
        self.messageID = messageID
        self.text = text
        self.attachmentSummaries = attachmentSummaries
    }
}

public struct TurnEndedPayload: TracePayloadView, Codable, Hashable {
    public static let kind = TraceEventKind.turnEnded

    public var status: String
    public var roundCount: Int?

    public init(status: String, roundCount: Int? = nil) {
        self.status = status
        self.roundCount = roundCount
    }
}

/// Everything Nativ decided to show the model on one call, captured before the
/// pieces are joined into a wire payload.
public struct RequestComposedPayload: TracePayloadView, Codable, Hashable {
    public static let kind = TraceEventKind.requestComposed

    public var systemSections: [PromptSection]
    public var tools: [ToolDescriptor]
    public var parameters: SamplingParameters
    public var messages: [TraceMessageRef]
    public var omissions: [TraceOmission]
    /// False when the round gate withheld tools for this call.
    public var advertisesTools: Bool

    public init(
        systemSections: [PromptSection] = [],
        tools: [ToolDescriptor] = [],
        parameters: SamplingParameters = SamplingParameters(),
        messages: [TraceMessageRef] = [],
        omissions: [TraceOmission] = [],
        advertisesTools: Bool = true
    ) {
        self.systemSections = systemSections
        self.tools = tools
        self.parameters = parameters
        self.messages = messages
        self.omissions = omissions
        self.advertisesTools = advertisesTools
    }
}

public struct ResponseDeltaPayload: TracePayloadView, Codable, Hashable {
    public static let kind = TraceEventKind.responseDelta

    public var content: String?
    public var reasoning: String?

    public init(content: String? = nil, reasoning: String? = nil) {
        self.content = content
        self.reasoning = reasoning
    }
}

public struct ResponseCompletedPayload: TracePayloadView, Codable, Hashable {
    public static let kind = TraceEventKind.responseCompleted

    public var messageID: String
    public var content: String
    public var reasoning: String?
    public var usage: TraceUsage?
    public var finishReason: String?

    public init(
        messageID: String,
        content: String,
        reasoning: String? = nil,
        usage: TraceUsage? = nil,
        finishReason: String? = nil
    ) {
        self.messageID = messageID
        self.content = content
        self.reasoning = reasoning
        self.usage = usage
        self.finishReason = finishReason
    }
}

public struct ResponseFailedPayload: TracePayloadView, Codable, Hashable {
    public static let kind = TraceEventKind.responseFailed

    public var message: String
    public var isCancellation: Bool?

    public init(message: String, isCancellation: Bool? = nil) {
        self.message = message
        self.isCancellation = isCancellation
    }
}

public struct ToolCallPayload: TracePayloadView, Codable, Hashable {
    public static let kind = TraceEventKind.toolCall

    public var callID: String
    public var name: String
    public var origin: ToolOrigin?
    public var originDetail: String?
    public var arguments: TraceJSON?

    public init(
        callID: String,
        name: String,
        origin: ToolOrigin? = nil,
        originDetail: String? = nil,
        arguments: TraceJSON? = nil
    ) {
        self.callID = callID
        self.name = name
        self.origin = origin
        self.originDetail = originDetail
        self.arguments = arguments
    }
}

public struct ToolResultPayload: TracePayloadView, Codable, Hashable {
    public static let kind = TraceEventKind.toolResult

    public var callID: String
    public var messageID: String?
    public var name: String?
    public var output: String?
    public var isError: Bool?
    public var durationMilliseconds: Int?

    public init(
        callID: String,
        messageID: String? = nil,
        name: String? = nil,
        output: String? = nil,
        isError: Bool? = nil,
        durationMilliseconds: Int? = nil
    ) {
        self.callID = callID
        self.messageID = messageID
        self.name = name
        self.output = output
        self.isError = isError
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct ToolConsentPayload: TracePayloadView, Codable, Hashable {
    public static let kind = TraceEventKind.toolConsent

    public var callID: String
    public var name: String?
    /// `requested`, `approved`, `denied`, or `cancelled`.
    public var decision: String

    public init(callID: String, name: String? = nil, decision: String) {
        self.callID = callID
        self.name = name
        self.decision = decision
    }
}

public struct ModelSwitchedPayload: TracePayloadView, Codable, Hashable {
    public static let kind = TraceEventKind.modelSwitched

    public var from: String?
    public var to: String

    public init(from: String? = nil, to: String) {
        self.from = from
        self.to = to
    }
}

public struct TraceUsage: Sendable, Hashable, Codable {
    public var promptTokens: Int?
    public var completionTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}
