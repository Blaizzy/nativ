import Foundation
import NativSQLite

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

public actor TraceStore {
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
        }

        for event in events {
            nextSequenceByTrace[event.traceID] = max(
                nextSequenceByTrace[event.traceID] ?? 0,
                event.seq + 1
            )
        }
    }

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

    @discardableResult
    public func prune(retaining window: TraceRetentionWindow, now: Date = Date()) throws -> Int {
        try connection.transaction {
            let doomed = try doomedTraceIDs(retaining: window, now: now)
            guard !doomed.isEmpty else { return 0 }

            for traceID in doomed {
                try connection.withStatement("DELETE FROM trace_events WHERE trace_id = ?;") { statement in
                    statement.bind(traceID)
                    try statement.run()
                }
            }
            for traceID in doomed {
                nextSequenceByTrace.removeValue(forKey: traceID)
            }
            return doomed.count
        }
    }

    public func deleteAll() throws {
        try connection.execute("DELETE FROM trace_events;")
        nextSequenceByTrace.removeAll()
    }

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

    private func doomedTraceIDs(
        retaining window: TraceRetentionWindow,
        now: Date
    ) throws -> [String] {
        var traceIDs = Set<String>()
        if window.days != nil {
            try connection.withStatement(
                "SELECT trace_id FROM trace_events GROUP BY trace_id HAVING MAX(ts) < ?;"
            ) { statement in
                statement.bind(window.cutoff(from: now))
                traceIDs.formUnion(try statement.rows { $0.string(0) }.compactMap { $0 })
            }
        }
        if let maximum = window.maximumTraces, maximum >= 0 {
            try connection.withStatement(
                "SELECT trace_id FROM trace_events GROUP BY trace_id ORDER BY MAX(ts) DESC LIMIT -1 OFFSET ?;"
            ) { statement in
                statement.bind(Int64(maximum))
                traceIDs.formUnion(try statement.rows { $0.string(0) }.compactMap { $0 })
            }
        }
        return traceIDs.sorted()
    }
}
