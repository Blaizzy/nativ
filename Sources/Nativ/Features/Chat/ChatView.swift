import AppKit
import Foundation
import NativServerKit
import SwiftUI
import Textual
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject var model: NativModel
    let chat: ChatViewModel
    @ObservedObject var mcpHost: MCPHostManager
    @ObservedObject var extensionManager: NativExtensionManager
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
                extensionManager: extensionManager,
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

private enum ChatTranscriptLayout {
    static let conversationMaxWidth: CGFloat = 680
    static let horizontalPadding: CGFloat = 32
    static let messageHorizontalInset: CGFloat = 32
    static let composerClearance: CGFloat = 48
    static let composerFadeExtension: CGFloat = 40
}

private struct ChatTranscriptView: View {

    @ObservedObject var model: NativModel
    @ObservedObject var chat: ChatViewModel
    @ObservedObject var extensionManager: NativExtensionManager
    let workspaceMode: ChatWorkspaceMode
    let onSelectWorkspaceMode: (ChatWorkspaceMode) -> Void
    let conversationWidthReduction: CGFloat
    let onExploreImageModels: (ChatImageOperation) -> Void
    @State private var transcriptScrollPosition = ScrollPosition(edge: .bottom)
    @State private var composerHeight: CGFloat = 0
    @State private var composerBackdropHeight: CGFloat = 0
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
            .frame(
                maxWidth: ChatTranscriptLayout.conversationMaxWidth
                    - conversationWidthReduction
                    - (ChatTranscriptLayout.messageHorizontalInset * 2)
            )
            .frame(maxWidth: .infinity)
            .padding(
                .horizontal,
                ChatTranscriptLayout.horizontalPadding
                    + ChatTranscriptLayout.messageHorizontalInset
            )
            .padding(.top, 18)
            .padding(
                .bottom,
                max(18, composerHeight + ChatTranscriptLayout.composerClearance)
            )
        }
        .scrollPosition($transcriptScrollPosition)
        .overlay(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                composerBackdrop

                ChatComposerContainer(
                    model: model,
                    chat: chat,
                    extensionManager: extensionManager,
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
                    },
                    onBackdropHeightChange: { height in
                        composerBackdropHeight = height
                    }
                )
            }
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
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
    @ObservedObject var extensionManager: NativExtensionManager
    let workspaceMode: ChatWorkspaceMode
    let onSelectWorkspaceMode: (ChatWorkspaceMode) -> Void
    let conversationWidthReduction: CGFloat
    let onHeightChange: (CGFloat) -> Void
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
                ?? chat.unavailableReason(isRunning: model.isRunning, selectedModelID: selectedModelID)
                ?? model.settings.structuredOutputValidationError,
            canCompose: (model.isRunning || model.isModelLoading)
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
            },
            onBackdropHeightChange: onBackdropHeightChange
        )
        .frame(
            maxWidth: ChatTranscriptLayout.conversationMaxWidth
                - conversationWidthReduction
        )
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ChatTranscriptLayout.horizontalPadding)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onHeightChange(height)
        }
    }
}

private struct ChatMessageRow: View, @MainActor Equatable {
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
                        isStreaming: message.isStreaming,
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
            return Text(
                "The model wants to switch to \(Text(verbatim: requestedModelID).bold()). The server restarts briefly; your session is kept."
            )
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
                            rendersMarkdown: true,
                            isStreaming: isStreaming
                        )
                        .font(.callout)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                    } else {
                        Text(collapsedPreviewContent)
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
        } else if rendersMarkdown && isStreaming {
            ChatStreamingMarkdownText(
                content: content,
                fontScale: chatFontScale
            )
        } else if rendersMarkdown {
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

private struct ChatStreamingMarkdownText: View {
    private static let chunkSpacing: CGFloat = 16

    let document: NativStreamingMarkdownDocument
    let fontScale: Double

    init(content: String, fontScale: Double) {
        document = NativMarkdownFormatting.streamingDocument(in: content)
        self.fontScale = fontScale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.chunkSpacing) {
            ForEach(document.completedChunks) { chunk in
                ChatStreamingMarkdownChunk(chunk: chunk)
                    .equatable()
            }

            if !document.tail.isEmpty {
                InlineText(
                    markdown: NativMarkdownFormatting.normalizedMathDelimiters(
                        in: document.tail
                    ),
                    syntaxExtensions: [.math]
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textual.structuredTextStyle(.gitHub)
        .textual.textSelection(.enabled)
        .font(ChatFontMetrics.bodyFont(scale: fontScale))
    }
}

private struct ChatStreamingMarkdownChunk: View, Equatable {
    let chunk: NativStreamingMarkdownDocument.Chunk

    var body: some View {
        StructuredText(
            markdown: NativMarkdownFormatting.normalizedMathDelimiters(
                in: chunk.markdown
            ),
            syntaxExtensions: [.math]
        )
        .fixedSize(horizontal: false, vertical: true)
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
        workspaceMode: .chat,
        onSelectWorkspaceMode: { _ in },
        showsConfiguration: .constant(true),
        conversationWidthReduction: 0,
        onExploreImageModels: { _ in }
    )
}
