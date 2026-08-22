import AppKit
import Foundation
import SwiftUI

private struct ChatImageThumbnail: View {
    let attachment: ChatImageAttachment
    let isUserMessage: Bool
    var width: CGFloat = 120
    var height: CGFloat = 90

    var body: some View {
        Group {
            if let data = attachment.imageData,
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: ArtifactKind.resolve(mimeType: attachment.mimeType, filename: attachment.filename).systemImage)
                        .font(.title3)
                    Text(attachment.filename)
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(isUserMessage ? Color.white.opacity(0.82) : Color(nsColor: .secondaryLabelColor))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isUserMessage ? Color.white.opacity(0.3) : Color(nsColor: .separatorColor),
                    lineWidth: 0.5
                )
        )
        .help(attachment.filename)
    }
}

private enum ChatReasoningLevel: String, CaseIterable, Identifiable {
    case off = "Off"
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case max = "Max"

    var id: Self { self }

    var tokenBudget: Int? {
        switch self {
        case .off, .max:
            nil
        case .low:
            512
        case .medium:
            2_048
        case .high:
            8_192
        }
    }

    var detail: String {
        switch self {
        case .off:
            ""
        case .low:
            "Max 512 tokens"
        case .medium:
            "Max 2,048 tokens"
        case .high:
            "Max 8,192 tokens"
        case .max:
            "Unlimited"
        }
    }

}

private struct ChatBrowsingAvailability: Sendable {
    let isSearchAvailable: Bool
    let isReadAvailable: Bool
    let searchProviderLabel: String?
    let readProviderLabel: String?

    static func load() -> Self {
        let preferences = WebBrowsingPreferences()
        let isSearchAvailable = ChatWebSearchToolRegistry.isConfigured()
        let isReadAvailable = ChatWebReadToolRegistry.isConfigured()

        return Self(
            isSearchAvailable: isSearchAvailable,
            isReadAvailable: isReadAvailable,
            searchProviderLabel: isSearchAvailable
                ? preferences.searchProvider.metadata.displayName
                : nil,
            readProviderLabel: isReadAvailable
                ? preferences.provider(for: .read)?.metadata.displayName
                : nil
        )
    }
}

struct ChatComposer: View {
    @ObservedObject var model: NativModel
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var extensionManager: NativExtensionManager
    @Environment(\.openExtensionsHubSection) private var openExtensionsHubSection
    @StateObject private var localLibrary = LocalModelLibrary()
    let unavailableReason: String?
    let canCompose: Bool
    let canSend: Bool
    let workspaceMode: ChatWorkspaceMode
    let onSelectWorkspaceMode: (ChatWorkspaceMode) -> Void
    let onSend: (Bool, Bool) -> Void
    let onBackdropHeightChange: (CGFloat) -> Void
    @State private var editorContentHeight: CGFloat = 0
    @State private var didApplyInitialReasoningDefault = false
    @State private var isApplyingDrafterSelection = false
    @State private var showsKits = false
    @State private var showsCapabilities = false
    @State private var showsAddPanel = false
    @State private var isWebSearchAvailable = false
    @State private var isWebReadAvailable = false
    @State private var webSearchProviderLabel: String?
    @State private var webReadProviderLabel: String?
    @State private var browsingConfigurationRevision = 0
    @State private var composerWidth: CGFloat = 410
    private let textInset = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
    private let editorMinimumHeight: CGFloat = 64
    private let editorMaximumHeight: CGFloat = 120
    private let composerVerticalPadding: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.promptEditContext != nil {
                ChatPromptEditBanner(
                    onCancel: viewModel.cancelPromptEditing
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if viewModel.isCurrentSessionSending, let sendingStartedAt = viewModel.sendingStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(sendingStartedAt)
                    Text(workingStatus(elapsed: elapsed))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, textInset.leading + 4)
            } else if let unavailableReason {
                Text(unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, textInset.leading + 4)
            }

            if !viewModel.currentSessionQueuedPrompts.isEmpty {
                ChatQueueTray(
                    prompts: viewModel.currentSessionQueuedPrompts,
                    onSteer: viewModel.steerQueuedRequest,
                    onPrioritize: viewModel.prioritizeQueuedRequest,
                    onRemove: viewModel.removeQueuedRequest
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ChatComposerTextEditor(
                        text: $viewModel.draft,
                        isEnabled: canCompose,
                        onSubmit: send,
                        onCancel: cancelPromptEditingAction,
                        onPasteImage: { viewModel.attachImages(from: $0) },
                        onContentHeightChange: { height in
                            editorContentHeight = height
                        },
                        fontScale: model.settings.chatFontScale,
                        focusToken: viewModel.composerFocusToken
                    )

                    if viewModel.draft.isEmpty {
                        Text(viewModel.promptEditContext == nil ? "Message" : "Edit message")
                            .font(ChatFontMetrics.bodyFont(scale: model.settings.chatFontScale))
                            .foregroundStyle(.tertiary)
                            .padding(textInset)
                            .offset(x: 4)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: editorHeight)

                if !viewModel.pendingImageAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.pendingImageAttachments) { attachment in
                                ChatPendingImageAttachmentView(
                                    attachment: attachment,
                                    validation: viewModel.attachmentValidation(for: attachment.id),
                                    modelRejectsImage: modelLacksVision
                                        && attachment.chatAttachmentKind == .image
                                ) {
                                    viewModel.removePendingImageAttachment(attachment.id)
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }

                if !attachmentNotices.isEmpty {
                    ChatAttachmentNoticesView(
                        notices: attachmentNotices,
                        onDismiss: dismissAttachmentNotice
                    )
                }

                HStack(spacing: 8) {
                    ChatComposerAddButton(
                        isEnabled: canCompose,
                        isPresented: $showsAddPanel
                    )
                    .frame(width: 30, height: 30)
                    .help("More message options")

                    ChatWorkspacePicker(
                        selection: workspaceMode,
                        onSelect: onSelectWorkspaceMode
                    )

                    Spacer(minLength: 12)

                    modelPicker

                    Button {
                        if showsStopButton {
                            viewModel.cancel()
                        } else {
                            send()
                        }
                    } label: {
                        Image(systemName: showsStopButton ? "stop.fill" : "arrow.up")
                            .font(.system(size: showsStopButton ? 10 : 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(actionButtonColor, in: Circle())
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(!showsStopButton && !effectiveCanSend)
                    .help(actionButtonHelp)
                }
                .padding(.leading, 10)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                onBackdropHeightChange(height + (composerVerticalPadding * 2))
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                composerWidth = width
            }
            .background {
                NativArrowlessPopoverPresenter(isPresented: $showsAddPanel) {
                    addPanel
                }
            }
        }
        .padding(.vertical, composerVerticalPadding)
        .task(id: modelScanKey) {
            localLibrary.scan(searchPaths: model.settings.localModelSearchPaths)
        }
        .task(id: browsingConfigurationRevision) {
            await refreshBrowsingAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: .webBrowsingConfigurationDidChange)) { _ in
            browsingConfigurationRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .localModelLibraryDidChange)) { _ in
            localLibrary.scan(searchPaths: model.settings.localModelSearchPaths)
        }
        .onChange(of: localLibrary.models) { _, models in
            disableThinkingIfUnsupported(modelID: selectedModelID, models: models)
            applyInitialReasoningDefaultIfNeeded(modelID: selectedModelID, models: models)
        }
        .onChange(of: selectedModelID) { oldModelID, newModelID in
            // Drafter selection writes the switched model's full configuration itself;
            // re-running the generic profile swap here would corrupt it.
            if isApplyingDrafterSelection {
                isApplyingDrafterSelection = false
                return
            }
            applyModelConfigOnSwitch(from: oldModelID, to: newModelID, models: localLibrary.models)
        }
        .onChange(of: model.settings.currentModelProfile) { _, _ in
            guard let modelID = selectedModelID, !modelID.isEmpty else {
                return
            }
            model.settings.rememberProfile(forModel: modelID)
        }
        .onDisappear {
            localLibrary.cancel()
        }
        .sheet(isPresented: $showsKits) {
            ChatKitsPickerSheet(
                model: model,
                manager: extensionManager
            )
        }
        .sheet(isPresented: $showsCapabilities) {
            ChatCapabilitiesSheet(model: model)
        }
    }

