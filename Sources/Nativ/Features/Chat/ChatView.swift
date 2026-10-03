import AppKit
import Foundation
import NativServerKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    var model: NativModel
    @ObservedObject var chat: ChatViewModel
    @ObservedObject var mcpHost: MCPHostManager
    @ObservedObject var extensionManager: NativExtensionManager
    @ObservedObject var projects: ChatProjectStore
    let workspaceMode: ChatWorkspaceMode
    let onSelectWorkspaceMode: (ChatWorkspaceMode) -> Void
    @Binding var showsConfiguration: Bool
    let onExploreImageModels: (ChatImageOperation) -> Void
    let onFindDraftModels: (String) -> Void
    @State private var isDropTargeted = false
    @State private var previewedAttachment: ChatImageAttachment?

    var body: some View {
        let project = chat.currentProjectID.flatMap { projects.project(withID: $0) }
        ModelConfigurationLayout(
            model: model,
            isConfigurationVisible: $showsConfiguration
        ) {
            ChatWorkSplitView(
                isWorkVisible: chat.workState.isVisible,
                isExpanded: Binding(get: { chat.workState.isExpanded == true }, set: { expanded in
                    if expanded != (chat.workState.isExpanded == true) { chat.toggleWorkPaneExpanded() }
                }),
                isWorkOnLeft: Binding(get: { chat.workState.isWorkOnLeft == true },
                                      set: { chat.setWorkPaneOnLeft($0) }),
                onShowChatOnly: { chat.setWorkPaneVisible(false) }
            ) {
                transcript(project: project)
            } work: {
                ChatWorkPane(chat: chat) { target, request in
                    try await chat.sendWorkEdit(target, request: request, using: model)
                }
            }
        }
        .background(Color.nativMainContentBackground)
        .overlay {
            if let previewedAttachment {
                ChatAttachmentPreview(
                    attachment: previewedAttachment,
                    onClose: { self.previewedAttachment = nil }
                )
            }
        }
        .onChange(of: chat.workState.isVisible) { _, visible in
            if visible { showsConfiguration = false }
        }
        .onChange(of: showsConfiguration) { _, visible in
            if visible { chat.setWorkPaneVisible(false) }
        }
        .onAppear {
            chat.mcpHost = mcpHost
            mcpHost.reload(servers: model.settings.mcpServers)
            chat.refreshPendingImageModelSelections()
        }
        .onChange(of: model.settings.mcpServers) { _, servers in
            mcpHost.reload(servers: servers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .routineDidSaveChatSession)) { _ in
            chat.reloadPersistedSessions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .localModelLibraryDidChange)) { _ in
            chat.refreshPendingImageModelSelections()
        }
        .onReceive(HuggingFaceDownloadManager.shared.completedDownloads) { modelID in
            chat.highlightImageModel(modelID)
            chat.refreshPendingImageModelSelections()
        }
        .environment(\.chatFontScale, model.settings.chatFontScale)
    }

    private func transcript(project: ChatProject?) -> some View {
        ChatTranscriptView(
            model: model,
            chat: chat,
            extensionManager: extensionManager,
            project: project,
            projectRootIsAvailable: project.map { projects.isRootAvailable(for: $0) } ?? true,
            workspaceMode: workspaceMode,
            onSelectWorkspaceMode: onSelectWorkspaceMode,
            onExploreImageModels: onExploreImageModels,
            onFindDraftModels: onFindDraftModels,
            onAttachmentDropTargetChange: { isDropTargeted = $0 },
            onPreviewAttachment: { previewedAttachment = $0 }
        )
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.image.identifier],
            isTargeted: $isDropTargeted,
            perform: chat.loadAttachments
        )
        .overlay {
            if isDropTargeted {
                dropOverlay
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    private var dropOverlay: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.72)
            VStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 34, weight: .semibold))
                Text("Drop files here")
                    .legacyTextStyle(.emptyStateTitle)
            }
            .foregroundStyle(.secondary)
            .padding(44)
            .frame(maxWidth: 320)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        Color.secondary.opacity(0.55),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                    )
            )
        }
        .ignoresSafeArea()
    }
}

private enum ChatTranscriptLayout {
    static let conversationMaxWidth: CGFloat = 680
    static let horizontalPadding: CGFloat = 32
    static let messageHorizontalInset: CGFloat = 32
    static let composerClearance: CGFloat = 48
    static let composerFadeExtension: CGFloat = 40
    static let scrollIndicatorClearance: CGFloat = 17
}

