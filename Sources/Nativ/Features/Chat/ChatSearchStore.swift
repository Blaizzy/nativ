import Foundation
import SQLite3

final class ChatSearchStore {
    struct Session: Codable, Equatable, Sendable {
        let id: UUID
        let title: String
        let updatedAt: Date

        init(_ summary: ChatSessionSummary) {
            id = summary.id
            title = summary.title
            updatedAt = summary.updatedAt
        }
    }

    struct Failure: Error {
        let code: Int32
        let message: String
    }

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Nativ/Chat/Search.sqlite")
    }

    private var database: OpaquePointer?
    private let encoder: PropertyListEncoder = {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }()
    private let decoder = PropertyListDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let code = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else {
            let error = failure(code)
            sqlite3_close(database)
            database = nil
            throw error
        }
        do {
            try configure()
        } catch let error as Failure where error.code == SQLITE_CORRUPT || error.code == SQLITE_NOTADB {
            sqlite3_close(database)
            database = nil
            for suffix in ["", "-wal", "-shm"] {
                let path = url.path + suffix
                if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            }
            let code = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
            guard code == SQLITE_OK else {
                let error = failure(code)
                sqlite3_close(database)
                database = nil
                throw error
            }
            do { try configure() }
            catch {
                sqlite3_close(database)
                database = nil
                throw error
            }
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    private func configure() throws {
        sqlite3_busy_timeout(database, 2_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA secure_delete=ON")
        try execute("CREATE TABLE IF NOT EXISTS metadata (version TEXT NOT NULL)")
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let version = "1:\(system.majorVersion).\(system.minorVersion)"
        var storedVersion: String?
        try rows("SELECT version FROM metadata") { statement in
            if let text = sqlite3_column_text(statement, 0) { storedVersion = String(cString: text) }
        }
        if storedVersion != version {
            try transaction {
                try execute("DROP TABLE IF EXISTS messages")
                try execute("DROP TABLE IF EXISTS sessions")
                try execute("DELETE FROM metadata")
                try execute("INSERT INTO metadata VALUES (?)", strings: [version])
            }
        }
        try execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS messages (session_id TEXT NOT NULL, message_id TEXT NOT NULL, position INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY (session_id, message_id))")
    }

    func restore(into index: inout ChatSearchIndex) throws -> [UUID: Session] {
        var sessions: [UUID: Session] = [:]
        do {
            try rows("SELECT payload FROM sessions") { statement in
                let session = try decoder.decode(Session.self, from: data(statement, column: 0))
                sessions[session.id] = session
            }
            try rows("SELECT position, payload FROM messages") { statement in
                try Task.checkCancellation()
                let record = try decoder.decode(ChatSearchIndex.Record.self, from: data(statement, column: 1))
                index.insert(record, position: Int(sqlite3_column_int64(statement, 0)))
            }
        } catch is DecodingError {
            try transaction {
                try execute("DELETE FROM messages")
                try execute("DELETE FROM sessions")
            }
            index = ChatSearchIndex()
            return [:]
        }
        return sessions
    }

    func save(_ index: ChatSearchIndex, sessions: [Session] = [], removedSessions: Set<UUID> = []) throws {
        let changes = index.changes
        guard !changes.updated.isEmpty || !changes.removed.isEmpty || !changes.moved.isEmpty
                || !sessions.isEmpty || !removedSessions.isEmpty else { return }
        try transaction {
            for id in removedSessions {
                try execute("DELETE FROM messages WHERE session_id = ?", strings: [id.uuidString])
                try execute("DELETE FROM sessions WHERE id = ?", strings: [id.uuidString])
            }
            for session in sessions {
                try execute("INSERT OR REPLACE INTO sessions VALUES (?, ?)", strings: [session.id.uuidString],
                            payload: encoder.encode(session))
            }
            for key in changes.removed {
                try execute("DELETE FROM messages WHERE session_id = ? AND message_id = ?", strings: identifiers(key))
            }
            for key in changes.updated {
                guard let entry = index.entries[key], let record = index.record(for: key) else { continue }
                try execute("INSERT OR REPLACE INTO messages VALUES (?, ?, ?, ?)", strings: identifiers(key),
                            position: entry.position, payload: encoder.encode(record))
            }
            for key in changes.moved.subtracting(changes.updated) {
                guard let entry = index.entries[key] else { continue }
                try execute("UPDATE messages SET position = ? WHERE session_id = ? AND message_id = ?",
                            strings: identifiers(key), position: entry.position, positionFirst: true)
            }
        }
    }

    func checkpoint() throws { try execute("PRAGMA wal_checkpoint(TRUNCATE)") }

    private func identifiers(_ key: ChatSearchIndex.Key) -> [String] {
        [key.sessionID?.uuidString ?? "", key.messageID.uuidString]
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, strings: [String] = [], position: Int? = nil,
                         payload: Data? = nil, positionFirst: Bool = false) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var parameter: Int32 = 1
        if positionFirst, let position {
            try check(sqlite3_bind_int64(statement, parameter, sqlite3_int64(position)))
            parameter += 1
        }
        for string in strings {
            try check(sqlite3_bind_text(statement, parameter, string, -1, transient))
            parameter += 1
        }
        if !positionFirst, let position {
            try check(sqlite3_bind_int64(statement, parameter, sqlite3_int64(position)))
            parameter += 1
        }
        if let payload {
            try payload.withUnsafeBytes { bytes in
                try check(sqlite3_bind_blob(statement, parameter, bytes.baseAddress, Int32(bytes.count), transient))
            }
        }
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW { code = sqlite3_step(statement) }
        guard code == SQLITE_DONE else { throw failure(code) }
    }

    private func rows(_ sql: String, read: (OpaquePointer) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            try read(statement)
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw failure(code) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw failure(code) }
        return statement
    }

    private func data(_ statement: OpaquePointer, column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else { throw failure(code) }
    }

    private func failure(_ code: Int32) -> Failure {
        Failure(code: code, message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open search cache")
    }
}
