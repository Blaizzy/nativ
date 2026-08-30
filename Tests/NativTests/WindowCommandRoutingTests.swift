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
