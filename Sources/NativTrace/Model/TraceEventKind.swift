import Foundation

/// The kind of a recorded trace event.
///
/// Deliberately an open string-backed type rather than a closed `enum`: a trace
/// written by a newer build carries kinds this build has never heard of, and
/// decoding one must not fail. Unknown kinds flow through the store untouched
/// and surface in the transcript as `TraceItem.unknown`.
///
/// Values are part of the on-disk format. Never rename or reuse one; add a new
/// kind and leave the old constant in place so historical traces keep rendering.
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
    /// A chat session was opened or resumed.
    public static let sessionStarted = TraceEventKind(rawValue: "session_started")
    /// The user submitted a prompt, opening a turn.
    public static let turnStarted = TraceEventKind(rawValue: "turn_started")
    /// A turn finished, successfully or otherwise.
    public static let turnEnded = TraceEventKind(rawValue: "turn_ended")

    /// Nativ finished assembling one model call, before flattening it to the
    /// wire. Carries system-prompt provenance and tool origins that cannot be
    /// recovered from the request body alone.
    public static let requestComposed = TraceEventKind(rawValue: "request_composed")
    /// The request body as sent. Emitted for calls Nativ did not compose.
    public static let requestSent = TraceEventKind(rawValue: "request_sent")
    /// Coalesced streaming output for one model call.
    public static let responseDelta = TraceEventKind(rawValue: "response_delta")
    /// A model call finished, with usage and timings.
    public static let responseCompleted = TraceEventKind(rawValue: "response_completed")
    /// A model call failed.
    public static let responseFailed = TraceEventKind(rawValue: "response_failed")

    /// The model asked for a tool.
    public static let toolCall = TraceEventKind(rawValue: "tool_call")
    /// A tool returned.
    public static let toolResult = TraceEventKind(rawValue: "tool_result")
    /// A tool call was gated on the user, and how that resolved.
    public static let toolConsent = TraceEventKind(rawValue: "tool_consent")

    /// The active model changed mid-session.
    public static let modelSwitched = TraceEventKind(rawValue: "model_switched")
}

extension TraceEventKind {
    /// Kinds that end a call's output without carrying it.
    ///
    /// `responseCompleted` is absent on purpose: it carries the authoritative
    /// text, so the accumulated stream is discarded rather than written. Tool
    /// events are absent too — a tool call happens *within* a call, and sealing
    /// on one would store the partial text and then store it again with the
    /// completion.
    public var sealsStreamedOutput: Bool {
        self == .responseFailed || self == .turnEnded
    }
}

extension TraceEventKind: CustomStringConvertible {
    public var description: String { rawValue }
}
