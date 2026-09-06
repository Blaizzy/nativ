import Foundation

public enum TraceStoreError: Error, CustomStringConvertible {
    case corruptPayload(String)
    case unsupportedPayloadEncoding(String)
    case sequenceConflict(traceID: String, seq: Int64)

    public var description: String {
        switch self {
        case .corruptPayload(let detail): "Corrupt trace payload: \(detail)"
        case .unsupportedPayloadEncoding(let encoding):
            "Trace payload uses encoding '\(encoding)', which this build cannot read"
        case .sequenceConflict(let traceID, let seq):
            "Trace \(traceID) already has an event at seq \(seq)"
        }
    }
}

/// Summary row for one trace, read from the derived index.
public struct TraceSummary: Sendable, Hashable, Identifiable {
    public let traceID: String
    public let sessionID: String?
    public let startedAt: Date
    public let lastEventAt: Date
    public let eventCount: Int
    public let lastSeq: Int64
    public let modelIDs: [String]

    public var id: String { traceID }
}

/// Append-only storage for trace events.
///
/// An actor so that writes never block the main thread and so that sequence
/// allocation, the append itself, and the derived-index update happen as one
/// serialised unit. `trace_events` rows are immutable once written; the only
/// deletions are whole-trace, performed by retention.
public actor TraceStore {
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

    /// Allocates the next sequence number for a trace.
    ///
    /// Cached per trace so a burst of streaming events does not hit the
    /// database once per event just to learn where it goes.
    public func reserveSequence(forTrace traceID: String, count: Int = 1) throws -> Int64 {
        let next = try nextSequenceByTrace[traceID] ?? loadNextSequence(forTrace: traceID)
        nextSequenceByTrace[traceID] = next + Int64(count)
        return next
    }

    public func append(_ event: TraceEvent) throws {
        try append([event])
    }

    public func append(_ events: [TraceEvent]) throws {
        guard !events.isEmpty else { return }
        try connection.transaction {
            let insert = try connection.prepare(
                """
                INSERT INTO trace_events (
                    trace_id, seq, ts, kind, format_version,
                    session_id, turn_id, request_id, round_index, model_id,
                    payload, payload_encoding, payload_bytes
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            )
            for event in events {
                let encoded = try TracePayloadCodec.encode(event.payload)
                insert.bind(event.traceID, at: 1)
                insert.bind(event.seq, at: 2)
                insert.bind(event.timestamp.timeIntervalSince1970, at: 3)
                insert.bind(event.kind.rawValue, at: 4)
                insert.bind(Int64(event.formatVersion), at: 5)
                insert.bind(event.scope.sessionID, at: 6)
                insert.bind(event.scope.turnID, at: 7)
                insert.bind(event.scope.requestID, at: 8)
                insert.bind(event.scope.roundIndex, at: 9)
                insert.bind(event.scope.modelID, at: 10)
                insert.bind(encoded.data, at: 11)
                insert.bind(encoded.encoding, at: 12)
                insert.bind(Int64(encoded.byteCount), at: 13)
                try insert.run()
                insert.reset()
            }
            try updateIndex(for: events)
        }

        for event in events {
            let next = event.seq + 1
            if next > nextSequenceByTrace[event.traceID] ?? 0 {
                nextSequenceByTrace[event.traceID] = next
            }
        }
    }

    // MARK: - Reading

    public func events(forTrace traceID: String, after seq: Int64? = nil) throws -> [TraceEvent] {
        let sql = """
            SELECT \(eventColumns) FROM trace_events
            WHERE trace_id = ?\(seq == nil ? "" : " AND seq > ?")
            ORDER BY seq ASC;
            """
        let statement = try connection.prepare(sql)
        statement.bind(traceID, at: 1)
        if let seq { statement.bind(seq, at: 2) }
        return try readEvents(statement)
    }

    public func events(forSession sessionID: String) throws -> [TraceEvent] {
        let statement = try connection.prepare(
            """
            SELECT \(eventColumns) FROM trace_events
            WHERE session_id = ?
            ORDER BY ts ASC, trace_id ASC, seq ASC;
            """
        )
        statement.bind(sessionID, at: 1)
        return try readEvents(statement)
    }

    public func events(forRequest requestID: String) throws -> [TraceEvent] {
        let statement = try connection.prepare(
            """
            SELECT \(eventColumns) FROM trace_events
            WHERE request_id = ?
            ORDER BY ts ASC, trace_id ASC, seq ASC;
            """
        )
        statement.bind(requestID, at: 1)
        return try readEvents(statement)
    }

    public func recentTraces(limit: Int = 50) throws -> [TraceSummary] {
        let statement = try connection.prepare(
            """
            SELECT trace_id, session_id, started_at, last_event_at, event_count, last_seq, models
            FROM trace_index
            ORDER BY last_event_at DESC
            LIMIT ?;
            """
        )
        statement.bind(Int64(limit), at: 1)

        var rows: [TraceSummary] = []
        while try statement.step() {
            rows.append(
                TraceSummary(
                    traceID: statement.string(at: 0) ?? "",
                    sessionID: statement.string(at: 1),
                    startedAt: Date(timeIntervalSince1970: statement.double(at: 2)),
                    lastEventAt: Date(timeIntervalSince1970: statement.double(at: 3)),
                    eventCount: statement.int(at: 4),
                    lastSeq: statement.int64(at: 5),
                    modelIDs: decodeModelList(statement.string(at: 6))
                )
            )
        }
        return rows
    }

    // MARK: - Maintenance

    /// Drops whole traces whose last activity predates `cutoff`, then trims the
    /// oldest traces until at most `maxTraces` remain. Returns the number of
    /// traces removed.
    @discardableResult
    public func prune(before cutoff: Date, maxTraces: Int?) throws -> Int {
        try connection.transaction {
            var removed = 0

            let byAge = try connection.prepare(
                "DELETE FROM trace_index WHERE last_event_at < ? RETURNING trace_id;"
            )
            byAge.bind(cutoff.timeIntervalSince1970, at: 1)
            var doomed: [String] = []
            while try byAge.step() {
                if let traceID = byAge.string(at: 0) { doomed.append(traceID) }
            }

            if let maxTraces, maxTraces >= 0 {
                let overflow = try connection.prepare(
                    """
                    DELETE FROM trace_index WHERE trace_id IN (
                        SELECT trace_id FROM trace_index
                        ORDER BY last_event_at DESC
                        LIMIT -1 OFFSET ?
                    ) RETURNING trace_id;
                    """
                )
                overflow.bind(Int64(maxTraces), at: 1)
                while try overflow.step() {
                    if let traceID = overflow.string(at: 0) { doomed.append(traceID) }
                }
            }

            let deleteEvents = try connection.prepare("DELETE FROM trace_events WHERE trace_id = ?;")
            for traceID in doomed {
                deleteEvents.bind(traceID, at: 1)
                try deleteEvents.run()
                deleteEvents.reset()
                nextSequenceByTrace.removeValue(forKey: traceID)
                removed += 1
            }
            return removed
        }
    }

    public func deleteAll() throws {
        try connection.transaction {
            try connection.execute("DELETE FROM trace_events;")
            try connection.execute("DELETE FROM trace_index;")
        }
        nextSequenceByTrace.removeAll()
    }

    /// Rebuilds `trace_index` from `trace_events`.
    ///
    /// The index is a cache. If it is ever wrong — an interrupted write, a
    /// restore from backup, a future column added by a newer build — this
    /// restores it without touching the source of truth.
    public func rebuildIndex() throws {
        try connection.transaction {
            try connection.execute("DELETE FROM trace_index;")
            try connection.execute(
                """
                INSERT INTO trace_index (
                    trace_id, session_id, started_at, last_event_at, event_count, last_seq, models
                )
                SELECT
                    trace_id,
                    MAX(session_id),
                    MIN(ts),
                    MAX(ts),
                    COUNT(*),
                    MAX(seq),
                    '[]'
                FROM trace_events
                GROUP BY trace_id;
                """
            )
            try connection.execute(
                """
                UPDATE trace_index SET models = COALESCE((
                    SELECT json_group_array(model_id) FROM (
                        SELECT DISTINCT model_id FROM trace_events
                        WHERE trace_events.trace_id = trace_index.trace_id
                          AND model_id IS NOT NULL
                        ORDER BY model_id
                    )
                ), '[]');
                """
            )
        }
    }

    // MARK: - Internals

    private let eventColumns = """
        trace_id, seq, ts, kind, format_version, session_id, turn_id, \
        request_id, round_index, model_id, payload, payload_encoding, payload_bytes
        """

    private func readEvents(_ statement: SQLiteStatement) throws -> [TraceEvent] {
        var events: [TraceEvent] = []
        while try statement.step() {
            let payload: TraceJSON
            do {
                payload = try TracePayloadCodec.decode(
                    data: statement.data(at: 10),
                    encoding: statement.string(at: 11) ?? TracePayloadCodec.plain,
                    byteCount: statement.int(at: 12)
                )
            } catch {
                payload = .object(["_unreadable": .string(String(describing: error))])
            }

            events.append(
                TraceEvent(
                    traceID: statement.string(at: 0) ?? "",
                    seq: statement.int64(at: 1),
                    timestamp: Date(timeIntervalSince1970: statement.double(at: 2)),
                    kind: TraceEventKind(rawValue: statement.string(at: 3) ?? ""),
                    scope: TraceScope(
                        sessionID: statement.string(at: 5),
                        turnID: statement.string(at: 6),
                        requestID: statement.string(at: 7),
                        roundIndex: statement.optionalInt(at: 8),
                        modelID: statement.string(at: 9)
                    ),
                    payload: payload,
                    formatVersion: statement.int(at: 4)
                )
            )
        }
        return events
    }

    private func loadNextSequence(forTrace traceID: String) throws -> Int64 {
        let statement = try connection.prepare(
            "SELECT COALESCE(MAX(seq), -1) FROM trace_events WHERE trace_id = ?;"
        )
        statement.bind(traceID, at: 1)
        guard try statement.step() else { return 0 }
        return statement.int64(at: 0) + 1
    }

    private func updateIndex(for events: [TraceEvent]) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO trace_index (
                trace_id, session_id, started_at, last_event_at, event_count, last_seq, models
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(trace_id) DO UPDATE SET
                session_id    = COALESCE(trace_index.session_id, excluded.session_id),
                started_at    = MIN(trace_index.started_at, excluded.started_at),
                last_event_at = MAX(trace_index.last_event_at, excluded.last_event_at),
                event_count   = trace_index.event_count + excluded.event_count,
                last_seq      = MAX(trace_index.last_seq, excluded.last_seq),
                models        = excluded.models;
            """
        )

        for (traceID, batch) in Dictionary(grouping: events, by: \.traceID) {
            let timestamps = batch.map(\.timestamp.timeIntervalSince1970)
            let existing = try existingModelIDs(forTrace: traceID)
            let merged = existing.union(batch.compactMap(\.scope.modelID))
            let models = merged.sorted().map(TraceJSON.string)

            statement.bind(traceID, at: 1)
            statement.bind(batch.compactMap(\.scope.sessionID).first, at: 2)
            statement.bind(timestamps.min() ?? 0, at: 3)
            statement.bind(timestamps.max() ?? 0, at: 4)
            statement.bind(Int64(batch.count), at: 5)
            statement.bind(batch.map(\.seq).max() ?? 0, at: 6)
            statement.bind(try TraceJSON.array(models).canonicalString(), at: 7)
            try statement.run()
            statement.reset()
        }
    }

    private func existingModelIDs(forTrace traceID: String) throws -> Set<String> {
        let statement = try connection.prepare("SELECT models FROM trace_index WHERE trace_id = ?;")
        statement.bind(traceID, at: 1)
        guard try statement.step() else { return [] }
        return Set(decodeModelList(statement.string(at: 0)))
    }

    private func decodeModelList(_ raw: String?) -> [String] {
        guard let raw, let json = try? TraceJSON.decode(raw), let items = json.arrayValue else {
            return []
        }
        return items.compactMap(\.stringValue)
    }
}
