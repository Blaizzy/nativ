import XCTest
@testable import NativServerKit

/// Covers the one thing that makes quitting Nativ actually stop its MCP
/// servers: terminating the child process without waiting on the actor.
///
/// These run real subprocesses rather than mocking the transport, because the
/// bug being guarded against is precisely that the process outlives the app —
/// a mocked client cannot fail that way.
final class MCPClientTerminationTests: XCTestCase {
    private var fixturePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/idle_mcp_server.py")
            .path
    }

    /// Starts a fixture server and returns its client plus the pid of the real
    /// process behind it.
    private func startFixtureServer() async throws -> (client: MCPClient, pid: pid_t) {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-fixture-\(UUID().uuidString).pid")
        let client = MCPClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", fixturePath, pidFile.path],
            environment: ProcessInfo.processInfo.environment
        )
        try await client.connect()
        addTeardownBlock {
            await client.disconnect()
            try? FileManager.default.removeItem(at: pidFile)
        }

        let raw = try XCTUnwrap(
            try? String(contentsOf: pidFile, encoding: .utf8),
            "fixture never wrote its pid, so it never started"
        )
        let pid = try XCTUnwrap(pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(isRunning(pid), "fixture should be alive right after connecting")
        return (client, pid)
    }

    /// Whether the OS still has a live process under this pid.
    ///
    /// Foundation reaps its own children, so a terminated fixture stops
    /// answering `kill(_:0)` shortly after it dies; polling absorbs that gap
    /// without making the test depend on exact timing.
    private func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func waitUntilNotRunning(_ pid: pid_t, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning(pid) { return true }
            usleep(20_000)
        }
        return !isRunning(pid)
    }

    func testTerminateImmediatelyStopsTheServerProcess() async throws {
        let (client, pid) = try await startFixtureServer()

        // Deliberately synchronous, with nothing awaited afterwards — this is
        // the call app termination makes, and it has to be enough on its own.
        // Awaiting disconnect() here would prove nothing about the quit path.
        client.terminateImmediately()

        XCTAssertTrue(
            waitUntilNotRunning(pid),
            "the server process outlived terminateImmediately(), which is the exact bug this guards"
        )
    }

    func testDisconnectAlsoStopsTheServerProcess() async throws {
        let (client, pid) = try await startFixtureServer()

        await client.disconnect()

        XCTAssertTrue(
            waitUntilNotRunning(pid),
            "the graceful path should stop the process too"
        )
    }

    func testTerminateImmediatelyIsSafeToCallTwice() async throws {
        let (client, pid) = try await startFixtureServer()

        client.terminateImmediately()
        client.terminateImmediately()

        XCTAssertTrue(waitUntilNotRunning(pid))
    }

    func testTerminateImmediatelyOnAClientThatNeverConnectedDoesNothing() {
        let client = MCPClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            environment: [:]
        )

        // No process was ever started; this must not trap.
        client.terminateImmediately()
    }
}

/// The manager-level path: what `applicationWillTerminate` actually calls.
@MainActor
final class MCPHostManagerShutdownTests: XCTestCase {
    private var fixturePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/idle_mcp_server.py")
            .path
    }

    private func fixtureConfig(named name: String, pidFile: URL) -> MCPServerConfig {
        MCPServerConfig(
            name: name,
            command: "/usr/bin/env",
            arguments: ["python3", fixturePath, pidFile.path],
            environment: [:]
        )
    }

    private func pid(from pidFile: URL) throws -> pid_t {
        let raw = try XCTUnwrap(try? String(contentsOf: pidFile, encoding: .utf8))
        return try XCTUnwrap(pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    func testShutdownStopsEveryConnectedServer() async throws {
        let pidFiles = (0..<2).map { index in
            FileManager.default.temporaryDirectory
                .appendingPathComponent("mcp-host-\(index)-\(UUID().uuidString).pid")
        }
        addTeardownBlock {
            pidFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        }

        let manager = MCPHostManager()
        let servers = [
            fixtureConfig(named: "first", pidFile: pidFiles[0]),
            fixtureConfig(named: "second", pidFile: pidFiles[1]),
        ]
        manager.reload(servers: servers)

        // reload() debounces and connects asynchronously, so wait for the
        // states it publishes rather than guessing at a sleep duration.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let connected = servers.allSatisfy { server in
                if case .connected = manager.states[server.id] { return true }
                return false
            }
            if connected { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        for server in servers {
            guard case .connected = manager.states[server.id] else {
                return XCTFail("\(server.name) never connected: \(String(describing: manager.states[server.id]))")
            }
        }

        let pids = try pidFiles.map(pid(from:))
        for pid in pids {
            XCTAssertTrue(isRunning(pid), "fixture \(pid) should be up before shutdown")
        }

        manager.shutdown()

        for pid in pids {
            let stopped = waitUntilNotRunning(pid)
            XCTAssertTrue(stopped, "server \(pid) survived shutdown() — it would outlive the app")
        }
    }

    /// Polls synchronously on purpose, and that is load-bearing.
    ///
    /// The version of `shutdown()` this guards against handed its work to a
    /// `Task` created in a main-actor context. Blocking the main actor here is
    /// what makes this a faithful stand-in for app termination, where the main
    /// actor stops servicing work and the process exits. Awaiting instead would
    /// hand that task a chance to run and the test would pass against the very
    /// bug it exists to catch.
    private func waitUntilNotRunning(_ pid: pid_t, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning(pid) { return true }
            usleep(20_000)
        }
        return !isRunning(pid)
    }
}
