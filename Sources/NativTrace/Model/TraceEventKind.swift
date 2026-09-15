import Foundation

public struct TraceEventKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension TraceEventKind {
    public static let sessionStarted = TraceEventKind(rawValue: "session_started")
    public static let turnStarted = TraceEventKind(rawValue: "turn_started")
    public static let turnEnded = TraceEventKind(rawValue: "turn_ended")

    public static let requestComposed = TraceEventKind(rawValue: "request_composed")
    public static let responseDelta = TraceEventKind(rawValue: "response_delta")
    public static let responseCompleted = TraceEventKind(rawValue: "response_completed")
    public static let responseFailed = TraceEventKind(rawValue: "response_failed")

    public static let toolCall = TraceEventKind(rawValue: "tool_call")
    public static let toolResult = TraceEventKind(rawValue: "tool_result")
    public static let toolConsent = TraceEventKind(rawValue: "tool_consent")

    public static let modelSwitched = TraceEventKind(rawValue: "model_switched")
}

extension TraceEventKind {
    public var sealsStreamedOutput: Bool {
        self == .responseFailed || self == .turnEnded
    }
}

extension TraceEventKind: CustomStringConvertible {
    public var description: String { rawValue }
}

