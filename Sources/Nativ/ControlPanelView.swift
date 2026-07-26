import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ControlPanelTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case imageGeneration = "Images"
    case dashboard = "Dashboard"
    case system = "System"
    case models = "Models"
    case integrations = "Integrations"
    case developer = "Developer"
    case settings = "Settings"

    static var allCases: [ControlPanelTab] {
        [
            .chat,
            .imageGeneration,
            .dashboard,
            .system,
            .models,
            .integrations,
            .developer,
        ]
    }

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .chat:
            "bubble.left.and.bubble.right"
        case .imageGeneration:
            "photo.on.rectangle"
        case .dashboard:
            "chart.bar.xaxis"
        case .system:
            "gauge.open.with.lines.needle.33percent"
        case .models:
            "cube.transparent"
        case .integrations:
            "puzzlepiece.extension"
        case .developer:
            "hammer"
        case .settings:
            "gearshape"
        }
    }
}

@MainActor
final class ControlPanelNavigation: ObservableObject {
    @Published private(set) var requestedTab: ControlPanelTab?
    @Published private(set) var newChatRequest = 0
    private var consumedNewChatRequest = 0

    func open(_ tab: ControlPanelTab) {
        requestedTab = tab
    }

    func createChat() {
        newChatRequest += 1
    }

