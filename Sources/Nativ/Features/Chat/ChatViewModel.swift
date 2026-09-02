import AppKit
import Combine
import Foundation
import NativServerKit
import Observation
import UniformTypeIdentifiers

struct ChatQueuedPrompt: Identifiable, Equatable {
    let id: UUID
    let content: String
    let attachmentCount: Int
    let position: Int
}

struct ChatPromptEditContext: Equatable {
    let messageID: UUID
}

private struct ChatSessionBootstrap {
    let sessions: [ChatSession]
}

enum ChatStreamingRenderPolicy {
    static func updatesPerSecond(characterCount: Int) -> Double {
        switch characterCount {
        case ..<2_000:
            10
        case ..<8_000:
            9
        case ..<20_000:
            8.5
        default:
            8
        }
    }

    static func flushIntervalSeconds(characterCount: Int) -> TimeInterval {
        1 / updatesPerSecond(characterCount: characterCount)
    }

    static func flushInterval(characterCount: Int) -> Duration {
        .seconds(flushIntervalSeconds(characterCount: characterCount))
    }
}

@MainActor
@Observable
final class ChatTranscriptRevision {
    private(set) var value = 0

    func bump() {
        value &+= 1
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    /// MCP tool host, set by ChatView. Provides MCP tool definitions + execution.
    weak var mcpHost: MCPHostManager?
    private static let liveDecodeRateRefreshInterval: TimeInterval = 0.25

    private struct QueuedChatRequest {
        let id: UUID
        let sessionID: UUID
        let userMessageID: UUID
        let assistantMessageID: UUID
        let settings: NativSettings
        let toolScope: ChatToolScope
        let imageGenerationModelID: String?
        let languageModelSupportsTools: Bool
        let languageModelSupportsVision: Bool
    }

    private struct ComposerSnapshot {
        let draft: String
        let attachments: [ChatImageAttachment]
    }

    private struct ImageModelPreparationContext {
        let modelSearchPath: String
        let modelCacheVolumeIdentifier: String?
        let additionalModelSearchPaths: [String]
        let huggingFaceToken: String?
    }

    private struct PreparedDocumentContext {
        var result: ChatDocumentContextResult
        var characterLimit: Int
    }

    @Published private(set) var sessions: [ChatSessionSummary] = []
    @Published private(set) var folders: [ChatFolder] = []
    @Published private(set) var currentSessionID: UUID?
    @Published private(set) var currentProjectID: UUID?
    @Published private(set) var messages: [ChatTranscriptMessage] = []
    @Published private(set) var pendingImageAttachments: [ChatImageAttachment] = [] {
        didSet {
            if pendingImageAttachments.isEmpty {
                attachmentImportError = nil
            }
            synchronizeAttachmentValidations()
        }
    }
    @Published private(set) var attachmentValidations: [UUID: ChatAttachmentValidation] = [:]
    @Published private(set) var attachmentImportError: String?
    @Published private var documentOmissionsBySessionID: [UUID: [ChatDocumentOmission]] = [:]
    @Published var draft = ""
    @Published private(set) var promptEditContext: ChatPromptEditContext?
    @Published private(set) var composerFocusToken = 0
    @Published private(set) var activeRequestSessionID: UUID?
    @Published private(set) var sendingStartedAt: Date?
    let transcriptRevision = ChatTranscriptRevision()
    @Published var scrollTargetMessageID: UUID?
    @Published private(set) var isLoadingSessions = true
    @Published private(set) var imageModelSelectionRequests:
        [UUID: ChatImageModelSelectionRequest] = [:]

    private let sessionStore = ChatSessionStore()
    private let windowID: UUID
    private let persistedDataChanges: PersistedDataChangeHub
    private let inferenceActivity: InferenceActivityCoordinator
    private let documentContextBuilder: ChatDocumentContextBuilder
    private let attachmentValidator: ChatAttachmentValidator
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
    private let projectStore: ChatProjectStore
    private let toolConsentGate = ChatToolConsentGate()
    private let imageModelSelectionGate = ChatImageModelSelectionGate()
    private var imageModelPreparationTasks: [UUID: Task<Void, Never>] = [:]
    private var imageModelPreparationContexts: [UUID: ImageModelPreparationContext] = [:]
    private var imageModelRefreshTask: Task<Void, Never>?
    private var composerSnapshot: ComposerSnapshot?
    private var attachmentValidationTasks: [UUID: Task<Void, Never>] = [:]
    private var persistedDataChangeCancellable: AnyCancellable?
    private var needsPersistedSessionReload = false

    init(
        windowID: UUID = UUID(),
        persistedDataChanges: PersistedDataChangeHub = .init(),
        inferenceActivity: InferenceActivityCoordinator = .init(),
        projectStore: ChatProjectStore = .init()
    ) {
        self.windowID = windowID
        self.persistedDataChanges = persistedDataChanges
        self.inferenceActivity = inferenceActivity
        self.projectStore = projectStore
        let documentExtractionCache = ChatDocumentExtractionCache()
        documentContextBuilder = ChatDocumentContextBuilder(
            extractionCache: documentExtractionCache
        )
        attachmentValidator = ChatAttachmentValidator(
            extractionCache: documentExtractionCache
        )
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
        persistedDataChangeCancellable = persistedDataChanges.changes
            .sink { [weak self] change in
                self?.handlePersistedDataChange(change)
            }
        observeInferenceActivity()
    }

    deinit {
        activeTask?.cancel()
        sessionLoadTask?.cancel()
        attachmentValidationTasks.values.forEach { $0.cancel() }
    }

    private func observeInferenceActivity() {
        withObservationTracking {
            _ = inferenceActivity.hasActiveOperations
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.observeInferenceActivity()
                self.startNextRequestIfNeeded()
            }
        }
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

    var isCurrentSessionActiveInAnotherWindow: Bool {
        guard let currentSessionID else {
            return false
        }
        return !canModifySession(currentSessionID)
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
            && !hasBlockingAttachmentValidation
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !pendingImageAttachments.isEmpty)
    }

    var hasPendingImageAttachments: Bool {
        pendingImageAttachments.contains { $0.chatAttachmentKind == .image }
    }

    var hasImageAttachmentsInCurrentSession: Bool {
        messages.contains { message in
            message.imageAttachments.contains { $0.chatAttachmentKind == .image }
        }
    }

    var importedModelRepositoryID: String? {
        currentSession?.importedModelRepositoryID
    }

    var importedPromptTokenCount: Int? {
        messages.reversed().compactMap { message -> Int? in
            guard message.role == .assistant else {
                return nil
            }
            return message.responseMetrics?.totalTokens
        }.first
    }

    func attachmentValidation(for attachmentID: UUID) -> ChatAttachmentValidation? {
        attachmentValidations[attachmentID]
    }