private struct ChatWorktreeSetupView: View {
    let progress: ChatWorktreeSetupProgress
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(progress.isComplete ? "Worktree ready" : progress.error == nil ? "Preparing worktree" : "Worktree setup stopped")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if progress.isComplete || progress.error != nil {
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Dismiss setup progress").accessibilityLabel("Dismiss setup progress")
                }
            }
            ForEach(ChatWorktreeSetupProgress.Step.allCases, id: \.rawValue) { step in
                let complete = progress.isComplete || step.rawValue < progress.step.rawValue
                let active = !progress.isComplete && step == progress.step
                HStack(spacing: 8) {
                    Group {
                        if complete {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if active && progress.error != nil {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        } else if active {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }.frame(width: 14, height: 14)
                    Text(step.title)
                    Spacer(minLength: 8)
                    if let detail = step == .sync ? progress.source : step == .name ? progress.branch : nil {
                        Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(detail)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(complete ? "Complete" : active ? (progress.error == nil ? "In progress" : "Stopped") : "Waiting")
            }
            if let error = progress.error {
                Text(error).foregroundStyle(.secondary).lineLimit(3).help(error).textSelection(.enabled)
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14)
            .fill(Color.primary.opacity(0.035)))
    }
}

private struct ChatProjectContextControls: View {
    let project: ChatProject?
    let rootIsAvailable: Bool
    let toolsEnabled: Bool
    @ObservedObject var chat: ChatViewModel
    @State private var setupError: String?
    @State private var gitHead: ChatGitHead?
    var isSummary = false

    private var path: String {
        chat.currentWorktree?.isReady == false ? project?.rootPath ?? "" : chat.currentWorktree?.projectPath ?? project?.rootPath ?? ""
    }
    private var available: Bool {
        chat.currentWorktree?.isReady == false ? rootIsAvailable : chat.currentWorktree.map { $0.availableRootPath != nil } ?? rootIsAvailable
    }

    private var branch: String? { gitHead?.displayName }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                projectMenu
                if !isSummary, let branch {
                    branchLabel(branch)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(branch)
                }
                Spacer(minLength: 4)
                if chat.isPreparingCurrentWorktree || chat.isDeletingCurrentSession {
                    ProgressView().controlSize(.small)
                }
                HStack(spacing: 6) {
                    Text("Worktree")
                    Toggle("Worktree", isOn: Binding(
                        get: { chat.currentWorktree != nil },
                        set: { enabled in
                            setupError = nil
                            Task {
                                do { try await chat.setCurrentWorktreeEnabled(enabled) }
                                catch { setupError = error.localizedDescription }
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!chat.canChangeCurrentWorktree)
                }
                .fixedSize()
                .help(chat.currentWorktree?.isReady == true
                      ? "This chat uses its own worktree"
                      : "Use a separate checkout when you send your first message")
                if !isSummary && (!available || !toolsEnabled) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(available ? Color.secondary : Color.orange)
                        .help(available ? "Project tools are off" : "Project folder unavailable")
                        .accessibilityLabel(available ? "Project tools are off" : "Project folder unavailable")
                }
            }
            if let setupError {
                Text(setupError).foregroundStyle(.red).textSelection(.enabled)
            }
            if isSummary {
                Divider()
                if let branch {
                    branchLabel(branch)
                        .lineLimit(2).textSelection(.enabled)
                }
                Text(path)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Divider()
                LabeledContent("Project tools", value: available ? (toolsEnabled ? "Enabled" : "Off") : "Folder unavailable")
                LabeledContent("Files", value: "\(chat.workState.items.filter(\.canEdit).count)")
            }
        }
        .font(.system(size: 12))
        .padding(isSummary ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !isSummary {
                UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14)
                    .fill(Color.primary.opacity(0.035))
            }
        }
        .task(id: path) {
            gitHead = nil
            guard !path.isEmpty else { return }
            let directory = path
            let worktree = chat.currentWorktree
            // This runs only while the controls are visible. It also catches branch changes
            // from the user's shell, not just commands invoked by the agent.
            while !Task.isCancelled {
                let head = await Task.detached {
                    if let worktree, worktree.isReady { return worktree.currentHead }
                    return try? ChatGitWorktreeStore(root: URL(fileURLWithPath: directory)).currentHead(at: directory)
                }.value
                guard !Task.isCancelled else { return }
                gitHead = head
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private var projectMenu: some View {
        Menu {
            if chat.currentWorktree?.isReady == false {
                Text("Setup starts when you send a message")
            }
            switch gitHead {
            case .branch(let name):
                Button("Copy branch name", systemImage: "doc.on.doc") { copy(name) }
            case .detached(let commit):
                Button("Copy commit ID", systemImage: "doc.on.doc") { copy(commit) }
            case nil: EmptyView()
            }
            Divider()
            Button("Copy folder path", systemImage: "doc.on.doc") { copy(path) }
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            }.disabled(!available)
        } label: {
            Label(project?.name ?? "Worktree", systemImage: available ? "folder" : "folder.badge.questionmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(available ? Color.secondary : Color.orange)
                .lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help(path)
        .accessibilityLabel("Project folder")
    }

    private func branchLabel(_ name: String) -> some View {
        Label {
            Text(name)
        } icon: {
            Image(systemName: "arrow.triangle.branch")
                .rotationEffect(.degrees(90))
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct ChatPinnedSummaryToggle: View {
    let project: ChatProject?
    let rootIsAvailable: Bool
    let toolsEnabled: Bool
    @ObservedObject var chat: ChatViewModel
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isPresented ? Color.primary : Color.secondary)
                .frame(width: ControlPanelLayout.topControlSize, height: ControlPanelLayout.topControlSize)
                .background(isPresented ? Color.primary.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isPresented ? "Hide pinned summary" : "Show pinned summary")
        .accessibilityLabel("Pinned summary")
        .accessibilityValue(isPresented ? "Shown" : "Hidden")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pinned summary").font(.headline)
                ChatProjectContextControls(project: project, rootIsAvailable: rootIsAvailable,
                                           toolsEnabled: toolsEnabled, chat: chat, isSummary: true)
            }
            .padding(20)
            .frame(width: 340)
        }
        .onChange(of: chat.currentSessionID) { _, _ in isPresented = false }
    }
}

private struct ChatTranscriptView: View {
    var model: NativModel
    @ObservedObject var chat: ChatViewModel
    @ObservedObject var extensionManager: NativExtensionManager
    let project: ChatProject?
    let projectRootIsAvailable: Bool
    let workspaceMode: ChatWorkspaceMode
    let onSelectWorkspaceMode: (ChatWorkspaceMode) -> Void
    let onExploreImageModels: (ChatImageOperation) -> Void
    let onFindDraftModels: (String) -> Void
    let onAttachmentDropTargetChange: (Bool) -> Void
    let onPreviewAttachment: (ChatImageAttachment) -> Void
    @State private var composerHeight: CGFloat = 0
    @State private var composerBackdropHeight: CGFloat = 0
    @State private var search: ChatSearchState
    @Environment(\.chatLibrarySearch) private var librarySearch
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: NativModel, chat: ChatViewModel, extensionManager: NativExtensionManager,
         project: ChatProject?, projectRootIsAvailable: Bool, workspaceMode: ChatWorkspaceMode,
         onSelectWorkspaceMode: @escaping (ChatWorkspaceMode) -> Void,
         onExploreImageModels: @escaping (ChatImageOperation) -> Void,
         onFindDraftModels: @escaping (String) -> Void,
         onAttachmentDropTargetChange: @escaping (Bool) -> Void,
         onPreviewAttachment: @escaping (ChatImageAttachment) -> Void) {
        self.model = model
        self.chat = chat
        self.extensionManager = extensionManager
        self.project = project
        self.projectRootIsAvailable = projectRootIsAvailable
        self.workspaceMode = workspaceMode
        self.onSelectWorkspaceMode = onSelectWorkspaceMode
        self.onExploreImageModels = onExploreImageModels
        self.onFindDraftModels = onFindDraftModels
        self.onAttachmentDropTargetChange = onAttachmentDropTargetChange
        self.onPreviewAttachment = onPreviewAttachment
        _search = State(initialValue: ChatSearchState(library: chat.searchLibrary))
    }

    private var selectedModelID: String? {
        model.settings.normalized().languageModelID
    }

    var body: some View {
        let forkableAssistantResponseIDs = chat.forkableAssistantResponseIDs
        let latestUserMessageID = chat.latestUserMessageID
        let visibleItems = chat.visibleTranscriptItems

        transcript(
            items: visibleItems,
            forkableAssistantResponseIDs: forkableAssistantResponseIDs,
            latestUserMessageID: latestUserMessageID
        )
        .overlay(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                composerBackdrop
                composerSurface
            }
        }
        .background(Color.nativMainContentBackground)
        .environment(\.chatAnnotationActions, chat.annotationActions)
        .environment(\.canAddChatAnnotation, chat.pendingAnnotations.count < ChatAnnotation.maximumCount)
        .environment(\.chatSearchState, search)
        .focusedSceneValue(\.chatSearch, search)
        .onChange(of: chat.currentSessionID, initial: true) { _, id in
            search.reset(sessionID: id)
        }
        .onChange(of: search.query) { _, _ in
            search.update(queryChanged: true)
        }
        .onChange(of: search.query.isEmpty ? 0 : chat.searchLibrary.revision) { _, _ in
            if !search.query.isEmpty {
                search.update()
            }
        }
        .task(id: librarySearch?.destination?.id) {
            guard let destination = librarySearch?.takeDestination(for: chat.currentSessionID) else { return }
            search.reveal(destination.result.occurrence, query: destination.query,
                          sessionID: destination.result.sessionID)
        }
        .onDisappear { search.reset(sessionID: nil) }
    }

    private func transcript(
        items: [ChatTranscriptItem],
        forkableAssistantResponseIDs: Set<UUID>,
        latestUserMessageID: UUID?
    ) -> some View {
        ChatTranscriptScroller(
            currentSessionID: chat.currentSessionID,
            revision: chat.transcriptRevision,
            submissionID: chat.transcriptSubmissionID,
            scrollTargetMessageID: $chat.scrollTargetMessageID,
            itemIDs: items.map(\.id),
            searchNavigation: search.navigationRequest,
            onSearchNavigation: search.finishNavigation,
            bottomOverlayClearance: max(
                composerHeight,
                composerBackdropHeight + ChatTranscriptLayout.composerFadeExtension
            )
        ) { attachedRange in
            ChatTranscriptStack(items: Array(items[attachedRange])) {
                if chat.messages.isEmpty {
                    ChatEmptyTranscriptView(
                        isRunning: model.isRunning,
                        selectedModelID: selectedModelID,
                        modelLoadingProgress: model.isModelLoading
                            ? model.modelLoadingProgress : nil
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
                }
            } row: { item in
                transcriptItemRow(
                    item,
                    latestUserMessageID: latestUserMessageID,
                    forkableAssistantResponseIDs: forkableAssistantResponseIDs
                )
            } footer: {
                Color.clear
                    .frame(
                        height: max(
                            18,
                            composerHeight + ChatTranscriptLayout.composerClearance
                        )
                    )
                    .id(ChatTranscriptScrollTarget.bottom)
            }
            .frame(
                maxWidth: ChatTranscriptLayout.conversationMaxWidth
                    - (ChatTranscriptLayout.messageHorizontalInset * 2)
            )
            .frame(maxWidth: .infinity)
            .padding(
                .horizontal,
                ChatTranscriptLayout.horizontalPadding
                    + ChatTranscriptLayout.messageHorizontalInset
            )
            .padding(.top, 18)
        }
        .overlay(alignment: .topTrailing) {
            ZStack(alignment: .topTrailing) {
                if !chat.messages.isEmpty, project != nil || chat.currentWorktree != nil {
                    ChatPinnedSummaryToggle(project: project, rootIsAvailable: projectRootIsAvailable,
                                            toolsEnabled: model.settings.projectToolsEnabled, chat: chat)
                        .padding(.trailing, ControlPanelLayout.topControlsTrailingPadding
                                 + (chat.workState.isVisible ? 0 : ControlPanelLayout.topControlSize * 2))
                        .padding(.top, ControlPanelLayout.topControlsTopPadding)
                }
                if search.isPresented {
                    ChatSearchBar(search: search)
                        .padding(.leading, 16)
                        .padding(.trailing, ControlPanelLayout.topControlsTrailingPadding
                                 + ControlPanelLayout.topControlSize * (chat.workState.isVisible ? 1 : 3) + 12)
                        .padding(.top, 8)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: search.isPresented)
        }
    }

    @ViewBuilder
    private func transcriptItemRow(
        _ item: ChatTranscriptItem,
        latestUserMessageID: UUID?,
        forkableAssistantResponseIDs: Set<UUID>
    ) -> some View {
        switch item {
        case .message(let message):
            messageRow(
                message,
                latestUserMessageID: latestUserMessageID,
                forkableAssistantResponseIDs: forkableAssistantResponseIDs
            )
            .id(item.id)
        case .agentTurn(let turn):
            ChatAgentTurnRow(
                turn: turn,
                prefillProgress: turn.isAssistantStreaming ? model.prefillProgress : .init(),
                imageModelSelectionRequests: imageModelSelectionRequests(for: turn),
                canForkAssistantResponse: turn.finalAssistantMessage.map {
                    forkableAssistantResponseIDs.contains($0.id)
                } ?? false,
                onForkAssistantResponse: chat.forkAssistantResponse,
                onConfirmToolConsent: chat.confirmToolConsent,
                onDenyToolConsent: chat.denyToolConsent,
                onSelectImageModel: chat.selectImageModel,
                onCancelImageModelSelection: chat.cancelImageModelSelection,
                onExploreImageModels: onExploreImageModels,
                onPreviewAttachment: onPreviewAttachment
            )
            .id(item.id)
        }
    }

    private func messageRow(
        _ message: ChatTranscriptMessage,
        latestUserMessageID: UUID?,
        forkableAssistantResponseIDs: Set<UUID>
    ) -> some View {
        let showsEditUserMessage = message.id == latestUserMessageID
        let editUnavailableReason = showsEditUserMessage
            ? userPromptEditingUnavailableReason(for: message)
            : nil

        return ChatMessageRow(
            message: message,
            imageModelSelectionRequest: chat.imageModelSelectionRequest(for: message.id),
            showsEditUserMessage: showsEditUserMessage,
            canEditUserMessage: editUnavailableReason == nil,
            editUserMessageUnavailableReason: editUnavailableReason,
            isEditingUserMessage: chat.promptEditContext?.messageID == message.id,
            canForkAssistantResponse: forkableAssistantResponseIDs.contains(message.id),
            onEditUserMessage: chat.beginEditingUserMessage,
            onForkAssistantResponse: chat.forkAssistantResponse,
            onConfirmToolConsent: chat.confirmToolConsent,
            onDenyToolConsent: chat.denyToolConsent,
            onSelectImageModel: chat.selectImageModel,
            onCancelImageModelSelection: chat.cancelImageModelSelection,
            onExploreImageModels: onExploreImageModels,
            onPreviewAttachment: onPreviewAttachment,
            prefillProgress: message.role == .assistant && message.isStreaming
                ? model.prefillProgress : .init()
        )
        .equatable()
        .id(message.id)
    }

    private var composerSurface: some View {
        ChatComposerContainer(
            model: model,
            chat: chat,
            extensionManager: extensionManager,
            project: project,
            projectRootIsAvailable: projectRootIsAvailable,
            workspaceMode: workspaceMode,
            onSelectWorkspaceMode: onSelectWorkspaceMode,
            onFindDraftModels: onFindDraftModels,
            onAttachmentDropTargetChange: onAttachmentDropTargetChange,
            onBackdropHeightChange: { composerBackdropHeight = $0 }
        )
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            composerHeight = height
        }
        .zIndex(1)
    }

    private var composerBackdrop: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Color.nativMainContentBackground.opacity(0),
                    Color.nativMainContentBackground.opacity(0.84),
                    Color.nativMainContentBackground,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: ChatTranscriptLayout.composerFadeExtension)

            Color.nativMainContentBackground
                .frame(height: max(72, composerBackdropHeight))
        }
        .padding(.trailing, ChatTranscriptLayout.scrollIndicatorClearance)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func imageModelSelectionRequests(
        for turn: ChatAgentTurnPresentation
    ) -> [UUID: ChatImageModelSelectionRequest] {
        Dictionary(
            uniqueKeysWithValues: turn.toolMessages.compactMap { message in
                chat.imageModelSelectionRequest(for: message.id).map { (message.id, $0) }
            }
        )
    }

    private func userPromptEditingUnavailableReason(
        for message: ChatTranscriptMessage
    ) -> String? {
        guard message.role == .user else {
            return "Only user prompts can be edited"
        }
        guard chat.canEditUserMessage(message.id) else {
            return "Stop the response and remove queued prompts before editing"
        }
        guard model.isRunning else {
            return "Start the server before editing a prompt"
        }
        guard !model.isModelLoading else {
            return "Wait for the model to finish loading"
        }
        guard selectedModelID?.isEmpty == false else {
            return "Choose a language model before editing a prompt"
        }
        if let validationError = model.settings.structuredOutputValidationError {
            return validationError
        }
        return nil
    }
}

