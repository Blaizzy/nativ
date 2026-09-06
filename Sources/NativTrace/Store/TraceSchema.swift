import Foundation

/// One idempotent, named schema change.
///
/// Migrations are append-only: once a name has shipped it is never renamed,
/// reordered, or edited, because a database in the field records that name as
/// applied and will skip it forever.
struct TraceMigration: Sendable {
    let name: String
    let apply: @Sendable (SQLiteConnection) throws -> Void

    init(name: String, sql: String) {
        self.name = name
        self.apply = { try $0.execute(sql) }
    }

    init(name: String, apply: @escaping @Sendable (SQLiteConnection) throws -> Void) {
        self.name = name
        self.apply = apply
    }
}

enum TraceSchema {
    /// Tables created on a fresh database.
    ///
    /// `trace_events` is the source of truth and is append-only: no code in
    /// this framework may `UPDATE` or `DELETE` a row except the retention
    /// sweep, which drops whole traces. `trace_index` is a derived convenience
    /// and is rebuildable from `trace_events` — never treat it as authoritative.
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

        CREATE TABLE IF NOT EXISTS trace_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS trace_migrations (
            name       TEXT PRIMARY KEY,
            applied_at REAL NOT NULL
        );
        """

    /// Append new entries here. Never edit or remove an existing one.
    static let migrations: [TraceMigration] = []

    static func open(_ connection: SQLiteConnection) throws {
        try connection.execute(baseSQL)
        try runMigrations(on: connection)
    }

    private static func runMigrations(on connection: SQLiteConnection) throws {
        let applied = Set(
            try connection.withStatement("SELECT name FROM trace_migrations;") { statement in
                try statement.rows { $0.string(0) }.compactMap { $0 }
            }
        )

        for migration in migrations where !applied.contains(migration.name) {
            try connection.transaction {
                try migration.apply(connection)
                try connection.withStatement(
                    "INSERT OR IGNORE INTO trace_migrations (name, applied_at) VALUES (?, ?);"
                ) { statement in
                    statement.bind(migration.name)
                    statement.bind(Date())
                    try statement.run()
                }
            }
        }
    }
}
