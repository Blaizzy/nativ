import NativServerKit
import XCTest

@MainActor
final class ChatMCPToolBridgeTests: XCTestCase {
    private func makeBridge(exemptTool: String? = nil) -> ChatMCPToolBridge {
        let manager = MCPServerManager()
        manager.configure([
            MCPServerConfiguration(
                name: "filesystem",
                command: "true",
                arguments: [],
                consentExemptTools: exemptTool.map { Set([$0]) } ?? []
            )
        ])
        return ChatMCPToolBridge(manager: manager)
    }

    func testRequiresConsentFalseForNonMCPShapedName() {
        let bridge = makeBridge()
        XCTAssertFalse(bridge.requiresConsent(ChatSystemMonitorToolRegistry.toolName))
        XCTAssertFalse(bridge.requiresConsent("not_a_qualified_name"))
    }

    func testRequiresConsentFailsClosedOnMalformedMCPShapedName() {
        let bridge = makeBridge()
        XCTAssertTrue(bridge.requiresConsent("mcp__onlyoneseg"))
    }

    func testRequiresConsentFailsClosedWhenServerNotFound() {
        let bridge = makeBridge()
        XCTAssertTrue(bridge.requiresConsent(MCPToolNameQualifier.qualify(server: "nonexistent", tool: "read_file")))
    }

    // The consent policy is exempt-by-allowlist, not gated-by-allowlist: a
    // tool on a known server requires consent by default unless explicitly
    // marked exempt. This is the fail-open gap fable-reviewer flagged.
    func testRequiresConsentTrueForToolNotInExemptListOnRealConnection() {
        let bridge = makeBridge()
        XCTAssertTrue(bridge.requiresConsent(MCPToolNameQualifier.qualify(server: "filesystem", tool: "write_file")))
    }

    func testRequiresConsentFalseForExemptToolOnRealConnection() {
        let bridge = makeBridge(exemptTool: "read_file")
        XCTAssertFalse(bridge.requiresConsent(MCPToolNameQualifier.qualify(server: "filesystem", tool: "read_file")))
        XCTAssertTrue(bridge.requiresConsent(MCPToolNameQualifier.qualify(server: "filesystem", tool: "write_file")))
    }

    // Regression test for the real, reachable bug grind-reviewer found: with a
    // non-nil but zero-config MCP bridge (the app's default state), a plain
    // native tool call must never be routed into MCP consent gating.
    func testDetectReturnsNilForNativeToolCallWithMCPBridgePresent() {
        let bridge = ChatMCPToolBridge(manager: MCPServerManager())
        let call = MLXChatToolCall(
            id: "1",
            function: MLXChatFunctionCall(name: ChatSystemMonitorToolRegistry.toolName, arguments: "{}")
        )
        XCTAssertNil(ChatConsentGatedAction.detect(call: call, mcpBridge: bridge))
    }
}
