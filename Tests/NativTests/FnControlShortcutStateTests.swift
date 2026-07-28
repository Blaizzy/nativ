import XCTest

final class FnControlShortcutStateTests: XCTestCase {
    func testActivatesOnlyWhenFnAndControlAreBothHeld() {
        var state = FnControlShortcutState()

        XCTAssertNil(state.update(functionIsDown: true, controlIsDown: false))
        XCTAssertEqual(state.update(functionIsDown: true, controlIsDown: true), true)
        XCTAssertNil(state.update(functionIsDown: true, controlIsDown: true))
    }

    func testReleasesWhenEitherModifierIsReleased() {
        var state = FnControlShortcutState()
        XCTAssertEqual(state.update(functionIsDown: true, controlIsDown: true), true)

        XCTAssertEqual(state.update(functionIsDown: false, controlIsDown: true), false)
        XCTAssertNil(state.update(functionIsDown: false, controlIsDown: false))
    }

    func testCanStartAgainAfterRelease() {
        var state = FnControlShortcutState()
        XCTAssertEqual(state.update(functionIsDown: true, controlIsDown: true), true)
        XCTAssertEqual(state.update(functionIsDown: true, controlIsDown: false), false)
        XCTAssertEqual(state.update(functionIsDown: true, controlIsDown: true), true)
    }
}

final class FnRetryShortcutStateTests: XCTestCase {
    func testTriggersOnlyOnInitialPress() {
        var state = FnRetryShortcutState()

        XCTAssertTrue(state.update(isPressed: true))
        XCTAssertFalse(state.update(isPressed: true))
        XCTAssertFalse(state.update(isPressed: true))
    }

    func testCanTriggerAgainAfterRelease() {
        var state = FnRetryShortcutState()

        XCTAssertTrue(state.update(isPressed: true))
        XCTAssertFalse(state.update(isPressed: false))
        XCTAssertTrue(state.update(isPressed: true))
    }
}
