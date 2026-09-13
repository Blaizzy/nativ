import Foundation
import NativSQLite

public struct TraceSummary: Sendable, Hashable, Identifiable {
    public let traceID: String
    public let sessionID: String?
    public let startedAt: Date
    public let lastEventAt: Date
    public let eventCount: Int
    public let lastSeq: Int64
    public let modelIDs: [String]

    public var id: String { traceID }

    public init(
        traceID: String,
        sessionID: String?,
        startedAt: Date,
        lastEventAt: Date,
        eventCount: Int,
        lastSeq: Int64,
        modelIDs: [String]
    ) {
        self.traceID = traceID
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.eventCount = eventCount
        self.lastSeq = lastSeq
        self.modelIDs = modelIDs
    }
}

enum TraceIndex {
    private static let summaryColumns =
        "trace_id, MAX(session_id), MIN(ts), MAX(ts), COUNT(*), MAX(seq)"

    static func summaries(limit: Int, on connection: SQLiteConnection) throws -> [TraceSummary] {
        try read(
            """
            SELECT \(summaryColumns) FROM trace_events
            GROUP BY trace_id
            ORDER BY MAX(ts) DESC
            LIMIT ?;
            """,
            on: connection
        ) { $0.bind(Int64(limit)) }
    }

    static func summaries(
        forSession sessionID: String,
        on connection: SQLiteConnection
    ) throws -> [TraceSummary] {
        try read(
            """
            SELECT \(summaryColumns) FROM trace_events
            WHERE trace_id IN (SELECT trace_id FROM trace_events WHERE session_id = ?)
            GROUP BY trace_id
            ORDER BY MIN(ts) ASC;
            """,
            on: connection
        ) { $0.bind(sessionID) }
    }

    private static func read(
        _ sql: String,
        on connection: SQLiteConnection,
        bind: (SQLiteStatement) -> Void
    ) throws -> [TraceSummary] {
        let partial = try connection.withStatement(sql) { statement in
            bind(statement)
            return try statement.rows {
                (
                    traceID: $0.string(0) ?? "",
                    sessionID: $0.string(1),
                    startedAt: $0.date(2),
                    lastEventAt: $0.date(3),
                    eventCount: $0.int(4),
                    lastSeq: $0.int64(5)
                )
            }
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

    static func doomedTraceIDs(
        _ window: TraceRetentionWindow,
        now: Date,
        on connection: SQLiteConnection
    ) throws -> [String] {
        var doomed: Set<String> = []

        if window.days != nil {
            try connection.withStatement(
                """
                SELECT trace_id FROM trace_events
                GROUP BY trace_id
                HAVING MAX(ts) < ?;
                """
            ) { statement in
                statement.bind(window.cutoff(from: now))
                doomed.formUnion(try statement.rows { $0.string(0) }.compactMap { $0 })
            }
        }

        if let maximum = window.maximumTraces, maximum >= 0 {
            try connection.withStatement(
                """
                SELECT trace_id FROM trace_events
                GROUP BY trace_id
                ORDER BY MAX(ts) DESC
                LIMIT -1 OFFSET ?;
                """
            ) { statement in
                statement.bind(Int64(maximum))
                doomed.formUnion(try statement.rows { $0.string(0) }.compactMap { $0 })
            }
        }

        return doomed.sorted()
    }

    static func remove(traceIDs: [String], on connection: SQLiteConnection) throws {
        for traceID in traceIDs {
            try connection.withStatement("DELETE FROM trace_events WHERE trace_id = ?;") { statement in
                statement.bind(traceID)
                try statement.run()
            }
        }
    }

    private static func modelIDs(
        forTrace traceID: String,
        on connection: SQLiteConnection
    ) throws -> [String] {
        try connection.withStatement(
            """
            SELECT DISTINCT model_id FROM trace_events
            WHERE trace_id = ? AND model_id IS NOT NULL
            ORDER BY model_id;
            """
        ) { statement in
            statement.bind(traceID)
            return try statement.rows { $0.string(0) }.compactMap { $0 }
        }
    }
}
