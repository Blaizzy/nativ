import XCTest

@MainActor
final class WindowCommandRoutingTests: XCTestCase {
    func testRoutesNavigationIntents() {
        let navigation = ControlPanelNavigation()
        let sessionID = UUID()

        navigation.perform(.openTab(.dashboard))
        XCTAssertEqual(navigation.requestedTab, .dashboard)

        navigation.perform(.openChat(sessionID))
        XCTAssertEqual(navigation.requestedChatSessionID, sessionID)

        navigation.perform(.openExtensionPage("voice.audio"))
        XCTAssertEqual(navigation.requestedExtensionPageID, "voice.audio")

        navigation.perform(.openSpeechModels)
        XCTAssertEqual(navigation.requestedTab, .models)
        XCTAssertEqual(navigation.speechModelDiscoveryRequest, 1)
    }

    func testRoutesCommandRequests() {
        let navigation = ControlPanelNavigation()

        navigation.perform(.newChat)
        navigation.perform(.toggleSidebar)
        navigation.perform(.collapseSidebarSections)

        XCTAssertTrue(navigation.consumeNewChatRequest())
        XCTAssertTrue(navigation.consumeToggleSidebarRequest())
        XCTAssertTrue(navigation.consumeCollapseAllSectionsRequest())
    }

    func testOpensDiscoveryForAnExactModel() {
        let navigation = ControlPanelNavigation()
        let repoID = "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"

        navigation.openModelDiscovery(repoID: repoID)

        XCTAssertEqual(navigation.requestedTab, .models)
        XCTAssertEqual(navigation.modelDiscoveryRepositoryID, repoID)
        XCTAssertEqual(navigation.modelDiscoveryRequest, 1)
    }

    func testOpensDrafterDiscoveryForTargetModel() {
        let navigation = ControlPanelNavigation()
        let targetID = "mlx-community/Qwen3.8-27B-4bit"

        navigation.openDrafterModelDiscovery(for: targetID)

        XCTAssertEqual(navigation.requestedTab, .models)
        XCTAssertEqual(navigation.drafterModelDiscoveryTargetID, targetID)
        XCTAssertEqual(navigation.drafterModelDiscoveryRequest, 1)
    }

    func testActivateDoesNotChangeNavigation() {
        let navigation = ControlPanelNavigation()

        navigation.perform(.activate)

        XCTAssertNil(navigation.requestedTab)
        XCTAssertNil(navigation.requestedChatSessionID)
        XCTAssertNil(navigation.requestedExtensionPageID)
        XCTAssertFalse(navigation.consumeNewChatRequest())
        XCTAssertFalse(navigation.consumeToggleSidebarRequest())
        XCTAssertFalse(navigation.consumeCollapseAllSectionsRequest())
    }
}
