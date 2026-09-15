import Foundation

enum TraceSchema {
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

        DROP TABLE IF EXISTS trace_index;
        DROP TABLE IF EXISTS trace_models;
        """

    static func open(_ connection: SQLiteConnection) throws {
        try connection.execute(baseSQL)
    }
}

