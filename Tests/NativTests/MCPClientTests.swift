import XCTest
@testable import NativServerKit

final class MCPClientTests: XCTestCase {
    func testProcessExitSurfacesStderrStatusAndRedactsSecrets() async {
        let secret = "issue-366-secret"
        let client = makeClient(
            script: "i=0; while [ $i -lt 3000 ]; do echo beginning-$i >&2; i=$((i + 1)); done; echo 'Authorization: Bearer \(secret)' >&2; echo 'Invalid MCP header' >&2; exit 23"
        )
        let start = Date()

        let failure = await connectionFailure(from: client, timeout: 5)

        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(failure.message, "MCP server exited before connecting.")
        XCTAssertEqual(failure.details?.contains("Process exited with status 23."), true)
        XCTAssertEqual(failure.details?.contains("Earlier server output was truncated."), true)
        XCTAssertEqual(failure.details?.contains("beginning-0\n"), false)
        XCTAssertEqual(failure.details?.contains("Invalid MCP header"), true)
        XCTAssertEqual(failure.details?.contains("<redacted>"), true)
        XCTAssertNotEqual(failure.details?.contains(secret), true)
    }

    func testConnectionDeadlineStopsStalledHandshake() async {
        let client = makeClient(script: "while IFS= read -r line; do :; done")
        let start = Date()

        let failure = await connectionFailure(from: client, timeout: 0.2)
        let isConnected = await client.isConnected

        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(failure.message, "MCP server didn’t connect within 1 second.")
        XCTAssertFalse(isConnected)
    }

    private func makeClient(script: String) -> MCPClient {
        MCPClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            environment: [:]
        )
    }

    private func connectionFailure(
        from client: MCPClient,
        timeout: TimeInterval
    ) async -> MCPConnectionFailure {
        do {
            _ = try await client.connectAndListTools(timeout: timeout)
            XCTFail("Expected the MCP connection to fail")
            await client.disconnect()
            return MCPConnectionFailure(message: "Unexpected success")
        } catch let failure as MCPConnectionFailure {
            await client.disconnect()
            return failure
        } catch {
            XCTFail("Expected MCPConnectionFailure, got \(error)")
            await client.disconnect()
            return MCPConnectionFailure(message: error.localizedDescription)
        }
    }
}
