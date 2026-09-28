import Foundation

@MainActor
final class ControlPanelSharedDependencies {
    let mcpHost = MCPHostManager()
    let systemMonitor = SystemMonitorStore()
    let launchAtLogin = LaunchAtLoginController()
    let persistedDataChanges = PersistedDataChangeHub()
    let inferenceActivity = InferenceActivityCoordinator()
    let projects = ChatProjectStore()
    let chatSearch = ChatSearchLibrary(storageURL: ChatSearchStore.defaultURL)
    private let artifactChangeOrigin = UUID()
    lazy var artifactTrash = ArtifactTrash(
        isActive: { [inferenceActivity] workspace, id in
            switch workspace {
            case .chat: inferenceActivity.isActive(.chat(id))
            case .imageGeneration: inferenceActivity.isActive(.imageGeneration(id))
            }
        },
        didChange: { [persistedDataChanges, artifactChangeOrigin] kind in
            persistedDataChanges.send(kind, originWindowID: artifactChangeOrigin)
        }
    )
}

@MainActor
final class ControlPanelDependencies: ObservableObject {
    let mcpHost: MCPHostManager
    let systemMonitor: SystemMonitorStore
    let launchAtLogin: LaunchAtLoginController
    let windowID: UUID
    let persistedDataChanges: PersistedDataChangeHub
    let inferenceActivity: InferenceActivityCoordinator
    let projects: ChatProjectStore
    let chatSearch: ChatSearchLibrary
    let artifactTrash: ArtifactTrash

    lazy var chat = ChatViewModel(
        windowID: windowID,
        persistedDataChanges: persistedDataChanges,
        inferenceActivity: inferenceActivity,
        projectStore: projects,
        searchLibrary: chatSearch
    )
    lazy var imageGeneration = ImageGenerationViewModel(
        windowID: windowID,
        persistedDataChanges: persistedDataChanges,
        inferenceActivity: inferenceActivity
    )
    lazy var artifacts = ArtifactStore(persistedDataChanges: persistedDataChanges, trash: artifactTrash)
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
        inferenceActivity = shared.inferenceActivity
        projects = shared.projects
        chatSearch = shared.chatSearch
        artifactTrash = shared.artifactTrash
    }
}
