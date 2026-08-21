import AppKit
import Combine
import SwiftUI
import Textual

private enum ModelsPageSection: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case discover = "Discover"

    var id: String { rawValue }
}

private enum HubAccessFilter: String, CaseIterable, Identifiable {
    case all = "All access"
    case open = "Open models"
    case gated = "Gated models"

    var id: String { rawValue }
}

private enum ModelsTypeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case language = "Language"
    case image = "Image"
    case speech = "Speech"
    case embeddings = "Embeddings"
    case reranking = "Reranking"

    var id: String { rawValue }

    func matches(_ capabilities: Set<LocalModelCapability>) -> Bool {
        switch self {
        case .all:
            true
        case .language:
            capabilities.contains(.text) && !capabilities.contains(.reranking)
        case .image:
            !capabilities.isDisjoint(with: [.imageGeneration, .imageEditing])
        case .speech:
            !capabilities.isDisjoint(with: [.audio, .speechToText, .textToSpeech])
        case .embeddings:
            capabilities.contains(.embeddings)
        case .reranking:
            capabilities.contains(.reranking)
        }
    }

}

private struct HubSearchTaskID: Hashable {
    let section: ModelsPageSection
    let query: String
    let sort: HuggingFaceModelSort
    let direction: HuggingFaceSortDirection
    let capabilities: Set<LocalModelCapability>
    let access: HubAccessFilter
    let authenticationToken: String?
}

private struct ModelReadmeSelection: Equatable {
    let repoID: String
    let provider: LocalModelProvider?
    let localSnapshotURL: URL?
}

/// Filters the app-wide model publisher down to values that can actually
/// change the Models page. In particular, the one-second server metrics poll
/// must not invalidate the full Discover list just because uptime changed.
@MainActor
private final class ModelsNativState: ObservableObject {
    @Published private(set) var settings: NativSettings
    @Published private(set) var isRunning: Bool
    @Published private(set) var modelSwitchInProgress: Bool
    @Published private(set) var modelSwitchTargetID: String?
    @Published private(set) var modelLoadingProgress: Double?
    @Published private(set) var metricsLoading: Bool
    @Published private(set) var modelLoadFailure: ModelLoadFailure?
    @Published private(set) var systemHuggingFaceCredential: HuggingFaceCredential?
    @Published private(set) var loadedModelID: String?

    private var cancellables = Set<AnyCancellable>()

    init(model: NativModel) {
        settings = model.settings
        isRunning = model.isRunning
        modelSwitchInProgress = model.modelSwitchInProgress
        modelSwitchTargetID = model.modelSwitchTargetID
        modelLoadingProgress = model.modelLoadingProgress
        metricsLoading = model.metricsLoading
        modelLoadFailure = model.modelLoadFailure
        systemHuggingFaceCredential = model.systemHuggingFaceCredential
        loadedModelID = model.metrics?.server.loadedModel

        model.$settings
            .removeDuplicates()
            .sink { [weak self] in self?.settings = $0 }
            .store(in: &cancellables)
        model.$isRunning
            .removeDuplicates()
            .sink { [weak self] in self?.isRunning = $0 }
            .store(in: &cancellables)
        model.$modelSwitchInProgress
            .removeDuplicates()
            .sink { [weak self] in self?.modelSwitchInProgress = $0 }
            .store(in: &cancellables)
        model.$modelSwitchTargetID
            .removeDuplicates()
            .sink { [weak self] in self?.modelSwitchTargetID = $0 }
            .store(in: &cancellables)
        model.$modelLoadingProgress
            .removeDuplicates()
            .sink { [weak self] in self?.modelLoadingProgress = $0 }
            .store(in: &cancellables)
        model.$metricsLoading
            .removeDuplicates()
            .sink { [weak self] in self?.metricsLoading = $0 }
            .store(in: &cancellables)
        model.$modelLoadFailure
            .removeDuplicates()
            .sink { [weak self] in self?.modelLoadFailure = $0 }
            .store(in: &cancellables)
        model.$systemHuggingFaceCredential
            .removeDuplicates()
            .sink { [weak self] in self?.systemHuggingFaceCredential = $0 }
            .store(in: &cancellables)
        model.$metrics
            .map { $0?.server.loadedModel }
            .removeDuplicates()
            .sink { [weak self] in self?.loadedModelID = $0 }
            .store(in: &cancellables)
    }

    var effectiveHuggingFaceToken: String? {
        HuggingFaceAuthentication.effectiveToken(
            customToken: settings.huggingFaceToken,
            environmentToken: systemHuggingFaceCredential?.token
        )
    }

    var modelLoadingID: String? {
        if modelSwitchInProgress {
            return modelSwitchTargetID
        }
        guard metricsLoading || modelLoadingProgress != nil else {
            return nil
        }
        return settings.normalized().languageModelID
    }

    var modelLoadingPercentage: Int? {
        modelLoadingProgress.map { progress in
            min(max(Int((progress * 100).rounded()), 0), 100)
        }
    }
}

/// Stops unrelated `NativModel` publications in the parent control panel from
/// walking the Models subtree. Relevant model changes arrive through
/// `ModelsNativState` instead.
struct ModelsViewHost: View, @MainActor Equatable {
    let model: NativModel
    @Binding var showsConfiguration: Bool
    var titleLeadingInset: CGFloat = 0
    var speechModelDiscoveryRequest = 0
    var imageModelDiscoveryRequest = 0
    var imageModelDiscoveryCapability: LocalModelCapability = .imageGeneration

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model
            && lhs.showsConfiguration == rhs.showsConfiguration
            && lhs.titleLeadingInset == rhs.titleLeadingInset
            && lhs.speechModelDiscoveryRequest == rhs.speechModelDiscoveryRequest
            && lhs.imageModelDiscoveryRequest == rhs.imageModelDiscoveryRequest
            && lhs.imageModelDiscoveryCapability == rhs.imageModelDiscoveryCapability
    }

    var body: some View {
        ModelsView(
            model: model,
            showsConfiguration: $showsConfiguration,
            titleLeadingInset: titleLeadingInset,
            speechModelDiscoveryRequest: speechModelDiscoveryRequest,
            imageModelDiscoveryRequest: imageModelDiscoveryRequest,
            imageModelDiscoveryCapability: imageModelDiscoveryCapability
        )
    }
}

struct ModelsView: View {
    let model: NativModel
    @Binding var showsConfiguration: Bool
    var titleLeadingInset: CGFloat = 0
    var speechModelDiscoveryRequest = 0
    var imageModelDiscoveryRequest = 0
    var imageModelDiscoveryCapability: LocalModelCapability = .imageGeneration
    @StateObject private var modelState: ModelsNativState
    @StateObject private var localLibrary = LocalModelLibrary()
    @StateObject private var hubLibrary = HuggingFaceModelLibrary()
    @StateObject private var readmeStore = HuggingFaceModelReadmeStore()
    // Keep download progress observation in the banner and individual rows.
    // Observing the manager here invalidates the entire Models view for every
    // progress tick, which makes Discover scroll janky during downloads.
    private var downloadManager: HuggingFaceDownloadManager { .shared }
    @State private var section: ModelsPageSection = .installed
    @State private var renderedSection: ModelsPageSection = .installed
    @State private var typeFilter: ModelsTypeFilter = .all
    @State private var localQuery = ""
    @State private var hubQuery = ""
    @State private var hubSort: HuggingFaceModelSort = .trending
    @State private var hubSortDirection: HuggingFaceSortDirection = .descending
    @State private var hubCapabilityFilters = Set<LocalModelCapability>()
    @State private var hubAccessFilter: HubAccessFilter = .all
    @State private var handledSpeechModelDiscoveryRequest = 0
    @State private var handledImageModelDiscoveryRequest = 0
    @State private var lastStartedHubSearchTaskID: HubSearchTaskID?
    @State private var readmeSelection: ModelReadmeSelection?

    init(
        model: NativModel,
        showsConfiguration: Binding<Bool>,
        titleLeadingInset: CGFloat = 0,
        speechModelDiscoveryRequest: Int = 0,
        imageModelDiscoveryRequest: Int = 0,
        imageModelDiscoveryCapability: LocalModelCapability = .imageGeneration
    ) {
        self.model = model
        _showsConfiguration = showsConfiguration
        self.titleLeadingInset = titleLeadingInset
        self.speechModelDiscoveryRequest = speechModelDiscoveryRequest
        self.imageModelDiscoveryRequest = imageModelDiscoveryRequest
        self.imageModelDiscoveryCapability = imageModelDiscoveryCapability
        _modelState = StateObject(wrappedValue: ModelsNativState(model: model))
    }