private struct ChatComposerContainer: View {
    var model: NativModel
    @ObservedObject var chat: ChatViewModel
    @ObservedObject var extensionManager: NativExtensionManager
    let project: ChatProject?
    let projectRootIsAvailable: Bool
    let workspaceMode: ChatWorkspaceMode
    let onSelectWorkspaceMode: (ChatWorkspaceMode) -> Void
    let onFindDraftModels: (String) -> Void
    let onAttachmentDropTargetChange: (Bool) -> Void
    let onBackdropHeightChange: (CGFloat) -> Void

    private var selectedModelID: String? {
        model.settings.normalized().languageModelID
    }

    var body: some View {
        ChatComposer(
            model: model,
            viewModel: chat,
            extensionManager: extensionManager,
            unavailableReason: model.modelLoadingStatusText
                ?? chat.unavailableReason(
                    isRunning: model.isRunning, selectedModelID: selectedModelID)
                ?? model.settings.structuredOutputValidationError,
            canCompose: (model.isRunning || model.isModelLoading)
                && selectedModelID?.isEmpty == false
                && model.settings.structuredOutputValidationError == nil
                && !chat.isCurrentSessionActiveInAnotherWindow,
            canSend: !model.isModelLoading
                && model.settings.structuredOutputValidationError == nil
                && chat.canSend(isRunning: model.isRunning, selectedModelID: selectedModelID),
            workspaceMode: workspaceMode,
            onSelectWorkspaceMode: onSelectWorkspaceMode,
            onFindDraftModels: onFindDraftModels,
            onAttachmentDropTargetChange: onAttachmentDropTargetChange,
            onSend: { languageModelSupportsTools, languageModelSupportsVision in
                chat.send(
                    using: model,
                    languageModelSupportsTools: languageModelSupportsTools,
                    languageModelSupportsVision: languageModelSupportsVision
                )
            },
            onBackdropHeightChange: onBackdropHeightChange,
            contextHeader: contextHeader
        )
        .frame(maxWidth: ChatTranscriptLayout.conversationMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ChatTranscriptLayout.horizontalPadding)
        .transformPreference(ChatComposerMinimumWidthKey.self) { width in
            if width > 0 { width += ChatTranscriptLayout.horizontalPadding * 2 }
        }
    }

    @ViewBuilder
    private var contextHeader: some View {
        if let progress = chat.currentWorktreeSetupProgress {
            ChatWorktreeSetupView(progress: progress, dismiss: chat.dismissWorktreeSetupProgress)
        } else if chat.messages.isEmpty, project != nil || chat.currentWorktree != nil {
            ChatProjectContextControls(project: project, rootIsAvailable: projectRootIsAvailable,
                                       toolsEnabled: model.settings.projectToolsEnabled, chat: chat)
        }
    }
}

private struct ChatMessageRow: View, @MainActor Equatable {
    private static let maximumUserBubbleWidth: CGFloat = 560

