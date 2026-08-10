import AppKit
import Foundation
import NativServerKit
import SwiftUI
import Textual
import UniformTypeIdentifiers

struct ChatQueuedPrompt: Identifiable, Equatable {
    let id: UUID
    let content: String
    let attachmentCount: Int
    let position: Int
}

struct ChatPromptEditContext: Equatable {
    let messageID: UUID
    let discardedMessageCount: Int
}

private struct ChatSessionBootstrap {
    let sessions: [ChatSession]
}

struct ChatView: View {
    @ObservedObject var model: NativModel
    let chat: ChatViewModel
    @ObservedObject var mcpHost: MCPHostManager
    let workspaceMode: ChatWorkspaceMode
    let onSelectWorkspaceMode: (ChatWorkspaceMode) -> Void
    @Binding var showsConfiguration: Bool
    let conversationWidthReduction: CGFloat
    let onExploreImageModels: (ChatImageOperation) -> Void
    @State private var isDropTargeted = false

    var body: some View {
        ModelConfigurationLayout(
            model: model,
            isConfigurationVisible: $showsConfiguration
        ) {
            ChatTranscriptView(
                model: model,
                chat: chat,
                workspaceMode: workspaceMode,
                onSelectWorkspaceMode: onSelectWorkspaceMode,
                conversationWidthReduction: conversationWidthReduction,
                onExploreImageModels: onExploreImageModels
            )
            .dropDestination(for: URL.self) { urls, _ in
                chat.attachImages(fromURLs: urls)
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    dropOverlay
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        }
        .background(Color.nativMainContentBackground)
        .onAppear {
            chat.mcpHost = mcpHost
            chat.refreshPendingImageModelSelections()
        }
        .onReceive(NotificationCenter.default.publisher(for: .routineDidSaveChatSession)) { _ in
            chat.reloadPersistedSessions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .localModelLibraryDidChange)) { _ in
            chat.refreshPendingImageModelSelections()
        }
        .environment(\.chatFontScale, model.settings.chatFontScale)
    }

    private var dropOverlay: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.72)
            VStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 34, weight: .semibold))
                Text("Drop files here")
                    .font(.system(size: 15, weight: .medium))
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

private struct ChatTranscriptView: View {
    private enum Layout {
        static let conversationMaxWidth: CGFloat = 680
        static let horizontalPadding: CGFloat = 32
    }

    @ObservedObject var model: NativModel
    @ObservedObject var chat: ChatViewModel
    let workspaceMode: ChatWorkspaceMode
    let onSelectWorkspaceMode: (ChatWorkspaceMode) -> Void
    let conversationWidthReduction: CGFloat
    let onExploreImageModels: (ChatImageOperation) -> Void
    @State private var transcriptScrollPosition = ScrollPosition(edge: .bottom)
    @State private var composerHeight: CGFloat = 0
    @State private var followsLatestMessage = true
    @State private var isUserScrollingTranscript = false

    private var selectedModelID: String? {
        model.settings.normalized().languageModelID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if chat.visibleMessages.isEmpty {
                    if chat.messages.isEmpty {
                        ChatEmptyTranscriptView(
                            isRunning: model.isRunning,
                            selectedModelID: selectedModelID,
                            modelLoadingProgress: model.isModelLoading ? model.modelLoadingProgress : nil
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                    }
                } else {
                    ForEach(chat.visibleMessages) { message in
                        let editUnavailableReason = userPromptEditingUnavailableReason(for: message)
                        ChatMessageRow(
                            message: message,
                            imageModelSelectionRequest: chat.imageModelSelectionRequest(
                                for: message.id
                            ),
                            canEditUserMessage: editUnavailableReason == nil,
                            editUserMessageUnavailableReason: editUnavailableReason,
                            isEditingUserMessage: chat.promptEditContext?.messageID == message.id,
                            onEditUserMessage: chat.beginEditingUserMessage,
                            onConfirmToolConsent: chat.confirmToolConsent,
                            onDenyToolConsent: chat.denyToolConsent,
                            onSelectImageModel: chat.selectImageModel,
                            onCancelImageModelSelection: chat.cancelImageModelSelection,
                            onExploreImageModels: onExploreImageModels
                        )
                        .equatable()
                        .id(message.id)
                    }
                }
            }
            .frame(maxWidth: Layout.conversationMaxWidth - conversationWidthReduction)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.top, 18)
            .padding(.bottom, max(18, composerHeight))
        }
        .scrollPosition($transcriptScrollPosition)
        .overlay(alignment: .bottom) {
            ChatComposerContainer(
                model: model,
                chat: chat,
                workspaceMode: workspaceMode,
                onSelectWorkspaceMode: onSelectWorkspaceMode,
                conversationWidthReduction: conversationWidthReduction,
                onHeightChange: { height in
                    let isInitialMeasurement = composerHeight == 0
                    composerHeight = height
                    if isInitialMeasurement {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(50))
                            transcriptScrollPosition.scrollTo(edge: .bottom)
                        }
                    }
                }
            )
        }
        .onScrollPhaseChange { _, newPhase, context in
            switch newPhase {
            case .tracking, .interacting:
                isUserScrollingTranscript = true
                followsLatestMessage = false
            case .decelerating:
                if isUserScrollingTranscript {
                    followsLatestMessage = false
                }
            case .idle:
                guard isUserScrollingTranscript else { return }
                isUserScrollingTranscript = false
                followsLatestMessage = isAtTranscriptBottom(context.geometry)
            case .animating:
                break
            }
        }
        .onChange(of: chat.scrollToken) { _, _ in
            if followsLatestMessage {
                transcriptScrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: chat.currentSessionID) { _, _ in
            followsLatestMessage = true
            transcriptScrollPosition.scrollTo(edge: .bottom)
        }
        .onChange(of: chat.scrollTargetMessageID) { _, target in
            guard let target else { return }
            followsLatestMessage = false
            DispatchQueue.main.async {
                transcriptScrollPosition.scrollTo(id: target, anchor: .center)
                chat.scrollTargetMessageID = nil
            }
        }
        .onAppear {
            followsLatestMessage = true
            transcriptScrollPosition.scrollTo(edge: .bottom)
        }
    }

    private func isAtTranscriptBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.visibleRect.maxY >= geometry.contentSize.height - 8
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
            return "Select a language model before editing a prompt"
        }
        if let validationError = model.settings.structuredOutputValidationError {
            return validationError
        }
        return nil
    }
}

private struct ChatComposerContainer: View {
    @ObservedObject var model: NativModel
    @ObservedObject var chat: ChatViewModel
    let workspaceMode: ChatWorkspaceMode
    let onSelectWorkspaceMode: (ChatWorkspaceMode) -> Void
    let conversationWidthReduction: CGFloat
    let onHeightChange: (CGFloat) -> Void

    private var selectedModelID: String? {
        model.settings.normalized().languageModelID
    }

