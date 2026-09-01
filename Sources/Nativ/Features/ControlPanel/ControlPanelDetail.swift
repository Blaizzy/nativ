import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

extension ControlPanelView {
    var detail: some View {
        VStack(spacing: 0) {
            Group {
                if case .extensionPage(let pageID) = sidebarSelection {
                    extensionPage(pageID)
                } else {
                    corePage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.nativMainContentBackground)
        .alert(
            "Models May Not Fit in Memory",
            isPresented: Binding(
                get: { chromeState.modelPreloadMemoryWarning != nil },
                set: { isPresented in
                    if !isPresented {
                        model.cancelPendingModelPreloadSwitch()
                    }
                }
            )
        ) {
            Button("Load Anyway") {
                model.confirmPendingModelPreloadSwitch()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                model.cancelPendingModelPreloadSwitch()
            }
        } message: {
            Text(chromeState.modelPreloadMemoryWarning?.message ?? "")
        }
    }

    @ViewBuilder
    var corePage: some View {
        switch selectedTab {
        case .chat:
            ChatWorkspaceView(
                mode: chatWorkspaceMode,
                onSelectMode: selectChatWorkspaceMode,
                model: model,
                chat: chat,
                mcpHost: mcpHost,
                extensionManager: extensionManager,
                imageGeneration: imageGeneration,
                projects: projects,
                showsConfiguration: $isModelConfigurationVisible,
                onExploreImageModels: navigation.openImageModelDiscovery
            )
        case .scheduled:
            ScheduledTasksView(
                model: model,
                mcpHost: mcpHost,
                extensionManager: extensionManager,
                titleLeadingInset: 0,
                onOpenRun: { applySidebarSelection(.chat($0)) },
                onDeleteTaskChats: { taskID, sessionIDs, disposition in
                    chat.handleScheduledTaskDeletion(
                        taskID: taskID,
                        linkedSessionIDs: sessionIDs,
                        disposition: disposition
                    )
                }
            )
        case .artifacts:
            ArtifactsPageHost(
                store: artifacts,
                model: model,
                downloads: downloads,
                embeddingLibrary: embeddingLibrary,
                settings: chromeState.artifactSettings,
                titleLeadingInset: 0,
                onOpenModels: { navigation.open(.models) },
                onOpenChat: { artifact in
                    switch artifact.source {
                    case .uploaded:
                        applySidebarSelection(.chat(artifact.sessionID))
                        chat.scrollTargetMessageID = artifact.messageID
                    case .generated:
                        applySidebarSelection(.imageGeneration(artifact.sessionID))
                    }
                },
                onUseInChat: { artifact in
                    if let attachment = artifacts.chatAttachment(for: artifact) {
                        chat.stageAttachment(attachment)
                    }
                    showChatWorkspace()
                },
                onUseAsReference: { artifact in
                    imageGeneration.beginNewDraft()
                    showImageWorkspace()
                    if let attachment = artifacts.chatAttachment(for: artifact) {
                        imageGeneration.useAsReference(attachment)
                    }
                }
            )
        case .dashboard:
            StatsView(
                model: model,
                dashboard: dashboard,
                titleLeadingInset: 0
            )
        case .system:
            SystemMonitorView(
                store: systemMonitor,
                menuBarPreferences: .shared,
                titleLeadingInset: 0
            )
        case .models:
            ModelsViewHost(
                model: model,
                showsConfiguration: $isModelConfigurationVisible,
                titleLeadingInset: 0,
                speechModelDiscoveryRequest: speechModelDiscoveryRequest,
                imageModelDiscoveryRequest: imageModelDiscoveryRequest,
                imageModelDiscoveryCapability: imageModelDiscoveryCapability,
                modelDiscoveryRequest: modelDiscoveryRequest,
                modelDiscoveryRepositoryID: modelDiscoveryRepositoryID
            )
            .equatable()
        case .extensions:
            ExtensionsHubView(
                manager: extensionManager,
                host: mcpHost,
                model: model,
                section: $selectedExtensionsHubSection
            )
        case .dev:
            DevHubView(
                section: $selectedDevSection,
                model: model,
                runtime: runtime,
                showsConfiguration: $isModelConfigurationVisible
            )
        case .settings:
            SettingsView(
                model: model,
                softwareUpdater: softwareUpdater,
                launchAtLogin: launchAtLogin
            )
        }
    }

    @ViewBuilder
    func extensionPage(_ pageID: String) -> some View {
        if let page = extensionManager.makePage(
            id: pageID,
            context: NativExtensionPageContext(
                model: model,
                titleLeadingInset: 0,
                openSpeechModels: {
                    navigation.openSpeechModelDiscovery()
                }
            )
        ) {
            page
        } else {
            ContentUnavailableView {
                Label("Extension Unavailable", systemImage: "puzzlepiece.extension")
            } description: {
                Text("Enable or restore this extension from the Extensions page.")
            } actions: {
                Button("Open Extensions") {
                    applySidebarSelection(.tab(.extensions))
                }
            }
        }
    }

    func applySidebarSelection(_ selection: ControlPanelSidebarSelection) {
        switch selection {
        case .tab(let tab):
            if tab == .extensions {
                isExtensionsBadgeDismissed = true
            }
            if tab == .chat {
                switch chatWorkspaceMode {
                case .chat where sidebarState.currentChatSessionID == nil:
                    chat.createSession()
                default:
                    break
                }
            }
            sidebarSelection = selection
            selectedTab = tab
        case .extensionPage(let pageID):
            guard
                contentState.extensionSidebarContributions.contains(
                    where: { $0.id == pageID }
                )
            else {
                sidebarSelection = .tab(.extensions)
                selectedTab = .extensions
                return
            }
            sidebarSelection = selection
            selectedTab = .extensions
        case .chat(let sessionID):
            if sidebarState.recents.containsChatSession(sessionID) {
                chat.selectSession(sessionID)
                sidebarSelection = selection
            } else {
                sidebarSelection = .tab(.chat)
            }
            chatWorkspaceMode = .chat
            selectedTab = .chat
        case .imageGeneration(let sessionID):
            if sidebarState.recents.containsImageSession(sessionID) {
                imageGeneration.selectSession(sessionID)
                sidebarSelection = selection
            } else {
                sidebarSelection = .tab(.chat)
            }
            chatWorkspaceMode = .images
            selectedTab = .chat
        }
    }

}

struct ChatWorkspaceView: View {
    let mode: ChatWorkspaceMode
    let onSelectMode: (ChatWorkspaceMode) -> Void
    let model: NativModel
    let chat: ChatViewModel
    let mcpHost: MCPHostManager
    let extensionManager: NativExtensionManager
    let imageGeneration: ImageGenerationViewModel
    let projects: ChatProjectStore
    @Binding var showsConfiguration: Bool
    let onExploreImageModels: (ChatImageOperation) -> Void

    var body: some View {
        Group {
            switch mode {
            case .chat:
                ChatView(
                    model: model,
                    chat: chat,
                    mcpHost: mcpHost,
                    extensionManager: extensionManager,
                    projects: projects,
                    workspaceMode: mode,
                    onSelectWorkspaceMode: onSelectMode,
                    showsConfiguration: $showsConfiguration,
                    onExploreImageModels: onExploreImageModels
                )
            case .images:
                ImageGenerationView(
                    model: model,
                    viewModel: imageGeneration,
                    workspaceMode: mode,
                    onSelectWorkspaceMode: onSelectMode,
                    onExploreImageModels: { onExploreImageModels(.generate) }
                )
            }
        }
        .id(mode)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.1), value: mode)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nativMainContentBackground)
    }
}