    let message: ChatTranscriptMessage
    let imageModelSelectionRequest: ChatImageModelSelectionRequest?
    let showsEditUserMessage: Bool
    let canEditUserMessage: Bool
    let editUserMessageUnavailableReason: String?
    let isEditingUserMessage: Bool
    let canForkAssistantResponse: Bool
    let onEditUserMessage: (UUID) -> Void
    let onForkAssistantResponse: (UUID) -> Void
    let onConfirmToolConsent: (UUID) -> Void
    let onDenyToolConsent: (UUID) -> Void
    let onSelectImageModel: (UUID, String) -> Void
    let onCancelImageModelSelection: (UUID) -> Void
    let onExploreImageModels: (ChatImageOperation) -> Void
    let onPreviewAttachment: (ChatImageAttachment) -> Void
    var displaysModelTitle = true
    var displaysThinking = true
    var prefillProgress = NativPrefillProgressState()
    @State private var didCopyMessage = false
    @State private var isHoveringMessage = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
            && lhs.imageModelSelectionRequest == rhs.imageModelSelectionRequest
            && lhs.showsEditUserMessage == rhs.showsEditUserMessage
            && lhs.canEditUserMessage == rhs.canEditUserMessage
            && lhs.editUserMessageUnavailableReason == rhs.editUserMessageUnavailableReason
            && lhs.isEditingUserMessage == rhs.isEditingUserMessage
            && lhs.canForkAssistantResponse == rhs.canForkAssistantResponse
            && lhs.displaysModelTitle == rhs.displaysModelTitle
            && lhs.displaysThinking == rhs.displaysThinking
            && lhs.prefillProgress == rhs.prefillProgress
    }

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            if displaysModelTitle && !title.isEmpty {
                HStack(spacing: 8) {
                    Text(title)
                    ServerPrefillProgressLabel(progress: prefillProgress)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if message.role == .tool {
                ChatAgentStepCell(
                    message: message,
                    imageModelSelectionRequest: imageModelSelectionRequest,
                    onConfirm: onConfirmToolConsent,
                    onDeny: onDenyToolConsent,
                    onSelectImageModel: onSelectImageModel,
                    onCancelImageModelSelection: onCancelImageModelSelection,
                    onExploreImageModels: onExploreImageModels
                )
            }

            VStack(alignment: contentStackAlignment, spacing: 6) {
                if !message.imageAttachments.isEmpty {
                    ChatImageAttachmentStack(
                        attachments: message.imageAttachments,
                        isUserMessage: message.role == .user,
                        showsSaveButton: message.role == .tool,
                        onPreview: onPreviewAttachment
                    )
                }

                if displaysThinkingBubble {
                    ChatThinkingBubble(
                        content: message.reasoningContent,
                        isThinking: message.isStreaming && message.content.isEmpty,
                        isStreaming: message.isStreaming,
                        thinkingDuration: message.thinkingDuration
                    )
                }

                if !message.annotationPresentation.annotations.isEmpty {
                    ChatAnnotationCards(annotations: message.annotationPresentation.annotations)
                }
                if showsTextContent {
                    if message.role == .user, !message.pastedTexts.isEmpty {
                        pastedTextContent
                    } else {
                        textBubble(displayContent)
                    }
                }
            }

            if let responseMetrics {
                ChatResponseMetricsRow(metrics: responseMetrics)
            }

            if showsMessageActions {
                HStack(spacing: 8) {
                    HStack(spacing: 0) {
                        if canCopyMessage {
                            ChatCopyMessageButton(
                                didCopy: didCopyMessage,
                                messageKind: message.role == .user ? "prompt" : "response",
                                onCopy: copyMessage
                            )
                        }

                        if showsEditUserMessage {
                            ChatMessageActionButton(
                                icon: .system("square.and.pencil"),
                                title: editActionTitle,
                                isActive: isEditingUserMessage,
                                isEnabled: canEditUserMessage
                            ) {
                                onEditUserMessage(message.id)
                            }
                        }

                        if canForkAssistantResponse {
                            ChatMessageActionButton(
                                icon: .asset("ChatForkIcon"),
                                title: "Fork chat from this response",
                                isActive: false,
                                isEnabled: true
                            ) {
                                onForkAssistantResponse(message.id)
                            }
                        }
                    }

                    Text(message.createdAt, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                // Align the visible icons with the response text, keeping their full hit areas.
                .padding(.leading, message.role == .assistant ? -10 : 0)
                .opacity(isHoveringMessage || didCopyMessage || isEditingUserMessage ? 1 : 0)
                .accessibilityHidden(!isHoveringMessage && !didCopyMessage && !isEditingUserMessage)
            }
        }
        .frame(maxWidth: .infinity, alignment: rowAlignment)
        .contentShape(.rect)
        .onHover { isHoveringMessage = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHoveringMessage)
    }

    @ViewBuilder
    private var pastedTextContent: some View {
        let items = ChatPastedText.validated(message.pastedTexts, in: message.content)
        let source = message.content as NSString
        if items.isEmpty {
            textBubble(displayContent)
        } else {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let start = index == 0 ? 0 : NSMaxRange(items[index - 1].range)
                if item.location > start {
                    textBubble(source.substring(with: NSRange(location: start, length: item.location - start)))
                }
                ChatPastedTextCard(pastedText: item)
                if index == items.count - 1, NSMaxRange(item.range) < source.length {
                    textBubble(source.substring(from: NSMaxRange(item.range)))
                }
            }
        }
    }

    @ViewBuilder
    private func textBubble(_ content: String) -> some View {
        let usesCompactBubble = !content.contains(where: \.isNewline) && content.count <= 72
        Group {
            if usesCompactBubble {
                ChatMessageText(
                    messageID: message.id,
                    content: content,
                    rendersMarkdown: rendersMarkdown,
                    isStreaming: message.isStreaming,
                    isUserPrompt: message.role == .user
                )
                .lineSpacing(2)
                .fixedSize(horizontal: true, vertical: false)
            } else {
                ChatMessageText(
                    messageID: message.id,
                    content: content,
                    rendersMarkdown: rendersMarkdown,
                    isStreaming: message.isStreaming,
                    isUserPrompt: message.role == .user
                )
                .lineSpacing(2)
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, alignment: alignment)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(ChatSelectionReplyModifier(message: message))
        .font(.body)
        .padding(.horizontal, message.role == .assistant ? 0 : 12)
        .padding(.vertical, message.role == .assistant ? 3 : 9)
        .frame(maxWidth: message.role == .user && !usesCompactBubble ? Self.maximumUserBubbleWidth : nil,
               alignment: alignment)
        .foregroundStyle(foregroundStyle)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: message.role == .error ? 1 : 0.5)
        )
    }

    private var title: String {
        switch message.role {
        case .user:
            return ""
        case .assistant:
            return message.modelID.map { NativFormatting.truncateModelName($0, maxLength: 42) }
                ?? "Assistant"
        case .tool:
            return ""
        case .error:
            return "Error"
        }
    }

    private var rowAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var alignment: Alignment {
        .leading
    }

    private var textAlignment: TextAlignment {
        .leading
    }

    private var contentStackAlignment: HorizontalAlignment {
        message.role == .user ? .trailing : .leading
    }

    private var displayContent: String {
        let content = message.annotationPresentation.content
        return content.isEmpty ? " " : content
    }

    private var showsTextContent: Bool {
        if message.role == .tool {
            return false
        }
        return !message.content.isEmpty
            || (!displaysThinkingBubble
                && (message.imageAttachments.isEmpty || message.isStreaming))
    }

    private var displaysThinkingBubble: Bool {
        displaysThinking && hasThinkingContent
    }

    private var hasThinkingContent: Bool {
        guard message.role == .assistant else {
            return false
        }
        return !message.reasoningContent.isEmpty
            || (message.isThinkingEnabled && message.isStreaming && message.content.isEmpty)
    }

    private var rendersMarkdown: Bool {
        message.role == .assistant
    }

    private var foregroundStyle: Color {
        message.role == .user ? .white : Color(nsColor: .labelColor)
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user:
            return .accentColor
        case .assistant:
            return .clear
        case .tool:
            return Color(nsColor: .controlBackgroundColor)
        case .error:
            return Color(nsColor: .systemRed).opacity(0.12)
        }
    }

    private var borderColor: Color {
        switch message.role {
        case .user:
            return .clear
        case .assistant:
            return .clear
        case .tool:
            return Color(nsColor: .separatorColor)
        case .error:
            return Color(nsColor: .systemRed).opacity(0.45)
        }
    }

    private var responseMetrics: ChatResponseMetrics? {
        guard message.role == .assistant,
            !message.isStreaming,
            let responseMetrics = message.responseMetrics,
            responseMetrics.hasVisibleValues
        else {
            return nil
        }

        return responseMetrics
    }

    private var canCopyMessage: Bool {
        (message.role == .user || message.role == .assistant)
            && !message.isStreaming
            && !message.content.isEmpty
    }

    private var showsMessageActions: Bool {
        message.role == .user || canCopyMessage || canForkAssistantResponse
    }

    private var editActionTitle: String {
        if isEditingUserMessage {
            return "Editing prompt"
        }
        if canEditUserMessage {
            return "Edit prompt"
        }
        return editUserMessageUnavailableReason ?? "Prompt editing is temporarily unavailable"
    }

    private func copyMessage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.content, forType: .string)

        withAnimation(.easeInOut(duration: 0.15)) {
            didCopyMessage = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeInOut(duration: 0.15)) {
                didCopyMessage = false
            }
        }
    }
}

