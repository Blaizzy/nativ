import Foundation

enum TraceSchema {
    /// Tables created on a fresh database.
    ///
    /// `trace_events` is the source of truth and is append-only: no code in
    /// this framework may `UPDATE` or `DELETE` a row except the retention
    /// sweep, which drops whole traces. `trace_index` and `trace_models` are
    /// derived and rebuildable — never treat them as authoritative.
    ///
    /// Every statement is `CREATE ... IF NOT EXISTS`, so a build that needs to
    /// change an existing table introduces a versioned migration registry
    /// together with its first migration. Shipping the registry ahead of any
    /// migration to run through it only invites drift between the two.
    static let baseSQL = """
        CREATE TABLE IF NOT EXISTS trace_events (
            trace_id         TEXT    NOT NULL,
            seq              INTEGER NOT NULL,
            ts               REAL    NOT NULL,
            kind             TEXT    NOT NULL,
            format_version   INTEGER NOT NULL,
            session_id       TEXT,
            turn_id          TEXT,
            request_id       TEXT,
            round_index      INTEGER,
            model_id         TEXT,
            payload          BLOB    NOT NULL,
            payload_encoding TEXT    NOT NULL,
            payload_bytes    INTEGER NOT NULL,
            PRIMARY KEY (trace_id, seq)
        );

        CREATE INDEX IF NOT EXISTS idx_trace_events_ts
            ON trace_events (ts);
        CREATE INDEX IF NOT EXISTS idx_trace_events_session
            ON trace_events (session_id, ts);
        CREATE INDEX IF NOT EXISTS idx_trace_events_request
            ON trace_events (request_id);

        CREATE TABLE IF NOT EXISTS trace_index (
            trace_id      TEXT PRIMARY KEY,
            session_id    TEXT,
            started_at    REAL    NOT NULL,
            last_event_at REAL    NOT NULL,
            event_count   INTEGER NOT NULL,
            last_seq      INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_trace_index_last_event
            ON trace_index (last_event_at DESC);

        -- Models seen in a trace. A child table rather than a column so
        -- recording one is an INSERT OR IGNORE instead of a read, a union, and
        -- a write back on every append.
        CREATE TABLE IF NOT EXISTS trace_models (
            trace_id TEXT NOT NULL,
            model_id TEXT NOT NULL,
            PRIMARY KEY (trace_id, model_id)
        );
        """

    static func open(_ connection: SQLiteConnection) throws {
        try connection.execute(baseSQL)
    }
}
