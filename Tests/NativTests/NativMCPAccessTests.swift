import XCTest

final class NativMCPAccessTests: XCTestCase {
    private let fullKey = NativMCPKey(agent: NativMCPAgent(name: "This Mac", scope: .full), secret: "full-secret")
    private let readOnlyKey = NativMCPKey(agent: NativMCPAgent(name: "Cloud agent", scope: .readOnly), secret: "read-secret")

    private func makeAccess() -> NativMCPAccess {
        NativMCPAccess(
            keys: [fullKey, readOnlyKey],
            readOnlyTools: [ChatModelLibraryToolRegistry.toolName]
        )
    }

    func testEachKeyResolvesToItsOwnScope() {
        let access = makeAccess()
        XCTAssertEqual(access.key(forSecret: "full-secret")?.agent.scope, .full)
        XCTAssertEqual(access.key(forSecret: "read-secret")?.agent.scope, .readOnly)
    }

    func testUnknownEmptyAndMissingSecretsAreRejected() {
        let access = makeAccess()
        XCTAssertNil(access.key(forSecret: "not-a-secret"))
        XCTAssertNil(access.key(forSecret: ""))
        XCTAssertNil(access.key(forSecret: nil))
    }

    func testSecretsOfADifferentLengthAreRejected() {
        let access = makeAccess()
        XCTAssertNil(access.key(forSecret: "full-secret-and-more"))
        XCTAssertNil(access.key(forSecret: "full"))
    }

    func testRemovingAKeyRevokesOnlyThatAgent() {
        let access = NativMCPAccess(keys: [fullKey], readOnlyTools: [])
        XCTAssertEqual(access.key(forSecret: "full-secret")?.agent.scope, .full)
        XCTAssertNil(
            access.key(forSecret: "read-secret"),
            "revoking one agent must not affect the others"
        )
    }

    func testAFullKeyMayUseAnyToolAndAReadOnlyKeyMayNot() {
        let access = makeAccess()
        XCTAssertTrue(access.permits("anything_at_all", in: .full))
        XCTAssertTrue(access.permits(ChatModelLibraryToolRegistry.toolName, in: .readOnly))
        XCTAssertFalse(access.permits("anything_at_all", in: .readOnly))
    }

    func testTheDefaultReadOnlyListHoldsOnlyReportingTools() {
        XCTAssertEqual(
            NativMCPAccess.defaultReadOnlyTools,
            [
                ChatModelLibraryToolRegistry.toolName,
                ChatSystemMonitorToolRegistry.toolName,
                ChatServerStatsToolRegistry.toolName,
            ]
        )
    }

    func testEachGeneratedSecretIsDistinct() {
        let first = NativMCPKey.newSecret()
        let second = NativMCPKey.newSecret()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.isEmpty)
    }
}