    func consumeNewChatRequest() -> Bool {
        guard consumedNewChatRequest < newChatRequest else {
            return false
        }
        consumedNewChatRequest = newChatRequest
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
    static let collapsedSidebarTitleClearance: CGFloat = 56
    static let coordinateSpaceName = "ControlPanelLayout"
}

/// A small pulsing download arrow shown next to the Models sidebar row while a model
/// is downloading. When concurrent downloads are supported this can show the number of
/// models still downloading beside the arrow.
private struct ModelsDownloadArrow: View {
    @State private var pulse = false

    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.caption)
            .foregroundStyle(.tint)
            .opacity(pulse ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .help("A model is downloading")
            .accessibilityLabel("A model is downloading")
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
    @ObservedObject var model: NativModel
    @ObservedObject var navigation: ControlPanelNavigation
    @ObservedObject var runtime: SystemRuntimeMonitor
    let softwareUpdater: SoftwareUpdater
    @StateObject private var chat = ChatViewModel()
    @StateObject private var imageGeneration = ImageGenerationViewModel()
    @StateObject private var dashboard = DashboardViewModel()
    @StateObject private var systemMonitor = SystemMonitorStore()
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @ObservedObject private var downloads = HuggingFaceDownloadManager.shared
    @State private var sidebarSelection: ControlPanelSidebarSelection = .tab(.chat)
    @State private var selectedTab: ControlPanelTab = .chat
    @State private var hoveredFooterControl: FooterControl?
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var detailLeadingEdge = ControlPanelLayout.sidebarIdealWidth
    @State private var expandedDetailLeadingEdge = ControlPanelLayout.sidebarIdealWidth
    @State private var isSidebarTransitioning = false
    @State private var isModelConfigurationVisible = false
    @State private var isFullScreen = false
    @State private var isNewChatHovering = false
    private let sidebarItemInsets = EdgeInsets(top: -1, leading: 0, bottom: -1, trailing: 0)

    var body: some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: ControlPanelLayout.sidebarMinimumWidth,
                    ideal: ControlPanelLayout.sidebarIdealWidth,
                    max: ControlPanelLayout.sidebarMaximumWidth
                )
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .ignoresSafeArea(.container, edges: .top)
        .coordinateSpace(name: ControlPanelLayout.coordinateSpaceName)
        .frame(minWidth: 1040, minHeight: 600)
        .overlay(alignment: .topLeading) {
            if splitColumnVisibility == .detailOnly {
                sidebarVisibilityButton
                    .padding(12)
                    .offset(y: -32)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsModelConfigurationToggle {
                modelConfigurationVisibilityButton
                    .padding(12)
                    .offset(y: -32)
            }
        }
        .overlay(alignment: .top) {
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
        .background {
            ControlPanelWindowStateReader(isFullScreen: $isFullScreen)
                .frame(width: 0, height: 0)
        }
        .onAppear {
            applySidebarSelection(navigation.requestedTab.map(ControlPanelSidebarSelection.tab) ?? sidebarSelection)
            handleNewChatRequest()
        }
        .onReceive(navigation.$requestedTab) { tab in
            guard let tab else { return }
            applySidebarSelection(.tab(tab))
        }
        .onChange(of: navigation.newChatRequest) { _, _ in
            handleNewChatRequest()
        }
        .onChange(of: splitColumnVisibility) { _, newVisibility in
            beginSidebarTransition(to: newVisibility)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
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
        } message: {
            Text(launchAtLogin.errorMessage ?? "An unknown error occurred.")
        }
    }

    private var sidebar: some View {
        List {
            Section {
                ForEach(ControlPanelTab.allCases) { tab in
                    let selection = ControlPanelSidebarSelection.tab(tab)
                    Button {
                        applySidebarSelection(selection)
                    } label: {
                        HStack(spacing: 8) {
                            Label(tab.rawValue, systemImage: tab.systemImage)
                            if tab == .models, downloads.downloadingModelID != nil {
                                ModelsDownloadArrow()
                            }
                            Spacer(minLength: 0)
                            if tab == .models,
                               model.isModelLoading,
                               let percentage = model.modelLoadingPercentageText {
                                Text(percentage)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .sidebarRowSelectionStyle(isSelected: sidebarSelection == selection)
                    .buttonStyle(.plain)
                    .listRowInsets(sidebarItemInsets)
                }
            }

            Section {
                ForEach(recentSessions) { recent in
                    ControlPanelRecentSessionRow(
                        recent: recent,
                        isSelected: sidebarSelection == recent.selection,
                        isCurrent: isCurrentRecent(recent),
                        isSelectionDisabled: isRecentSelectionDisabled(recent),
                        isDeleteDisabled: isRecentDeleteDisabled(recent),
                        canExport: canExportRecent(recent),
                        onSelect: {
                            applySidebarSelection(recent.selection)
                        },
                        onDelete: {
                            deleteRecentSession(recent)
                        },
                        onCopyConversation: {
                            copyRecentConversation(recent)
                        },
                        onExportFile: {
                            exportRecentConversation(recent)
                        },
                        onRevealInFinder: {
                            revealRecentSession(recent)
                        }
                    )
                    .listRowInsets(sidebarItemInsets)
                }
            } header: {
                HStack(spacing: 8) {
                    Text("Recents")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.7))

                    Spacer(minLength: 0)

                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            createRecentSession()
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(isNewChatHovering ? Color.primary : Color.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedTab == .imageGeneration && imageGeneration.isGenerating)
                    .help(newRecentHelp)
                    .padding(.trailing, 4)
                    .onHover { isNewChatHovering = $0 }
                }
                .textCase(nil)
                .padding(.horizontal, 7)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 18)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                    .overlay(Color.secondary.opacity(0.25))

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
        }
        .navigationTitle("Nativ")
        .overlay(alignment: .topTrailing) {
            sidebarVisibilityButton
                .padding(12)
                .offset(y: -32)
        }
        .background(
            ControlPanelSurfaceReader(isFullScreen: isFullScreen)
        )
    }

    private var sidebarVisibilityButton: some View {
        let help = splitColumnVisibility == .detailOnly
            ? "Show Sidebar"
            : "Hide Sidebar"

        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                splitColumnVisibility =
                    splitColumnVisibility == .detailOnly ? .all : .detailOnly
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(help)
        .accessibilityLabel(help)
    }

    private var modelConfigurationVisibilityButton: some View {
        let help = isModelConfigurationVisible
            ? "Hide model configuration"
            : "Show model configuration"

        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                isModelConfigurationVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(help)
        .accessibilityLabel(help)
    }

    private var showsModelConfigurationToggle: Bool {
        switch selectedTab {
        case .chat, .models, .developer:
            true
        case .imageGeneration, .dashboard, .system, .integrations, .settings:
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

    private var detail: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .chat:
                    ChatView(
                        model: model,
                        chat: chat,
                        showsConfiguration: $isModelConfigurationVisible
                    )
                case .imageGeneration:
                    ImageGenerationView(model: model, viewModel: imageGeneration)
                case .dashboard:
                    StatsView(
                        model: model,
                        dashboard: dashboard,
                        titleLeadingInset: detailTitleLeadingInset
                    )
                case .system:
                    SystemMonitorView(
                        store: systemMonitor,
                        menuBarPreferences: .shared
                    )
                case .models:
                    ModelsView(
                        model: model,
                        showsConfiguration: $isModelConfigurationVisible,
                        titleLeadingInset: detailTitleLeadingInset
                    )
                case .integrations:
                    IntegrationsView(model: model)
                case .developer:
                    DeveloperView(
                        model: model,
                        runtime: runtime,
                        showsConfiguration: $isModelConfigurationVisible,
                        titleLeadingInset: detailTitleLeadingInset
                    )
                case .settings:
                    SettingsView(
                        softwareUpdater: softwareUpdater,
                        launchAtLogin: launchAtLogin
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(ControlPanelDetailSafeArea(isFullScreen: isFullScreen))
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
            Button("Cancel", role: .cancel) {
                model.cancelPendingModelPreloadSwitch()
            }
        } message: {
            Text(model.modelPreloadMemoryWarning?.message ?? "")
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(ControlPanelLayout.coordinateSpaceName)).minX
        } action: { leadingEdge in
            updateDetailLeadingEdge(leadingEdge)
        }
    }

    private func applySidebarSelection(_ selection: ControlPanelSidebarSelection) {
        switch selection {
        case .tab(let tab):
            if tab == .chat, chat.currentSessionID == nil {
                chat.createSession()
            } else if tab == .imageGeneration,
                      imageGeneration.currentSessionID == nil {
                imageGeneration.createSession()
            }
            sidebarSelection = selection
            selectedTab = tab
        case .chat(let sessionID):
            if chat.sessions.contains(where: { $0.id == sessionID }) {
                chat.selectSession(sessionID)
                sidebarSelection = selection
            } else {
                sidebarSelection = .tab(.chat)
            }
            selectedTab = .chat
        case .imageGeneration(let sessionID):
            if imageGeneration.sessions.contains(where: { $0.id == sessionID }) {
                imageGeneration.selectSession(sessionID)
                sidebarSelection = selection
            } else {
                sidebarSelection = .tab(.imageGeneration)
            }
            selectedTab = .imageGeneration
        }
    }

    private var detailTitleLeadingInset: CGFloat {
        guard isSidebarTransitioning else {
            return splitColumnVisibility == .detailOnly
                ? ControlPanelLayout.collapsedSidebarTitleClearance
                : 0
        }

        let expandedLeadingEdge = max(expandedDetailLeadingEdge, 1)
        let visibleFraction = min(max(detailLeadingEdge / expandedLeadingEdge, 0), 1)
        return ControlPanelLayout.collapsedSidebarTitleClearance * (1 - visibleFraction)
    }

    private func beginSidebarTransition(to visibility: NavigationSplitViewVisibility) {
        if visibility == .detailOnly {
            expandedDetailLeadingEdge = max(detailLeadingEdge, 1)
        }
        isSidebarTransitioning = true
    }

    private func updateDetailLeadingEdge(_ leadingEdge: CGFloat) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            detailLeadingEdge = max(0, leadingEdge)

            if isSidebarTransitioning {
                if splitColumnVisibility == .detailOnly {
                    if detailLeadingEdge <= 0.5 {
                        isSidebarTransitioning = false
                    }
                } else if detailLeadingEdge >= expandedDetailLeadingEdge - 0.5 {
                    expandedDetailLeadingEdge = detailLeadingEdge
                    isSidebarTransitioning = false
                }
            } else if splitColumnVisibility != .detailOnly,
                      detailLeadingEdge >= ControlPanelLayout.sidebarMinimumWidth {
                expandedDetailLeadingEdge = detailLeadingEdge
            }
        }
    }

