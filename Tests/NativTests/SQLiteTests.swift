import XCTest

final class SQLiteTests: XCTestCase {
    func testStatementBindingsAndRows() throws {
        let database = try SQLiteConnection(url: databaseURL())
        try database.execute("CREATE TABLE entries (name TEXT, count INTEGER, value REAL, payload BLOB)")
        let payload = Data([1, 2, 3])

        try database.withStatement("INSERT INTO entries VALUES (?, ?, ?, ?)") { statement in
            try statement.bind("entry").bind(Int64(4)).bind(1.5).bind(payload).run()
        }

        let row = try database.withStatement("SELECT name, count, value, payload FROM entries") {
            try XCTUnwrap($0.firstRow { ($0.string(0), $0.int64(1), $0.double(2), $0.data(3)) })
        }
        XCTAssertEqual(row.0, "entry")
        XCTAssertEqual(row.1, 4)
        XCTAssertEqual(row.2, 1.5)
        XCTAssertEqual(row.3, payload)
    }

    func testTransactionRollsBackOnFailure() throws {
        enum ExpectedError: Error { case stop }
        let database = try SQLiteConnection(url: databaseURL())
        try database.execute("CREATE TABLE entries (value TEXT)")

        XCTAssertThrowsError(try database.transaction {
            try database.withStatement("INSERT INTO entries VALUES (?)") { try $0.bind("discard").run() }
            throw ExpectedError.stop
        })

        let count = try database.withStatement("SELECT COUNT(*) FROM entries") { try XCTUnwrap($0.firstRow { $0.int64(0) }) }
        XCTAssertEqual(count, 0)
    }

    func testNestedUseOfCachedStatementFails() throws {
        let database = try SQLiteConnection(url: databaseURL())

        XCTAssertThrowsError(try database.withStatement("SELECT 1") { _ in
            try database.withStatement("SELECT 1") { _ in }
        }) { error in
            guard case .reentrantStatement("SELECT 1") = error as? SQLiteError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    private func databaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite3")
    }
}
