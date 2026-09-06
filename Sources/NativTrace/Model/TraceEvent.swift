import Foundation

/// One immutable, append-only record in a trace.
///
/// Events are the source of truth. Everything a reader shows — the transcript,
/// the exposure panel, the dashboard's per-call rows — is folded from these and
/// can be thrown away and rebuilt. Nothing in the system may mutate an event
/// after it is written.
public struct TraceEvent: Sendable, Hashable, Codable, Identifiable {
    /// Bumped only for a change that older builds cannot read correctly.
    /// Additive changes — a new `TraceEventKind`, a new payload field — do not
    /// bump it, because the format tolerates both by construction.
    public static let currentFormatVersion = 1

    /// Trace this event belongs to. One trace per chat session, or one per
    /// external client connection.
    public let traceID: String
    /// Position within the trace. Monotonic, assigned by the writer, and the
    /// tiebreaker when two events share a timestamp.
    public let seq: Int64
    public let timestamp: Date
    public let kind: TraceEventKind
    public let scope: TraceScope
    public let payload: TraceJSON
    public let formatVersion: Int

    public var id: String { "\(traceID):\(seq)" }

    public init(
        traceID: String,
        seq: Int64,
        timestamp: Date,
        kind: TraceEventKind,
        scope: TraceScope = TraceScope(),
        payload: TraceJSON = .object([:]),
        formatVersion: Int = TraceEvent.currentFormatVersion
    ) {
        self.traceID = traceID
        self.seq = seq
        self.timestamp = timestamp
        self.kind = kind
        self.scope = scope
        self.payload = payload
        self.formatVersion = formatVersion
    }
}

extension TraceEvent {
    /// Total order used everywhere events are merged: sequence within a trace,
    /// timestamp across traces. Two writers never share a `traceID`, so `seq`
    /// alone orders a single trace deterministically.
    public static func ordered(_ lhs: TraceEvent, _ rhs: TraceEvent) -> Bool {
        if lhs.traceID == rhs.traceID { return lhs.seq < rhs.seq }
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return (lhs.traceID, lhs.seq) < (rhs.traceID, rhs.seq)
    }
}

/// A typed reader over a `TraceEvent` payload.
///
/// Conformances must tolerate missing and unrecognised fields: they are applied
/// to payloads written by other builds. Returning `nil` from `init` means "this
/// payload is not mine", not "this payload is malformed".
public protocol TracePayloadView: Sendable {
    static var kind: TraceEventKind { get }
    init?(payload: TraceJSON)
}

extension TracePayloadView {
    /// Reads the view from an event, or `nil` if the event is a different kind.
    public init?(event: TraceEvent) {
        guard event.kind == Self.kind else { return nil }
        self.init(payload: event.payload)
    }
}