    private var addPanel: some View {
        ChatComposerActionPanel(
            canPasteImage: viewModel.canPasteImage,
            showsGlobalTools: true,
            isWebSearchEnabled: globalToolIsEnabled(
                ChatWebSearchToolRegistry.toolName,
                isAvailable: isWebSearchAvailable
            ),
            isWebSearchAvailable: isWebSearchAvailable,
            webSearchProviderLabel: webSearchProviderLabel,
            isWebReadEnabled: globalToolIsEnabled(
                ChatWebReadToolRegistry.toolName,
                isAvailable: isWebReadAvailable
            ),
            isWebReadAvailable: isWebReadAvailable,
            webReadProviderLabel: webReadProviderLabel,
            onAttachImages: { dismissAddPanelAndPerform(viewModel.chooseAttachments) },
            onPasteImage: { dismissAddPanelAndPerform(viewModel.pasteImageFromClipboard) },
            onCaptureScreenshot: { dismissAddPanelAndPerform(viewModel.captureScreenshot) },
            onToggleWebSearch: {
                toggleGlobalBrowsingTool(
                    ChatWebSearchToolRegistry.toolName,
                    isAvailable: isWebSearchAvailable
                )
            },
            onToggleWebRead: {
                toggleGlobalBrowsingTool(
                    ChatWebReadToolRegistry.toolName,
                    isAvailable: isWebReadAvailable
                )
            },
            onOpenKits: { dismissAddPanelAndPerform { showsKits = true } },
            onOpenCapabilities: { dismissAddPanelAndPerform { showsCapabilities = true } }
        )
        .frame(width: max(320, composerWidth))
    }

    private func dismissAddPanelAndPerform(_ action: @escaping () -> Void) {
        showsAddPanel = false
        Task { @MainActor in
            await Task.yield()
            action()
        }
    }

    private func globalToolIsEnabled(_ toolName: String, isAvailable: Bool) -> Bool {
        isAvailable && model.settings.isToolEnabled(toolName)
    }

    private func toggleGlobalBrowsingTool(
        _ toolName: String,
        isAvailable: Bool
    ) {
        guard isAvailable else {
            let openExtensionsHubSection = openExtensionsHubSection
            dismissAddPanelAndPerform {
                openExtensionsHubSection(.tools)
            }
            return
        }

        model.settings.setToolEnabled(
            !model.settings.isToolEnabled(toolName),
            toolName: toolName
        )
        showsAddPanel = false
    }

    private func refreshBrowsingAvailability() async {
        let availability = await Task.detached(priority: .userInitiated) {
            ChatBrowsingAvailability.load()
        }.value
        guard !Task.isCancelled else { return }

        isWebSearchAvailable = availability.isSearchAvailable
        isWebReadAvailable = availability.isReadAvailable
        webSearchProviderLabel = availability.searchProviderLabel
        webReadProviderLabel = availability.readProviderLabel
    }

    private var modelScanKey: String {
        model.settings.localModelSearchPaths.cacheKey
    }

    private var modelPicker: some View {
        ComposerModelPicker(
            models: languageModels,
            selectedModelID: selectedModelID,
            selectedModelLabel: selectedModelLabel,
            selectedModelProvider: selectedModelProvider,
            selectedModelDetail: selectedModelSupportsThinking
                ? reasoningLevel.rawValue
                : nil,
            secondarySection: reasoningPickerSection,
            isModelLoading: model.isModelLoading,
            modelLoadingPercentage: model.modelLoadingPercentage,
            isDisabled: model.isModelLoading || viewModel.hasPendingRequests,
            statusLabel: localModelStatusLabel,
            helpText: modelPickerHelp,
            accessibilityValue: modelPickerAccessibilityValue,
            shortcutLabel: "⌃⇧M",
            emptyStateActionTitle: nil,
            onEmptyStateAction: nil,
            onSelectModel: select,
            onSwitchModel: { model.switchLanguageModel(to: $0) },
            drafters: drafterModels,
            selectedDrafterID: selectedDrafterID,
            onSelectDrafter: selectDrafter
        )
    }

    private var languageModels: [LocalModel] {
        localLibrary.models.filter { $0.isEligibleForLanguageModelPicker }
    }

    private var drafterModels: [LocalModel] {
        localLibrary.models.filter { $0.drafterKind != nil }
    }

    private var selectedDrafterID: String? {
        guard model.settings.speculativeDecodingActive else { return nil }
        return model.settings.draftModelID
    }

    private var selectedModelID: String? {
        model.settings.normalized().languageModelID
    }

    private var selectedModelLabel: String {
        guard let selectedModelID else {
            return "Choose model"
        }
        return modelMenuLabel(selectedModelID)
    }

    private var modelPickerAccessibilityValue: String {
        let value = selectedModelSupportsThinking
            ? "\(selectedModelLabel), reasoning \(reasoningLevel.rawValue)"
            : selectedModelLabel
        guard model.isModelLoading, let percentage = model.modelLoadingPercentage else {
            return value
        }
        return "\(value), loading \(percentage) percent"
    }

    private var modelLacksVision: Bool {
        guard let model = selectedLocalModel else { return false }
        return !model.capabilities.contains(.vision)
    }

    private var hasVisionRejectedAttachment: Bool {
        modelLacksVision && viewModel.hasPendingImageAttachments
    }

    private var effectiveCanSend: Bool {
        canSend && !hasVisionRejectedAttachment
    }

