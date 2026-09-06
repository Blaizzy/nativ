import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(sql: String, message: String)
    case step(String)
    case execute(String)
    case reentrantStatement(String)

    public var description: String {
        switch self {
        case .open(let message):
            "SQLite open failed: \(message)"
        case .prepare(let sql, let message):
            "SQLite prepare failed: \(message) — while preparing: \(sql)"
        case .step(let message):
            "SQLite step failed: \(message)"
        case .execute(let message):
            "SQLite execute failed: \(message)"
        case .reentrantStatement(let sql):
            "SQLite statement used re-entrantly: \(sql)"
        }
    }
}

/// Minimal SQLite wrapper owned by `NativTrace`.
///
/// Deliberately not shared with the analytics store: that one reads a database
/// Python writes, this one read-writes a database only Nativ writes. Coupling
/// them would make either side's locking and migration choices the other's
/// problem.
///
/// Not thread-safe on its own — `TraceStore` is an actor and is the only owner.
final class SQLiteConnection {
    private let handle: OpaquePointer
    private var cache: [String: SQLiteStatement] = [:]

    init(url: URL, readOnly: Bool = false) throws {
        if !readOnly {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        var database: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(url.path, &database, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database
        else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
                ?? "unable to open \(url.lastPathComponent)"
            sqlite3_close(database)
            throw SQLiteError.open(message)
        }
        handle = database

        if !readOnly {
            try execute("PRAGMA journal_mode = WAL;")
            try execute("PRAGMA synchronous = NORMAL;")
        }
        try execute("PRAGMA busy_timeout = 5000;")
    }

    deinit {
        cache.removeAll()
        sqlite3_close(handle)
    }

    var errorMessage: String {
        sqlite3_errmsg(handle).map(String.init(cString:)) ?? "unknown SQLite error"
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.execute(errorMessage)
        }
    }

    /// Runs `body` against a prepared statement, reset and ready.
    ///
    /// Scoped rather than vended because a statement carries cursor state:
    /// handing one out and trusting every caller to reset it is how a stale
    /// binding leaks into the next query. Statements are cached and reused, so
    /// the append path does not re-prepare its insert for every event.
    @discardableResult
    func withStatement<Result>(
        _ sql: String,
        _ body: (SQLiteStatement) throws -> Result
    ) throws -> Result {
        let statement = try cached(sql)
        guard !statement.isInUse else {
            throw SQLiteError.reentrantStatement(sql)
        }
        statement.isInUse = true
        statement.reset()
        defer {
            statement.reset()
            statement.isInUse = false
        }
        return try body(statement)
    }

    /// Runs `work` inside `BEGIN IMMEDIATE`, rolling back on any throw.
    ///
    /// Immediate rather than deferred so the writer takes its lock up front. A
    /// deferred transaction that upgrades mid-way can fail with `SQLITE_BUSY`
    /// after part of the work is already done.
    func transaction<Result>(_ work: () throws -> Result) throws -> Result {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try work()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func cached(_ sql: String) throws -> SQLiteStatement {
        if let existing = cache[sql] { return existing }

        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &raw, nil) == SQLITE_OK, let raw else {
            throw SQLiteError.prepare(sql: sql, message: errorMessage)
        }
        let statement = SQLiteStatement(handle: raw, connection: self)
        cache[sql] = statement
        return statement
    }
}

final class SQLiteStatement {
    private let handle: OpaquePointer
    private unowned let connection: SQLiteConnection
    fileprivate var isInUse = false

    /// Next parameter index for `bind(_:)`, so call sites do not hand-number
    /// placeholders — a numbering mistake binds a value to the wrong column and
    /// still runs.
    private var nextParameter: Int32 = 1

    init(handle: OpaquePointer, connection: SQLiteConnection) {
        self.handle = handle
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        nextParameter = 1
    }

    // MARK: - Binding

    @discardableResult
    func bind(_ value: String?) -> SQLiteStatement {
        defer { nextParameter += 1 }
        if let value {
            sqlite3_bind_text(handle, nextParameter, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(handle, nextParameter)
        }
        return self
    }

    @discardableResult
    func bind(_ value: Int64?) -> SQLiteStatement {
        defer { nextParameter += 1 }
        if let value {
            sqlite3_bind_int64(handle, nextParameter, value)
        } else {
            sqlite3_bind_null(handle, nextParameter)
        }
        return self
    }

    @discardableResult
    func bind(_ value: Int?) -> SQLiteStatement {
        bind(value.map(Int64.init))
    }

    @discardableResult
    func bind(_ value: Double?) -> SQLiteStatement {
        defer { nextParameter += 1 }
        if let value {
            sqlite3_bind_double(handle, nextParameter, value)
        } else {
            sqlite3_bind_null(handle, nextParameter)
        }
        return self
    }

    @discardableResult
    func bind(_ value: Date) -> SQLiteStatement {
        bind(value.timeIntervalSince1970)
    }

    @discardableResult
    func bind(_ value: Data) -> SQLiteStatement {
        defer { nextParameter += 1 }
        let index = nextParameter
        value.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
        }
        return self
    }

    // MARK: - Stepping

    /// Advances the cursor. `true` means a row is available.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: true
        case SQLITE_DONE: false
        default: throw SQLiteError.step(connection.errorMessage)
        }
    }

    func run() throws {
        _ = try step()
    }

    /// Steps to completion, collecting one value per row.
    func rows<Row>(_ transform: (SQLiteStatement) -> Row) throws -> [Row] {
        var rows: [Row] = []
        while try step() {
            rows.append(transform(self))
        }
        return rows
    }

    /// Steps once and reads a single value, or `nil` when there is no row.
    func firstRow<Row>(_ transform: (SQLiteStatement) -> Row) throws -> Row? {
        try step() ? transform(self) : nil
    }

    // MARK: - Reading

    func string(_ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: raw)
    }

    func int64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    func int(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(handle, index))
    }

    func double(_ index: Int32) -> Double {
        sqlite3_column_double(handle, index)
    }

    func date(_ index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(handle, index))
    }

    func data(_ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(handle, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, index)))
    }

    func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(handle, index) == SQLITE_NULL
    }

    func optionalInt(_ index: Int32) -> Int? {
        isNull(index) ? nil : int(index)
    }
}
