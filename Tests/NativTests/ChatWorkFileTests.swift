import XCTest

final class ChatWorkFileTests: XCTestCase {
    private func fixture() throws -> ChatWorkFileStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ChatWorkFileStore(root: root.appendingPathComponent("Files"))
    }

    func testFilesHaveReadableNamesAndAreIsolatedByItemAndChat() throws {
        let files = try fixture()
        let sessionID = UUID()
        var state = ChatWorkState()
        let first = try state.create(title: "Notes", kind: .document, content: "# One")
        let second = try state.create(title: "Notes", kind: .document, content: "# Two")
        let code = try state.create(title: "main", kind: .code, content: "print(1)", language: "python")
        let html = try state.create(title: "Game", kind: .document, content: "<!DOCTYPE html><html><body>Play</body></html>")
        let remote = try state.create(title: "Web", kind: .website, url: "https://example.com")
        let terminal = try state.create(title: "Terminal", kind: .terminal)
        try files.save(state, previous: nil, sessionID: sessionID)
        for (item, name) in [(first, "Notes.md"), (second, "Notes.md"), (code, "main.py"), (html, "Game.html")] {
            let url = try XCTUnwrap(files.fileURL(for: item, sessionID: sessionID))
            XCTAssertEqual(url.lastPathComponent, name)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), item.content)
        }
        XCTAssertNotEqual(files.fileURL(for: first, sessionID: sessionID), files.fileURL(for: second, sessionID: sessionID))
        XCTAssertNotEqual(files.fileURL(for: first, sessionID: sessionID), files.fileURL(for: first, sessionID: UUID()))
        XCTAssertNil(files.fileURL(for: remote, sessionID: sessionID))
        XCTAssertNil(files.fileURL(for: terminal, sessionID: sessionID))
    }

    func testLegacyMaterializationRenameAndClosedTabsKeepTheSameItem() throws {
        let files = try fixture()
        let sessionID = UUID()
        var state = ChatWorkState()
        let item = try state.create(title: "Notes.md", kind: .document, content: "# Original")
        let original = state
        // Older sessions have JSON content but no source files yet.
        try files.save(state, previous: state, sessionID: sessionID)
        XCTAssertEqual(try files.refreshed(state, sessionID: sessionID), original)
        let oldURL = try XCTUnwrap(files.fileURL(for: item, sessionID: sessionID))
        let renamed = try state.update(id: item.id, content: "# Edited", expectedRevision: 1, title: "Renamed.md", author: "Agent")
        state.close(item.id)
        try files.save(state, previous: original, sessionID: sessionID)
        files.removeRenamedFiles(previous: original, current: state, sessionID: sessionID)
        let url = try XCTUnwrap(files.fileURL(for: renamed, sessionID: sessionID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Edited")
        XCTAssertEqual(try files.refreshed(state, sessionID: sessionID).items.first?.id, item.id)
        XCTAssertTrue(state.openIDs.isEmpty)
    }

    func testExternalEditsSurviveChatSavesAndRejectConflictingWrites() throws {
        let files = try fixture()
        let sessionID = UUID()
        var state = ChatWorkState()
        let item = try state.create(title: "Notes.md", kind: .document, content: "Original")
        try files.save(state, previous: nil, sessionID: sessionID)
        let url = try XCTUnwrap(files.fileURL(for: item, sessionID: sessionID))
        try "From editor".write(to: url, atomically: true, encoding: .utf8)
        try files.save(state, previous: state, sessionID: sessionID)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "From editor")
        var conflicting = state
        try conflicting.update(id: item.id, content: "Stale agent write", expectedRevision: 1, author: "Agent")
        XCTAssertThrowsError(try files.save(conflicting, previous: state, sessionID: sessionID))
        let refreshed = try files.refreshed(state, sessionID: sessionID)
        XCTAssertEqual(refreshed.selectedItem?.id, item.id)
        XCTAssertEqual(refreshed.selectedItem?.content, "From editor")
        XCTAssertEqual(refreshed.selectedItem?.revision, 2)
        XCTAssertEqual(refreshed.selectedItem?.updatedBy, "File")
        try files.save(refreshed, previous: state, sessionID: sessionID)
        XCTAssertEqual(try files.refreshed(refreshed, sessionID: sessionID), refreshed)
    }

    func testFilenamesStayInsideTheirItemDirectory() throws {
        let files = try fixture()
        let sessionID = UUID()
        for title in ["../../outside.md", "a/b:c\\d\n.md", String(repeating: "🗂", count: 150) + ".md"] {
            var state = ChatWorkState()
            let item = try state.create(title: title, kind: .document, content: "Safe")
            let url = try XCTUnwrap(files.fileURL(for: item, sessionID: sessionID))
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, item.id.uuidString)
            XCTAssertLessThanOrEqual(url.lastPathComponent.utf8.count, 240)
            try files.save(state, previous: nil, sessionID: sessionID)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), item.content)
        }
    }

    func testLinksAndInvalidExternalFilesAreNotImportedOrOverwritten() throws {
        let files = try fixture()
        let sessionID = UUID()
        var state = ChatWorkState()
        let item = try state.create(title: "Notes.md", kind: .document, content: "Original")
        try files.save(state, previous: nil, sessionID: sessionID)
        let url = try XCTUnwrap(files.fileURL(for: item, sessionID: sessionID))
        for data in [Data([0xFF, 0xFE]), Data(repeating: 65, count: ChatWorkState.maximumContentBytes + 1)] {
            try data.write(to: url)
            XCTAssertThrowsError(try files.refreshed(state, sessionID: sessionID))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
        let outside = files.root.deletingLastPathComponent().appendingPathComponent("Outside.md")
        try "Do not touch".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        XCTAssertThrowsError(try files.save(state, previous: state, sessionID: sessionID))
        XCTAssertThrowsError(try files.refreshed(state, sessionID: sessionID))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "Do not touch")
    }
}
