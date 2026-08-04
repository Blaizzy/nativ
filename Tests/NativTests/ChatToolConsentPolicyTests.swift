import XCTest
@testable import NativServerKit

final class ChatToolConsentRequirementTests: XCTestCase {
    func testNativeToolsRunWithoutAsking() {
        XCTAssertEqual(ChatToolConsentRequirement.resolve(toolName: "get_system_stats"), .notRequired)
        XCTAssertEqual(ChatToolConsentRequirement.resolve(toolName: "list_models"), .notRequired)
        XCTAssertEqual(ChatToolConsentRequirement.resolve(toolName: "generate_image"), .notRequired)
    }

    func testMissingToolNameRequiresNothing() {
        XCTAssertEqual(ChatToolConsentRequirement.resolve(toolName: nil), .notRequired)
    }

    func testSwitchModelStillAsks() {
        XCTAssertEqual(
            ChatToolConsentRequirement.resolve(toolName: ChatSwitchModelToolRegistry.toolName),
            .switchModel
        )
    }

    func testEveryMCPToolAsks() {
        XCTAssertEqual(
            ChatToolConsentRequirement.resolve(toolName: "mcp__filesystem__read_file"),
            .mcpTool(qualifiedName: "mcp__filesystem__read_file")
        )
    }

    func testAnUnroutableServerStillAsks() {
        // Fail-closed: the gate must not depend on whether the host can
        // currently route the name. Connections reload asynchronously, so a
        // name that looks unroutable here can be routable by dispatch time.
        XCTAssertTrue(
            ChatToolConsentRequirement.resolve(toolName: "mcp__never_connected__wipe_disk").isRequired
        )
    }

    func testAMalformedMCPNameStillAsks() {
        // No server, no tool, nothing to identify — still gated rather than
        // waved through for being unrecognizable.
        XCTAssertTrue(ChatToolConsentRequirement.resolve(toolName: "mcp__").isRequired)
        XCTAssertTrue(ChatToolConsentRequirement.resolve(toolName: "mcp__filesystem").isRequired)
    }

    func testTheMCPPrefixMustLeadTheName() {
        // A native tool that merely contains the prefix is not an MCP call,
        // and must not be mistaken for one.
        XCTAssertEqual(ChatToolConsentRequirement.resolve(toolName: "my_mcp__helper"), .notRequired)
        XCTAssertEqual(ChatToolConsentRequirement.resolve(toolName: "run_mcp__tool"), .notRequired)
    }

    func testDeclinedPayloadsAreNeverEmpty() {
        // The model is told something in every declined case; an empty tool
        // result reads as a successful no-op.
        for requirement: ChatToolConsentRequirement in [
            .switchModel,
            .mcpTool(qualifiedName: "mcp__filesystem__read_file"),
        ] {
            XCTAssertFalse(requirement.declinedPayload().isEmpty, "\(requirement)")
        }
    }
}

final class MCPToolDisplayNameTests: XCTestCase {
    func testSplitsServerAndTool() {
        let split = MCPToolDisplayName.split("mcp__filesystem__read_file")
        XCTAssertEqual(split?.server, "filesystem")
        XCTAssertEqual(split?.tool, "read_file")
    }

    func testASlugContainingTheSeparatorKeepsItsFullName() {
        // Slugs are built by replacing each non-alphanumeric with "_", so two
        // adjacent ones produce "__" inside the server name. Splitting on the
        // last separator keeps that intact.
        let split = MCPToolDisplayName.split("mcp__my__server__read_file")
        XCTAssertEqual(split?.server, "my__server")
        XCTAssertEqual(split?.tool, "read_file")
    }

    func testUnexpectedShapesReturnNilRatherThanGuessing() {
        XCTAssertNil(MCPToolDisplayName.split("mcp__filesystem"))
        XCTAssertNil(MCPToolDisplayName.split("mcp__filesystem__"))
        XCTAssertNil(MCPToolDisplayName.split("mcp____read_file"))
        XCTAssertNil(MCPToolDisplayName.split("get_system_stats"))
    }
}