private struct ChatAgentTurnRow: View {
    let turn: ChatAgentTurnPresentation
    var prefillProgress = NativPrefillProgressState()
    let imageModelSelectionRequests: [UUID: ChatImageModelSelectionRequest]
    let canForkAssistantResponse: Bool
    let onForkAssistantResponse: (UUID) -> Void
    let onConfirmToolConsent: (UUID) -> Void
    let onDenyToolConsent: (UUID) -> Void
    let onSelectImageModel: (UUID, String) -> Void
    let onCancelImageModelSelection: (UUID) -> Void
    let onExploreImageModels: (ChatImageOperation) -> Void
    let onPreviewAttachment: (ChatImageAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(modelTitle)
                ServerPrefillProgressLabel(progress: prefillProgress)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if showsThinkingBubble {
                ChatThinkingBubble(
                    content: turn.reasoningContent,
                    isThinking: turn.isThinking,
                    isStreaming: turn.isAssistantStreaming,
                    thinkingDuration: turn.thinkingDuration
                )
            }

            if !turn.toolMessages.isEmpty {
                ChatToolUsageSummaryRow(
                    turn: turn,
                    imageModelSelectionRequests: imageModelSelectionRequests,
                    onConfirmToolConsent: onConfirmToolConsent,
                    onDenyToolConsent: onDenyToolConsent,
                    onSelectImageModel: onSelectImageModel,
                    onCancelImageModelSelection: onCancelImageModelSelection,
                    onExploreImageModels: onExploreImageModels
                )
            }

            ForEach(toolMessagesWithAttachments) { message in
                ChatImageAttachmentStack(
                    attachments: message.imageAttachments,
                    isUserMessage: false,
                    showsSaveButton: true,
                    onPreview: onPreviewAttachment
                )
            }

            if let finalAssistantMessage = turn.finalAssistantMessage,
                shouldRender(finalAssistantMessage)
            {
                ChatMessageRow(
                    message: finalAssistantMessage,
                    imageModelSelectionRequest: nil,
                    showsEditUserMessage: false,
                    canEditUserMessage: false,
                    editUserMessageUnavailableReason: nil,
                    isEditingUserMessage: false,
                    canForkAssistantResponse: canForkAssistantResponse,
                    onEditUserMessage: { _ in },
                    onForkAssistantResponse: onForkAssistantResponse,
                    onConfirmToolConsent: onConfirmToolConsent,
                    onDenyToolConsent: onDenyToolConsent,
                    onSelectImageModel: onSelectImageModel,
                    onCancelImageModelSelection: onCancelImageModelSelection,
                    onExploreImageModels: onExploreImageModels,
                    onPreviewAttachment: onPreviewAttachment,
                    displaysModelTitle: false,
                    displaysThinking: false
                )
                .equatable()
                .id(finalAssistantMessage.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelTitle: String {
        turn.modelID.map { NativFormatting.truncateModelName($0, maxLength: 42) }
            ?? "Assistant"
    }

    private var showsThinkingBubble: Bool {
        !turn.reasoningContent.isEmpty || turn.isThinking
    }

    private var toolMessagesWithAttachments: [ChatTranscriptMessage] {
        turn.toolMessages.filter { !$0.imageAttachments.isEmpty }
    }

    private func shouldRender(_ message: ChatTranscriptMessage) -> Bool {
        !message.content.isEmpty
            || !message.imageAttachments.isEmpty
            || message.responseMetrics != nil
            || canForkAssistantResponse
    }
}

private struct ChatToolUsageSummaryRow: View {
    let turn: ChatAgentTurnPresentation
    let imageModelSelectionRequests: [UUID: ChatImageModelSelectionRequest]
    let onConfirmToolConsent: (UUID) -> Void
    let onDenyToolConsent: (UUID) -> Void
    let onSelectImageModel: (UUID, String) -> Void
    let onCancelImageModelSelection: (UUID) -> Void
    let onExploreImageModels: (ChatImageOperation) -> Void
    @State private var isExpanded = false

    private var summary: ChatToolUsageSummary {
        turn.toolUsage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    statusIcon

                    Text(summary.text)
                        .font(.callout)
                        .foregroundStyle(summaryColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide tool details" : "Show tool details")

            if isExpanded || summary.requiresInteraction {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(detailMessages) { message in
                        if message.role == .tool {
                            ChatAgentStepCell(
                                message: message,
                                imageModelSelectionRequest: imageModelSelectionRequests[
                                    message.id
                                ],
                                onConfirm: onConfirmToolConsent,
                                onDeny: onDenyToolConsent,
                                onSelectImageModel: onSelectImageModel,
                                onCancelImageModelSelection: onCancelImageModelSelection,
                                onExploreImageModels: onExploreImageModels
                            )
                        } else if !message.content.isEmpty {
                            ChatIntermediateAssistantContent(message: message)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary.text)
    }

    private var detailMessages: [ChatTranscriptMessage] {
        let finalAssistantID = turn.finalAssistantMessage?.id
        return turn.messages.filter { message in
            message.id != finalAssistantID
                && (message.role == .tool
                    || (message.role == .assistant && !message.content.isEmpty))
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if summary.requiresInteraction {
            Image(systemName: statusSymbolName)
                .foregroundStyle(summaryColor)
        } else if summary.hasFailure {
            Image(systemName: statusSymbolName)
                .foregroundStyle(summaryColor)
        } else if summary.isActive {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: statusSymbolName)
                .foregroundStyle(summaryColor)
        }
    }

    private var statusSymbolName: String {
        if summary.requiresInteraction {
            return "questionmark.circle"
        }
        if summary.hasFailure {
            return "exclamationmark.triangle.fill"
        }
        if summary.hasNonSuccess {
            return "xmark.circle"
        }
        return "book"
    }

    private var summaryColor: Color {
        if summary.requiresInteraction {
            return .orange
        }
        if summary.hasFailure {
            return .red
        }
        return .secondary
    }
}

private struct ChatIntermediateAssistantContent: View {
    let message: ChatTranscriptMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let modelID = message.modelID {
                Text(NativFormatting.truncateModelName(modelID, maxLength: 42))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ChatMessageText(
                content: message.content,
                rendersMarkdown: true,
                isStreaming: message.isStreaming
            )
            .font(.callout)
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            if let responseMetrics = message.responseMetrics,
                responseMetrics.hasVisibleValues
            {
                ChatResponseMetricsRow(metrics: responseMetrics)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ChatAgentStepCell: View {
    let message: ChatTranscriptMessage
    let imageModelSelectionRequest: ChatImageModelSelectionRequest?
    let onConfirm: (UUID) -> Void
    let onDeny: (UUID) -> Void
    let onSelectImageModel: (UUID, String) -> Void
    let onCancelImageModelSelection: (UUID) -> Void
    let onExploreImageModels: (ChatImageOperation) -> Void
    @State private var isExpanded = false

    private var isAwaitingConsent: Bool {
        message.toolStatus == .awaitingConsent
    }

    private var isAwaitingImageModelSelection: Bool {
        message.toolStatus == .awaitingImageModelSelection
            && imageModelSelectionRequest != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide call details" : "Show call details")
            .disabled(isAwaitingConsent || isAwaitingImageModelSelection)

            if isAwaitingImageModelSelection {
                Divider()
                    .padding(.top, 7)
                imageModelSelectionPrompt
            } else if isAwaitingConsent {
                Divider()
                    .padding(.top, 7)
                consentPrompt
            } else if isExpanded {
                Divider()
                    .padding(.top, 7)
                details
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(accessibilityStatus)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if message.toolStatus == .running {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: symbolName)
                        .foregroundStyle(tintColor)
                }

                Text(title)
                    .font(.callout.weight(.medium))
                if let mcpServerSlug {
                    NativStatusBadge(
                        text: mcpServerSlug, tone: .neutral, symbol: "puzzlepiece.extension")
                }
                statusBadge

                Spacer(minLength: 12)

                if !isAwaitingConsent && !isAwaitingImageModelSelection {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            if message.toolStatus == .failed, let toolErrorMessage {
                Text(toolErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch message.toolStatus {
        case .succeeded:
            NativStatusBadge(text: "Done", tone: .success)
        case .failed:
            NativStatusBadge(text: "Failed", tone: .danger)
        case .cancelled:
            NativStatusBadge(text: "Canceled", tone: .neutral)
        case .declined:
            NativStatusBadge(text: "Declined", tone: .neutral)
        case .preparing, .running, .awaitingConsent,
            .awaitingImageModelSelection, nil:
            EmptyView()
        }
    }

    private var consentPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let terminalRequest {
                terminalConsentPrompt(for: terminalRequest)
            } else {
                consentDescription
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if message.toolName == ChatWorkToolRegistry.toolName {
                ScrollView {
                    NativCodeBlock(raw: formattedArguments)
                }
                .frame(maxHeight: 180)
            }
            HStack(spacing: 8) {
                Button("Deny") {
                    onDeny(message.id)
                }
                .buttonStyle(.bordered)
                .help("Deny (Esc)")

                ChatToolConfirmationButton {
                    onConfirm(message.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 7)
    }

    private func terminalConsentPrompt(for request: ChatTerminalToolRequest) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(
                "The model wants to run this command on your Mac. Review it carefully before confirming."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let cwd = request.cwd {
                LabeledContent("Working directory") {
                    Text(cwd)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .font(.caption)
            }

            NativCodeBlock(raw: request.command, lineLimit: 10)

            ForEach(terminalAssessment.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var consentDescription: Text {
        if message.toolName == ChatWorkToolRegistry.toolName {
            if let data = message.content.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let description = payload["consent_description"] as? String {
                return Text(verbatim: description)
            }
            return Text("The agent wants to work in this chat’s side pane. Review the action and arguments below before allowing it.")
        }
        if message.toolName == ChatSwitchModelToolRegistry.toolName {
            return Text(
                "The model wants to switch to \(Text(verbatim: requestedModelID).bold()). The server restarts briefly; your session is kept."
            )
        }
        if let toolName = message.toolName,
            ChatFileWriteToolRegistry.toolNames.contains(toolName)
        {
            return Text(
                "The model wants to modify a protected instruction or credential configuration file in your authorized folder. Confirm to allow this change."
            )
        }
        return Text(
            "The model wants to run this script tool on your Mac. Confirm to allow its code to run."
        )
    }

    @ViewBuilder
    private var imageModelSelectionPrompt: some View {
        if let request = imageModelSelectionRequest {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose the model to use for \(request.operation.capabilityName).")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if request.models.isEmpty {
                    Text("No compatible downloaded models are available.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !request.installedModels.isEmpty {
                    imageModelSection(
                        title: "Downloaded",
                        models: request.installedModels,
                        defaultActionModelID: request.effectiveHighlightedModelID
                    )
                }

                if !request.downloadableModels.isEmpty {
                    imageModelSection(
                        title: "Available to download",
                        models: request.downloadableModels
                    )
                }

                HStack(spacing: 8) {
                    Button("Cancel") {
                        onCancelImageModelSelection(message.id)
                    }
                    .buttonStyle(.bordered)
                    .help("Cancel (Esc)")

                    Button("Open Models") {
                        onExploreImageModels(request.operation)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 7)
        }
    }

    private func imageModelSection(
        title: String,
        models: [ChatImageModelOption],
        defaultActionModelID: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ForEach(models) { model in
                ChatImageModelOptionRow(
                    model: model,
                    isDefaultAction: model.modelID == defaultActionModelID
                ) {
                    onSelectImageModel(message.id, model.modelID)
                }
            }
        }
    }

    private var requestedModelID: String {
        guard let data = message.toolArguments?.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let modelID = object["model_id"] as? String
        else {
            return "a different model"
        }
        return modelID
    }

    private var terminalRequest: ChatTerminalToolRequest? {
        guard message.toolName == ChatTerminalToolRegistry.toolName else { return nil }
        return try? ChatTerminalToolRequest(argumentsJSON: message.toolArguments)
    }

    private var terminalAssessment: TerminalCommandAssessment {
        guard let terminalRequest else {
            return TerminalCommandAssessment(blockedReason: nil, warnings: [])
        }
        return TerminalCommandSafetyPolicy.assess(command: terminalRequest.command)
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Arguments")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                NativCodeBlock(raw: formattedArguments)
            }
            if !message.content.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Result")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    NativCodeBlock(raw: message.content, lineLimit: 12)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 7)
    }

    private var formattedArguments: String {
        guard let toolArguments = message.toolArguments, !toolArguments.isEmpty else {
            return "{}"
        }
        return toolArguments
    }

    private var title: String {
        // For MCP tools show the bare tool name, not the mcp__slug__ prefix.
        let name = mcpToolParts?.tool ?? message.toolName
        return ChatToolPresentation.title(toolName: name, status: message.toolStatus)
    }

    private var symbolName: String {
        ChatToolPresentation.symbolName(toolName: message.toolName, status: message.toolStatus)
    }

    private var statusTone: NativStatusTone {
        switch message.toolStatus {
        case .preparing, .running: return .active
        case .succeeded: return .success
        case .failed: return .danger
        case .awaitingConsent, .awaitingImageModelSelection: return .warning
        case .cancelled, .declined, nil: return .neutral
        }
    }

    private var tintColor: Color {
        statusTone.color
    }

    /// Splits an MCP tool name (`mcp__<slug>__<tool>`) into its server slug and
    /// bare tool name; nil for built-in tools.
    private var mcpToolParts: (slug: String, tool: String)? {
        guard let name = message.toolName, name.hasPrefix("mcp__") else { return nil }
        let body = name.dropFirst("mcp__".count)
        guard let separator = body.range(of: "__") else { return nil }
        let slug = String(body[..<separator.lowerBound])
        let tool = String(body[separator.upperBound...])
        guard !slug.isEmpty, !tool.isEmpty else { return nil }
        return (slug, tool)
    }

    private var mcpServerSlug: String? { mcpToolParts?.slug }

    private var accessibilityStatus: String {
        switch message.toolStatus {
        case .preparing:
            "preparing"
        case .running:
            "running"
        case .succeeded:
            "succeeded"
        case .failed:
            "failed"
        case .cancelled:
            "canceled"
        case .awaitingConsent:
            "awaiting your confirmation"
        case .awaitingImageModelSelection:
            "awaiting image model selection"
        case .declined:
            "declined"
        case nil:
            "unknown"
        }
    }

    private var toolErrorMessage: String? {
        guard let data = message.content.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object["error"] as? String
    }
}

private struct ChatImageModelOptionRow: View {
    private static let downloadButtonLabelWidth: CGFloat = 180

    @ObservedObject private var downloadManager = HuggingFaceDownloadManager.shared
    @State private var isHovered = false

    let model: ChatImageModelOption
    var isDefaultAction = false
    let onChoose: () -> Void

    private var choosesOnRowClick: Bool {
        model.isInstalled && !isDefaultAction
    }

    private var rowBackground: Color {
        choosesOnRowClick && isHovered
            ? Color.primary.opacity(0.07)
            : Color(nsColor: .controlBackgroundColor)
    }

    @ViewBuilder
    var body: some View {
        if choosesOnRowClick {
            Button(action: onChoose) {
                rowContent
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityLabel("Use \(model.displayName)")
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(model.modelID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 12)
                trailingControl
            }

            if let error = downloadManager.errorByModelID[model.modelID] {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    isDefaultAction ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isDefaultAction ? 1.5 : 0.5
                )
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if model.isInstalled {
            if isDefaultAction {
                ChatToolConfirmationButton(
                    title: "Use",
                    systemImage: "chevron.right",
                    showsReturnHint: false,
                    accessibilityLabel: "Use \(model.displayName)",
                    action: onChoose
                )
            }
        } else if downloadManager.isDownloading(model.modelID) {
            ModelDownloadProgressControl(
                progress: downloadManager.progress(for: model.modelID),
                isPaused: downloadManager.isPaused(for: model.modelID),
                onPauseResume: {
                    if downloadManager.isPaused(for: model.modelID) {
                        downloadManager.resumeDownload(model.modelID)
                    } else {
                        downloadManager.pauseDownload(model.modelID)
                    }
                },
                onRemove: { downloadManager.removeDownload(model.modelID) }
            )
        } else {
            Button(action: onChoose) {
                Label(downloadTitle, systemImage: "arrow.down.circle")
                    .frame(width: Self.downloadButtonLabelWidth)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Download and use \(model.displayName)")
        }
    }

    private var downloadTitle: String {
        guard let sizeBytes = model.downloadSizeBytes else {
            return "Download"
        }
        let size = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        return "Download · \(size)"
    }
}

private struct ChatCopyMessageButton: View {
    let didCopy: Bool
    let messageKind: String
    let onCopy: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onCopy) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.medium))
                .foregroundStyle(
                    didCopy
                        ? Color.green
                        : (isHovering ? Color.primary : Color.secondary)
                )
                .frame(width: 30, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(didCopy ? "Copied" : "Copy \(messageKind)")
        .accessibilityLabel(didCopy ? "\(messageKind.capitalized) copied" : "Copy \(messageKind)")
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.15), value: didCopy)
    }
}

private struct ChatMessageActionButton: View {
    enum Icon {
        case system(String)
        case asset(String)
    }

    let icon: Icon
    let title: String
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            iconView
                .foregroundStyle(
                    isActive ? Color.accentColor : (isHovering ? Color.primary : Color.secondary)
                )
                .frame(width: 30, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(title)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
        case .asset(let name):
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
                .offset(y: 1)
        }
    }
}

private struct ChatThinkingBubble: View {
    private static let collapsedPreviewCharacterLimit = 1_000

    let content: String
    let isThinking: Bool
    let isStreaming: Bool
    let thinkingDuration: TimeInterval?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if isThinking {
                        ChatThinkingShimmerText("Working")
                    } else {
                        Text(completedTitle)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Show less reasoning" : "Show full reasoning")

            if isExpanded || isThinking {
                Divider()

                Group {
                    if isExpanded {
                        ChatMessageText(
                            content: content,
                            rendersMarkdown: true,
                            isStreaming: isStreaming
                        )
                        .font(.callout)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                    } else {
                        Text(collapsedPreviewContent)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(height: 58, alignment: .bottomLeading)
                            .clipped()
                            .padding(14)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.075), lineWidth: 0.75)
        }
        .animation(.easeInOut(duration: 0.2), value: isThinking)
        .accessibilityElement(children: .contain)
    }

    private var completedTitle: String {
        guard let thinkingDuration else {
            return "Worked"
        }
        return "Worked for \(NativFormatting.elapsedDuration(thinkingDuration))"
    }

    private var collapsedPreviewContent: String {
        String(content.suffix(Self.collapsedPreviewCharacterLimit))
    }
}

private struct ChatThinkingShimmerText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Group {
            if reduceMotion {
                label
                    .foregroundStyle(.secondary)
            } else {
                TimelineView(.animation) { context in
                    let duration = 1.65
                    let progress =
                        context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: duration) / duration

                    label
                        .foregroundStyle(Color.primary.opacity(0.38))
                        .overlay {
                            GeometryReader { proxy in
                                let beamWidth = max(34, proxy.size.width * 0.55)

                                LinearGradient(
                                    colors: [
                                        .clear,
                                        Color.secondary.opacity(0.25),
                                        Color.primary.opacity(0.75),
                                        .white,
                                        Color.primary.opacity(0.75),
                                        Color.secondary.opacity(0.25),
                                        .clear,
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: beamWidth)
                                .offset(
                                    x: -beamWidth
                                        + (proxy.size.width + beamWidth) * progress
                                )
                                .blur(radius: 1.1)
                            }
                            .mask(label)
                            .allowsHitTesting(false)
                        }
                }
            }
        }
        .fixedSize()
        .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(.callout.weight(.medium))
    }
}

private struct ChatResponseMetricsRow: View {
    let metrics: ChatResponseMetrics

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                metricPills
            }

            VStack(alignment: .leading, spacing: 6) {
                metricPills
            }
        }
        .padding(.top, 2)
        // Align the labels with the response text; the card border hangs into the margin.
        .padding(.leading, -ChatResponseMetricPill.horizontalPadding)
    }

    @ViewBuilder
    private var metricPills: some View {
        ChatResponseMetricPill(
            label: "Total tokens",
            value: NativFormatting.integer(metrics.totalTokens)
        )
        ChatResponseMetricPill(
            label: "Decode tok/s",
            value: NativFormatting.rate(metrics.decodeTokensPerSecond)
        )
        if let acceptanceRate = metrics.specAcceptanceRate {
            ChatResponseMetricPill(
                label: "Draft acceptance",
                value: acceptanceRate.formatted(.percent.precision(.fractionLength(0)))
            )
        }
        ChatResponseMetricPill(
            label: "Peak memory",
            value: metrics.peakMemoryGB.map(NativFormatting.gigabytes)
                ?? NativFormatting.missingValue
        )
    }
}

private struct ChatResponseMetricPill: View {
    static let horizontalPadding: CGFloat = 9

    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)

            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .help("\(label): \(value)")
    }
}

private struct ChatImageAttachmentStack: View {
    let attachments: [ChatImageAttachment]
    let isUserMessage: Bool
    let showsSaveButton: Bool
    let onPreview: (ChatImageAttachment) -> Void

    var body: some View {
        VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                ChatImageAttachmentView(
                    attachment: attachment,
                    showsSaveButton: showsSaveButton,
                    onPreview: { onPreview(attachment) }
                )
            }
        }
    }
}

private struct ChatImageAttachmentView: View {
    let attachment: ChatImageAttachment
    let showsSaveButton: Bool
    let onPreview: () -> Void
    @State private var saveErrorMessage: String?
    @State private var showsSaveError = false
    @State private var isSaveButtonHovered = false
    @State private var documentThumbnail: NSImage?

    private let maximumSideLength: CGFloat = 300

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button(action: onPreview) {
                preview
            }
            .buttonStyle(.plain)
            .help("Open \(attachment.filename)")
            .accessibilityLabel("Open \(attachment.filename)")

            if showsSaveButton,
                attachment.chatAttachmentKind == .image,
                attachment.imageData != nil
            {
                Button(action: saveImage) {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(
                            isSaveButtonHovered
                                ? Color.primary
                                : Color(nsColor: .secondaryLabelColor)
                        )
                        .frame(width: 30, height: 28)
                        .contentShape(.rect)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(
                                    isSaveButtonHovered
                                        ? Color(nsColor: .separatorColor)
                                        : .clear,
                                    lineWidth: 0.75
                                )
                        }
                }
                .buttonStyle(.plain)
                .help("Save image")
                .accessibilityLabel("Save image")
                .onHover { isSaveButtonHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isSaveButtonHovered)
            }
        }
        .help(attachment.filename)
        .accessibilityLabel(attachment.filename)
        .alert("Couldn’t save image", isPresented: $showsSaveError) {
            Button("OK", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(saveErrorMessage ?? "The image could not be saved.")
        }
        .task(id: attachment.id) {
            await loadDocumentThumbnail()
        }
    }

    @ViewBuilder
    private var preview: some View {
        Group {
            if let image = image ?? documentThumbnail {
                let size = displaySize(for: image)

                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .background(Color.white)
            } else {
                VStack(spacing: 8) {
                    FileTypeIcon(fileExtension: attachment.fileExtension, size: 48)
                    Text(attachment.filename)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(width: 180, height: 120)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var image: NSImage? {
        guard attachment.chatAttachmentKind == .image,
            let data = attachment.imageData
        else {
            return nil
        }
        return NSImage(data: data)
    }

    private func loadDocumentThumbnail() async {
        documentThumbnail = nil
        guard attachment.chatAttachmentKind != .image,
            let file = try? await ChatAttachmentPreviewFile.create(for: attachment)
        else {
            return
        }
        defer { file.remove() }

        let size = CGSize(width: maximumSideLength, height: maximumSideLength)
        let request = QLThumbnailGenerator.Request(
            fileAt: file.url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        guard
            let representation = try? await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request),
            !Task.isCancelled
        else {
            return
        }
        documentThumbnail = NSImage(cgImage: representation.cgImage, size: .zero)
    }

    private func displaySize(for image: NSImage) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: maximumSideLength, height: maximumSideLength)
        }

        let scale = min(1, maximumSideLength / max(image.size.width, image.size.height))
        return CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
    }

    private func saveImage() {
        guard let imageData = attachment.imageData else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [imageType]
        panel.nameFieldStringValue = attachment.filename
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try imageData.write(to: url, options: .atomic)
        } catch {
            saveErrorMessage = error.localizedDescription
            showsSaveError = true
        }
    }

    private var imageType: UTType {
        UTType(mimeType: attachment.mimeType)
            ?? UTType(filenameExtension: URL(fileURLWithPath: attachment.filename).pathExtension)
            ?? .png
    }
}

private struct ChatMessageText: View {
    var messageID: UUID? = nil
    let content: String
    let rendersMarkdown: Bool
    let isStreaming: Bool
    var isUserPrompt = false
    @Environment(\.chatFontScale) private var chatFontScale
    @Environment(\.chatSearchState) private var search
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    var body: some View {
        let highlight = messageID.flatMap { search?.highlight(for: $0) }
        if isUserPrompt {
            if let highlight {
                MarkdownView(content: content,
                             style: MarkdownStyle(fontSize: ChatFontMetrics.baseBodyPointSize * chatFontScale,
                                                  dark: colorScheme == .dark), plainText: true)
                    .environment(\.chatSearchHighlight, highlight)
            } else {
                Text(verbatim: content)
                    .textSelection(.enabled)
                    .font(ChatFontMetrics.bodyFont(scale: chatFontScale))
            }
        } else if rendersMarkdown {
            ChatMarkdownRenderer(
                messageID: messageID,
                content: content,
                isStreaming: isStreaming,
                fontScale: chatFontScale
            )
            .environment(\.chatSearchHighlight, highlight)
        } else {
            Text(verbatim: content)
                .textSelection(.enabled)
                .font(ChatFontMetrics.bodyFont(scale: chatFontScale))
        }
    }
}

extension Color {
    fileprivate static let nativMark = Color(
        nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor(white: 0.5, alpha: 1) : NSColor(white: 0.25, alpha: 1)
        })
}

