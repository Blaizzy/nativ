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
                    Image(systemName: "photo")
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

struct ChatComposer: View {
    @ObservedObject var model: NativModel
    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var localLibrary = LocalModelLibrary()
    let unavailableReason: String?
    let canCompose: Bool
    let canSend: Bool
    let onSend: () -> Void
    @State private var editorContentHeight: CGFloat = 0
    @State private var didApplyInitialReasoningDefault = false
    private let textInset = EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14)
    private let editorMinimumHeight: CGFloat = 64
    private let editorMaximumHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.isCurrentSessionSending, let sendingStartedAt = viewModel.sendingStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(sendingStartedAt)
                    Text(workingStatus(elapsed: elapsed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            } else if let unavailableReason {
                Text(unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                        onSubmit: onSend,
                        onContentHeightChange: { height in
                            editorContentHeight = height
                        }
                    )

                    if viewModel.draft.isEmpty {
                        Text("Message")
                            .font(.body)
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
                                ChatPendingImageAttachmentView(attachment: attachment) {
                                    viewModel.removePendingImageAttachment(attachment.id)
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }

                HStack(spacing: 8) {
                    ChatComposerActionMenu(
                        isEnabled: canCompose,
                        onAttachImages: viewModel.chooseImageAttachments
                    )
                    .frame(width: 30, height: 30)
                    .help("Add attachment")

                    Spacer(minLength: 12)

                    modelPicker

                    Button {
                        if showsStopButton {
                            viewModel.cancel()
                        } else {
                            onSend()
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
                    .disabled(!showsStopButton && !canSend)
                    .help(showsStopButton ? "Stop response" : "Send (Return)")
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
        }
        .padding(.vertical, 18)
        .task(id: modelScanKey) {
            localLibrary.scan(
                path: model.settings.modelSearchPath,
                additionalPaths: model.settings.normalized().additionalModelSearchPaths
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .localModelLibraryDidChange)) { _ in
            localLibrary.scan(
                path: model.settings.modelSearchPath,
                additionalPaths: model.settings.normalized().additionalModelSearchPaths
            )
        }
        .onChange(of: localLibrary.models) { _, models in
            disableThinkingIfUnsupported(modelID: selectedModelID, models: models)
            applyInitialReasoningDefaultIfNeeded(modelID: selectedModelID, models: models)
        }
        .onChange(of: selectedModelID) { _, modelID in
            configureReasoningForSelectedModel(modelID: modelID, models: localLibrary.models)
        }
        .onDisappear {
            localLibrary.cancel()
        }
    }

    private var modelScanKey: String {
        let settings = model.settings.normalized()
        return ([settings.expandedModelSearchPath] + settings.additionalModelSearchPaths)
            .joined(separator: "\u{0}")
    }

    private var modelPicker: some View {
        StableChatModelPicker(
            models: localLibrary.models,
            selectedModelID: selectedModelID,
            selectedModelLabel: selectedModelLabel,
            selectedModelProvider: selectedModelProvider,
            supportsReasoning: selectedModelSupportsThinking,
            reasoningLevel: reasoningLevel,
            modelSwitchInProgress: model.modelSwitchInProgress,
            isDisabled: model.modelSwitchInProgress || viewModel.hasPendingRequests,
            statusLabel: localModelStatusLabel,
            helpText: modelPickerHelp,
            accessibilityValue: modelPickerAccessibilityValue,
            onSelectModel: select,
            onSwitchModel: { model.switchLanguageModel(to: $0) },
            onSelectReasoning: applyReasoningLevel
        )
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
        selectedModelSupportsThinking
            ? "\(selectedModelLabel), reasoning \(reasoningLevel.rawValue)"
            : selectedModelLabel
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
        guard model.settings.thinkingBudgetEnabled else {
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
        return localLibrary.error ?? "No installed models"
    }

    private var modelPickerHelp: String {
        if viewModel.hasPendingRequests {
            return "Model switching is unavailable while requests are active or queued"
        }
        if model.modelSwitchInProgress {
            return "Restarting the server with \(selectedModelLabel)"
        }
        return "Change model"
    }

    private func modelMenuLabel(_ modelID: String) -> String {
        let shortName = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return NativFormatting.truncateModelName(shortName, maxLength: 28)
    }

    private func select(_ localModel: LocalModel) {
        if localModel.capabilities.contains(.reasoning) {
            applyReasoningLevel(.max)
        } else {
            model.settings.thinkingEnabled = false
        }
        model.switchLanguageModel(to: localModel.repoID)
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
            model.settings.thinkingBudgetEnabled = true
            model.settings.thinkingBudget = level.tokenBudget ?? model.settings.thinkingBudget
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
              let localModel = models.first(where: { $0.repoID == modelID })
        else {
            return
        }

        didApplyInitialReasoningDefault = true
        if localModel.capabilities.contains(.reasoning) {
            applyReasoningLevel(.max)
        }
    }

    private func configureReasoningForSelectedModel(
        modelID: String?,
        models: [LocalModel]
    ) {
        guard let modelID,
              let localModel = models.first(where: { $0.repoID == modelID })
        else {
            return
        }

        if localModel.capabilities.contains(.reasoning) {
            applyReasoningLevel(.max)
        } else {
            model.settings.thinkingEnabled = false
        }
    }

    private func provider(for modelID: String) -> LocalModelProvider? {
        LocalModelProviderResolver.resolve(
            repoID: modelID,
            modelType: nil,
            architectures: []
        )
    }

    private var actionButtonColor: Color {
        if showsStopButton || canSend {
            return .accentColor
        }
        return Color(nsColor: .tertiaryLabelColor)
    }

    private var showsStopButton: Bool {
        viewModel.isCurrentSessionSending && !canSend
    }

    private func workingStatus(elapsed: TimeInterval) -> String {
        "Working for \(NativFormatting.elapsedDuration(elapsed))..."
    }

    private var editorHeight: CGFloat {
        min(max(editorContentHeight, editorMinimumHeight), editorMaximumHeight)
    }
}

private struct StableChatModelPicker: View {
    @State private var isPickerHovered = false
    @State private var isMenuOpen = false

    let models: [LocalModel]
    let selectedModelID: String?
    let selectedModelLabel: String
    let selectedModelProvider: LocalModelProvider?
    let supportsReasoning: Bool
    let reasoningLevel: ChatReasoningLevel
    let modelSwitchInProgress: Bool
    let isDisabled: Bool
    let statusLabel: String
    let helpText: String
    let accessibilityValue: String
    let onSelectModel: (LocalModel) -> Void
    let onSwitchModel: (String) -> Void
    let onSelectReasoning: (ChatReasoningLevel) -> Void

    var body: some View {
        ZStack {
            pickerLabel
                .opacity(0)

            ChatModelPickerMenuControl(
                models: models,
                selectedModelID: selectedModelID,
                selectedModelLabel: selectedModelLabel,
                selectedModelProvider: selectedModelProvider,
                supportsReasoning: supportsReasoning,
                reasoningLevel: reasoningLevel,
                isEnabled: !isDisabled,
                statusLabel: statusLabel,
                onSelectModel: onSelectModel,
                onSwitchModel: onSwitchModel,
                onSelectReasoning: onSelectReasoning,
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
                ChatModelPickerTooltip(
                    title: pickerTooltip,
                    showsShortcut: !isDisabled
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
        ChatModelPickerLabel(
            selectedModelLabel: selectedModelLabel,
            selectedModelProvider: selectedModelProvider,
            supportsReasoning: supportsReasoning,
            reasoningLevel: reasoningLevel,
            modelSwitchInProgress: modelSwitchInProgress
        )
    }

    private var pickerTooltip: String {
        isDisabled ? helpText : "Select model"
    }

    private var isPickerActive: Bool {
        isPickerHovered || isMenuOpen
    }

    private var pickerHighlightColor: Color {
        let background = NSColor.controlBackgroundColor
        return Color(
            nsColor: background.blended(withFraction: 0.24, of: NSColor.labelColor)
                ?? background
        )
    }

    private var pickerRestingColor: Color {
        Color(nsColor: .textBackgroundColor)
    }

}

private struct ChatModelPickerMenuControl: NSViewRepresentable {
    let models: [LocalModel]
    let selectedModelID: String?
    let selectedModelLabel: String
    let selectedModelProvider: LocalModelProvider?
    let supportsReasoning: Bool
    let reasoningLevel: ChatReasoningLevel
    let isEnabled: Bool
    let statusLabel: String
    let onSelectModel: (LocalModel) -> Void
    let onSwitchModel: (String) -> Void
    let onSelectReasoning: (ChatReasoningLevel) -> Void
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
        button.setAccessibilityLabel("Model")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = isEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ChatModelPickerMenuControl

        private static let menuFont = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        private static let reasoningLabelColumnWidth = ChatReasoningLevel.allCases
            .map { textWidth($0.rawValue) }
            .max() ?? 0
        private static let reasoningDetailColumnWidth = ChatReasoningLevel.allCases
            .map { textWidth($0.detail) }
            .max() ?? 0

        init(parent: ChatModelPickerMenuControl) {
            self.parent = parent
        }

        @objc func showMenu(_ sender: NSButton) {
            // Build the entire tree before tracking begins. Keeping both submenus
            // alive for the whole session prevents hover-driven view replacement.
            let menu = makeMenu()
            parent.onTrackingChanged(true)
            defer { parent.onTrackingChanged(false) }
            menu.update()
            menu.popUp(
                positioning: nil,
                at: NSPoint(
                    x: -8,
                    y: sender.bounds.maxY + menu.size.height + 4
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

            if parent.supportsReasoning {
                let reasoningItem = NSMenuItem(
                    title: "Reasoning   \(parent.reasoningLevel.rawValue)",
                    action: nil,
                    keyEquivalent: ""
                )
                reasoningItem.submenu = makeReasoningMenu()
                menu.addItem(reasoningItem)
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
                    action: #selector(switchModel(_:))
                )
                item.state = .on
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
                    action: #selector(selectModel(_:))
                )
                item.state = model.repoID == parent.selectedModelID ? .on : .off
                menu.addItem(item)
            }

            if parent.models.isEmpty && parent.selectedModelID == nil {
                let item = NSMenuItem(title: parent.statusLabel, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }

            return menu
        }

        private func makeReasoningMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            for (index, level) in ChatReasoningLevel.allCases.enumerated() {
                let item = NSMenuItem(
                    title: level.rawValue,
                    action: #selector(selectReasoning(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = index
                item.state = level == parent.reasoningLevel ? .on : .off
                item.attributedTitle = reasoningTitle(level)
                menu.addItem(item)
            }

            return menu
        }

        private func modelItem(
            title: String,
            repoID: String,
            provider: LocalModelProvider?,
            action: Selector
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = repoID
            item.image = providerImage(provider)
            return item
        }

        @objc private func selectModel(_ sender: NSMenuItem) {
            guard let repoID = sender.representedObject as? String,
                  let model = parent.models.first(where: { $0.repoID == repoID })
            else { return }
            parent.onSelectModel(model)
        }

        @objc private func switchModel(_ sender: NSMenuItem) {
            guard let repoID = sender.representedObject as? String else { return }
            parent.onSwitchModel(repoID)
        }

        @objc private func selectReasoning(_ sender: NSMenuItem) {
            guard ChatReasoningLevel.allCases.indices.contains(sender.tag) else { return }
            parent.onSelectReasoning(ChatReasoningLevel.allCases[sender.tag])
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

        private func reasoningTitle(_ level: ChatReasoningLevel) -> NSAttributedString {
            let title = NSMutableAttributedString(
                string: level.rawValue,
                attributes: [.font: Self.menuFont]
            )
            guard !level.detail.isEmpty else { return title }

            let labelPadding = padding(
                from: Self.textWidth(level.rawValue),
                to: Self.reasoningLabelColumnWidth
            ) + String(repeating: "\u{2007}", count: 3)
            let detailPadding = padding(
                from: Self.textWidth(level.detail),
                to: Self.reasoningDetailColumnWidth
            )
            title.append(
                NSAttributedString(
                    string: labelPadding + detailPadding + level.detail,
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

private struct ChatModelPickerLabel: View {
    let selectedModelLabel: String
    let selectedModelProvider: LocalModelProvider?
    let supportsReasoning: Bool
    let reasoningLevel: ChatReasoningLevel
    let modelSwitchInProgress: Bool

    var body: some View {
        HStack(spacing: 5) {
            Label {
                pickerTitle
                    .lineLimit(1)
            } icon: {
                Group {
                    if modelSwitchInProgress {
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
        .font(.caption.weight(.medium))
        .foregroundStyle(Color.primary)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 32)
    }

    private var pickerTitle: Text {
        let modelName = Text(selectedModelLabel)
        guard supportsReasoning else {
            return modelName
        }
        return Text("\(modelName)  \(reasoningLevel.rawValue)").foregroundColor(.secondary)
    }

}

private struct ChatModelPickerTooltip: View {
    let title: String
    let showsShortcut: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.primary)

            if showsShortcut {
                Text("⌃⇧M")
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

private struct ChatComposerActionMenu: NSViewRepresentable {
    let isEnabled: Bool
    let onAttachImages: () -> Void

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

            let imageItem = NSMenuItem(
                title: "Attach Image",
                action: #selector(attachImages(_:)),
                keyEquivalent: ""
            )
            imageItem.target = self
            imageItem.image = menuImage("photo.badge.plus", description: "Attach Image")
            imageItem.isEnabled = true
            menu.addItem(imageItem)

            return menu
        }

        @objc private func attachImages(_ sender: NSMenuItem) {
            parent.onAttachImages()
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
            ? "1 image"
            : "\(prompt.attachmentCount) images"
    }
}

private struct ChatComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let onSubmit: () -> Void
    let onContentHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onContentHeightChange: onContentHeightChange
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ChatComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = context.coordinator.handleSubmit
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.font = NSFont.preferredFont(forTextStyle: .body)
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
        context.coordinator.onContentHeightChange = onContentHeightChange

        guard let textView = context.coordinator.textView else {
            return
        }

        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled

        guard textView.string != text else {
            context.coordinator.reportContentHeight()
            return
        }

        textView.string = text
        context.coordinator.reportContentHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        var onSubmit: () -> Void
        var onContentHeightChange: (CGFloat) -> Void
        weak var textView: NSTextView?
        private var lastReportedHeight: CGFloat?

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onContentHeightChange: @escaping (CGFloat) -> Void
        ) {
            _text = text
            self.onSubmit = onSubmit
            self.onContentHeightChange = onContentHeightChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else {
                return
            }

            text = textView.string
            reportContentHeight()
        }

        func handleSubmit() {
            onSubmit()
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

    override func keyDown(with event: NSEvent) {
        switch ComposerReturnBehavior.resolve(for: event) {
        case .submit:
            onSubmit?()
        case .insertNewline:
            insertText("\n", replacementRange: selectedRange())
        case .passthrough:
            super.keyDown(with: event)
        }
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

private struct ChatPendingImageAttachmentView: View {
    let attachment: ChatImageAttachment
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

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("Remove image")
        }
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}
