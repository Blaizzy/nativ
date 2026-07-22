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

struct ChatView: View {
    private enum Layout {
        static let conversationMaxWidth: CGFloat = 680
        static let horizontalPadding: CGFloat = 32
    }

    @ObservedObject var model: NativModel
    @ObservedObject var chat: ChatViewModel
    @Binding var showsConfiguration: Bool
    @State private var transcriptScrollPosition = ScrollPosition(edge: .bottom)
    @State private var composerHeight: CGFloat = 0
    @State private var followsLatestMessage = true

    var body: some View {
        ModelConfigurationLayout(
            model: model,
            isConfigurationVisible: $showsConfiguration
        ) {
            VStack(spacing: 0) {
                transcript
                    .overlay(alignment: .bottom) {
                        ChatComposer(
                            model: model,
                            viewModel: chat,
                            unavailableReason: unavailableReason,
                            canCompose: canCompose,
                            canSend: canSend,
                            onSend: {
                                chat.send(using: model)
                            }
                        )
                        .frame(maxWidth: Layout.conversationMaxWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Layout.horizontalPadding)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            let isInitialMeasurement = composerHeight == 0
                            composerHeight = height
                            if isInitialMeasurement {
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(50))
                                    transcriptScrollPosition.scrollTo(edge: .bottom)
                                }
                            }
                        }
                    }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var selectedModelID: String? {
        model.settings.normalized().languageModelID
    }

    private var canSend: Bool {
        model.settings.structuredOutputValidationError == nil
            && chat.canSend(isRunning: model.isRunning, selectedModelID: selectedModelID)
    }

    private var canCompose: Bool {
        model.isRunning
            && selectedModelID?.isEmpty == false
            && model.settings.structuredOutputValidationError == nil
    }

