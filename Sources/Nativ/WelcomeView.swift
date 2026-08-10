import AppKit
import SwiftUI

enum WelcomePreferences {
    static let completionKey = "hasCompletedWelcome1"

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completionKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completionKey)
    }
}

struct WelcomeGateView: View {
    @AppStorage(WelcomePreferences.completionKey) private var hasCompletedWelcome = false

    @ObservedObject var model: NativModel
    @ObservedObject var navigation: ControlPanelNavigation
    @ObservedObject var runtime: SystemRuntimeMonitor
    @ObservedObject var extensionManager: NativExtensionManager
    let softwareUpdater: SoftwareUpdater
    let onComplete: (_ modelID: String?, _ serverAPIKey: String?) -> Void

    var body: some View {
        Group {
            if hasCompletedWelcome {
                ControlPanelView(
                    model: model,
                    navigation: navigation,
                    runtime: runtime,
                    extensionManager: extensionManager,
                    softwareUpdater: softwareUpdater
                )
            } else {
                WelcomeView(model: model) { modelID, serverAPIKey in
                    onComplete(modelID, serverAPIKey)
                    hasCompletedWelcome = true
                }
                .transition(.opacity)
            }
        }
        .textSelection(.enabled)
        .animation(.easeInOut(duration: 0.25), value: hasCompletedWelcome)
    }
}

enum WelcomeModelTier: String, CaseIterable, Identifiable {
    case fast = "Fast"
    case balanced = "Balanced"
    case smart = "Smart"

    var id: Self { self }

    var summary: String {
        switch self {
        case .fast:
            return "Small and quick — runs on any Mac"
        case .balanced:
            return "A capable daily driver for this Mac"
        case .smart:
            return "The most capable models your memory can run"
        }
    }
}

enum WelcomeModelCatalog {
    static func recommendedModelIDs(for tier: WelcomeModelTier) -> [String] {
        switch tier {
        case .fast:
            return [
                "mlx-community/LFM2.5-VL-1.6B-8bit",
                "mlx-community/Qwen3.5-0.8B-8bit",
                "mlx-community/Qwen3-VL-2B-Instruct-4bit"
            ]
        case .balanced:
            return [
                "mlx-community/Qwen3-VL-4B-Instruct-4bit",
                "mlx-community/Qwen3.5-9B-4bit",
                "mlx-community/Qwen3.5-4B-MLX-4bit"
            ]
        case .smart:
            return [
                "mlx-community/Qwen2.5-VL-32B-Instruct-4bit",
                "mlx-community/Qwen3.6-35B-A3B-4bit",
                "mlx-community/Qwen3-VL-30B-A3B-Instruct-4bit"
            ]
        }
    }

    static func codingModelID(for tier: WelcomeModelTier) -> String {
        switch tier {
        case .fast:
            return "mlx-community/Qwen2.5-Coder-3B-Instruct-4bit"
        case .balanced:
            return "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"
        case .smart:
            return "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
        }
    }

    static func allModelIDs(for tier: WelcomeModelTier) -> [String] {
        recommendedModelIDs(for: tier) + [codingModelID(for: tier)]
    }

    static var allTierModelIDs: [String] {
        var ids: [String] = []
        for tier in WelcomeModelTier.allCases {
            for id in allModelIDs(for: tier) where !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }
}

private struct WelcomeView: View {
    private enum Step: Equatable {
        case model
        case apiKey
        case permissions
    }

    @ObservedObject var model: NativModel
    @StateObject private var modelLibrary = LocalModelLibrary()
    @StateObject private var hubLibrary = HuggingFaceModelLibrary()
    @ObservedObject private var downloadManager = HuggingFaceDownloadManager.shared
    @State private var step = Step.model
    @State private var selectedModelID: String?
    @State private var selectedTier: WelcomeModelTier = .balanced
    @State private var didRequestRecommendedModels = false
    @State private var showsAPIKeyEditor = false
    @State private var serverAPIKey: String
    @State private var configuredServerAPIKey: String?
    @StateObject private var permissions = NativPermissionStore()
    @FocusState private var isAPIKeyFieldFocused: Bool

    let onComplete: (_ modelID: String?, _ serverAPIKey: String?) -> Void

