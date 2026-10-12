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

    func testQuitStopsAgentChildrenAndInteractiveJobsAcrossPools() async throws {
        let center = NotificationCenter()
        let firstPool = ChatWorkTerminalPool(notificationCenter: center)
        let secondPool = ChatWorkTerminalPool(notificationCenter: center)
        let directory = FileManager.default.temporaryDirectory
        let pidFile = directory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        var item = ChatWorkItem(title: "Agent terminal", kind: .terminal, content: "")
        item.terminalCommand = "sleep 60"
        let agent = firstPool.session(for: item, sessionID: UUID(), directory: directory.path)
        agent.beginCommand(item.terminalCommand!, directory: directory.path)
        let command = Task {
            try await TerminalProcessRunner().run(.init(
                command: "sleep 60 & child=$!; printf '%s' $child > '\(pidFile.path)'; wait $child",
                currentDirectoryURL: directory, timeout: 1, environment: ["PATH": "/usr/bin:/bin"], background: true))
        }
        agent.onStop = { command.cancel() }
        defer { agent.stop() }
        try await waitUntil("Agent child started") { FileManager.default.fileExists(atPath: pidFile.path) }
        let child = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))

        let shell = secondPool.session(for: .init(title: "Terminal", kind: .terminal, content: ""),
                                       sessionID: UUID(), directory: directory.path)
        defer { shell.stop() }
        shell.startIfNeeded(arguments: ["-f"])
        let view = try XCTUnwrap(shell.view as? LocalProcessTerminalView)
        let shellPID = view.process.shellPid
        // This job ignores polite shutdown signals, exercising the Quit escalation.
        view.send(txt: "trap '' HUP TERM; sleep 60\n")
        try await waitUntil("Interactive job started") {
            let foreground = tcgetpgrp(view.process.childfd)
            return foreground > 0 && foreground != shellPID
        }
        let foreground = tcgetpgrp(view.process.childfd)
        let start = Date()
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertNil(agent.onStop, "The quit notification must run cleanup synchronously")
        XCTAssertEqual(kill(shellPID, 0), -1, "Quit must reap the interactive shell before returning")
        do { _ = try await command.value; XCTFail("Quit must cancel the managed command") }
        catch is CancellationError {}
        try await waitUntil("All child processes exited") { kill(child, 0) == -1 && kill(foreground, 0) == -1 }
    }

    func testQuitCancelsAQueuedCommandBeforeItCanLaunch() async throws {
        let center = NotificationCenter()
        let pool = ChatWorkTerminalPool(notificationCenter: center)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var item = ChatWorkItem(title: "Agent terminal", kind: .terminal, content: "")
        item.terminalCommand = "touch"
        let terminal = pool.session(for: item, sessionID: UUID(), directory: file.deletingLastPathComponent().path)
        let command = Task {
            try await TerminalProcessRunner().run(.init(command: "touch '\(file.path)'",
                currentDirectoryURL: file.deletingLastPathComponent(), timeout: 5, environment: ["PATH": "/usr/bin:/bin"]))
        }
        terminal.onStop = { command.cancel() }
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        do { _ = try await command.value; XCTFail("A queued command must not launch during Quit") }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
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
