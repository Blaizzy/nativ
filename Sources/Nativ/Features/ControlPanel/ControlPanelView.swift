import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

struct ControlPanelView: View {
    @Environment(\.displayScale) var displayScale

    let model: NativModel
    let navigation: ControlPanelNavigation
    let runtime: SystemRuntimeMonitor
    let extensionManager: NativExtensionManager
    let softwareUpdater: SoftwareUpdater

    let dependencies: ControlPanelDependencies
    @StateObject var chromeState: ControlPanelChromeState
    @StateObject var sidebarState: ChatSidebarState
    @StateObject var contentState: ControlPanelContentState
    @AppStorage(ControlPanelOnboarding.extensionsBadgeDismissedKey)
    var isExtensionsBadgeDismissed = false
    @State var sidebarSelection: ControlPanelSidebarSelection = .tab(.chat)
    @State var selectedTab: ControlPanelTab = .chat
    @State var isFullScreen = false
    @State var selectedExtensionsHubSection: ExtensionsHubView.HubSection = .kits
    @State var chatWorkspaceMode: ChatWorkspaceMode = .chat
    @State var speechModelDiscoveryRequest: Int
    @State var imageModelDiscoveryRequest: Int
    @State var imageModelDiscoveryCapability: LocalModelCapability
    @State var hoveredFooterControl: FooterControl?
    @State var isSidebarVisible = true
    @State var sidebarWidth = ControlPanelLayout.sidebarIdealWidth
    @State var sidebarDragStartWidth: CGFloat?
    @State var isModelConfigurationVisible = false
    @State var selectedDevSection: DevHubView.Section = .integrations
    @State var isNewChatHovering = false
    @State var isSelectingRecents = false
    @State var selectedRecentIDs: Set<ControlPanelRecentSession.ID> = []
    @State var selectedFolderIDs: Set<UUID> = []
    @State var isPinnedDropTargeted = false
    @State var isSessionsDropTargeted = false
    @State var reorderTargetID: ControlPanelRecentSession.ID?
    @State var reorderInsertAfter = false
    @State var isFoldersDropTargeted = false
    @State var pendingDeleteRecent: ControlPanelRecentSession?
    @State var pendingDeleteFolder: ChatFolder?
    @State var isConfirmingBulkDelete = false

    var chat: ChatViewModel { dependencies.chat }
    var mcpHost: MCPHostManager { dependencies.mcpHost }
    var imageGeneration: ImageGenerationViewModel { dependencies.imageGeneration }
    var artifacts: ArtifactStore { dependencies.artifacts }
    var dashboard: DashboardViewModel { dependencies.dashboard }
    var systemMonitor: SystemMonitorStore { dependencies.systemMonitor }
    var launchAtLogin: LaunchAtLoginController { dependencies.launchAtLogin }
    var downloads: HuggingFaceDownloadManager { dependencies.downloads }
    var embeddingLibrary: LocalModelLibrary { dependencies.embeddingLibrary }
    var routineStore: RoutineStore { dependencies.routineStore }
    var routineModelLibrary: LocalModelLibrary { dependencies.routineModelLibrary }