    private var attachmentNotices: [ChatAttachmentNotice] {
        var notices: [ChatAttachmentNotice] = []
        let rejectedImages = modelLacksVision
            ? viewModel.pendingImageAttachments.filter { $0.chatAttachmentKind == .image }
            : []

        if !rejectedImages.isEmpty {
            notices.append(ChatAttachmentNotice(
                id: "vision-model-required",
                severity: .error,
                title: "This model can’t view images",
                message: visionModelWarningMessage(for: rejectedImages),
                systemImage: "eye.slash.fill"
            ))
        }

        for attachment in viewModel.pendingImageAttachments {
            if modelLacksVision, attachment.chatAttachmentKind == .image {
                continue
            }

            guard let validation = viewModel.attachmentValidation(for: attachment.id) else {
                continue
            }
            switch validation {
            case .processing(let message):
                notices.append(ChatAttachmentNotice(
                    id: "attachment-\(attachment.id.uuidString)",
                    severity: .progress,
                    message: message
                ))
            case .warning(let message, _):
                notices.append(ChatAttachmentNotice(
                    id: "attachment-\(attachment.id.uuidString)",
                    severity: .warning,
                    title: "PDF will be shortened",
                    message: message
                ))
            case .blocked(let message):
                notices.append(ChatAttachmentNotice(
                    id: "attachment-\(attachment.id.uuidString)",
                    severity: .error,
                    title: "Attachment can’t be used",
                    message: message
                ))
            case .ready:
                break
            }
        }

        let pendingPDFCount = viewModel.pendingImageAttachments.count {
            $0.chatAttachmentKind == .pdf
        }
        if pendingPDFCount > 1,
           viewModel.pendingPDFCharacterCount
            > ChatDocumentContextBuilder.defaultMaximumCharactersPerRequest {
            notices.append(ChatAttachmentNotice(
                id: "pdf-request-limit",
                severity: .warning,
                title: "PDF context limit reached",
                message: "These PDFs exceed the "
                    + "\(ChatDocumentContextBuilder.defaultMaximumCharactersPerRequest.formatted())"
                    + "-character request limit. Newer documents will be prioritized."
            ))
        }

        if modelLacksVision,
           !viewModel.hasPendingImageAttachments,
           viewModel.hasImageAttachmentsInCurrentSession {
            notices.append(ChatAttachmentNotice(
                id: "historical-images-unavailable",
                severity: .warning,
                title: "Earlier images are unavailable",
                message: "The selected model can’t access images from earlier messages in this chat.",
                systemImage: "eye.slash.fill"
            ))
        }

        if let attachmentImportError = viewModel.attachmentImportError {
            notices.append(ChatAttachmentNotice(
                id: "attachment-import-error",
                severity: .warning,
                title: "Some files weren’t added",
                message: attachmentImportError,
                isDismissible: true
            ))
        }
        return notices
    }

    private func visionModelWarningMessage(
        for attachments: [ChatImageAttachment]
    ) -> String {
        if attachments.count == 1, let filename = attachments.first?.filename {
            return "Remove “\(filename)” or choose a vision-capable model to continue."
        }
        return "Remove these \(attachments.count) images or choose a vision-capable model to continue."
    }

    private var selectedLocalModel: LocalModel? {
        guard let selectedModelID else { return nil }
        return localLibrary.models.first { $0.repoID == selectedModelID }
    }

    private var selectedModelProvider: LocalModelProvider? {
        if let provider = selectedLocalModel?.provider {
            return provider
        }
        guard let selectedModelID else { return nil }
        return provider(for: selectedModelID)
    }

    private var selectedModelSupportsThinking: Bool {
        model.settings.thinkingEnabled
            || selectedLocalModel?.capabilities.contains(.reasoning) == true
    }

    private var reasoningLevel: ChatReasoningLevel {
        guard model.settings.thinkingEnabled else {
            return .off
        }
        guard model.settings.thinkingBudgetEnabled,
              !model.settings.speculativeDecodingActive
        else {
            return .max
        }

        switch model.settings.thinkingBudget {
        case ...512:
            return .low
        case ...2_048:
            return .medium
        default:
            return .high
        }
    }

    private var localModelStatusLabel: String {
        if localLibrary.isScanning {
            return "Scanning for models…"
        }
        return localLibrary.error ?? "No installed language models"
    }

    private var reasoningPickerSection: ComposerModelPickerSecondarySection? {
        guard selectedModelSupportsThinking else {
            return nil
        }
        return ComposerModelPickerSecondarySection(
            title: "Reasoning",
            selectedID: reasoningLevel.rawValue,
            selectedLabel: reasoningLevel.rawValue,
            options: availableReasoningLevels.map {
                ComposerModelPickerSecondaryOption(
                    id: $0.rawValue,
                    title: $0.rawValue,
                    detail: $0.detail
                )
            },
            onSelect: { rawValue in
                guard let level = ChatReasoningLevel(rawValue: rawValue) else {
                    return
                }
                applyReasoningLevel(level)
            }
        )
    }

    private var modelPickerHelp: String {
        if viewModel.hasPendingRequests {
            return "Model switching is unavailable while requests are active or queued"
        }
        if model.isModelLoading {
            return model.modelLoadingStatusText ?? "Loading \(selectedModelLabel)"
        }
        return "Change model"
    }

    private func modelMenuLabel(_ modelID: String) -> String {
        let shortName = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return NativFormatting.truncateModelName(shortName, maxLength: 28)
    }

    private func select(_ localModel: LocalModel) {
        model.requestPreloadedModelSwitch(
            to: localModel,
            for: .language,
            availableModels: localLibrary.models
        ) {}
    }

    /// Picking a drafter from the model menu enables speculative decoding on its
    /// compatible chat model instead of loading the drafter as the main model.
    private func selectDrafter(_ drafter: LocalModel) {
        let currentID = model.settings.normalized().languageModelID
        guard let target = DrafterTargetResolver.compatibleTarget(
            for: drafter,
            currentModelID: currentID,
            models: localLibrary.models
        ) else { return }

        var next = model.settings
        if let currentID, !currentID.isEmpty, currentID != target.repoID {
            next.rememberProfile(forModel: currentID)
        }
        if currentID != target.repoID, let existing = next.modelProfile(for: target.repoID) {
            next.applyProfile(existing)
        }
        next.speculativeDecodingEnabled = true
        next.draftModelID = drafter.repoID
        next.draftKind = "auto"
        next.rememberProfile(forModel: target.repoID)

        if target.repoID == currentID {
            model.settings = next.normalized()
            model.restartServer()
            return
        }

        model.requestPreloadedModelSwitch(
            to: target,
            for: .language,
            availableModels: localLibrary.models
        ) {
            isApplyingDrafterSelection = true
            var switched = next
            switched.setModelID(target.repoID, for: .language)
            model.settings = switched.normalized()
        }
    }

    private var availableReasoningLevels: [ChatReasoningLevel] {
        guard model.settings.speculativeDecodingActive else {
            return ChatReasoningLevel.allCases
        }
        return ChatReasoningLevel.allCases.filter { $0.tokenBudget == nil }
    }

