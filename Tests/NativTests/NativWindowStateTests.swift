import XCTest

@MainActor
final class NativWindowStateTests: XCTestCase {
    func testWindowUsesItsIdentifierForDependencies() {
        let id = UUID()
        let state = NativWindowState(
            sharedDependencies: ControlPanelSharedDependencies(),
            id: id
        )

        XCTAssertEqual(state.id, id)
        XCTAssertEqual(state.dependencies.windowID, id)
    }

    func testWindowsOwnIndependentStateAndShareApplicationDependencies() {
        let shared = ControlPanelSharedDependencies()
        let first = NativWindowState(sharedDependencies: shared)
        let second = NativWindowState(sharedDependencies: shared)

        XCTAssertFalse(first.navigation === second.navigation)
        XCTAssertFalse(first.dependencies.chat === second.dependencies.chat)
        XCTAssertTrue(first.dependencies.mcpHost === second.dependencies.mcpHost)
        XCTAssertTrue(first.dependencies.systemMonitor === second.dependencies.systemMonitor)
        XCTAssertTrue(first.dependencies.inferenceActivity === second.dependencies.inferenceActivity)
    }

    func testWindowRoutesIntentsToItsNavigation() {
        let state = NativWindowState(
            sharedDependencies: ControlPanelSharedDependencies()
        )

        state.perform(.openTab(.settings))

        XCTAssertEqual(state.navigation.requestedTab, .settings)
    }
}
