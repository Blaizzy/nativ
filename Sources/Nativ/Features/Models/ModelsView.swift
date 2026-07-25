import AppKit
import SwiftUI

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

    var id: String { rawValue }

    func matches(_ capabilities: Set<LocalModelCapability>) -> Bool {
        switch self {
        case .all:
            true
        case .language:
            capabilities.contains(.text)
        case .image:
            capabilities.contains(.imageGeneration)
        case .speech:
            !capabilities.isDisjoint(with: [.audio, .speechToText, .textToSpeech])
        }
    }

}

private struct HubSearchTaskID: Hashable {
    let section: ModelsPageSection
    let query: String
    let sort: HuggingFaceModelSort
    let authenticationToken: String?
}

struct ModelsView: View {
    @ObservedObject var model: NativModel
    @Binding var showsConfiguration: Bool
    var titleLeadingInset: CGFloat = 0
    @StateObject private var localLibrary = LocalModelLibrary()
    @StateObject private var hubLibrary = HuggingFaceModelLibrary()
    @ObservedObject private var downloadManager = HuggingFaceDownloadManager.shared
    @State private var section: ModelsPageSection = .installed
    @State private var typeFilter: ModelsTypeFilter = .all
    @State private var localQuery = ""
    @State private var hubQuery = ""
    @State private var hubSort: HuggingFaceModelSort = .downloads
    @State private var hubCapabilityFilters = Set<LocalModelCapability>()
    @State private var hubAccessFilter: HubAccessFilter = .all

