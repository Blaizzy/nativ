import SwiftUI
import TipKit
import XCTest

final class NativFeatureTipTests: XCTestCase {
    func testFeatureTipsDefaultToOnePresentation() {
        let tip = ExampleFeatureTip()

        XCTAssertEqual(tip.options.count, 1)
    }

    func testFeatureTipsCanDefineFeatureSpecificContent() {
        let tip = ExampleFeatureTip()

        XCTAssertNotNil(tip.message)
        XCTAssertNotNil(tip.image)
        XCTAssertEqual(tip.actions.count, 1)
    }
}

private struct ExampleFeatureTip: NativFeatureTip {
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
