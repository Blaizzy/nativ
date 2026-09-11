import Foundation
import XCTest

final class HuggingFaceDownloadPreflightTests: XCTestCase {
    func testPinsDryRunRevisionAndOnlyRequiresUncachedBytes() throws {
        let result = try run(files: "[(90, False, 'commit-a'), (10, True, 'commit-a')]")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("__NATIV_RESERVE__:10"))
        XCTAssertTrue(result.output.contains("__NATIV_PROGRESS__:90:100"))
        XCTAssertTrue(result.output.contains("resolved=commit-a"))
    }

    func testRefusesTransferWithoutExplicitCapacityApproval() throws {
        for approval in ["", "{}\n", "not-json\n", "{\"error\":\"Insufficient disk space\"}\n"] {
            let result = try run(files: "[(100, True, 'commit-a')]", approval: approval)
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.output.contains("__NATIV_RESERVE__:100"))
            XCTAssertFalse(result.output.contains("__NATIV_PROGRESS__"))
            XCTAssertFalse(result.output.contains("resolved="))
        }
    }

    func testUnknownFileSizeAndMixedRevisionsFailBeforeTransfer() throws {
        for files in ["[(None, True, 'commit-a')]", "[(-1, True, 'commit-a')]", "[(1, True, 'a'), (1, True, 'b')]", "[]"] {
            let result = try run(files: files)
            XCTAssertNotEqual(result.status, 0)
            XCTAssertFalse(result.output.contains("__NATIV_RESERVE__"))
            XCTAssertFalse(result.output.contains("__NATIV_PROGRESS__"))
        }
    }

    private func run(files: String, approval: String = "{\"approved\":true}\n") throws -> (status: Int32, output: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = """
        import os, sys
        from types import SimpleNamespace
        ignored_patterns = ["*.[gG][gG][uU][fF]"]
        def snapshot_download(**kwargs):
            assert kwargs['dry_run'] is True
            assert kwargs['revision'] == 'requested-commit'
            assert kwargs['ignore_patterns'] == ignored_patterns
            return [SimpleNamespace(file_size=s, will_download=d, commit_hash=c) for s,d,c in \(files)]
        \(HuggingFaceDownloadPreflight.script)
        print('resolved=' + revision)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, "org/model", directory.path, "0", "requested-commit"]
        let pipe = Pipe()
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(approval.utf8))
        try input.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
