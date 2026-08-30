import Foundation

@MainActor
final class ControlPanelSharedDependencies {
    let mcpHost = MCPHostManager()
    let systemMonitor = SystemMonitorStore()
    let launchAtLogin = LaunchAtLoginController()
    let persistedDataChanges = PersistedDataChangeHub()
}

@MainActor
final class ControlPanelDependencies: ObservableObject {
    let mcpHost: MCPHostManager
    let systemMonitor: SystemMonitorStore
    let launchAtLogin: LaunchAtLoginController
    let windowID: UUID
    let persistedDataChanges: PersistedDataChangeHub

    lazy var chat = ChatViewModel(
        windowID: windowID,
        persistedDataChanges: persistedDataChanges
    )
    lazy var imageGeneration = ImageGenerationViewModel(
        windowID: windowID,
        persistedDataChanges: persistedDataChanges
    )
    lazy var artifacts = ArtifactStore()
    lazy var dashboard = DashboardViewModel()
    lazy var downloads = HuggingFaceDownloadManager.shared
    lazy var embeddingLibrary = LocalModelLibrary()
    lazy var routineModelLibrary = LocalModelLibrary()

    init(
        shared: ControlPanelSharedDependencies = .init(),
        windowID: UUID = UUID()
    ) {
        mcpHost = shared.mcpHost
        systemMonitor = shared.systemMonitor
        launchAtLogin = shared.launchAtLogin
        self.windowID = windowID
        persistedDataChanges = shared.persistedDataChanges
    }
}
