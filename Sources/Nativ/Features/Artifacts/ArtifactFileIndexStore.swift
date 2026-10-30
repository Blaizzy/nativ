import CryptoKit
import Foundation
import SQLite3

final class ArtifactFileIndexStore {
    struct File: Equatable, Sendable {
        let id: String
        let session: String
        let path: String
        let name: String
        let title: String
        let revision: String
        var access: String = ""
    }
    struct Pending: Sendable {
        let file: File
        let stamp: String
        let hash: String
        let force: Bool
    }
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open file index"
            sqlite3_close(db)
            throw NSError(domain: "ArtifactFileIndex", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        do {
            sqlite3_busy_timeout(db, 1_000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            let version = try rows("SELECT value FROM metadata WHERE key='version'").first?.first
            guard version == nil || version == "1" || version == "2" else { throw failure("Unsupported file index version") }
            if version == "1" {
                // Old entries contain resolved paths without their original access boundary.
                // Rebuild instead of retaining potentially out-of-bounds indexed content.
                try transaction {
                    for table in ["files", "file_text", "sessions", "session_jobs", "metadata"] {
                        try execute("DROP TABLE IF EXISTS \(table)")
                    }
                    try execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                }
            }
            try execute("INSERT OR IGNORE INTO metadata VALUES ('version', '2')")
            try execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, stamp TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS session_jobs (id TEXT PRIMARY KEY, retry REAL NOT NULL)")
            try execute("""
                CREATE TABLE IF NOT EXISTS files (
                  id TEXT UNIQUE NOT NULL, session TEXT NOT NULL, path TEXT NOT NULL, name TEXT NOT NULL,
                  title TEXT NOT NULL, revision TEXT NOT NULL, access TEXT NOT NULL, stamp TEXT NOT NULL DEFAULT '',
                  hash TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '', pending INTEGER NOT NULL DEFAULT 1,
                  force INTEGER NOT NULL DEFAULT 1, retry REAL NOT NULL DEFAULT 0, available INTEGER NOT NULL DEFAULT 1)
                """)
            try execute("CREATE INDEX IF NOT EXISTS files_session ON files(session)")
            try execute("CREATE INDEX IF NOT EXISTS files_pending ON files(pending, retry)")
            try execute("CREATE INDEX IF NOT EXISTS files_path ON files(path)")
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS file_text USING fts5(name, title, body, content='files', content_rowid='rowid')")
            try execute("""
                CREATE TRIGGER IF NOT EXISTS files_insert AFTER INSERT ON files BEGIN
                  INSERT INTO file_text(rowid,name,title,body) VALUES(new.rowid,new.name,new.title,new.body); END
                """)
            try execute("""
                CREATE TRIGGER IF NOT EXISTS files_delete AFTER DELETE ON files BEGIN
                  INSERT INTO file_text(file_text,rowid,name,title,body) VALUES('delete',old.rowid,old.name,old.title,old.body); END
                """)
            try execute("""
                CREATE TRIGGER IF NOT EXISTS files_update AFTER UPDATE OF name,title,body ON files BEGIN
                  INSERT INTO file_text(file_text,rowid,name,title,body) VALUES('delete',old.rowid,old.name,old.title,old.body);
                  INSERT INTO file_text(rowid,name,title,body) VALUES(new.rowid,new.name,new.title,new.body); END
                """)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }

    func sessionStamp(_ id: String) throws -> String? {
        try rows("SELECT stamp FROM sessions WHERE id=?", [id]).first?.first
    }

    func synchronize(session: String, stamp: String, files: [File]) throws {
        try transaction {
            let live = Set(files.map(\.id))
            for row in try rows("SELECT id FROM files WHERE session=?", [session]) where !live.contains(row[0]) {
                try execute("DELETE FROM files WHERE id=?", [row[0]])
            }
            for file in files {
                let old = try rows("SELECT path,name,title,revision,access FROM files WHERE id=?", [file.id]).first
                let values = [file.path, file.name, file.title, file.revision, file.access]
                guard old != values else { continue }
                if let old {
                    try execute("UPDATE files SET path=?,name=?,title=?,revision=?,access=?,pending=1,force=MAX(force,CAST(? AS INTEGER)),retry=0 WHERE id=?",
                                values + [old[0] != file.path || old[3] != file.revision || old[4] != file.access ? "1" : "0", file.id])
                } else {
                    try execute("INSERT INTO files(id,session,path,name,title,revision,access) VALUES(?,?,?,?,?,?,?)",
                                [file.id, file.session] + values)
                }
            }
            try execute("INSERT INTO sessions VALUES(?,?) ON CONFLICT(id) DO UPDATE SET stamp=excluded.stamp", [session, stamp])
            try execute("DELETE FROM session_jobs WHERE id=?", [session])
        }
    }

    func removeSession(_ id: String) throws {
        try transaction {
            try execute("DELETE FROM files WHERE session=?", [id])
            try execute("DELETE FROM sessions WHERE id=?", [id])
            try execute("DELETE FROM session_jobs WHERE id=?", [id])
        }
    }
    func sessionIDs() throws -> [String] { try rows("SELECT id FROM sessions UNION SELECT id FROM session_jobs").map { $0[0] } }
    func paths() throws -> [(String, String, String, String)] {
        try rows("SELECT id,path,stamp,access FROM files").map { ($0[0], $0[1], $0[2], $0[3]) }
    }
    func markPending(id: String, force: Bool = false) throws {
        try execute("UPDATE files SET pending=1,force=MAX(force,CAST(? AS INTEGER)),retry=0 WHERE id=?", [force ? "1" : "0", id])
    }
    func markPath(_ path: String) throws {
        try execute("UPDATE files SET pending=1,retry=0 WHERE path=?", [path])
    }
    func pending() throws -> Pending? {
        guard let row = try rows("SELECT id,session,path,name,title,revision,stamp,hash,force,access FROM files WHERE pending=1 AND retry<=? LIMIT 1",
                                 [String(Date.now.timeIntervalSince1970)]).first else { return nil }
        return Pending(file: File(id: row[0], session: row[1], path: row[2], name: row[3], title: row[4], revision: row[5], access: row[9]),
                       stamp: row[6], hash: row[7], force: row[8] == "1")
    }
    func deferSession(_ id: String) throws {
        try execute("INSERT OR REPLACE INTO session_jobs VALUES(?,?)", [id, String(Date.now.addingTimeInterval(60).timeIntervalSince1970)])
    }
    func pendingSessions() throws -> [String] {
        try rows("SELECT id FROM session_jobs WHERE retry<=?", [String(Date.now.timeIntervalSince1970)]).map { $0[0] }
    }
    func hasPending() throws -> Bool {
        try !rows("SELECT id FROM files WHERE pending=1 UNION ALL SELECT id FROM session_jobs LIMIT 1").isEmpty
    }
    func deferFile(_ id: String) throws {
        try execute("UPDATE files SET available=0,body='',hash='',stamp='',force=1,retry=? WHERE id=?", [String(Date.now.addingTimeInterval(60).timeIntervalSince1970), id])
    }
    func finish(_ id: String, stamp: String, hash: String, body: String?) throws {
        try transaction {
            if let body { try execute("UPDATE files SET body=? WHERE id=?", [body, id]) }
            try execute("UPDATE files SET stamp=?,hash=?,pending=0,force=0,retry=0,available=1 WHERE id=?", [stamp, hash, id])
        }
    }
    func markBackfillComplete() throws {
        guard try !hasPending() else { return }
        try execute("INSERT OR IGNORE INTO metadata VALUES('backfill_complete','1')")
    }
    func search(_ query: String) throws -> [String] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        let expression = words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
        return try rows("SELECT files.id FROM file_text JOIN files ON files.rowid=file_text.rowid WHERE file_text MATCH ? AND files.available=1 ORDER BY rank",
                        [expression]).map { $0[0] }
    }
    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try work(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func execute(_ sql: String, _ values: [String] = []) throws { _ = try rows(sql, values) }
    private func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw failure() }
        }
        var result: [[String]] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw failure() }
        return result
    }
    private func failure(_ message: String? = nil) -> NSError {
        NSError(domain: "ArtifactFileIndex", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: message ?? String(cString: sqlite3_errmsg(db))])
    }
}

