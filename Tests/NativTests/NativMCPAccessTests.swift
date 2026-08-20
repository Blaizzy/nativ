import XCTest

final class NativMCPAccessTests: XCTestCase {
    private func makeAccess(outside: Bool = true) -> NativMCPAccess {
        NativMCPAccess(
            localPort: 8765,
            outsidePort: outside ? 8766 : nil,
            localSecret: "local-secret",
            outsideSecret: outside ? "outside-secret" : nil,
            outsideAllowedTools: [ChatModelLibraryToolRegistry.toolName]
        )
    }

    func testTheLocalPortAcceptsOnlyTheLocalSecret() {
        let access = makeAccess()
        XCTAssertEqual(access.caller(arrivingOn: 8765, secret: "local-secret"), .local)
        XCTAssertNil(access.caller(arrivingOn: 8765, secret: "outside-secret"))
        XCTAssertNil(access.caller(arrivingOn: 8765, secret: nil))
        XCTAssertNil(access.caller(arrivingOn: 8765, secret: ""))
    }

    func testTheOutsidePortAcceptsOnlyTheOutsideSecret() {
        let access = makeAccess()
        XCTAssertEqual(access.caller(arrivingOn: 8766, secret: "outside-secret"), .outside)
        XCTAssertNil(
            access.caller(arrivingOn: 8766, secret: "local-secret"),
            "the local secret must not unlock the wider door"
        )
    }

    func testUnknownPortsAreRejected() {
        let access = makeAccess()
        XCTAssertNil(access.caller(arrivingOn: 9999, secret: "local-secret"))
    }

    func testOutsideAccessIsClosedWhenNoOutsidePortIsConfigured() {
        let access = makeAccess(outside: false)
        XCTAssertNil(access.caller(arrivingOn: 8766, secret: "outside-secret"))
        XCTAssertEqual(access.caller(arrivingOn: 8765, secret: "local-secret"), .local)
    }

    func testLocalCallersMayUseAnyToolAndOutsideCallersMayNot() {
        let access = makeAccess()
        XCTAssertTrue(access.permits("anything_at_all", for: .local))
        XCTAssertTrue(access.permits(ChatModelLibraryToolRegistry.toolName, for: .outside))
        XCTAssertFalse(access.permits("anything_at_all", for: .outside))
    }

    func testTheDefaultOutsideListIsReadOnly() {
        XCTAssertEqual(
            NativMCPAccess.defaultOutsideAllowedTools,
            [
                ChatModelLibraryToolRegistry.toolName,
                ChatSystemMonitorToolRegistry.toolName,
                ChatServerStatsToolRegistry.toolName,
            ]
        )
    }
}