    init(
        model: NativModel,
        onComplete: @escaping (_ modelID: String?, _ serverAPIKey: String?) -> Void
    ) {
        self.model = model
        self.onComplete = onComplete
        let settings = model.settings.normalized()
        _selectedModelID = State(initialValue: settings.languageModelID)
        _serverAPIKey = State(
            initialValue: settings.serverAPIKey ?? ServerAPIAuthentication.generateToken()
        )
        _configuredServerAPIKey = State(initialValue: settings.serverAPIKey)
    }

    var body: some View {
        ZStack {
            WelcomeBackground()

            VStack(spacing: 0) {
                welcomeHeader

                Group {
                    switch step {
                    case .model:
                        modelStep
                    case .apiKey:
                        apiKeyStep
                    case .permissions:
                        permissionsStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: 760, maxHeight: 900)
            .padding(.horizontal, 48)
            .padding(.vertical, 32)
        }
        .frame(minWidth: 900, minHeight: 760)
        .task(id: model.settings.localModelSearchPaths) {
            modelLibrary.scan(searchPaths: model.settings.localModelSearchPaths)
        }
        .task(id: step) {
            guard step == .permissions else { return }
            permissions.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            guard step == .permissions else { return }
            permissions.refresh()
        }
        .onChange(of: modelLibrary.isScanning) { _, isScanning in
            guard !isScanning else { return }
            loadRecommendedModelsIfNeeded()
        }
        .onDisappear {
            modelLibrary.cancel()
            hubLibrary.cancel()
        }
    }

    private var welcomeHeader: some View {
        VStack(spacing: 16) {
            Image(nsImage: NativApplicationIcon.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
                .accessibilityLabel("Nativ app icon")

            VStack(spacing: 6) {
                Text("Welcome to Nativ")
                    .font(.system(size: 32, weight: .semibold))
                Text(stepSubtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 8) {
                WelcomeStepIndicator(number: 1, title: "Model", isActive: step == .model)
                Capsule()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 34, height: 1)
                WelcomeStepIndicator(number: 2, title: "API Key", isActive: step == .apiKey)
                Capsule()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 34, height: 1)
                WelcomeStepIndicator(
                    number: 3,
                    title: "Permissions",
                    isActive: step == .permissions
                )
            }
        }
        .padding(.bottom, 24)
    }

    private var stepSubtitle: String {
        switch step {
        case .model:
            "Choose how your local server should start."
        case .apiKey:
            "Optionally protect the server’s management endpoints."
        case .permissions:
            "Optional access for voice features — Nativ works fine without it."
        }
    }

    private var modelStep: some View {
        VStack(spacing: 16) {
            WelcomeCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Select your first model")
                                .font(.headline)
                            Text("You can change this at any time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if modelLibrary.isScanning || hubLibrary.isSearching {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button {
                                refreshModelChoices()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .disabled(downloadManager.activeCount > 0)
                            .help("Refresh installed models")
                        }
                    }
                    .padding(16)

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            WelcomeModelPickerRow(
                                title: "Load on demand",
                                detail: "Start without preloading a model",
                                systemImage: "bolt.badge.clock",
                                isSelected: selectedModelID == nil
                            ) {
                                selectedModelID = nil
                            }

                            ForEach(pickerModels) { localModel in
                                WelcomeModelPickerRow(
                                    model: localModel,
                                    isSelected: selectedModelID == localModel.repoID
                                ) {
                                    selectedModelID = localModel.repoID
                                }
                            }

                            if shouldShowRecommendedModels {
                                recommendedModelsSection
                            }
                        }
                        .padding(12)
                    }
                    .frame(minHeight: 340, maxHeight: .infinity)

                    if let modelScanMessage {
                        Divider()
                        Label(modelScanMessage.text, systemImage: modelScanMessage.systemImage)
                            .font(.caption)
                            .foregroundStyle(modelScanMessage.isError ? Color.orange : Color.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                    }
                }
            }

            HStack {
                if downloadManager.activeCount > 0 {
                    Label("Downloads continue in the background", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Continue") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = .apiKey
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .help("Continue setup")
            }
        }
    }

