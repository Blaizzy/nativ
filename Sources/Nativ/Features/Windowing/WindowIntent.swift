import Foundation

enum NativWindowIntent: Equatable {
    case activate
    case newChat
    case openChat(UUID)
    case openTab(ControlPanelTab)
    case openExtensionPage(String)
    case openSpeechModels
    case toggleSidebar
    case collapseSidebarSections
}

extension ControlPanelNavigation {
    func perform(_ intent: NativWindowIntent) {
        switch intent {
        case .activate:
            break
        case .newChat:
            createChat()
        case .openChat(let sessionID):
            openChatSession(sessionID)
        case .openTab(let tab):
            open(tab)
        case .openExtensionPage(let pageID):
            openExtensionPage(pageID)
        case .openSpeechModels:
            openSpeechModelDiscovery()
        case .toggleSidebar:
            toggleSidebar()
        case .collapseSidebarSections:
            collapseAllSections()
        }
    }
}
