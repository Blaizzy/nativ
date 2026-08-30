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
        XCTAssertTrue(first.persistedDataChanges === second.persistedDataChanges)
        XCTAssertTrue(first.downloads === second.downloads)
    }

    func testControlPanelsReceiveDistinctWindowIdentifiers() {
        let firstWindowID = UUID()
        let secondWindowID = UUID()

        let first = ControlPanelDependencies(windowID: firstWindowID)
        let second = ControlPanelDependencies(windowID: secondWindowID)

        XCTAssertEqual(first.windowID, firstWindowID)
        XCTAssertEqual(second.windowID, secondWindowID)
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