    private func createRecentSession() {
        if selectedTab == .imageGeneration {
            imageGeneration.createSession()
            applySidebarSelection(
                imageGeneration.currentSessionID.map(ControlPanelSidebarSelection.imageGeneration)
                    ?? .tab(.imageGeneration)
            )
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

    private func revealRecentSession(_ recent: ControlPanelRecentSession) {
        let fileURL: URL?
        switch recent.selection {
        case .chat(let sessionID):
            fileURL = chat.sessionDataFileURL(for: sessionID)
        case .imageGeneration(let sessionID):
            fileURL = imageGeneration.sessionDataFileURL(for: sessionID)
        case .tab:
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
            chat.deleteSession(sessionID)
        case .imageGeneration(let sessionID):
            imageGeneration.deleteSession(sessionID)
        case .tab:
            break
        }

        guard shouldSelectReplacement else {
            return
        }
        applySidebarSelection(
            replacementSelection ?? fallbackTabSelection(for: recent)
        )
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
            return sessionID == chat.currentSessionID
        case (.tab(.imageGeneration), .imageGeneration(let sessionID)):
            return sessionID == imageGeneration.currentSessionID
        default:
            return false
        }
    }

    private func fallbackTabSelection(
        for recent: ControlPanelRecentSession
    ) -> ControlPanelSidebarSelection {
        switch recent.selection {
        case .chat:
            .tab(.chat)
        case .imageGeneration:
            .tab(.imageGeneration)
        case .tab(let tab):
            .tab(tab)
        }
    }

    private func isCurrentRecent(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat(let sessionID):
            return sessionID == chat.currentSessionID
        case .imageGeneration(let sessionID):
            return sessionID == imageGeneration.currentSessionID
        case .tab:
            return false
        }
    }

