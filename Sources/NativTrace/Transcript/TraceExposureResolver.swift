import Foundation

public struct ResolvedMessage: Sendable, Hashable, Identifiable {
    public let reference: TraceMessageRef
    public let text: String?
    public let isVerified: Bool

    public var id: String { reference.messageID }

    public var isMissing: Bool { text == nil }
}

public struct ResolvedExposure: Sendable, Hashable {
    public let systemSections: [PromptSection]
    public let tools: [ToolDescriptor]
    public let parameters: SamplingParameters
    public let messages: [ResolvedMessage]
    public let omissions: [TraceOmission]
    public let advertisesTools: Bool
}

public struct TraceExposureIndex: Sendable {
    private let bodiesByID: [String: String]
    private let verified: [String: Bool]

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
        verified = bodies.reduce(into: [:]) { result, entry in
            result[Self.verificationKey(entry.key, TraceHash.content(entry.value))] = true
        }
    }

    private static func verificationKey(_ messageID: String, _ hash: String) -> String {
        "\(messageID)|\(hash)"
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

    public func resolve(_ reference: TraceMessageRef) -> ResolvedMessage {
        guard let body = reference.inlineBody ?? bodiesByID[reference.messageID] else {
            return ResolvedMessage(reference: reference, text: nil, isVerified: false)
        }
        let matches = reference.inlineBody == nil
            ? verified[Self.verificationKey(reference.messageID, reference.contentHash)] ?? false
            : TraceHash.content(body) == reference.contentHash
        return ResolvedMessage(reference: reference, text: body, isVerified: matches)
    }
}
