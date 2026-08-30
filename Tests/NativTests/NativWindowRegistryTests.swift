import AppKit
import XCTest

@MainActor
final class NativWindowRegistryTests: XCTestCase {
    func testRoutesIntentToRegisteredWindow() {
        let registry = NativWindowRegistry()
        let state = NativWindowState(
            sharedDependencies: ControlPanelSharedDependencies()
        )
        let window = TestWindowHandle()
        registry.register(state: state, window: window)

        registry.perform(.openTab(.dashboard))

        XCTAssertEqual(state.navigation.requestedTab, .dashboard)
    }

    func testPendingIntentRunsWhenWindowRegisters() {
        let registry = NativWindowRegistry()
        var openWindowCount = 0
        registry.registerWindowOpener {
            openWindowCount += 1
        }

        registry.perform(.newChat)

        XCTAssertEqual(openWindowCount, 1)
        let state = NativWindowState(
            sharedDependencies: ControlPanelSharedDependencies()
        )
        let window = TestWindowHandle()
        registry.register(state: state, window: window)
        XCTAssertTrue(state.navigation.consumeNewChatRequest())
        XCTAssertEqual(window.activationCount, 1)
    }

    func testUnregisteredWindowNoLongerReceivesIntents() {
        let registry = NativWindowRegistry()
        let state = NativWindowState(
            sharedDependencies: ControlPanelSharedDependencies()
        )
        let window = TestWindowHandle()
        registry.register(state: state, window: window)
        registry.unregister(stateID: state.id, window: window)
        var openWindowCount = 0
        registry.registerWindowOpener {
            openWindowCount += 1
        }

        registry.perform(.newChat)

        XCTAssertEqual(openWindowCount, 1)
        XCTAssertFalse(state.navigation.consumeNewChatRequest())
    }

    private final class TestWindowHandle: NativWindowHandle {
        var appKitWindow: NSWindow? {
            nil
        }

        private(set) var activationCount = 0

        func activate() {
            activationCount += 1
        }
    }
}
