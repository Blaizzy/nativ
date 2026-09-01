import Foundation

@MainActor
final class ControlPanelSharedDependencies {
    let mcpHost = MCPHostManager()
    let systemMonitor = SystemMonitorStore()
    let launchAtLogin = LaunchAtLoginController()
    let persistedDataChanges = PersistedDataChangeHub()
    let inferenceActivity = InferenceActivityCoordinator()
}

@MainActor
final class ControlPanelDependencies: ObservableObject {
    let mcpHost: MCPHostManager
    let systemMonitor: SystemMonitorStore
    let launchAtLogin: LaunchAtLoginController
    let windowID: UUID
    let persistedDataChanges: PersistedDataChangeHub
    let inferenceActivity: InferenceActivityCoordinator

    lazy var chat = ChatViewModel(
        windowID: windowID,
        persistedDataChanges: persistedDataChanges,
        inferenceActivity: inferenceActivity
    )
    lazy var imageGeneration = ImageGenerationViewModel(
        windowID: windowID,
        persistedDataChanges: persistedDataChanges,
        inferenceActivity: inferenceActivity
    )
    lazy var artifacts = ArtifactStore { [weak self] artifact in
        guard let self else {
            return false
        }
        switch artifact.source {
        case .uploaded:
            return chat.removeAttachment(
                sessionID: artifact.sessionID,
                messageID: artifact.messageID,
                attachmentID: artifact.id
            )
        case .generated:
            return imageGeneration.removeOutput(
                sessionID: artifact.sessionID,
                turnID: artifact.messageID,
                outputID: artifact.id
            )
        }
    }
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
    }
}
