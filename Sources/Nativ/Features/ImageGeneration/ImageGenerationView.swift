import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageGenerationView: View {
    private enum Layout {
        static let conversationMaxWidth: CGFloat = 860
        static let composerMaxWidth: CGFloat = 680
        static let horizontalPadding: CGFloat = 32
    }

    @ObservedObject var model: NativModel
    @ObservedObject var viewModel: ImageGenerationViewModel
    let workspaceMode: ChatWorkspaceMode
    let onSelectWorkspaceMode: (ChatWorkspaceMode) -> Void
    let conversationWidthReduction: CGFloat
    let onExploreImageModels: () -> Void
    @StateObject private var localLibrary = LocalModelLibrary()
    @State private var transcriptScrollPosition = ScrollPosition(edge: .bottom)
    @State private var composerHeight: CGFloat = 0
    @State private var followsLatestTurn = true

    var body: some View {
        transcript
            .overlay(alignment: .bottom) {
                ImageGenerationComposer(
                    model: model,
                    viewModel: viewModel,
                    localModels: localLibrary.models,
                    isScanningForModels: localLibrary.isScanning,
                    modelScanError: localLibrary.error,
                    workspaceMode: workspaceMode,
                    onSelectWorkspaceMode: onSelectWorkspaceMode,
                    onExploreImageModels: onExploreImageModels
                )
                    .frame(
                        maxWidth: Layout.composerMaxWidth
                            - conversationWidthReduction
                    )
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
            .background(Color.nativMainContentBackground)
            .task(id: modelScanKey) {
                localLibrary.scan(searchPaths: model.settings.localModelSearchPaths)
            }
            .onReceive(NotificationCenter.default.publisher(for: .localModelLibraryDidChange)) { _ in
                localLibrary.scan(searchPaths: model.settings.localModelSearchPaths)
            }
            .onChange(of: imageModels.map(\.repoID)) { _, modelIDs in
                viewModel.applyDefaultModel(
                    model.settings.normalized().imageGenerationModelID,
                    installedImageModelIDs: modelIDs
                )
            }
            .onAppear {
                viewModel.applyDefaultModel(model.settings.normalized().imageGenerationModelID)
                followsLatestTurn = true
                transcriptScrollPosition.scrollTo(edge: .bottom)
            }
            .onDisappear {
                localLibrary.cancel()
                viewModel.persistDraftState()
            }
    }

    private var imageModels: [LocalModel] {
        localLibrary.models.filter {
            !$0.capabilities.isDisjoint(
                with: [.imageGeneration, .imageEditing]
            )
        }
    }

    private var selectedModelID: String? {
        imageModels.contains { $0.repoID == viewModel.modelID }
            ? viewModel.modelID
            : nil
    }

    private var modelScanKey: String {
        model.settings.localModelSearchPaths.cacheKey
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if viewModel.turns.isEmpty {
                    ImageGenerationEmptyView(
                        isRunning: model.isRunning,
                        selectedModelID: selectedModelID,
                        modelLoadingProgress: model.isModelLoading
                            && model.modelLoadingID == selectedModelID
                            ? model.modelLoadingProgress
                            : nil
                    )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                } else {
                    ForEach(viewModel.turns) { turn in
                        ImageGenerationTurnView(
                            turn: turn,
                            activeReferenceID: viewModel.activeReference?.id,
                            isGenerating: viewModel.isGenerating,
                            progressText: viewModel.statusText,
                            onUseOutput: viewModel.useAsReference,
                            onUseInput: viewModel.useAsReference,
                            onSave: viewModel.save
                        )
                        .id(turn.id)
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
            geometry.visibleRect.maxY >= geometry.contentSize.height - 180
        } action: { _, isNearBottom in
            followsLatestTurn = isNearBottom
        }
        .onChange(of: viewModel.scrollToken) { _, _ in
            if followsLatestTurn {
                transcriptScrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: viewModel.currentSessionID) { _, _ in
            followsLatestTurn = true
            transcriptScrollPosition.scrollTo(edge: .bottom)
        }
    }
}

private struct ImageGenerationComposer: View {
    @ObservedObject var model: NativModel
    @ObservedObject var viewModel: ImageGenerationViewModel
    let localModels: [LocalModel]
    let isScanningForModels: Bool
    let modelScanError: String?
    let workspaceMode: ChatWorkspaceMode
    let onSelectWorkspaceMode: (ChatWorkspaceMode) -> Void
    let onExploreImageModels: () -> Void
    @State private var editorContentHeight: CGFloat = 0
    @State private var showsSettings = false
    @State private var isDropTargeted = false

    private let textInset = EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14)
    private let editorMinimumHeight: CGFloat = 64
    private let editorMaximumHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let unavailableReason {
                Text(unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, textInset.leading + 4)
            }

            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ChatComposerTextEditor(
                        text: $viewModel.prompt,
                        isEnabled: canCompose,
                        onSubmit: submit,
                        onPasteImage: viewModel.attachImages,
                        onContentHeightChange: { editorContentHeight = $0 }
                    )

                    if viewModel.prompt.isEmpty {
                        Text(placeholder)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(textInset)
                            .offset(x: 4)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: editorHeight)

                referenceTray

                HStack(spacing: 8) {
                    ChatComposerActionMenu(
                        isEnabled: canCompose,
                        canPasteImage: viewModel.canPasteImage,
                        onAttachImages: viewModel.chooseImageAttachments,
                        onPasteImage: viewModel.pasteImageFromClipboard,
                        onCaptureScreenshot: viewModel.captureScreenshot
                    )
                    .frame(width: 30, height: 30)
                    .help("Add a reference image")

                    ChatWorkspacePicker(
                        selection: workspaceMode,
                        onSelect: onSelectWorkspaceMode
                    )

                    Button {
                        showsSettings.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help("Image settings")
                    .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                        ImageGenerationSettingsView(viewModel: viewModel)
                    }

                    Spacer(minLength: 12)

                    modelPicker

                    Button(action: action) {
                        Image(systemName: viewModel.isGenerating ? "stop.fill" : "arrow.up")
                            .font(.system(size: viewModel.isGenerating ? 10 : 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(actionButtonColor, in: Circle())
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.isGenerating && !canSubmit)
                    .help(viewModel.isGenerating ? "Stop" : actionHelp)
                }
                .padding(.leading, 10)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isDropTargeted ? 2 : 0.75)
            }
            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
            .onDrop(
                of: ImageGenerationDrag.supportedDropTypeIdentifiers,
                isTargeted: $isDropTargeted,
                perform: viewModel.loadImageAttachments
            )
        }
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var referenceTray: some View {
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
        } else if let activeReference = viewModel.activeReference {
            HStack(spacing: 8) {
                Text("Continue from")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ChatPendingImageAttachmentView(attachment: activeReference) {
                    viewModel.clearActiveReference()
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var canCompose: Bool {
        model.isRunning
            && selectedModelID != nil
            && !viewModel.isGenerating
    }

    private var canSubmit: Bool {
        selectedModelID != nil
            && viewModel.canSubmit(isRunning: model.isRunning)
            && (!selectedModelIsEditOnly || viewModel.nextRequestIsEdit)
    }

    private var placeholder: String {
        if selectedModelIsEditOnly && !viewModel.nextRequestIsEdit {
            return "Add a reference image to use this edit model"
        }
        return viewModel.nextRequestIsEdit
            ? "Describe how to change the image"
            : "Describe an image to create"
    }

    private var editorHeight: CGFloat {
        min(max(editorContentHeight, editorMinimumHeight), editorMaximumHeight)
    }

    private var modelLabel: String {
        guard let selectedModelID else {
            return "Choose model"
        }
        return selectedModelID.split(separator: "/").last.map(String.init)
            ?? selectedModelID
    }

    private var modelPicker: some View {
        ComposerModelPicker(
            models: imageModels,
            selectedModelID: selectedModelID,
            selectedModelLabel: modelLabel,
            selectedModelProvider: selectedModelProvider,
            selectedModelDetail: nil,
            secondarySection: nil,
            isModelLoading: isSelectedModelLoading,
            modelLoadingPercentage: isSelectedModelLoading
                ? model.modelLoadingPercentage
                : nil,
            isDisabled: model.isModelLoading || viewModel.isGenerating,
            statusLabel: localModelStatusLabel,
            helpText: modelPickerHelp,
            accessibilityValue: modelLabel,
            shortcutLabel: "⌃⇧M",
            emptyStateActionTitle: "Browse Image Models…",
            onEmptyStateAction: onExploreImageModels,
            onSelectModel: selectImageModel,
            onSwitchModel: selectImageModel,
            drafters: [],
            selectedDrafterID: nil,
            onSelectDrafter: { _ in }
        )
    }

    private var imageModels: [LocalModel] {
        localModels.filter {
            !$0.capabilities.isDisjoint(
                with: [.imageGeneration, .imageEditing]
            )
        }
    }

    private var selectedModelID: String? {
        imageModels.contains { $0.repoID == viewModel.modelID }
            ? viewModel.modelID
            : nil
    }

    private var selectedModelIsEditOnly: Bool {
        guard let selectedModelID,
              let selectedModel = imageModels.first(where: {
                  $0.repoID == selectedModelID
              })
        else { return false }
        return selectedModel.capabilities.contains(.imageEditing)
            && !selectedModel.capabilities.contains(.imageGeneration)
    }

    private var selectedModelProvider: LocalModelProvider? {
        guard let selectedModelID else { return nil }
        return imageModels.first(where: {
            $0.repoID == selectedModelID
        })?.provider
    }

    private var isSelectedModelLoading: Bool {
        model.isModelLoading && model.modelLoadingID == viewModel.modelID
    }

    private var localModelStatusLabel: String {
        if isScanningForModels {
            return "Scanning for models…"
        }
        return modelScanError ?? "No compatible image models"
    }

    private var modelPickerHelp: String {
        if viewModel.isGenerating {
            return "Model switching is unavailable while generating"
        }
        if model.isModelLoading {
            return model.modelLoadingStatusText ?? "Loading \(modelLabel)"
        }
        if selectedModelIsEditOnly {
            return "This model loads on demand when you edit an image"
        }
        return "Change image model"
    }

    private var unavailableReason: String? {
        if !model.isRunning {
            return "Server is stopped."
        }
        return nil
    }

    private var actionButtonColor: Color {
        viewModel.isGenerating || canSubmit ? .accentColor : Color(nsColor: .tertiaryLabelColor)
    }

    private var actionHelp: String {
        if selectedModelIsEditOnly && !viewModel.nextRequestIsEdit {
            return "Add a reference image to use this edit model"
        }
        return viewModel.nextRequestIsEdit
            ? "Edit image (Return)"
            : "Generate image (Return)"
    }

    private func submit() {
        guard canSubmit else {
            return
        }
        viewModel.run(
            using: model,
            modelIsInstalled: imageModels.contains { $0.repoID == viewModel.modelID }
        )
    }

    private func selectImageModel(_ localModel: LocalModel) {
        if localModel.capabilities.contains(.imageEditing)
            && !localModel.capabilities.contains(.imageGeneration)
        {
            viewModel.applyDefaultModel(localModel.repoID)
            return
        }
        model.requestPreloadedModelSwitch(
            to: localModel,
            for: .imageGeneration,
            availableModels: localModels
        ) {
            viewModel.applyDefaultModel(localModel.repoID)
        }
    }

    private func selectImageModel(_ modelID: String) {
        viewModel.applyDefaultModel(modelID)
        guard !MLXImageModelResolver.isKnownImageEditOnlyModelID(modelID) else {
            return
        }
        model.switchPreloadedModel(to: modelID, for: .imageGeneration)
    }

    private func action() {
        if viewModel.isGenerating {
            viewModel.cancel()
        } else {
            submit()
        }
    }
}

private struct ImageGenerationSettingsView: View {
    @ObservedObject var viewModel: ImageGenerationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Image Settings")
                .font(.headline)

            settingRow("Size") {
                TextField("Width", value: $viewModel.requestSettings.width, format: .number)
                    .frame(width: 72)
                Text("×").foregroundStyle(.secondary)
                TextField("Height", value: $viewModel.requestSettings.height, format: .number)
                    .frame(width: 72)

                Menu("\(viewModel.currentLongestSide) px") {
                    ForEach(ImageGenerationSizeOptions.longestSides, id: \.self) { side in
                        Button("\(side) px") {
                            viewModel.applyLongestSide(side)
                        }
                    }
                }
            }

            settingRow("Images") {
                TextField("", value: $viewModel.requestSettings.count, format: .number)
                    .frame(width: 72)
                Stepper("", value: $viewModel.requestSettings.count, in: 1...10)
                    .labelsHidden()
            }

            settingRow("Steps") {
                TextField("", value: $viewModel.requestSettings.steps, format: .number)
                    .frame(width: 72)
                Stepper("", value: $viewModel.requestSettings.steps, in: 1...1_000)
                    .labelsHidden()
            }

            settingRow("Guidance") {
                Slider(value: $viewModel.requestSettings.guidance, in: 0...20, step: 0.1)
                    .frame(width: 150)
                Text(viewModel.requestSettings.guidance, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }

            settingRow("Seed") {
                TextField("Random", text: $viewModel.requestSettings.seedText)
                    .frame(width: 150)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(18)
        .frame(width: 390)
    }

    private func settingRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

private struct ImageGenerationTurnView: View {
    let turn: ImageGenerationTurn
    let activeReferenceID: UUID?
    let isGenerating: Bool
    let progressText: String?
    let onUseOutput: (GeneratedImage) -> Void
    let onUseInput: (ChatImageAttachment) -> Void
    let onSave: (GeneratedImage) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 12, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 12) {
            userRequest
                .frame(maxWidth: .infinity, alignment: .trailing)

            assistantResult
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var userRequest: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !turn.referenceImages.isEmpty {
                HStack(spacing: 8) {
                    ForEach(turn.referenceImages) { attachment in
                        Button {
                            onUseInput(attachment)
                        } label: {
                            ImageAttachmentPreview(attachment: attachment, maximumSide: 112)
                        }
                        .buttonStyle(.plain)
                        .disabled(isGenerating)
                        .help("Use this reference again")
                    }
                }
            }

            Text(turn.prompt)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(turn.isEdit ? "Edit" : "Generate")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 620, alignment: .trailing)
    }

    @ViewBuilder
    private var assistantResult: some View {
        switch turn.status {
        case .inProgress:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(progressText ?? (turn.isEdit ? "Editing image…" : "Generating image…"))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)

        case .failed, .cancelled:
            Label(turn.errorMessage ?? "Image generation failed.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(turn.status == .cancelled ? .secondary : Color.orange)
                .textSelection(.enabled)
                .padding(.vertical, 12)

        case .completed:
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(turn.outputs) { output in
                    GeneratedImageCard(
                        result: output,
                        isActiveReference: activeReferenceID == output.id,
                        isGenerating: isGenerating,
                        onUseAsReference: { onUseOutput(output) },
                        onSave: { onSave(output) }
                    )
                }
            }
        }
    }
}

private struct GeneratedImageCard: View {
    let result: GeneratedImage
    let isActiveReference: Bool
    let isGenerating: Bool
    let onUseAsReference: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = result.nsImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 420)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onDrag { ImageGenerationDrag.itemProvider(for: result) }
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(result.width)×\(result.height)")
                        .font(.caption.weight(.semibold))
                    Text("Seed \(result.seed)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(action: onUseAsReference) {
                    Label(
                        isActiveReference ? "Selected" : "Continue",
                        systemImage: isActiveReference ? "checkmark.circle.fill" : "arrow.turn.down.right"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isGenerating || isActiveReference)
                .help("Use this image as the next edit reference")

                Button(action: onSave) {
                    Image(systemName: "square.and.arrow.down")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .help("Save image")
            }

            if let revisedPrompt = result.revisedPrompt,
               !revisedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(revisedPrompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isActiveReference ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isActiveReference ? 1.5 : 0.5
                )
        }
    }
}

private struct ImageAttachmentPreview: View {
    let attachment: ChatImageAttachment
    let maximumSide: CGFloat

    var body: some View {
        Group {
            if let data = attachment.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: maximumSide, maxHeight: maximumSide)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .accessibilityLabel(attachment.filename)
    }
}

private struct ImageGenerationEmptyView: View {
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
                .foregroundStyle(.secondary)

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
            return "Loading image model"
        }
        if !isRunning {
            return "Server is stopped"
        }
        if selectedModelID == nil {
            return "No image model downloaded"
        }
        return "Create with Images"
    }

    private var detail: String {
        if let modelLoadingProgress {
            let percentage = Int((modelLoadingProgress * 100).rounded())
            return "\(selectedModelID ?? "Image model") · \(percentage)%"
        }
        if !isRunning {
            return "Start the server to create images."
        }
        if selectedModelID == nil {
            return "Download an image model in Models."
        }
        return "Describe an image below. Attach a reference to edit it, then continue iterating from any result."
    }
}

private enum ImageGenerationDrag {
    static let supportedDropTypeIdentifiers = [
        UTType.fileURL,
        .png,
        .jpeg,
        .tiff,
        .gif,
        .image
    ].map(\.identifier)

    static func itemProvider(for result: GeneratedImage) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = result.filename
        provider.registerDataRepresentation(
            forTypeIdentifier: result.imageType.identifier,
            visibility: .all
        ) { completion in
            completion(result.imageData, nil)
            return nil
        }
        return provider
    }
}
