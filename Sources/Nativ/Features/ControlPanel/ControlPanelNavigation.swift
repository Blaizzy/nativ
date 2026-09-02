import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

enum ControlPanelTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case scheduled = "Scheduled"
    case artifacts = "Artifacts"
    case dashboard = "Dashboard"
    case system = "System"
    case models = "Models"
    case extensions = "Extensions"
    case dev = "Dev"
    case settings = "Settings"

    static var allCases: [ControlPanelTab] {
        [
            .chat,
            .models,
            .artifacts,
            .scheduled,
            .dashboard,
            .system,
            .extensions,
            .dev,
        ]
    }

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .chat:
            "bubble.left.and.bubble.right"
        case .scheduled:
            "clock.badge.checkmark"
        case .artifacts:
            "photo.on.rectangle.angled"
        case .dashboard:
            "chart.bar.xaxis"
        case .system:
            "gauge.open.with.lines.needle.33percent"
        case .models:
            "cube.transparent"
        case .extensions:
            "point.3.filled.connected.trianglepath.dotted"
        case .dev:
            "chevron.left.forwardslash.chevron.right"
        case .settings:
            "gearshape"
        }
    }
}

@MainActor
final class ControlPanelNavigation: ObservableObject {
    @Published private(set) var requestedTab: ControlPanelTab?
    @Published private(set) var requestedExtensionPageID: String?
    @Published private(set) var requestedChatSessionID: UUID?
    @Published private(set) var newChatRequest = 0
    @Published private(set) var toggleSidebarRequest = 0
    @Published private(set) var speechModelDiscoveryRequest = 0
    @Published private(set) var imageModelDiscoveryRequest = 0
    @Published private(set) var imageModelDiscoveryCapability: LocalModelCapability =
        .imageGeneration
    @Published private(set) var modelDiscoveryRequest = 0
    @Published private(set) var modelDiscoveryRepositoryID: String?
    @Published private(set) var collapseAllSectionsRequest = 0
    private var consumedNewChatRequest = 0
    private var consumedToggleSidebarRequest = 0
    private var consumedCollapseAllSectionsRequest = 0

    func open(_ tab: ControlPanelTab) {
        requestedExtensionPageID = nil
        requestedChatSessionID = nil
        requestedTab = tab
    }

    func openChatSession(_ sessionID: UUID) {
        requestedTab = nil
        requestedExtensionPageID = nil
        requestedChatSessionID = sessionID
    }

    func openExtensionPage(_ pageID: String) {
        requestedTab = nil
        requestedExtensionPageID = pageID
    }

    func openSpeechModelDiscovery() {
        speechModelDiscoveryRequest += 1
        requestedTab = .models
    }

    func openImageModelDiscovery(for operation: ChatImageOperation) {
        imageModelDiscoveryCapability = operation.requiredCapability
        imageModelDiscoveryRequest += 1
        requestedTab = .models
    }

    func openModelDiscovery(repoID: String) {
        modelDiscoveryRepositoryID = repoID
        modelDiscoveryRequest += 1
        requestedTab = .models
    }

    func createChat() {
        newChatRequest += 1
    }

    func toggleSidebar() {
        toggleSidebarRequest += 1
    }

    func collapseAllSections() {
        collapseAllSectionsRequest += 1
    }

    func consumeNewChatRequest() -> Bool {
        guard consumedNewChatRequest < newChatRequest else {
            return false
        }
        consumedNewChatRequest = newChatRequest
        return true
    }

    func consumeToggleSidebarRequest() -> Bool {
        guard consumedToggleSidebarRequest < toggleSidebarRequest else {
            return false
        }
        consumedToggleSidebarRequest = toggleSidebarRequest
        return true
    }

    func consumeCollapseAllSectionsRequest() -> Bool {
        guard consumedCollapseAllSectionsRequest < collapseAllSectionsRequest else {
            return false
        }
        consumedCollapseAllSectionsRequest = collapseAllSectionsRequest
        return true
    }
}