private struct ChatEmptyTranscriptView: View {
    let isRunning: Bool
    let selectedModelID: String?
    let modelLoadingProgress: Double?

    var body: some View {
        VStack(spacing: 16) {
            Image("NativMark")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 64)
                .foregroundStyle(Color.nativMark)

            if let modelLoadingProgress {
                ProgressView(value: modelLoadingProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 180)
            }

            VStack(spacing: 7) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        if modelLoadingProgress != nil {
            return "Loading model"
        }
        if !isRunning {
            return "Server is stopped"
        }
        if selectedModelID == nil {
            return "No model selected"
        }
        return "No messages"
    }

    private var detail: String {
        if let modelLoadingProgress {
            let percentage = Int((modelLoadingProgress * 100).rounded())
            return "\(selectedModelID ?? "Model") · \(percentage)%"
        }
        if !isRunning {
            return "Start the server to chat."
        }
        if selectedModelID == nil {
            return "Choose a model in Models."
        }
        return selectedModelID ?? ""
    }
}

#Preview {
    ChatView(
        model: .init(),
        chat: ChatViewModel(),
        mcpHost: MCPHostManager(),
        extensionManager: NativExtensionManager(builtInExtensions: []),
        projects: ChatProjectStore(),
        workspaceMode: .chat,
        onSelectWorkspaceMode: { _ in },
        showsConfiguration: .constant(true),
        onExploreImageModels: { _ in },
        onFindDraftModels: { _ in }
    )
}

