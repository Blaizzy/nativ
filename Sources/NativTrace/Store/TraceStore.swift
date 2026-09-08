import Foundation

public enum TraceStoreError: Error, CustomStringConvertible {
    case unsupportedPayloadEncoding(String)
    case corruptPayload(String)

    public var description: String {
        switch self {
        case .unsupportedPayloadEncoding(let encoding):
            "Trace payload uses encoding '\(encoding)', which this build cannot read"
        case .corruptPayload(let detail):
            "Corrupt trace payload: \(detail)"
        }
    }
}

/// Append-only storage for trace events.
///
/// An actor so writes never block the main thread, and so sequence allocation
/// and the append that consumes it cannot be separated by a suspension point.
/// `record` does both in one call for exactly that reason: an API that hands
/// out a sequence number and trusts the caller to use it invites two writers to
/// interleave, and the resulting gap is silent.
///
/// Rows in `trace_events` are immutable once written. The only deletion is
/// retention removing a whole trace.
public actor TraceStore {
    /// Key holding the decode failure when a payload cannot be read. The event
    /// still returns, so a corrupt row shows up as an unknown item instead of
    /// vanishing from the middle of a transcript.
    public static let unreadablePayloadKey = "_unreadable"

    private let connection: SQLiteConnection
    private var nextSequenceByTrace: [String: Int64] = [:]

    public init(url: URL = TraceStore.defaultURL()) throws {
        connection = try SQLiteConnection(url: url)
        try TraceSchema.open(connection)
    }

    public static func defaultURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        return applicationSupport
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Traces.sqlite3")
    }

    // MARK: - Writing

    /// Appends one event, allocating its sequence number as part of the same
    /// transaction. Returns the event as stored.
    @discardableResult
    public func record(
        kind: TraceEventKind,
        payload: TraceJSON,
        traceID: String,
        scope: TraceScope,
        timestamp: Date = Date()
    ) throws -> TraceEvent {
        let event = TraceEvent(
            traceID: traceID,
            seq: try nextSequence(forTrace: traceID),
            timestamp: timestamp,
            kind: kind,
            scope: scope,
            payload: payload
        )
        try insert(preSequenced: [event])
        return event
    }

    /// Appends events that already carry sequence numbers.
    ///
    /// For restoring an exported trace and for tests that need a specific
    /// shape. Producers should use `record`, which cannot assign a colliding
    /// sequence.
    public func insert(preSequenced events: [TraceEvent]) throws {
        guard !events.isEmpty else { return }

        try connection.transaction {
            for event in events {
                let encoded = try TracePayloadCodec.encode(event.payload)
                try connection.withStatement(
                    """
                    INSERT INTO trace_events (
                        trace_id, seq, ts, kind, format_version,
                        session_id, turn_id, request_id, round_index, model_id,
                        payload, payload_encoding, payload_bytes
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """
                ) { statement in
                    statement.bind(event.traceID)
                    statement.bind(event.seq)
                    statement.bind(event.timestamp)
                    statement.bind(event.kind.rawValue)
                    statement.bind(Int64(event.formatVersion))
                    statement.bind(event.scope.sessionID)
                    statement.bind(event.scope.turnID)
                    statement.bind(event.scope.requestID)
                    statement.bind(event.scope.roundIndex)
                    statement.bind(event.scope.modelID)
                    statement.bind(encoded.data)
                    statement.bind(encoded.encoding)
                    statement.bind(Int64(encoded.byteCount))
                    try statement.run()
                }
            }
            try TraceIndex.apply(events, on: connection)
        }

        for event in events {
            nextSequenceByTrace[event.traceID] = max(
                nextSequenceByTrace[event.traceID] ?? 0,
                event.seq + 1
            )
        }
    }

    // MARK: - Reading

    /// Events in a trace, oldest first. `after` and `limit` page a long trace
    /// so a reader is not forced to hold a whole session in memory.
    public func events(
        forTrace traceID: String,
        after seq: Int64? = nil,
        limit: Int? = nil
    ) throws -> [TraceEvent] {
        try connection.withStatement(
            """
            SELECT \(Self.eventColumns) FROM trace_events
            WHERE trace_id = ?\(seq == nil ? "" : " AND seq > ?")
            ORDER BY seq ASC
            \(limit == nil ? "" : "LIMIT ?");
            """
        ) { statement in
            statement.bind(traceID)
            if let seq { statement.bind(seq) }
            if let limit { statement.bind(Int64(limit)) }
            return try statement.rows(Self.event)
        }
    }

    public func events(forSession sessionID: String) throws -> [TraceEvent] {
        try events(matching: "session_id = ?", value: sessionID)
    }

    public func events(forRequest requestID: String) throws -> [TraceEvent] {
        try events(matching: "request_id = ?", value: requestID)
    }

    public func recentTraces(limit: Int = 50) throws -> [TraceSummary] {
        try TraceIndex.summaries(limit: limit, on: connection)
    }

    /// Traces belonging to one chat, oldest first — one per model that served it.
    public func traces(forSession sessionID: String) throws -> [TraceSummary] {
        try TraceIndex.summaries(forSession: sessionID, on: connection)
    }

    // MARK: - Maintenance

    /// Removes whole traces that fall outside `window`. Returns how many went.
    @discardableResult
    public func prune(retaining window: TraceRetentionWindow, now: Date = Date()) throws -> Int {
        try connection.transaction {
            let doomed = try TraceIndex.doomedTraceIDs(window, now: now, on: connection)
            guard !doomed.isEmpty else { return 0 }

            try TraceIndex.remove(traceIDs: doomed, on: connection)
            for traceID in doomed {
                nextSequenceByTrace.removeValue(forKey: traceID)
            }
            return doomed.count
        }
    }

    public func deleteAll() throws {
        try connection.transaction {
            try connection.execute("DELETE FROM trace_events;")
            try connection.execute("DELETE FROM trace_index;")
            try connection.execute("DELETE FROM trace_models;")
        }
        nextSequenceByTrace.removeAll()
    }

    /// Rebuilds the derived tables from `trace_events`.
    ///
    /// The index is a cache. If it is ever wrong — an interrupted write, a
    /// restore from backup, a column a newer build added — this restores it
    /// without touching the source of truth.
    public func rebuildIndex() throws {
        try connection.transaction {
            try TraceIndex.rebuild(on: connection)
        }
    }

    // MARK: - Internals

    private static let eventColumns = """
        trace_id, seq, ts, kind, format_version, session_id, turn_id, \
        request_id, round_index, model_id, payload, payload_encoding, payload_bytes
        """

    private func events(matching predicate: String, value: String) throws -> [TraceEvent] {
        try connection.withStatement(
            """
            SELECT \(Self.eventColumns) FROM trace_events
            WHERE \(predicate)
            ORDER BY ts ASC, trace_id ASC, seq ASC;
            """
        ) { statement in
            statement.bind(value)
            return try statement.rows(Self.event)
        }
    }

    private static func event(_ statement: SQLiteStatement) -> TraceEvent {
        TraceEvent(
            traceID: statement.string(0) ?? "",
            seq: statement.int64(1),
            timestamp: statement.date(2),
            kind: TraceEventKind(rawValue: statement.string(3) ?? ""),
            scope: TraceScope(
                sessionID: statement.string(5),
                turnID: statement.string(6),
                requestID: statement.string(7),
                roundIndex: statement.optionalInt(8),
                modelID: statement.string(9)
            ),
            payload: payload(statement),
            formatVersion: statement.int(4)
        )
    }

    private static func payload(_ statement: SQLiteStatement) -> TraceJSON {
        do {
            return try TracePayloadCodec.decode(
                data: statement.data(10),
                encoding: statement.string(11) ?? TracePayloadCodec.plain,
                byteCount: statement.int(12)
            )
        } catch {
            return .object([unreadablePayloadKey: .string(String(describing: error))])
        }
    }

    /// Cached so a burst of streaming events does not query the database once
    /// per event just to learn where it goes.
    private func nextSequence(forTrace traceID: String) throws -> Int64 {
        if let cached = nextSequenceByTrace[traceID] { return cached }

        let stored = try connection.withStatement(
            "SELECT COALESCE(MAX(seq), -1) FROM trace_events WHERE trace_id = ?;"
        ) { statement in
            statement.bind(traceID)
            return try statement.firstRow { $0.int64(0) } ?? -1
        }
        let next = stored + 1
        nextSequenceByTrace[traceID] = next
        return next
    }
}