    var body: some View {
        ChatComposer(
            model: model,
            viewModel: chat,
            unavailableReason: model.modelLoadingStatusText
                ?? chat.unavailableReason(isRunning: model.isRunning, selectedModelID: selectedModelID)
                ?? model.settings.structuredOutputValidationError,
            canCompose: model.isRunning
                && !model.isModelLoading
                && selectedModelID?.isEmpty == false
                && model.settings.structuredOutputValidationError == nil,
            canSend: !model.isModelLoading
                && model.settings.structuredOutputValidationError == nil
                && chat.canSend(isRunning: model.isRunning, selectedModelID: selectedModelID),
            workspaceMode: workspaceMode,
            onSelectWorkspaceMode: onSelectWorkspaceMode,
            onSend: { languageModelSupportsTools in
                chat.send(
                    using: model,
                    languageModelSupportsTools: languageModelSupportsTools
                )
            }
        )
        .frame(maxWidth: 680 - conversationWidthReduction)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onHeightChange(height)
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    /// MCP tool host, set by ChatView. Provides MCP tool definitions + execution.
    weak var mcpHost: MCPHostManager?
    private static let liveDecodeRateRefreshInterval: TimeInterval = 0.25
    private static let streamFlushInterval: TimeInterval = 1.0 / 15.0

    private struct QueuedChatRequest {
        let id: UUID
        let sessionID: UUID
        let userMessageID: UUID
        let assistantMessageID: UUID
        let settings: NativSettings
        let imageGenerationModelID: String?
        let languageModelSupportsTools: Bool
    }

    private struct ComposerSnapshot {
        let draft: String
        let attachments: [ChatImageAttachment]
    }

    private struct ImageModelPreparationContext {
        let modelSearchPath: String
        let additionalModelSearchPaths: [String]
        let huggingFaceToken: String?
    }

    @Published private(set) var sessions: [ChatSessionSummary] = []
    @Published private(set) var folders: [ChatFolder] = []
    @Published private(set) var currentSessionID: UUID?
    @Published private(set) var messages: [ChatTranscriptMessage] = []
    @Published private(set) var pendingImageAttachments: [ChatImageAttachment] = []
    @Published var draft = ""
    @Published private(set) var promptEditContext: ChatPromptEditContext?
    @Published private(set) var composerFocusToken = 0
    @Published private(set) var activeRequestSessionID: UUID?
    @Published private(set) var sendingStartedAt: Date?
    @Published private(set) var scrollToken = 0
    @Published var scrollTargetMessageID: UUID?
    @Published private(set) var isLoadingSessions = true
    @Published private(set) var imageModelSelectionRequests: [
        UUID: ChatImageModelSelectionRequest
    ] = [:]

    private let sessionStore = ChatSessionStore()
    private var sessionLoadTask: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    private var activeAssistantMessageID: UUID?
    @Published private var requestQueue: [QueuedChatRequest] = []
    private var storedSessions: [ChatSession] = []
    private var currentSession: ChatSession?
    private var liveDecodeRateRefreshDates: [UUID: Date] = [:]
    private var pendingStreamContent: [UUID: String] = [:]
    private var pendingStreamReasoning: [UUID: String] = [:]
    private var pendingStreamMetrics: [UUID: MLXChatStreamDelta] = [:]
    private var streamFlushDates: [UUID: Date] = [:]
    private var streamFlushTasks: [UUID: Task<Void, Never>] = [:]
    private weak var appModel: NativModel?
    private let toolConsentGate = ChatToolConsentGate()
    private let imageModelSelectionGate = ChatImageModelSelectionGate()
    private var imageModelPreparationTasks: [UUID: Task<Void, Never>] = [:]
    private var imageModelPreparationContexts: [UUID: ImageModelPreparationContext] = [:]
    private var imageModelRefreshTask: Task<Void, Never>?
    private var composerSnapshot: ComposerSnapshot?

    init() {
        folders = sessionStore.loadFolders()
        let now = Date()
        applyCurrentSession(
            ChatSession(
                id: UUID(),
                title: ChatSession.timestampTitle(for: now),
                createdAt: now,
                updatedAt: now,
                messages: []
            )
        )

        let loadTask = Task.detached(priority: .userInitiated) {
            ChatSessionBootstrap(sessions: ChatSessionStore().loadSessions())
        }
        sessionLoadTask = Task { @MainActor [weak self] in
            let bootstrap = await loadTask.value
            guard let self, !Task.isCancelled else { return }
            finishLoadingSessions(bootstrap)
        }
    }

    deinit {
        activeTask?.cancel()
        sessionLoadTask?.cancel()
    }

    var isCurrentSessionSending: Bool {
        guard let activeRequestSessionID else {
            return false
        }
        return activeRequestSessionID == currentSessionID
    }

    var hasPendingRequests: Bool {
        activeRequestSessionID != nil || !requestQueue.isEmpty
    }

    var visibleMessages: [ChatTranscriptMessage] {
        let queuedMessageIDs = Set(
            requestQueue.lazy
                .filter { $0.sessionID == self.currentSessionID }
                .map(\.userMessageID)
        )
        return messages.filter {
            !queuedMessageIDs.contains($0.id)
                && !($0.role == .assistant
                    && $0.content.isEmpty
                    && $0.reasoningContent.isEmpty
                    && !$0.toolCalls.isEmpty)
        }
    }

    var currentSessionQueuedPrompts: [ChatQueuedPrompt] {
        requestQueue.enumerated().compactMap { index, queuedRequest in
            guard queuedRequest.sessionID == currentSessionID,
                  let message = message(queuedRequest.userMessageID, in: queuedRequest.sessionID)
            else {
                return nil
            }
            return ChatQueuedPrompt(
                id: queuedRequest.id,
                content: message.content,
                attachmentCount: message.imageAttachments.count,
                position: index + 1
            )
        }
    }

    func isSessionBusy(_ sessionID: UUID) -> Bool {
        activeRequestSessionID == sessionID
            || requestQueue.contains(where: { $0.sessionID == sessionID })
    }

    func canSend(isRunning: Bool, selectedModelID: String?) -> Bool {
        isRunning
            && selectedModelID?.isEmpty == false
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !pendingImageAttachments.isEmpty)
    }

    func canEditUserMessage(_ messageID: UUID) -> Bool {
        guard let currentSessionID,
              !isSessionBusy(currentSessionID),
              let message = messages.first(where: { $0.id == messageID })
        else {
            return false
        }
        return message.role == .user
    }

    func beginEditingUserMessage(_ messageID: UUID) {
        guard canEditUserMessage(messageID),
              let message = messages.first(where: { $0.id == messageID }),
              let discardedMessageCount = ChatPromptRevision.discardedMessageCount(
                after: messageID,
                in: messages
              )
        else {
            return
        }

        if promptEditContext?.messageID == messageID {
            composerFocusToken += 1
            return
        }

        cancelPromptEditing()
        composerSnapshot = ComposerSnapshot(
            draft: draft,
            attachments: pendingImageAttachments
        )
        promptEditContext = ChatPromptEditContext(
            messageID: messageID,
            discardedMessageCount: discardedMessageCount
        )
        draft = message.content
        pendingImageAttachments = message.imageAttachments
        composerFocusToken += 1
    }

    func cancelPromptEditing() {
        guard promptEditContext != nil else {
            return
        }
        if let composerSnapshot {
            draft = composerSnapshot.draft
            pendingImageAttachments = composerSnapshot.attachments
        }
        promptEditContext = nil
        composerSnapshot = nil
    }

    func unavailableReason(isRunning: Bool, selectedModelID: String?) -> String? {
        if !isRunning {
            return "Server is stopped."
        }
        if selectedModelID?.isEmpty != false {
            return "Select a model in Models."
        }
        if activeRequestSessionID == currentSessionID {
            return "Working..."
        }
        return nil
    }

    func createSession() {
        if canReuseCurrentEmptySession {
            if let currentSession {
                applyCurrentSession(currentSession)
            }
            return
        }

        let createdAt = Date()
        let session = ChatSession(
            id: UUID(),
            title: ChatSession.timestampTitle(for: createdAt),
            createdAt: createdAt,
            updatedAt: createdAt,
            messages: []
        )

        persistCurrentSession(updateTimestamp: false)
        storedSessions.append(session)
        pruneRedundantEmptySessions()
        sessionStore.saveSession(session)
        discardPromptEditing()
        draft = ""
        pendingImageAttachments.removeAll()
        applyCurrentSession(session)
    }

    func stageAttachment(_ attachment: ChatImageAttachment) {
        pendingImageAttachments.append(attachment)
    }

    func removeAttachment(sessionID: UUID, messageID: UUID, attachmentID: UUID) {
        if sessionID == currentSessionID {
            for index in messages.indices where messages[index].id == messageID {
                messages[index].imageAttachments.removeAll { $0.id == attachmentID }
            }
            persistCurrentSession(updateTimestamp: false)
            return
        }

        guard var session = storedSessions.first(where: { $0.id == sessionID })
            ?? sessionStore.loadSession(id: sessionID)
        else {
            return
        }
        for index in session.messages.indices where session.messages[index].id == messageID {
            session.messages[index].imageAttachments.removeAll { $0.id == attachmentID }
        }
        upsertStoredSession(session)
        sessionStore.saveSession(session)
        refreshSessionList()
    }

    func selectSession(_ sessionID: UUID) {
        guard sessionID != currentSessionID else {
            return
        }

        if let session = storedSessions.first(where: { $0.id == sessionID }) {
            persistCurrentSession(updateTimestamp: false)
            discardPromptEditing()
            draft = ""
            pendingImageAttachments.removeAll()
            applyCurrentSession(session)
            return
        }

        if let session = sessionStore.loadSession(id: sessionID) {
            persistCurrentSession(updateTimestamp: false)
            upsertStoredSession(session)
            discardPromptEditing()
            draft = ""
            pendingImageAttachments.removeAll()
            applyCurrentSession(session)
        }
    }

    func renameSession(_ sessionID: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = storedSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        storedSessions[index].customTitle = trimmed.isEmpty ? nil : trimmed
        if currentSession?.id == sessionID {
            currentSession?.customTitle = trimmed.isEmpty ? nil : trimmed
        }
        sessionStore.saveSession(storedSessions[index])
        refreshSessionList()
    }

    func setPinned(_ sessionID: UUID, pinned: Bool) {
        guard let index = storedSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        let order = pinned ? nextPinnedOrder() : nil
        storedSessions[index].pinned = pinned
        storedSessions[index].pinnedOrder = order
        if currentSession?.id == sessionID {
            currentSession?.pinned = pinned
            currentSession?.pinnedOrder = order
        }
        sessionStore.saveSession(storedSessions[index])
        refreshSessionList()
    }

    @discardableResult
    func createFolder(name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = ChatFolder(name: trimmed.isEmpty ? "New Folder" : trimmed, isCollapsed: true)
        folders.append(folder)
        sessionStore.saveFolders(folders)
        return folder.id
    }