    private func applyReasoningLevel(_ level: ChatReasoningLevel) {
        switch level {
        case .off:
            model.settings.thinkingEnabled = false
        case .max:
            model.settings.thinkingEnabled = true
            model.settings.thinkingBudgetEnabled = false
        case .low, .medium, .high:
            model.settings.thinkingEnabled = true
            if model.settings.speculativeDecodingActive {
                model.settings.thinkingBudgetEnabled = false
            } else {
                model.settings.thinkingBudgetEnabled = true
                model.settings.thinkingBudget = level.tokenBudget ?? model.settings.thinkingBudget
            }
        }
    }

    private func disableThinkingIfUnsupported(modelID: String?, models: [LocalModel]) {
        guard model.settings.thinkingEnabled,
              let modelID,
              let localModel = models.first(where: { $0.repoID == modelID }),
              !localModel.capabilities.contains(.reasoning)
        else {
            return
        }
        model.settings.thinkingEnabled = false
    }

    private func applyInitialReasoningDefaultIfNeeded(
        modelID: String?,
        models: [LocalModel]
    ) {
        guard !didApplyInitialReasoningDefault,
              let modelID,
              models.contains(where: { $0.repoID == modelID })
        else {
            return
        }

        didApplyInitialReasoningDefault = true
        if let profile = model.settings.modelProfile(for: modelID) {
            model.settings.applyProfile(profile)
            disableThinkingIfUnsupported(modelID: modelID, models: models)
        } else {
            model.settings.rememberProfile(forModel: modelID)
        }
    }

    private func applyModelConfigOnSwitch(
        from oldModelID: String?,
        to newModelID: String?,
        models: [LocalModel]
    ) {
        if let oldModelID, !oldModelID.isEmpty {
            model.settings.rememberProfile(forModel: oldModelID)
        }
        guard let newModelID, !newModelID.isEmpty else {
            return
        }
        applyModelConfig(to: newModelID, models: models)
    }

    private func applyModelConfig(to modelID: String, models: [LocalModel]) {
        if let profile = model.settings.modelProfile(for: modelID) {
            model.settings.applyProfile(profile)
            disableThinkingIfUnsupported(modelID: modelID, models: models)
            return
        }
        let isReasoning = models.first(where: { $0.repoID == modelID })?
            .capabilities.contains(.reasoning) == true
        if isReasoning {
            applyReasoningLevel(.max)
        } else {
            model.settings.thinkingEnabled = false
        }
        model.settings.speculativeDecodingEnabled = false
        model.settings.rememberProfile(forModel: modelID)
    }

    private func provider(for modelID: String) -> LocalModelProvider? {
        LocalModelProviderResolver.resolve(
            repoID: modelID,
            modelType: nil,
            architectures: []
        )
    }

    private var actionButtonColor: Color {
        if showsStopButton || effectiveCanSend {
            return .accentColor
        }
        return Color(nsColor: .tertiaryLabelColor)
    }

    private var cancelPromptEditingAction: (() -> Void)? {
        guard viewModel.promptEditContext != nil else {
            return nil
        }
        return viewModel.cancelPromptEditing
    }

    private var actionButtonHelp: String {
        if showsStopButton {
            return "Stop response"
        }
        if let blockingNotice = attachmentNotices.first(where: {
            $0.severity == .error || $0.severity == .progress
        }) {
            return blockingNotice.message
        }
        if viewModel.promptEditContext != nil {
            return "Fork and regenerate (Return)"
        }
        return "Send (Return)"
    }

    private var showsStopButton: Bool {
        viewModel.isCurrentSessionSending && !canSend
    }

    private func workingStatus(elapsed: TimeInterval) -> String {
        "Working for \(NativFormatting.elapsedDuration(elapsed))..."
    }

    private func send() {
        guard effectiveCanSend else { return }
        onSend(
            selectedLocalModel?.capabilities.contains(.tools) == true,
            !modelLacksVision
        )
    }

    private func dismissAttachmentNotice(_ noticeID: String) {
        guard noticeID == "attachment-import-error" else {
            return
        }
        viewModel.clearAttachmentImportError()
    }

    private var editorHeight: CGFloat {
        min(max(editorContentHeight, editorMinimumHeight), editorMaximumHeight)
    }
}

private struct ChatPromptEditBanner: View {
    let onCancel: () -> Void
    @State private var isCancelHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "pencil")
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Editing prompt")
                    .fontWeight(.medium)
                Text("Sending will create a new conversation branch.")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button(action: onCancel) {
                Text("Cancel")
                    .fontWeight(.medium)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        isCancelHovered ? Color.accentColor.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .keyboardShortcut(.cancelAction)
            .onHover { isCancelHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isCancelHovered)
            .help("Cancel editing")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 0.5)
        }
    }
}

struct ComposerModelPickerSecondaryOption: Identifiable {
    let id: String
    let title: String
    let detail: String
}

struct ComposerModelPickerSecondarySection {
    let title: String
    let selectedID: String
    let selectedLabel: String
    let options: [ComposerModelPickerSecondaryOption]
    let onSelect: (String) -> Void
}

