import SwiftUI
import TipKit
import XCTest

final class NativReleaseTipTests: XCTestCase {
    func testReleaseTipsUseTheirStableIdentity() {
        XCTAssertEqual(ExampleReleaseTip().id, "nativ.release.example.v1")
    }

    func testReleaseTipsDefaultToOnePresentation() {
        XCTAssertEqual(ExampleReleaseTip().options.count, 1)
    }

    func testReleaseTipsCanDefineFeatureSpecificContent() {
        let tip = ExampleReleaseTip()

        XCTAssertNotNil(tip.message)
        XCTAssertNotNil(tip.image)
        XCTAssertEqual(tip.actions.count, 1)
    }

    func testReleaseTipsCanOverrideTheDefaultPresentationPolicy() {
        XCTAssertTrue(CustomPolicyReleaseTip().options.isEmpty)
    }
}

private struct ExampleReleaseTip: NativReleaseTip {
    static let stableID = "nativ.release.example.v1"

    var title: Text {
        Text("Example")
    }

    var message: Text? {
        Text("Example message")
    }

    var image: Image? {
        Image(systemName: "sparkles")
    }

    var actions: [Action] {
        Action(title: "Try it")
    }
}

private struct CustomPolicyReleaseTip: NativReleaseTip {
    static let stableID = "nativ.release.custom-policy.v1"

    var title: Text {
        Text("Custom policy")
    }

    var options: [any TipOption] {
        []
    }
}
