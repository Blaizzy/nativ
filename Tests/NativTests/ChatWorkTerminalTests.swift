import AppKit
import Darwin
import SwiftTerm
import XCTest

@MainActor
final class ChatWorkTerminalTests: XCTestCase {
    func testTerminalMetadataRoundTripsWithoutTreatingOutputAsEditableSource() throws {
        var state = ChatWorkState()
        let item = try state.create(title: "Terminal", kind: .terminal)
        state.items[0].content = "<!doctype html><html><body>output</body></html>"
        state.items[0].terminalWorkingDirectory = "/tmp"
        state.items[0].terminalCommand = "pwd"
        let restored = try JSONDecoder().decode(ChatWorkState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored.selectedItem?.resolvedKind, .terminal)
        XCTAssertFalse(try XCTUnwrap(restored.selectedItem).canEdit)
        XCTAssertThrowsError(try state.update(id: item.id, content: "echo should-not-run", expectedRevision: 1, author: "Agent"))
        XCTAssertThrowsError(try state.create(title: "Terminal", kind: .terminal, content: "echo should-not-run"))
        XCTAssertThrowsError(try state.create(title: "Terminal", kind: .terminal, url: "https://example.com"))
    }

    func testInteractiveShellKeepsWorkingDirectoryAndEnvironmentAndStopsOnClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("with spaces")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = ChatWorkItem(title: "Terminal", kind: .terminal, content: "")
        let pool = ChatWorkTerminalPool()
        let chatID = UUID()
        let session = pool.session(for: item, sessionID: chatID, directory: root.path)
        let terminal = try XCTUnwrap(session.view as? LocalProcessTerminalView)
        session.startIfNeeded(arguments: ["-f"])
        defer { session.stop() }
        XCTAssertTrue(session.isRunning)
        let pid = terminal.process.shellPid
        terminal.send(txt: "test -t 0 && printf '\\nPTY_%s\\n' OK\n")
        try await waitUntil("PTY: \(session.text)") { session.text.contains("PTY_OK") }
        terminal.send(txt: "export NATIV_TERMINAL_CHECK=42; cd 'with spaces'\n")
        // A second lookup or view appearance must not recreate the shell.
        XCTAssertTrue(pool.session(for: item, sessionID: chatID, directory: "/") === session)
        session.startIfNeeded(arguments: ["-f"])
        XCTAssertEqual(terminal.process.shellPid, pid)
        terminal.send(txt: "printf '\\nSTATE_%s:%s\\n' \"$NATIV_TERMINAL_CHECK\" \"$PWD\"\n")
        try await waitUntil("Working directory") { session.text.contains("STATE_42:") && session.text.contains("/with spaces") }
        terminal.setFrameSize(NSSize(width: 480, height: 280))
        terminal.send(txt: "printf '\\nSIZE_'; stty size\n")
        let rows = terminal.getTerminal().rows
        let cols = terminal.getTerminal().cols
        try await waitUntil("Resize: \(rows) \(cols)") { session.text.contains("SIZE_\(rows) \(cols)") }
        terminal.send(txt: "sleep 30\n")
        try await waitUntil("Foreground job") { tcgetpgrp(terminal.process.childfd) != pid }
        session.interrupt()
        terminal.send(txt: "printf '\\nINTERRUPT_%s\\n' OK\n")
        try await waitUntil("Interrupt") { session.text.contains("INTERRUPT_OK") }
        pool.remove(itemID: item.id, sessionID: chatID)
        XCTAssertNil(pool.existing(itemID: item.id, sessionID: chatID))
        try await waitUntil("Shell exit") { kill(pid, 0) == -1 && errno == ESRCH }
    }

    func testTerminalPoolsSeparateChatsAndAgentOutputHandlesSplitUTF8() {
        var item = ChatWorkItem(title: "Agent terminal", kind: .terminal, content: "")
        item.terminalCommand = "printf hello"
        let pool = ChatWorkTerminalPool()
        let chatID = UUID()
        let first = pool.session(for: item, sessionID: chatID, directory: "/tmp")
        let second = pool.session(for: item, sessionID: UUID(), directory: "/tmp")
        XCTAssertFalse(first === second)
        first.startIfNeeded()
        XCTAssertFalse(first.isRunning)
        XCTAssertFalse(first.view is LocalProcessTerminalView)
        for byte in "Hello 🌍\nsecond line\n".utf8 { first.appendOutput(Data([byte])) }
        XCTAssertTrue(first.text.contains("Hello 🌍"), first.text)
        XCTAssertTrue(first.text.contains("second line"), first.text)
        XCTAssertFalse(second.text.contains("Hello"))
        first.append("API_KEY=supersecretvalue\n")
        XCTAssertFalse(first.savedText.contains("supersecretvalue"))
    }

    private func waitUntil(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Terminal condition did not become true: \(label)")
        throw CancellationError()
    }
}