struct ComposerModelPicker: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPickerHovered = false
    @State private var isMenuOpen = false

    let models: [LocalModel]
    let selectedModelID: String?
    let selectedModelLabel: String
    let selectedModelProvider: LocalModelProvider?
    let selectedModelDetail: String?
    let secondarySection: ComposerModelPickerSecondarySection?
    let isModelLoading: Bool
    let modelLoadingPercentage: Int?
    let isDisabled: Bool
    let statusLabel: String
    let helpText: String
    let accessibilityValue: String
    let shortcutLabel: String?
    let emptyStateActionTitle: String?
    let onEmptyStateAction: (() -> Void)?
    let onSelectModel: (LocalModel) -> Void
    let onSwitchModel: (String) -> Void
    let drafters: [LocalModel]
    let selectedDrafterID: String?
    let onSelectDrafter: (LocalModel) -> Void

    var body: some View {
        ZStack {
            pickerLabel
                .opacity(0)

            ComposerModelPickerMenuControl(
                models: models,
                selectedModelID: selectedModelID,
                selectedModelLabel: selectedModelLabel,
                selectedModelProvider: selectedModelProvider,
                secondarySection: secondarySection,
                isEnabled: !isDisabled,
                usesSelectModelShortcut: shortcutLabel != nil,
                statusLabel: statusLabel,
                emptyStateActionTitle: emptyStateActionTitle,
                onEmptyStateAction: onEmptyStateAction,
                onSelectModel: onSelectModel,
                onSwitchModel: onSwitchModel,
                drafters: drafters,
                selectedDrafterID: selectedDrafterID,
                onSelectDrafter: onSelectDrafter,
                onTrackingChanged: { isTracking in
                    isMenuOpen = isTracking
                    if !isTracking {
                        isPickerHovered = false
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // The native control owns interaction while this stable SwiftUI copy
            // preserves the provider logo and exact composer styling.
            pickerLabel
                .background {
                    Capsule()
                        .fill(isPickerActive ? pickerHighlightColor : pickerRestingColor)
                }
                .allowsHitTesting(false)
        }
        .fixedSize()
        .frame(height: 32)
        .overlay(alignment: .top) {
            if isPickerHovered && !isMenuOpen {
                ComposerModelPickerTooltip(
                    title: pickerTooltip,
                    shortcutLabel: isDisabled ? nil : shortcutLabel
                )
                    .offset(y: -50)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Capsule())
        .disabled(isDisabled)
        .onHover { hovering in
            guard !isMenuOpen else { return }
            isPickerHovered = hovering
        }
        .animation(.easeOut(duration: 0.1), value: isPickerActive)
        .accessibilityLabel("Model")
        .accessibilityValue(accessibilityValue)
    }

    private var pickerLabel: some View {
        ComposerModelPickerLabel(
            selectedModelLabel: selectedModelLabel,
            selectedModelProvider: selectedModelProvider,
            selectedModelDetail: selectedModelDetail,
            isModelLoading: isModelLoading,
            modelLoadingPercentage: modelLoadingPercentage
        )
    }

    private var pickerTooltip: String {
        isDisabled ? helpText : "Select model"
    }

    private var isPickerActive: Bool {
        isPickerHovered || isMenuOpen
    }

    private var pickerHighlightColor: Color {
        colorScheme == .light
            ? Color.black.opacity(0.08)
            : Color.white.opacity(0.14)
    }

    private var pickerRestingColor: Color {
        Color(nsColor: .textBackgroundColor)
    }

}

private struct ComposerModelPickerMenuControl: NSViewRepresentable {
    let models: [LocalModel]
    let selectedModelID: String?
    let selectedModelLabel: String
    let selectedModelProvider: LocalModelProvider?
    let secondarySection: ComposerModelPickerSecondarySection?
    let isEnabled: Bool
    let usesSelectModelShortcut: Bool
    let statusLabel: String
    let emptyStateActionTitle: String?
    let onEmptyStateAction: (() -> Void)?
    let onSelectModel: (LocalModel) -> Void
    let onSwitchModel: (String) -> Void
    let drafters: [LocalModel]
    let selectedDrafterID: String?
    let onSelectDrafter: (LocalModel) -> Void
    let onTrackingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.title = ""
        button.image = nil
        button.focusRingType = .none
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        configureShortcut(for: button)
        button.setAccessibilityLabel("Model")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = isEnabled
        configureShortcut(for: button)
        context.coordinator.updateActionAvailability(isEnabled)
    }

    private func configureShortcut(for button: NSButton) {
        button.keyEquivalent = usesSelectModelShortcut ? "m" : ""
        button.keyEquivalentModifierMask = usesSelectModelShortcut
            ? [.control, .shift]
            : []
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ComposerModelPickerMenuControl

        private static let menuFont = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        private weak var modelSummaryItem: NSMenuItem?
        private weak var secondarySummaryItem: NSMenuItem?
        private var modelOptionViews = [PersistentMenuActionView]()
        private var drafterOptionViews = [PersistentMenuActionView]()
        private var secondaryOptionViews = [PersistentMenuActionView]()

        init(parent: ComposerModelPickerMenuControl) {
            self.parent = parent
        }

        @objc func showMenu(_ sender: NSButton) {
            // Build the entire tree before tracking begins. Keeping both submenus
            // alive for the whole session prevents hover-driven view replacement.
            modelOptionViews.removeAll()
            drafterOptionViews.removeAll()
            secondaryOptionViews.removeAll()
            let menu = makeMenu()
            parent.onTrackingChanged(true)
            defer { parent.onTrackingChanged(false) }
            menu.update()
            menu.popUp(
                positioning: nil,
                at: NSPoint(
                    x: -8,
                    y: sender.isFlipped
                        ? sender.bounds.minY - menu.size.height - 4
                        : sender.bounds.maxY + menu.size.height + 4
                ),
                in: sender
            )
        }

        private func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            let modelItem = NSMenuItem(
                title: "Model   \(parent.selectedModelLabel)",
                action: nil,
                keyEquivalent: ""
            )
            modelItem.submenu = makeModelMenu()
            menu.addItem(modelItem)
            modelSummaryItem = modelItem

            if let secondarySection = parent.secondarySection {
                let secondaryItem = NSMenuItem(
                    title: "\(secondarySection.title)   \(secondarySection.selectedLabel)",
                    action: nil,
                    keyEquivalent: ""
                )
                secondaryItem.submenu = makeSecondaryMenu(secondarySection)
                menu.addItem(secondaryItem)
                secondarySummaryItem = secondaryItem
            }

            return menu
        }

        private func makeModelMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            if let selectedModelID = parent.selectedModelID,
               !parent.models.contains(where: { $0.repoID == selectedModelID }) {
                let item = modelItem(
                    title: modelMenuLabel(selectedModelID),
                    repoID: selectedModelID,
                    provider: parent.selectedModelProvider,
                    isSelected: true
                )
                menu.addItem(item)

                if !parent.models.isEmpty {
                    menu.addItem(.separator())
                }
            }

            for model in parent.models {
                let item = modelItem(
                    title: modelMenuLabel(model.repoID),
                    repoID: model.repoID,
                    provider: model.provider,
                    isSelected: model.repoID == parent.selectedModelID
                )
                menu.addItem(item)
            }

            if !parent.drafters.isEmpty {
                menu.addItem(.separator())
                let header = NSMenuItem(
                    title: "Drafters — speculative decoding",
                    action: nil,
                    keyEquivalent: ""
                )
                header.isEnabled = false
                menu.addItem(header)

                for drafter in parent.drafters {
                    var title = modelMenuLabel(drafter.repoID)
                    if let kindLabel = drafter.drafterKindLabel {
                        title += " (\(kindLabel))"
                    }
                    let target = DrafterTargetResolver.compatibleTarget(
                        for: drafter,
                        currentModelID: parent.selectedModelID,
                        models: parent.models
                    )
                    if target == nil {
                        title += " — needs a compatible chat model"
                    }
                    let item = persistentMenuItem(
                        title: NSAttributedString(
                            string: title,
                            attributes: [.font: Self.menuFont]
                        ),
                        optionID: drafter.repoID,
                        image: nil,
                        isSelected: drafter.repoID == parent.selectedDrafterID
                    ) { [weak self] in
                        self?.selectModel(drafter.repoID)
                    }
                    if let itemView = item.view as? PersistentMenuActionView {
                        drafterOptionViews.append(itemView)
                    }
                    menu.addItem(item)
                }
            }

            if parent.models.isEmpty && parent.selectedModelID == nil {
                let item = NSMenuItem(title: parent.statusLabel, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)

                if let actionTitle = parent.emptyStateActionTitle,
                   parent.onEmptyStateAction != nil {
                    menu.addItem(.separator())
                    let actionItem = NSMenuItem(
                        title: actionTitle,
                        action: #selector(performEmptyStateAction),
                        keyEquivalent: ""
                    )
                    actionItem.target = self
                    actionItem.isEnabled = true
                    menu.addItem(actionItem)
                }
            }

            return menu
        }

        @objc private func performEmptyStateAction() {
            parent.onEmptyStateAction?()
        }

        private func makeSecondaryMenu(
            _ section: ComposerModelPickerSecondarySection
        ) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            for option in section.options {
                let title = secondaryOptionTitle(
                    option,
                    options: section.options
                )
                let item = persistentMenuItem(
                    title: title,
                    optionID: option.id,
                    image: nil,
                    isSelected: option.id == section.selectedID
                ) { [weak self] in
                    self?.selectSecondaryOption(option.id)
                }
                if let itemView = item.view as? PersistentMenuActionView {
                    secondaryOptionViews.append(itemView)
                }
                menu.addItem(item)
            }

            return menu
        }

        private func modelItem(
            title: String,
            repoID: String,
            provider: LocalModelProvider?,
            isSelected: Bool
        ) -> NSMenuItem {
            let item = persistentMenuItem(
                title: NSAttributedString(
                    string: title,
                    attributes: [.font: Self.menuFont]
                ),
                optionID: repoID,
                image: providerImage(provider),
                isSelected: isSelected
            ) { [weak self] in
                self?.selectModel(repoID)
            }
            if let itemView = item.view as? PersistentMenuActionView {
                modelOptionViews.append(itemView)
            }
            return item
        }

        private func persistentMenuItem(
            title: NSAttributedString,
            optionID: String,
            image: NSImage?,
            isSelected: Bool,
            onSelect: @escaping () -> Void
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title.string, action: nil, keyEquivalent: "")
            item.isEnabled = true
            item.view = PersistentMenuActionView(
                optionID: optionID,
                title: title,
                image: image,
                isSelected: isSelected,
                onSelect: onSelect
            )
            return item
        }

        private func selectModel(_ repoID: String) {
            if let drafter = parent.drafters.first(where: { $0.repoID == repoID }) {
                drafterOptionViews.forEach { $0.isSelected = $0.optionID == repoID }
                parent.onSelectDrafter(drafter)
                return
            }

            modelOptionViews.forEach { $0.isSelected = $0.optionID == repoID }
            modelSummaryItem?.title = "Model   \(modelMenuLabel(repoID))"

            if let model = parent.models.first(where: { $0.repoID == repoID }) {
                parent.onSelectModel(model)
            } else {
                parent.onSwitchModel(repoID)
            }
        }

        private func selectSecondaryOption(_ optionID: String) {
            guard let section = parent.secondarySection,
                  let option = section.options.first(where: { $0.id == optionID })
            else { return }

            secondaryOptionViews.forEach { $0.isSelected = $0.optionID == optionID }
            secondarySummaryItem?.title = "\(section.title)   \(option.title)"
            section.onSelect(optionID)
        }

        func updateActionAvailability(_ isEnabled: Bool) {
            modelOptionViews.forEach { $0.isActionEnabled = isEnabled }
            secondaryOptionViews.forEach { $0.isActionEnabled = isEnabled }
        }

        private func modelMenuLabel(_ modelID: String) -> String {
            let shortName = modelID.split(separator: "/").last.map(String.init) ?? modelID
            return NativFormatting.truncateModelName(shortName, maxLength: 28)
        }

        private func providerImage(_ provider: LocalModelProvider?) -> NSImage? {
            guard let provider,
                  let source = LocalModelProviderIcon.image(for: provider),
                  let image = source.copy() as? NSImage
            else { return nil }
            image.size = NSSize(width: 16, height: 16)
            return image
        }

        private func secondaryOptionTitle(
            _ option: ComposerModelPickerSecondaryOption,
            options: [ComposerModelPickerSecondaryOption]
        ) -> NSAttributedString {
            let title = NSMutableAttributedString(
                string: option.title,
                attributes: [.font: Self.menuFont]
            )
            guard !option.detail.isEmpty else { return title }

            let labelPadding = padding(
                from: Self.textWidth(option.title),
                to: options.map { Self.textWidth($0.title) }.max() ?? 0
            ) + String(repeating: "\u{2007}", count: 3)
            let detailPadding = padding(
                from: Self.textWidth(option.detail),
                to: options.map { Self.textWidth($0.detail) }.max() ?? 0
            )
            title.append(
                NSAttributedString(
                    string: labelPadding + detailPadding + option.detail,
                    attributes: [
                        .font: Self.menuFont,
                        .foregroundColor: NSColor.tertiaryLabelColor
                    ]
                )
            )
            return title
        }

        private static func textWidth(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: menuFont]).width
        }

        private func padding(from currentWidth: CGFloat, to targetWidth: CGFloat) -> String {
            var remainingWidth = max(0, targetWidth - currentWidth)
            let figureSpaceWidth = max(1, Self.textWidth("\u{2007}"))
            let hairSpaceWidth = max(1, Self.textWidth("\u{200A}"))
            let figureSpaces = Int(remainingWidth / figureSpaceWidth)
            remainingWidth -= CGFloat(figureSpaces) * figureSpaceWidth
            let hairSpaces = Int((remainingWidth / hairSpaceWidth).rounded())
            return String(repeating: "\u{2007}", count: figureSpaces)
                + String(repeating: "\u{200A}", count: hairSpaces)
        }
    }
}

