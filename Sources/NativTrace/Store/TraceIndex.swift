import Foundation

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

/// Maintains `trace_index` and `trace_models`.
///
/// Both are caches. `rebuild` reconstructs them from `trace_events` alone, and
/// nothing may read a fact from them that is not derivable from the events —
/// if that stops being true, the index has quietly become a second source of
/// truth and a restore from backup will produce a different app.
///
/// Models live in their own table rather than as a JSON column so that adding
/// one is an `INSERT OR IGNORE`. Merging into a column would mean reading the
/// current list, unioning, and writing it back on every append: a query per
/// trace per batch, and a read-modify-write where an insert would do.
enum TraceIndex {
    static func apply(_ events: [TraceEvent], on connection: SQLiteConnection) throws {
        for (traceID, batch) in Dictionary(grouping: events, by: \.traceID) {
            let timestamps = batch.map(\.timestamp)
            try connection.withStatement(
                """
                INSERT INTO trace_index (
                    trace_id, session_id, started_at, last_event_at, event_count, last_seq
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(trace_id) DO UPDATE SET
                    session_id    = COALESCE(trace_index.session_id, excluded.session_id),
                    started_at    = MIN(trace_index.started_at, excluded.started_at),
                    last_event_at = MAX(trace_index.last_event_at, excluded.last_event_at),
                    event_count   = trace_index.event_count + excluded.event_count,
                    last_seq      = MAX(trace_index.last_seq, excluded.last_seq);
                """
            ) { statement in
                statement.bind(traceID)
                statement.bind(batch.compactMap(\.scope.sessionID).first)
                statement.bind(timestamps.min() ?? .distantPast)
                statement.bind(timestamps.max() ?? .distantPast)
                statement.bind(Int64(batch.count))
                statement.bind(batch.map(\.seq).max() ?? 0)
                try statement.run()
            }

            for modelID in Set(batch.compactMap(\.scope.modelID)) {
                try connection.withStatement(
                    "INSERT OR IGNORE INTO trace_models (trace_id, model_id) VALUES (?, ?);"
                ) { statement in
                    statement.bind(traceID)
                    statement.bind(modelID)
                    try statement.run()
                }
            }
        }
    }

    static func summaries(limit: Int, on connection: SQLiteConnection) throws -> [TraceSummary] {
        try connection.withStatement(
            """
            SELECT trace_id, session_id, started_at, last_event_at, event_count, last_seq
            FROM trace_index
            ORDER BY last_event_at DESC
            LIMIT ?;
            """
        ) { statement in
            statement.bind(Int64(limit))
            let partial = try statement.rows {
                (
                    traceID: $0.string(0) ?? "",
                    sessionID: $0.string(1),
                    startedAt: $0.date(2),
                    lastEventAt: $0.date(3),
                    eventCount: $0.int(4),
                    lastSeq: $0.int64(5)
                )
            }
            return try partial.map { row in
                TraceSummary(
                    traceID: row.traceID,
                    sessionID: row.sessionID,
                    startedAt: row.startedAt,
                    lastEventAt: row.lastEventAt,
                    eventCount: row.eventCount,
                    lastSeq: row.lastSeq,
                    modelIDs: try modelIDs(forTrace: row.traceID, on: connection)
                )
            }
        }
    }

    static func remove(traceIDs: [String], on connection: SQLiteConnection) throws {
        for traceID in traceIDs {
            for sql in [
                "DELETE FROM trace_events WHERE trace_id = ?;",
                "DELETE FROM trace_models WHERE trace_id = ?;",
            ] {
                try connection.withStatement(sql) { statement in
                    statement.bind(traceID)
                    try statement.run()
                }
            }
        }
    }

    static func rebuild(on connection: SQLiteConnection) throws {
        try connection.execute("DELETE FROM trace_index;")
        try connection.execute("DELETE FROM trace_models;")
        try connection.execute(
            """
            INSERT INTO trace_index (
                trace_id, session_id, started_at, last_event_at, event_count, last_seq
            )
            SELECT trace_id, MAX(session_id), MIN(ts), MAX(ts), COUNT(*), MAX(seq)
            FROM trace_events
            GROUP BY trace_id;
            """
        )
        try connection.execute(
            """
            INSERT OR IGNORE INTO trace_models (trace_id, model_id)
            SELECT DISTINCT trace_id, model_id FROM trace_events
            WHERE model_id IS NOT NULL;
            """
        )
    }

    private static func modelIDs(
        forTrace traceID: String,
        on connection: SQLiteConnection
    ) throws -> [String] {
        try connection.withStatement(
            "SELECT model_id FROM trace_models WHERE trace_id = ? ORDER BY model_id;"
        ) { statement in
            statement.bind(traceID)
            return try statement.rows { $0.string(0) }.compactMap { $0 }
        }
    }
}