    init(
        model: NativModel,
        navigation: ControlPanelNavigation,
        runtime: SystemRuntimeMonitor,
        extensionManager: NativExtensionManager,
        softwareUpdater: SoftwareUpdater,
        dependencies: ControlPanelDependencies
    ) {
        self.model = model
        self.navigation = navigation
        self.runtime = runtime
        self.extensionManager = extensionManager
        self.softwareUpdater = softwareUpdater
        self.dependencies = dependencies
        _chromeState = StateObject(wrappedValue: ControlPanelChromeState(model: model))
        _sidebarState = StateObject(
            wrappedValue: ChatSidebarState(
                chat: dependencies.chat,
                imageGeneration: dependencies.imageGeneration
            )
        )
        _contentState = StateObject(
            wrappedValue: ControlPanelContentState(
                dependencies: dependencies,
                extensionManager: extensionManager
            )
        )
        _speechModelDiscoveryRequest = State(
            initialValue: navigation.speechModelDiscoveryRequest
        )
        _imageModelDiscoveryRequest = State(
            initialValue: navigation.imageModelDiscoveryRequest
        )
        _imageModelDiscoveryCapability = State(
            initialValue: navigation.imageModelDiscoveryCapability
        )
    }

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: isSidebarVisible ? sidebarWidth : 0)

                detail
                    .frame(
                        minWidth: ControlPanelLayout.detailMinimumWidth,
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                    .ignoresSafeArea(
                        .container,
                        edges: isSidebarVisible ? .top : []
                    )
            }

            resizableSidebar
                .offset(
                    x: isSidebarVisible
                        ? 0
                        : -sidebarWidth
                )
                .allowsHitTesting(isSidebarVisible)
                .accessibilityHidden(!isSidebarVisible)
        }
        .animation(
            .easeInOut(duration: ControlPanelLayout.sidebarTransitionDuration),
            value: isSidebarVisible
        )
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar(removing: .title)
        .frame(minWidth: 1040, minHeight: 600)
        .environment(\.controlPanelIsFullScreen, isFullScreen)
        .environment(\.controlPanelIsSidebarVisible, isSidebarVisible)
        .environment(\.openExtensionsHubSection) { section in
            selectedExtensionsHubSection = section
            Task { @MainActor in
                await Task.yield()
                applySidebarSelection(.tab(.extensions))
            }
        }
        .overlay(alignment: .top) {
            Group {
                if selectedTab != .models, let failure = chromeState.modelLoadFailure {
                    GlobalModelLoadFailureBanner(
                        failure: failure,
                        onOpenModels: { navigation.open(.models) },
                        onDismiss: { model.clearModelLoadFailure() }
                    )
                    .padding(.top, 10)
                    .padding(.horizontal, 16)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selectedTab)
        }
        .overlay(alignment: .top) {
            controlPanelTopControls
        }
        .background {
            ControlPanelWindowStateReader(isFullScreen: $isFullScreen)
                .frame(width: 0, height: 0)
        }
        .onAppear {
            applySidebarSelection(
                navigation.requestedTab.map(ControlPanelSidebarSelection.tab) ?? sidebarSelection)
            handleNewChatRequest()
            embeddingLibrary.scan(searchPaths: chromeState.artifactSettings.localModelSearchPaths)
            artifacts.onDeleteArtifact = { artifact in
                switch artifact.source {
                case .uploaded:
                    chat.removeAttachment(
                        sessionID: artifact.sessionID,
                        messageID: artifact.messageID,
                        attachmentID: artifact.id
                    )
                case .generated:
                    imageGeneration.removeOutput(
                        sessionID: artifact.sessionID,
                        turnID: artifact.messageID,
                        outputID: artifact.id
                    )
                }
            }
        }
        .onReceive(navigation.$requestedTab) { tab in
            guard let tab else { return }
            applySidebarSelection(.tab(tab))
        }
        .onReceive(navigation.$requestedExtensionPageID) { pageID in
            guard let pageID else { return }
            applySidebarSelection(.extensionPage(pageID))
        }
        .onReceive(navigation.$requestedChatSessionID) { sessionID in
            guard let sessionID else { return }
            chat.reloadPersistedSessions()
            applySidebarSelection(.chat(sessionID))
        }
        .onChange(of: contentState.extensionSidebarContributions) { _, contributions in
            guard case .extensionPage(let pageID) = sidebarSelection,
                !contributions.contains(
                    where: { $0.id == pageID }
                )
            else {
                return
            }
            applySidebarSelection(.tab(.extensions))
        }
        .onReceive(navigation.$newChatRequest) { _ in
            handleNewChatRequest()
        }
        .onReceive(navigation.$toggleSidebarRequest) { _ in
            handleToggleSidebarRequest()
        }
        .onReceive(navigation.$collapseAllSectionsRequest) { _ in
            handleCollapseAllSectionsRequest()
        }
        .onReceive(navigation.$speechModelDiscoveryRequest) { request in
            speechModelDiscoveryRequest = request
        }
        .onReceive(navigation.$imageModelDiscoveryRequest) { request in
            imageModelDiscoveryRequest = request
        }
        .onReceive(navigation.$imageModelDiscoveryCapability) { capability in
            imageModelDiscoveryCapability = capability
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            launchAtLogin.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .routineDidSaveChatSession)) { _ in
            chat.reloadPersistedSessions()
        }
        .alert(
            "Unable to Update Start at Login",
            isPresented: Binding(
                get: { contentState.launchAtLoginErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        launchAtLogin.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                launchAtLogin.errorMessage = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(contentState.launchAtLoginErrorMessage ?? "An unknown error occurred.")
        }
    }

    private var controlPanelTopControls: some View {
        HStack(spacing: 0) {
            controlPanelTopButton(
                systemName: "sidebar.left",
                help: isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                action: toggleSidebarVisibility
            )

            Spacer(minLength: 0)

            if showsModelConfigurationToggle {
                controlPanelTopButton(
                    systemName: "sidebar.right",
                    help: isModelConfigurationVisible
                        ? "Hide model configuration"
                        : "Show model configuration",
                    action: toggleModelConfigurationVisibility
                )
            }
        }
        .padding(
            .leading,
            isFullScreen ? ControlPanelLayout.topControlsLeadingPaddingFullScreen : ControlPanelLayout.topControlsLeadingPadding
        )
        .padding(.trailing, ControlPanelLayout.topControlsTrailingPadding)
        .padding(.top, ControlPanelLayout.topControlsTopPadding)
        .ignoresSafeArea(.container, edges: .top)
    }

    private func controlPanelTopButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(
                    width: ControlPanelLayout.topControlSize,
                    height: ControlPanelLayout.topControlSize
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

#Preview {
    ControlPanelView(
        model: .init(),
        navigation: .init(),
        runtime: .init(),
        extensionManager: .init(builtInExtensions: []),
        softwareUpdater: .init(),
        dependencies: .init()
    )
}