    func clearAttachmentImportError() {
        attachmentImportError = nil
    }

    var currentDocumentContextOmissions: [ChatDocumentOmission] {
        currentSessionID.flatMap { documentOmissionsBySessionID[$0] } ?? []
    }

    func clearDocumentContextOmissions() {
        guard let currentSessionID else { return }
        documentOmissionsBySessionID[currentSessionID] = nil
    }

    func canEditUserMessage(_ messageID: UUID) -> Bool {
        guard let currentSessionID,
            !isSessionBusy(currentSessionID),
            canModifySession(currentSessionID),
            latestUserMessageID == messageID
        else {
            return false
        }
        return true
    }

    var latestUserMessageID: UUID? {
        ChatPromptRevision.latestUserMessageID(in: messages)
    }

    func beginEditingUserMessage(_ messageID: UUID) {
        guard canEditUserMessage(messageID),
            let message = messages.first(where: { $0.id == messageID })
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
        promptEditContext = ChatPromptEditContext(messageID: messageID)
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

    var forkableAssistantResponseIDs: Set<UUID> {
        ChatConversationBranch.forkableAssistantResponseIDs(in: messages)
    }

    func forkAssistantResponse(_ messageID: UUID) {
        guard let sourceSession = currentSessionSnapshot,
            let branch = ChatConversationBranch.throughAssistantResponse(
                messageID,
                in: sourceSession
            )
        else {
            return
        }

        activateBranch(branch)
    }

    func unavailableReason(isRunning: Bool, selectedModelID: String?) -> String? {
        if !isRunning {
            return "Server is stopped."
        }
        if selectedModelID?.isEmpty != false {
            return "Choose a model in Models."
        }
        if activeRequestSessionID == currentSessionID {
            return "Working…"
        }
        if isCurrentSessionActiveInAnotherWindow {
            return "This chat is active in another window."
        }
        return nil
    }

    func createSession(projectID: UUID? = nil) {
        if canReuseCurrentEmptySession(in: projectID) {
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
            messages: [],
            projectID: projectID
        )

        persistCurrentSession(updateTimestamp: false)
        storedSessions.append(session)
        pruneRedundantEmptySessions()
        saveSession(session)
        discardPromptEditing()
        draft = ""
        pendingImageAttachments.removeAll()
        applyCurrentSession(session)
    }

    func archive(
        for sessionID: UUID,
        selectedModelID: String?,
        systemPrompt: String
    ) -> ChatArchive? {
        let session: ChatSession?
        if sessionID == currentSessionID {
            session = currentSessionSnapshot
        } else {
            session = storedSessions.first(where: { $0.id == sessionID })
                ?? sessionStore.loadSession(id: sessionID)
        }

        guard let session,
            let modelRepositoryID = session.importedModelRepositoryID
                ?? session.messages.reversed().compactMap(\.modelID).first
                ?? selectedModelID
        else {
            return nil
        }

        return ChatArchive(
            chat: session,
            modelRepositoryID: modelRepositoryID,
            systemPrompt: session.importedSystemPrompt ?? systemPrompt
        )
    }

    func importArchive(_ archive: ChatArchive) throws -> UUID? {
        let session = try ChatArchiveCodec.importedSession(from: archive)
        persistCurrentSession(updateTimestamp: false)
        guard saveSession(session) else {
            return nil
        }
        upsertStoredSession(session)
        discardPromptEditing()
        draft = ""
        pendingImageAttachments.removeAll()
        applyCurrentSession(session)
        return session.id
    }

    func stageAttachment(_ attachment: ChatImageAttachment) {
        pendingImageAttachments.append(attachment)
    }

    @discardableResult
    func removeAttachment(sessionID: UUID, messageID: UUID, attachmentID: UUID) -> Bool {
        guard canModifySession(sessionID) else {
            return false
        }
        if sessionID == currentSessionID {
            let previousMessages = messages
            guard
                removeAttachment(
                    messageID: messageID,
                    attachmentID: attachmentID,
                    from: &messages
                )
            else {
                return false
            }
            guard persistCurrentSession(updateTimestamp: false) else {
                messages = previousMessages
                return false
            }
            return true
        }

        guard
            var session = storedSessions.first(where: { $0.id == sessionID })
                ?? sessionStore.loadSession(id: sessionID)
        else {
            return false
        }
        guard
            removeAttachment(
                messageID: messageID,
                attachmentID: attachmentID,
                from: &session.messages
            )
        else {
            return false
        }
        guard saveSession(session) else {
            return false
        }
        upsertStoredSession(session)
        refreshSessionList()
        return true
    }

    private func removeAttachment(
        messageID: UUID,
        attachmentID: UUID,
        from messages: inout [ChatTranscriptMessage]
    ) -> Bool {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
            let attachmentIndex = messages[messageIndex].imageAttachments.firstIndex(
                where: { $0.id == attachmentID }
            )
        else {
            return false
        }
        messages[messageIndex].imageAttachments.remove(at: attachmentIndex)
        return true
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
        guard canModifySession(sessionID),
            let index = storedSessions.firstIndex(where: { $0.id == sessionID })
        else {
            return
        }
        storedSessions[index].customTitle = trimmed.isEmpty ? nil : trimmed
        if currentSession?.id == sessionID {
            currentSession?.customTitle = trimmed.isEmpty ? nil : trimmed
        }
        saveSession(storedSessions[index])
        refreshSessionList()
    }

    func setPinned(_ sessionID: UUID, pinned: Bool) {
        guard canModifySession(sessionID),
            let index = storedSessions.firstIndex(where: { $0.id == sessionID })
        else {
            return
        }
        let order = pinned ? nextPinnedOrder() : nil
        storedSessions[index].pinned = pinned
        storedSessions[index].pinnedOrder = order
        if currentSession?.id == sessionID {
            currentSession?.pinned = pinned
            currentSession?.pinnedOrder = order
        }
        saveSession(storedSessions[index])
        refreshSessionList()
    }

    @discardableResult
    func createFolder(name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = ChatFolder(name: trimmed.isEmpty ? "New Folder" : trimmed, isCollapsed: true)
        folders.append(folder)
        saveFolders()
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
        saveFolders()
    }

    func deleteFolder(_ folderID: UUID) {
        let affectedSessionIDs = storedSessions.lazy
            .filter { $0.folderID == folderID }
            .map(\.id)
        guard affectedSessionIDs.allSatisfy(canModifySession) else {
            return
        }
        folders.removeAll { $0.id == folderID }
        saveFolders()
        for index in storedSessions.indices where storedSessions[index].folderID == folderID {
            storedSessions[index].folderID = nil
            saveSession(storedSessions[index])
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
        saveFolders()
    }

    func setAllFoldersCollapsed(_ collapsed: Bool) {
        guard folders.contains(where: { $0.isCollapsed != collapsed }) else {
            return
        }
        for index in folders.indices {
            folders[index].isCollapsed = collapsed
        }
        saveFolders()
    }

    func moveSession(_ sessionID: UUID, toFolder folderID: UUID?) {
        guard canModifySession(sessionID),
            let index = storedSessions.firstIndex(where: { $0.id == sessionID })
        else {
            return
        }
        storedSessions[index].folderID = folderID
        if currentSession?.id == sessionID {
            currentSession?.folderID = folderID
        }
        saveSession(storedSessions[index])
        refreshSessionList()
    }

    func setFolderPinned(_ folderID: UUID, pinned: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else {
            return
        }
        folders[index].isPinned = pinned
        saveFolders()
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
        saveFolders()
    }

    func applyPinnedOrder(_ orderedSessionIDs: [UUID]) {
        guard orderedSessionIDs.allSatisfy(canModifySession) else {
            return
        }
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
            saveSession(storedSessions[index])
        }
        refreshSessionList()
    }

    func applySessionOrder(_ orderedSessionIDs: [UUID]) {
        guard orderedSessionIDs.allSatisfy(canModifySession) else {
            return
        }
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
            saveSession(storedSessions[index])
        }
        refreshSessionList()
    }