private struct ComposerModelPickerLabel: View {
    let selectedModelLabel: String
    let selectedModelProvider: LocalModelProvider?
    let selectedModelDetail: String?
    let isModelLoading: Bool
    let modelLoadingPercentage: Int?

    var body: some View {
        HStack(spacing: 5) {
            Label {
                HStack(spacing: 4) {
                    pickerTitle
                        .lineLimit(1)
                    if isModelLoading, let modelLoadingPercentage {
                        Text("· \(modelLoadingPercentage)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } icon: {
                Group {
                    if isModelLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        ChatComposerModelIcon(provider: selectedModelProvider)
                    }
                }
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.primary)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 32)
    }

    private var pickerTitle: Text {
        let modelName = Text(selectedModelLabel)
        guard let selectedModelDetail else {
            return modelName
        }
        return Text("\(modelName)  \(selectedModelDetail)").foregroundColor(.secondary)
    }

}

private struct ComposerModelPickerTooltip: View {
    let title: String
    let shortcutLabel: String?

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.primary)

            if let shortcutLabel {
                Text(shortcutLabel)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.12), in: Capsule())
            }
        }
        .font(.callout)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        .fixedSize()
    }
}

private struct ChatComposerModelIcon: View {
    let provider: LocalModelProvider?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if provider?.needsLightIconBackgroundInDarkMode == true,
               colorScheme == .dark {
                Circle()
                    .fill(Color.white.opacity(0.94))
                    .frame(width: 18, height: 18)
            }