    func renameFolder(_ folderID: UUID, to newName: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else {
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        folders[index].name = trimmed
        sessionStore.saveFolders(folders)
    }

    func deleteFolder(_ folderID: UUID) {
        folders.removeAll { $0.id == folderID }
        sessionStore.saveFolders(folders)
        for index in storedSessions.indices where storedSessions[index].folderID == folderID {
            storedSessions[index].folderID = nil
            sessionStore.saveSession(storedSessions[index])
        }
        if currentSession?.folderID == folderID {
            currentSession?.folderID = nil
        }
        refreshSessionList()
    }

    func setFolderCollapsed(_ folderID: UUID, collapsed: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else {
            return
        }
        folders[index].isCollapsed = collapsed
        sessionStore.saveFolders(folders)
    }

    func setAllFoldersCollapsed(_ collapsed: Bool) {
        guard folders.contains(where: { $0.isCollapsed != collapsed }) else {
            return
        }
        for index in folders.indices {
            folders[index].isCollapsed = collapsed
        }
        sessionStore.saveFolders(folders)
    }

    func moveSession(_ sessionID: UUID, toFolder folderID: UUID?) {
        guard let index = storedSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        storedSessions[index].folderID = folderID
        if currentSession?.id == sessionID {
            currentSession?.folderID = folderID
        }
        sessionStore.saveSession(storedSessions[index])
        refreshSessionList()
    }

    func setFolderPinned(_ folderID: UUID, pinned: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else {
            return
        }
        folders[index].isPinned = pinned
        sessionStore.saveFolders(folders)
    }

    func applyFolderOrder(_ orderedFolderIDs: [UUID]) {
        var reordered: [ChatFolder] = []
        for id in orderedFolderIDs {
            if let folder = folders.first(where: { $0.id == id }) {
                reordered.append(folder)
            }
        }
        for folder in folders where !orderedFolderIDs.contains(folder.id) {
            reordered.append(folder)
        }
        folders = reordered
        sessionStore.saveFolders(folders)
    }

    func applyPinnedOrder(_ orderedSessionIDs: [UUID]) {
        for (order, sessionID) in orderedSessionIDs.enumerated() {
            guard let index = storedSessions.firstIndex(where: { $0.id == sessionID }) else {
                continue
            }
            storedSessions[index].pinned = true
            storedSessions[index].pinnedOrder = order
            if currentSession?.id == sessionID {
                currentSession?.pinned = true
                currentSession?.pinnedOrder = order
            }
            sessionStore.saveSession(storedSessions[index])
        }
        refreshSessionList()
    }

    func applySessionOrder(_ orderedSessionIDs: [UUID]) {
        for (order, sessionID) in orderedSessionIDs.enumerated() {
            guard let index = storedSessions.firstIndex(where: { $0.id == sessionID }) else {
                continue
            }
            storedSessions[index].pinned = false
            storedSessions[index].pinnedOrder = nil
            storedSessions[index].sessionOrder = order
            if currentSession?.id == sessionID {
                currentSession?.pinned = false
                currentSession?.pinnedOrder = nil
                currentSession?.sessionOrder = order
            }
            sessionStore.saveSession(storedSessions[index])
        }
        refreshSessionList()
    }

    private func nextPinnedOrder() -> Int {
        (storedSessions.compactMap(\.pinnedOrder).max() ?? -1) + 1
    }

    func deleteSession(_ sessionID: UUID) {
        guard !isSessionBusy(sessionID) else {
            return
        }

        storedSessions.removeAll { $0.id == sessionID }
        sessionStore.deleteSession(id: sessionID)
        pruneRedundantEmptySessions()

        guard sessionID == currentSessionID else {
            refreshSessionList()
            return
        }

        discardPromptEditing()
        draft = ""
        pendingImageAttachments.removeAll()

        if let nextSession = storedSessions.sorted(by: ChatSession.recencySort).first {
            applyCurrentSession(nextSession)
        } else {
            currentSession = nil
            currentSessionID = nil
            messages = []
            refreshSessionList()
        }
    }

    func sessionDataFileURL(for sessionID: UUID) -> URL? {
        guard storedSessions.contains(where: { $0.id == sessionID }) else {
            return nil
        }
        if sessionID == currentSessionID {
            persistCurrentSession(updateTimestamp: false)
        }
        let url = sessionStore.sessionURL(for: sessionID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func conversationText(for sessionID: UUID) -> String? {
        guard let session = storedSessions.first(where: { $0.id == sessionID }) else {
            return nil
        }
        var lines = [session.displayTitle, ""]
        for message in session.messages {
            let speaker: String
            switch message.role {
            case .user:
                speaker = "You"
            case .assistant:
                speaker = message.modelID.map { NativFormatting.truncateModelName($0, maxLength: 60) } ?? "Assistant"
            case .tool:
                speaker = message.toolName == ChatImageToolRegistry.editToolName
                    ? "Image edit"
                    : "Image generation"
            case .error:
                speaker = "Error"
            }
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty && message.imageAttachments.isEmpty {
                continue
            }
            lines.append("\(speaker):")
            if !message.imageAttachments.isEmpty {
                let count = message.imageAttachments.count
                lines.append("[\(count) attachment\(count == 1 ? "" : "s")]")
            }
            if !content.isEmpty {
                lines.append(content)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func send(using appModel: NativModel, languageModelSupportsTools: Bool) {
        let settings = appModel.settings.normalized()
        guard canSend(isRunning: appModel.isRunning, selectedModelID: settings.languageModelID),
              let modelID = settings.languageModelID,
              let currentSession
        else {
            return
        }

        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageAttachments = pendingImageAttachments

        if let promptEditContext {
            guard canEditUserMessage(promptEditContext.messageID),
                  let revision = ChatPromptRevision.make(
                    messageID: promptEditContext.messageID,
                    content: prompt,
                    attachments: imageAttachments,
                    modelID: modelID,
                    in: messages
                  )
            else {
                return
            }

            messages = revision.messages
            restoreComposerAfterPromptEditing()
            persistCurrentSession(updateTimestamp: true)
            enqueueGeneration(
                for: promptEditContext.messageID,
                in: currentSession.id,
                settings: settings,
                languageModelSupportsTools: languageModelSupportsTools,
                appModel: appModel
            )
            return
        }

        draft = ""
        pendingImageAttachments.removeAll()

        let userMessage = ChatTranscriptMessage(
            role: .user,
            content: prompt,
            modelID: modelID,
            imageAttachments: imageAttachments
        )
        messages.append(userMessage)
        persistCurrentSession(updateTimestamp: true)
        enqueueGeneration(
            for: userMessage.id,
            in: currentSession.id,
            settings: settings,
            languageModelSupportsTools: languageModelSupportsTools,
            appModel: appModel
        )
    }

    private func enqueueGeneration(
        for userMessageID: UUID,
        in sessionID: UUID,
        settings: NativSettings,
        languageModelSupportsTools: Bool,
        appModel: NativModel
    ) {
        if let modelID = settings.languageModelID {
            appModel.clearModelLoadFailure(for: modelID)
        }
        self.appModel = appModel
        requestQueue.append(QueuedChatRequest(
            id: UUID(),
            sessionID: sessionID,
            userMessageID: userMessageID,
            assistantMessageID: UUID(),
            settings: settings,
            imageGenerationModelID: imageGenerationModelID(for: sessionID)
                ?? settings.imageGenerationModelID,
            languageModelSupportsTools: languageModelSupportsTools
        ))
        bumpScroll()
        startNextRequestIfNeeded()
    }

    func confirmToolConsent(_ toolMessageID: UUID) {
        toolConsentGate.confirm(toolMessageID)
    }

    func denyToolConsent(_ toolMessageID: UUID) {
        toolConsentGate.deny(toolMessageID)
    }

    func imageModelSelectionRequest(
        for toolMessageID: UUID
    ) -> ChatImageModelSelectionRequest? {
        imageModelSelectionRequests[toolMessageID]
    }

    func selectImageModel(_ toolMessageID: UUID, _ modelID: String) {
        guard let request = imageModelSelectionRequests[toolMessageID],
              let selectedModel = ChatImageModelSelection.selectedModel(
                  withID: modelID,
                  from: request
              )
        else {
            return
        }

        guard !selectedModel.isInstalled else {
            imageModelSelectionGate.select(modelID: modelID, for: toolMessageID)
            return
        }
        guard let preparationContext = imageModelPreparationContexts[toolMessageID] else {
            return
        }

        imageModelPreparationTasks[toolMessageID]?.cancel()
        imageModelPreparationTasks[toolMessageID] = Task { @MainActor [weak self] in
            defer {
                self?.imageModelPreparationTasks.removeValue(forKey: toolMessageID)
            }
            do {
                try await HuggingFaceDownloadManager.shared.downloadIfNeeded(
                    repoID: selectedModel.modelID,
                    sizeBytes: selectedModel.downloadSizeBytes,
                    cachePath: preparationContext.modelSearchPath,
                    token: preparationContext.huggingFaceToken
                )
                try Task.checkCancellation()
                let installedModels = try await ChatImageModelSelection.installedOptions(
                    modelSearchPath: preparationContext.modelSearchPath,
                    additionalModelSearchPaths: preparationContext.additionalModelSearchPaths
                )
                guard ChatImageModelSelection.isPrepared(
                    modelID: selectedModel.modelID,
                    for: request.operation,
                    installedModels: installedModels
                ) else {
                    HuggingFaceDownloadManager.shared.reportError(
                        "The downloaded model is not compatible with \(request.operation.capabilityName).",
                        for: selectedModel.modelID
                    )
                    return
                }
                guard self?.imageModelSelectionRequests[toolMessageID] != nil else {
                    return
                }
                self?.imageModelSelectionGate.select(
                    modelID: selectedModel.modelID,
                    for: toolMessageID
                )
            } catch is CancellationError {
                return
            } catch {
                HuggingFaceDownloadManager.shared.reportError(
                    error.localizedDescription,
                    for: selectedModel.modelID
                )
            }
        }
    }

    func cancelImageModelSelection(_ toolMessageID: UUID) {
        guard imageModelSelectionRequests[toolMessageID] != nil else {
            return
        }
        imageModelPreparationTasks.removeValue(forKey: toolMessageID)?.cancel()
        imageModelSelectionGate.cancel(toolMessageID)
    }

    func refreshPendingImageModelSelections() {
        guard !imageModelSelectionRequests.isEmpty else {
            return
        }

        let pendingRequests = imageModelSelectionRequests.compactMap { id, request in
            imageModelPreparationContexts[id].map { (id, request.operation, $0) }
        }
        imageModelRefreshTask?.cancel()
        imageModelRefreshTask = Task { @MainActor [weak self] in
            for (toolMessageID, operation, context) in pendingRequests {
                do {
                    let models = try await ChatImageModelSelection.availableOptions(
                        for: operation,
                        modelSearchPath: context.modelSearchPath,
                        additionalModelSearchPaths: context.additionalModelSearchPaths,
                        huggingFaceToken: context.huggingFaceToken
                    )
                    try Task.checkCancellation()
                    guard self?.imageModelSelectionRequests[toolMessageID]?.operation
                            == operation
                    else {
                        continue
                    }
                    self?.imageModelSelectionRequests[toolMessageID] =
                        ChatImageModelSelectionRequest(
                            operation: operation,
                            models: models
                        )
                } catch is CancellationError {
                    return
                } catch {
                    // Keep the last known choices if the local cache cannot be
                    // scanned. Hub failures are already handled as offline mode.
                }
            }
        }
    }

    private func awaitToolConsent(for toolMessageID: UUID) async -> Bool {
        await toolConsentGate.awaitDecision(for: toolMessageID)
    }

    func cancel() {
        activeTask?.cancel()
    }

    func prioritizeQueuedRequest(_ requestID: UUID) {
        guard let index = requestQueue.firstIndex(where: { $0.id == requestID }), index > 0 else {
            return
        }
        let queuedRequest = requestQueue.remove(at: index)
        requestQueue.insert(queuedRequest, at: 0)
    }

    func steerQueuedRequest(_ requestID: UUID) {
        guard requestQueue.contains(where: { $0.id == requestID }) else {
            return
        }
        prioritizeQueuedRequest(requestID)
        activeTask?.cancel()
    }

    func removeQueuedRequest(_ requestID: UUID) {
        guard let index = requestQueue.firstIndex(where: { $0.id == requestID }) else {
            return
        }
        let queuedRequest = requestQueue.remove(at: index)
        removeMessage(queuedRequest.userMessageID, from: queuedRequest.sessionID)
        persistSession(queuedRequest.sessionID, updateTimestamp: true)
        if currentSessionID == queuedRequest.sessionID {
            bumpScroll()
        }
    }

    func chooseImageAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie, .pdf, .plainText, .rtf, .spreadsheet, .presentation]

        guard panel.runModal() == .OK else {
            return
        }

        let attachments = panel.urls.compactMap { url in
            try? ChatImageAttachment(contentsOf: url)
        }
        guard !attachments.isEmpty else {
            return
        }

        pendingImageAttachments.append(contentsOf: attachments)
    }

    var canPasteImage: Bool {
        ChatImageAttachment.canReadImages(from: .general)
    }

    @discardableResult
    func attachImages(from pasteboard: NSPasteboard) -> Bool {
        let attachments = ChatImageAttachment.imageAttachments(from: pasteboard)
        guard !attachments.isEmpty else {
            return false
        }
        pendingImageAttachments.append(contentsOf: attachments)
        return true
    }

    @discardableResult
    func attachImages(fromURLs urls: [URL]) -> Bool {
        let attachments = urls.compactMap { try? ChatImageAttachment(contentsOf: $0) }
        guard !attachments.isEmpty else {
            return false
        }
        pendingImageAttachments.append(contentsOf: attachments)
        return true
    }

    func pasteImageFromClipboard() {
        attachImages(from: .general)
    }

    func captureScreenshot() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nativ-Screenshot-\(UUID().uuidString).png")

        Task { [weak self] in
            let captured = await ChatScreenCapture.captureInteractive(to: fileURL)
            guard captured, let attachment = try? ChatImageAttachment(contentsOf: fileURL) else {
                return
            }
            self?.pendingImageAttachments.append(attachment)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func removePendingImageAttachment(_ id: UUID) {
        pendingImageAttachments.removeAll { $0.id == id }
    }

    func clear() {
        activeTask?.cancel()
        activeTask = nil
        activeRequestID = nil
        activeAssistantMessageID = nil
        activeRequestSessionID = nil
        requestQueue.removeAll()
        sendingStartedAt = nil
        discardPromptEditing()
        draft = ""
        pendingImageAttachments.removeAll()
        messages.removeAll()
        persistCurrentSession(updateTimestamp: true)
        bumpScroll()
    }

    private func restoreComposerAfterPromptEditing() {
        if let composerSnapshot {
            draft = composerSnapshot.draft
            pendingImageAttachments = composerSnapshot.attachments
        } else {
            draft = ""
            pendingImageAttachments.removeAll()
        }
        promptEditContext = nil
        composerSnapshot = nil
    }

    private func discardPromptEditing() {
        promptEditContext = nil
        composerSnapshot = nil
    }

    private func startNextRequestIfNeeded() {
        guard activeTask == nil else {
            return
        }

        while !requestQueue.isEmpty {
            let queuedRequest = requestQueue.removeFirst()
            guard insertAssistantMessage(for: queuedRequest) else {
                continue
            }

            activeRequestID = queuedRequest.id
            activeAssistantMessageID = queuedRequest.assistantMessageID
            activeRequestSessionID = queuedRequest.sessionID
            sendingStartedAt = Date()
            if currentSessionID == queuedRequest.sessionID {
                bumpScroll()
            }

            activeTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                do {
                    try await runChatLoop(queuedRequest)
                    appModel?.refreshMetricsIfRunning(force: true)
                } catch is CancellationError {
                    finishActiveAssistantAsCancelled(in: queuedRequest.sessionID)
                } catch let error as URLError where error.code == .cancelled {
                    finishActiveAssistantAsCancelled(in: queuedRequest.sessionID)
                } catch {
                    appModel?.reportModelLoadFailure(
                        modelID: queuedRequest.settings.languageModelID,
                        error: error
                    )
                    if let activeAssistantMessageID {
                        failAssistantMessage(
                            activeAssistantMessageID,
                            in: queuedRequest.sessionID,
                            error: error
                        )
                    }
                    appModel?.refreshMetricsIfRunning(force: true)
                }

                guard activeRequestID == queuedRequest.id else {
                    return
                }
                activeRequestID = nil
                activeAssistantMessageID = nil
                activeRequestSessionID = nil
                sendingStartedAt = nil
                activeTask = nil
                if currentSessionID == queuedRequest.sessionID {
                    bumpScroll()
                }
                startNextRequestIfNeeded()
            }
            return
        }
    }

    private func runChatLoop(_ queuedRequest: QueuedChatRequest) async throws {
        let client = NativChatClient(
            baseURL: queuedRequest.settings.serverBaseURL,
            apiKey: queuedRequest.settings.serverAPIKey
        )
        var assistantMessageID = queuedRequest.assistantMessageID
        var toolRounds = 0
        var activeSettings = queuedRequest.settings
        var activeImageModelID = queuedRequest.imageGenerationModelID

        while true {
            try Task.checkCancellation()
            let advertisesTools = ChatToolRoundGate.advertisesTools(atRound: toolRounds)
            guard let request = makeCompletionRequest(
                for: queuedRequest,
                before: assistantMessageID,
                advertisesTools: advertisesTools,
                settings: activeSettings
            ) else {
                throw NativChatError.invalidResponse
            }

            let completion = try await client.streamChat(request, onEvent: { [weak self] event in
                await MainActor.run {
                    self?.append(
                        event: event,
                        to: assistantMessageID,
                        in: queuedRequest.sessionID
                    )
                }
            })
            let toolCalls = normalizedToolCalls(completion.toolCalls)
            finishAssistantMessage(
                assistantMessageID,
                in: queuedRequest.sessionID,
                fallbackContent: completion.content,
                fallbackReasoningContent: completion.reasoningContent,
                responseMetrics: ChatResponseMetrics(completion: completion),
                toolCalls: toolCalls,
                isCancelled: false
            )

            guard advertisesTools, !toolCalls.isEmpty else {
                return
            }

            var insertionAnchor = assistantMessageID
            for (index, toolCall) in toolCalls.enumerated() {
                try Task.checkCancellation()
                let toolMessageID = UUID()
                let initialToolStatus: ChatTranscriptMessage.ToolStatus = switch toolCall.function?.name {
                case ChatImageToolRegistry.generateToolName,
                     ChatImageToolRegistry.editToolName: .preparing
                default: .running
                }
                guard insertToolMessage(
                    id: toolMessageID,
                    call: toolCall,
                    after: insertionAnchor,
                    in: queuedRequest.sessionID,
                    status: initialToolStatus
                ) else {
                    throw NativChatError.invalidResponse
                }
                insertionAnchor = toolMessageID

                let customTool = toolCall.function?.name.flatMap { toolName in
                    queuedRequest.settings.customTools.first { $0.toolName == toolName }
                }
                if customTool?.kind == .script {
                    updateToolMessage(
                        toolMessageID,
                        in: queuedRequest.sessionID,
                        status: .awaitingConsent,
                        content: "",
                        attachments: []
                    )
                    let approved = await awaitToolConsent(for: toolMessageID)
                    switch ChatToolConsentRouter.outcome(approved: approved, isCancelled: Task.isCancelled) {
                    case .cancelled:
                        cancelToolMessages(
                            currentID: toolMessageID,
                            currentCall: toolCall,
                            remainingCalls: Array(toolCalls.dropFirst(index + 1)),
                            after: insertionAnchor,
                            in: queuedRequest.sessionID
                        )
                        throw CancellationError()
                    case .declined:
                        updateToolMessage(
                            toolMessageID,
                            in: queuedRequest.sessionID,
                            status: .declined,
                            content: #"{"ok":false,"error":"The user declined to run this script tool."}"#,
                            attachments: []
                        )
                        continue
                    case .approved:
                        updateToolMessage(
                            toolMessageID,
                            in: queuedRequest.sessionID,
                            status: .running,
                            content: "",
                            attachments: []
                        )
                    }
                }

                if toolCall.function?.name == ChatSwitchModelToolRegistry.toolName {
                    updateToolMessage(
                        toolMessageID,
                        in: queuedRequest.sessionID,
                        status: .awaitingConsent,
                        content: "",
                        attachments: []
                    )
                    let approved = await awaitToolConsent(for: toolMessageID)
                    switch ChatToolConsentRouter.outcome(approved: approved, isCancelled: Task.isCancelled) {
                    case .cancelled:
                        cancelToolMessages(
                            currentID: toolMessageID,
                            currentCall: toolCall,
                            remainingCalls: Array(toolCalls.dropFirst(index + 1)),
                            after: insertionAnchor,
                            in: queuedRequest.sessionID
                        )
                        throw CancellationError()
                    case .declined:
                        updateToolMessage(
                            toolMessageID,
                            in: queuedRequest.sessionID,
                            status: .declined,
                            content: ChatSwitchModelToolExecutor().declinedPayload(),
                            attachments: []
                        )
                        continue
                    case .approved:
                        updateToolMessage(
                            toolMessageID,
                            in: queuedRequest.sessionID,
                            status: .running,
                            content: "",
                            attachments: []
                        )
                    }
                    guard let appModel else {
                        updateToolMessage(
                            toolMessageID,
                            in: queuedRequest.sessionID,
                            status: .failed,
                            content: ChatSwitchModelToolExecutor().failurePayload(
                                operation: ChatSwitchModelToolRegistry.toolName,
                                error: ChatSwitchModelToolError.appModelUnavailable
                            ),
                            attachments: []
                        )
                        continue
                    }
                    do {
                        let content = try await ChatSwitchModelToolExecutor().execute(call: toolCall, appModel: appModel)
                        activeSettings.languageModelID = appModel.settings.normalized().languageModelID
                        updateToolMessage(
                            toolMessageID,
                            in: queuedRequest.sessionID,
                            status: .succeeded,
                            content: content,
                            attachments: []
                        )
                        appModel.refreshMetricsIfRunning(force: true)
                    } catch {
                        updateToolMessage(
                            toolMessageID,
                            in: queuedRequest.sessionID,
                            status: .failed,
                            content: ChatSwitchModelToolExecutor().failurePayload(
                                operation: ChatSwitchModelToolRegistry.toolName,
                                error: error
                            ),
                            attachments: []
                        )
                    }
                    continue
                }

                do {
                    let references = latestImageReferences(
                        beforeOrAt: toolMessageID,
                        in: queuedRequest.sessionID
                    )
                    let imageModelPreparationContext = ImageModelPreparationContext(
                        modelSearchPath: queuedRequest.settings.expandedModelSearchPath,
                        additionalModelSearchPaths: queuedRequest.settings.additionalModelSearchPaths,
                        huggingFaceToken: appModel?.effectiveHuggingFaceToken
                    )
                    let context = ChatToolExecutionContext(
                        imageGenerationModelID: activeImageModelID,
                        baseURL: queuedRequest.settings.serverBaseURL,
                        apiKey: queuedRequest.settings.serverAPIKey,
                        imageReferences: references,
                        modelSearchPath: queuedRequest.settings.expandedModelSearchPath,
                        additionalModelSearchPaths: queuedRequest.settings.additionalModelSearchPaths,
                        huggingFaceToken: imageModelPreparationContext.huggingFaceToken,
                        imageModelSelection: { [weak self] request in
                            guard let self else {
                                throw CancellationError()
                            }
                            defer {
                                self.imageModelPreparationTasks
                                    .removeValue(forKey: toolMessageID)?
                                    .cancel()
                                self.imageModelSelectionRequests.removeValue(
                                    forKey: toolMessageID
                                )
                                self.imageModelPreparationContexts.removeValue(
                                    forKey: toolMessageID
                                )
                            }

                            let selectedModelID = await self.imageModelSelectionGate
                                .awaitSelection(for: toolMessageID) {
                                    self.imageModelSelectionRequests[toolMessageID] = request
                                    self.imageModelPreparationContexts[toolMessageID] =
                                        imageModelPreparationContext
                                    self.setToolMessageStatus(
                                        toolMessageID,
                                        in: queuedRequest.sessionID,
                                        status: .awaitingImageModelSelection
                                    )
                                }
                            guard let selectedModelID else {
                                throw CancellationError()
                            }
                            return selectedModelID
                        },
                        imageExecutionWillStart: { [weak self] selectedModelID in
                            activeImageModelID = selectedModelID
                            self?.beginImageExecution(
                                toolMessageID,
                                modelID: selectedModelID,
                                in: queuedRequest.sessionID
                            )
                        }
                    )
                    let outcome: ChatToolExecutionOutcome
                    if let customTool {
                        let result = try await CustomToolExecutor.execute(
                            customTool,
                            argumentsJSON: toolCall.function?.arguments
                        )
                        outcome = ChatToolExecutionOutcome(content: result, attachments: [])
                    } else if let host = mcpHost,
                              let toolName = toolCall.function?.name,
                              host.handlesTool(named: toolName) {
                        let result = try await host.callTool(named: toolName, argumentsJSON: toolCall.function?.arguments)
                        outcome = ChatToolExecutionOutcome(content: result, attachments: [])
                    } else {
                        outcome = try await ChatToolDispatcher.execute(call: toolCall, context: context)
                    }
                    updateToolMessage(
                        toolMessageID,
                        in: queuedRequest.sessionID,
                        status: .succeeded,
                        content: outcome.content,
                        attachments: outcome.attachments
                    )
                    appModel?.refreshMetricsIfRunning(force: true)
                } catch is CancellationError {
                    cancelToolMessages(
                        currentID: toolMessageID,
                        currentCall: toolCall,
                        remainingCalls: Array(toolCalls.dropFirst(index + 1)),
                        after: insertionAnchor,
                        in: queuedRequest.sessionID
                    )
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    cancelToolMessages(
                        currentID: toolMessageID,
                        currentCall: toolCall,
                        remainingCalls: Array(toolCalls.dropFirst(index + 1)),
                        after: insertionAnchor,
                        in: queuedRequest.sessionID
                    )
                    throw CancellationError()
                } catch {
                    updateToolMessage(
                        toolMessageID,
                        in: queuedRequest.sessionID,
                        status: .failed,
                        content: ChatToolDispatcher.failurePayload(
                            toolName: toolCall.function?.name,
                            error: error
                        ),
                        attachments: []
                    )
                }
            }

            toolRounds += 1
            assistantMessageID = UUID()
            activeAssistantMessageID = assistantMessageID
            guard insertAssistantMessage(
                id: assistantMessageID,
                after: insertionAnchor,
                in: queuedRequest.sessionID,
                settings: activeSettings
            ) else {
                throw NativChatError.invalidResponse
            }
        }
    }

    private func makeCompletionRequest(
        for queuedRequest: QueuedChatRequest,
        before assistantMessageID: UUID,
        advertisesTools: Bool,
        settings: NativSettings
    ) -> MLXChatCompletionRequest? {
        guard let modelID = settings.languageModelID,
              let sessionMessages = sessionMessages(for: queuedRequest.sessionID),
              let assistantIndex = sessionMessages.firstIndex(where: { $0.id == assistantMessageID })
        else {
            return nil
        }

        let precedingMessages = sessionMessages[..<assistantIndex]
        var requestMessages = precedingMessages.compactMap(\.apiMessage)

        let advertisesToolsForModel = advertisesTools && queuedRequest.languageModelSupportsTools
        var toolDefinitions: [MLXChatToolDefinition] = advertisesToolsForModel
            ? ChatToolRegistry.definitions(
                canEditImage: precedingMessages.contains { !$0.imageAttachments.isEmpty }
            )
            : []
        if advertisesToolsForModel {
            toolDefinitions += settings.customTools.compactMap { try? $0.definition() }
            toolDefinitions += mcpHost?.toolDefinitions() ?? []
            let webSearchIsConfigured = ChatWebSearchToolRegistry.isConfigured()
            toolDefinitions.removeAll {
                settings.disabledToolNames.contains($0.function.name)
                    || ($0.function.name == ChatWebSearchToolRegistry.toolName
                        && !webSearchIsConfigured)
            }
        }
        let tools = toolDefinitions.isEmpty ? nil : toolDefinitions

        var systemParts: [String] = []
        if !settings.systemPrompt.isEmpty {
            systemParts.append(settings.systemPrompt)
        }
        // Inject the built-in tool-use skill when tools are available.
        if !toolDefinitions.isEmpty {
            systemParts.append(NativSkill.builtInToolGuide.instructions)
        }
        for skill in settings.skills where skill.isEnabled && !skill.instructions.isEmpty {
            systemParts.append(skill.instructions)
        }
        if !systemParts.isEmpty {
            requestMessages.insert(
                MLXChatMessage(role: "system", content: systemParts.joined(separator: "\n\n")),
                at: 0
            )
        }
        return MLXChatCompletionRequest(
            model: modelID,
            messages: requestMessages,
            maxTokens: settings.maxTokens,
            temperature: settings.temperature,
            topK: settings.topK,
            topP: settings.topP,
            minP: settings.minP,
            repetitionPenalty: settings.repetitionPenaltyEnabled ? settings.repetitionPenalty : nil,
            enableThinking: settings.thinkingEnabled,
            thinkingBudget: settings.thinkingEnabled
                && settings.thinkingBudgetEnabled
                && !settings.speculativeDecodingActive
                ? settings.thinkingBudget
                : nil,
            thinkingStartToken: settings.thinkingEnabled ? settings.thinkingStartToken : nil,
            thinkingEndToken: settings.thinkingEnabled ? settings.thinkingEndToken : nil,
            responseFormat: tools == nil ? settings.chatResponseFormat : nil,
            tools: tools,
            toolChoice: tools == nil ? nil : "auto",
            stream: true
        )
    }

    private func insertAssistantMessage(for queuedRequest: QueuedChatRequest) -> Bool {
        insertAssistantMessage(
            id: queuedRequest.assistantMessageID,
            after: queuedRequest.userMessageID,
            in: queuedRequest.sessionID,
            settings: queuedRequest.settings
        )
    }

    private func insertAssistantMessage(
        id: UUID,
        after messageID: UUID,
        in sessionID: UUID,
        settings: NativSettings
    ) -> Bool {
        insertMessage(
            ChatTranscriptMessage(
                id: id,
                role: .assistant,
                content: "",
                modelID: settings.languageModelID,
                isStreaming: true,
                isThinkingEnabled: settings.thinkingEnabled
            ),
            after: messageID,
            in: sessionID
        )
    }

    private func insertToolMessage(
        id: UUID,
        call: MLXChatToolCall,
        after messageID: UUID,
        in sessionID: UUID,
        status: ChatTranscriptMessage.ToolStatus = .running
    ) -> Bool {
        insertMessage(
            ChatTranscriptMessage(
                id: id,
                role: .tool,
                content: "",
                isStreaming: true,
                toolCallID: call.id,
                toolName: call.function?.name,
                toolStatus: status,
                toolArguments: call.function?.arguments
            ),
            after: messageID,
            in: sessionID
        )
    }

    private func insertMessage(
        _ message: ChatTranscriptMessage,
        after anchorID: UUID,
        in sessionID: UUID
    ) -> Bool {
        if currentSessionID == sessionID {
            guard let anchorIndex = messages.firstIndex(where: { $0.id == anchorID }) else {
                return false
            }
            messages.insert(message, at: anchorIndex + 1)
            return true
        }

        guard let sessionIndex = storedSessions.firstIndex(where: { $0.id == sessionID }),
              let anchorIndex = storedSessions[sessionIndex].messages.firstIndex(
                where: { $0.id == anchorID }
              )
        else {
            return false
        }
        storedSessions[sessionIndex].messages.insert(message, at: anchorIndex + 1)
        return true
    }

    private func normalizedToolCalls(_ toolCalls: [MLXChatToolCall]) -> [MLXChatToolCall] {
        toolCalls.enumerated().map { index, call in
            var normalized = call
            normalized.index = index
            if normalized.id?.isEmpty != false {
                normalized.id = "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            }
            if normalized.type?.isEmpty != false {
                normalized.type = "function"
            }
            return normalized
        }
    }

    private func latestImageReferences(
        beforeOrAt messageID: UUID,
        in sessionID: UUID
    ) -> [ChatImageAttachment] {
        guard let sessionMessages = sessionMessages(for: sessionID),
              let messageIndex = sessionMessages.firstIndex(where: { $0.id == messageID })
        else {
            return []
        }
        return sessionMessages[...messageIndex]
            .reversed()
            .first(where: { !$0.imageAttachments.isEmpty })?
            .imageAttachments ?? []
    }

    private func updateToolMessage(
        _ id: UUID,
        in sessionID: UUID,
        status: ChatTranscriptMessage.ToolStatus,
        content: String,
        attachments: [ChatImageAttachment]
    ) {
        updateMessage(id, in: sessionID) { message in
            message.content = content
            message.imageAttachments = attachments
            message.toolStatus = status
            message.isStreaming = false
        }
        if status != .awaitingImageModelSelection {
            imageModelSelectionRequests.removeValue(forKey: id)
            imageModelPreparationContexts.removeValue(forKey: id)
        }
        persistSession(sessionID, updateTimestamp: true)
        if currentSessionID == sessionID {
            bumpScroll()
        }
    }

    private func setToolMessageStatus(
        _ id: UUID,
        in sessionID: UUID,
        status: ChatTranscriptMessage.ToolStatus
    ) {
        updateMessage(id, in: sessionID) { message in
            message.toolStatus = status
        }
        if status != .awaitingImageModelSelection {
            imageModelSelectionRequests.removeValue(forKey: id)
            imageModelPreparationContexts.removeValue(forKey: id)
        }
        persistSession(sessionID, updateTimestamp: true)
        if currentSessionID == sessionID {
            bumpScroll()
        }
    }

    private func cancelToolMessages(
        currentID: UUID,
        currentCall: MLXChatToolCall,
        remainingCalls: [MLXChatToolCall],
        after anchorID: UUID,
        in sessionID: UUID
    ) {
        let cancellation = CancellationError()
        updateToolMessage(
            currentID,
            in: sessionID,
            status: .cancelled,
            content: ChatToolDispatcher.failurePayload(
                toolName: currentCall.function?.name,
                error: cancellation
            ),
            attachments: []
        )

        var anchorID = anchorID
        for call in remainingCalls {
            let id = UUID()
            guard insertToolMessage(id: id, call: call, after: anchorID, in: sessionID) else {
                continue
            }
            updateToolMessage(
                id,
                in: sessionID,
                status: .cancelled,
                content: ChatToolDispatcher.failurePayload(
                    toolName: call.function?.name,
                    error: cancellation
                ),
                attachments: []
            )
            anchorID = id
        }
    }

    private func finishActiveAssistantAsCancelled(in sessionID: UUID) {
        guard let activeAssistantMessageID,
              message(activeAssistantMessageID, in: sessionID)?.isStreaming == true
        else {
            return
        }
        finishAssistantMessage(
            activeAssistantMessageID,
            in: sessionID,
            fallbackContent: "Response cancelled.",
            fallbackReasoningContent: nil,
            responseMetrics: nil,
            isCancelled: true
        )
    }

    private func sessionMessages(for sessionID: UUID) -> [ChatTranscriptMessage]? {
        if currentSessionID == sessionID {
            return messages
        }
        return storedSessions.first(where: { $0.id == sessionID })?.messages
    }

    private func imageGenerationModelID(for sessionID: UUID) -> String? {
        if currentSessionID == sessionID {
            return currentSession?.imageGenerationModelID
        }
        return storedSessions.first(where: { $0.id == sessionID })?
            .imageGenerationModelID
    }

    private func beginImageExecution(
        _ toolMessageID: UUID,
        modelID: String,
        in sessionID: UUID
    ) {
        if currentSessionID == sessionID {
            currentSession?.imageGenerationModelID = modelID
        } else {
            guard let sessionIndex = storedSessions.firstIndex(where: {
                $0.id == sessionID
            }) else {
                return
            }
            storedSessions[sessionIndex].imageGenerationModelID = modelID
        }

        updateMessage(toolMessageID, in: sessionID) { message in
            message.toolStatus = .running
        }
        imageModelSelectionRequests.removeValue(forKey: toolMessageID)
        imageModelPreparationContexts.removeValue(forKey: toolMessageID)
        persistSession(sessionID, updateTimestamp: true)
        if currentSessionID == sessionID {
            bumpScroll()
        }
    }

    private func message(_ messageID: UUID, in sessionID: UUID) -> ChatTranscriptMessage? {
        sessionMessages(for: sessionID)?.first(where: { $0.id == messageID })
    }

    private func removeMessage(_ messageID: UUID, from sessionID: UUID) {
        if currentSessionID == sessionID {
            messages.removeAll { $0.id == messageID }
            return
        }
        guard let sessionIndex = storedSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        storedSessions[sessionIndex].messages.removeAll { $0.id == messageID }
    }

    private func append(event: MLXChatStreamDelta, to id: UUID, in sessionID: UUID) {
        // Accumulate deltas into buffers and flush to the published message at a
        // capped cadence. Applying every token synchronously starves the main
        // run loop, which freezes the transcript, thinking bubble, and "Working"
        // animation until an input event (issue #11).
        if let reasoningContent = event.reasoningContent, !reasoningContent.isEmpty {
            pendingStreamReasoning[id, default: ""] += reasoningContent
        }
        if let content = event.content, !content.isEmpty {
            pendingStreamContent[id, default: ""] += content
        }
        if shouldRefreshLiveMetrics(event, for: id) {
            pendingStreamMetrics[id] = event
        }

        guard hasPendingStreamUpdate(id) else {
            return
        }

        let now = Date()
        if let lastFlush = streamFlushDates[id],
           now.timeIntervalSince(lastFlush) < Self.streamFlushInterval {
            scheduleStreamFlush(id, in: sessionID)
            return
        }
        flushStream(id, in: sessionID)
    }

    private func hasPendingStreamUpdate(_ id: UUID) -> Bool {
        pendingStreamContent[id]?.isEmpty == false
            || pendingStreamReasoning[id]?.isEmpty == false
            || pendingStreamMetrics[id] != nil
    }

    private func scheduleStreamFlush(_ id: UUID, in sessionID: UUID) {
        guard streamFlushTasks[id] == nil else {
            return
        }
        streamFlushTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.streamFlushInterval * 1_000_000_000))
            guard let self, !Task.isCancelled else {
                return
            }
            self.streamFlushTasks[id] = nil
            self.flushStream(id, in: sessionID)
        }
    }

    private func flushStream(_ id: UUID, in sessionID: UUID) {
        streamFlushTasks[id]?.cancel()
        streamFlushTasks[id] = nil

        let content = pendingStreamContent.removeValue(forKey: id) ?? ""
        let reasoning = pendingStreamReasoning.removeValue(forKey: id) ?? ""
        let metrics = pendingStreamMetrics.removeValue(forKey: id)
        guard !content.isEmpty || !reasoning.isEmpty || metrics != nil else {
            return
        }

        updateMessage(id, in: sessionID) { message in
            if !reasoning.isEmpty {
                message.reasoningContent.append(reasoning)
            }
            if !content.isEmpty {
                if !message.reasoningContent.isEmpty, message.thinkingDuration == nil {
                    message.thinkingDuration = Date().timeIntervalSince(message.createdAt)
                }
                message.content.append(content)
            }
            if let metrics {
                message.responseMetrics = ChatResponseMetrics(
                    totalTokens: message.responseMetrics?.totalTokens,
                    generatedTokens: metrics.generatedTokens
                        ?? message.responseMetrics?.generatedTokens,
                    decodeTokensPerSecond: metrics.decodeTokensPerSecond
                        ?? message.responseMetrics?.decodeTokensPerSecond,
                    peakMemoryGB: message.responseMetrics?.peakMemoryGB,
                    specAcceptanceRate: message.responseMetrics?.specAcceptanceRate
                )
            }
        }
        streamFlushDates[id] = Date()
        if (!content.isEmpty || !reasoning.isEmpty), currentSessionID == sessionID {
            bumpScroll()
        }
    }

    private func clearStreamBuffers(_ id: UUID) {
        streamFlushTasks[id]?.cancel()
        streamFlushTasks.removeValue(forKey: id)
        pendingStreamContent.removeValue(forKey: id)
        pendingStreamReasoning.removeValue(forKey: id)
        pendingStreamMetrics.removeValue(forKey: id)
        streamFlushDates.removeValue(forKey: id)
    }

    private func shouldRefreshLiveMetrics(
        _ event: MLXChatStreamDelta,
        for messageID: UUID
    ) -> Bool {
        let hasGeneratedTokens = event.generatedTokens.map { $0 > 0 } == true
        let hasDecodeRate = event.decodeTokensPerSecond.map {
            $0 > 0 && $0.isFinite
        } == true
        guard hasGeneratedTokens || hasDecodeRate else {
            return false
        }

        let now = Date()
        if let lastRefresh = liveDecodeRateRefreshDates[messageID],
           now.timeIntervalSince(lastRefresh) < Self.liveDecodeRateRefreshInterval {
            return false
        }

        liveDecodeRateRefreshDates[messageID] = now
        return true
    }

    private func finishAssistantMessage(
        _ id: UUID,
        in sessionID: UUID,
        fallbackContent: String,
        fallbackReasoningContent: String?,
        responseMetrics: ChatResponseMetrics?,
        toolCalls: [MLXChatToolCall] = [],
        isCancelled: Bool
    ) {
        flushStream(id, in: sessionID)
        clearStreamBuffers(id)
        liveDecodeRateRefreshDates.removeValue(forKey: id)
        updateMessage(id, in: sessionID) { message in
            message.isStreaming = false
            if message.content.isEmpty {
                message.content = fallbackContent
            }
            if message.reasoningContent.isEmpty,
               let fallbackReasoningContent {
                message.reasoningContent = fallbackReasoningContent
            }
            message.toolCalls = toolCalls
            if !message.reasoningContent.isEmpty,
               message.thinkingDuration == nil {
                message.thinkingDuration = Date().timeIntervalSince(message.createdAt)
            }
            if isCancelled,
               message.content == fallbackContent,
               message.reasoningContent.isEmpty {
                message.role = .error
            }
            message.responseMetrics = responseMetrics?.hasVisibleValues == true
                ? responseMetrics
                : nil
        }
        persistSession(sessionID, updateTimestamp: true)
    }

    private func failAssistantMessage(_ id: UUID, in sessionID: UUID, error: Error) {
        clearStreamBuffers(id)
        liveDecodeRateRefreshDates.removeValue(forKey: id)
        guard updateMessage(id, in: sessionID, mutate: { message in
            message.role = .error
            message.content = error.localizedDescription
            message.isStreaming = false
            if !message.reasoningContent.isEmpty,
               message.thinkingDuration == nil {
                message.thinkingDuration = Date().timeIntervalSince(message.createdAt)
            }
        }) else {
            return
        }
        persistSession(sessionID, updateTimestamp: true)
    }

    @discardableResult
    private func updateMessage(
        _ messageID: UUID,
        in sessionID: UUID,
        mutate: (inout ChatTranscriptMessage) -> Void
    ) -> Bool {
        if currentSessionID == sessionID {
            guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }) else {
                return false
            }
            mutate(&messages[messageIndex])
            return true
        }

        guard let sessionIndex = storedSessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = storedSessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID })
        else {
            return false
        }

        mutate(&storedSessions[sessionIndex].messages[messageIndex])
        return true
    }

    private func bumpScroll() {
        scrollToken += 1
    }

    private func applyCurrentSession(_ session: ChatSession) {
        currentSession = session
        currentSessionID = session.id
        messages = ChatSessionLoadPolicy.shouldNormalizeOnApply(
            sessionID: session.id,
            activeRequestSessionID: activeRequestSessionID
        ) ? normalizedForLoad(session.messages) : session.messages
        refreshSessionList()
        bumpScroll()
    }

    private func finishLoadingSessions(_ bootstrap: ChatSessionBootstrap) {
        let localSession = currentSession
        let localSessionHasWork = localSession.map { session in
            !session.messages.isEmpty
                || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !pendingImageAttachments.isEmpty
                || activeRequestID != nil
        } == true

        storedSessions = bootstrap.sessions
        if localSessionHasWork, let localSession {
            upsertStoredSession(localSession)
        }

        pruneRedundantEmptySessions()
        isLoadingSessions = false

        guard !localSessionHasWork else {
            refreshSessionList()
            return
        }

        if let latestSession = storedSessions.sorted(by: ChatSession.recencySort).first {
            applyCurrentSession(latestSession)
        } else if let localSession {
            storedSessions = [localSession]
            sessionStore.saveSession(localSession)
            refreshSessionList()
        } else {
            createSession()
        }
    }

    private func normalizedForLoad(_ messages: [ChatTranscriptMessage]) -> [ChatTranscriptMessage] {
        messages.map { message in
            var message = message
            if message.toolStatus == .awaitingConsent
                || message.toolStatus == .awaitingImageModelSelection
                || message.toolStatus == .preparing
                || message.toolStatus == .running
            {
                message.toolStatus = .cancelled
                message.content = ChatToolDispatcher.failurePayload(
                    toolName: message.toolName,
                    error: CancellationError()
                )
                message.isStreaming = false
            }
            return message
        }
    }

    private func persistCurrentSession(updateTimestamp: Bool) {
        guard var session = currentSession else {
            return
        }

        session.messages = messages
        session.title = ChatSession.defaultTitle(for: messages, createdAt: session.createdAt)
        if updateTimestamp {
            session.updatedAt = Date()
        }

        currentSession = session
        upsertStoredSession(session)
        sessionStore.saveSession(session)
        refreshSessionList()
    }

    private func persistSession(_ sessionID: UUID, updateTimestamp: Bool) {
        if sessionID == currentSessionID {
            persistCurrentSession(updateTimestamp: updateTimestamp)
            return
        }

        guard let index = storedSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }

        storedSessions[index].title = ChatSession.defaultTitle(
            for: storedSessions[index].messages,
            createdAt: storedSessions[index].createdAt
        )
        if updateTimestamp {
            storedSessions[index].updatedAt = Date()
        }
        sessionStore.saveSession(storedSessions[index])
        refreshSessionList()
    }

    func reloadPersistedSessions() {
        guard !isLoadingSessions else {
            return
        }
        storedSessions = sessionStore.loadSessions()
        if let currentSession,
           !storedSessions.contains(where: { $0.id == currentSession.id }) {
            upsertStoredSession(currentSession)
        }
        if let id = currentSessionID,
           activeRequestSessionID != id,
           let fresh = storedSessions.first(where: { $0.id == id }),
           fresh.messages.count != messages.count {
            applyCurrentSession(fresh)
        }
        refreshSessionList()
    }

    private func upsertStoredSession(_ session: ChatSession) {
        if let index = storedSessions.firstIndex(where: { $0.id == session.id }) {
            storedSessions[index] = session
        } else {
            storedSessions.append(session)
        }
    }

    private func refreshSessionList() {
        sessions = storedSessions
            .map(\.summary)
            .sorted(by: ChatSessionSummary.recencySort)
    }

    private var canReuseCurrentEmptySession: Bool {
        guard let currentSession else {
            return false
        }

        return currentSession.messages.isEmpty
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pendingImageAttachments.isEmpty
    }

    private func pruneRedundantEmptySessions() {
        let sortedSessions = storedSessions.sorted(by: ChatSession.recencySort)
        var seenIDs = Set<UUID>()
        var keptSessions: [ChatSession] = []
        var keptEmptySession = false
        var removedSessionIDs: [UUID] = []

        for session in sortedSessions {
            guard seenIDs.insert(session.id).inserted else {
                removedSessionIDs.append(session.id)
                continue
            }

            if session.messages.isEmpty {
                if RoutineStore.shared.routine(forSession: session.id) != nil {
                    keptSessions.append(session)
                    continue
                }
                if keptEmptySession {
                    removedSessionIDs.append(session.id)
                    continue
                }
                keptEmptySession = true
            }

            keptSessions.append(session)
        }

        storedSessions = keptSessions
        for sessionID in removedSessionIDs {
            sessionStore.deleteSession(id: sessionID)
        }
    }
}

