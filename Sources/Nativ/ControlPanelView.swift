import AppKit
import NativServerKit
import NativExtensionSDK
import SwiftUI
import UniformTypeIdentifiers

enum ControlPanelTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
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
            .artifacts,
            .dashboard,
            .system,
            .models,
            .extensions,
            .dev,
        ]
    }

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .chat:
            "bubble.left.and.bubble.right"
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
    @Published private(set) var newChatRequest = 0
    @Published private(set) var toggleSidebarRequest = 0
    @Published private(set) var speechModelDiscoveryRequest = 0
    @Published private(set) var imageModelDiscoveryRequest = 0
    @Published private(set) var imageModelDiscoveryCapability: LocalModelCapability = .imageGeneration
    @Published private(set) var collapseAllSectionsRequest = 0
    private var consumedNewChatRequest = 0
    private var consumedToggleSidebarRequest = 0
    private var consumedCollapseAllSectionsRequest = 0

    func open(_ tab: ControlPanelTab) {
        requestedExtensionPageID = nil
        requestedTab = tab
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

private enum FooterControl {
    case settings
    case support
    case server
    case reportIssue
}

private enum ControlPanelLayout {
    static let sidebarMinimumWidth: CGFloat = 220
    static let sidebarIdealWidth: CGFloat = 260
    static let sidebarMaximumWidth: CGFloat = 320
    static let detailMinimumWidth: CGFloat = 720
    static let titlebarHeight: CGFloat = 52
    static let collapsedSidebarTitleClearance: CGFloat = 108
    static let sidebarButtonLeadingPadding: CGFloat = 88
    static let modelConfigurationButtonTrailingPadding: CGFloat = 12
    static let collapseButtonSize: CGFloat = 30
    static let windowControlsLeadingPadding: CGFloat = 19
    static let windowControlsTopPadding: CGFloat = 9
    static let windowControlsWidth: CGFloat = 64
    static let windowControlsHeight: CGFloat = 28
    static let windowControlsCenterY =
        windowControlsTopPadding + (windowControlsHeight / 2)
    static let sidebarTransitionDuration: TimeInterval = 0.2
    static let sidebarTransitionSettleDuration: Duration = .milliseconds(225)
}

private enum ControlPanelOnboarding {
    static let extensionsBadgeDismissedKey =
        "nativ.control-panel.extensions-new-badge-dismissed.v1"
}

extension Color {
    static let nativMainContentBackground = Color(
        nsColor: NSColor(name: NSColor.Name("NativMainContentBackground")) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(
                    srgbRed: 24 / 255,
                    green: 24 / 255,
                    blue: 24 / 255,
                    alpha: 1
                )
            }

            return .windowBackgroundColor
        }
    )
}

/// A small pulsing download arrow shown at the trailing edge of the Models sidebar row
/// while a model is downloading.
private struct ModelsDownloadArrow: View {
    let count: Int
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.tint)
                .opacity(pulse ? 0.4 : 1.0)
                .animation(
                    .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.tint)
            }
        }
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        count == 1 ? "A model is downloading" : "\(count) models are downloading"
    }
}

private struct SidebarNavigationLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .frame(width: 24, alignment: .center)
            configuration.title
        }
    }
}

private struct GlobalModelLoadFailureBanner: View {
    let failure: ModelLoadFailure
    let onOpenModels: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(failure.title)
                    .font(.callout.weight(.semibold))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button("Open Models", action: onOpenModels)
                .buttonStyle(.bordered)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Dismiss model loading error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }
}

struct ControlPanelView: View {
    @Environment(\.displayScale) private var displayScale
    @ObservedObject var model: NativModel
    @ObservedObject var navigation: ControlPanelNavigation
    // Only the Developer page observes live runtime values. Keeping this as a
    // plain reference prevents its one-second polling cycle from invalidating
    // the entire control panel (including the Models result list).
    let runtime: SystemRuntimeMonitor
    @ObservedObject var extensionManager: NativExtensionManager
    let softwareUpdater: SoftwareUpdater
    @StateObject private var chat = ChatViewModel()
    @StateObject private var mcpHost = MCPHostManager()
    @StateObject private var imageGeneration = ImageGenerationViewModel()
    @StateObject private var artifacts = ArtifactStore()
    @StateObject private var dashboard = DashboardViewModel()
    @StateObject private var systemMonitor = SystemMonitorStore()
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @ObservedObject private var downloads = HuggingFaceDownloadManager.shared
    @StateObject private var embeddingLibrary = LocalModelLibrary()

    private static let embeddingModelID = "mlx-community/Qwen3-VL-Embedding-2B-bf16"
    private static let embeddingModelSize: Int64 = 4_300_000_000