    var body: some View {
        ModelConfigurationLayoutContent(
            settings: settingsBinding,
            settingsRequireRestart: model.settingsRequireRestart,
            isConfigurationVisible: $showsConfiguration,
            onReset: model.resetSettings
        ) {
            VStack(spacing: 0) {
                pageHeader
                Divider()
                activeDownloadBanner
                modelLoadFailureBanner

                modelsPage
            }
        }
        .background(Color.nativMainContentBackground)
        .task(id: modelScanPath) {
            rescanLocalModels()
        }
        .onReceive(NotificationCenter.default.publisher(for: .localModelLibraryDidChange)) { _ in
            rescanLocalModels()
        }
        .onAppear {
            openSpeechModelDiscoveryIfRequested()
            openImageModelDiscoveryIfRequested()
        }
        .onChange(of: speechModelDiscoveryRequest) { _, _ in
            openSpeechModelDiscoveryIfRequested()
        }
        .onChange(of: imageModelDiscoveryRequest) { _, _ in
            openImageModelDiscoveryIfRequested()
        }
        .onChange(of: section) { _, newSection in
            // Let the segmented control commit before replacing the toolbar
            // and active rows. This queues one main-loop turn with no fixed
            // delay and keeps only one section's content mounted at a time.
            DispatchQueue.main.async {
                guard section == newSection else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    renderedSection = newSection
                    selectFirstReadme(in: newSection)
                }
            }
        }
        .onChange(of: localLibrary.models.map(\.repoID)) { _, _ in
            selectFirstVisibleReadmeIfNeeded(in: .installed)
        }
        .onChange(of: hubLibrary.models.map(\.id)) { _, _ in
            selectFirstVisibleReadmeIfNeeded(in: .discover)
        }
        .task(id: hubSearchTaskID) {
            guard renderedSection == .discover else { return }
            let searchTaskID = hubSearchTaskID
            guard searchTaskID != lastStartedHubSearchTaskID else { return }
            lastStartedHubSearchTaskID = searchTaskID
            hubLibrary.search(
                query: hubQuery,
                sort: hubSort,
                direction: hubSortDirection,
                capabilities: hubCapabilityFilters,
                predicate: hubVisibilityPredicate,
                token: modelState.effectiveHuggingFaceToken
            )
        }
        .task(id: readmeSelection?.repoID) {
            guard let readmeSelection else {
                readmeStore.clearSelection()
                return
            }
            await readmeStore.load(
                repoID: readmeSelection.repoID,
                localSnapshotURL: readmeSelection.localSnapshotURL,
                token: modelState.effectiveHuggingFaceToken
            )
        }
        .onDisappear {
            localLibrary.cancel()
            hubLibrary.cancel()
            lastStartedHubSearchTaskID = nil
        }
    }

    private func openSpeechModelDiscoveryIfRequested() {
        guard speechModelDiscoveryRequest > handledSpeechModelDiscoveryRequest else {
            return
        }
        handledSpeechModelDiscoveryRequest = speechModelDiscoveryRequest
        section = .discover
        typeFilter = .speech
        hubQuery = ""
        hubCapabilityFilters = [.speechToText]
        hubAccessFilter = .all
    }

    private func openImageModelDiscoveryIfRequested() {
        guard imageModelDiscoveryRequest > handledImageModelDiscoveryRequest else {
            return
        }
        handledImageModelDiscoveryRequest = imageModelDiscoveryRequest
        section = .discover
        typeFilter = .image
        hubQuery = ""
        hubSort = .downloads
        hubSortDirection = .descending
        hubCapabilityFilters = [imageModelDiscoveryCapability]
        hubAccessFilter = .all
    }

    @ViewBuilder
    private var modelLoadFailureBanner: some View {
        if let failure = modelState.modelLoadFailure {
            ModelsNotice(
                title: failure.title,
                message: failure.message,
                systemImage: "exclamationmark.triangle.fill",
                color: .orange,
                onDismiss: { model.clearModelLoadFailure() }
            )
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            Divider()
        }
    }

    @ViewBuilder
    private var activeDownloadBanner: some View {
        ActiveDownloadBannerView()
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            pageTitle
            Spacer(minLength: 12)
            sectionPicker
        }
        .padding(.horizontal, 22)
        .padding(.leading, titleLeadingInset)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var modelsPage: some View {
        VStack(spacing: 0) {
            sectionToolbar
                .padding(.horizontal, 22)
                .padding(.vertical, 14)

            sectionResults
        }
    }

    @ViewBuilder
    private var sectionResults: some View {
        // Keep the results hierarchy mounted when details open. Replacing the
        // whole scroller here made a card click wait for the visible rows to
        // be rebuilt before SwiftUI could present the README loading state.
        VStack(spacing: 0) {
            switch renderedSection {
            case .installed:
                installedResultsHeader
                    .modelsListRow(top: 0)
            case .discover:
                discoverResultsHeader
                    .modelsListRow(top: 0)
            }

            GeometryReader { geometry in
                HStack(spacing: 0) {
                    sectionScroller(showsResultsHeader: false)

                    if let readmeSelection, section == renderedSection {
                        Divider()
                        ModelReadmePanel(
                            selection: readmeSelection,
                            store: readmeStore,
                            onClose: { self.readmeSelection = nil }
                        )
                        .frame(width: geometry.size.width * 0.4)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
    }

    private var sectionToolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                DebouncedModelsSearchField(
                    prompt: renderedSection == .installed
                        ? "Search installed models" : "Search models on Hugging Face",
                    text: activeSearchQuery,
                    identity: renderedSection,
                    debounceMilliseconds: renderedSection == .installed ? 100 : 350
                )
                .frame(height: 32)

                if renderedSection == .discover, hubLibrary.isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28)
                }
            }

            switch renderedSection {
            case .installed:
                installedFilterBar
            case .discover:
                discoverFilterBar
            }
        }
    }

    @ViewBuilder
    private func sectionScroller(showsResultsHeader: Bool) -> some View {
        if section != renderedSection {
            ScrollView {
                Text("Opening \(section.rawValue)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .modelsListRow(top: 0)
            }
        } else {
            switch renderedSection {
            case .installed:
                ScrollView {
                    LazyVStack(spacing: 0) {
                        installedRows(showsResultsHeader: showsResultsHeader)

                        Color.clear
                            .frame(height: 12)
                            .modelsListRow(top: 0, bottom: 0)
                    }
                }
            case .discover:
                discoverScroller(showsResultsHeader: showsResultsHeader)
            }
        }
    }

    @ViewBuilder
    private func installedRows(showsResultsHeader: Bool) -> some View {
        let visibleModels = filteredLocalModels
        let normalizedSettings = modelState.settings.normalized()

        if let error = localLibrary.error {
            ModelsNotice(
                title: "Couldn’t read the model cache",
                message: error,
                systemImage: "exclamationmark.triangle.fill",
                color: .orange
            )
            .modelsListRow()
        }

        if localLibrary.isScanning && localLibrary.models.isEmpty {
            ModelsLoadingState(title: "Scanning your Hugging Face cache…")
                .modelsListRow()
        } else if visibleModels.isEmpty {
            ModelsEmptyState(
                systemImage: installedFilterIsActive
                    ? "line.3.horizontal.decrease.circle" : "shippingbox",
                title: installedFilterIsActive
                    ? "No models match your filter" : "No MLX models installed",
                message: installedFilterIsActive
                    ? "Try a different search or model type."
                    : "Discover an MLX model on Hugging Face and download it to this cache.",
                actionTitle: installedFilterIsActive ? nil : "Discover models",
                action: { section = .discover }
            )
            .modelsListRow()
        } else {
            if showsResultsHeader {
                installedResultsHeader
                    .modelsListRow(top: 0)
            }

            ForEach(visibleModels) { localModel in
                let preloadSlots = preloadSlots(for: localModel)
                let selectedSlots = Set(
                    ModelPreloadSlot.allCases.filter {
                        normalizedSettings.modelID(for: $0) == localModel.repoID
                    }
                )
                InstalledModelRow(
                    localModel: localModel,
                    preloadSlots: preloadSlots,
                    selectedPreloadSlots: selectedSlots,
                    preferredPreloadSlot: preferredPreloadSlot(
                        among: preloadSlots
                    ),
                    isSelectionDisabled: modelState.modelSwitchInProgress,
                    isModelLoading: modelState.modelLoadingID
                        == localModel.repoID,
                    modelLoadingPercentage: modelState.modelLoadingPercentage,
                    isReadmeSelected: readmeSelection?.repoID == localModel.repoID,
                    isDeleting: localLibrary.deletingModelIDs.contains(
                        localModel.repoID),
                    canDelete: localModel.isDeletable && !modelState.modelSwitchInProgress
                        && !isModelInUse(localModel.repoID),
                    onSetPreload: { slot, isEnabled in
                        if isEnabled {
                            model.requestPreloadedModelSwitch(
                                to: localModel,
                                for: slot,
                                availableModels: localLibrary.models
                            )
                        } else {
                            model.switchPreloadedModel(to: nil, for: slot)
                        }
                    },
                    onShowReadme: {
                        showReadme(
                            repoID: localModel.repoID,
                            provider: localModel.provider,
                            localSnapshotURL: localModel.snapshotURL
                        )
                    },
                    onDelete: { deleteInstalledModel(localModel) }
                )
                .equatable()
                .modelsListRow()
            }
        }
    }

    private var installedResultsHeader: some View {
        let visibleModels = filteredLocalModels
        return HStack {
            Text("\(visibleModels.count) \(visibleModels.count == 1 ? "model" : "models")")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if localLibrary.isScanning {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var installedFilterBar: some View {
        HStack(spacing: 10) {
            typeFilterPicker
            sourcesMenu
            Spacer(minLength: 0)
            refreshButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var refreshButton: some View {
        Button {
            rescanLocalModels()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(localLibrary.isScanning)
        .help("Refresh installed models")
        .accessibilityLabel("Refresh installed models")
    }

    @ViewBuilder
    private func discoverScroller(showsResultsHeader: Bool) -> some View {
        if let error = hubLibrary.error {
            ScrollView {
                ModelsNotice(
                    title: "Hugging Face is unavailable",
                    message: error,
                    systemImage: "wifi.exclamationmark",
                    color: .orange
                )
                .modelsListRow()
            }
        } else if hubLibrary.isSearching && hubLibrary.models.isEmpty {
            ScrollView {
                ModelsLoadingState(
                    title: hubQuery.isEmpty
                        ? "Finding popular Safetensors models…" : "Searching Hugging Face…")
                    .modelsListRow()
            }
        } else if hubLibrary.models.isEmpty {
            ScrollView {
                if hubCapabilityFilters.isEmpty && hubAccessFilter == .all {
                    ModelsEmptyState(
                        systemImage: "magnifyingglass",
                        title: "No Safetensors models found",
                        message: "Try a model family, provider, or repository name.",
                        actionTitle: nil,
                        action: {}
                    )
                    .modelsListRow()
                } else {
                    ModelsEmptyState(
                        systemImage: "line.3.horizontal.decrease.circle",
                        title: "No models match these filters",
                        message:
                            "Try another model type, capability, or access filter, or continue to the next page.",
                        actionTitle: nil,
                        action: {}
                    )
                    .modelsListRow()
                }
            }
        } else {
            let installedIDs = installedModelIDs
            let models = filteredHubModels
            // Keep only visible Discover rows mounted. These rows contain
            // several badges and controls, so laying out the entire page on
            // every scroll pass is noticeably more expensive than Installed.
            ScrollView {
                LazyVStack(spacing: 0) {
                    if showsResultsHeader {
                        discoverResultsHeader
                            .modelsListRow(top: 0)
                    }

                    ForEach(models) { hubModel in
                        HubModelRowContainer(
                            model: hubModel,
                            isInstalled: installedIDs.contains(hubModel.id),
                            isReadmeSelected: readmeSelection?.repoID == hubModel.id,
                            onShowReadme: {
                                showReadme(
                                    repoID: hubModel.id,
                                    provider: hubModel.provider,
                                    localSnapshotURL: nil
                                )
                            },
                            onDownload: { downloadSizeBytes in
                                downloadManager.download(
                                    repoID: hubModel.id,
                                    sizeBytes: downloadSizeBytes,
                                    cachePath: modelState.settings.modelSearchPath,
                                    token: modelState.effectiveHuggingFaceToken
                                ) {}
                            },
                            onPauseResume: {
                                if downloadManager.isPaused(for: hubModel.id) {
                                    downloadManager.resumeDownload(hubModel.id)
                                } else {
                                    downloadManager.pauseDownload(hubModel.id)
                                }
                            },
                            onRemoveDownload: {
                                downloadManager.removeDownload(hubModel.id)
                            }
                        )
                        .equatable()
                        .modelsListRow()
                    }

                    discoverPagination
                        .modelsListRow(top: 13)

                    Color.clear
                        .frame(height: 12)
                        .modelsListRow(top: 0, bottom: 0)
                }
            }
        }
    }

    private var discoverPagination: some View {
        HStack(spacing: 12) {
            Spacer()

            HubPaginationButton(
                title: "Previous",
                systemImage: "chevron.left",
                isDisabled: !hubLibrary.canGoToPreviousPage,
                action: hubLibrary.goToPreviousPage
            )

            Text("Page \(hubLibrary.pageNumber) of up to 5")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 122)

            HubPaginationButton(
                title: "Next",
                systemImage: "chevron.right",
                isDisabled: !hubLibrary.canGoToNextPage
            ) {
                hubLibrary.goToNextPage(token: modelState.effectiveHuggingFaceToken)
            }

            Spacer()
        }
        .frame(height: 30)
    }

    private func isModelInUse(_ repoID: String) -> Bool {
        guard modelState.isRunning else { return false }
        let settings = modelState.settings.normalized()
        let configuredModelIDs = [
            settings.languageModelID,
            settings.imageGenerationModelID,
            settings.textToSpeechModelID,
            settings.speechToTextModelID,
            modelState.loadedModelID,
        ]
        return configuredModelIDs.contains(repoID)
    }

    private func showReadme(
        repoID: String,
        provider: LocalModelProvider?,
        localSnapshotURL: URL?
    ) {
        let selection = ModelReadmeSelection(
            repoID: repoID,
            provider: provider,
            localSnapshotURL: localSnapshotURL
        )
        if readmeSelection == selection {
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            readmeSelection = selection
        }
    }

    private func selectFirstVisibleReadmeIfNeeded(in targetSection: ModelsPageSection) {
        guard renderedSection == targetSection else { return }
        let visibleIDs: [String] = switch targetSection {
        case .installed:
            filteredLocalModels.map(\.repoID)
        case .discover:
            filteredHubModels.map(\.id)
        }
        guard readmeSelection == nil || !visibleIDs.contains(readmeSelection?.repoID ?? "") else {
            return
        }
        selectFirstReadme(in: targetSection)
    }

    private func selectFirstReadme(in targetSection: ModelsPageSection) {
        switch targetSection {
        case .installed:
            guard let model = filteredLocalModels.first else {
                readmeSelection = nil
                return
            }
            showReadme(
                repoID: model.repoID,
                provider: model.provider,
                localSnapshotURL: model.snapshotURL
            )
        case .discover:
            guard let model = filteredHubModels.first else {
                readmeSelection = nil
                return
            }
            showReadme(
                repoID: model.id,
                provider: model.provider,
                localSnapshotURL: nil
            )
        }
    }

    private func preloadSlots(for localModel: LocalModel) -> [ModelPreloadSlot] {
        var slots: [ModelPreloadSlot] = []
        if localModel.isEligibleForLanguageModelPicker {
            slots.append(.language)
        }
        if localModel.capabilities.contains(.imageGeneration) {
            slots.append(.imageGeneration)
        }
        if localModel.capabilities.contains(.textToSpeech) {
            slots.append(.textToSpeech)
        }
        if localModel.capabilities.contains(.speechToText) {
            slots.append(.speechToText)
        }
        if localModel.capabilities.contains(.embeddings) {
            slots.append(.embeddings)
        }
        return slots
    }

    private func preferredPreloadSlot(
        among slots: [ModelPreloadSlot]
    ) -> ModelPreloadSlot? {
        let preferredSlot: ModelPreloadSlot? =
            switch typeFilter {
            case .all:
                nil
            case .language:
                .language
            case .image:
                .imageGeneration
            case .speech:
                nil
            case .embeddings:
                .embeddings
            case .reranking:
                nil
            }
        if let preferredSlot, slots.contains(preferredSlot) {
            return preferredSlot
        }
        return slots.first
    }

    private func deleteInstalledModel(_ localModel: LocalModel) {
        guard localModel.isDeletable else { return }
        localLibrary.delete(
            model: localModel,
            path: modelState.settings.modelSearchPath
        ) {
            var settings = modelState.settings
            if settings.languageModelID == localModel.repoID {
                settings.languageModelID = nil
            }
            if settings.imageGenerationModelID == localModel.repoID {
                settings.imageGenerationModelID = nil
            }
            if settings.textToSpeechModelID == localModel.repoID {
                settings.textToSpeechModelID = nil
            }
            if settings.speechToTextModelID == localModel.repoID {
                settings.speechToTextModelID = nil
            }
            model.settings = settings
            NotificationCenter.default.post(name: .localModelLibraryDidChange, object: nil)
        }
    }

    private var filteredLocalModels: [LocalModel] {
        let query = localQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var models =
            query.isEmpty
            ? localLibrary.models
            : localLibrary.models.filter {
                $0.repoID.localizedCaseInsensitiveContains(query)
                    || $0.displayName.localizedCaseInsensitiveContains(query)
                    || $0.provider?.displayName.localizedCaseInsensitiveContains(query) == true
            }

        models = models.filter { typeFilter.matches($0.capabilities) }

        let settings = modelState.settings.normalized()
        let selectedModelIDs = Set(
            ModelPreloadSlot.allCases.compactMap {
                settings.modelID(for: $0)
            })
        return models.enumerated().sorted { lhs, rhs in
            let lhsIsSelected = selectedModelIDs.contains(lhs.element.repoID)
            let rhsIsSelected = selectedModelIDs.contains(rhs.element.repoID)
            if lhsIsSelected != rhsIsSelected {
                return lhsIsSelected
        }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private var installedModelIDs: Set<String> {
        Set(localLibrary.models.map(\.repoID))
    }

    private var pageTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Models")
                .font(.title2.weight(.semibold))
            Text("Manage local MLX models or find new ones on Hugging Face.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var sectionPicker: some View {
        Picker("Section", selection: $section) {
            ForEach(ModelsPageSection.allCases) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 230, alignment: .leading)
    }

    private var activeSearchQuery: Binding<String> {
        Binding(
            get: { renderedSection == .installed ? localQuery : hubQuery },
            set: { newValue in
                if renderedSection == .installed {
                    localQuery = newValue
                } else {
                    hubQuery = newValue
                }
            }
        )
    }

    private var settingsBinding: Binding<NativSettings> {
        Binding(
            get: { modelState.settings },
            set: { model.settings = $0 }
        )
    }

    private var typeFilterPicker: some View {
        Picker("Filter", selection: $typeFilter) {
            ForEach(ModelsTypeFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var discoverFilterBar: some View {
        HStack(spacing: 12) {
            hubSortPicker
            hubSortDirectionPicker
            hubCapabilityPicker
            hubAccessPicker
            Spacer(minLength: 8)
            shownModelCount
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hubSortPicker: some View {
        Picker("Sort by", selection: $hubSort) {
            ForEach(HuggingFaceModelSort.allCases) { sort in
                Label(sort.displayName, systemImage: sort.systemImage)
                    .tag(sort)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var hubSortDirectionPicker: some View {
        Picker("Order", selection: $hubSortDirection) {
            ForEach(HuggingFaceSortDirection.allCases) { direction in
                Label(direction.displayName, systemImage: direction.systemImage)
                    .tag(direction)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var hubCapabilityPicker: some View {
        HStack(spacing: 8) {
            Text("Capability")

            Menu {
                Button {
                    hubCapabilityFilters.removeAll()
                } label: {
                    if hubCapabilityFilters.isEmpty {
                        Label("All capabilities", systemImage: "checkmark")
                    } else {
                        Text("All capabilities")
                    }
                }

                Divider()

                Section("Tasks") {
                    ForEach(LocalModelCapability.discoverTaskFilters, id: \.self) { capability in
                        Toggle(
                            capability.displayName,
                            isOn: capabilitySelectionBinding(for: capability)
                        )
                    }
                }

                Section("Features") {
                    ForEach(LocalModelCapability.discoverFeatureFilters, id: \.self) { capability in
                        Toggle(
                            capability.displayName,
                            isOn: capabilitySelectionBinding(for: capability)
                        )
                    }
                }
            } label: {
                Text(capabilityFilterTitle)
                    .frame(minWidth: 130, alignment: .leading)
            }
            .menuStyle(.button)
        }
        .fixedSize()
    }

    private var capabilityFilterTitle: String {
        switch hubCapabilityFilters.count {
        case 0:
            "All capabilities"
        case 1:
            hubCapabilityFilters.first?.displayName ?? "All capabilities"
        default:
            "\(hubCapabilityFilters.count) selected"
        }
    }

    private func capabilitySelectionBinding(
        for capability: LocalModelCapability
    ) -> Binding<Bool> {
        Binding(
            get: { hubCapabilityFilters.contains(capability) },
            set: { isSelected in
                if isSelected {
                    hubCapabilityFilters.insert(capability)
                } else {
                    hubCapabilityFilters.remove(capability)
                }
            }
        )
    }

    private var hubAccessPicker: some View {
        Picker("Access", selection: $hubAccessFilter) {
            ForEach(HubAccessFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var shownModelCount: some View {
        Text("\(filteredHubModels.count) shown")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var discoverResultsHeader: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 8)
            openHubLink
        }
    }

    private var openHubLink: some View {
        Link(destination: hubModelsURL) {
            Label("Open Hub", systemImage: "arrow.up.right")
                .font(.caption)
        }
        .fixedSize()
    }

    private var hubVisibilityPredicate: (HuggingFaceModel) -> Bool {
        let capabilities = hubCapabilityFilters
        let access = hubAccessFilter
        return { hubModel in
            // Search results are already restricted to the Hub's SafeTensors
            // index. Mixed repositories remain visible; the downloader skips
            // any optional GGUF files they also contain.
            let matchesCapability = HuggingFaceCapabilityFilter.matches(
                hubModel,
                capabilities: capabilities
            )
            let matchesAccess: Bool
            switch access {
            case .all:
                matchesAccess = true
            case .open:
                matchesAccess = !hubModel.isGated && !hubModel.isPrivate
            case .gated:
                matchesAccess = hubModel.isGated
            }
            return matchesCapability && matchesAccess
        }
    }

    private var filteredHubModels: [HuggingFaceModel] {
        hubLibrary.models
    }

    private var installedFilterIsActive: Bool {
        typeFilter != .all
            || !localQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var modelScanPath: String {
        modelState.settings.localModelSearchPaths.cacheKey
    }

    private var sourcesMenu: some View {
        Menu {
            Section("Hugging Face cache") {
                Text(abbreviatedPath(modelState.settings.normalized().modelSearchPath))
            }
            Section("Model folders") {
                ForEach(modelState.settings.normalized().additionalModelSearchPaths, id: \.self) {
                    path in
                    Menu(abbreviatedPath(path)) {
                        Button("Remove", role: .destructive) {
                            removeModelSourceFolder(path)
                        }
                    }
                }
                Button {
                    addModelSourceFolder()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
            }
        } label: {
            Label("Sources", systemImage: "folder")
        }
        .fixedSize()
        .help("Folders scanned for MLX models in addition to the Hugging Face cache")
    }

    private func rescanLocalModels() {
        localLibrary.scan(searchPaths: modelState.settings.localModelSearchPaths)
    }

    private func addModelSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder containing MLX models."
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        model.settings.additionalModelSearchPaths.append(
            (url.path as NSString).abbreviatingWithTildeInPath
        )
    }

    private func removeModelSourceFolder(_ path: String) {
        model.settings.additionalModelSearchPaths.removeAll { $0 == path }
    }

    private func abbreviatedPath(_ path: String) -> String {
        (LocalModelDiscovery.expandedPath(path) as NSString).abbreviatingWithTildeInPath
    }

    private var hubSearchTaskID: HubSearchTaskID {
        HubSearchTaskID(
            section: renderedSection,
            query: hubQuery,
            sort: hubSort,
            direction: hubSortDirection,
            capabilities: hubCapabilityFilters,
            access: hubAccessFilter,
            authenticationToken: modelState.effectiveHuggingFaceToken
        )
    }

    private var hubModelsURL: URL {
        var components = URLComponents(string: "https://huggingface.co/models")!
        var queryItems = [
            URLQueryItem(name: "library", value: "safetensors"),
            URLQueryItem(name: "sort", value: hubSort.hubWebValue),
            URLQueryItem(name: "p", value: String(hubLibrary.pageNumber - 1)),
        ]

        let query = hubQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: query))
        }
        queryItems.append(
            contentsOf:
                hubCapabilityFilters
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.hubQueryItem))

        switch hubAccessFilter {
        case .all:
            break
        case .open:
            queryItems.append(URLQueryItem(name: "gated", value: "false"))
        case .gated:
            queryItems.append(URLQueryItem(name: "gated", value: "true"))
        }

        components.queryItems = queryItems
        return components.url!
    }

}

/// Keeps the editor buffer inside AppKit so typing does not start a SwiftUI
/// transaction. Only a committed query reaches the Models view; remote search
/// uses a longer debounce while local filtering stays within a 100 ms response
/// window and coalesces repeated typing or deletion.
private struct DebouncedModelsSearchField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String
    let identity: ModelsPageSection
    let debounceMilliseconds: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            identity: identity,
            debounceMilliseconds: debounceMilliseconds
        )
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = prompt
        searchField.stringValue = text
        searchField.delegate = context.coordinator
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.commitFromAction(_:))
        searchField.sendsWholeSearchString = true
        searchField.sendsSearchStringImmediately = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        let identityChanged = context.coordinator.identity != identity
        if identityChanged {
            context.coordinator.cancelPendingCommit()
            context.coordinator.identity = identity
        }
        context.coordinator.text = $text
        context.coordinator.debounceMilliseconds = debounceMilliseconds
        searchField.placeholderString = prompt

        // Do not overwrite an in-progress AppKit edit when an unrelated parent
        // update arrives before the query's debounce interval has elapsed.
        if identityChanged {
            searchField.stringValue = text
            searchField.currentEditor()?.string = text
        } else if searchField.currentEditor() == nil, searchField.stringValue != text {
            searchField.stringValue = text
        }
    }

    static func dismantleNSView(_ searchField: NSSearchField, coordinator: Coordinator) {
        coordinator.cancelPendingCommit()
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var identity: ModelsPageSection
        var debounceMilliseconds: Int
        private var pendingCommit: Task<Void, Never>?

        init(
            text: Binding<String>,
            identity: ModelsPageSection,
            debounceMilliseconds: Int
        ) {
            self.text = text
            self.identity = identity
            self.debounceMilliseconds = debounceMilliseconds
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            scheduleCommit(searchField.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            commit(searchField.stringValue)
        }

        @objc func commitFromAction(_ searchField: NSSearchField) {
            commit(searchField.stringValue)
        }

        func cancelPendingCommit() {
            pendingCommit?.cancel()
            pendingCommit = nil
        }

        private func scheduleCommit(_ value: String) {
            cancelPendingCommit()
            pendingCommit = Task { @MainActor [weak self] in
                if let debounceMilliseconds = self?.debounceMilliseconds,
                    debounceMilliseconds > 0
                {
                    do {
                        try await Task.sleep(
                            for: .milliseconds(Int64(debounceMilliseconds)))
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                self?.commit(value)
            }
        }

        private func commit(_ value: String) {
            cancelPendingCommit()
            guard text.wrappedValue != value else { return }
            text.wrappedValue = value
        }
    }
}

private struct ModelReadmePanel: View {
    let selection: ModelReadmeSelection
    @ObservedObject var store: HuggingFaceModelReadmeStore
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color.nativMainContentBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model README")
    }

    private var header: some View {
        HStack(spacing: 12) {
            ModelProviderBadge(provider: selection.provider)

            VStack(alignment: .leading, spacing: 3) {
                Text(modelName(selection.repoID))
                    .font(.headline)
                    .lineLimit(1)
                Text(selection.repoID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Close model details")
            .accessibilityLabel("Close model details")
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if store.modelID != selection.repoID || store.isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading README…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let markdown = store.markdown {
            ScrollView {
                StructuredText(
                    markdown: NativMarkdownFormatting.normalizedMathDelimiters(
                        in: HuggingFaceModelReadmeFormatting.removingDuplicateLeadingTitle(
                            markdown,
                            modelTitle: modelName(selection.repoID)
                        )
                    ),
                    baseURL: readmeAssetBaseURL,
                    syntaxExtensions: [.math]
                )
                .textual.structuredTextStyle(.gitHub)
                .textual.tableStyle(.overflow(relativeWidth: 4))
                .textual.imageAttachmentLoader(.image(relativeTo: readmeAssetBaseURL))
                .textual.overflowMode(.scroll)
                .textual.textSelection(.enabled)
                .font(.system(size: 15))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
        } else {
            ContentUnavailableView {
                Label("README unavailable", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(store.error ?? "This model doesn’t include a README.")
            } actions: {
                if let hubURL {
                    Link("Open on Hugging Face", destination: hubURL)
                }
            }
        }
    }

    private var hubURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(selection.repoID)"
        return components.url
    }

    private var readmeAssetBaseURL: URL {
        if let localSnapshotURL = selection.localSnapshotURL {
            return localSnapshotURL.appendingPathComponent("", isDirectory: true)
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(selection.repoID)/resolve/main/"
        return components.url ?? URL(string: "https://huggingface.co/")!
    }
}

private struct InstalledModelRow: View, @MainActor Equatable {
    let localModel: LocalModel
    let preloadSlots: [ModelPreloadSlot]
    let selectedPreloadSlots: Set<ModelPreloadSlot>
    let preferredPreloadSlot: ModelPreloadSlot?
    let isSelectionDisabled: Bool
    let isModelLoading: Bool
    let modelLoadingPercentage: Int?
    let isReadmeSelected: Bool
    let isDeleting: Bool
    let canDelete: Bool
    let onSetPreload: (ModelPreloadSlot, Bool) -> Void
    let onShowReadme: () -> Void
    let onDelete: () -> Void

    @State private var showsDeleteConfirmation = false
    @State private var showsUnsupportedModelInformation = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.localModel == rhs.localModel
            && lhs.preloadSlots == rhs.preloadSlots
            && lhs.selectedPreloadSlots == rhs.selectedPreloadSlots
            && lhs.preferredPreloadSlot == rhs.preferredPreloadSlot
            && lhs.isSelectionDisabled == rhs.isSelectionDisabled
            && lhs.isModelLoading == rhs.isModelLoading
            && lhs.modelLoadingPercentage == rhs.modelLoadingPercentage
            && lhs.isReadmeSelected == rhs.isReadmeSelected
            && lhs.isDeleting == rhs.isDeleting
            && lhs.canDelete == rhs.canDelete
    }

    private var isSelected: Bool {
        !selectedPreloadSlots.isEmpty
    }

    private var isLoading: Bool {
        isModelLoading
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onShowReadme) {
                HStack(spacing: 14) {
                    ModelProviderBadge(provider: localModel.provider)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Text(modelName(localModel.displayName))
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                            if let sourceLabel = localModel.source.badgeLabel {
                                ModelPill(
                                    title: sourceLabel,
                                    systemImage: "cube",
                                    color: .purple
                                )
                            }
                            if isLoading {
                                ModelPill(
                                    title: modelLoadingPercentage.map { "Loading model · \($0)%" }
                                        ?? "Loading model",
                                    systemImage: "arrow.triangle.2.circlepath",
                                    color: .orange
                                )
                            }
                            if localModel.capabilities.contains(.imageEditing)
                                && !localModel.capabilities.contains(.imageGeneration)
                            {
                                ModelPill(
                                    title: "Loads on demand",
                                    systemImage: "photo.on.rectangle.angled",
                                    color: .accentColor
                                )
                            } else if preloadSlots.isEmpty {
                                ModelPill(
                                    title: "Not supported",
                                    systemImage: "exclamationmark.triangle",
                                    color: .orange
                                )
                            }
                            ForEach(
                                preloadSlots.filter(selectedPreloadSlots.contains)
                            ) { slot in
                                ModelPill(
                                    title: slot.displayName,
                                    systemImage: slot.systemImage,
                                    color: .accentColor
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()

                        Text(localModel.repoID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        HStack(spacing: 6) {
                            if let contextSize = localModel.contextSize {
                                ModelPill(
                                    title: "\(compactContextSize(contextSize)) context",
                                    systemImage: "text.line.first.and.arrowtriangle.forward"
                                )
                            }
                            if let sizeBytes = localModel.sizeBytes {
                                ModelPill(
                                    title: ByteCountFormatter.string(
                                        fromByteCount: sizeBytes, countStyle: .file),
                                    systemImage: "internaldrive"
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()

                        HStack(spacing: 6) {
                            ForEach(LocalModelCapability.visibleModelTags, id: \.self) {
                                capability in
                                if localModel.capabilities.contains(capability) {
                                    CapabilityPill(capability: capability)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Show README for \(localModel.repoID)")
            .accessibilityLabel("Show details for \(localModel.repoID)")

            loadButton

            modelActionsMenu
        }
        .padding(14)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .modelRowBackground(isHighlighted: isReadmeSelected)
        .alert("Model isn’t supported", isPresented: $showsUnsupportedModelInformation) {
            Button("OK", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(
                "\(localModel.repoID) is installed in your Hugging Face cache, but Nativ can’t use it for chat, image generation, text-to-speech, or speech-to-text."
            )
        }
        .alert("Delete \(modelName(localModel.repoID))?", isPresented: $showsDeleteConfirmation) {
            Button("Delete Model", role: .destructive, action: onDelete)
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \(localModel.repoID) from the local Hugging Face cache.")
        }
    }

    @ViewBuilder
    private var modelActionsMenu: some View {
        if isDeleting {
            ProgressView()
                .controlSize(.small)
                .frame(width: 30, height: 30)
                .help("Deleting model")
        } else {
            Menu {
                if let snapshotURL = localModel.snapshotURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([snapshotURL])
                    } label: {
                        Label("Show in Finder", systemImage: "arrow.up.forward.square")
                    }

                    Divider()
                }

                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label("Delete Model…", systemImage: "trash")
                }
                .disabled(!canDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(
                canDelete
                    ? "Model actions"
                    : "Model actions — stop the server before deleting this model"
            )
            .accessibilityLabel("Actions for \(localModel.repoID)")
        }
    }

    @ViewBuilder
    private var loadButton: some View {
        if let preferredPreloadSlot {
            let isLoaded = selectedPreloadSlots.contains(preferredPreloadSlot)
            Button {
                guard !isSelectionDisabled else { return }
                onSetPreload(preferredPreloadSlot, !isLoaded)
            } label: {
                Image(systemName: isLoaded ? "stop.fill" : "play.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isLoaded ? Color.red : Color.accentColor)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSelectionDisabled)
            .help(rowHelp)
            .accessibilityLabel(rowHelp)
            .fixedSize()
        } else {
            Button {
                showsUnsupportedModelInformation = true
            } label: {
                Label("Unavailable", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.secondary.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
            .help(rowHelp)
            .fixedSize()
        }
    }

    private var rowHelp: String {
        if let preferredPreloadSlot,
            selectedPreloadSlots.contains(preferredPreloadSlot)
        {
            return "Unload \(localModel.repoID) from \(preferredPreloadSlot.displayName)"
        }
        if let preferredPreloadSlot {
            return "Preload \(localModel.repoID) for \(preferredPreloadSlot.displayName)"
        }
        return "\(localModel.repoID) has no supported preload role"
    }
}

private struct ActiveDownloadBannerView: View {
    @ObservedObject private var downloadManager = HuggingFaceDownloadManager.shared

    var body: some View {
        if !downloadManager.downloads.isEmpty {
            VStack(spacing: 0) {
                ForEach(downloadManager.downloads) { download in
                    ActiveDownloadBannerRow(
                        download: download,
                        onPauseResume: { toggleDownload(download) },
                        onRemove: { downloadManager.removeDownload(download.modelID) }
                    )
                }
            }
            .background(.regularMaterial)

            Divider()
        }
    }

    private func toggleDownload(_ download: HuggingFaceDownloadManager.ActiveDownload) {
        if download.state == .paused {
            downloadManager.resumeDownload(download.modelID)
        } else {
            downloadManager.pauseDownload(download.modelID)
        }
    }
}

private struct ActiveDownloadBannerRow: View {
    let download: HuggingFaceDownloadManager.ActiveDownload
    let onPauseResume: () -> Void
    let onRemove: () -> Void

    @State private var isConfirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(modelName)
                        .font(.headline)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(statusText)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("\(percentage)%")
                            .bold()
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                }

                Spacer()

                HStack(spacing: 10) {
                    Button(pauseResumeTitle, systemImage: pauseResumeSymbol, action: onPauseResume)
                        .help(pauseResumeTitle)

                    Button(
                        "Remove download",
                        systemImage: "xmark",
                        role: .destructive,
                        action: confirmRemoval
                    )
                    .help("Remove download")
                    .confirmationDialog(
                        "Remove download?",
                        isPresented: $isConfirmingRemoval
                    ) {
                        Button("Remove Download", role: .destructive, action: onRemove)
                            .keyboardShortcut(.defaultAction)
                        Button("Keep Download", role: .cancel) {}
                    } message: {
                        Text("The partial download for \(download.modelID) will be removed from the local cache.")
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.large)
            }

            ProgressView(value: displayedProgress)
                .progressViewStyle(.linear)
                .tint(download.state == .paused ? .secondary : .accentColor)
                .accessibilityLabel("Download progress")
                .accessibilityValue("\(percentage) percent")

            HStack(spacing: 6) {
                Text(byteProgress ?? "Calculating download size…")
                    .monospacedDigit()

                if let speed {
                    Text("·")
                        .accessibilityHidden(true)
                    Text(speed)
                        .monospacedDigit()
                }

                Spacer()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var modelName: String {
        NativFormatting.truncateModelName(
            download.modelID.split(separator: "/").last.map(String.init) ?? download.modelID,
            maxLength: 44
        )
    }

    private var percentage: Int {
        ModelDownloadProgressPresentation.activePercentage(download.progress)
    }

    private var displayedProgress: Double {
        min(max(download.progress, 0), 0.99)
    }

    private var pauseResumeTitle: String {
        download.state == .paused ? "Resume download" : "Pause download"
    }

    private var pauseResumeSymbol: String {
        download.state == .paused ? "play.fill" : "pause.fill"
    }

    private var byteProgress: String? {
        ModelDownloadProgressPresentation.formattedByteProgress(download.metrics)
    }

    private var speed: String? {
        guard download.state == .downloading, download.phase == .downloading else { return nil }
        return ModelDownloadProgressPresentation.formattedSpeed(download.bytesPerSecond)
    }

    private var statusText: String {
        if download.state == .paused {
            return "Paused"
        }
        if ModelDownloadProgressPresentation.isFinalizing(download.progress) {
            return "Finalizing"
        }
        switch download.phase {
        case .preparing: return "Preparing"
        case .downloading: return "Downloading"
        case .finalizing: return "Finalizing"
        case .retrying: return "Retrying"
        }
    }

    private func confirmRemoval() {
        isConfirmingRemoval = true
    }
}

private struct HubModelMemoryFitWarning: Equatable {
    let title: String
    let message: String

    var accessibilityText: String {
        "\(title). \(message)"
    }
}

private struct HubModelRow: View, @MainActor Equatable {
    let model: HuggingFaceModel
    let downloadSizeBytes: Int64?
    let isInstalled: Bool
    let isReadmeSelected: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let isDownloadPaused: Bool
    let downloadError: HuggingFaceDownloadFailure?
    let onShowReadme: () -> Void
    let onDownload: () -> Void
    let onPauseResume: () -> Void
    let onRemoveDownload: () -> Void

    static func == (lhs: HubModelRow, rhs: HubModelRow) -> Bool {
        // Actions are intentionally excluded: they do not affect rendering,
        // while closures are recreated whenever the parent view is rebuilt.
        lhs.model == rhs.model
            && lhs.downloadSizeBytes == rhs.downloadSizeBytes
            && lhs.isInstalled == rhs.isInstalled
            && lhs.isReadmeSelected == rhs.isReadmeSelected
            && lhs.isDownloading == rhs.isDownloading
            && lhs.downloadProgress == rhs.downloadProgress
            && lhs.isDownloadPaused == rhs.isDownloadPaused
            && lhs.downloadError == rhs.downloadError
    }

    private var memoryFitWarning: HubModelMemoryFitWarning? {
        if let estimate = model.memoryEstimate, !estimate.isUsable {
            let required = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: estimate.workingSetBytes),
                countStyle: .memory
            )
            let total = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: estimate.totalMemoryBytes),
                countStyle: .memory
            )
            return HubModelMemoryFitWarning(
                title: "May not fit in memory",
                message: "Needs about \(required); this Mac has \(total). Try a smaller or quantized model."
            )
        }
        if let sizeBytes = model.sizeBytes, sizeBytes > 0 {
            let totalMemoryBytes = ProcessInfo.processInfo.physicalMemory
            let budget = Double(totalMemoryBytes) * (1 - LocalModelMemoryEstimate.headroomFraction)
            if Double(sizeBytes) > budget {
                let size = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .memory)
                let total = ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: totalMemoryBytes), countStyle: .memory)
                return HubModelMemoryFitWarning(
                    title: "May not fit in memory",
                    message: "About \(size) of model data; this Mac has \(total) of memory. Try a smaller or quantized model."
                )
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Button(action: onShowReadme) {
                    HStack(spacing: 14) {
                        ModelProviderBadge(provider: model.provider)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 7) {
                                Text(modelName(model.id))
                                    .font(.body.weight(.semibold))
                                    .lineLimit(1)
                                if model.isGated {
                                    ModelPill(title: "Gated", systemImage: "lock")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clipped()

                            Text(model.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            HStack(spacing: 6) {
                                ModelPill(
                                    title: compactCount(model.downloads),
                                    systemImage: "arrow.down.circle"
                                )
                                ModelPill(title: compactCount(model.likes), systemImage: "heart")
                                if let sizeBytes = downloadSizeBytes {
                                    ModelPill(
                                        title: ByteCountFormatter.string(
                                            fromByteCount: sizeBytes, countStyle: .file),
                                        systemImage: "internaldrive"
                                    )
                                }
                                if let memoryFitWarning {
                                    HubModelMemoryWarningBadge(warning: memoryFitWarning)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clipped()

                            HStack(spacing: 6) {
                                ForEach(
                                    LocalModelCapability.visibleModelTags.filter(
                                        model.capabilities.contains
                                    ),
                                    id: \.self
                                ) { capability in
                                    CapabilityPill(capability: capability)
                                }
                            }
                            // Keep Discover rows the same height so the mounted page has
                            // stable geometry when capability pills are absent.
                            .frame(maxWidth: .infinity, minHeight: 19, alignment: .leading)
                            .clipped()
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                        Spacer(minLength: 12)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .help("Show README for \(model.id)")
                .accessibilityLabel("Show details for \(model.id)")

                if isInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                        .fixedSize()
                } else if isDownloading {
                    ModelDownloadProgressControl(
                        progress: downloadProgress,
                        isPaused: isDownloadPaused,
                        onPauseResume: onPauseResume,
                        onRemove: onRemoveDownload
                    )
                } else {
                    HubModelDownloadButton(
                        isDisabled: model.isPrivate,
                        help: downloadHelp,
                        action: onDownload
                    )
                }
            }

            if let downloadError {
                downloadErrorView(downloadError)
            }
        }
        .padding(14)
        .modelRowBackground(isHighlighted: isReadmeSelected)
    }

    private var downloadHelp: String {
        return model.isGated
            ? "Gated models require Hugging Face authentication."
            : "Download to the configured cache"
    }

    @ViewBuilder
    private func downloadErrorView(_ error: HuggingFaceDownloadFailure) -> some View {
        switch error {
        case .gatedRepository:
            VStack(alignment: .leading, spacing: 6) {
                Label(error.localizedDescription, systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Request access, then add or update the approved account’s token in Developer and retry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(destination: modelHubURL) {
                    Label("Request access on Hugging Face", systemImage: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                }
            }
        case .message:
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    private var modelHubURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(model.id)"
        return components.url ?? URL(string: "https://huggingface.co/")!
    }
}

private struct HubModelMemoryWarningBadge: View {
    let warning: HubModelMemoryFitWarning

    @State private var isTooltipPresented = false
    @State private var pendingTooltip: Task<Void, Never>?

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.red)
            )
            .contentShape(Rectangle())
            .onHover(perform: handleHover)
            .popover(isPresented: $isTooltipPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(warning.title, systemImage: "memorychip")
                        .font(.subheadline.weight(.semibold))

                    Text(warning.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 230, alignment: .leading)
                .padding(10)
            }
            .accessibilityLabel("Memory warning")
            .accessibilityValue(warning.accessibilityText)
            .onDisappear {
                pendingTooltip?.cancel()
                pendingTooltip = nil
                isTooltipPresented = false
            }
    }

    private func handleHover(_ isHovering: Bool) {
        pendingTooltip?.cancel()
        pendingTooltip = nil

        guard isHovering else {
            isTooltipPresented = false
            return
        }

        pendingTooltip = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            isTooltipPresented = true
        }
    }
}

/// Avoid the platform bordered-button style inside every Discover row. On
/// macOS that style installs scroll-edge behavior and adds substantial view-list
/// work while the containing scroll view moves.
private struct HubModelDownloadButton: View {
    let isDisabled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Download", systemImage: "arrow.down.circle")
                .font(.callout.weight(.medium))
                .foregroundStyle(isDisabled ? Color.secondary : Color.white)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isDisabled ? Color.secondary.opacity(0.12) : Color.accentColor)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
        .accessibilityLabel("Download model")
        .fixedSize()
    }
}

private struct HubPaginationButton: View {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .foregroundStyle(isDisabled ? Color.secondary.opacity(0.55) : Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.secondary.opacity(isDisabled ? 0.06 : 0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(title)
        .fixedSize()
    }
}

/// Keeps download progress observation local to the affected row. The parent
/// Discover view remains stable while a download reports progress.
private struct HubModelRowContainer: View, @MainActor Equatable {
    private let downloadManager = HuggingFaceDownloadManager.shared
    @State private var downloadSnapshot: HuggingFaceDownloadManager.RowSnapshot

    let model: HuggingFaceModel
    let isInstalled: Bool
    let isReadmeSelected: Bool
    let onShowReadme: () -> Void
    let onDownload: (Int64?) -> Void
    let onPauseResume: () -> Void
    let onRemoveDownload: () -> Void

    init(
        model: HuggingFaceModel,
        isInstalled: Bool,
        isReadmeSelected: Bool,
        onShowReadme: @escaping () -> Void,
        onDownload: @escaping (Int64?) -> Void,
        onPauseResume: @escaping () -> Void,
        onRemoveDownload: @escaping () -> Void
    ) {
        self.model = model
        self.isInstalled = isInstalled
        self.isReadmeSelected = isReadmeSelected
        self.onShowReadme = onShowReadme
        self.onDownload = onDownload
        self.onPauseResume = onPauseResume
        self.onRemoveDownload = onRemoveDownload
        _downloadSnapshot = State(
            initialValue: HuggingFaceDownloadManager.shared.rowSnapshot(for: model.id)
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model
            && lhs.isInstalled == rhs.isInstalled
            && lhs.isReadmeSelected == rhs.isReadmeSelected
    }

    var body: some View {
        let downloadSizeBytes = model.estimatedDownloadBytes
        HubModelRow(
            model: model,
            downloadSizeBytes: downloadSizeBytes,
            isInstalled: isInstalled,
            isReadmeSelected: isReadmeSelected,
            isDownloading: downloadSnapshot.isDownloading,
            downloadProgress: downloadSnapshot.progress,
            isDownloadPaused: downloadSnapshot.isPaused,
            downloadError: downloadSnapshot.error,
            onShowReadme: onShowReadme,
            onDownload: {
                onDownload(downloadSizeBytes)
            },
            onPauseResume: onPauseResume,
            onRemoveDownload: onRemoveDownload
        )
        .equatable()
        .onReceive(downloadManager.rowUpdates) { updatedModelID in
            guard updatedModelID == nil || updatedModelID == model.id else { return }
            let snapshot = downloadManager.rowSnapshot(for: model.id)
            guard snapshot != downloadSnapshot else { return }
            downloadSnapshot = snapshot
        }
    }
}

struct ModelDownloadProgressControl: View {
    let progress: Double
    let isPaused: Bool
    let onPauseResume: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false
    @State private var isConfirmingRemoval = false

    var body: some View {
        ZStack {
            if isHovering {
                HStack(spacing: 6) {
                    ModelDownloadActionButton(
                        title: isPaused ? "Resume download" : "Pause download",
                        systemImage: isPaused ? "play.fill" : "pause.fill",
                        tint: isPaused ? .green : .orange,
                        action: onPauseResume
                    )

                    ModelDownloadActionButton(
                        title: "Remove download",
                        systemImage: "trash",
                        tint: .red,
                        action: { isConfirmingRemoval = true }
                    )
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                progressRing
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: 74, height: 36)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.16), value: isHovering)
        .animation(.easeOut(duration: 0.18), value: displayedProgress)
        .help(
            progressDescription
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(progressDescription)
        .accessibilityValue(
            "\(ModelDownloadProgressPresentation.activePercentage(progress)) percent"
        )
        .alert("Remove download?", isPresented: $isConfirmingRemoval) {
            Button("Remove Download", role: .destructive, action: onRemove)
                .keyboardShortcut(.defaultAction)
            Button("Keep Download", role: .cancel) {}
        } message: {
            Text("The partial download will be removed from the local cache.")
        }
    }

    private var displayedProgress: Double {
        ModelDownloadProgressPresentation.ringProgress(progress)
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.16), lineWidth: 3)

            Circle()
                .trim(from: 0, to: displayedProgress)
                .stroke(
                    isPaused ? Color.orange : Color.accentColor,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            if progress > 0 {
                Text("\(ModelDownloadProgressPresentation.activePercentage(progress))%")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
            } else {
                Image(systemName: isPaused ? "pause.fill" : "arrow.down")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .frame(width: 34, height: 34)
    }

    private var progressDescription: String {
        if isPaused {
            return "Download paused"
        }
        if ModelDownloadProgressPresentation.isFinalizing(progress) {
            return "Finalizing download"
        }
        return "Downloading \(ModelDownloadProgressPresentation.activePercentage(progress)) percent"
    }
}

private struct ModelDownloadActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    var isDisabled = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    isDisabled
                        ? Color.secondary.opacity(0.45) : (isHovering ? tint : Color.secondary)
                )
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            isHovering && !isDisabled
                                ? tint.opacity(0.13) : Color.secondary.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 && !isDisabled }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct ModelProviderBadge: View {
    let provider: LocalModelProvider?
    var isHighlighted = false
    @Environment(\.colorScheme) private var colorScheme

    private var color: Color {
        provider?.modelBadgeColor ?? .secondary
    }

    private var backgroundColor: Color {
        if provider?.needsLightIconBackgroundInDarkMode == true, colorScheme == .dark {
            return Color.white.opacity(0.92)
        }
        if isHighlighted {
            return Color(nsColor: .controlBackgroundColor)
        }
        if provider?.preservesIconColors == true {
            return Color.secondary.opacity(0.10)
        }
        return color.opacity(0.14)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(backgroundColor)

            if let provider, let image = LocalModelProviderIcon.image(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(color)
                    .frame(width: 25, height: 25)
                    .accessibilityLabel(provider.displayName)
            } else if let provider {
                Text(provider.monogram)
                    .font(.system(size: provider.monogram.count > 2 ? 9 : 12, weight: .bold))
                    .foregroundStyle(color)
            } else {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 46, height: 46)
        .help(provider?.displayName ?? "Unknown provider")
    }
}

private struct ModelPill: View {
    let title: String
    let systemImage: String
    var color: Color = .secondary

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.10)))
            .fixedSize()
    }
}

private struct CapabilityPill: View {
    let capability: LocalModelCapability

    var body: some View {
        ModelPill(title: capability.displayName, systemImage: capability.systemImage)
    }
}

private struct ModelsNotice: View {
    let title: String
    let message: String
    let systemImage: String
    let color: Color
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
    }
}

private struct ModelsLoadingState: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

private struct ModelsEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

private struct ModelRowBackground: ViewModifier {
    let isHighlighted: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
    }

    private var backgroundColor: Color {
        if isHovered {
            return Color.accentColor.opacity(0.08)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var borderColor: Color {
        if isHighlighted {
            return Color.accentColor.opacity(0.90)
        }
        if isHovered {
            return Color.accentColor.opacity(0.40)
        }
        return Color(nsColor: .separatorColor)
    }

    private var borderWidth: CGFloat {
        isHighlighted ? 1.5 : (isHovered ? 1 : 0.5)
    }
}

extension View {
    fileprivate func modelRowBackground(isHighlighted: Bool, isHovered: Bool = false) -> some View {
        modifier(ModelRowBackground(isHighlighted: isHighlighted, isHovered: isHovered))
    }

    fileprivate func modelsListRow(
        top: CGFloat = 5,
        bottom: CGFloat = 5
    ) -> some View {
        padding(.horizontal, 22)
            .padding(.top, top)
            .padding(.bottom, bottom)
    }

}

extension LocalModelCapability {
    fileprivate static let visibleModelTags = allCases.filter { $0 != .text }

    fileprivate static let discoverTaskFilters: [Self] = [
        .text,
        .vision,
        .audio,
        .video,
        .imageGeneration,
        .imageEditing,
        .speechToText,
        .textToSpeech,
        .embeddings,
        .reranking,
    ]

    fileprivate static let discoverFeatureFilters: [Self] = [
        .reasoning,
        .tools,
        .drafter,
    ]

    fileprivate var hubQueryItem: URLQueryItem {
        switch self {
        case .text:
            URLQueryItem(name: "pipeline_tag", value: "text-generation")
        case .vision:
            URLQueryItem(name: "pipeline_tag", value: "image-text-to-text")
        case .audio:
            URLQueryItem(name: "other", value: "audio")
        case .video:
            URLQueryItem(name: "other", value: "video")
        case .imageGeneration:
            URLQueryItem(name: "pipeline_tag", value: "text-to-image")
        case .imageEditing:
            URLQueryItem(name: "pipeline_tag", value: "image-to-image")
        case .speechToText:
            URLQueryItem(name: "pipeline_tag", value: "automatic-speech-recognition")
        case .textToSpeech:
            URLQueryItem(name: "pipeline_tag", value: "text-to-speech")
        case .embeddings:
            URLQueryItem(name: "pipeline_tag", value: "feature-extraction")
        case .reranking:
            URLQueryItem(name: "pipeline_tag", value: "text-ranking")
        case .reasoning:
            URLQueryItem(name: "other", value: "reasoning")
        case .tools:
            URLQueryItem(name: "other", value: "tool-calling")
        case .drafter:
            URLQueryItem(name: "other", value: "draft-model")
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .vision: "eye"
        case .audio: "waveform"
        case .video: "film"
        case .imageGeneration: "photo.badge.plus"
        case .imageEditing: "photo.on.rectangle.angled"
        case .speechToText: "captions.bubble"
        case .textToSpeech: "speaker.wave.2"
        case .embeddings: "circle.grid.3x3"
        case .reranking: "arrow.up.arrow.down.circle"
        case .reasoning: "brain.fill"
        case .tools: "hammer"
        case .drafter: "hare"
        }
    }
}

extension LocalModelProvider {
    fileprivate var modelBadgeColor: Color {
        switch self {
        case .google:
            .primary
        case .openAI:
            .primary
        case .meta:
            Color(red: 0 / 255, green: 129 / 255, blue: 251 / 255)
        case .mistral:
            .primary
        case .qwen:
            Color(red: 0 / 255, green: 46 / 255, blue: 254 / 255)
        case .microsoft:
            .primary
        case .cohere:
            .primary
        case .deepSeek:
            Color(red: 79 / 255, green: 112 / 255, blue: 255 / 255)
        case .ai2:
            Color(red: 255 / 255, green: 103 / 255, blue: 170 / 255)
        case .openBMB:
            Color(red: 68 / 255, green: 119 / 255, blue: 255 / 255)
        case .openMOSS:
            .primary
        case .poolside:
            .primary
        case .prismML:
            .primary
        case .blackForestLabs:
            .primary
        case .nvidia:
            Color(red: 118 / 255, green: 185 / 255, blue: 0 / 255)
        case .apple:
            .primary
        case .ibm:
            Color(red: 15 / 255, green: 98 / 255, blue: 254 / 255)
        case .liquidAI:
            .primary
        case .zAI:
            .primary
        case .inclusionAI:
            .primary
        case .miniMax:
            .primary
        case .baidu:
            .primary
        case .moonshotAI:
            .primary
        case .stabilityAI:
            .primary
        case .thinkingMachines:
            .primary
        case .meituanLongCat:
            .primary
        }
    }
}

private func modelName(_ repoID: String) -> String {
    repoID.split(separator: "/").last.map(String.init) ?? repoID
}

private func compactContextSize(_ value: Int) -> String {
    let million = 1024 * 1024
    if value >= million, value.isMultiple(of: million) { return "\(value / million)M" }
    if value >= 1024, value.isMultiple(of: 1024) { return "\(value / 1024)K" }
    return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
}

private func compactCount(_ value: Int) -> String {
    if value >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(
            of: ".0M", with: "M")
    }
    if value >= 1_000 {
        return String(format: "%.1fK", Double(value) / 1_000).replacingOccurrences(
            of: ".0K", with: "K")
    }
    return "\(value)"
}

#Preview {
    ModelsView(model: .init(), showsConfiguration: .constant(true))
        .frame(width: 850, height: 680)
}