struct ArtifactsPageHost: View {
    private static let embeddingModelID = "mlx-community/Qwen3-VL-Embedding-2B-bf16"
    private static let embeddingModelSize: Int64 = 4_300_000_000

    let store: ArtifactStore
    let model: NativModel
    @ObservedObject var downloads: HuggingFaceDownloadManager
    @ObservedObject var embeddingLibrary: LocalModelLibrary
    let settings: ControlPanelChromeState.ArtifactSettings
    let titleLeadingInset: CGFloat
    let onOpenModels: () -> Void
    let onOpenChat: (Artifact) -> Void
    let onUseInChat: (Artifact) -> Void
    let onUseAsReference: (Artifact) -> Void

    private var semanticSearch: ArtifactSemanticSearchConfig? {
        guard ProcessInfo.processInfo.physicalMemory >= 16_000_000_000 else {
            return nil
        }
        let baseURL =
            URL(string: "http://127.0.0.1:\(settings.serverPort)")
            ?? URL(string: "http://127.0.0.1:8080")!
        let modelID = Self.embeddingModelID
        let modelSearchPath = settings.modelSearchPath
        let insufficientReason = downloads.capacityBlocker(
            sizeBytes: Self.embeddingModelSize,
            cachePath: settings.modelSearchPath
        )
        return ArtifactSemanticSearchConfig(
            modelID: modelID,
            sizeBytes: Self.embeddingModelSize,
            client: NativEmbeddingsClient(baseURL: baseURL, apiKey: settings.serverAPIKey),
            isModelInstalled: embeddingLibrary.models.contains { $0.repoID == modelID },
            isDownloading: downloads.isDownloading(modelID),
            downloadProgress: downloads.progress(for: modelID),
            canInstall: insufficientReason == nil,
            insufficientReason: insufficientReason,
            onEnable: {
                enableSemanticSearch()
            },
            onRemove: {
                removeSemanticSearchModel()
            },
            prepareModel: {
                EmbeddingModelPreparer.prepare(
                    repoID: modelID,
                    searchPath: modelSearchPath
                )
            }
        )
    }

    var body: some View {
        ArtifactsView(
            store: store,
            semanticSearch: semanticSearch,
            titleLeadingInset: titleLeadingInset,
            onOpenChat: onOpenChat,
            onUseInChat: onUseInChat,
            onUseAsReference: onUseAsReference
        )
    }

    private func enableSemanticSearch() {
        let modelID = Self.embeddingModelID
        downloads.download(
            repoID: modelID,
            sizeBytes: Self.embeddingModelSize,
            cachePath: settings.modelSearchPath,
            volumeIdentifier: settings.modelCacheVolumeIdentifier,
            token: model.effectiveHuggingFaceToken
        ) {
            EmbeddingModelPreparer.prepare(
                repoID: modelID,
                searchPath: settings.modelSearchPath
            )
            embeddingLibrary.scan(searchPaths: settings.localModelSearchPaths)
            NotificationCenter.default.post(name: .localModelLibraryDidChange, object: nil)
        }
        onOpenModels()
    }

    private func removeSemanticSearchModel() {
        let modelID = Self.embeddingModelID
        Task {
            try? await LocalModelDiscovery.delete(
                repoID: modelID,
                path: settings.modelSearchPath,
                volumeIdentifier: settings.modelCacheVolumeIdentifier
            )
            embeddingLibrary.scan(searchPaths: settings.localModelSearchPaths)
            NotificationCenter.default.post(name: .localModelLibraryDidChange, object: nil)
        }
    }

}