private struct ChatMessageRow: View, Equatable {
    private static let maximumUserBubbleWidth: CGFloat = 560

    let message: ChatTranscriptMessage
    let imageModelSelectionRequest: ChatImageModelSelectionRequest?
    let canEditUserMessage: Bool
    let editUserMessageUnavailableReason: String?
    let isEditingUserMessage: Bool
    let onEditUserMessage: (UUID) -> Void
    let onConfirmToolConsent: (UUID) -> Void
    let onDenyToolConsent: (UUID) -> Void
    let onSelectImageModel: (UUID, String) -> Void
    let onCancelImageModelSelection: (UUID) -> Void
    let onExploreImageModels: (ChatImageOperation) -> Void
    @State private var didCopyMessage = false
    @State private var isHoveringMessage = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
            && lhs.imageModelSelectionRequest == rhs.imageModelSelectionRequest
            && lhs.canEditUserMessage == rhs.canEditUserMessage
            && lhs.editUserMessageUnavailableReason == rhs.editUserMessageUnavailableReason
            && lhs.isEditingUserMessage == rhs.isEditingUserMessage
    }

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            if !title.isEmpty {
                Text(title)
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
                        showsSaveButton: message.role == .tool
                    )
                }

                if showsThinkingBubble {
                    ChatThinkingBubble(
                        content: message.reasoningContent,
                        isThinking: message.isStreaming && message.content.isEmpty,
                        thinkingDuration: message.thinkingDuration
                    )
                }

                if showsTextContent {
                    textBubble
                }
            }

            if let liveResponseMetrics {
                ChatLiveDecodeMetricsBadge(metrics: liveResponseMetrics)
                    .equatable()
            } else if let responseMetrics {
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

                        if message.role == .user {
                            ChatMessageActionButton(
                                systemImage: "square.and.pencil",
                                title: editActionTitle,
                                isActive: isEditingUserMessage,
                                isEnabled: canEditUserMessage
                            ) {
                                onEditUserMessage(message.id)
                            }
                        }
                    }

                    Text(message.createdAt, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
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
    private var textBubble: some View {
        Group {
            if usesCompactBubble {
                ChatMessageText(
                    content: displayContent,
                    rendersMarkdown: rendersMarkdown,
                    isStreaming: message.isStreaming,
                    isUserPrompt: message.role == .user
                )
                .lineSpacing(2)
                .fixedSize(horizontal: true, vertical: false)
            } else {
                ChatMessageText(
                    content: displayContent,
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
        .font(.body)
        .padding(.horizontal, message.role == .assistant ? 0 : 12)
        .padding(.vertical, message.role == .assistant ? 3 : 9)
        .frame(maxWidth: bubbleMaximumWidth, alignment: alignment)
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
            return message.modelID.map { NativFormatting.truncateModelName($0, maxLength: 42) } ?? "Assistant"
        case .tool:
            return ""
        case .error:
            return "Error"
        }
    }

    private var rowAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var bubbleMaximumWidth: CGFloat? {
        message.role == .user && !usesCompactBubble ? Self.maximumUserBubbleWidth : nil
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
        message.content.isEmpty ? " " : message.content
    }

    private var usesCompactBubble: Bool {
        !displayContent.contains(where: \.isNewline)
            && displayContent.count <= 72
    }

    private var showsTextContent: Bool {
        if message.role == .tool {
            return false
        }
        return !message.content.isEmpty
            || (!showsThinkingBubble && (message.imageAttachments.isEmpty || message.isStreaming))
    }

    private var showsThinkingBubble: Bool {
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

    private var liveResponseMetrics: ChatResponseMetrics? {
        guard message.role == .assistant,
              message.isStreaming,
              let responseMetrics = message.responseMetrics,
              responseMetrics.generatedTokens.map({ $0 > 0 }) == true
                || responseMetrics.decodeTokensPerSecond.map({
                    $0 > 0 && $0.isFinite
                }) == true
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
        message.role == .user || canCopyMessage
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
                    NativStatusBadge(text: mcpServerSlug, tone: .neutral, symbol: "puzzlepiece.extension")
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
            NativStatusBadge(text: "Cancelled", tone: .neutral)
        case .declined:
            NativStatusBadge(text: "Declined", tone: .neutral)
        case .preparing, .running, .awaitingConsent,
             .awaitingImageModelSelection, nil:
            EmptyView()
        }
    }

    private var consentPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            consentDescription
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Deny") {
                    onDeny(message.id)
                }
                .buttonStyle(.bordered)

                Button("Confirm") {
                    onConfirm(message.id)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 7)
    }

    private var consentDescription: Text {
        if message.toolName == ChatSwitchModelToolRegistry.toolName {
            return Text("The model wants to switch to ")
                + Text(verbatim: requestedModelID).bold()
                + Text(". The server restarts briefly; your session is kept.")
        }
        return Text("The model wants to run this script tool on your Mac. Confirm to allow its code to run.")
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
                        models: request.installedModels
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

                    Button("Explore models") {
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
        models: [ChatImageModelOption]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ForEach(models) { model in
                ChatImageModelOptionRow(model: model) {
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
            "cancelled"
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

    let model: ChatImageModelOption
    let onChoose: () -> Void

    var body: some View {
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
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if model.isInstalled {
            Button(action: onChoose) {
                Label("Use", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Use \(model.displayName)")
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

private struct ChatLiveDecodeMetricsBadge: View, Equatable {
    let metrics: ChatResponseMetrics

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)

            Text("Decode")
                .foregroundStyle(.secondary)

            if let generatedTokens = metrics.generatedTokens {
                Text("\(NativFormatting.integer(generatedTokens)) tokens")
                    .fontWeight(.medium)
                    .monospacedDigit()
            }

            if metrics.generatedTokens != nil,
               metrics.decodeTokensPerSecond != nil {
                Text("·")
                    .foregroundStyle(.tertiary)
            }

            if let decodeTokensPerSecond = metrics.decodeTokensPerSecond {
                Text(NativFormatting.rate(decodeTokensPerSecond))
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(0.1))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Decode metrics")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        [
            metrics.generatedTokens.map { "\($0) generated tokens" },
            metrics.decodeTokensPerSecond.map(NativFormatting.rate)
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
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
    let systemImage: String
    let title: String
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : (isHovering ? Color.primary : Color.secondary))
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
}

private struct ChatThinkingBubble: View {
    let content: String
    let isThinking: Bool
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
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
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
                            rendersMarkdown: !isThinking,
                            isStreaming: isThinking
                        )
                        .font(.callout)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                    } else {
                        Text(content)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(height: 58, alignment: .bottomLeading)
                            .clipped()
                            .padding(12)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
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
                    let progress = context.date.timeIntervalSinceReferenceDate
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
                                        .clear
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
            value: metrics.peakMemoryGB.map(NativFormatting.gigabytes) ?? "--"
        )
    }
}

private struct ChatResponseMetricPill: View {
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
        .padding(.horizontal, 9)
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

    var body: some View {
        VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                ChatImageAttachmentView(
                    attachment: attachment,
                    showsSaveButton: showsSaveButton
                )
            }
        }
    }
}

private struct ChatImageAttachmentView: View {
    let attachment: ChatImageAttachment
    let showsSaveButton: Bool
    @State private var saveErrorMessage: String?
    @State private var showsSaveError = false
    @State private var isSaveButtonHovered = false

    private let maximumSideLength: CGFloat = 300

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            preview

            if showsSaveButton, attachment.imageData != nil {
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
        .alert("Couldn’t Save Image", isPresented: $showsSaveError) {
            Button("OK", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(saveErrorMessage ?? "The image could not be saved.")
        }
    }

    @ViewBuilder
    private var preview: some View {
        Group {
            if let image {
                let size = displaySize(for: image)

                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: ArtifactKind.resolve(mimeType: attachment.mimeType, filename: attachment.filename).systemImage)
                        .font(.title2)
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
        guard let data = attachment.imageData else {
            return nil
        }
        return NSImage(data: data)
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
    let content: String
    let rendersMarkdown: Bool
    let isStreaming: Bool
    var isUserPrompt = false
    @Environment(\.chatFontScale) private var chatFontScale

    @ViewBuilder
    var body: some View {
        if isUserPrompt {
            ChatSelectablePromptText(
                content: content,
                fontScale: chatFontScale
            )
        } else if rendersMarkdown && !isStreaming {
            StructuredText(
                markdown: NativMarkdownFormatting.normalizedMathDelimiters(in: content),
                syntaxExtensions: [.math]
            )
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
            .font(ChatFontMetrics.bodyFont(scale: chatFontScale))
        } else {
            renderedText
                .textSelection(.enabled)
                .font(ChatFontMetrics.bodyFont(scale: chatFontScale))
        }
    }

    private var renderedText: Text {
        guard rendersMarkdown,
              let attributed = try? AttributedString(
                markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
              )
        else {
            return Text(content)
        }

        return Text(attributed)
    }
}

private struct ChatSelectablePromptText: NSViewRepresentable {
    let content: String
    let fontScale: Double

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        update(textView)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        update(textView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: NSTextView,
        context: Context
    ) -> CGSize? {
        let font = ChatFontMetrics.bodyNSFont(scale: fontScale)
        let availableWidth = proposal.width ?? .greatestFiniteMagnitude
        let bounds = (content as NSString).boundingRect(
            with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes(font: font)
        )
        let measuredWidth = max(1, ceil(bounds.width))
        let width = proposal.width.map { min($0, measuredWidth) } ?? measuredWidth
        return CGSize(width: width, height: max(1, ceil(bounds.height)))
    }

    private func update(_ textView: NSTextView) {
        let font = ChatFontMetrics.bodyNSFont(scale: fontScale)
        if textView.string != content || textView.font != font {
            textView.textStorage?.setAttributedString(NSAttributedString(
                string: content,
                attributes: textAttributes(font: font)
            ))
        }
        textView.setAccessibilityLabel(content)
    }

    private func textAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = 2
        return [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]
    }
}

private extension Color {
    static let nativMark = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor.black : NSColor(white: 0.86, alpha: 1)
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
        workspaceMode: .chat,
        onSelectWorkspaceMode: { _ in },
        showsConfiguration: .constant(true),
        conversationWidthReduction: 0,
        onExploreImageModels: { _ in }
    )
}