    @ViewBuilder
    private var recommendedModelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "memorychip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(deviceMemoryLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Hugging Face")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            Picker("", selection: $selectedTier) {
                ForEach(WelcomeModelTier.allCases) { tier in
                    Text(tier.rawValue).tag(tier)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(selectedTier.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            HStack {
                Text("Recommended models")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !recommendedModels.isEmpty {
                    Text("\(recommendedFitCount) fit")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)

            recommendedModelRows

            Divider()
                .padding(.vertical, 2)

            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Coding agent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)

            codingAgentRow
        }
    }

    @ViewBuilder
    private var recommendedModelRows: some View {
        if hubLibrary.isSearching && recommendedModels.isEmpty {
            searchingPlaceholder
        } else if recommendedModels.isEmpty {
            emptyRecommendedLabel
        } else {
            ForEach(recommendedModels) { hubModel in
                downloadRow(for: hubModel)
            }
        }
    }

    @ViewBuilder
    private var codingAgentRow: some View {
        if let codingModel {
            downloadRow(for: codingModel)
        } else if hubLibrary.isSearching {
            searchingPlaceholder
        } else {
            emptyRecommendedLabel
        }
    }

    private var searchingPlaceholder: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Finding models for this Mac…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 54)
    }

    private var emptyRecommendedLabel: some View {
        Label(
            hubLibrary.error == nil
                ? "No recommended models are available right now."
                : "Couldn’t load recommended models.",
            systemImage: hubLibrary.error == nil ? "shippingbox" : "wifi.exclamationmark"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(minHeight: 54)
    }

    private func downloadRow(for hubModel: HuggingFaceModel) -> some View {
        WelcomeDownloadModelRow(
            model: hubModel,
            isDownloaded: isInstalled(hubModel.id),
            isSelected: selectedModelID == hubModel.id,
            isDownloading: downloadManager.isDownloading(hubModel.id),
            downloadProgress: downloadManager.progress(for: hubModel.id),
            downloadBlockedReason: downloadManager.capacityBlocker(
                sizeBytes: hubModel.sizeBytes,
                cachePath: model.settings.modelSearchPath
            ),
            downloadError: downloadManager.errorByModelID[hubModel.id],
            onSelect: { selectedModelID = hubModel.id },
            onDownload: { downloadRecommendedModel(hubModel) },
            onCancel: { downloadManager.removeDownload(hubModel.id) }
        )
    }

    private var apiKeyStep: some View {
        VStack(spacing: 16) {
            WelcomeCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.blue)
                            .frame(width: 38, height: 38)
                            .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 5) {
                            Text("Protect management access")
                                .font(.headline)
                            Text("An API key provides basic security if you're running Nativ on a shared network.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if showsAPIKeyEditor {
                        apiKeyEditor
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showsAPIKeyEditor = true
                                }
                                DispatchQueue.main.async {
                                    isAPIKeyFieldFocused = true
                                }
                            } label: {
                                Label("Set Up an API Key", systemImage: "key.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)

                            Button("Skip") {
                                skipAPIKey()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(20)
            }

            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = .model
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)

                Spacer()

                if showsAPIKeyEditor {
                    Button("Skip") {
                        skipAPIKey()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button("Save & Continue") {
                        continueFromAPIKey()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedAPIKey == nil)
                } else {
                    Button("Continue") {
                        skipAPIKey()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var permissionsStep: some View {
        VStack(spacing: 16) {
            WelcomeCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.blue)
                            .frame(width: 38, height: 38)
                            .background(
                                Color.blue.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 10)
                            )

                        VStack(alignment: .leading, spacing: 5) {
                            Text("Optional permissions")
                                .font(.headline)
                            Text(
                                "Nativ works fully without any of these. Enable them only if you want to dictate with \(VoiceShortcut.recordDefault.displayName), take voice notes, or capture meetings — audio and transcription stay local to your Mac."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    NativPermissionsCard(store: permissions)

                    NativPermissionsSummary(store: permissions)

                    Text("You can change these any time from Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }

            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = .apiKey
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Skip for Now") {
                    finish(serverAPIKey: configuredServerAPIKey)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Finish Setup") {
                    finish(serverAPIKey: configuredServerAPIKey)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func continueFromAPIKey() {
        guard let normalizedAPIKey else { return }
        configuredServerAPIKey = normalizedAPIKey
        withAnimation(.easeInOut(duration: 0.2)) {
            step = .permissions
        }
    }

    private func skipAPIKey() {
        configuredServerAPIKey = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            step = .permissions
        }
    }

    private var apiKeyEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Server API key")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Generate New") {
                    serverAPIKey = ServerAPIAuthentication.generateToken()
                    isAPIKeyFieldFocused = true
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 8) {
                TextField("API key", text: $serverAPIKey)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($isAPIKeyFieldFocused)
                    .onSubmit {
                        continueFromAPIKey()
                    }

                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(serverAPIKey, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy API key")
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }

            Text("A secure random key is ready. Edit or replace it before saving if you prefer your own value.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var pickerModels: [LocalModel] {
        modelLibrary.models.filter { localModel in
            localModel.repoID == selectedModelID
                || localModel.isEligibleForLanguageModelPicker
        }
    }

    private var shouldShowRecommendedModels: Bool {
        !modelLibrary.isScanning
    }

    private var recommendedModels: [HuggingFaceModel] {
        WelcomeModelCatalog.recommendedModelIDs(for: selectedTier).compactMap { id in
            hubLibrary.models.first { $0.id == id && !$0.isPrivate && !$0.isGated }
        }
    }

    private var codingModel: HuggingFaceModel? {
        let id = WelcomeModelCatalog.codingModelID(for: selectedTier)
        return hubLibrary.models.first { $0.id == id && !$0.isPrivate && !$0.isGated }
    }

    private var recommendedFitCount: Int {
        recommendedModels.filter { $0.memoryEstimate?.isUsable ?? true }.count
    }

    private var deviceMemoryLabel: String {
        let gb = ByteCountFormatter.string(
            fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory),
            countStyle: .memory
        )
        return "\(gb) unified memory"
    }

    private func isInstalled(_ repoID: String) -> Bool {
        modelLibrary.models.contains { $0.repoID == repoID }
    }

    private var modelSearchPath: String {
        model.settings.normalized().expandedModelSearchPath
    }

    private var missingDefaultModelCache: Bool {
        modelLibrary.error == LocalModelDiscoveryError.pathNotFound("").errorDescription
            && modelSearchPath == LocalModelDiscovery.expandedPath(NativSettings.defaultModelSearchPath)
    }

    private var normalizedAPIKey: String? {
        let trimmed = serverAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var modelScanMessage: (text: String, systemImage: String, isError: Bool)? {
        if let error = modelLibrary.error, !missingDefaultModelCache {
            return (error, "exclamationmark.triangle.fill", true)
        }
        if !modelLibrary.isScanning, pickerModels.isEmpty {
            return (
                "No compatible language models are installed. Download one above or continue with load on demand.",
                "info.circle",
                false
            )
        }
        return nil
    }

    private func finish(serverAPIKey: String?) {
        onComplete(selectedModelID, serverAPIKey)
    }

    private func refreshModelChoices() {
        modelLibrary.scan(searchPaths: model.settings.localModelSearchPaths)
        requestRecommendedModels()
    }

    private func loadRecommendedModelsIfNeeded() {
        guard !didRequestRecommendedModels else { return }
        requestRecommendedModels()
    }

    private func requestRecommendedModels() {
        didRequestRecommendedModels = true
        hubLibrary.loadCurated(
            ids: WelcomeModelCatalog.allTierModelIDs,
            token: model.effectiveHuggingFaceToken
        )
    }

    private func downloadRecommendedModel(_ hubModel: HuggingFaceModel) {
        downloadManager.download(
            repoID: hubModel.id,
            sizeBytes: hubModel.sizeBytes,
            cachePath: model.settings.modelSearchPath,
            token: model.effectiveHuggingFaceToken
        ) {
            modelLibrary.scan(searchPaths: model.settings.localModelSearchPaths)
            if selectedModelID == nil {
                selectedModelID = hubModel.id
            }
        }
    }
}

private struct WelcomeCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.08), radius: 24, y: 10)
    }
}

private struct WelcomeStepIndicator: View {
    let number: Int
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(isActive ? Color.white : Color.secondary)
                .frame(width: 20, height: 20)
                .background(isActive ? Color.accentColor : Color.secondary.opacity(0.14), in: Circle())
            Text(title)
                .font(.caption.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
        }
    }
}

private struct WelcomeModelPickerRow: View {
    let title: String
    let detail: String
    let systemImage: String?
    let provider: LocalModelProvider?
    let memoryEstimate: LocalModelMemoryEstimate?
    let isSelected: Bool
    let action: () -> Void

    init(
        title: String,
        detail: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        provider = nil
        memoryEstimate = nil
        self.isSelected = isSelected
        self.action = action
    }

    init(model: LocalModel, isSelected: Bool, action: @escaping () -> Void) {
        title = model.repoID.split(separator: "/").last.map(String.init) ?? model.repoID
        detail = WelcomeModelPickerRow.modelDetail(model)
        systemImage = nil
        provider = model.provider
        memoryEstimate = model.memoryEstimate()
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                modelIcon

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .layoutPriority(1)

                        if let memoryEstimate, !memoryEstimate.isUsable {
                            WelcomeMemoryFitBadge(estimate: memoryEstimate)
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var modelIcon: some View {
        if let provider,
           let image = LocalModelProviderIcon.image(for: provider) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .frame(width: 36, height: 36)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        } else {
            Image(systemName: systemImage ?? "cube.transparent.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private static func modelDetail(_ model: LocalModel) -> String {
        var details: [String] = []
        if let provider = model.provider {
            details.append(provider.displayName)
        }
        if let parameterSize = model.parameterSizeLabel {
            details.append(parameterSize)
        }
        if let quantization = model.quantizationLabel {
            details.append(quantization)
        }
        if let sizeBytes = model.sizeBytes {
            details.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
        }
        if let contextSize = model.contextSize {
            details.append("\(compactContextSize(contextSize)) context")
        }
        return details.isEmpty ? model.repoID : details.joined(separator: " · ")
    }

    private static func compactContextSize(_ value: Int) -> String {
        if value >= 1_048_576, value.isMultiple(of: 1_048_576) {
            return "\(value / 1_048_576)M"
        }
        if value >= 1024, value.isMultiple(of: 1024) {
            return "\(value / 1024)K"
        }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private var accessibilityLabel: String {
        let selection = isSelected ? "selected" : "not selected"
        guard let memoryEstimate else {
            return "\(title), \(selection)"
        }
        return "\(title), \(memoryEstimate.compatibilityLabel), \(selection)"
    }
}

private struct WelcomeDownloadModelRow: View {
    let model: HuggingFaceModel
    let isDownloaded: Bool
    let isSelected: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let downloadBlockedReason: String?
    let downloadError: String?
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                modelIcon

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(modelName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .layoutPriority(1)

                        if let memoryEstimate = model.memoryEstimate,
                           !memoryEstimate.isUsable {
                            WelcomeMemoryFitBadge(estimate: memoryEstimate)
                        }
                    }

                    Text(modelDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                if isDownloaded && isSelected {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .fixedSize()
                } else if isDownloaded {
                    Button("Use", action: onSelect)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if isDownloading {
                    HStack(spacing: 8) {
                        VStack(alignment: .trailing, spacing: 3) {
                            ProgressView(value: downloadProgress)
                                .frame(width: 74)
                            Text(downloadProgress > 0
                                ? "\(Int((downloadProgress * 100).rounded()))%"
                                : "Starting…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Button(action: onCancel) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Cancel and remove download")
                    }
                    .fixedSize()
                } else {
                    Button("Download", action: onDownload)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(downloadBlockedReason != nil)
                        .help(downloadBlockedReason ?? "Download \(model.id) to the configured cache")
                }
            }

            if let downloadError {
                Label(downloadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .padding(.leading, 48)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 54)
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var modelIcon: some View {
        if let provider = model.provider,
           let image = LocalModelProviderIcon.image(for: provider) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .frame(width: 36, height: 36)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        } else {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var modelName: String {
        model.id.split(separator: "/").last.map(String.init) ?? model.id
    }

    private var modelDetail: String {
        var details: [String] = []
        if let provider = model.provider {
            details.append(provider.displayName)
        }
        if let sizeBytes = model.sizeBytes {
            details.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
        }
        details.append("\(compactCount(model.downloads)) downloads")
        return details.joined(separator: " · ")
    }

    private func compactCount(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
        }
    }
}

private struct WelcomeMemoryFitBadge: View {
    let estimate: LocalModelMemoryEstimate

    var body: some View {
        Label(
            estimate.compatibilityLabel,
            systemImage: estimate.isUsable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption2.weight(.semibold))
        .foregroundStyle(estimate.isUsable ? Color.green : Color.orange)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            (estimate.isUsable ? Color.green : Color.orange).opacity(0.10),
            in: Capsule()
        )
        .fixedSize()
        .help(estimate.explanation)
    }
}

private struct WelcomeBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [Color.accentColor.opacity(0.10), Color.clear, Color.gray.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.accentColor.opacity(0.08))
                .frame(width: 420, height: 420)
                .blur(radius: 80)
                .offset(x: -360, y: -250)
        }
        .ignoresSafeArea()
    }
}

#Preview {
    WelcomeView(model: NativModel()) { _, _ in }
        .frame(width: 1240, height: 720)
}