#Preview("Coalesced agent turns") {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            ChatAgentTurnPreviewRow(turn: .previewCompleted)
            Divider()
            ChatAgentTurnPreviewRow(turn: .previewRunning)
            Divider()
            ChatAgentTurnPreviewRow(turn: .previewFailed)
        }
        .padding(24)
    }
    .frame(width: 640, height: 720)
    .background(Color.nativMainContentBackground)
}

private struct ChatAgentTurnPreviewRow: View {
    let turn: ChatAgentTurnPresentation

    var body: some View {
        ChatAgentTurnRow(
            turn: turn,
            imageModelSelectionRequests: [:],
            canForkAssistantResponse: false,
            onForkAssistantResponse: { _ in },
            onConfirmToolConsent: { _ in },
            onDenyToolConsent: { _ in },
            onSelectImageModel: { _, _ in },
            onCancelImageModelSelection: { _ in },
            onExploreImageModels: { _ in },
            onPreviewAttachment: { _ in }
        )
    }
}

extension ChatAgentTurnPresentation {
    fileprivate static let previewCompleted = ChatAgentTurnPresentation(messages: [
        previewAssistant(
            id: "00000000-0000-0000-0000-000000000101",
            reasoning: "I’ll inspect the relevant files first.",
            duration: 1,
            callID: "read-1",
            toolName: ChatReadFileToolRegistry.toolName
        ),
        previewTool(
            id: "00000000-0000-0000-0000-000000000102",
            callID: "read-1",
            toolName: ChatReadFileToolRegistry.toolName,
            status: .succeeded
        ),
        previewAssistant(
            id: "00000000-0000-0000-0000-000000000103",
            reasoning: "A second file defines the rendering path.",
            duration: 4,
            callID: "read-2",
            toolName: ChatReadFileToolRegistry.toolName
        ),
        previewTool(
            id: "00000000-0000-0000-0000-000000000104",
            callID: "read-2",
            toolName: ChatReadFileToolRegistry.toolName,
            status: .succeeded
        ),
        previewAssistant(
            id: "00000000-0000-0000-0000-000000000105",
            reasoning: "I’ll run the focused tests.",
            duration: 3,
            callID: "terminal-1",
            toolName: ChatTerminalToolRegistry.toolName
        ),
        previewTool(
            id: "00000000-0000-0000-0000-000000000106",
            callID: "terminal-1",
            toolName: ChatTerminalToolRegistry.toolName,
            status: .succeeded
        ),
        ChatTranscriptMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000107")!,
            role: .assistant,
            content: "The repeated activity now renders as one compact agent turn.",
            modelID: "LiquidAI/LFM2.5-2.6B"
        ),
    ])

    fileprivate static let previewRunning = ChatAgentTurnPresentation(messages: [
        previewAssistant(
            id: "00000000-0000-0000-0000-000000000201",
            reasoning: "I need one current source to finish this answer.",
            duration: 2,
            callID: "search-1",
            toolName: ChatWebSearchToolRegistry.toolName
        ),
        previewTool(
            id: "00000000-0000-0000-0000-000000000202",
            callID: "search-1",
            toolName: ChatWebSearchToolRegistry.toolName,
            status: .running,
            isStreaming: true
        ),
    ])

    fileprivate static let previewFailed = ChatAgentTurnPresentation(messages: [
        previewAssistant(
            id: "00000000-0000-0000-0000-000000000301",
            reasoning: "I’ll inspect the requested file.",
            duration: 1,
            callID: "read-failed",
            toolName: ChatReadFileToolRegistry.toolName
        ),
        previewTool(
            id: "00000000-0000-0000-0000-000000000302",
            callID: "read-failed",
            toolName: ChatReadFileToolRegistry.toolName,
            status: .failed
        ),
    ])

    private static func previewAssistant(
        id: String,
        reasoning: String,
        duration: TimeInterval,
        callID: String,
        toolName: String
    ) -> ChatTranscriptMessage {
        ChatTranscriptMessage(
            id: UUID(uuidString: id)!,
            role: .assistant,
            content: "",
            reasoningContent: reasoning,
            modelID: "LiquidAI/LFM2.5-2.6B",
            thinkingDuration: duration,
            toolCalls: [
                MLXChatToolCall(
                    id: callID,
                    function: MLXChatFunctionCall(name: toolName, arguments: "{}")
                )
            ]
        )
    }

    private static func previewTool(
        id: String,
        callID: String,
        toolName: String,
        status: ChatTranscriptMessage.ToolStatus,
        isStreaming: Bool = false
    ) -> ChatTranscriptMessage {
        ChatTranscriptMessage(
            id: UUID(uuidString: id)!,
            role: .tool,
            content: status == .failed
                ? #"{"ok":false,"error":"The file could not be read."}"#
                : #"{"ok":true}"#,
            isStreaming: isStreaming,
            toolCallID: callID,
            toolName: toolName,
            toolStatus: status,
            toolArguments: "{}"
        )
    }
}
