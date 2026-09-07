import Foundation

/// How much history to keep.
///
/// Both limits apply: whichever removes more wins. Age alone lets a heavy week
/// grow without bound; a count alone lets a trace from last year outlive its
/// usefulness because nothing newer arrived.
public struct TraceRetentionWindow: Sendable, Hashable {
    /// `nil` keeps every trace regardless of age.
    public var days: Int?
    /// `nil` keeps any number of traces.
    public var maximumTraces: Int?

    public static let `default` = TraceRetentionWindow(days: 30, maximumTraces: 500)
    /// Keeps nothing. Named for what it does, because `days: 0` reads like
    /// "no limit" while it means "older than now", i.e. everything.
    public static let clearAll = TraceRetentionWindow(days: 0, maximumTraces: 0)
    public static let unlimited = TraceRetentionWindow(days: nil, maximumTraces: nil)

    public init(days: Int?, maximumTraces: Int?) {
        self.days = days
        self.maximumTraces = maximumTraces
    }

    public func cutoff(from reference: Date) -> Date {
        guard let days else { return .distantPast }
        return reference.addingTimeInterval(-Double(days) * 24 * 60 * 60)
    }
}

/// Drops whole traces. Never trims a trace part-way: half a conversation reads
/// as a bug, and a partial trace cannot be folded into anything trustworthy.
enum TraceRetentionSweep {
    static func doomedTraceIDs(
        _ window: TraceRetentionWindow,
        now: Date,
        on connection: SQLiteConnection
    ) throws -> [String] {
        var doomed: Set<String> = []

        if window.days != nil {
            try connection.withStatement(
                "SELECT trace_id FROM trace_index WHERE last_event_at < ?;"
            ) { statement in
                statement.bind(window.cutoff(from: now))
                doomed.formUnion(try statement.rows { $0.string(0) }.compactMap { $0 })
            }
        }

        if let maximum = window.maximumTraces, maximum >= 0 {
            try connection.withStatement(
                """
                SELECT trace_id FROM trace_index
                ORDER BY last_event_at DESC
                LIMIT -1 OFFSET ?;
                """
            ) { statement in
                statement.bind(Int64(maximum))
                doomed.formUnion(try statement.rows { $0.string(0) }.compactMap { $0 })
            }
        }

        return doomed.sorted()
    }

    static func removeIndexRows(for traceIDs: [String], on connection: SQLiteConnection) throws {
        for traceID in traceIDs {
            try connection.withStatement("DELETE FROM trace_index WHERE trace_id = ?;") { statement in
                statement.bind(traceID)
                try statement.run()
            }
        }
    }
}