struct ArtifactFileManifest: Sendable {
    static let changed = Notification.Name("NativArtifactFilesChanged")
    let root: URL
    let sessionID: UUID
    let stamp: String
    let files: [ArtifactFileIndexStore.File]

    static func artifactID(session: UUID, item: UUID) -> UUID {
        let d = Array(SHA256.hash(data: Data("work:\(session):\(item)".utf8)))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
                           d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }

    init(root: URL, session: ChatSession, stamp: String) {
        self.init(root: root, id: session.id, title: session.displayTitle, state: session.workState,
                  worktree: session.worktree, inWorktree: session.workFilesInWorktree == true, stamp: stamp)
    }

    private init(root: URL, id: UUID, title: String, state: ChatWorkState?,
                 worktree: ChatGitWorktree?, inWorktree: Bool, stamp: String) {
        self.root = ChatWorkFileStore.canonicalRoot(root)
        sessionID = id
        self.stamp = stamp
        let directory: URL
        if inWorktree, let worktree { directory = URL(fileURLWithPath: worktree.projectPath).appending(path: "Nativ Files") }
        else { directory = self.root.appending(path: "Files/\(id.uuidString)") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let accessRoot = inWorktree ? directory : self.root.appending(path: "Files")
        files = (state?.items ?? []).filter(\.canEdit).map { item in
            let name = item.storedFilename
            let url = directory.appending(path: item.id.uuidString).appendingPathComponent(name)
            let access = ChatWorkFileAccess(url: url, root: accessRoot,
                                           worktree: inWorktree ? worktree : nil)
            return .init(id: Self.artifactID(session: id, item: item.id).uuidString,
                         session: id.uuidString, path: url.path,
                         name: name, title: title, revision: String(item.revision),
                         access: (try? encoder.encode(access)).flatMap { String(data: $0, encoding: .utf8) } ?? "")
        }
    }

    static func load(_ url: URL, root: URL, stamp: String) throws -> Self {
        struct Projection: Decodable {
            let id: UUID
            let title: String
            let customTitle: String?
            let workState: ChatWorkState?
            let worktree: ChatGitWorktree?
            let workFilesInWorktree: Bool?
        }
        let snapshot = try JSONDecoder().decode(Projection.self, from: Data(contentsOf: url, options: .mappedIfSafe))
        return Self(root: root, id: snapshot.id, title: snapshot.customTitle ?? snapshot.title,
                    state: snapshot.workState, worktree: snapshot.worktree,
                    inWorktree: snapshot.workFilesInWorktree == true, stamp: stamp)
    }
}
