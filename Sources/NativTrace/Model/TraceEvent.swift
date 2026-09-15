import Foundation

public struct TraceEvent: Sendable, Hashable, Codable, Identifiable {
    public static let currentFormatVersion = 1

    public let traceID: String
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
    public static func ordered(_ lhs: TraceEvent, _ rhs: TraceEvent) -> Bool {
        if lhs.traceID == rhs.traceID { return lhs.seq < rhs.seq }
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return (lhs.traceID, lhs.seq) < (rhs.traceID, rhs.seq)
    }
}

public protocol TracePayloadView: Sendable {
    static var kind: TraceEventKind { get }
    init?(payload: TraceJSON)
}

extension TracePayloadView {
    public init?(event: TraceEvent) {
        guard event.kind == Self.kind else { return nil }
        self.init(payload: event.payload)
    }
}
