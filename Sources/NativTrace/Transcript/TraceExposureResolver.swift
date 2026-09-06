import Foundation

/// A message referenced by an exposure, paired with the body it resolved to.
public struct ResolvedMessage: Sendable, Hashable, Identifiable {
    public let reference: TraceMessageRef
    /// `nil` when the body is not in this trace and was not inlined.
    public let text: String?
    /// True when the resolved body hashes to what the producer recorded. False
    /// means the reader found a message with the right id but different
    /// content — an edited or branched turn — and must not present it as what
    /// the model saw.
    public let isVerified: Bool

    public var id: String { reference.messageID }

    public var isMissing: Bool { text == nil }
}

/// What one call showed the model, with message references resolved.
public struct ResolvedExposure: Sendable, Hashable {
    public let systemSections: [PromptSection]
    public let tools: [ToolDescriptor]
    public let parameters: SamplingParameters
    public let messages: [ResolvedMessage]
    public let omissions: [TraceOmission]
    public let advertisesTools: Bool

    public var systemPromptText: String {
        systemSections.map(\.body).joined(separator: "\n\n")
    }
}

/// Resolves the message references in an exposure against the trace they came
/// from.
///
/// Built once per transcript and reused. A turn's tool loop produces one
/// exposure per round, so resolving each against a freshly walked item list
/// would be quadratic in the length of the turn — which is exactly the cost the
/// reference scheme exists to avoid paying in storage.
public struct TraceExposureIndex: Sendable {
    private let bodiesByID: [String: String]

    public init(items: [TraceItem]) {
        var bodies: [String: String] = [:]
        for item in items {
            switch item.body {
            case .message(let message):
                if let id = message.messageID { bodies[id] = message.text }
            case .tool(let tool):
                if let output = tool.output { bodies[tool.callID] = output }
            default:
                continue
            }
        }
        bodiesByID = bodies
    }

    public func resolve(_ payload: RequestComposedPayload) -> ResolvedExposure {
        ResolvedExposure(
            systemSections: payload.systemSections,
            tools: payload.tools,
            parameters: payload.parameters,
            messages: payload.messages.map(resolve),
            omissions: payload.omissions,
            advertisesTools: payload.advertisesTools
        )
    }

    private func resolve(_ reference: TraceMessageRef) -> ResolvedMessage {
        guard let body = reference.inlineBody ?? bodiesByID[reference.messageID] else {
            return ResolvedMessage(reference: reference, text: nil, isVerified: false)
        }
        return ResolvedMessage(
            reference: reference,
            text: body,
            isVerified: TraceHash.content(body) == reference.contentHash
        )
    }
}
