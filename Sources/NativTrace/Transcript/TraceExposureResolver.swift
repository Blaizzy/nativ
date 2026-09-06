import Foundation

/// A message referenced by an exposure, paired with the body it resolved to.
public struct ResolvedMessage: Sendable, Hashable, Identifiable {
    public let reference: TraceMessageRef
    /// `nil` when the body is not in this trace and was not inlined.
    public let text: String?
    /// True when the resolved body hashes to what the producer recorded. False
    /// means the reader found a message with the right id but the wrong
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

/// Turns the compact form written to disk back into something renderable.
///
/// A tool loop re-sends the whole conversation every round, so an exposure
/// stores message *references* rather than bodies. Resolution walks the items
/// already folded from the same trace, which is why the trace stays
/// self-contained: the bodies are events too.
public enum TraceExposureResolver {
    public static func resolve(
        _ payload: RequestComposedPayload,
        in items: [TraceItem]
    ) -> ResolvedExposure {
        var bodiesByMessageID: [String: String] = [:]
        for item in items {
            switch item.body {
            case .message(let message):
                if let id = message.messageID { bodiesByMessageID[id] = message.text }
            case .tool(let tool):
                if let output = tool.output { bodiesByMessageID[tool.callID] = output }
            default:
                continue
            }
        }

        let messages = payload.messages.map { reference -> ResolvedMessage in
            if let inline = reference.inlineBody {
                return ResolvedMessage(
                    reference: reference,
                    text: inline,
                    isVerified: TraceHash.content(inline) == reference.contentHash
                )
            }
            guard let body = bodiesByMessageID[reference.messageID] else {
                return ResolvedMessage(reference: reference, text: nil, isVerified: false)
            }
            return ResolvedMessage(
                reference: reference,
                text: body,
                isVerified: TraceHash.content(body) == reference.contentHash
            )
        }

        return ResolvedExposure(
            systemSections: payload.systemSections,
            tools: payload.tools,
            parameters: payload.parameters,
            messages: messages,
            omissions: payload.omissions,
            advertisesTools: payload.advertisesTools
        )
    }
}