    private func nextPinnedOrder() -> Int {
        (storedSessions.compactMap(\.pinnedOrder).max() ?? -1) + 1
    }

    func deleteSession(_ sessionID: UUID) {
        guard canModifySession(sessionID) else {
            return
        }
        // A busy session used to be undeletable, so a chat whose stream never
        // finished could not be removed at all. Cancel its work and delete it.
        if isSessionBusy(sessionID) {
            cancelRequests(for: sessionID)
        }

        storedSessions.removeAll { $0.id == sessionID }
        RoutineStore.shared.detachSession(sessionID)
        deletePersistedSession(sessionID)
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
            currentProjectID = nil
            messages = []
            refreshSessionList()
        }
    }

    @discardableResult
    func removeProjectSessions(
        projectID: UUID,
        disposition: ChatProjectSessionRemovalDisposition
    ) -> Bool {
        let sessionIDs = Array(
            storedSessions.lazy
                .filter { $0.projectID == projectID }
                .map(\.id))
        guard sessionIDs.allSatisfy(canModifySession) else {
            return false
        }

        switch disposition {
        case .keepChats:
            for index in storedSessions.indices where storedSessions[index].projectID == projectID {
                storedSessions[index].projectID = nil
                storedSessions[index].folderID = nil
                guard saveSession(storedSessions[index]) else {
                    return false
                }
                if currentSession?.id == storedSessions[index].id {
                    currentSession = storedSessions[index]
                    currentProjectID = nil
                }
            }
            pruneRedundantEmptySessions()
            refreshSessionList()
        case .deleteChats:
            for sessionID in sessionIDs {
                deleteSession(sessionID)
            }
        }
        return true
    }

    func handleScheduledTaskDeletion(
        taskID: String,
        linkedSessionIDs: Set<UUID>,
        disposition: ScheduledTaskChatDisposition
    ) {
        let sessionIDs = linkedSessionIDs.union(
            storedSessions.lazy
                .filter { $0.scheduledTaskID == taskID }
                .map(\.id)
        )

        switch disposition {
        case .keepChats:
            for index in storedSessions.indices where sessionIDs.contains(storedSessions[index].id)
            {
                guard canModifySession(storedSessions[index].id) else {
                    continue
                }
                let session = ScheduledTaskChatLinker.makeIndependentSession(
                    from: storedSessions[index]
                )
                storedSessions[index] = session
                saveSession(session)
                if currentSession?.id == session.id {
                    currentSession = session
                }
            }
            refreshSessionList()

        case .deleteChats:
            for sessionID in sessionIDs {
                deleteSession(sessionID)
            }
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
                speaker =
                    message.modelID.map { NativFormatting.truncateModelName($0, maxLength: 60) }
                    ?? "Assistant"
            case .tool:
                speaker =
                    message.toolName == ChatImageToolRegistry.editToolName
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

    func send(
        using appModel: NativModel,
        languageModelSupportsTools: Bool,
        languageModelSupportsVision: Bool
    ) {
        var settings = appModel.settings.normalized()
        if let importedSystemPrompt = currentSession?.importedSystemPrompt {
            settings.systemPrompt = importedSystemPrompt
        }
        guard canSend(isRunning: appModel.isRunning, selectedModelID: settings.languageModelID),
            languageModelSupportsVision || !hasPendingImageAttachments,
            let modelID = settings.languageModelID,
            let currentSession,
            canModifySession(currentSession.id)
        else {
            return
        }

        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageAttachments = pendingImageAttachments

        if let promptEditContext {
            guard canEditUserMessage(promptEditContext.messageID),
                let sourceSession = currentSessionSnapshot,
                let revision = ChatPromptRevision.make(
                    messageID: promptEditContext.messageID,
                    content: prompt,
                    attachments: imageAttachments,
                    modelID: modelID,
                    in: sourceSession.messages
                )
            else {
                return
            }

            let branch = ChatConversationBranch.make(
                from: sourceSession,
                messages: revision.messages
            )
            activateBranch(branch, restoring: composerSnapshot)
            enqueueGeneration(
                for: promptEditContext.messageID,
                in: branch.id,
                settings: settings,
                languageModelSupportsTools: languageModelSupportsTools,
                languageModelSupportsVision: languageModelSupportsVision,
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
            languageModelSupportsVision: languageModelSupportsVision,
            appModel: appModel
        )
    }

    private func enqueueGeneration(
        for userMessageID: UUID,
        in sessionID: UUID,
        settings: NativSettings,
        languageModelSupportsTools: Bool,
        languageModelSupportsVision: Bool,
        appModel: NativModel
    ) {
        if let modelID = settings.languageModelID {
            appModel.clearModelLoadFailure(for: modelID)
        }
        self.appModel = appModel
        documentOmissionsBySessionID[sessionID] = nil
        requestQueue.append(
            QueuedChatRequest(
                id: UUID(),
                sessionID: sessionID,
                userMessageID: userMessageID,
                assistantMessageID: UUID(),
                settings: settings,
                toolScope: projectStore.toolScope(
                    for: projectID(for: sessionID),
                    settings: settings
                ),
                imageGenerationModelID: imageGenerationModelID(for: sessionID)
                    ?? settings.imageGenerationModelID,
                languageModelSupportsTools: languageModelSupportsTools,
                languageModelSupportsVision: languageModelSupportsVision
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
                    volumeIdentifier: preparationContext.modelCacheVolumeIdentifier,
                    token: preparationContext.huggingFaceToken
                )
                try Task.checkCancellation()
                let installedModels = try await ChatImageModelSelection.installedOptions(
                    modelSearchPath: preparationContext.modelSearchPath,
                    additionalModelSearchPaths: preparationContext.additionalModelSearchPaths
                )
                guard
                    ChatImageModelSelection.isPrepared(
                        modelID: selectedModel.modelID,
                        for: request.operation,
                        installedModels: installedModels
                    )
                else {
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
                    guard
                        self?.imageModelSelectionRequests[toolMessageID]?.operation
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
        // Do not wait for the task to unwind: a stalled stream may stay parked in
        // URLSession until its idle timeout fires, and the composer must become
        // usable the moment the user asks to stop.
        if let sessionID = activeRequestSessionID {
            finishActiveAssistantAsCancelled(in: sessionID)
        }
        releaseActiveRequestSlot(matching: nil)
        startNextRequestIfNeeded()
    }

    /// Cancels in-flight and queued work for one session, leaving other sessions
    /// untouched.
    private func cancelRequests(for sessionID: UUID) {
        requestQueue.removeAll { $0.sessionID == sessionID }
        guard activeRequestSessionID == sessionID else {
            return
        }
        activeTask?.cancel()
        finishActiveAssistantAsCancelled(in: sessionID)
        releaseActiveRequestSlot(matching: nil)
        startNextRequestIfNeeded()
    }

    /// Frees the single in-flight request slot.
    ///
    /// Pass the owning request's id to release it only if that request still owns
    /// the slot, or `nil` to force-release whatever is active (user-driven
    /// recovery). `activeTask` is always cleared together with the rest of the
    /// slot so `startNextRequestIfNeeded()` can never be blocked by a handle that
    /// outlived its request.
    private func releaseActiveRequestSlot(matching requestID: UUID?) {
        if let requestID, activeRequestID != requestID {
            return
        }
        activeRequestID = nil
        activeAssistantMessageID = nil
        activeRequestSessionID = nil
        sendingStartedAt = nil
        activeTask = nil
    }

    private func ownsActiveRequest(_ requestID: UUID) -> Bool {
        activeRequestID == requestID
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

    func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes =
            [.image, .pdf, .text, .rtf, .commaSeparatedText]
            + ["doc", "docx", "pptx"].compactMap { UTType(filenameExtension: $0) }

        guard panel.runModal() == .OK else {
            return
        }

        let attachments = importAttachments(from: panel.urls)
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
        guard ChatImageAttachment.canReadImages(from: pasteboard) else {
            return false
        }
        let attachments = ChatImageAttachment.imageAttachments(from: pasteboard)
        guard !attachments.isEmpty else {
            attachmentImportError = "The clipboard image couldn’t be read."
            return false
        }
        attachmentImportError = nil
        pendingImageAttachments.append(contentsOf: attachments)
        return true
    }

    @discardableResult
    func attachFiles(fromURLs urls: [URL]) -> Bool {
        let attachments = importAttachments(from: urls)
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
            guard captured else {
                self?.attachmentImportError =
                    "The screenshot couldn’t be captured. "
                    + "Check Screen Recording permission."
                return
            }
            defer {
                try? FileManager.default.removeItem(at: fileURL)
            }
            do {
                let attachment = try ChatImageAttachment(contentsOf: fileURL)
                self?.attachmentImportError = nil
                self?.pendingImageAttachments.append(attachment)
            } catch {
                self?.attachmentImportError = "The screenshot was captured but couldn’t be read."
            }
        }
    }

    func removePendingImageAttachment(_ id: UUID) {
        pendingImageAttachments.removeAll { $0.id == id }
    }

    private func importAttachments(from urls: [URL]) -> [ChatImageAttachment] {
        var attachments: [ChatImageAttachment] = []
        var failedFilenames: [String] = []

        for url in urls {
            do {
                attachments.append(try ChatImageAttachment(contentsOf: url))
            } catch {
                failedFilenames.append(url.lastPathComponent)
            }
        }

        switch failedFilenames.count {
        case 0:
            attachmentImportError = nil
        case 1:
            attachmentImportError =
                "“\(failedFilenames[0])” couldn’t be read. "
                + "Check that the file still exists and that you have permission to open it."
        default:
            attachmentImportError =
                "\(failedFilenames.count) files couldn’t be read. "
                + "Check that they still exist and that you have permission to open them."
        }
        return attachments
    }

    private var hasBlockingAttachmentValidation: Bool {
        pendingImageAttachments.contains { attachment in
            attachmentValidations[attachment.id]?.preventsSending ?? true
        }
    }

    private func synchronizeAttachmentValidations() {
        let liveIDs = Set(pendingImageAttachments.map(\.id))

        let staleTaskIDs = attachmentValidationTasks.keys.filter { !liveIDs.contains($0) }
        for id in staleTaskIDs {
            attachmentValidationTasks.removeValue(forKey: id)?.cancel()
        }
        attachmentValidations = attachmentValidations.filter { liveIDs.contains($0.key) }

        for attachment in pendingImageAttachments
        where attachmentValidations[attachment.id] == nil {
            if let validation = ChatAttachmentValidator.immediateValidation(for: attachment) {
                attachmentValidations[attachment.id] = validation
                continue
            }

            attachmentValidations[attachment.id] = .processing(
                message: "Reading “\(attachment.filename)”…"
            )
            let attachmentID = attachment.id
            attachmentValidationTasks[attachmentID] = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                do {
                    let validation = try await attachmentValidator.validateDocument(attachment)
                    try Task.checkCancellation()
                    guard pendingImageAttachments.contains(where: { $0.id == attachmentID }) else {
                        return
                    }
                    attachmentValidations[attachmentID] = validation
                } catch is CancellationError {
                    return
                } catch {
                    guard pendingImageAttachments.contains(where: { $0.id == attachmentID }) else {
                        return
                    }
                    attachmentValidations[attachmentID] = .blocked(
                        message:
                            "“\(attachment.filename)” couldn’t be processed: \(error.localizedDescription)"
                    )
                }
                attachmentValidationTasks[attachmentID] = nil
            }
        }
    }

    func clear() {
        if let currentSessionID, !canModifySession(currentSessionID) {
            return
        }
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
            let resource = InferenceActivityCoordinator.Resource.chat(
                queuedRequest.sessionID
            )
            guard
                inferenceActivity.begin(
                    resource: resource,
                    windowID: windowID,
                    operationID: queuedRequest.id
                )
            else {
                requestQueue.insert(queuedRequest, at: 0)
                return
            }
            guard insertAssistantMessage(for: queuedRequest) else {
                inferenceActivity.end(
                    resource: resource,
                    operationID: queuedRequest.id
                )
                continue
            }

            activeRequestID = queuedRequest.id
            activeAssistantMessageID = queuedRequest.assistantMessageID
            activeRequestSessionID = queuedRequest.sessionID
            sendingStartedAt = Date()
            if currentSessionID == queuedRequest.sessionID {
                bumpScroll()
            }

            activeTask = Task { @MainActor [weak self, inferenceActivity] in
                // Release the in-flight slot on every exit path. Clearing it only
                // after the request returned normally meant a stalled stream left
                // the session marked busy forever, which is what made a frozen
                // chat impossible to delete, stop, or switch away from.
                defer {
                    inferenceActivity.end(
                        resource: resource,
                        operationID: queuedRequest.id
                    )
                    if let self {
                        let ownedRequest = self.ownsActiveRequest(queuedRequest.id)
                        self.releaseActiveRequestSlot(matching: queuedRequest.id)
                        if ownedRequest {
                            if self.currentSessionID == queuedRequest.sessionID {
                                self.bumpScroll()
                            }
                            self.startNextRequestIfNeeded()
                        }
                    }
                }

                guard let self else {
                    return
                }

                do {
                    try await runChatLoop(queuedRequest)
                    appModel?.refreshMetricsIfRunning(force: true)
                } catch is CancellationError {
                    if ownsActiveRequest(queuedRequest.id) {
                        finishActiveAssistantAsCancelled(in: queuedRequest.sessionID)
                    }
                } catch let error as URLError where error.code == .cancelled {
                    if ownsActiveRequest(queuedRequest.id) {
                        finishActiveAssistantAsCancelled(in: queuedRequest.sessionID)
                    }
                } catch {
                    guard ownsActiveRequest(queuedRequest.id) else {
                        return
                    }
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
        let fileReadTracker = ChatReadFileTracker()
        let fileSearchTracker = ChatSearchFilesTracker()
        let fileOperationRunID = UUID()

        guard let initialMessages = sessionMessages(for: queuedRequest.sessionID),
            let initialAssistantIndex = initialMessages.firstIndex(where: {
                $0.id == queuedRequest.assistantMessageID
            })
        else {
            throw NativChatError.invalidResponse
        }
        let documentMessages = Array(initialMessages[..<initialAssistantIndex])
        var documentContext = PreparedDocumentContext(
            result: try await documentContextBuilder.contexts(for: documentMessages),
            characterLimit: ChatDocumentContextBuilder.defaultMaximumCharactersPerRequest
        )
        var effectiveContextLimit: Int?
        if !documentContext.result.contexts.isEmpty {
            effectiveContextLimit = try? await NativMetricsClient(
                baseURL: queuedRequest.settings.serverBaseURL
            )
            .fetchMetrics(apiKey: queuedRequest.settings.serverAPIKey)
            .server.effectiveContextLimit
        }

        while true {
            try Task.checkCancellation()
            let advertisesTools = ChatToolRoundGate.advertisesTools(atRound: toolRounds)
            documentContext = try await fittedDocumentContext(
                documentContext,
                messages: documentMessages,
                for: queuedRequest,
                before: assistantMessageID,
                advertisesTools: advertisesTools,
                settings: activeSettings,
                effectiveContextLimit: effectiveContextLimit,
                client: client
            )
            setDocumentContextOmissions(
                documentContext.result.omittedDocuments,
                for: queuedRequest.sessionID
            )
            guard
                let request = makeCompletionRequest(
                    for: queuedRequest,
                    before: assistantMessageID,
                    advertisesTools: advertisesTools,
                    settings: activeSettings,
                    documentContexts: documentContext.result.contexts
                )
            else {
                throw NativChatError.invalidResponse
            }

            let streamingMessageID = assistantMessageID
            let streamingSessionID = queuedRequest.sessionID
            let appendEvent: @MainActor @Sendable (MLXChatStreamDelta) -> Void = {
                [weak self] event in
                self?.append(
                    event: event,
                    to: streamingMessageID,
                    in: streamingSessionID
                )
            }
            let completion = try await client.streamChat(
                request,
                onEvent: { event in
                    await appendEvent(event)
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
                let initialToolStatus: ChatTranscriptMessage.ToolStatus =
                    switch toolCall.function?.name {
                    case ChatImageToolRegistry.generateToolName,
                        ChatImageToolRegistry.editToolName:
                        .preparing
                    default: .running
                    }
                guard
                    insertToolMessage(
                        id: toolMessageID,
                        call: toolCall,
                        after: insertionAnchor,
                        in: queuedRequest.sessionID,
                        status: initialToolStatus
                    )
                else {
                    throw NativChatError.invalidResponse
                }
                insertionAnchor = toolMessageID

                let customTool = toolCall.function?.name.flatMap { toolName in
                    queuedRequest.settings.customTools.first { $0.toolName == toolName }
                }
                var fileWriteApprovalGranted = false
                var terminalApprovalGranted = false
                if customTool?.kind == .script {
                    updateToolMessage(
                        toolMessageID,
                        in: queuedRequest.sessionID,
                        status: .awaitingConsent,
                        content: "",
                        attachments: []
                    )
                    let approved = await awaitToolConsent(for: toolMessageID)
                    switch ChatToolConsentRouter.outcome(
                        approved: approved, isCancelled: Task.isCancelled)
                    {
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
                            content:
                                #"{"ok":false,"error":"The user declined to run this script tool."}"#,
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

                let isNativeTerminal =
                    customTool == nil
                    && !(toolCall.function?.name.flatMap {
                        mcpHost?.handlesTool(named: $0)
                    } ?? false)
                    && toolCall.function?.name == ChatTerminalToolRegistry.toolName
                if isNativeTerminal {
                    do {
                        try ChatTerminalToolExecutor().preflight(
                            call: toolCall,
                            defaultWorkingDirectory: queuedRequest.toolScope
                                .terminalWorkingDirectory
                        )
                    } catch {
                        updateToolMessage(
                            toolMessageID,
                            in: queuedRequest.sessionID,
                            status: .failed,
                            content: ChatTerminalToolExecutor().failurePayload(error: error),
                            attachments: []
                        )
                        continue
                    }

                    updateToolMessage(
                        toolMessageID,
                        in: queuedRequest.sessionID,
                        status: .awaitingConsent,
                        content: "",
                        attachments: []
                    )
                    let approved = await awaitToolConsent(for: toolMessageID)
                    switch ChatToolConsentRouter.outcome(
                        approved: approved,
                        isCancelled: Task.isCancelled
                    ) {
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
                            content: ChatTerminalToolExecutor().declinedPayload(),
                            attachments: []
                        )
                        continue
                    case .approved:
                        terminalApprovalGranted = true
                        updateToolMessage(
                            toolMessageID,
                            in: queuedRequest.sessionID,
                            status: .running,
                            content: "",
                            attachments: []
                        )
                    }
                }

                if customTool == nil,
                    !(toolCall.function?.name.flatMap { mcpHost?.handlesTool(named: $0) } ?? false),
                    ChatFileWriteApprovalPolicy.requiresApproval(
                        call: toolCall,
                        rootPath: queuedRequest.toolScope.isProject
                            ? queuedRequest.toolScope.fileWriteRootPath
                            : queuedRequest.settings.fileWriteRootPath
                    )
                {
                    updateToolMessage(
                        toolMessageID,
                        in: queuedRequest.sessionID,
                        status: .awaitingConsent,
                        content: "",
                        attachments: []
                    )
                    let approved = await awaitToolConsent(for: toolMessageID)
                    switch ChatToolConsentRouter.outcome(
                        approved: approved,
                        isCancelled: Task.isCancelled
                    ) {
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
                            content: ChatFileWriteToolExecutor().declinedPayload(),
                            attachments: []
                        )
                        continue
                    case .approved:
                        fileWriteApprovalGranted = true
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
                    switch ChatToolConsentRouter.outcome(
                        approved: approved, isCancelled: Task.isCancelled)
                    {
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
                        let content = try await ChatSwitchModelToolExecutor().execute(
                            call: toolCall, appModel: appModel)
                        activeSettings.languageModelID =
                            appModel.settings.normalized().languageModelID
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
                        modelCacheVolumeIdentifier: queuedRequest.settings
                            .externalModelCache?.volumeIdentifier,
                        additionalModelSearchPaths: queuedRequest.settings
                            .additionalModelSearchPaths,
                        huggingFaceToken: appModel?.effectiveHuggingFaceToken
                    )
                    let context = ChatToolExecutionContext(
                        imageGenerationModelID: activeImageModelID,
                        baseURL: queuedRequest.settings.serverBaseURL,
                        apiKey: queuedRequest.settings.serverAPIKey,
                        imageReferences: references,
                        modelSearchPath: queuedRequest.settings.expandedModelSearchPath,
                        additionalModelSearchPaths: queuedRequest.settings
                            .additionalModelSearchPaths,
                        huggingFaceToken: imageModelPreparationContext.huggingFaceToken,
                        fileReadRootPath: queuedRequest.toolScope.isProject
                            ? queuedRequest.toolScope.fileReadRootPath
                            : queuedRequest.settings.fileReadRootPath,
                        fileReadTracker: fileReadTracker,
                        fileSearchTracker: fileSearchTracker,
                        fileWriteRootPath: queuedRequest.toolScope.isProject
                            ? queuedRequest.toolScope.fileWriteRootPath
                            : queuedRequest.settings.fileWriteRootPath,
                        fileWriteApprovalGranted: fileWriteApprovalGranted,
                        fileOperationRunID: fileOperationRunID,
                        terminalApprovalGranted: terminalApprovalGranted,
                        terminalDefaultWorkingDirectory: queuedRequest.toolScope
                            .terminalWorkingDirectory,
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
                        host.handlesTool(named: toolName)
                    {
                        let result = try await host.callTool(
                            named: toolName, argumentsJSON: toolCall.function?.arguments)
                        outcome = ChatToolExecutionOutcome(content: result, attachments: [])
                    } else {
                        outcome = try await ChatToolDispatcher.execute(
                            call: toolCall, context: context)
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
            guard ownsActiveRequest(queuedRequest.id) else {
                throw CancellationError()
            }
            assistantMessageID = UUID()
            activeAssistantMessageID = assistantMessageID
            guard
                insertAssistantMessage(
                    id: assistantMessageID,
                    after: insertionAnchor,
                    in: queuedRequest.sessionID,
                    settings: activeSettings
                )
            else {
                throw NativChatError.invalidResponse
            }
        }
    }

    private func fittedDocumentContext(
        _ current: PreparedDocumentContext,
        messages: [ChatTranscriptMessage],
        for queuedRequest: QueuedChatRequest,
        before assistantMessageID: UUID,
        advertisesTools: Bool,
        settings: NativSettings,
        effectiveContextLimit: Int?,
        client: NativChatClient
    ) async throws -> PreparedDocumentContext {
        guard !current.result.contexts.isEmpty,
            let effectiveContextLimit,
            effectiveContextLimit > 0
        else { return current }

        var prepared = current
        var measuredBasePromptTokens: Int?
        do {
            for _ in 0 ..< 3 {
                guard
                    let request = makeCompletionRequest(
                        for: queuedRequest,
                        before: assistantMessageID,
                        advertisesTools: advertisesTools,
                        settings: settings,
                        documentContexts: prepared.result.contexts
                    )
                else { return prepared }
                let promptTokens = try await client.countPromptTokens(for: request).inputTokens
                let promptLimit = max(
                    0,
                    effectiveContextLimit - request.maxTokens - ChatDocumentTokenBudget.safetyMargin
                )
                guard promptTokens > promptLimit else { return prepared }

                if measuredBasePromptTokens == nil {
                    guard
                        let baseRequest = makeCompletionRequest(
                            for: queuedRequest,
                            before: assistantMessageID,
                            advertisesTools: advertisesTools,
                            settings: settings,
                            documentContexts: [:]
                        )
                    else { return prepared }
                    measuredBasePromptTokens = try await client.countPromptTokens(
                        for: baseRequest
                    ).inputTokens
                }
                guard let basePromptTokens = measuredBasePromptTokens else { return prepared }
                var nextLimit = ChatDocumentTokenBudget.characterLimit(
                    currentLimit: prepared.characterLimit,
                    basePromptTokens: basePromptTokens,
                    documentPromptTokens: promptTokens,
                    contextLimit: effectiveContextLimit,
                    maximumOutputTokens: request.maxTokens
                )
                if nextLimit >= prepared.characterLimit {
                    nextLimit = max(0, prepared.characterLimit - 1)
                }
                prepared = PreparedDocumentContext(
                    result: try await documentContextBuilder.contexts(
                        for: messages,
                        maximumCharactersPerRequest: nextLimit
                    ),
                    characterLimit: nextLimit
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Preserve the character-bounded path if token preflight is unavailable.
        }
        return prepared
    }

    private func setDocumentContextOmissions(
        _ omissions: [ChatDocumentOmission],
        for sessionID: UUID
    ) {
        let contextLimited = omissions.filter { $0.reason == .contextLimit }
        if documentOmissionsBySessionID[sessionID] != contextLimited {
            documentOmissionsBySessionID[sessionID] = contextLimited.isEmpty ? nil : contextLimited
        }
    }

    private func makeCompletionRequest(
        for queuedRequest: QueuedChatRequest,
        before assistantMessageID: UUID,
        advertisesTools: Bool,
        settings: NativSettings,
        documentContexts: [UUID: String]
    ) -> MLXChatCompletionRequest? {
        guard let modelID = settings.languageModelID,
            let sessionMessages = sessionMessages(for: queuedRequest.sessionID),
            let assistantIndex = sessionMessages.firstIndex(where: { $0.id == assistantMessageID })
        else {
            return nil
        }

        let precedingMessages = sessionMessages[..<assistantIndex]
        var requestMessages = precedingMessages.compactMap { message in
            message.apiMessage(
                documentContext: documentContexts[message.id],
                includesImages: queuedRequest.languageModelSupportsVision
            )
        }

        let advertisesToolsForModel = advertisesTools && queuedRequest.languageModelSupportsTools
        var toolDefinitions: [MLXChatToolDefinition] =
            advertisesToolsForModel
            ? ChatToolRegistry.definitions(
                canEditImage: precedingMessages.contains { message in
                    message.imageAttachments.contains { $0.chatAttachmentKind == .image }
                }
            )
            : []
        if advertisesToolsForModel {
            toolDefinitions += settings.customTools.compactMap { try? $0.definition() }
            toolDefinitions += mcpHost?.toolDefinitions() ?? []
            let webSearchIsConfigured = ChatWebSearchToolRegistry.isConfigured()
            let webReadIsConfigured = ChatWebReadToolRegistry.isConfigured()
            let fileReadIsConfigured = FileReadAccessPolicy.isConfigured(
                rootPath: settings.fileReadRootPath
            )
            let fileReadToolsAreEnabled = ChatReadFileToolRegistry.toolNames.allSatisfy(
                settings.isToolEnabled
            )
            let fileWriteIsConfigured = FileWriteAccessPolicy.isConfigured(
                rootPath: settings.fileWriteRootPath
            )
            toolDefinitions.removeAll {
                let toolName = $0.function.name
                if queuedRequest.toolScope.isProject,
                    ChatToolScope.projectToolNames.contains(toolName)
                {
                    return !queuedRequest.toolScope.projectToolsAreAvailable
                }
                return !settings.isToolEnabled(toolName)
                    || ($0.function.name == ChatWebSearchToolRegistry.toolName
                        && !webSearchIsConfigured)
                    || ($0.function.name == ChatWebReadToolRegistry.toolName
                        && !webReadIsConfigured)
                    || (ChatReadFileToolRegistry.toolNames.contains($0.function.name)
                        && (!fileReadIsConfigured || !fileReadToolsAreEnabled))
                    || (ChatFileWriteToolRegistry.toolNames.contains($0.function.name)
                        && !fileWriteIsConfigured)
            }
        }
        let tools = toolDefinitions.isEmpty ? nil : toolDefinitions

        var systemParts: [String] = []
        if !settings.systemPrompt.isEmpty {
            systemParts.append(settings.systemPrompt)
        }
        if let projectPrompt = queuedRequest.toolScope.systemPrompt {
            systemParts.append(projectPrompt)
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
        for message in sessionMessages[...messageIndex].reversed() {
            let images = message.imageAttachments.filter {
                $0.chatAttachmentKind == .image
            }
            if !images.isEmpty {
                return images
            }
        }
        return []
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
            fallbackContent: "Response canceled.",
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

    private func projectID(for sessionID: UUID) -> UUID? {
        if currentSessionID == sessionID {
            return currentSession?.projectID
        }
        return storedSessions.first(where: { $0.id == sessionID })?.projectID
    }

    private func beginImageExecution(
        _ toolMessageID: UUID,
        modelID: String,
        in sessionID: UUID
    ) {
        if currentSessionID == sessionID {
            currentSession?.imageGenerationModelID = modelID
        } else {
            guard
                let sessionIndex = storedSessions.firstIndex(where: {
                    $0.id == sessionID
                })
            else {
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

        let now = Date.now
        let characterCount = streamingCharacterCount(id, in: sessionID)
        let flushInterval = ChatStreamingRenderPolicy.flushIntervalSeconds(
            characterCount: characterCount
        )
        if let lastFlush = streamFlushDates[id] {
            let elapsed = now.timeIntervalSince(lastFlush)
            if elapsed < flushInterval {
                scheduleStreamFlush(
                    id,
                    in: sessionID,
                    delay: flushInterval - elapsed
                )
                return
            }
        }
        flushStream(id, in: sessionID)
    }

    private func hasPendingStreamUpdate(_ id: UUID) -> Bool {
        pendingStreamContent[id]?.isEmpty == false
            || pendingStreamReasoning[id]?.isEmpty == false
            || pendingStreamMetrics[id] != nil
    }

    private func scheduleStreamFlush(
        _ id: UUID,
        in sessionID: UUID,
        delay: TimeInterval
    ) {
        guard streamFlushTasks[id] == nil else {
            return
        }
        streamFlushTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
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
        streamFlushDates[id] = .now
        if !content.isEmpty || !reasoning.isEmpty, currentSessionID == sessionID {
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

    private func streamingCharacterCount(_ id: UUID, in sessionID: UUID) -> Int {
        let message = message(id, in: sessionID)
        let contentCount = (message?.content.count ?? 0)
            + (pendingStreamContent[id]?.count ?? 0)
        let reasoningCount = (message?.reasoningContent.count ?? 0)
            + (pendingStreamReasoning[id]?.count ?? 0)
        return max(contentCount, reasoningCount)
    }

    private func shouldRefreshLiveMetrics(
        _ event: MLXChatStreamDelta,
        for messageID: UUID
    ) -> Bool {
        let hasGeneratedTokens = event.generatedTokens.map { $0 > 0 } == true
        let hasDecodeRate =
            event.decodeTokensPerSecond.map {
                $0 > 0 && $0.isFinite
            } == true
        guard hasGeneratedTokens || hasDecodeRate else {
            return false
        }

        let now = Date()
        if let lastRefresh = liveDecodeRateRefreshDates[messageID],
            now.timeIntervalSince(lastRefresh) < Self.liveDecodeRateRefreshInterval
        {
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
                let fallbackReasoningContent
            {
                message.reasoningContent = fallbackReasoningContent
            }
            message.toolCalls = toolCalls
            if !message.reasoningContent.isEmpty,
                message.thinkingDuration == nil
            {
                message.thinkingDuration = Date().timeIntervalSince(message.createdAt)
            }
            if isCancelled,
                message.content == fallbackContent,
                message.reasoningContent.isEmpty
            {
                message.role = .error
            }
            message.responseMetrics =
                responseMetrics?.hasVisibleValues == true
                ? responseMetrics
                : nil
        }
        persistSession(sessionID, updateTimestamp: true)
    }

    private func failAssistantMessage(_ id: UUID, in sessionID: UUID, error: Error) {
        clearStreamBuffers(id)
        liveDecodeRateRefreshDates.removeValue(forKey: id)
        guard
            updateMessage(
                id, in: sessionID,
                mutate: { message in
                    message.role = .error
                    message.content = error.localizedDescription
                    message.isStreaming = false
                    if !message.reasoningContent.isEmpty,
                        message.thinkingDuration == nil
                    {
                        message.thinkingDuration = Date().timeIntervalSince(message.createdAt)
                    }
                })
        else {
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
            let messageIndex = storedSessions[sessionIndex].messages.firstIndex(where: {
                $0.id == messageID
            })
        else {
            return false
        }

        mutate(&storedSessions[sessionIndex].messages[messageIndex])
        return true
    }

    private func bumpScroll() {
        transcriptRevision.bump()
    }

    private func applyCurrentSession(_ session: ChatSession) {
        currentSession = session
        currentSessionID = session.id
        currentProjectID = session.projectID
        messages =
            ChatSessionLoadPolicy.shouldNormalizeOnApply(
                sessionID: session.id,
                activeRequestSessionID: activeRequestSessionID
            ) ? normalizedForLoad(session.messages) : session.messages
        refreshSessionList()
        bumpScroll()
    }

    private func finishLoadingSessions(_ bootstrap: ChatSessionBootstrap) {
        defer {
            if needsPersistedSessionReload {
                needsPersistedSessionReload = false
                reloadPersistedSessions(preservingCurrentIfMissing: false)
            }
        }
        let localSession = currentSession
        let localSessionHasWork =
            localSession.map { session in
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
            saveSession(localSession)
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

    @discardableResult
    private func persistCurrentSession(updateTimestamp: Bool) -> Bool {
        guard var session = currentSession, canModifySession(session.id) else {
            return false
        }

        session.messages = messages
        session.title = ChatSession.defaultTitle(for: messages, createdAt: session.createdAt)
        if updateTimestamp {
            session.updatedAt = Date()
        }

        guard saveSession(session) else {
            return false
        }
        currentSession = session
        upsertStoredSession(session)
        refreshSessionList()
        return true
    }

    private var currentSessionSnapshot: ChatSession? {
        guard var session = currentSession else {
            return nil
        }
        session.messages = messages
        return session
    }

    private func activateBranch(
        _ branch: ChatSession,
        restoring composer: ComposerSnapshot? = nil
    ) {
        persistCurrentSession(updateTimestamp: false)

        draft = composer?.draft ?? ""
        pendingImageAttachments = composer?.attachments ?? []
        discardPromptEditing()
        upsertStoredSession(branch)
        saveSession(branch)
        applyCurrentSession(branch)
    }

    private func persistSession(_ sessionID: UUID, updateTimestamp: Bool) {
        guard canModifySession(sessionID) else {
            return
        }
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
        saveSession(storedSessions[index])
        refreshSessionList()
    }

    func reloadPersistedSessions() {
        reloadPersistedSessions(preservingCurrentIfMissing: true)
    }

    private func reloadPersistedSessions(preservingCurrentIfMissing: Bool) {
        guard !isLoadingSessions else {
            return
        }
        storedSessions = sessionStore.loadSessions()
        if let currentSession {
            if let fresh = storedSessions.first(where: { $0.id == currentSession.id }) {
                if activeRequestSessionID != currentSession.id, fresh != currentSession {
                    applyCurrentSession(fresh)
                }
            } else if preservingCurrentIfMissing || activeRequestSessionID == currentSession.id {
                upsertStoredSession(currentSession)
            } else {
                discardPromptEditing()
                draft = ""
                pendingImageAttachments.removeAll()
                if let replacement = storedSessions.sorted(by: ChatSession.recencySort).first {
                    applyCurrentSession(replacement)
                } else {
                    currentSessionID = nil
                    currentProjectID = nil
                    messages = []
                    self.currentSession = nil
                    createSession()
                }
            }
        }
        refreshSessionList()
    }

    private func handlePersistedDataChange(_ change: PersistedDataChange) {
        guard change.originWindowID != windowID else { return }

        switch change.kind {
        case .chatSession:
            if isLoadingSessions {
                needsPersistedSessionReload = true
            } else {
                reloadPersistedSessions(preservingCurrentIfMissing: false)
            }
        case .chatFolders:
            folders = sessionStore.loadFolders()
        case .imageGenerationSession:
            break
        }
    }

    @discardableResult
    private func saveSession(_ session: ChatSession) -> Bool {
        guard canModifySession(session.id) else {
            return false
        }
        guard sessionStore.saveSession(session) else {
            return false
        }
        persistedDataChanges.send(.chatSession(session.id), originWindowID: windowID)
        return true
    }

    func canModifySession(_ sessionID: UUID) -> Bool {
        !inferenceActivity.isOwnedByAnotherWindow(
            .chat(sessionID),
            windowID: windowID
        )
    }

    private func deletePersistedSession(_ sessionID: UUID) {
        sessionStore.deleteSession(id: sessionID)
        persistedDataChanges.send(.chatSession(sessionID), originWindowID: windowID)
    }

    private func saveFolders() {
        sessionStore.saveFolders(folders)
        persistedDataChanges.send(.chatFolders, originWindowID: windowID)
    }

    private func upsertStoredSession(_ session: ChatSession) {
        if let index = storedSessions.firstIndex(where: { $0.id == session.id }) {
            storedSessions[index] = session
        } else {
            storedSessions.append(session)
        }
    }

    private func refreshSessionList() {
        sessions =
            storedSessions
            .map(\.summary)
            .sorted(by: ChatSessionSummary.recencySort)
    }

    private func canReuseCurrentEmptySession(in projectID: UUID?) -> Bool {
        guard let currentSession else {
            return false
        }

        return currentSession.projectID == projectID
            && currentSession.messages.isEmpty
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pendingImageAttachments.isEmpty
    }

    private func pruneRedundantEmptySessions() {
        let selectedSessionID = currentSessionID
        let sortedSessions = storedSessions.sorted { lhs, rhs in
            if lhs.id == selectedSessionID { return true }
            if rhs.id == selectedSessionID { return false }
            return ChatSession.recencySort(lhs, rhs)
        }
        var seenIDs = Set<UUID>()
        var keptSessions: [ChatSession] = []
        var keptEmptyScopes = Set<UUID?>()
        var removedSessionIDs: [UUID] = []

        for session in sortedSessions {
            guard seenIDs.insert(session.id).inserted else {
                removedSessionIDs.append(session.id)
                continue
            }

            if session.messages.isEmpty {
                let routineStore = RoutineStore.shared
                let isLinkedToRoutine = routineStore.routines.contains {
                    $0.sourceSessionID == session.id
                } || routineStore.runs.contains {
                    $0.sessionID == session.id
                }
                if isLinkedToRoutine {
                    keptSessions.append(session)
                    continue
                }
                if !keptEmptyScopes.insert(session.projectID).inserted {
                    removedSessionIDs.append(session.id)
                    continue
                }
            }

            keptSessions.append(session)
        }

        storedSessions = keptSessions
        for sessionID in removedSessionIDs {
            RoutineStore.shared.detachSession(sessionID)
            deletePersistedSession(sessionID)
        }
    }
}