            if let provider, let image = LocalModelProviderIcon.image(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color(nsColor: provider.iconTintColor))
                    .frame(width: 15, height: 15)
            } else if let provider {
                Text(provider.monogram)
                    .font(.system(size: provider.monogram.count > 2 ? 7 : 9, weight: .bold))
                    .foregroundStyle(Color(nsColor: provider.iconTintColor))
            } else {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

struct ChatComposerActionMenu: NSViewRepresentable {
    let isEnabled: Bool
    let canPasteImage: Bool
    var uploadMenuTitle = "Upload Image…"
    var uploadMenuSystemImage = "photo.badge.plus"
    let onAttachImages: () -> Void
    let onPasteImage: () -> Void
    let onCaptureScreenshot: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "More message options"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        )
        button.setAccessibilityLabel("More message options")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = isEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ChatComposerActionMenu

        init(parent: ChatComposerActionMenu) {
            self.parent = parent
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = makeMenu()
            if let event = NSApp.currentEvent {
                NSMenu.popUpContextMenu(menu, with: event, for: sender)
            } else {
                menu.popUp(
                    positioning: nil,
                    at: NSPoint(x: -8, y: sender.bounds.maxY + 4),
                    in: sender
                )
            }
        }

        private func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.minimumWidth = 190

            let fileItem = NSMenuItem(
                title: parent.uploadMenuTitle,
                action: #selector(attachImages(_:)),
                keyEquivalent: ""
            )
            fileItem.target = self
            fileItem.image = menuImage(
                parent.uploadMenuSystemImage,
                description: parent.uploadMenuTitle
            )
            fileItem.isEnabled = true
            menu.addItem(fileItem)

            let pasteItem = NSMenuItem(
                title: "Paste Image",
                action: #selector(pasteImage(_:)),
                keyEquivalent: ""
            )
            pasteItem.target = self
            pasteItem.image = menuImage("doc.on.clipboard", description: "Paste Image")
            pasteItem.isEnabled = parent.canPasteImage
            menu.addItem(pasteItem)

            let screenshotItem = NSMenuItem(
                title: "Take Screenshot",
                action: #selector(captureScreenshot(_:)),
                keyEquivalent: ""
            )
            screenshotItem.target = self
            screenshotItem.image = menuImage("camera.viewfinder", description: "Take Screenshot")
            screenshotItem.isEnabled = true
            menu.addItem(screenshotItem)

            return menu
        }

        @objc private func attachImages(_ sender: NSMenuItem) {
            parent.onAttachImages()
        }

        @objc private func pasteImage(_ sender: NSMenuItem) {
            parent.onPasteImage()
        }

        @objc private func captureScreenshot(_ sender: NSMenuItem) {
            parent.onCaptureScreenshot()
        }

        private func menuImage(_ systemName: String, description: String) -> NSImage? {
            NSImage(
                systemSymbolName: systemName,
                accessibilityDescription: description
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            )
        }

    }
}

struct ChatComposerAddButton: View {
    let isEnabled: Bool
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .regular))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("More message options")
    }
}

struct ChatComposerActionPanel: View {
    let canPasteImage: Bool
    var showsGlobalTools = false
    var isWebSearchEnabled = false
    var isWebSearchAvailable = false
    var webSearchProviderLabel: String?
    var isWebReadEnabled = false
    var isWebReadAvailable = false
    var webReadProviderLabel: String?
    let onAttachImages: () -> Void
    let onPasteImage: () -> Void
    let onCaptureScreenshot: () -> Void
    var onToggleWebSearch: () -> Void = {}
    var onToggleWebRead: () -> Void = {}
    var onOpenKits: (() -> Void)? = nil
    var onOpenCapabilities: (() -> Void)? = nil

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                section("Add") {
                    ChatComposerActionRow(
                        title: "Upload file",
                        detail: "Choose an image or PDF from your Mac",
                        systemName: "doc.badge.plus",
                        action: onAttachImages
                    )

                    if canPasteImage {
                        ChatComposerActionRow(
                            title: "Paste image",
                            detail: "Use an image from your clipboard",
                            systemName: "doc.on.clipboard",
                            action: onPasteImage
                        )
                    }

                    ChatComposerActionRow(
                        title: "Take a screenshot",
                        detail: "Capture part of your screen",
                        systemName: "camera.viewfinder",
                        action: onCaptureScreenshot
                    )
                }

                if showsGlobalTools {
                    section("Tools") {
                        ChatComposerActionRow(
                            title: "Web Search",
                            detail: capabilityDetail(
                                provider: webSearchProviderLabel,
                                isAvailable: isWebSearchAvailable
                            ),
                            systemName: "globe",
                            isSelected: isWebSearchEnabled,
                            showsDisclosure: !isWebSearchAvailable,
                            action: onToggleWebSearch
                        )

                        ChatComposerActionRow(
                            title: "Web Read",
                            detail: capabilityDetail(
                                provider: webReadProviderLabel,
                                isAvailable: isWebReadAvailable
                            ),
                            systemName: "doc.text.magnifyingglass",
                            isSelected: isWebReadEnabled,
                            showsDisclosure: !isWebReadAvailable,
                            action: onToggleWebRead
                        )
                    }
                }

                if onOpenKits != nil || onOpenCapabilities != nil {
                    section("Capabilities") {
                        if let onOpenKits {
                            ChatComposerActionRow(
                                title: "Kits",
                                detail: "Enable a bundled set of capabilities",
                                systemName: "shippingbox",
                                showsDisclosure: true,
                                action: onOpenKits
                            )
                        }

                        if let onOpenCapabilities {
                            ChatComposerActionRow(
                                title: "Directory",
                                detail: "Manage tools, skills, and connections",
                                systemName: "square.grid.2x2",
                                showsDisclosure: true,
                                action: onOpenCapabilities
                            )
                        }
                    }
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 500)
    }

    private func capabilityDetail(provider: String?, isAvailable: Bool) -> String {
        isAvailable ? (provider ?? "Ready") : "Needs setup"
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            VStack(spacing: 1) {
                content()
            }
        }
    }
}

private struct ChatComposerActionRow: View {
    let title: String
    let detail: String
    let systemName: String
    var isSelected = false
    var showsDisclosure = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)

                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.green)
                        .frame(width: 18, height: 18)
                } else if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                }
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowBackground)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isSelected ? "Enabled globally" : "")
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.green.opacity(isHovering ? 0.16 : 0.10)
        }
        return isHovering ? Color.primary.opacity(0.07) : .clear
    }
}

private struct ChatQueueTray: View {
    let prompts: [ChatQueuedPrompt]
    let onSteer: (UUID) -> Void
    let onPrioritize: (UUID) -> Void
    let onRemove: (UUID) -> Void

    var body: some View {
        Group {
            if prompts.count <= 3 {
                rows
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    rows
                }
                .frame(maxHeight: 168)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.035), radius: 5, y: 2)
        .animation(.snappy(duration: 0.2), value: prompts)
    }

    private var rows: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(prompts.enumerated()), id: \.element.id) { index, prompt in
                if index > 0 {
                    Divider()
                        .padding(.leading, 46)
                }

                ChatQueuedPromptRow(
                    prompt: prompt,
                    onSteer: { onSteer(prompt.id) },
                    onPrioritize: { onPrioritize(prompt.id) },
                    onRemove: { onRemove(prompt.id) }
                )
            }
        }
    }
}