    private func isRecentDeleteDisabled(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat(let sessionID):
            return chat.isSessionBusy(sessionID)
        case .imageGeneration:
            return imageGeneration.isGenerating
        case .tab:
            return false
        }
    }

    private func isRecentSelectionDisabled(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat:
            return false
        case .imageGeneration:
            return imageGeneration.isGenerating
        case .tab:
            return false
        }
    }

    private var newRecentHelp: String {
        selectedTab == .imageGeneration ? "Create a new image conversation" : "Create a new chat"
    }

    private func createChatSession() {
        chat.createSession()
        applySidebarSelection(chat.currentSessionID.map(ControlPanelSidebarSelection.chat) ?? .tab(.chat))
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
        configureGlassSurface()
    }

    func update(isFullScreen: Bool) {
        self.isFullScreen = isFullScreen
        updateCornerCorrectionTimer()
        configureGlassSurface()
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
        configureGlassSurface(adjustsConstraints: false)
        DispatchQueue.main.async { [weak self] in
            self?.configureGlassSurface(adjustsConstraints: false)
        }
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
                surface.cornerRadius = 0
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
        glassSurface.cornerRadius = 0

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
        configureGlassSurface(adjustsConstraints: false)

        if liveResizeCornerCorrectionTimer == nil {
            let timer = Timer(
                timeInterval: 1 / 120,
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
            deadline: .now() + 0.15,
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
            backdropView.setValue(
                NSNumber(value: 0),
                forKey: "punchOutCornerRadius"
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

        guard let backdropView = container.subviews.first(where: {
            $0 !== glassSurface
                && $0.responds(to: cornerRadiusSelector)
                && $0.responds(to: edgeInsetsSelector)
        }) else {
            return
        }

        if sidebarBackdropView !== backdropView {
            stopObservingBackdropCornerRadius()
            sidebarBackdropView = backdropView
            defaultBackdropEdgeInsets =
                (backdropView.value(forKey: edgeInsetsKey) as? NSValue)?.edgeInsetsValue
            startObservingBackdropCornerRadius(backdropView)
        }

        backdropView.setValue(
            NSNumber(value: 0),
            forKey: cornerRadiusKey
        )

        if let edgeInsets = isFullScreen
            ? NSEdgeInsets(top: 0, left: -4, bottom: 2, right: 0)
            : defaultBackdropEdgeInsets {
            backdropView.setValue(
                NSValue(edgeInsets: edgeInsets),
                forKey: edgeInsetsKey
            )
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
            for buttonType in [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton,
            ] {
                window?.standardWindowButton(buttonType)?.isHidden = false
            }

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

private struct ControlPanelDetailSafeArea: ViewModifier {
    let isFullScreen: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isFullScreen {
            content
        } else {
            content.ignoresSafeArea(.container, edges: .top)
        }
    }
}

private enum ControlPanelSidebarSelection: Hashable {
    case tab(ControlPanelTab)
    case chat(UUID)
    case imageGeneration(UUID)
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

    init(chat session: ChatSessionSummary) {
        id = .chat(session.id)
        title = session.title
        createdAt = session.createdAt
        updatedAt = session.updatedAt
    }

    init(imageGeneration session: ImageGenerationSessionSummary) {
        id = .imageGeneration(session.id)
        title = session.title
        createdAt = session.createdAt
        updatedAt = session.updatedAt
    }

    var selection: ControlPanelSidebarSelection {
        switch id {
        case .chat(let sessionID):
            return .chat(sessionID)
        case .imageGeneration(let sessionID):
            return .imageGeneration(sessionID)
        }
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
}

private struct ControlPanelRecentSessionRow: View {
    let recent: ControlPanelRecentSession
    let isSelected: Bool
    let isCurrent: Bool
    let isSelectionDisabled: Bool
    let isDeleteDisabled: Bool
    let canExport: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onCopyConversation: () -> Void
    let onExportFile: () -> Void
    let onRevealInFinder: () -> Void
    @State private var isHovering = false
    @State private var isDeleteHovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(isCurrent ? Color.accentColor : Color.clear)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)

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

                    Text(recent.title)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isSelectionDisabled)
            .help(recent.title)

            if isHovering {
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
                .opacity(isHovering && !isDeleteDisabled ? 1 : 0)
                .allowsHitTesting(isHovering && !isDeleteDisabled)
                .onHover { isDeleteHovering = $0 }
            }
        }
        .sidebarRowSelectionStyle(isSelected: isSelected)
        .opacity(isSelectionDisabled && !isCurrent ? 0.55 : 1)
        .onHover { isHovering = $0 }
        .animation(.easeInOut, value: isHovering)
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            .disabled(isSelectionDisabled)

            Button {
                onRevealInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            if canExport {
                Button {
                    onCopyConversation()
                } label: {
                    Label("Copy Conversation", systemImage: "doc.on.doc")
                }
                Button {
                    onExportFile()
                } label: {
                    Label("Export as Text\u{2026}", systemImage: "square.and.arrow.up")
                }
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(isDeleteDisabled)
        }
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
            .animation(.easeInOut, value: isHovering)
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
        softwareUpdater: .init()
    )
}
