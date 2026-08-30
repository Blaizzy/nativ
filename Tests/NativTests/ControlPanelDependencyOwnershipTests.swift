import XCTest

@MainActor
final class ControlPanelDependencyOwnershipTests: XCTestCase {
    func testApplicationDependenciesAreSharedAcrossControlPanels() {
        let shared = ControlPanelSharedDependencies()
        let first = ControlPanelDependencies(shared: shared)
        let second = ControlPanelDependencies(shared: shared)

        XCTAssertTrue(first.mcpHost === second.mcpHost)
        XCTAssertTrue(first.systemMonitor === second.systemMonitor)
        XCTAssertTrue(first.launchAtLogin === second.launchAtLogin)
        XCTAssertTrue(first.downloads === second.downloads)
    }

    func testControlPanelStateIsIndependent() {
        let shared = ControlPanelSharedDependencies()
        let first = ControlPanelDependencies(shared: shared)
        let second = ControlPanelDependencies(shared: shared)

        XCTAssertFalse(first.chat === second.chat)
        XCTAssertFalse(first.imageGeneration === second.imageGeneration)
        XCTAssertFalse(first.artifacts === second.artifacts)
        XCTAssertFalse(first.dashboard === second.dashboard)
        XCTAssertFalse(first.embeddingLibrary === second.embeddingLibrary)
        XCTAssertFalse(first.routineModelLibrary === second.routineModelLibrary)
    }
}
