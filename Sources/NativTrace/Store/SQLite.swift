import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)
    case step(String)
    case execute(String)

    public var description: String {
        switch self {
        case .open(let message): "SQLite open failed: \(message)"
        case .prepare(let message): "SQLite prepare failed: \(message)"
        case .step(let message): "SQLite step failed: \(message)"
        case .execute(let message): "SQLite execute failed: \(message)"
        }
    }
}

/// Minimal SQLite wrapper owned by `NativTrace`.
///
/// Deliberately not shared with the analytics store: that one is a read path
/// for a database Python writes, this one is a read/write path for a database
/// only Nativ writes. Coupling them would make either side's locking and
/// migration choices the other's problem.
///
/// Not thread-safe by itself. `TraceStore` serialises access.
final class SQLiteConnection {
    private let handle: OpaquePointer

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
            try execute("PRAGMA foreign_keys = ON;")
        }
        try execute("PRAGMA busy_timeout = 5000;")
    }

    deinit {
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

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLiteError.prepare("\(errorMessage) — while preparing: \(sql)")
        }
        return SQLiteStatement(handle: statement, connection: self)
    }

    /// Runs `work` inside `BEGIN IMMEDIATE`, rolling back on any throw.
    ///
    /// `IMMEDIATE` rather than deferred: the writer takes its lock up front, so
    /// a concurrent reader can never turn a half-applied append into a
    /// `SQLITE_BUSY` upgrade failure part way through.
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

    var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    var changeCount: Int {
        Int(sqlite3_changes(handle))
    }
}

final class SQLiteStatement {
    private let handle: OpaquePointer
    private unowned let connection: SQLiteConnection

    init(handle: OpaquePointer, connection: SQLiteConnection) {
        self.handle = handle
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(handle)
    }

    @discardableResult
    func bind(_ value: String?, at index: Int32) -> SQLiteStatement {
        if let value {
            sqlite3_bind_text(handle, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(handle, index)
        }
        return self
    }

    @discardableResult
    func bind(_ value: Int64?, at index: Int32) -> SQLiteStatement {
        if let value {
            sqlite3_bind_int64(handle, index, value)
        } else {
            sqlite3_bind_null(handle, index)
        }
        return self
    }

    @discardableResult
    func bind(_ value: Int?, at index: Int32) -> SQLiteStatement {
        bind(value.map(Int64.init), at: index)
    }

    @discardableResult
    func bind(_ value: Double?, at index: Int32) -> SQLiteStatement {
        if let value {
            sqlite3_bind_double(handle, index, value)
        } else {
            sqlite3_bind_null(handle, index)
        }
        return self
    }

    @discardableResult
    func bind(_ value: Data, at index: Int32) -> SQLiteStatement {
        value.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
        }
        return self
    }

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

    /// Rewinds the statement so it can be re-run with fresh bindings.
    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func string(at index: Int32) -> String? {
        guard let raw = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: raw)
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    func int(at index: Int32) -> Int {
        Int(sqlite3_column_int64(handle, index))
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(handle, index)
    }

    func data(at index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(handle, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, index)))
    }

    func isNull(at index: Int32) -> Bool {
        sqlite3_column_type(handle, index) == SQLITE_NULL
    }

    func optionalInt(at index: Int32) -> Int? {
        isNull(at: index) ? nil : int(at: index)
    }
}