    var body: some View {
        ModelConfigurationLayout(
            model: model,
            isConfigurationVisible: $showsConfiguration
        ) {
            VStack(spacing: 0) {
                pageHeader
                Divider()

                switch section {
                case .installed:
                    installedPage
                case .discover:
                    discoverPage
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: modelScanPath) {
            rescanLocalModels()
        }
        .task(id: hubSearchTaskID) {
            guard section == .discover else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            hubLibrary.search(
                query: hubQuery,
                sort: hubSort,
                token: model.effectiveHuggingFaceToken
            )
        }
        .onDisappear {
            localLibrary.cancel()
            hubLibrary.cancel()
        }
    }

    private var pageHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                pageTitle
                Spacer(minLength: 12)
                sectionPicker
            }

            VStack(alignment: .leading, spacing: 12) {
                pageTitle
                HStack {
                    Spacer()
                    sectionPicker
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.leading, titleLeadingInset)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var installedPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ModelsSearchField(prompt: "Search installed models", text: $localQuery)

                typeFilterPicker

                sourcesMenu

                Button {
                    rescanLocalModels()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(localLibrary.isScanning)

            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let error = localLibrary.error {
                        ModelsNotice(
                            title: "Couldn’t read the model cache",
                            message: error,
                            systemImage: "exclamationmark.triangle.fill",
                            color: .orange
                        )
                    }

                    if localLibrary.isScanning && localLibrary.models.isEmpty {
                        ModelsLoadingState(title: "Scanning your Hugging Face cache…")
                    } else if filteredLocalModels.isEmpty {
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
                    } else {
                        HStack {
                            Text(
                                "\(filteredLocalModels.count) \(filteredLocalModels.count == 1 ? "model" : "models")"
                            )
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if localLibrary.isScanning {
                                ProgressView().controlSize(.small)
                            }
                        }

                        ForEach(filteredLocalModels) { localModel in
                            let preloadSlots = preloadSlots(for: localModel)
                            InstalledModelRow(
                                localModel: localModel,
                                preloadSlots: preloadSlots,
                                selectedPreloadSlots: selectedPreloadSlots(
                                    for: localModel.repoID
                                ),
                                preferredPreloadSlot: preferredPreloadSlot(
                                    among: preloadSlots
                                ),
                                isSelectionDisabled: model.modelSwitchInProgress,
                                isModelLoading: model.modelLoadingID
                                    == localModel.repoID,
                                modelLoadingPercentage: model.modelLoadingPercentage,
                                isDeleting: localLibrary.deletingModelIDs.contains(
                                    localModel.repoID),
                                canDelete: localModel.isDeletable && !model.modelSwitchInProgress
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
                                onDelete: { deleteInstalledModel(localModel) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
    }

    private var discoverPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    ModelsSearchField(prompt: "Search models on Hugging Face", text: $hubQuery)

                    if hubLibrary.isSearching {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 28)
                    }
                }

                discoverFilterBar
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let error = hubLibrary.error {
                        ModelsNotice(
                            title: "Hugging Face is unavailable",
                            message: error,
                            systemImage: "wifi.exclamationmark",
                            color: .orange
                        )
                    } else if hubLibrary.isSearching && hubLibrary.models.isEmpty {
                        ModelsLoadingState(
                            title: hubQuery.isEmpty
                                ? "Finding popular Safetensors models…" : "Searching Hugging Face…")
                    } else if hubLibrary.models.isEmpty {
                        ModelsEmptyState(
                            systemImage: "magnifyingglass",
                            title: "No Safetensors models found",
                            message: "Try a model family, provider, or repository name.",
                            actionTitle: nil,
                            action: {}
                        )
                    } else {
                        discoverResultsHeader

                        if filteredHubModels.isEmpty {
                            ModelsEmptyState(
                                systemImage: "line.3.horizontal.decrease.circle",
                                title: "No models match these filters",
                                message:
                                    "Try another model type, capability, or access filter, or continue to the next page.",
                                actionTitle: nil,
                                action: {}
                            )
                        } else {
                            ForEach(filteredHubModels) { hubModel in
                                HubModelRow(
                                    model: hubModel,
                                    isInstalled: installedModelIDs.contains(hubModel.id),
                                    isDownloading: downloadManager.downloadingModelID
                                        == hubModel.id,
                                    downloadProgress: downloadManager.downloadingModelID
                                        == hubModel.id
                                        ? downloadManager.downloadProgress
                                        : 0,
                                    isDownloadPaused: downloadManager.downloadingModelID
                                        == hubModel.id
                                        && downloadManager.isDownloadPaused,
                                    anotherDownloadIsActive: downloadManager.downloadingModelID
                                        != nil,
                                    downloadError: downloadManager.errorByModelID[hubModel.id],
                                    onDownload: {
                                        downloadManager.download(
                                            repoID: hubModel.id,
                                            cachePath: model.settings.modelSearchPath,
                                            token: model.effectiveHuggingFaceToken
                                        ) {
                                            rescanLocalModels()
                                            NotificationCenter.default.post(
                                                name: .localModelLibraryDidChange,
                                                object: nil
                                            )
                                        }
                                    },
                                    onPauseResume: {
                                        if downloadManager.isDownloadPaused {
                                            downloadManager.resumeDownload()
                                        } else {
                                            downloadManager.pauseDownload()
                                        }
                                    },
                                    onRemoveDownload: {
                                        downloadManager.removeDownload()
                                    }
                                )
                            }
                        }

                        HStack(spacing: 12) {
                            Spacer()

                            Button {
                                hubLibrary.goToPreviousPage()
                            } label: {
                                Label("Previous", systemImage: "chevron.left")
                            }
                            .disabled(!hubLibrary.canGoToPreviousPage)

                            Text("Page \(hubLibrary.pageNumber) of up to 5")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 122)

                            Button {
                                hubLibrary.goToNextPage(token: model.effectiveHuggingFaceToken)
                            } label: {
                                Label("Next", systemImage: "chevron.right")
                                    .labelStyle(.titleAndIcon)
                            }
                            .disabled(!hubLibrary.canGoToNextPage)

                            Spacer()
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
    }

    private func isModelInUse(_ repoID: String) -> Bool {
        guard model.isRunning else { return false }
        let settings = model.settings.normalized()
        let configuredModelIDs = [
            settings.languageModelID,
            settings.imageGenerationModelID,
            settings.textToSpeechModelID,
            settings.speechToTextModelID,
            model.metrics?.server.loadedModel,
        ]
        return configuredModelIDs.contains(repoID)
    }

    private func preloadSlots(for localModel: LocalModel) -> [ModelPreloadSlot] {
        var slots: [ModelPreloadSlot] = []
        if localModel.capabilities.contains(.text) {
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
        return slots
    }

    private func selectedPreloadSlots(
        for repoID: String
    ) -> Set<ModelPreloadSlot> {
        let settings = model.settings.normalized()
        return Set(
            ModelPreloadSlot.allCases.filter {
                settings.modelID(for: $0) == repoID
            })
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
            path: model.settings.modelSearchPath
        ) {
            var settings = model.settings
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

        let settings = model.settings.normalized()
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
        .frame(width: 230)
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                hubSortPicker
                hubCapabilityPicker
                hubAccessPicker
                Spacer(minLength: 8)
                shownModelCount
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    hubSortPicker
                    Spacer(minLength: 8)
                    shownModelCount
                }
                HStack(spacing: 12) {
                    hubCapabilityPicker
                    hubAccessPicker
                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                hubSortPicker
                hubCapabilityPicker
                hubAccessPicker
                shownModelCount
            }
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

                ForEach(
                    LocalModelCapability.visibleModelTags.filter { $0 != .embeddings },
                    id: \.self
                ) { capability in
                    Toggle(
                        capability.displayName,
                        isOn: capabilitySelectionBinding(for: capability)
                    )
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                discoverResultsTitle
                Spacer(minLength: 8)
                discoverSortStatus
                openHubLink
            }

            VStack(alignment: .leading, spacing: 6) {
                discoverResultsTitle
                HStack(spacing: 12) {
                    discoverSortStatus
                    Spacer(minLength: 8)
                    openHubLink
                }
            }
        }
    }

    private var discoverResultsTitle: some View {
        Text(hubQuery.isEmpty ? "Safetensors models on Hugging Face" : "Search results")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var discoverSortStatus: some View {
        Label("Sorted by \(hubSort.displayName.lowercased())", systemImage: hubSort.systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var openHubLink: some View {
        Link(destination: hubModelsURL) {
            Label("Open Hub", systemImage: "arrow.up.right")
                .font(.caption)
        }
        .fixedSize()
    }

    private var filteredHubModels: [HuggingFaceModel] {
        hubLibrary.models.filter { hubModel in
            let matchesCapability = hubCapabilityFilters.allSatisfy {
                hubModel.capabilities.contains($0)
            }
            let matchesAccess: Bool
            switch hubAccessFilter {
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

    private var installedFilterIsActive: Bool {
        typeFilter != .all
            || !localQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var modelScanPath: String {
        let settings = model.settings.normalized()
        return ([settings.expandedModelSearchPath] + settings.additionalModelSearchPaths)
            .joined(separator: "\u{0}")
    }

    private var sourcesMenu: some View {
        Menu {
            Section("Hugging Face cache") {
                Text(abbreviatedPath(model.settings.normalized().modelSearchPath))
            }
            Section("Model folders") {
                ForEach(model.settings.normalized().additionalModelSearchPaths, id: \.self) {
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
        localLibrary.scan(
            path: model.settings.modelSearchPath,
            additionalPaths: model.settings.normalized().additionalModelSearchPaths
        )
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
            section: section,
            query: hubQuery,
            sort: hubSort,
            authenticationToken: model.effectiveHuggingFaceToken
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

private struct ModelsSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

private struct InstalledModelRow: View {
    let localModel: LocalModel
    let preloadSlots: [ModelPreloadSlot]
    let selectedPreloadSlots: Set<ModelPreloadSlot>
    let preferredPreloadSlot: ModelPreloadSlot?
    let isSelectionDisabled: Bool
    let isModelLoading: Bool
    let modelLoadingPercentage: Int?
    let isDeleting: Bool
    let canDelete: Bool
    let onSetPreload: (ModelPreloadSlot, Bool) -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var showsDeleteConfirmation = false

    private var isSelected: Bool {
        !selectedPreloadSlots.isEmpty
    }

    private var isLoading: Bool {
        isModelLoading
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                guard let preferredPreloadSlot,
                    !isSelectionDisabled
                else {
                    return
                }
                onSetPreload(
                    preferredPreloadSlot,
                    !selectedPreloadSlots.contains(preferredPreloadSlot)
                )
            } label: {
                HStack(spacing: 14) {
                    ModelProviderBadge(provider: localModel.provider, isHighlighted: isSelected)

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

                        HStack(spacing: 6) {
                            ForEach(LocalModelCapability.visibleModelTags, id: \.self) {
                                capability in
                                if localModel.capabilities.contains(capability) {
                                    CapabilityPill(capability: capability)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(rowHelp)
            .accessibilityLabel(rowHelp)

            if isDeleting {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 30, height: 30)
                    .help("Deleting model")
            } else if let snapshotURL = localModel.snapshotURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([snapshotURL])
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .accessibilityLabel("Show \(localModel.repoID) in Finder")
            }

            ModelDownloadActionButton(
                title: canDelete
                    ? "Delete installed model"
                    : "Stop the server before deleting this model",
                systemImage: "trash",
                tint: .red,
                isDisabled: !canDelete || isDeleting
            ) {
                showsDeleteConfirmation = true
            }
        }
        .padding(14)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .modelRowBackground(isHighlighted: isSelected, isHovered: isHovered)
        .alert("Delete \(modelName(localModel.repoID))?", isPresented: $showsDeleteConfirmation) {
            Button("Delete Model", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \(localModel.repoID) from the local Hugging Face cache.")
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

private struct HubModelRow: View {
    let model: HuggingFaceModel
    let isInstalled: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let isDownloadPaused: Bool
    let anotherDownloadIsActive: Bool
    let downloadError: String?
    let onDownload: () -> Void
    let onPauseResume: () -> Void
    let onRemoveDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                        if let memoryEstimate = model.memoryEstimate, !memoryEstimate.isUsable {
                            ModelPill(
                                title: "May not fit in memory",
                                systemImage: "exclamationmark.triangle.fill",
                                color: .orange
                            )
                            .help("Pre-download estimate. \(memoryEstimate.explanation)")
                        }
                    }

                    Text(model.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        ModelPill(
                            title: compactCount(model.downloads), systemImage: "arrow.down.circle")
                        ModelPill(title: compactCount(model.likes), systemImage: "heart")
                        if let sizeBytes = model.sizeBytes {
                            ModelPill(
                                title: ByteCountFormatter.string(
                                    fromByteCount: sizeBytes, countStyle: .file),
                                systemImage: "internaldrive"
                            )
                        }
                    }

                    if !model.capabilities.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(LocalModelCapability.visibleModelTags, id: \.self) {
                                capability in
                                if model.capabilities.contains(capability) {
                                    CapabilityPill(capability: capability)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 12)

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
                    Button(action: onDownload) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(anotherDownloadIsActive || model.isPrivate)
                    .help(
                        model.isGated
                            ? "Gated models require Hugging Face authentication."
                            : "Download to the configured cache"
                    )
                        .fixedSize()
                }
            }

            if let downloadError {
                Label(downloadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .modelRowBackground(isHighlighted: false)
    }
}

private struct ModelDownloadProgressControl: View {
    let progress: Double
    let isPaused: Bool
    let onPauseResume: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

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
                        action: onRemove
                    )
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
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
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    } else {
                        Image(systemName: isPaused ? "pause.fill" : "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .frame(width: 34, height: 34)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: 74, height: 36)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.16), value: isHovering)
        .animation(.easeOut(duration: 0.18), value: displayedProgress)
        .help(
            isPaused ? "Download paused" : "Downloading \(Int((progress * 100).rounded())) percent"
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isPaused ? "Download paused" : "Download progress")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }

    private var displayedProgress: Double {
        min(max(progress, 0.025), 1)
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
        if isHighlighted {
            return Color.accentColor.opacity(0.38)
        }
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
}

extension LocalModelCapability {
    fileprivate static let visibleModelTags = allCases.filter { $0 != .text }

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
        case .speechToText:
            URLQueryItem(name: "pipeline_tag", value: "automatic-speech-recognition")
        case .textToSpeech:
            URLQueryItem(name: "pipeline_tag", value: "text-to-speech")
        case .embeddings:
            URLQueryItem(name: "pipeline_tag", value: "feature-extraction")
        case .reasoning:
            URLQueryItem(name: "other", value: "reasoning")
        case .tools:
            URLQueryItem(name: "other", value: "tool-calling")
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .vision: "eye"
        case .audio: "waveform"
        case .video: "film"
        case .imageGeneration: "photo.badge.plus"
        case .speechToText: "captions.bubble"
        case .textToSpeech: "speaker.wave.2"
        case .embeddings: "circle.grid.3x3"
        case .reasoning: "brain.fill"
        case .tools: "hammer"
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
