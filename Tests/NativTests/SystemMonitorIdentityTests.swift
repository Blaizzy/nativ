import XCTest
@testable import Nativ

final class SystemMonitorIdentityTests: XCTestCase {
    func testDeviceModelCodeIncludesEnclosureColor() {
        var identity = SystemMonitorIdentity()
        identity.modelIdentifier = "Mac17,6"
        identity.enclosureColorCode = "9"

        XCTAssertEqual(identity.deviceModelCode, "Mac17,6@ECOLOR=9")
    }

    func testDeviceModelCodeFallsBackToModelIdentifierWithoutColor() {
        var identity = SystemMonitorIdentity()
        identity.modelIdentifier = "Mac17,6"

        XCTAssertEqual(identity.deviceModelCode, "Mac17,6")
    }
}
