import XCTest

final class NativMCPAccessTests: XCTestCase {
    private let fullKey = NativMCPKey(name: "This Mac", scope: .full, secret: "full-secret")
    private let readOnlyKey = NativMCPKey(name: "Cloud agent", scope: .readOnly, secret: "read-secret")

    private func makeAccess() -> NativMCPAccess {
        NativMCPAccess(
            keys: [fullKey, readOnlyKey],
            readOnlyTools: [ChatModelLibraryToolRegistry.toolName]
        )
    }

    func testEachKeyResolvesToItsOwnScope() {
        let access = makeAccess()
        XCTAssertEqual(access.scope(forSecret: "full-secret"), .full)
        XCTAssertEqual(access.scope(forSecret: "read-secret"), .readOnly)
    }

    func testUnknownEmptyAndMissingSecretsAreRejected() {
        let access = makeAccess()
        XCTAssertNil(access.scope(forSecret: "not-a-secret"))
        XCTAssertNil(access.scope(forSecret: ""))
        XCTAssertNil(access.scope(forSecret: nil))
    }

    func testSecretsOfADifferentLengthAreRejected() {
        let access = makeAccess()
        XCTAssertNil(access.scope(forSecret: "full-secret-and-more"))
        XCTAssertNil(access.scope(forSecret: "full"))
    }

    func testRemovingAKeyRevokesOnlyThatAgent() {
        let access = NativMCPAccess(keys: [fullKey], readOnlyTools: [])
        XCTAssertEqual(access.scope(forSecret: "full-secret"), .full)
        XCTAssertNil(
            access.scope(forSecret: "read-secret"),
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

    func testANewKeyGetsItsOwnSecret() {
        let first = NativMCPKey(name: "One", scope: .full)
        let second = NativMCPKey(name: "Two", scope: .full)
        XCTAssertNotEqual(first.secret, second.secret)
        XCTAssertFalse(first.secret.isEmpty)
    }
}