    private var artifactSemanticSearch: ArtifactSemanticSearchConfig? {
        guard ProcessInfo.processInfo.physicalMemory >= 16_000_000_000 else {
            return nil
        }
        let settings = model.settings.normalized()
        let baseURL = URL(string: "http://127.0.0.1:\(settings.serverPort)")
            ?? URL(string: "http://127.0.0.1:8080")!
        let modelID = Self.embeddingModelID
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
                downloads.download(
                    repoID: modelID,
                    sizeBytes: Self.embeddingModelSize,
                    cachePath: settings.modelSearchPath,
                    token: model.effectiveHuggingFaceToken
                ) {
                    EmbeddingModelPreparer.prepare(
                        repoID: modelID,
                        searchPath: settings.modelSearchPath
                    )
                    embeddingLibrary.scan(searchPaths: settings.localModelSearchPaths)
                    NotificationCenter.default.post(name: .localModelLibraryDidChange, object: nil)
                }
                navigation.open(.models)
            },
            onRemove: {
                Task {
                    try? await LocalModelDiscovery.delete(
                        repoID: modelID,
                        path: settings.modelSearchPath
                    )
                    embeddingLibrary.scan(searchPaths: settings.localModelSearchPaths)
                    NotificationCenter.default.post(name: .localModelLibraryDidChange, object: nil)
                }
            },
            prepareModel: {
                EmbeddingModelPreparer.prepare(
                    repoID: modelID,
                    searchPath: settings.modelSearchPath
                )
            }
        )
    }
    @AppStorage(ControlPanelOnboarding.extensionsBadgeDismissedKey)
    private var isExtensionsBadgeDismissed = false
    @State private var sidebarSelection: ControlPanelSidebarSelection = .tab(.chat)
    @State private var selectedTab: ControlPanelTab = .chat
    @State private var chatWorkspaceMode: ChatWorkspaceMode = .chat
    @State private var hoveredFooterControl: FooterControl?
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarWidth = ControlPanelLayout.sidebarIdealWidth
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var isSidebarVisuallyVisible = true
    @State private var detailTransitionOffset: CGFloat = 0
    @State private var isSidebarTransitioning = false
    @State private var sidebarTransitionGeneration = 0
    @ObservedObject private var routineStore = RoutineStore.shared
    @StateObject private var routineModelLibrary = LocalModelLibrary()
    @State private var schedulingRoutineDraft: RoutineDraft?
    @State private var isModelConfigurationVisible = false
    @State private var selectedDevSection: DevHubView.Section = .integrations
    @State private var isFullScreen = false
    @State private var windowControlsRefreshTrigger = 0
    @State private var isNewChatHovering = false
    @State private var isSelectingRecents = false
    @State private var selectedRecentIDs: Set<ControlPanelRecentSession.ID> = []
    @State private var selectedFolderIDs: Set<UUID> = []
    @State private var isPinnedDropTargeted = false
    @State private var isSessionsDropTargeted = false
    @State private var reorderTargetID: ControlPanelRecentSession.ID?
    @State private var reorderInsertAfter = false
    @State private var isFoldersDropTargeted = false
    @State private var pendingDeleteRecent: ControlPanelRecentSession?
    @State private var pendingDeleteFolder: ChatFolder?
    @State private var isConfirmingBulkDelete = false

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(
                        width: splitColumnVisibility == .detailOnly
                            ? 0
                            : sidebarWidth
                    )

                detail
                    .frame(
                        minWidth: ControlPanelLayout.detailMinimumWidth,
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                    .clipped()
                    .offset(x: detailTransitionOffset)
            }
            .animation(nil, value: splitColumnVisibility)

            resizableSidebar
                .compositingGroup()
                .offset(
                    x: isSidebarVisuallyVisible
                        ? 0
                        : -(sidebarWidth + 5)
                )
                .allowsHitTesting(isSidebarVisuallyVisible)
                .accessibilityHidden(!isSidebarVisuallyVisible)
        }
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1040, minHeight: 600)
        .overlay(alignment: .top) {
            Group {
                if selectedTab != .models, let failure = model.modelLoadFailure {
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
        .background {
            ZStack {
                ControlPanelWindowStateReader(isFullScreen: $isFullScreen)
                ControlPanelWindowControls(refreshTrigger: windowControlsRefreshTrigger)
                ControlPanelCollapseButtons(
                    showsModelConfigurationButton: showsModelConfigurationToggle,
                    sidebarHelp: isSidebarVisuallyVisible
                        ? "Hide Sidebar"
                        : "Show Sidebar",
                    modelConfigurationHelp: isModelConfigurationVisible
                        ? "Hide model configuration"
                        : "Show model configuration",
                    onToggleSidebar: toggleSidebarVisibility,
                    onToggleModelConfiguration: toggleModelConfigurationVisibility
                )
            }
            .frame(width: 0, height: 0)
        }
        .onAppear {
            applySidebarSelection(navigation.requestedTab.map(ControlPanelSidebarSelection.tab) ?? sidebarSelection)
            handleNewChatRequest()
            embeddingLibrary.scan(searchPaths: model.settings.localModelSearchPaths)
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
        .onChange(of: extensionManager.records) { _, _ in
            guard case .extensionPage(let pageID) = sidebarSelection,
                  !extensionManager.enabledSidebarContributions.contains(
                    where: { $0.id == pageID }
                  ) else {
                return
            }
            applySidebarSelection(.tab(.extensions))
        }
        .onChange(of: navigation.newChatRequest) { _, _ in
            handleNewChatRequest()
        }
        .onChange(of: navigation.toggleSidebarRequest) { _, _ in
            handleToggleSidebarRequest()
        }
        .onChange(of: navigation.collapseAllSectionsRequest) { _, _ in
            handleCollapseAllSectionsRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            windowControlsRefreshTrigger += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
            windowControlsRefreshTrigger += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
        .alert(
            "Unable to Update Start at Login",
            isPresented: Binding(
                get: { launchAtLogin.errorMessage != nil },
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
            Text(launchAtLogin.errorMessage ?? "An unknown error occurred.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: ControlPanelLayout.titlebarHeight)

            sidebarNavigation
                .padding(.horizontal, 10)
                .padding(.bottom, 5)

            if isSelectingRecents {
                bulkSelectionBar
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            } else {
                sidebarActionBar
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showsPinnedSection {
                        pinnedSection
                    }
                    if showsFoldersSection {
                        foldersSection
                    }
                    sessionsSection
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: sidebarSeparatorThickness)

            HStack(spacing: 4) {
                settingsButton
                supportButton
                serverToggleButton
                issueReportMenu
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .navigationTitle("Nativ")
        .background(
            ControlPanelSurfaceReader(
                isFullScreen: isFullScreen
            )
        )
        .alert(
            "Delete chat?",
            isPresented: Binding(
                get: { pendingDeleteRecent != nil },
                set: { if !$0 { pendingDeleteRecent = nil } }
            ),
            presenting: pendingDeleteRecent
        ) { recent in
            Button("Delete", role: .destructive) {
                deleteRecentSession(recent)
                pendingDeleteRecent = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingDeleteRecent = nil
            }
        } message: { recent in
            if case .chat(let sessionID) = recent.selection,
               let routine = routineStore.routine(forSession: sessionID) {
                Text("“\(recent.title)” has a routine (\(RoutineFormatting.summary(routine))). Deleting the chat cancels the routine.")
            } else {
                Text("“\(recent.title)” will be permanently deleted.")
            }
        }
        .alert(
            "Delete folder?",
            isPresented: Binding(
                get: { pendingDeleteFolder != nil },
                set: { if !$0 { pendingDeleteFolder = nil } }
            ),
            presenting: pendingDeleteFolder
        ) { folder in
            Button("Delete", role: .destructive) {
                chat.deleteFolder(folder.id)
                pendingDeleteFolder = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingDeleteFolder = nil
            }
        } message: { folder in
            Text("“\(folder.name)” will be removed. Its chats will be moved out, not deleted.")
        }
        .alert(
            "Delete \(selectedRecentIDs.count + selectedFolderIDs.count) items?",
            isPresented: $isConfirmingBulkDelete
        ) {
            Button("Delete", role: .destructive) {
                bulkDeleteSelected()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected chats are permanently deleted. Selected folders are removed but their chats are kept.")
        }
        .sheet(item: $schedulingRoutineDraft) { draft in
            let textModelIDs = routineModelLibrary.models
                .filter { $0.capabilities.contains(.text) }
                .map(\.repoID)
            let snapshotModelID = draft.routine.modelID
            let availableModelIDs = (
                snapshotModelID.isEmpty || textModelIDs.contains(snapshotModelID)
                    ? textModelIDs
                    : textModelIDs + [snapshotModelID]
            ).sorted()
            let isExistingRoutine = RoutineStore.shared.routine(id: draft.routine.id) != nil
            RoutineEditor(
                draft: draft,
                availableModelIDs: availableModelIDs,
                onSave: { routine in
                    saveScheduledRoutine(routine)
                    schedulingRoutineDraft = nil
                },
                onCancel: { schedulingRoutineDraft = nil },
                onDelete: isExistingRoutine ? {
                    RoutineStore.shared.delete(id: draft.routine.id)
                    schedulingRoutineDraft = nil
                } : nil
            )
        }
    }

    private var resizableSidebar: some View {
        sidebar
            .frame(width: sidebarWidth)
            .background {
                Group {
                    if isSidebarTransitioning {
                        Rectangle()
                            .fill(Color(nsColor: .windowBackgroundColor))
                    } else if isFullScreen {
                        Rectangle()
                            .fill(.regularMaterial)
                    } else {
                        Color.clear
                            .glassEffect(.regular, in: Rectangle())
                    }
                }
                    .ignoresSafeArea(.container, edges: [.top, .bottom, .leading])
            }
            .overlay(alignment: .trailing) {
                sidebarResizeHandle
            }
            .zIndex(1)
    }

    private var sidebarResizeHandle: some View {
        ZStack {
            Color.clear

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: sidebarSeparatorThickness)
        }
        .frame(width: 9)
        .contentShape(Rectangle())
        .offset(x: 4)
        .onHover { isHovering in
            (isHovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if sidebarDragStartWidth == nil {
                        sidebarDragStartWidth = sidebarWidth
                    }

                    let startWidth = sidebarDragStartWidth ?? sidebarWidth
                    let proposedWidth = startWidth + value.translation.width
                    sidebarWidth = min(
                        max(proposedWidth, ControlPanelLayout.sidebarMinimumWidth),
                        ControlPanelLayout.sidebarMaximumWidth
                    )
                }
                .onEnded { _ in
                    sidebarDragStartWidth = nil
                    NSCursor.arrow.set()
                }
        )
    }

    private var sidebarSeparatorThickness: CGFloat {
        1 / max(displayScale, 1)
    }

    private var sidebarNavigation: some View {
        VStack(spacing: 0) {
            ForEach(ControlPanelTab.allCases) { tab in
                sidebarTabButton(tab)

                if tab == .chat {
                    ForEach(extensionManager.enabledSidebarContributions) { contribution in
                        extensionSidebarButton(contribution)
                    }
                }
            }
        }
    }

    private func sidebarTabButton(_ tab: ControlPanelTab) -> some View {
        let selection = ControlPanelSidebarSelection.tab(tab)
        return Button {
            applySidebarSelection(selection)
        } label: {
            HStack(spacing: 8) {
                Label(tab.rawValue, systemImage: tab.systemImage)
                    .labelStyle(SidebarNavigationLabelStyle())
                if tab == .extensions, !isExtensionsBadgeDismissed {
                    Text("NEW")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
                Spacer(minLength: 0)
                if tab == .models {
                    HStack(spacing: 6) {
                        if model.isModelLoading,
                           let percentage = model.modelLoadingPercentageText {
                            Text(percentage)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                        if downloads.activeCount > 0 {
                            ModelsDownloadArrow(count: downloads.activeCount)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .sidebarRowSelectionStyle(isSelected: sidebarSelection == selection)
        .buttonStyle(.plain)
    }

    private func extensionSidebarButton(
        _ contribution: NativSidebarContribution
    ) -> some View {
        let selection = ControlPanelSidebarSelection.extensionPage(contribution.id)
        return Button {
            applySidebarSelection(selection)
        } label: {
            Label(contribution.title, systemImage: contribution.systemImage)
                .labelStyle(SidebarNavigationLabelStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .sidebarRowSelectionStyle(isSelected: sidebarSelection == selection)
        .buttonStyle(.plain)
    }

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarPinnedHeader
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .padding(.bottom, 4)

            if !model.settings.sidebarPinnedCollapsed {
                Group {
                    if pinnedSessions.isEmpty && pinnedFolders.isEmpty {
                        emptyPinnedHint
                    } else {
                        ForEach(pinnedFolders) { folder in
                            folderView(folder, dropTargeted: isPinnedDropTargeted)
                        }
                        ForEach(pinnedSessions) { recent in
                            draggableRow(recent, isPinnedRow: true)
                                .overlay(alignment: .top) {
                                    pinnedInsertionLine(visible: reorderTargetID == recent.id && !reorderInsertAfter && isPinnedDropTargeted)
                                }
                                .overlay(alignment: .bottom) {
                                    pinnedInsertionLine(visible: reorderTargetID == recent.id && reorderInsertAfter && isPinnedDropTargeted)
                                }
                        }
                    }
                }
                .transition(.slide)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dropHighlight(isTargeted: isPinnedDropTargeted))
        .onDrop(of: [.text], isTargeted: $isPinnedDropTargeted) { providers in
            loadDropString(providers) { payload in
                revealSidebarSection(\.sidebarPinnedCollapsed)
                handlePinnedDrop(payload)
            }
        }
    }

    private var showsPinnedSection: Bool {
        isSelectingRecents || !pinnedSessions.isEmpty || !pinnedFolders.isEmpty
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarRecentsHeader
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .padding(.top, showsPinnedSection || showsFoldersSection ? 12 : 0)
                .padding(.bottom, 4)

            if !model.settings.sidebarSessionsCollapsed {
                ForEach(ungroupedSessions) { recent in
                    draggableRow(recent, isPinnedRow: false)
                        .overlay(alignment: .top) {
                            pinnedInsertionLine(visible: reorderTargetID == recent.id && !reorderInsertAfter && isSessionsDropTargeted)
                        }
                        .overlay(alignment: .bottom) {
                            pinnedInsertionLine(visible: reorderTargetID == recent.id && reorderInsertAfter && isSessionsDropTargeted)
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dropHighlight(isTargeted: isSessionsDropTargeted))
        .onDrop(of: [.text], isTargeted: $isSessionsDropTargeted) { providers in
            loadDropString(providers) { payload in
                revealSidebarSection(\.sidebarSessionsCollapsed)
                _ = handleSessionsDrop([payload])
            }
        }
    }

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarFoldersHeader
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .padding(.top, 12)
                .padding(.bottom, 4)

            if !model.settings.sidebarFoldersCollapsed {
                if unpinnedFolders.isEmpty {
                    emptyFoldersHint
                } else {
                    ForEach(unpinnedFolders) { folder in
                        folderView(folder, dropTargeted: isFoldersDropTargeted)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dropHighlight(isTargeted: isFoldersDropTargeted))
        .onDrop(of: [.text], isTargeted: $isFoldersDropTargeted) { _ in false }
    }

    private var showsFoldersSection: Bool {
        isSelectingRecents || !unpinnedFolders.isEmpty
    }

    private var emptyFoldersHint: some View {
        Label("No folders yet — tap + to add one", systemImage: "folder")
            .font(.system(size: 13))
            .foregroundStyle(.secondary.opacity(0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
    }

    @ViewBuilder
    private func folderView(_ folder: ChatFolder, dropTargeted: Bool) -> some View {
        ControlPanelFolderHeaderView(
            folder: folder,
            count: sessions(inFolder: folder.id).count,
            isSelecting: isSelectingRecents,
            isChecked: selectedFolderIDs.contains(folder.id),
            onToggleCollapse: {
                chat.setFolderCollapsed(folder.id, collapsed: !folder.isCollapsed)
            },
            onRename: { chat.renameFolder(folder.id, to: $0) },
            onTogglePin: {
                chat.setFolderPinned(folder.id, pinned: !folder.isPinned)
            },
            onToggleSelect: {
                toggleFolderSelection(folder.id)
            },
            onExport: {
                exportFolder(folder)
            },
            onDelete: {
                pendingDeleteFolder = folder
            }
        )
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .onDrag {
            NSItemProvider(object: "folder:\(folder.id.uuidString)" as NSString)
        }
        .onDrop(of: [.text], delegate: FolderDropDelegate(
            onChatDrop: { chatID in
                chat.moveSession(chatID, toFolder: folder.id)
            },
            onFolderDrop: { draggedFolderID in
                handleFolderReorder(dragged: draggedFolderID, target: folder.id)
            }
        ))

        if !folder.isCollapsed {
            ForEach(sessions(inFolder: folder.id)) { recent in
                folderChatRow(recent, folderID: folder.id)
                    .overlay(alignment: .top) {
                        pinnedInsertionLine(visible: reorderTargetID == recent.id && !reorderInsertAfter && dropTargeted)
                    }
                    .overlay(alignment: .bottom) {
                        pinnedInsertionLine(visible: reorderTargetID == recent.id && reorderInsertAfter && dropTargeted)
                    }
                    .padding(.leading, 12)
            }
        }
    }

    @ViewBuilder
    private func folderChatRow(_ recent: ControlPanelRecentSession, folderID: UUID) -> some View {
        if let payload = recent.dragPayload, !isSelectingRecents {
            recentSessionRow(recent)
                .onDrag {
                    NSItemProvider(object: payload as NSString)
                } preview: {
                    dragPreview(recent)
                }
                .onDrop(of: [.text], delegate: RowReorderDropDelegate(
                    targetID: recent.id,
                    setTarget: { id, after in
                        if reorderTargetID != id || reorderInsertAfter != after {
                            reorderTargetID = id
                            reorderInsertAfter = after
                        }
                    },
                    onDrop: { draggedPayload, after in
                        handleFolderRowDrop(
                            draggedPayload: draggedPayload,
                            target: recent,
                            insertAfter: after,
                            folderID: folderID
                        )
                    }
                ))
        } else {
            recentSessionRow(recent)
        }
    }

    private var emptyPinnedHint: some View {
        Label("Drag a chat here to pin", systemImage: "pin")
            .font(.system(size: 13))
            .foregroundStyle(.secondary.opacity(0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            .contentShape(.rect)
    }

    private func dropHighlight(isTargeted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accentColor.opacity(isTargeted ? 0.08 : 0))
    }

    @ViewBuilder
    private func draggableRow(
        _ recent: ControlPanelRecentSession,
        isPinnedRow: Bool
    ) -> some View {
        if let payload = recent.dragPayload, !isSelectingRecents {
            recentSessionRow(recent)
                .onDrag {
                    NSItemProvider(object: payload as NSString)
                } preview: {
                    dragPreview(recent)
                }
                .onDrop(of: [.text], delegate: RowReorderDropDelegate(
                    targetID: recent.id,
                    setTarget: { id, after in
                        if reorderTargetID != id || reorderInsertAfter != after {
                            reorderTargetID = id
                            reorderInsertAfter = after
                        }
                    },
                    onDrop: { draggedPayload, after in
                        handleRowDrop(
                            draggedPayload: draggedPayload,
                            target: recent,
                            insertAfter: after,
                            isPinnedRow: isPinnedRow
                        )
                    }
                ))
        } else {
            recentSessionRow(recent)
        }
    }

    private func handleRowDrop(
        draggedPayload: String,
        target: ControlPanelRecentSession,
        insertAfter: Bool,
        isPinnedRow: Bool
    ) {
        guard let draggedID = UUID(uuidString: draggedPayload),
              chat.sessions.contains(where: { $0.id == draggedID }),
              let targetID = target.chatID,
              draggedID != targetID
        else {
            return
        }
        var order = (isPinnedRow ? pinnedSessions : unpinnedSessions).compactMap(\.chatID)
        order.removeAll { $0 == draggedID }
        if let index = order.firstIndex(of: targetID) {
            order.insert(draggedID, at: insertAfter ? index + 1 : index)
        } else {
            order.append(draggedID)
        }
        reorderTargetID = nil
        reorderInsertAfter = false
        if isPinnedRow {
            chat.applyPinnedOrder(order)
        } else {
            chat.applySessionOrder(order)
        }
    }

    private func handleFolderRowDrop(
        draggedPayload: String,
        target: ControlPanelRecentSession,
        insertAfter: Bool,
        folderID: UUID
    ) {
        reorderTargetID = nil
        reorderInsertAfter = false
        guard let draggedID = UUID(uuidString: draggedPayload),
              chat.sessions.contains(where: { $0.id == draggedID }),
              let targetID = target.chatID,
              draggedID != targetID
        else {
            return
        }
        var order = sessions(inFolder: folderID).compactMap(\.chatID)
        order.removeAll { $0 == draggedID }
        if let index = order.firstIndex(of: targetID) {
            order.insert(draggedID, at: insertAfter ? index + 1 : index)
        } else {
            order.append(draggedID)
        }
        chat.moveSession(draggedID, toFolder: folderID)
        chat.applySessionOrder(order)
    }

    @discardableResult
    private func loadDropString(
        _ providers: [NSItemProvider],
        _ handler: @escaping (String) -> Void
    ) -> Bool {
        guard let provider = providers.first else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            if let string = object as? String, !string.isEmpty {
                DispatchQueue.main.async { handler(string) }
            }
        }
        return true
    }

    private func pinnedInsertionLine(visible: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 8)
            .opacity(visible ? 1 : 0)
    }

    private func dragPreview(_ recent: ControlPanelRecentSession) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left")
                .font(.system(size: 11))
            Text(recent.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
    }

    private var sidebarActionBar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    enterSelectMode()
                }
            } label: {
                Image(systemName: "checklist")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 26, height: 28)
                    .foregroundStyle(Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .disabled(recentSessions.isEmpty && chat.folders.isEmpty)
            .help("Select multiple")

            Menu {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        createRecentSession()
                    }
                } label: {
                    Label(newRecentTitle, systemImage: newRecentSystemImage)
                }
                Button {
                    presentNewRoutine()
                } label: {
                    Label("New routine", systemImage: "bolt")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(isNewChatHovering ? Color.primary : Color.secondary.opacity(0.7))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(
                selectedTab == .chat
                    && chatWorkspaceMode == .images
                    && imageGeneration.isGenerating
            )
            .help(newRecentHelp)
            .onHover { isNewChatHovering = $0 }
        }
    }

    private var bulkSelectionBar: some View {
        HStack(spacing: 6) {
            Text(bulkSelectionTitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                bulkTogglePinSelected()
            } label: {
                Image(systemName: allSelectedPinned ? "pin.slash" : "pin")
                    .frame(width: 24, height: 22)
            }
            .help(allSelectedPinned ? "Unpin selected" : "Pin selected")
            .disabled(!hasSelectedPinnable)

            Button {
                bulkExportSelected()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 24, height: 22)
            }
            .help("Export selected")
            .disabled(!hasSelectedChats)

            Button(role: .destructive) {
                isConfirmingBulkDelete = true
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 22)
            }
            .help("Delete selected")
            .disabled(selectedRecentIDs.isEmpty && selectedFolderIDs.isEmpty)

            Button("Done") {
                withAnimation(.snappy(duration: 0.2)) {
                    exitSelectMode()
                }
            }
            .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func sidebarSectionHeader<Trailing: View>(
        title: String,
        isCollapsed: Bool,
        onToggle: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.7))

                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .frame(width: 12)

                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) {
                    onToggle()
                }
            }
            .help(isCollapsed ? "Expand \(title)" : "Collapse \(title)")

            trailing()
        }
    }

    private var sidebarPinnedHeader: some View {
        sidebarSectionHeader(
            title: "Pinned",
            isCollapsed: model.settings.sidebarPinnedCollapsed,
            onToggle: { model.settings.sidebarPinnedCollapsed.toggle() }
        ) {
            EmptyView()
        }
    }

    private var sidebarFoldersHeader: some View {
        sidebarSectionHeader(
            title: "Folders",
            isCollapsed: model.settings.sidebarFoldersCollapsed,
            onToggle: { model.settings.sidebarFoldersCollapsed.toggle() }
        ) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    model.settings.sidebarFoldersCollapsed = false
                    _ = chat.createFolder(name: "New Folder")
                }
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("New folder")
        }
    }

    private var sidebarRecentsHeader: some View {
        sidebarSectionHeader(
            title: "Sessions",
            isCollapsed: model.settings.sidebarSessionsCollapsed,
            onToggle: { model.settings.sidebarSessionsCollapsed.toggle() }
        ) {
            EmptyView()
        }
    }

    private var allSidebarSectionsCollapsed: Bool {
        model.settings.allSidebarSectionsCollapsed
            && !chat.folders.contains { !$0.isCollapsed }
    }

    private func revealSidebarSection(_ keyPath: WritableKeyPath<NativSettings, Bool>) {
        guard model.settings[keyPath: keyPath] else {
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            model.settings[keyPath: keyPath] = false
        }
    }

    private func toggleAllSidebarSections() {
        let shouldCollapse = !allSidebarSectionsCollapsed
        withAnimation(.snappy(duration: 0.2)) {
            model.settings.setAllSidebarSectionsCollapsed(shouldCollapse)
            chat.setAllFoldersCollapsed(shouldCollapse)
        }
    }

    private func toggleSidebarVisibility() {
        let willShowSidebar = !isSidebarVisuallyVisible
        sidebarTransitionGeneration &+= 1
        let transitionGeneration = sidebarTransitionGeneration
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isSidebarTransitioning = true
            splitColumnVisibility = willShowSidebar ? .all : .detailOnly
            detailTransitionOffset = willShowSidebar ? -sidebarWidth : sidebarWidth
        }
        withAnimation(.smooth(duration: ControlPanelLayout.sidebarTransitionDuration)) {
            isSidebarVisuallyVisible = willShowSidebar
            detailTransitionOffset = 0
        }

        Task { @MainActor in
            try? await Task.sleep(for: ControlPanelLayout.sidebarTransitionSettleDuration)
            guard sidebarTransitionGeneration == transitionGeneration else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isSidebarTransitioning = false
            }
        }
    }

    private func toggleModelConfigurationVisibility() {
        isModelConfigurationVisible.toggle()
    }

    private var showsModelConfigurationToggle: Bool {
        switch selectedTab {
        case .chat:
            chatWorkspaceMode == .chat
        case .models:
            true
        case .dev:
            selectedDevSection == .developer
        case .artifacts, .dashboard, .system, .extensions, .settings:
            false
        }
    }

    private var issueReportMenu: some View {
        footerControl(.reportIssue, tooltip: "Report an Issue") {
            Menu {
                ForEach(IssueReportCategory.allCases) { category in
                    Button {
                        reportIssue(category: category)
                    } label: {
                        Label(category.displayName, systemImage: category.systemImage)
                    }
                }
            } label: {
                footerIcon(systemName: "ladybug")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(.secondary)
            .foregroundStyle(.secondary)
        }
    }

    private var settingsButton: some View {
        footerControl(.settings, tooltip: "Settings") {
            Button {
                applySidebarSelection(.tab(.settings))
            } label: {
                footerIcon(systemName: "gearshape")
            }
            .buttonStyle(.plain)
        }
    }

    private var serverToggleButton: some View {
        footerControl(
            .server,
            tooltip: model.isRunning ? "Stop Server" : "Start Server"
        ) {
            Button {
                model.toggleServer()
            } label: {
                footerIcon(systemName: model.isRunning ? "stop.circle" : "play.circle")
            }
            .buttonStyle(.plain)
            .disabled(model.modelSwitchInProgress)
        }
    }

    private var supportButton: some View {
        footerControl(.support, tooltip: "Star Nativ on GitHub") {
            Button {
                guard let url = URL(string: "https://github.com/Blaizzy/nativ") else {
                    return
                }
                NSWorkspace.shared.open(url)
            } label: {
                footerIcon(
                    systemName: hoveredFooterControl == .support ? "heart.fill" : "heart"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func footerIcon(
        systemName: String
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    private func footerControl<Content: View>(
        _ control: FooterControl,
        tooltip: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(width: 40, height: 40)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hoveredFooterControl == control ? 0.08 : 0))
            }
            .overlay {
                FooterControlTrackingView(
                    tooltip: tooltip,
                    onHover: { isHovering in
                        updateFooterHover(control, isHovering: isHovering)
                    }
                )
            }
            .contentShape(Rectangle())
            .accessibilityLabel(tooltip)
            .animation(.easeOut(duration: 0.12), value: hoveredFooterControl == control)
    }

    private func updateFooterHover(_ control: FooterControl, isHovering: Bool) {
        if isHovering {
            hoveredFooterControl = control
        } else if hoveredFooterControl == control {
            hoveredFooterControl = nil
        }
    }

    private func reportIssue(category: IssueReportCategory) {
        let body = IssueReportBuilder.markdown(
            category: category,
            details: "",
            sections: IssueDiagnostics.collect(category: category, model: model, runtime: runtime),
            serverOutput: IssueDiagnostics.serverOutputTail(model: model)
        )
        let clipboard = (category == .crash ? IssueDiagnostics.latestCrashRawReport() : nil)
            ?? (body.count > IssueReportBuilder.urlBodyCharacterBudget ? body : nil)
        if let clipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(clipboard, forType: .string)
        }
        guard let url = IssueReportBuilder.githubIssueURL(
            title: "",
            label: category.githubLabel,
            body: body
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private var recentSessions: [ControlPanelRecentSession] {
        (
            chat.sessions.map(ControlPanelRecentSession.init(chat:))
                + imageGeneration.sessions.map(ControlPanelRecentSession.init(imageGeneration:))
        )
            .sorted(by: ControlPanelRecentSession.recencySort)
    }

    private var pinnedSessions: [ControlPanelRecentSession] {
        recentSessions
            .filter(\.pinned)
            .sorted(by: ControlPanelRecentSession.pinnedSort)
    }

    private var unpinnedSessions: [ControlPanelRecentSession] {
        recentSessions.filter { !$0.pinned }.sorted(by: ControlPanelRecentSession.sessionSort)
    }

    private var ungroupedSessions: [ControlPanelRecentSession] {
        let folderIDs = Set(chat.folders.map(\.id))
        return unpinnedSessions.filter { recent in
            guard let folderID = recent.folderID else {
                return true
            }
            return !folderIDs.contains(folderID)
        }
    }

    private var pinnedFolders: [ChatFolder] {
        chat.folders.filter(\.isPinned)
    }

    private var unpinnedFolders: [ChatFolder] {
        chat.folders.filter { !$0.isPinned }
    }

    private func sessions(inFolder folderID: UUID) -> [ControlPanelRecentSession] {
        recentSessions
            .filter { !$0.pinned && $0.folderID == folderID }
            .sorted(by: ControlPanelRecentSession.sessionSort)
    }

    @ViewBuilder
    private func recentSessionRow(_ recent: ControlPanelRecentSession) -> some View {
        ControlPanelRecentSessionRow(
            recent: recent,
            routineStatus: routineStatus(for: recent),
            isSelected: sidebarSelection == recent.selection,
            isCurrent: isCurrentRecent(recent),
            isActive: isRecentActive(recent),
            isSelectionDisabled: isRecentSelectionDisabled(recent),
            isDeleteDisabled: isRecentDeleteDisabled(recent),
            canExport: canExportRecent(recent),
            isSelecting: isSelectingRecents,
            isChecked: selectedRecentIDs.contains(recent.id),
            onToggleSelect: {
                toggleRecentSelection(recent)
            },
            onSelect: {
                applySidebarSelection(recent.selection)
            },
            onDelete: {
                pendingDeleteRecent = recent
            },
            onCopyConversation: {
                copyRecentConversation(recent)
            },
            onExportFile: {
                exportRecentConversation(recent)
            },
            onRevealInFinder: {
                revealRecentSession(recent)
            },
            onRename: { newTitle in
                renameRecentSession(recent, to: newTitle)
            },
            onNewChat: {
                createChatSession()
            },
            onTogglePin: {
                togglePinRecent(recent)
            },
            onScheduleRoutine: {
                scheduleRoutine(from: recent)
            },
            folders: chat.folders,
            onMoveToFolder: { folderID in
                moveRecentToFolder(recent, folderID: folderID)
            },
            onCreateFolderForSession: {
                createFolderForRecent(recent)
            }
        )
    }

    private func togglePinRecent(_ recent: ControlPanelRecentSession) {
        guard case .chat(let sessionID) = recent.selection else {
            return
        }
        chat.setPinned(sessionID, pinned: !recent.pinned)
    }

    private func routineStatus(for recent: ControlPanelRecentSession) -> RoutineRowStatus {
        guard case .chat(let sessionID) = recent.selection,
              let routine = routineStore.routine(forSession: sessionID)
        else {
            return .none
        }
        if routineStore.isRoutineRunning(forSession: sessionID) {
            return .running
        }
        return routine.isEnabled ? .scheduled : .disabled
    }

    private func scheduleRoutine(from recent: ControlPanelRecentSession) {
        guard case .chat(let sessionID) = recent.selection else {
            return
        }
        let settings = model.settings.normalized()
        routineModelLibrary.scan(searchPaths: settings.localModelSearchPaths)
        if let existing = RoutineStore.shared.routine(forSession: sessionID) {
            schedulingRoutineDraft = RoutineDraft(routine: existing)
            return
        }
        guard let session = ChatSessionStore().loadSession(id: sessionID) else {
            return
        }
        let instructions = session.messages.last { $0.role == .user }?.content ?? ""
        let modelID = session.messages
            .last { $0.role == .assistant && !($0.modelID ?? "").isEmpty }?
            .modelID
            ?? settings.languageModelID
            ?? ""
        schedulingRoutineDraft = RoutineDraft(
            routine: Routine(
                name: recent.title,
                instructions: instructions,
                modelID: modelID,
                triggerKind: .schedule,
                sourceSessionID: sessionID
            )
        )
    }

    private func presentNewRoutine() {
        let settings = model.settings.normalized()
        routineModelLibrary.scan(searchPaths: settings.localModelSearchPaths)
        schedulingRoutineDraft = RoutineDraft(
            routine: Routine(modelID: settings.languageModelID ?? "")
        )
    }

    private func saveScheduledRoutine(_ routine: Routine) {
        var routine = routine
        if routine.sourceSessionID == nil {
            let now = Date()
            let session = ChatSession(
                id: UUID(),
                title: routine.name.isEmpty ? "Routine" : routine.name,
                createdAt: now,
                updatedAt: now,
                messages: []
            )
            ChatSessionStore().saveSession(session)
            routine.sourceSessionID = session.id
        }
        RoutineStore.shared.upsert(routine)
        NotificationCenter.default.post(name: .routineDidSaveChatSession, object: nil)
    }

    private func moveRecentToFolder(_ recent: ControlPanelRecentSession, folderID: UUID?) {
        guard case .chat(let sessionID) = recent.selection else {
            return
        }
        chat.moveSession(sessionID, toFolder: folderID)
    }

    private func createFolderForRecent(_ recent: ControlPanelRecentSession) {
        guard case .chat(let sessionID) = recent.selection else {
            return
        }
        let folderID = chat.createFolder(name: "New Folder")
        chat.moveSession(sessionID, toFolder: folderID)
    }

    private func draggedChatID(from items: [String]) -> UUID? {
        for item in items {
            if let id = UUID(uuidString: item),
               chat.sessions.contains(where: { $0.id == id }) {
                return id
            }
        }
        return nil
    }

    private func handlePinnedDrop(_ item: String) {
        if item.hasPrefix("folder:") {
            if let id = UUID(uuidString: String(item.dropFirst("folder:".count))) {
                chat.setFolderPinned(id, pinned: true)
            }
            return
        }
        _ = handlePinDrop([item])
    }

    private func handlePinDrop(_ items: [String]) -> Bool {
        guard let draggedID = draggedChatID(from: items) else {
            return false
        }
        var order = pinnedSessions.compactMap(\.chatID)
        guard !order.contains(draggedID) else {
            return false
        }
        order.append(draggedID)
        reorderTargetID = nil
        reorderInsertAfter = false
        chat.applyPinnedOrder(order)
        return true
    }

    private func handleSessionsDrop(_ items: [String]) -> Bool {
        guard let draggedID = draggedChatID(from: items) else {
            return false
        }
        reorderTargetID = nil
        reorderInsertAfter = false
        if pinnedSessions.contains(where: { $0.chatID == draggedID }) {
            chat.setPinned(draggedID, pinned: false)
        }
        chat.moveSession(draggedID, toFolder: nil)
        return true
    }

    private func handleFolderReorder(dragged: UUID, target: UUID) {
        guard dragged != target else {
            return
        }
        var order = chat.folders.map(\.id)
        order.removeAll { $0 == dragged }
        if let index = order.firstIndex(of: target) {
            order.insert(dragged, at: index)
        } else {
            order.append(dragged)
        }
        chat.applyFolderOrder(order)
    }

    private func enterSelectMode() {
        selectedRecentIDs = []
        selectedFolderIDs = []
        isSelectingRecents = true
    }

    private func exitSelectMode() {
        isSelectingRecents = false
        selectedRecentIDs = []
        selectedFolderIDs = []
    }

    private func toggleRecentSelection(_ recent: ControlPanelRecentSession) {
        if selectedRecentIDs.contains(recent.id) {
            selectedRecentIDs.remove(recent.id)
        } else {
            selectedRecentIDs.insert(recent.id)
        }
    }

    private func toggleFolderSelection(_ folderID: UUID) {
        if selectedFolderIDs.contains(folderID) {
            selectedFolderIDs.remove(folderID)
        } else {
            selectedFolderIDs.insert(folderID)
        }
    }

    private var selectedChats: [ControlPanelRecentSession] {
        recentSessions.filter { $0.isChat && selectedRecentIDs.contains($0.id) }
    }

    private var hasSelectedChats: Bool {
        !selectedChats.isEmpty
    }

    private var selectedFolders: [ChatFolder] {
        chat.folders.filter { selectedFolderIDs.contains($0.id) }
    }

    private var hasSelectedPinnable: Bool {
        !selectedChats.isEmpty || !selectedFolders.isEmpty
    }

    private var allSelectedPinned: Bool {
        hasSelectedPinnable
            && selectedChats.allSatisfy(\.pinned)
            && selectedFolders.allSatisfy(\.isPinned)
    }

    private var bulkSelectionTitle: String {
        let count = selectedRecentIDs.count + selectedFolderIDs.count
        return count == 0 ? "Select items" : "\(count) selected"
    }

    private func bulkTogglePinSelected() {
        let shouldPin = !allSelectedPinned
        let chatIDs = selectedChats.compactMap(\.chatID)
        let folderIDs = selectedFolders.map(\.id)
        guard !chatIDs.isEmpty || !folderIDs.isEmpty else {
            return
        }
        for id in chatIDs {
            chat.setPinned(id, pinned: shouldPin)
        }
        for id in folderIDs {
            chat.setFolderPinned(id, pinned: shouldPin)
        }
        exitSelectMode()
    }

    private func bulkExportSelected() {
        let chats = selectedChats
        guard !chats.isEmpty else {
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let directory = panel.url else {
            return
        }
        for recent in chats {
            guard case .chat(let sessionID) = recent.selection,
                  let text = chat.conversationText(for: sessionID) else {
                continue
            }
            let url = uniqueExportURL(in: directory, title: recent.title)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        exitSelectMode()
    }

    private func uniqueExportURL(in directory: URL, title: String) -> URL {
        let separators = CharacterSet(charactersIn: "/:")
        let sanitized = title.components(separatedBy: separators).joined(separator: "-")
        let base = sanitized.isEmpty ? "Chat" : sanitized
        var candidate = directory.appendingPathComponent("\(base).txt")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(counter).txt")
            counter += 1
        }
        return candidate
    }

    private func bulkDeleteSelected() {
        let targets = recentSessions.filter { selectedRecentIDs.contains($0.id) }
        let folderTargets = selectedFolderIDs
        guard !targets.isEmpty || !folderTargets.isEmpty else {
            return
        }
        let affectsDisplayed = targets.contains { isDisplayedRecent($0) }
        let removedIDs = selectedRecentIDs
        withAnimation(.snappy(duration: 0.2)) {
            for recent in targets {
                switch recent.selection {
                case .chat(let sessionID):
                    chat.deleteSession(sessionID)
                case .imageGeneration(let sessionID):
                    imageGeneration.deleteSession(sessionID)
                case .tab, .extensionPage:
                    break
                }
            }
            for folderID in folderTargets {
                chat.deleteFolder(folderID)
            }
            exitSelectMode()
        }
        guard affectsDisplayed else {
            return
        }
        if let survivor = recentSessions.first(where: { !removedIDs.contains($0.id) }) {
            applySidebarSelection(survivor.selection)
        } else if chatWorkspaceMode == .images {
            imageGeneration.beginNewDraft()
            showImageWorkspace()
        } else {
            createChatSession()
        }
    }

    private func renameRecentSession(_ recent: ControlPanelRecentSession, to newTitle: String) {
        guard case .chat(let sessionID) = recent.selection else {
            return
        }
        chat.renameSession(sessionID, to: newTitle)
    }

    private var detail: some View {
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
        .modifier(
            ControlPanelDetailSafeArea(
                isFullScreen: isFullScreen,
                extendsIntoTitlebar: detailExtendsIntoTitlebar
            )
        )
        .background(Color.nativMainContentBackground)
        .alert(
            "Models May Not Fit in Memory",
            isPresented: Binding(
                get: { model.modelPreloadMemoryWarning != nil },
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
            Text(model.modelPreloadMemoryWarning?.message ?? "")
        }
    }

    @ViewBuilder
    private var corePage: some View {
        switch selectedTab {
        case .chat:
            ChatWorkspaceView(
                mode: chatWorkspaceMode,
                onSelectMode: selectChatWorkspaceMode,
                model: model,
                chat: chat,
                mcpHost: mcpHost,
                imageGeneration: imageGeneration,
                showsConfiguration: $isModelConfigurationVisible,
                conversationWidthReduction: isFullScreen
                    ? 0
                    : ControlPanelLayout.titlebarHeight,
                onExploreImageModels: navigation.openImageModelDiscovery
            )
        case .artifacts:
            ArtifactsView(
                store: artifacts,
                semanticSearch: artifactSemanticSearch,
                titleLeadingInset: detailTitleLeadingInset,
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
                titleLeadingInset: detailTitleLeadingInset
            )
        case .system:
            SystemMonitorView(
                store: systemMonitor,
                menuBarPreferences: .shared,
                titleLeadingInset: detailTitleLeadingInset
            )
        case .models:
            ModelsViewHost(
                model: model,
                showsConfiguration: $isModelConfigurationVisible,
                titleLeadingInset: detailTitleLeadingInset,
                speechModelDiscoveryRequest: navigation.speechModelDiscoveryRequest,
                imageModelDiscoveryRequest: navigation.imageModelDiscoveryRequest,
                imageModelDiscoveryCapability: navigation.imageModelDiscoveryCapability
            )
            .equatable()
        case .extensions:
            ExtensionsHubView(
                manager: extensionManager,
                host: mcpHost,
                model: model
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
    private func extensionPage(_ pageID: String) -> some View {
        if let page = extensionManager.makePage(
            id: pageID,
            context: NativExtensionPageContext(
                model: model,
                titleLeadingInset: detailTitleLeadingInset,
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

    private func applySidebarSelection(_ selection: ControlPanelSidebarSelection) {
        switch selection {
        case .tab(let tab):
            if tab == .extensions {
                isExtensionsBadgeDismissed = true
            }
            if tab == .chat {
                switch chatWorkspaceMode {
                case .chat where chat.currentSessionID == nil:
                    chat.createSession()
                default:
                    break
                }
            }
            sidebarSelection = selection
            selectedTab = tab
        case .extensionPage(let pageID):
            guard extensionManager.enabledSidebarContributions.contains(
                where: { $0.id == pageID }
            ) else {
                sidebarSelection = .tab(.extensions)
                selectedTab = .extensions
                return
            }
            sidebarSelection = selection
            selectedTab = .extensions
        case .chat(let sessionID):
            if chat.sessions.contains(where: { $0.id == sessionID }) {
                chat.selectSession(sessionID)
                sidebarSelection = selection
            } else {
                sidebarSelection = .tab(.chat)
            }
            chatWorkspaceMode = .chat
            selectedTab = .chat
        case .imageGeneration(let sessionID):
            if imageGeneration.sessions.contains(where: { $0.id == sessionID }) {
                imageGeneration.selectSession(sessionID)
                sidebarSelection = selection
            } else {
                sidebarSelection = .tab(.chat)
            }
            chatWorkspaceMode = .images
            selectedTab = .chat
        }
    }

    private var detailTitleLeadingInset: CGFloat {
        splitColumnVisibility == .detailOnly
            ? ControlPanelLayout.collapsedSidebarTitleClearance
            : 0
    }

    private var detailExtendsIntoTitlebar: Bool {
        if case .extensionPage = sidebarSelection {
            return true
        }
        switch selectedTab {
        case .dashboard, .system, .models, .extensions, .dev:
            return true
        case .chat, .artifacts, .settings:
            return false
        }
    }

    private func createRecentSession() {
        if selectedTab == .chat, chatWorkspaceMode == .images {
            imageGeneration.beginNewDraft()
            showImageWorkspace()
        } else {
            createChatSession()
        }
    }

    private func handleNewChatRequest() {
        guard navigation.consumeNewChatRequest() else {
            return
        }
        createChatSession()
    }

    private func handleToggleSidebarRequest() {
        guard navigation.consumeToggleSidebarRequest() else {
            return
        }
        toggleSidebarVisibility()
    }

    private func handleCollapseAllSectionsRequest() {
        guard navigation.consumeCollapseAllSectionsRequest() else {
            return
        }
        toggleAllSidebarSections()
    }

    private func canExportRecent(_ recent: ControlPanelRecentSession) -> Bool {
        if case .chat = recent.selection {
            return true
        }
        return false
    }

    private func copyRecentConversation(_ recent: ControlPanelRecentSession) {
        guard case .chat(let sessionID) = recent.selection,
              let text = chat.conversationText(for: sessionID)
        else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportRecentConversation(_ recent: ControlPanelRecentSession) {
        guard case .chat(let sessionID) = recent.selection,
              let text = chat.conversationText(for: sessionID)
        else {
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(recent.title).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func exportFolder(_ folder: ChatFolder) {
        let chatIDs = sessions(inFolder: folder.id).compactMap(\.chatID)
        guard !chatIDs.isEmpty else {
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let directory = panel.url else {
            return
        }
        let root = directory.appendingPathComponent(sanitizedFileName(folder.name), isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var usedNames: Set<String> = []
        for sessionID in chatIDs {
            guard let text = chat.conversationText(for: sessionID) else {
                continue
            }
            let title = chat.sessions.first { $0.id == sessionID }?.title ?? sessionID.uuidString
            let base = sanitizedFileName(title)
            var candidate = base
            var suffix = 2
            while usedNames.contains(candidate.lowercased()) {
                candidate = "\(base) \(suffix)"
                suffix += 1
            }
            usedNames.insert(candidate.lowercased())
            let fileURL = root.appendingPathComponent("\(candidate).txt")
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    private func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    private func revealRecentSession(_ recent: ControlPanelRecentSession) {
        let fileURL: URL?
        switch recent.selection {
        case .chat(let sessionID):
            fileURL = chat.sessionDataFileURL(for: sessionID)
        case .imageGeneration(let sessionID):
            fileURL = imageGeneration.sessionDataFileURL(for: sessionID)
        case .tab, .extensionPage:
            fileURL = nil
        }
        guard let fileURL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func deleteRecentSession(_ recent: ControlPanelRecentSession) {
        let shouldSelectReplacement = isDisplayedRecent(recent)
        let replacementSelection = shouldSelectReplacement
            ? adjacentRecentSelection(to: recent)
            : nil

        switch recent.selection {
        case .chat(let sessionID):
            routineStore.deleteRoutine(forSession: sessionID)
            chat.deleteSession(sessionID)
        case .imageGeneration(let sessionID):
            imageGeneration.deleteSession(sessionID)
        case .tab, .extensionPage:
            break
        }

        guard shouldSelectReplacement else {
            return
        }
        if let replacementSelection {
            applySidebarSelection(replacementSelection)
        } else {
            switch recent.selection {
            case .imageGeneration:
                imageGeneration.beginNewDraft()
                showImageWorkspace()
            case .chat, .tab, .extensionPage:
                createChatSession()
            }
        }
    }

    private func adjacentRecentSelection(
        to recent: ControlPanelRecentSession
    ) -> ControlPanelSidebarSelection? {
        let recents = recentSessions
        guard let index = recents.firstIndex(where: { $0.id == recent.id }) else {
            return nil
        }
        let nextIndex = recents.index(after: index)
        if recents.indices.contains(nextIndex) {
            return recents[nextIndex].selection
        }
        guard index > recents.startIndex else {
            return nil
        }
        return recents[recents.index(before: index)].selection
    }

    private func isDisplayedRecent(_ recent: ControlPanelRecentSession) -> Bool {
        if sidebarSelection == recent.selection {
            return true
        }
        switch (sidebarSelection, recent.selection) {
        case (.tab(.chat), .chat(let sessionID)):
            return chatWorkspaceMode == .chat && sessionID == chat.currentSessionID
        case (.tab(.chat), .imageGeneration(let sessionID)):
            return chatWorkspaceMode == .images && sessionID == imageGeneration.currentSessionID
        default:
            return false
        }
    }

    private func isCurrentRecent(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat(let sessionID):
            return sessionID == chat.currentSessionID
        case .imageGeneration(let sessionID):
            return sessionID == imageGeneration.currentSessionID
        case .tab, .extensionPage:
            return false
        }
    }

    /// True while this chat is the one generating a response — drives the title shimmer.
    private func isRecentActive(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat(let sessionID):
            return sessionID == chat.activeRequestSessionID
        case .imageGeneration, .tab, .extensionPage:
            return false
        }
    }

    private func isRecentDeleteDisabled(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat(let sessionID):
            return chat.isSessionBusy(sessionID)
        case .imageGeneration:
            return imageGeneration.isGenerating
        case .tab, .extensionPage:
            return false
        }
    }

    private func isRecentSelectionDisabled(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat:
            return false
        case .imageGeneration:
            return imageGeneration.isGenerating
        case .tab, .extensionPage:
            return false
        }
    }

    private var newRecentHelp: String {
        selectedTab == .chat && chatWorkspaceMode == .images
            ? "Start a new image draft"
            : "Create a new chat"
    }

    private var newRecentTitle: String {
        selectedTab == .chat && chatWorkspaceMode == .images
            ? "New image"
            : "New chat"
    }

    private var newRecentSystemImage: String {
        selectedTab == .chat && chatWorkspaceMode == .images
            ? "photo.badge.plus"
            : "square.and.pencil"
    }

    private func createChatSession() {
        chat.createSession()
        showChatWorkspace()
    }

    private func selectChatWorkspaceMode(_ mode: ChatWorkspaceMode) {
        guard mode != chatWorkspaceMode else {
            return
        }
        switch mode {
        case .chat:
            showChatWorkspace()
        case .images:
            imageGeneration.beginNewDraft(preservingUncommittedDraft: true)
            showImageWorkspace()
        }
    }

    private func showChatWorkspace() {
        if chat.currentSessionID == nil {
            chat.createSession()
        }
        chatWorkspaceMode = .chat
        selectedTab = .chat
        sidebarSelection = chat.currentSessionID.map(ControlPanelSidebarSelection.chat)
            ?? .tab(.chat)
    }

    private func showImageWorkspace() {
        chatWorkspaceMode = .images
        selectedTab = .chat
        sidebarSelection = imageGeneration.currentSessionID
            .map(ControlPanelSidebarSelection.imageGeneration)
            ?? .tab(.chat)
    }

}

private struct ChatWorkspaceView: View {
    let mode: ChatWorkspaceMode
    let onSelectMode: (ChatWorkspaceMode) -> Void
    @ObservedObject var model: NativModel
    let chat: ChatViewModel
    @ObservedObject var mcpHost: MCPHostManager
    @ObservedObject var imageGeneration: ImageGenerationViewModel
    @Binding var showsConfiguration: Bool
    let conversationWidthReduction: CGFloat
    let onExploreImageModels: (ChatImageOperation) -> Void

    var body: some View {
        Group {
            switch mode {
            case .chat:
                ChatView(
                    model: model,
                    chat: chat,
                    mcpHost: mcpHost,
                    workspaceMode: mode,
                    onSelectWorkspaceMode: onSelectMode,
                    showsConfiguration: $showsConfiguration,
                    conversationWidthReduction: conversationWidthReduction,
                    onExploreImageModels: onExploreImageModels
                )
            case .images:
                ImageGenerationView(
                    model: model,
                    viewModel: imageGeneration,
                    workspaceMode: mode,
                    onSelectWorkspaceMode: onSelectMode
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

private struct FooterControlTrackingView: NSViewRepresentable {
    let tooltip: String
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> FooterControlTrackingNSView {
        FooterControlTrackingNSView(tooltip: tooltip, onHover: onHover)
    }

    func updateNSView(_ view: FooterControlTrackingNSView, context: Context) {
        view.toolTip = tooltip
        view.onHover = onHover
    }
}

@MainActor
private final class FooterControlTrackingNSView: NSView {
    var onHover: (Bool) -> Void
    private var hoverTrackingArea: NSTrackingArea?

    init(tooltip: String, onHover: @escaping (Bool) -> Void) {
        self.onHover = onHover
        super.init(frame: .zero)
        toolTip = tooltip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover(false)
    }
}

private struct ControlPanelSurfaceReader: NSViewRepresentable {
    let isFullScreen: Bool

    func makeNSView(context: Context) -> ControlPanelSurfaceReaderView {
        let view = ControlPanelSurfaceReaderView()
        view.update(isFullScreen: isFullScreen)
        return view
    }

    func updateNSView(_ view: ControlPanelSurfaceReaderView, context: Context) {
        view.update(isFullScreen: isFullScreen)
    }
}

private var controlPanelBackdropCornerRadiusObservationContext = 0

@MainActor
private final class ControlPanelSurfaceReaderView: NSView {
    private static let liveCornerCorrectionInterval: TimeInterval = 1 / 30

    private weak var glassSurface: NSView?
    private weak var sidebarBackdropView: NSView?
    private weak var observedSplitView: NSSplitView?
    private weak var observedBackdropCornerRadiusView: NSView?
    private weak var observedWindow: NSWindow?
    private var defaultBackdropEdgeInsets: NSEdgeInsets?
    private var glassCornerRadiusObservation: NSKeyValueObservation?
    private var glassFrameObservation: NSKeyValueObservation?
    private var layerCornerRadiusObservations: [
        ObjectIdentifier: NSKeyValueObservation
    ] = [:]
    private var cornerCorrectionTimer: Timer?
    private var liveResizeCornerCorrectionTimer: Timer?
    private var liveResizeStopWorkItem: DispatchWorkItem?
    private var localMouseEventMonitor: Any?
    private var isFullScreen = false

    deinit {
        cornerCorrectionTimer?.invalidate()
        liveResizeCornerCorrectionTimer?.invalidate()
        liveResizeStopWorkItem?.cancel()
        glassCornerRadiusObservation?.invalidate()
        glassFrameObservation?.invalidate()
        layerCornerRadiusObservations.values.forEach { $0.invalidate() }
        observedBackdropCornerRadiusView?.removeObserver(
            self,
            forKeyPath: "punchOutCornerRadius",
            context: &controlPanelBackdropCornerRadiusObservationContext
        )
        if let localMouseEventMonitor {
            NSEvent.removeMonitor(localMouseEventMonitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeFullScreenTransitions()

        if window?.styleMask.contains(.fullScreen) == true {
            isFullScreen = true
        }

        updateCornerCorrectionTimer()
        configureGlassSurface()
        DispatchQueue.main.async { [weak self] in
            self?.configureGlassSurface()
        }
    }

    override func layout() {
        super.layout()
        if liveResizeCornerCorrectionTimer == nil {
            configureGlassSurface()
        }
    }

    func update(isFullScreen: Bool) {
        self.isFullScreen = isFullScreen
        updateCornerCorrectionTimer()

        if liveResizeCornerCorrectionTimer == nil {
            configureGlassSurface()
        }
    }

    private func observeFullScreenTransitions() {
        guard observedWindow !== window else { return }
        NotificationCenter.default.removeObserver(self)
        if let localMouseEventMonitor {
            NSEvent.removeMonitor(localMouseEventMonitor)
            self.localMouseEventMonitor = nil
        }
        observedSplitView = nil
        observedWindow = window
        guard let window else { return }
        observeSidebarDragEvents(in: window)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillEnterFullScreen(_:)),
            name: NSWindow.willEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidEnterFullScreen(_:)),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidExitFullScreen(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
        for notificationName in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.willStartLiveResizeNotification,
            NSWindow.didEndLiveResizeNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowGeometryDidChange(_:)),
                name: notificationName,
                object: window
            )
        }
    }

    private func observeSidebarDragEvents(in window: NSWindow) {
        localMouseEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self, weak window] event in
            MainActor.assumeIsolated {
                guard event.window === window else { return }
                if event.type == .leftMouseDragged {
                    self?.beginLiveSidebarResizeCornerCorrection()
                } else {
                    self?.scheduleEndLiveSidebarResizeCornerCorrection()
                }
            }
            return event
        }
    }

    @objc
    private func windowWillEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        updateCornerCorrectionTimer()
        configureGlassSurface()
    }

    @objc
    private func windowDidEnterFullScreen(_ notification: Notification) {
        isFullScreen = true

        // AppKit reapplies its concentric radius while completing this event.
        // Correct the live surface after its final full-screen layout pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.configureGlassSurface()
        }
    }

    @objc
    private func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        updateCornerCorrectionTimer()
        DispatchQueue.main.async { [weak self] in
            self?.configureGlassSurface()
        }
    }

    @objc
    private func windowGeometryDidChange(_ notification: Notification) {
        configureGlassSurface(adjustsConstraints: false)
        DispatchQueue.main.async { [weak self] in
            self?.configureGlassSurface(adjustsConstraints: false)
        }
    }

    @objc
    private func splitViewDidResize(_ notification: Notification) {
        beginLiveSidebarResizeCornerCorrection()
    }

    private func updateCornerCorrectionTimer() {
        guard isFullScreen, window != nil else {
            cornerCorrectionTimer?.invalidate()
            cornerCorrectionTimer = nil
            return
        }
        guard cornerCorrectionTimer == nil else { return }

        let timer = Timer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(correctSidebarCorners(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        cornerCorrectionTimer = timer
    }

    @objc
    private func correctSidebarCorners(_ timer: Timer) {
        guard isFullScreen else {
            updateCornerCorrectionTimer()
            return
        }
        configureGlassSurface()
    }

    private func configureGlassSurface(adjustsConstraints: Bool = true) {
        guard #available(macOS 26.0, *) else { return }
        var ancestor = superview
        var glassSurface: NSGlassEffectView?

        while let current = ancestor {
            if let glass = current as? NSGlassEffectView {
                glassSurface = glass
                break
            }
            ancestor = current.superview
        }

        guard let glassSurface, let container = glassSurface.superview else { return }
        observeSidebarResizing(above: container)

        if self.glassSurface !== glassSurface {
            glassCornerRadiusObservation?.invalidate()
            glassFrameObservation?.invalidate()
            layerCornerRadiusObservations.values.forEach { $0.invalidate() }
            layerCornerRadiusObservations.removeAll()
            self.glassSurface = glassSurface
            glassCornerRadiusObservation = glassSurface.observe(
                \.cornerRadius,
                options: [.new]
            ) { surface, _ in
                guard surface.cornerRadius != 0 else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    surface.cornerRadius = 0
                }
            }
            glassFrameObservation = glassSurface.observe(
                \.frame,
                options: [.new]
            ) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.beginLiveSidebarResizeCornerCorrection()
                }
            }
        }
        setCornerRadiusToZero(on: glassSurface)

        configureSidebarBackdrop(in: container, excluding: glassSurface)
        configureFullSizeGlassLayers(in: glassSurface)

        guard adjustsConstraints else { return }

        var changedConstraint = false
        for constraint in container.constraints {
            let firstView = constraint.firstItem as? NSView
            let secondView = constraint.secondItem as? NSView
            let directlyPositionsSurface =
                (firstView === glassSurface && secondView === container)
                || (firstView === container && secondView === glassSurface)

            guard directlyPositionsSurface else { continue }
            let extendsPastBottomEdge =
                isFullScreen
                && constraint.firstAttribute == .bottom
                && constraint.secondAttribute == .bottom
            let extendsPastLeadingEdge =
                isFullScreen
                && (
                    (
                        constraint.firstAttribute == .leading
                            && constraint.secondAttribute == .leading
                    )
                    || (
                        constraint.firstAttribute == .left
                            && constraint.secondAttribute == .left
                    )
                )
            let targetConstant: CGFloat
            if extendsPastBottomEdge {
                targetConstant = firstView === glassSurface ? 2 : -2
            } else if extendsPastLeadingEdge {
                targetConstant = firstView === glassSurface ? -4 : 4
            } else {
                targetConstant = 0
            }

            if constraint.constant != targetConstant {
                constraint.constant = targetConstant
                changedConstraint = true
            }
        }

        if changedConstraint {
            container.needsUpdateConstraints = true
            container.needsLayout = true
        }
    }

    private func beginLiveSidebarResizeCornerCorrection() {
        if liveResizeCornerCorrectionTimer == nil {
            configureGlassSurface(adjustsConstraints: false)
            let timer = Timer(
                timeInterval: Self.liveCornerCorrectionInterval,
                target: self,
                selector: #selector(correctLiveSidebarResizeCorners(_:)),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            liveResizeCornerCorrectionTimer = timer
        }

        scheduleEndLiveSidebarResizeCornerCorrection()
    }

    private func scheduleEndLiveSidebarResizeCornerCorrection() {
        guard liveResizeCornerCorrectionTimer != nil else { return }
        liveResizeStopWorkItem?.cancel()
        let stopWorkItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.endLiveSidebarResizeCornerCorrection()
            }
        }
        liveResizeStopWorkItem = stopWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.35,
            execute: stopWorkItem
        )
    }

    @objc
    private func correctLiveSidebarResizeCorners(_ timer: Timer) {
        configureGlassSurface(adjustsConstraints: false)
    }

    private func endLiveSidebarResizeCornerCorrection() {
        liveResizeCornerCorrectionTimer?.invalidate()
        liveResizeCornerCorrectionTimer = nil
        liveResizeStopWorkItem = nil
        configureGlassSurface(adjustsConstraints: false)
    }

    private func observeSidebarResizing(above view: NSView) {
        var ancestor: NSView? = view
        while let current = ancestor, !(current is NSSplitView) {
            ancestor = current.superview
        }
        guard let splitView = ancestor as? NSSplitView,
              observedSplitView !== splitView else {
            return
        }

        if let observedSplitView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSSplitView.didResizeSubviewsNotification,
                object: observedSplitView
            )
        }
        observedSplitView = splitView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewDidResize(_:)),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitView
        )
    }

    private func startObservingBackdropCornerRadius(_ backdropView: NSView) {
        let setter = NSSelectorFromString("setPunchOutCornerRadius:")
        guard backdropView.responds(to: setter) else { return }

        backdropView.addObserver(
            self,
            forKeyPath: "punchOutCornerRadius",
            options: [.new],
            context: &controlPanelBackdropCornerRadiusObservationContext
        )
        observedBackdropCornerRadiusView = backdropView
    }

    private func stopObservingBackdropCornerRadius() {
        guard let observedBackdropCornerRadiusView else { return }
        observedBackdropCornerRadiusView.removeObserver(
            self,
            forKeyPath: "punchOutCornerRadius",
            context: &controlPanelBackdropCornerRadiusObservationContext
        )
        self.observedBackdropCornerRadiusView = nil
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard context == &controlPanelBackdropCornerRadiusObservationContext,
              let backdropView = object as? NSView else {
            super.observeValue(
                forKeyPath: keyPath,
                of: object,
                change: change,
                context: context
            )
            return
        }

        let cornerRadius =
            (backdropView.value(forKey: "punchOutCornerRadius") as? NSNumber)?
            .doubleValue ?? 0
        if cornerRadius != 0 {
            setBackdropCornerRadiusToZero(
                on: backdropView,
                key: "punchOutCornerRadius"
            )
        }
    }

    private func configureSidebarBackdrop(
        in container: NSView,
        excluding glassSurface: NSView
    ) {
        let cornerRadiusKey = "punchOutCornerRadius"
        let edgeInsetsKey = "punchOutEdgeInsets"
        let cornerRadiusSelector = NSSelectorFromString(cornerRadiusKey)
        let edgeInsetsSelector = NSSelectorFromString(edgeInsetsKey)

        var candidateViews = container.subviews
        var backdropViews = [NSView]()
        var index = 0

        while index < candidateViews.count {
            let candidate = candidateViews[index]
            index += 1
            candidateViews.append(contentsOf: candidate.subviews)

            guard candidate !== glassSurface,
                  !candidate.isDescendant(of: glassSurface),
                  candidate.responds(to: cornerRadiusSelector),
                  candidate.responds(to: edgeInsetsSelector) else {
                continue
            }
            backdropViews.append(candidate)
        }

        guard let primaryBackdropView = backdropViews.first else { return }

        if sidebarBackdropView !== primaryBackdropView {
            stopObservingBackdropCornerRadius()
            sidebarBackdropView = primaryBackdropView
            defaultBackdropEdgeInsets =
                (primaryBackdropView.value(forKey: edgeInsetsKey) as? NSValue)?
                .edgeInsetsValue
            startObservingBackdropCornerRadius(primaryBackdropView)
        }

        for backdropView in backdropViews {
            setBackdropCornerRadiusToZero(
                on: backdropView,
                key: cornerRadiusKey
            )

            if let edgeInsets = isFullScreen
                ? NSEdgeInsets(top: 0, left: -4, bottom: 2, right: 0)
                : backdropView === primaryBackdropView
                    ? defaultBackdropEdgeInsets
                    : nil {
                backdropView.setValue(
                    NSValue(edgeInsets: edgeInsets),
                    forKey: edgeInsetsKey
                )
            }
        }
    }

    private func configureFullSizeGlassLayers(in glassSurface: NSGlassEffectView) {
        guard let rootLayer = glassSurface.layer else { return }
        let targetSize = glassSurface.bounds.size
        guard targetSize.width > 0, targetSize.height > 0 else { return }

        var layers = [rootLayer]
        var activeLayerIdentifiers = Set<ObjectIdentifier>()
        var index = 0

        while index < layers.count {
            let layer = layers[index]
            index += 1
            layers.append(contentsOf: layer.sublayers ?? [])

            let fillsSurface =
                abs(layer.bounds.width - targetSize.width) < 1
                && abs(layer.bounds.height - targetSize.height) < 1
            guard fillsSurface else { continue }

            let identifier = ObjectIdentifier(layer)
            activeLayerIdentifiers.insert(identifier)
            if layerCornerRadiusObservations[identifier] == nil {
                layerCornerRadiusObservations[identifier] = layer.observe(
                    \.cornerRadius,
                    options: [.new]
                ) { observedLayer, _ in
                    guard observedLayer.cornerRadius != 0 else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    observedLayer.cornerRadius = 0
                    CATransaction.commit()
                }
            }

            if layer.cornerRadius != 0 {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.cornerRadius = 0
                CATransaction.commit()
                layer.setNeedsDisplay()
            }
        }

        let staleLayerIdentifiers = layerCornerRadiusObservations.keys.filter {
            !activeLayerIdentifiers.contains($0)
        }
        for identifier in staleLayerIdentifiers {
            layerCornerRadiusObservations.removeValue(forKey: identifier)?
                .invalidate()
        }
    }

    @available(macOS 26.0, *)
    private func setCornerRadiusToZero(on glassSurface: NSGlassEffectView) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            glassSurface.cornerRadius = 0
        }
    }

    private func setBackdropCornerRadiusToZero(
        on backdropView: NSView,
        key: String
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            backdropView.setValue(
                NSNumber(value: 0),
                forKey: key
            )
        }
    }
}

private struct ControlPanelWindowStateReader: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> ControlPanelWindowStateReaderView {
        let view = ControlPanelWindowStateReaderView()
        view.onWindowChange = context.coordinator.update(window:)
        return view
    }

    func updateNSView(_ view: ControlPanelWindowStateReaderView, context: Context) {
        context.coordinator.isFullScreen = $isFullScreen
        view.onWindowChange = context.coordinator.update(window:)
        view.reportWindowState()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isFullScreen: $isFullScreen)
    }

    @MainActor
    final class Coordinator {
        var isFullScreen: Binding<Bool>

        init(isFullScreen: Binding<Bool>) {
            self.isFullScreen = isFullScreen
        }

        func update(window: NSWindow?) {
            window?.titlebarSeparatorStyle = .none

            let newValue = window?.styleMask.contains(.fullScreen) == true
            guard isFullScreen.wrappedValue != newValue else { return }
            isFullScreen.wrappedValue = newValue
        }
    }
}

@MainActor
private final class ControlPanelWindowStateReaderView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportWindowState()

        DispatchQueue.main.async { [weak self] in
            self?.reportWindowState()
        }
    }

    func reportWindowState() {
        onWindowChange?(window)
    }
}

private struct ControlPanelCollapseButtons: NSViewRepresentable {
    let showsModelConfigurationButton: Bool
    let sidebarHelp: String
    let modelConfigurationHelp: String
    let onToggleSidebar: () -> Void
    let onToggleModelConfiguration: () -> Void

    func makeNSView(context: Context) -> ControlPanelCollapseButtonsView {
        let view = ControlPanelCollapseButtonsView()
        update(view)
        return view
    }

    func updateNSView(_ view: ControlPanelCollapseButtonsView, context: Context) {
        update(view)
    }

    static func dismantleNSView(
        _ view: ControlPanelCollapseButtonsView,
        coordinator: ()
    ) {
        view.detachButtons()
    }

    private func update(_ view: ControlPanelCollapseButtonsView) {
        view.update(
            showsModelConfigurationButton: showsModelConfigurationButton,
            sidebarHelp: sidebarHelp,
            modelConfigurationHelp: modelConfigurationHelp,
            onToggleSidebar: onToggleSidebar,
            onToggleModelConfiguration: onToggleModelConfiguration
        )
    }
}

@MainActor
private final class ControlPanelCollapseButtonsView: NSView {
    private let sidebarButton = ControlPanelCollapseButton(
        systemImageName: "sidebar.left"
    )
    private let modelConfigurationButton = ControlPanelCollapseButton(
        systemImageName: "sidebar.right"
    )
    private weak var attachedContentView: NSView?
    private weak var actionWindow: NSWindow?
    private var localMouseEventMonitor: Any?

    deinit {
        if let localMouseEventMonitor {
            NSEvent.removeMonitor(localMouseEventMonitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachButtons()

        DispatchQueue.main.async { [weak self] in
            self?.attachButtons()
        }
    }

    func update(
        showsModelConfigurationButton: Bool,
        sidebarHelp: String,
        modelConfigurationHelp: String,
        onToggleSidebar: @escaping () -> Void,
        onToggleModelConfiguration: @escaping () -> Void
    ) {
        sidebarButton.toolTip = sidebarHelp
        sidebarButton.setAccessibilityLabel(sidebarHelp)
        sidebarButton.onAction = onToggleSidebar

        modelConfigurationButton.toolTip = modelConfigurationHelp
        modelConfigurationButton.setAccessibilityLabel(modelConfigurationHelp)
        modelConfigurationButton.onAction = onToggleModelConfiguration
        modelConfigurationButton.isHidden = !showsModelConfigurationButton

        attachButtons()
    }

    func detachButtons() {
        stopMonitoringButtonEvents()
        sidebarButton.removeFromSuperview()
        modelConfigurationButton.removeFromSuperview()
        attachedContentView = nil
        actionWindow = nil
    }

    private func attachButtons() {
        guard let window, let contentView = window.contentView else { return }

        if actionWindow !== window {
            stopMonitoringButtonEvents()
            observeButtonEvents(in: window)
            actionWindow = window
        }

        if attachedContentView !== contentView {
            detachButtons()
            observeButtonEvents(in: window)
            actionWindow = window
            for button in [sidebarButton, modelConfigurationButton] {
                button.translatesAutoresizingMaskIntoConstraints = true
                contentView.addSubview(button, positioned: .above, relativeTo: nil)
            }
            attachedContentView = contentView
        }

        positionButtons(in: contentView)
        contentView.addSubview(sidebarButton, positioned: .above, relativeTo: nil)
        contentView.addSubview(
            modelConfigurationButton,
            positioned: .above,
            relativeTo: nil
        )
    }

    private func positionButtons(in contentView: NSView) {
        let buttonSize = ControlPanelLayout.collapseButtonSize
        let topOrigin = ControlPanelLayout.windowControlsCenterY - (buttonSize / 2)
        let originY = contentView.isFlipped
            ? topOrigin
            : contentView.bounds.height - topOrigin - buttonSize
        let topAutoresizingMask: NSView.AutoresizingMask = contentView.isFlipped
            ? .maxYMargin
            : .minYMargin

        sidebarButton.frame = NSRect(
            x: ControlPanelLayout.sidebarButtonLeadingPadding,
            y: originY,
            width: buttonSize,
            height: buttonSize
        )
        sidebarButton.autoresizingMask = [.maxXMargin, topAutoresizingMask]

        modelConfigurationButton.frame = NSRect(
            x: contentView.bounds.width
                - ControlPanelLayout.modelConfigurationButtonTrailingPadding
                - buttonSize,
            y: originY,
            width: buttonSize,
            height: buttonSize
        )
        modelConfigurationButton.autoresizingMask = [.minXMargin, topAutoresizingMask]
    }

    private func observeButtonEvents(in window: NSWindow) {
        localMouseEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self, weak window] event in
            var result: NSEvent? = event
            MainActor.assumeIsolated {
                guard let self, let window,
                      event.window === window || window.isKeyWindow,
                      let contentView = self.attachedContentView else {
                    return
                }

                let location = contentView.convert(event.locationInWindow, from: nil)
                let buttons = [
                    self.sidebarButton,
                    self.modelConfigurationButton,
                ]
                guard let button = buttons.first(where: {
                    !$0.isHidden
                        && $0.frame.insetBy(dx: -3, dy: -3).contains(location)
                }) else {
                    return
                }

                button.highlight(true)
                DispatchQueue.main.async { [weak button] in
                    button?.highlight(false)
                }
                button.performClick(nil)
                result = nil
            }
            return result
        }
    }

    private func stopMonitoringButtonEvents() {
        if let localMouseEventMonitor {
            NSEvent.removeMonitor(localMouseEventMonitor)
            self.localMouseEventMonitor = nil
        }
    }
}

@MainActor
private final class ControlPanelCollapseButton: NSButton {
    var onAction: (() -> Void)?

    init(systemImageName: String) {
        super.init(frame: .zero)

        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 15,
            weight: .medium
        )
        image = NSImage(
            systemSymbolName: systemImageName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(symbolConfiguration)
        image?.isTemplate = true
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        contentTintColor = .labelColor
        isBordered = false
        bezelStyle = .inline
        focusRingType = .none
        target = self
        action = #selector(performButtonAction(_:))
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc
    private func performButtonAction(_ sender: Any?) {
        onAction?()
    }
}

private struct ControlPanelWindowControls: NSViewRepresentable {
    let refreshTrigger: Int

    func makeNSView(context: Context) -> ControlPanelWindowControlsView {
        let view = ControlPanelWindowControlsView()
        view.update(refreshTrigger: refreshTrigger)
        return view
    }

    func updateNSView(_ view: ControlPanelWindowControlsView, context: Context) {
        view.update(refreshTrigger: refreshTrigger)
    }

    static func dismantleNSView(_ view: ControlPanelWindowControlsView, coordinator: ()) {
        view.detachControls()
    }
}

@MainActor
private final class ControlPanelWindowControlsView: NSView {
    private let controlsOverlay = ControlPanelWindowControlsOverlayView()
    private weak var attachedContentView: NSView?
    private var controlsConstraints: [NSLayoutConstraint] = []
    private var lastRefreshTrigger: Int?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachControls()

        DispatchQueue.main.async { [weak self] in
            self?.attachControls()
        }
    }

    func update(refreshTrigger: Int) {
        controlsOverlay.isHidden = false
        attachControls()

        guard refreshTrigger != lastRefreshTrigger else { return }
        lastRefreshTrigger = refreshTrigger

        // AppKit resets the native buttons to a disabled, transparent state at
        // the end of a full-screen transition. Reapply our custom placement
        // after that final transition pass has completed.
        DispatchQueue.main.async { [weak self] in
            self?.attachControls()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.attachControls()
        }
    }

    func detachControls() {
        NSLayoutConstraint.deactivate(controlsConstraints)
        controlsConstraints.removeAll()
        controlsOverlay.detachWindow()
        controlsOverlay.removeFromSuperview()
        attachedContentView = nil
    }

    private func attachControls() {
        guard let window, let contentView = window.contentView else { return }

        if attachedContentView !== contentView {
            detachControls()
            controlsOverlay.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(controlsOverlay, positioned: .above, relativeTo: nil)
            controlsConstraints = [
                controlsOverlay.leadingAnchor.constraint(
                    equalTo: contentView.leadingAnchor,
                    constant: ControlPanelLayout.windowControlsLeadingPadding
                ),
                controlsOverlay.topAnchor.constraint(
                    equalTo: contentView.topAnchor,
                    constant: ControlPanelLayout.windowControlsTopPadding
                ),
                controlsOverlay.widthAnchor.constraint(
                    equalToConstant: ControlPanelLayout.windowControlsWidth
                ),
                controlsOverlay.heightAnchor.constraint(
                    equalToConstant: ControlPanelLayout.windowControlsHeight
                ),
            ]
            NSLayoutConstraint.activate(controlsConstraints)
            attachedContentView = contentView
        }

        contentView.addSubview(controlsOverlay, positioned: .above, relativeTo: nil)
        controlsOverlay.installWindowButtons(from: window)
    }
}

@MainActor
private final class ControlPanelWindowControlsOverlayView: NSView {
    private static let buttonTypes: [NSWindow.ButtonType] = [
        .closeButton,
        .miniaturizeButton,
        .zoomButton,
    ]
    private static let buttonStyleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
    ]

    private let windowButtons: [NSButton]
    private weak var actionWindow: NSWindow?
    private var shouldMiniaturizeAfterExitingFullScreen = false
    private var localMouseEventMonitor: Any?

    override init(frame frameRect: NSRect) {
        windowButtons = Self.buttonTypes.compactMap {
            NSWindow.standardWindowButton($0, for: Self.buttonStyleMask)
        }
        super.init(frame: frameRect)

        for button in windowButtons {
            button.autoresizingMask = []
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let localMouseEventMonitor {
            NSEvent.removeMonitor(localMouseEventMonitor)
        }
    }

    override func layout() {
        super.layout()

        let spacing: CGFloat = 6
        var originX: CGFloat = 0

        for button in windowButtons {
            button.frame.origin = NSPoint(
                x: originX,
                y: (bounds.height - button.frame.height) / 2
            )
            originX += button.frame.width + spacing
        }
    }

    func installWindowButtons(from window: NSWindow) {
        for buttonType in Self.buttonTypes {
            window.standardWindowButton(buttonType)?.isHidden = true
        }

        if actionWindow !== window {
            stopMonitoringWindowButtonEvents()
            observeWindowButtonEvents(in: window)
        }
        actionWindow = window
        for (buttonType, button) in zip(Self.buttonTypes, windowButtons) {
            button.isHidden = false
            button.isEnabled = true
            button.alphaValue = 1
            button.target = self

            switch buttonType {
            case .closeButton:
                button.action = #selector(closeWindow(_:))
            case .miniaturizeButton:
                button.action = #selector(miniaturizeWindow(_:))
            case .zoomButton:
                button.action = #selector(toggleFullScreen(_:))
            default:
                break
            }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func detachWindow() {
        NotificationCenter.default.removeObserver(self)
        shouldMiniaturizeAfterExitingFullScreen = false
        stopMonitoringWindowButtonEvents()

        if let actionWindow {
            for buttonType in Self.buttonTypes {
                actionWindow.standardWindowButton(buttonType)?.isHidden = false
            }
        }
        actionWindow = nil
    }

    private func observeWindowButtonEvents(in window: NSWindow) {
        localMouseEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self, weak window] event in
            var result: NSEvent? = event
            MainActor.assumeIsolated {
                guard let self, let window,
                      event.window === window || window.isKeyWindow else {
                    return
                }
                result = self.handleWindowButtonEvent(event)
            }
            return result
        }
    }

    private func stopMonitoringWindowButtonEvents() {
        if let localMouseEventMonitor {
            NSEvent.removeMonitor(localMouseEventMonitor)
            self.localMouseEventMonitor = nil
        }
    }

    private func handleWindowButtonEvent(_ event: NSEvent) -> NSEvent? {
        let location = convert(event.locationInWindow, from: nil)
        guard let button = windowButtons.first(where: {
            $0.frame.insetBy(dx: -3, dy: -3).contains(location)
        }) else {
            return event
        }

        button.highlight(true)
        DispatchQueue.main.async { [weak button] in
            button?.highlight(false)
        }
        performWindowAction(for: button)
        return nil
    }

    private func performWindowAction(for button: NSButton) {
        guard let index = windowButtons.firstIndex(where: { $0 === button }),
              Self.buttonTypes.indices.contains(index) else {
            return
        }

        switch Self.buttonTypes[index] {
        case .closeButton:
            closeWindow(button)
        case .miniaturizeButton:
            miniaturizeWindow(button)
        case .zoomButton:
            toggleFullScreen(button)
        default:
            break
        }
    }

    @objc
    private func closeWindow(_ sender: Any?) {
        actionWindow?.close()
    }

    @objc
    private func miniaturizeWindow(_ sender: Any?) {
        guard let actionWindow else { return }

        if actionWindow.styleMask.contains(.fullScreen) {
            shouldMiniaturizeAfterExitingFullScreen = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(didExitFullScreen(_:)),
                name: NSWindow.didExitFullScreenNotification,
                object: actionWindow
            )
            actionWindow.toggleFullScreen(sender)
        } else {
            actionWindow.miniaturize(sender)
        }
    }

    @objc
    private func toggleFullScreen(_ sender: Any?) {
        actionWindow?.toggleFullScreen(sender)
    }

    @objc
    private func didExitFullScreen(_ notification: Notification) {
        guard shouldMiniaturizeAfterExitingFullScreen,
              let window = notification.object as? NSWindow,
              window === actionWindow else {
            return
        }

        shouldMiniaturizeAfterExitingFullScreen = false
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
        window.miniaturize(nil)
    }
}

private struct ControlPanelDetailSafeArea: ViewModifier {
    let isFullScreen: Bool
    let extendsIntoTitlebar: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if !isFullScreen || extendsIntoTitlebar {
            content.ignoresSafeArea(.container, edges: .top)
        } else {
            content
        }
    }
}

private enum ControlPanelSidebarSelection: Hashable {
    case tab(ControlPanelTab)
    case extensionPage(String)
    case chat(UUID)
    case imageGeneration(UUID)
}

private struct RowReorderDropDelegate: DropDelegate {
    let targetID: ControlPanelRecentSession.ID
    let setTarget: (ControlPanelRecentSession.ID?, Bool) -> Void
    let onDrop: (String, Bool) -> Void
    private let rowHeight: CGFloat = 30

    func dropEntered(info: DropInfo) {
        setTarget(targetID, info.location.y > rowHeight / 2)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        setTarget(targetID, info.location.y > rowHeight / 2)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        setTarget(nil, false)
    }

    func performDrop(info: DropInfo) -> Bool {
        let insertAfter = info.location.y > rowHeight / 2
        setTarget(nil, false)
        guard let provider = info.itemProviders(for: [.text]).first else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            if let string = object as? String, !string.isEmpty {
                DispatchQueue.main.async {
                    onDrop(string, insertAfter)
                }
            }
        }
        return true
    }
}

private struct FolderDropDelegate: DropDelegate {
    let onChatDrop: (UUID) -> Void
    let onFolderDrop: (UUID) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, !string.isEmpty else {
                return
            }
            DispatchQueue.main.async {
                if string.hasPrefix("folder:") {
                    if let id = UUID(uuidString: String(string.dropFirst("folder:".count))) {
                        onFolderDrop(id)
                    }
                } else if let id = UUID(uuidString: string) {
                    onChatDrop(id)
                }
            }
        }
        return true
    }
}

private struct ControlPanelRecentSession: Identifiable, Equatable {
    enum ID: Hashable {
        case chat(UUID)
        case imageGeneration(UUID)
    }

    let id: ID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let pinned: Bool
    let pinnedOrder: Int?
    let sessionOrder: Int?
    let folderID: UUID?

    init(chat session: ChatSessionSummary) {
        id = .chat(session.id)
        title = session.title
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        pinned = session.isPinned
        pinnedOrder = session.pinnedOrder
        sessionOrder = session.sessionOrder
        folderID = session.folderID
    }

    init(imageGeneration session: ImageGenerationSessionSummary) {
        id = .imageGeneration(session.id)
        title = session.title
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        pinned = false
        pinnedOrder = nil
        sessionOrder = nil
        folderID = nil
    }

    var chatID: UUID? {
        if case .chat(let sessionID) = id {
            return sessionID
        }
        return nil
    }

    var dragPayload: String? {
        chatID?.uuidString
    }

    var selection: ControlPanelSidebarSelection {
        switch id {
        case .chat(let sessionID):
            return .chat(sessionID)
        case .imageGeneration(let sessionID):
            return .imageGeneration(sessionID)
        }
    }

    var isChat: Bool {
        if case .chat = id {
            return true
        }
        return false
    }

    var badgeSystemImage: String? {
        switch id {
        case .chat:
            nil
        case .imageGeneration:
            "photo"
        }
    }

    static func recencySort(_ lhs: ControlPanelRecentSession, _ rhs: ControlPanelRecentSession) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    static func pinnedSort(_ lhs: ControlPanelRecentSession, _ rhs: ControlPanelRecentSession) -> Bool {
        switch (lhs.pinnedOrder, rhs.pinnedOrder) {
        case let (left?, right?):
            return left == right ? recencySort(lhs, rhs) : left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return recencySort(lhs, rhs)
        }
    }

    static func sessionSort(_ lhs: ControlPanelRecentSession, _ rhs: ControlPanelRecentSession) -> Bool {
        switch (lhs.sessionOrder, rhs.sessionOrder) {
        case let (left?, right?):
            return left == right ? recencySort(lhs, rhs) : left < right
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        case (nil, nil):
            return recencySort(lhs, rhs)
        }
    }
}

private enum RoutineRowStatus {
    case none
    case disabled
    case scheduled
    case running
}

private struct ControlPanelRecentSessionRow: View {
    let recent: ControlPanelRecentSession
    let routineStatus: RoutineRowStatus
    let isSelected: Bool
    let isCurrent: Bool
    let isActive: Bool
    let isSelectionDisabled: Bool
    let isDeleteDisabled: Bool
    let canExport: Bool
    let isSelecting: Bool
    let isChecked: Bool
    let onToggleSelect: () -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onCopyConversation: () -> Void
    let onExportFile: () -> Void
    let onRevealInFinder: () -> Void
    let onRename: (String) -> Void
    let onNewChat: () -> Void
    let onTogglePin: () -> Void
    let onScheduleRoutine: () -> Void
    let folders: [ChatFolder]
    let onMoveToFolder: (UUID?) -> Void
    let onCreateFolderForSession: () -> Void
    @State private var isHovering = false
    @State private var isDeleteHovering = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var renameFieldFocused: Bool

    @ViewBuilder
    private var routineBolt: some View {
        switch routineStatus {
        case .none:
            EmptyView()
        case .disabled:
            Image(systemName: "bolt.slash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .help("Routine paused")
        case .scheduled:
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .help("Routine scheduled")
        case .running:
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.green)
                .help("Routine running now")
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            if isRenaming {
                HStack(spacing: 7) {
                    Circle()
                        .fill(isCurrent ? Color.accentColor : Color.clear)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)

                    TextField("Name", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .focused($renameFieldFocused)
                        .onSubmit {
                            commitRename()
                        }
                        .onExitCommand {
                            isRenaming = false
                        }
                        // Clicking away ends the rename (commit) instead of
                        // leaving a stuck field/caret that swallows clicks.
                        .onChange(of: renameFieldFocused) { _, focused in
                            if !focused, isRenaming { commitRename() }
                        }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button {
                    if isSelecting {
                        onToggleSelect()
                    } else if isSelected, recent.isChat {
                        beginRename()
                    } else {
                        onSelect()
                    }
                } label: {
                    HStack(spacing: 7) {
                        if isSelecting {
                            Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                                .accessibilityLabel(isChecked ? "Selected" : "Not selected")
                        } else {
                            Circle()
                                .fill(isCurrent ? Color.accentColor : Color.clear)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }

                        if let badgeSystemImage = recent.badgeSystemImage {
                            Image(systemName: badgeSystemImage)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.secondary.opacity(0.1))
                                )
                                .help("Image session")
                                .accessibilityLabel("Image session")
                        }

                        TextShimmerWave(text: recent.title, active: isActive)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        routineBolt

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(isSelectionDisabled && !isSelecting)
                .help(recent.title)
            }

            Menu {
                rowMenuContents
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .frame(width: 24, height: 20)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Actions")
            .opacity(isHovering && !isSelecting ? 1 : 0)
            .allowsHitTesting(isHovering && !isSelecting)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
                    .frame(width: 26, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isDeleteHovering ? Color.red.opacity(0.13) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(isDeleteHovering ? Color.red : Color.secondary)
            .disabled(isDeleteDisabled)
            .help("Delete \(recent.title)")
            .opacity(isHovering && !isSelecting && !isDeleteDisabled ? 1 : 0)
            .allowsHitTesting(isHovering && !isSelecting && !isDeleteDisabled)
            .onHover { isDeleteHovering = $0 }
        }
        .sidebarRowSelectionStyle(isSelected: isSelecting ? isChecked : isSelected)
        .opacity(isSelectionDisabled && !isCurrent && !isSelecting ? 0.55 : 1)
        .onHover { isHovering = $0 }
        .animation(.easeInOut, value: isHovering)
        .contextMenu {
            rowMenuContents
        }
    }

    @ViewBuilder
    private var rowMenuContents: some View {
        Button {
            onNewChat()
        } label: {
            Label("New", systemImage: "square.and.pencil")
        }

        if recent.isChat {
            Divider()

            Button {
                beginRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                onTogglePin()
            } label: {
                Label(
                    recent.pinned ? "Unpin" : "Pin",
                    systemImage: recent.pinned ? "pin.slash" : "pin"
                )
            }

            Button {
                onScheduleRoutine()
            } label: {
                Label(routineStatus == .none ? "Make recurring" : "Edit routine", systemImage: "bolt")
            }

            Menu {
                if recent.folderID != nil {
                    Button {
                        onMoveToFolder(nil)
                    } label: {
                        Label("Remove from Folder", systemImage: "folder.badge.minus")
                    }
                    Divider()
                }
                ForEach(folders) { folder in
                    Button {
                        onMoveToFolder(folder.id)
                    } label: {
                        if folder.id == recent.folderID {
                            Label(folder.name, systemImage: "checkmark")
                        } else {
                            Text(folder.name)
                        }
                    }
                }
                if !folders.isEmpty {
                    Divider()
                }
                Button {
                    onCreateFolderForSession()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            } label: {
                Label("Move to Folder", systemImage: "folder")
            }
        }

        Divider()

        if canExport {
            Button {
                onExportFile()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }

        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(isDeleteDisabled)
    }

    private func beginRename() {
        renameDraft = recent.title
        isRenaming = true
        DispatchQueue.main.async {
            renameFieldFocused = true
        }
    }

    private func commitRename() {
        isRenaming = false
        onRename(renameDraft)
    }
}

private struct ControlPanelFolderHeaderView: View {
    let folder: ChatFolder
    let count: Int
    let isSelecting: Bool
    let isChecked: Bool
    let onToggleCollapse: () -> Void
    let onRename: (String) -> Void
    let onTogglePin: () -> Void
    let onToggleSelect: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            if isSelecting {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                    .frame(width: 12)
            } else {
                Button(action: onToggleCollapse) {
                    Image(systemName: folder.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            }

            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if isRenaming {
                TextField("Name", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .focused($renameFieldFocused)
                    .onSubmit {
                        commitRename()
                    }
                    .onExitCommand {
                        isRenaming = false
                    }
                    .onChange(of: renameFieldFocused) { _, focused in
                        if !focused, isRenaming { commitRename() }
                    }
            } else {
                Text(folder.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            if !isSelecting {
                beginRename()
            }
        }
        .onTapGesture {
            if isSelecting {
                onToggleSelect()
            }
        }
        .contextMenu {
            Button {
                beginRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                onTogglePin()
            } label: {
                Label(
                    folder.isPinned ? "Unpin" : "Pin",
                    systemImage: folder.isPinned ? "pin.slash" : "pin"
                )
            }

            Button {
                onExport()
            } label: {
                Label("Export Folder", systemImage: "square.and.arrow.up")
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        }
    }

    private func beginRename() {
        renameDraft = folder.name
        isRenaming = true
        DispatchQueue.main.async {
            renameFieldFocused = true
        }
    }

    private func commitRename() {
        isRenaming = false
        onRename(renameDraft)
    }
}

private struct SidebarRowSelectionStyle: ViewModifier {
    let isSelected: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 15, weight: .regular))
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                        lineWidth: 0.5
                    )
            )
            .foregroundStyle(Color.primary)
            .contentShape(.rect)
            .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }
        if isHovering {
            return Color.accentColor.opacity(0.08)
        }
        return Color.clear
    }
}

private extension View {
    func sidebarRowSelectionStyle(isSelected: Bool) -> some View {
        modifier(SidebarRowSelectionStyle(isSelected: isSelected))
    }
}

#Preview {
    ControlPanelView(
        model: .init(),
        navigation: .init(),
        runtime: .init(),
        extensionManager: .init(builtInExtensions: []),
        softwareUpdater: .init()
    )
}