    private var unavailableReason: String? {
        chat.unavailableReason(isRunning: model.isRunning, selectedModelID: selectedModelID)
            ?? model.settings.structuredOutputValidationError
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if chat.visibleMessages.isEmpty {
                    if chat.messages.isEmpty {
                        ChatEmptyTranscriptView(
                            isRunning: model.isRunning,
                            selectedModelID: selectedModelID
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                    }
                } else {
                    ForEach(chat.visibleMessages) { message in
                        ChatMessageRow(message: message)
                            .id(message.id)
                    }
                }
            }
            .frame(maxWidth: Layout.conversationMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.top, 18)
            .padding(.bottom, max(18, composerHeight))
        }
        .scrollPosition($transcriptScrollPosition)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 160
        } action: { _, isNearBottom in
            followsLatestMessage = isNearBottom
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
        .onAppear {
            followsLatestMessage = true
            transcriptScrollPosition.scrollTo(edge: .bottom)
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    private static let liveDecodeRateRefreshInterval: TimeInterval = 0.25
    private static let streamFlushInterval: TimeInterval = 1.0 / 30.0

    private struct QueuedChatRequest {
        let id: UUID
        let sessionID: UUID
        let userMessageID: UUID
        let assistantMessageID: UUID
        let settings: NativSettings
    }

    @Published private(set) var sessions: [ChatSessionSummary] = []
    @Published private(set) var currentSessionID: UUID?
    @Published private(set) var messages: [ChatTranscriptMessage] = []
    @Published private(set) var pendingImageAttachments: [ChatImageAttachment] = []
    @Published var draft = ""
    @Published private(set) var activeRequestSessionID: UUID?
    @Published private(set) var sendingStartedAt: Date?
    @Published private(set) var scrollToken = 0

    private let sessionStore = ChatSessionStore()
    private var activeTask: Task<Void, Never>?
    private var activeRequestID: UUID?
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

    init() {
        storedSessions = sessionStore.loadSessions()
        pruneRedundantEmptySessions()
        if let latestSession = storedSessions.sorted(by: ChatSession.recencySort).first {
            applyCurrentSession(latestSession)
        } else {
            createSession()
        }
    }

    deinit {
        activeTask?.cancel()
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
        return messages.filter { !queuedMessageIDs.contains($0.id) }
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
        draft = ""
        pendingImageAttachments.removeAll()
        applyCurrentSession(session)
    }

    func selectSession(_ sessionID: UUID) {
        guard sessionID != currentSessionID else {
            return
        }

        if let session = storedSessions.first(where: { $0.id == sessionID }) {
            persistCurrentSession(updateTimestamp: false)
            draft = ""
            pendingImageAttachments.removeAll()
            applyCurrentSession(session)
            return
        }

        if let session = sessionStore.loadSession(id: sessionID) {
            persistCurrentSession(updateTimestamp: false)
            upsertStoredSession(session)
            draft = ""
            pendingImageAttachments.removeAll()
            applyCurrentSession(session)
        }
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

        draft = ""
        pendingImageAttachments.removeAll()

        if let nextSession = storedSessions.sorted(by: ChatSession.recencySort).first {
            applyCurrentSession(nextSession)
        } else {
            currentSession = nil
            currentSessionID = nil
            messages = []
            createSession()
        }
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

    func send(using appModel: NativModel) {
        let settings = appModel.settings.normalized()
        guard canSend(isRunning: appModel.isRunning, selectedModelID: settings.languageModelID),
              let modelID = settings.languageModelID,
              let currentSession
        else {
            return
        }

        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageAttachments = pendingImageAttachments
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
        self.appModel = appModel
        requestQueue.append(QueuedChatRequest(
            id: UUID(),
            sessionID: currentSession.id,
            userMessageID: userMessage.id,
            assistantMessageID: UUID(),
            settings: settings
        ))
        bumpScroll()
        startNextRequestIfNeeded()
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
        panel.allowedContentTypes = [.image]

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

    func removePendingImageAttachment(_ id: UUID) {
        pendingImageAttachments.removeAll { $0.id == id }
    }

    func clear() {
        activeTask?.cancel()
        activeTask = nil
        activeRequestID = nil
        activeRequestSessionID = nil
        requestQueue.removeAll()
        sendingStartedAt = nil
        draft = ""
        pendingImageAttachments.removeAll()
        messages.removeAll()
        persistCurrentSession(updateTimestamp: true)
        bumpScroll()
    }

    private func startNextRequestIfNeeded() {
        guard activeTask == nil else {
            return
        }

        while !requestQueue.isEmpty {
            let queuedRequest = requestQueue.removeFirst()
            guard let request = makeCompletionRequest(for: queuedRequest),
                  insertAssistantMessage(for: queuedRequest)
            else {
                continue
            }

            activeRequestID = queuedRequest.id
            activeRequestSessionID = queuedRequest.sessionID
            sendingStartedAt = Date()
            if currentSessionID == queuedRequest.sessionID {
                bumpScroll()
            }

            let client = NativChatClient(baseURL: queuedRequest.settings.serverBaseURL)

            activeTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                do {
                    let completion = try await client.streamChat(request, onEvent: { [weak self] event in
                        await MainActor.run {
                            self?.append(
                                event: event,
                                to: queuedRequest.assistantMessageID,
                                in: queuedRequest.sessionID
                            )
                        }
                    })
                    finishAssistantMessage(
                        queuedRequest.assistantMessageID,
                        in: queuedRequest.sessionID,
                        fallbackContent: completion.content,
                        fallbackReasoningContent: completion.reasoningContent,
                        responseMetrics: ChatResponseMetrics(completion: completion),
                        isCancelled: false
                    )
                    appModel?.refreshMetricsIfRunning(force: true)
                } catch is CancellationError {
                    finishAssistantMessage(
                        queuedRequest.assistantMessageID,
                        in: queuedRequest.sessionID,
                        fallbackContent: "Response cancelled.",
                        fallbackReasoningContent: nil,
                        responseMetrics: nil,
                        isCancelled: true
                    )
                } catch {
                    failAssistantMessage(
                        queuedRequest.assistantMessageID,
                        in: queuedRequest.sessionID,
                        error: error
                    )
                    appModel?.refreshMetricsIfRunning(force: true)
                }

                guard activeRequestID == queuedRequest.id else {
                    return
                }
                activeRequestID = nil
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

    private func makeCompletionRequest(for queuedRequest: QueuedChatRequest) -> MLXChatCompletionRequest? {
        guard let modelID = queuedRequest.settings.languageModelID,
              let sessionMessages = sessionMessages(for: queuedRequest.sessionID),
              let userMessageIndex = sessionMessages.firstIndex(where: { $0.id == queuedRequest.userMessageID })
        else {
            return nil
        }

        var requestMessages = sessionMessages[...userMessageIndex].compactMap(\.apiMessage)
        if !queuedRequest.settings.systemPrompt.isEmpty {
            requestMessages.insert(
                MLXChatMessage(role: "system", content: queuedRequest.settings.systemPrompt),
                at: 0
            )
        }

        let settings = queuedRequest.settings
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
            thinkingBudget: settings.thinkingEnabled && settings.thinkingBudgetEnabled
                ? settings.thinkingBudget
                : nil,
            thinkingStartToken: settings.thinkingEnabled ? settings.thinkingStartToken : nil,
            thinkingEndToken: settings.thinkingEnabled ? settings.thinkingEndToken : nil,
            responseFormat: settings.chatResponseFormat,
            stream: true
        )
    }

    private func insertAssistantMessage(for queuedRequest: QueuedChatRequest) -> Bool {
        let assistantMessage = ChatTranscriptMessage(
            id: queuedRequest.assistantMessageID,
            role: .assistant,
            content: "",
            modelID: queuedRequest.settings.languageModelID,
            isStreaming: true,
            isThinkingEnabled: queuedRequest.settings.thinkingEnabled
        )

        if currentSessionID == queuedRequest.sessionID {
            guard let userMessageIndex = messages.firstIndex(where: { $0.id == queuedRequest.userMessageID }) else {
                return false
            }
            messages.insert(assistantMessage, at: userMessageIndex + 1)
            return true
        }

        guard let sessionIndex = storedSessions.firstIndex(where: { $0.id == queuedRequest.sessionID }),
              let userMessageIndex = storedSessions[sessionIndex].messages.firstIndex(
                where: { $0.id == queuedRequest.userMessageID }
              )
        else {
            return false
        }
        storedSessions[sessionIndex].messages.insert(assistantMessage, at: userMessageIndex + 1)
        return true
    }

    private func sessionMessages(for sessionID: UUID) -> [ChatTranscriptMessage]? {
        if currentSessionID == sessionID {
            return messages
        }
        return storedSessions.first(where: { $0.id == sessionID })?.messages
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
                    peakMemoryGB: message.responseMetrics?.peakMemoryGB
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
        messages = session.messages
        refreshSessionList()
        bumpScroll()
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

private struct ChatMessageRow: View {
    private static let maximumUserBubbleWidth: CGFloat = 560

    let message: ChatTranscriptMessage
    @State private var didCopyResponse = false
    @State private var isHoveringMessage = false

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            if !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: contentStackAlignment, spacing: 6) {
                if !message.imageAttachments.isEmpty {
                    ChatImageAttachmentStack(
                        attachments: message.imageAttachments,
                        isUserMessage: message.role == .user
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

            if showsCopyAction {
                HStack(spacing: 8) {
                    ChatCopyResponseButton(
                        didCopy: didCopyResponse,
                        onCopy: copyResponse
                    )

                    Text(message.createdAt, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .opacity(isHoveringMessage || didCopyResponse ? 1 : 0)
                .accessibilityHidden(!isHoveringMessage && !didCopyResponse)
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
                    isStreaming: message.isStreaming
                )
                .lineSpacing(2)
                .fixedSize(horizontal: true, vertical: false)
            } else {
                ChatMessageText(
                    content: displayContent,
                    rendersMarkdown: rendersMarkdown,
                    isStreaming: message.isStreaming
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
        !message.content.isEmpty
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

    private var showsCopyAction: Bool {
        message.role == .assistant
            && !message.isStreaming
            && !message.content.isEmpty
    }

    private func copyResponse() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.content, forType: .string)

        withAnimation(.easeInOut(duration: 0.15)) {
            didCopyResponse = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeInOut(duration: 0.15)) {
                didCopyResponse = false
            }
        }
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

private struct ChatCopyResponseButton: View {
    let didCopy: Bool
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
        .help(didCopy ? "Copied" : "Copy response")
        .accessibilityLabel(didCopy ? "Response copied" : "Copy response")
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.15), value: didCopy)
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

    var body: some View {
        VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                ChatImageAttachmentView(attachment: attachment)
            }
        }
    }
}

private struct ChatImageAttachmentView: View {
    let attachment: ChatImageAttachment

    private let maximumSideLength: CGFloat = 300

    var body: some View {
        Group {
            if let image {
                let size = displaySize(for: image)

                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
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
        .help(attachment.filename)
        .accessibilityLabel(attachment.filename)
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
}

private struct ChatMessageText: View {
    let content: String
    let rendersMarkdown: Bool
    let isStreaming: Bool

    @ViewBuilder
    var body: some View {
        if rendersMarkdown && !isStreaming {
            StructuredText(
                markdown: NativMarkdownFormatting.normalizedMathDelimiters(in: content),
                syntaxExtensions: [.math]
            )
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
            .font(.body)
        } else {
            renderedText
                .textSelection(.enabled)
                .font(.body)
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

private struct ChatEmptyTranscriptView: View {
    let isRunning: Bool
    let selectedModelID: String?

    var body: some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        if !isRunning {
            return "Server is stopped"
        }
        if selectedModelID == nil {
            return "No model selected"
        }
        return "No messages"
    }

    private var detail: String {
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
    ChatView(model: .init(), chat: ChatViewModel(), showsConfiguration: .constant(true))
}