private struct ChatQueuedPromptRow: View {
    let prompt: ChatQueuedPrompt
    let onSteer: () -> Void
    let onPrioritize: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.indent")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayContent)
                    .font(.body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if prompt.attachmentCount > 0 {
                    Label(attachmentLabel, systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onSteer) {
                Label("Steer", systemImage: "arrow.turn.down.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Stop the current response and run this message next")

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove from queue")

            Menu {
                Button(action: onPrioritize) {
                    Label("Move to Front", systemImage: "arrow.up.to.line")
                }
                .disabled(prompt.position == 1)

                Divider()

                Button(role: .destructive, action: onRemove) {
                    Label("Remove from Queue", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Queue options")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }

    private var displayContent: String {
        prompt.content.isEmpty ? attachmentLabel : prompt.content
    }

    private var attachmentLabel: String {
        prompt.attachmentCount == 1
            ? "1 attachment"
            : "\(prompt.attachmentCount) attachments"
    }
}

struct ChatComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let onSubmit: () -> Void
    var onCancel: (() -> Void)?
    let onPasteImage: (NSPasteboard) -> Bool
    let onContentHeightChange: (CGFloat) -> Void
    var fontScale: Double = 1.0
    var focusToken: Int = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onCancel: onCancel,
            onPasteImage: onPasteImage,
            onContentHeightChange: onContentHeightChange,
            focusToken: focusToken
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ChatComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = context.coordinator.handleSubmit
        textView.onCancel = context.coordinator.handleCancel
        textView.onPasteImage = context.coordinator.handlePasteImage
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.font = ChatFontMetrics.bodyNSFont(scale: fontScale)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        let scrollView = ChatComposerNSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.onLayout = context.coordinator.reportContentHeight

        context.coordinator.textView = textView
        context.coordinator.reportContentHeight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
        context.coordinator.onPasteImage = onPasteImage
        context.coordinator.onContentHeightChange = onContentHeightChange

        guard let textView = context.coordinator.textView else {
            return
        }

        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.font = ChatFontMetrics.bodyNSFont(scale: fontScale)

        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
        }
        context.coordinator.reportContentHeight()
        context.coordinator.requestFocus(ifNeeded: focusToken)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        var onSubmit: () -> Void
        var onCancel: (() -> Void)?
        var onPasteImage: (NSPasteboard) -> Bool
        var onContentHeightChange: (CGFloat) -> Void
        weak var textView: NSTextView?
        private var lastReportedHeight: CGFloat?
        private var lastFocusToken: Int

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: (() -> Void)?,
            onPasteImage: @escaping (NSPasteboard) -> Bool,
            onContentHeightChange: @escaping (CGFloat) -> Void,
            focusToken: Int
        ) {
            _text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            self.onPasteImage = onPasteImage
            self.onContentHeightChange = onContentHeightChange
            lastFocusToken = focusToken
        }

        func handlePasteImage(_ pasteboard: NSPasteboard) -> Bool {
            onPasteImage(pasteboard)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else {
                return
            }

            guard !textView.hasMarkedText() else {
                reportContentHeight()
                return
            }

            text = textView.string
            reportContentHeight()
        }

        func handleSubmit() {
            onSubmit()
        }

        func handleCancel() {
            onCancel?()
        }

        func requestFocus(ifNeeded focusToken: Int) {
            guard focusToken != lastFocusToken, let textView else {
                return
            }
            lastFocusToken = focusToken
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
                let end = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
                textView.scrollRangeToVisible(NSRange(location: end, length: 0))
            }
        }

        func reportContentHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  textContainer.containerSize.width > 0
            else {
                return
            }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let measuredHeight = ceil(usedRect.maxY + (textView.textContainerInset.height * 2))

            guard lastReportedHeight.map({ abs($0 - measuredHeight) >= 0.5 }) ?? true else {
                return
            }

            lastReportedHeight = measuredHeight
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastReportedHeight == measuredHeight else {
                    return
                }
                self.onContentHeightChange(measuredHeight)
            }
        }
    }
}

private final class ChatComposerNSScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private final class ChatComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPasteImage: ((NSPasteboard) -> Bool)?

    override func keyDown(with event: NSEvent) {
        // Return confirms a marked composition in input methods such as Japanese
        // and Chinese. Let NSTextView route those events through the input method
        // before applying the composer send/newline behavior.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53, onCancel != nil {
            onCancel?()
            return
        }

        switch ComposerReturnBehavior.resolve(for: event) {
        case .submit:
            onSubmit?()
        case .insertNewline:
            insertText("\n", replacementRange: selectedRange())
        case .passthrough:
            super.keyDown(with: event)
        }
    }

    override func paste(_ sender: Any?) {
        if onPasteImage?(NSPasteboard.general) == true {
            return
        }
        super.paste(sender)
    }
}

private enum ComposerReturnBehavior {
    case submit
    case insertNewline
    case passthrough

    static func resolve(for event: NSEvent) -> ComposerReturnBehavior {
        guard isReturnKey(event) else {
            return .passthrough
        }

        let modifiers = relevantModifiers(for: event)
        if modifiers == [.command] {
            return .insertNewline
        }
        if modifiers.isEmpty {
            return .submit
        }
        return .passthrough
    }

    private static func isReturnKey(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }

    private static func relevantModifiers(for event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection([.command, .control, .option, .shift])
    }
}

struct ChatPendingImageAttachmentView: View {
    let attachment: ChatImageAttachment
    var validation: ChatAttachmentValidation? = nil
    var modelRejectsImage = false
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ChatImageThumbnail(
                attachment: attachment,
                isUserMessage: false,
                width: 42,
                height: 32
            )

            Text(attachment.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)

            statusIndicator

            Button("Remove attachment", systemImage: "xmark", action: onRemove)
                .labelStyle(.iconOnly)
                .font(.caption.weight(.semibold))
                .frame(width: 14, height: 14)
                .buttonStyle(.plain)
                .help("Remove \(attachment.filename)")
        }
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(attachmentBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(attachmentBorder, lineWidth: hasIssue ? 0.75 : 0.5)
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if modelRejectsImage {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
                .help("Requires a vision-capable model")
                .accessibilityLabel("Unsupported by the selected model")
        } else if let validation {
            switch validation {
            case .processing:
                ProgressView()
                    .controlSize(.small)
                    .help("Reading PDF")
                    .accessibilityLabel("Reading PDF")
            case .warning(let message, _):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(message)
                    .accessibilityLabel("Attachment warning")
            case .blocked(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                    .help(message)
                    .accessibilityLabel("Attachment cannot be used")
            case .ready:
                EmptyView()
            }
        }
    }

    private var hasIssue: Bool {
        if modelRejectsImage {
            return true
        }
        guard let validation else {
            return false
        }
        switch validation {
        case .warning, .blocked:
            return true
        case .processing, .ready:
            return false
        }
    }

    private var attachmentBackground: Color {
        hasIssue
            ? Color.orange.opacity(0.07)
            : Color(nsColor: .controlBackgroundColor)
    }

    private var attachmentBorder: Color {
        hasIssue
            ? Color.orange.opacity(0.30)
            : Color(nsColor: .separatorColor)
    }
}
