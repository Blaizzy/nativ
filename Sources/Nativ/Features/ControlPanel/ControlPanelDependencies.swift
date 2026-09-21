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
    lazy var artifacts: ArtifactStore = ArtifactStore(persistedDataChanges: persistedDataChanges, deletionHandler: { [weak self] artifact in
        guard let self else {
            return false
        }
        let current = ArtifactCatalog.artifacts(
            chats: ChatSessionStore().loadSessions(), images: ImageGenerationSessionStore().loadSessions()
        ).first { $0.id == artifact.id }
        guard let current else { return true }
        let removed = ArtifactDeletion.removeReferences(
            to: current,
            isActive: { workspace, id in
                switch workspace {
                case .chat: inferenceActivity.isActive(.chat(id))
                case .imageGeneration: inferenceActivity.isActive(.imageGeneration(id))
                }
            },
            remove: { workspace, id in
                switch workspace {
                case .chat: chat.removeArtifact(artifact.id, sessionID: id)
                case .imageGeneration: imageGeneration.removeArtifact(artifact.id, sessionID: id)
                }
            }
        )
        if !removed { artifacts.refresh() }
        return removed
    })
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
    }
}
