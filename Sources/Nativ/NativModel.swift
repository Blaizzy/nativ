import Combine
import Foundation
import NativServerKit

struct SessionTokenActivitySample: Equatable, Sendable {
    let recordedAt: Date
    let promptTokens: Int
    let generatedTokens: Int

    var totalTokens: Int {
        promptTokens + generatedTokens
    }
}

private struct PendingModelPreloadSwitch {
    let modelID: String
    let slot: ModelPreloadSlot
    let onSelectionAccepted: () -> Void
}

struct ModelLoadFailure: Equatable, Identifiable, Sendable {
    let id = UUID()
    let modelID: String?
    let message: String

    var title: String {
        guard let modelID else {
            return "Couldn’t load model"
        }
        let name = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return "Couldn’t load \(name)"
    }
}

@MainActor
final class NativModel: ObservableObject, ChatModelSwitchingSurface {
    @Published private(set) var isRunning = false
    @Published private(set) var logText = ""
    @Published private(set) var metrics: NativMetrics?
    @Published private(set) var lastMetricsError: String?
    @Published private(set) var lastMetricsFetchAt: Date?
    @Published private(set) var allTimeStats = NativAllTimeStats()
    @Published private(set) var sessionTokenActivity: [SessionTokenActivitySample] = []
    @Published private(set) var modelSwitchInProgress = false
    @Published private(set) var modelSwitchTargetID: String?
    @Published private(set) var modelLoadingProgress: Double?
    @Published private(set) var modelLoadFailure: ModelLoadFailure?
    @Published private(set) var modelPreloadMemoryWarning: ModelPreloadMemoryWarning?
    @Published private(set) var metricsLoading = false
    @Published private(set) var systemHuggingFaceCredential =
        HuggingFaceAuthentication.systemCredential()
    @Published private(set) var serverRestartCountdown: Int?
    @Published var settings = NativSettings.load() {
        didSet {
            settings.save()
        }
    }

    var menuIsOpen = false
    var onMenuStateChanged: (() -> Void)?

    private let server = NativProcessController()
    let mcpServers = MCPServerManager()
    private var resolvedMCPLaunchEnvironment: [String: String] = [:]
    private var metricsClient = NativMetricsClient()
    private var metricsFetchTask: Task<Void, Never>?
    private var metricsTimer: Timer?
    private var metricsStartupGraceUntil: Date?
    private var settingsAppliedAtServerStart: NativSettings?
    private var huggingFaceTokenAppliedAtServerStart: String?
    private var previousSessionPromptTokenCount: Int?
    private var previousSessionGeneratedTokenCount: Int?
    private var preservedSessionMetrics: NativMetrics?
    private var preservedSessionTokenActivity: [SessionTokenActivitySample] = []
    private var isStoppingForModelSwitch = false
    private var pendingModelPreloadSwitch: PendingModelPreloadSwitch?
    private var pendingServerRestartID: UUID?
    private var serverRestartTask: Task<Void, Never>?
    private var currentServerOutput = ""

    private let maxLogCharacters = 250_000
    private let maxCurrentServerOutputCharacters = 50_000
    private let maxSessionActivitySamples = 120

    init() {
        NativAllTimeStats.removeLegacyStorage()
        allTimeStats = NativAllTimeStats.load(from: currentAnalyticsDatabaseURL())
        configureServerCallbacks()
        isRunning = server.isRunning
        mcpServers.configure(settings.mcpServers)
        resolveHuggingFaceEnvironmentFromLoginShell()
        resolveMCPLaunchEnvironmentFromLoginShell()
        migrateCustomHuggingFaceCredentialIfNeeded()
    }

    /// GUI apps inherit launchd's environment, which excludes exports from
    /// shell startup files. Probe the user's login shell once for any missing
    /// Hugging Face cache or authentication variables. Environment tokens stay
    /// in memory; only a token entered in Developer settings is persisted.
    private func resolveHuggingFaceEnvironmentFromLoginShell() {
        let processEnvironment = ProcessInfo.processInfo.environment
        let needsCacheEnvironment = !HuggingFaceCache.isConfigured(in: processEnvironment)
        let needsTokenEnvironment = HuggingFaceAuthentication.token(in: processEnvironment) == nil
        guard needsCacheEnvironment || needsTokenEnvironment else { return }

        var names: [String] = []
        if needsCacheEnvironment {
            names.append(contentsOf: HuggingFaceCache.environmentVariableNames)
        }
        if needsTokenEnvironment {
            for name in HuggingFaceAuthentication.discoveryEnvironmentVariableNames
            where !names.contains(name) {
                names.append(name)
            }
        }

        let environmentVariableNames = names
        Task { [weak self] in
            let shellEnvironment = await Task.detached(priority: .utility) {
                ShellEnvironment.resolveFromLoginShell(names: environmentVariableNames)
            }.value
            guard !shellEnvironment.isEmpty else { return }
            guard let self else { return }
            if needsCacheEnvironment {
                let resolved = HuggingFaceCache.resolvedSearchPath(
                    stored: self.settings.modelSearchPath,
                    environment: shellEnvironment
                )
                if resolved != self.settings.modelSearchPath {
                    self.settings.modelSearchPath = resolved
                }
            }
            if needsTokenEnvironment {
                let effectiveEnvironment = processEnvironment.merging(shellEnvironment) {
                    _, shellValue in shellValue
                }
                self.systemHuggingFaceCredential = HuggingFaceAuthentication.systemCredential(
                    in: effectiveEnvironment
                )
            }
        }
    }

    /// launchd's PATH is missing /opt/homebrew/bin, so `npx`/`uvx` only
    /// resolve from Xcode/a terminal, not a real Finder launch. Same probe
    /// as resolveHuggingFaceEnvironmentFromLoginShell, a different variable.
    private func resolveMCPLaunchEnvironmentFromLoginShell() {
        Task { [weak self] in
            let resolved = await Task.detached(priority: .utility) {
                ShellEnvironment.resolveFromLoginShell(names: ["PATH"])
            }.value
            guard !resolved.isEmpty else { return }
            self?.resolvedMCPLaunchEnvironment = resolved
        }
    }

    func addMCPServer(_ configuration: MCPServerConfiguration) {
        settings.mcpServers.append(configuration)
        mcpServers.configure(settings.mcpServers)
    }

    func removeMCPServer(_ id: MCPServerConfiguration.ID) {
        settings.mcpServers.removeAll { $0.id == id }
        mcpServers.configure(settings.mcpServers)
    }

    func startMCPServer(_ id: MCPServerConfiguration.ID) {
        Task { [mcpServers, resolvedMCPLaunchEnvironment] in
            await mcpServers.start(id, additionalEnvironment: resolvedMCPLaunchEnvironment)
        }
    }

    func stopMCPServer(_ id: MCPServerConfiguration.ID) {
        Task { [mcpServers] in
            await mcpServers.stop(id)
        }
    }

    var effectiveHuggingFaceToken: String? {
        HuggingFaceAuthentication.effectiveToken(
            customToken: settings.huggingFaceToken,
            environmentToken: systemHuggingFaceCredential?.token
        )
    }

    func setCustomHuggingFaceToken(_ token: String?) {
        settings.huggingFaceToken = HuggingFaceAuthentication.normalizedToken(token)
        restartServerForHuggingFaceCredentialChangeIfNeeded()
    }

    func logInToHuggingFace(_ token: String) async throws {
        guard let token = HuggingFaceAuthentication.normalizedToken(token) else {
            throw HuggingFaceAuthenticationError.invalidResponse
        }

        let metadata = try await HuggingFaceAuthentication.tokenMetadata(for: token)
        guard let tokenName = metadata.name else {
            throw HuggingFaceAuthenticationError.invalidResponse
        }
        let credential = try HuggingFaceAuthentication.logIn(
            token: token,
            tokenName: tokenName
        )
        try? HuggingFaceTokenMetadataCache.save(metadata, for: token)

        settings.huggingFaceToken = nil
        if systemHuggingFaceCredential?.source != .environment {
            systemHuggingFaceCredential = credential
        }
        restartServerForHuggingFaceCredentialChangeIfNeeded()
    }

    func setServerAPIKey(_ token: String?) {
        let normalizedToken = ServerAPIAuthentication.normalizedToken(token)
        guard normalizedToken != settings.normalized().serverAPIKey else {
            return
        }

        settings.serverAPIKey = normalizedToken
        guard isRunning,
              normalizedToken != settingsAppliedAtServerStart?.serverAPIKey else {
            return
        }
        restartServer()
    }

    func logOutSystemHuggingFaceCredential() throws {
        guard let credential = systemHuggingFaceCredential else {
            return
        }
        try HuggingFaceAuthentication.logOut(credential: credential)
        systemHuggingFaceCredential = nil
        restartServerForHuggingFaceCredentialChangeIfNeeded()
    }

    private func restartServerForHuggingFaceCredentialChangeIfNeeded() {
        guard isRunning,
              effectiveHuggingFaceToken != huggingFaceTokenAppliedAtServerStart else {
            return
        }
        restartServer()
    }

    private func migrateCustomHuggingFaceCredentialIfNeeded() {
        guard let token = HuggingFaceAuthentication.normalizedToken(
            settings.huggingFaceToken
        ) else {
            return
        }

        Task { [weak self] in
            try? await self?.logInToHuggingFace(token)
        }
    }

    var metricsAreStale: Bool {
        guard let lastMetricsFetchAt else {
            return true
        }
        return Date().timeIntervalSince(lastMetricsFetchAt) >= 5
    }

    var loadedModelDisplay: String {
        metrics?.server.displayLoadedModel ?? "None"
    }

    var isModelLoading: Bool {
        modelSwitchInProgress
            || (settings.normalized().languageModelID != nil
                && (metricsLoading || modelLoadingProgress != nil))
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

    var modelLoadingPercentageText: String? {
        modelLoadingPercentage.map { "\($0)%" }
    }

    var modelLoadingStatusText: String? {
        guard isModelLoading else { return nil }
        if let modelLoadingPercentageText {
            return "Loading model · \(modelLoadingPercentageText)"
        }
        return "Loading model…"
    }

    var sessionStatsDisplayMetrics: NativMetrics? {
        metrics ?? preservedSessionMetrics
    }

    var sessionStatsDisplayTokenActivity: [SessionTokenActivitySample] {
        metrics == nil ? preservedSessionTokenActivity : sessionTokenActivity
    }

    var sessionStatsArePreserved: Bool {
        metrics == nil && preservedSessionMetrics != nil
    }

    var selectedModelDisplay: String {
        settings.normalized().languageModelID ?? "On demand"
    }

    var analyticsDatabaseURL: URL {
        currentAnalyticsDatabaseURL(runtimePath: metrics?.server.analyticsDatabasePath)
    }

    var unavailableMetricsText: String {
        lastMetricsError == nil ? "Waiting for server..." : "Metrics unavailable"
    }

    var settingsRequireRestart: Bool {
        guard isRunning, let settingsAppliedAtServerStart else {
            return false
        }
        return !settings.hasSameLaunchConfiguration(as: settingsAppliedAtServerStart)
            || effectiveHuggingFaceToken != huggingFaceTokenAppliedAtServerStart
    }

    var activeServerPort: Int? {
        guard isRunning, let settingsAppliedAtServerStart else {
            return nil
        }
        return settingsAppliedAtServerStart.normalized().serverPort
    }

    var activeServerHost: String? {
        guard isRunning, let settingsAppliedAtServerStart else {
            return nil
        }
        return settingsAppliedAtServerStart.normalized().serverHost
    }

    var activeServerBaseURL: URL? {
        guard isRunning, let settingsAppliedAtServerStart else {
            return nil
        }
        return settingsAppliedAtServerStart.serverBaseURL
    }

    func startServer() {
        var shouldStartMetrics = false
        clearModelLoadFailure()
        currentServerOutput = ""
        metricsClient = NativMetricsClient(baseURL: settings.serverBaseURL)
        modelLoadingProgress = settings.normalized().languageModelID == nil ? nil : 0
        var launchArguments = settings.launchArguments
        if let languageModelID = settings.normalized().languageModelID,
           isKnownNonGenerativeModel(languageModelID),
           let modelFlagIndex = launchArguments.firstIndex(of: "--model"),
           modelFlagIndex + 1 < launchArguments.count {
            // A stale, non-chat selection (e.g. a BERT encoder) would make the
            // server abort while pre-loading it. Start on-demand instead so it
            // still comes up.
            launchArguments.removeSubrange(modelFlagIndex...(modelFlagIndex + 1))
            modelLoadingProgress = nil
            appendLog("\n\(languageModelID) is not a text-generation model — starting the server without pre-loading it. Pick a chat model to load one.\n")
        }
        do {
            var launchEnvironment = settings.launchEnvironment
            launchEnvironment["MLX_PLATFORM_ANALYTICS_DB_PATH"] = currentAnalyticsDatabaseURL().path
            if let effectiveHuggingFaceToken {
                launchEnvironment[HuggingFaceAuthentication.environmentVariableName] = effectiveHuggingFaceToken
            }
            try server.start(
                arguments: launchArguments,
                environment: launchEnvironment
            )
            isRunning = true
            settingsAppliedAtServerStart = settings.normalized()
            huggingFaceTokenAppliedAtServerStart = effectiveHuggingFaceToken
            appendLog("\nStarted mlx-vlm-server.\n")
            shouldStartMetrics = true
        } catch NativError.alreadyRunning {
            isRunning = true
            settingsAppliedAtServerStart = settings.normalized()
            huggingFaceTokenAppliedAtServerStart = effectiveHuggingFaceToken
            appendLog("\nmlx-vlm-server is already running.\n")
            shouldStartMetrics = true
        } catch {
            modelLoadingProgress = nil
            appendLog("\nFailed to start mlx-vlm-server: \(error)\n")
        }

        if shouldStartMetrics {
            startMetricsPolling()
        }
        notifyMenuStateChanged()
    }

    /// Returns true only when the model is present locally and its config's
    /// architectures are all non-generative (e.g. a BERT/RoBERTa encoder), which
    /// mlx-vlm cannot load as a chat model. Any uncertainty returns false, so a
    /// genuine chat model is never skipped.
    private func isKnownNonGenerativeModel(_ repoID: String) -> Bool {
        let cacheName = "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        let fileManager = FileManager.default

        // Consolidated roots (primary folder + user-added folders + HF hub cache) so
        // this check also covers models the user keeps in custom folders.
        let roots = settings.normalized().modelSearchRoots

        let generativeMarkers = ["forcausallm", "forconditionalgeneration", "lmheadmodel"]
        for root in roots {
            let snapshots = URL(fileURLWithPath: root)
                .appendingPathComponent(cacheName)
                .appendingPathComponent("snapshots")
            guard let revisions = try? fileManager.contentsOfDirectory(
                at: snapshots,
                includingPropertiesForKeys: nil
            ) else {
                continue
            }
            for revision in revisions {
                let configURL = revision.appendingPathComponent("config.json")
                guard let data = try? Data(contentsOf: configURL),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let architectures = json["architectures"] as? [String],
                      !architectures.isEmpty
                else {
                    continue
                }
                let isGenerative = architectures
                    .map { $0.lowercased() }
                    .contains { arch in generativeMarkers.contains { arch.contains($0) } }
                return !isGenerative
            }
        }
        return false
    }

    func stopServer(preserveSessionStats: Bool = false) {
        cancelPendingServerRestart()
        modelLoadingProgress = nil
        if preserveSessionStats {
            preserveCurrentSessionStats()
        } else {
            modelSwitchInProgress = false
            modelSwitchTargetID = nil
            clearPreservedSessionStats()
        }

        do {
            appendLog("\nStopping mlx-vlm-server...\n")
            try server.stop()
        } catch NativError.notRunning {
            appendLog("\nmlx-vlm-server is not running.\n")
        } catch {
            appendLog("\nFailed to stop mlx-vlm-server: \(error)\n")
        }

        isRunning = server.isRunning
        if !isRunning {
            settingsAppliedAtServerStart = nil
            huggingFaceTokenAppliedAtServerStart = nil
        }
        stopMetricsPolling(clearSession: true)
        notifyMenuStateChanged()
    }

    func toggleServer() {
        if isRunning {
            stopServer()
        } else {
            startServer()
        }
    }

    func restartServer() {
        guard server.isRunning else {
            return
        }

        stopServer()
        guard !server.isRunning else {
            appendLog("\nCould not stop the current server to apply the configuration change.\n")
            return
        }
        startServer()
    }

    func scheduleServerRestartForEndpointChange() {
        cancelPendingServerRestart()
        guard isRunning else {
            return
        }

        let scheduledSettings = settings.normalized()
        let endpointHasChanged = scheduledSettings.serverHost != activeServerHost
            || scheduledSettings.serverPort != activeServerPort
        guard endpointHasChanged else {
            return
        }

        let restartID = UUID()
        pendingServerRestartID = restartID
        serverRestartCountdown = 3
        serverRestartTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.clearPendingServerRestart(id: restartID)
            }

            for secondsRemaining in stride(from: 3, through: 1, by: -1) {
                guard !Task.isCancelled, self.isRunning else {
                    return
                }
                self.serverRestartCountdown = secondsRemaining
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }

            let currentSettings = self.settings.normalized()
            guard currentSettings.serverHost == scheduledSettings.serverHost,
                  currentSettings.serverPort == scheduledSettings.serverPort
            else {
                return
            }

            let endpointStillNeedsRestart = currentSettings.serverHost != self.activeServerHost
                || currentSettings.serverPort != self.activeServerPort
            guard endpointStillNeedsRestart else {
                return
            }

            self.clearPendingServerRestart(id: restartID)
            self.restartServer()
        }
    }

    private func cancelPendingServerRestart() {
        serverRestartTask?.cancel()
        serverRestartTask = nil
        pendingServerRestartID = nil
        serverRestartCountdown = nil
    }

    private func clearPendingServerRestart(id: UUID) {
        guard pendingServerRestartID == id else {
            return
        }
        serverRestartTask = nil
        pendingServerRestartID = nil
        serverRestartCountdown = nil
    }

    func switchLanguageModel(to modelID: String?) {
        switchPreloadedModel(to: modelID, for: .language)
    }

    @discardableResult
    func requestPreloadedModelSwitch(
        to localModel: LocalModel,
        for slot: ModelPreloadSlot,
        availableModels: [LocalModel],
        onSelectionAccepted: @escaping () -> Void = {}
    ) -> Bool {
        guard !modelSwitchInProgress else {
            return false
        }

        if let warning = preloadMemoryWarning(
            for: localModel,
            slot: slot,
            availableModels: availableModels
        ) {
            pendingModelPreloadSwitch = PendingModelPreloadSwitch(
                modelID: localModel.repoID,
                slot: slot,
                onSelectionAccepted: onSelectionAccepted
            )
            modelPreloadMemoryWarning = warning
            return true
        }

        onSelectionAccepted()
        switchPreloadedModel(to: localModel.repoID, for: slot)
        return false
    }

    func confirmPendingModelPreloadSwitch() {
        guard let pendingModelPreloadSwitch else {
            modelPreloadMemoryWarning = nil
            return
        }

        self.pendingModelPreloadSwitch = nil
        modelPreloadMemoryWarning = nil
        pendingModelPreloadSwitch.onSelectionAccepted()
        switchPreloadedModel(
            to: pendingModelPreloadSwitch.modelID,
            for: pendingModelPreloadSwitch.slot
        )
    }

    func cancelPendingModelPreloadSwitch() {
        pendingModelPreloadSwitch = nil
        modelPreloadMemoryWarning = nil
    }

    func switchPreloadedModel(
        to modelID: String?,
        for slot: ModelPreloadSlot
    ) {
        guard !modelSwitchInProgress else {
            return
        }
        clearModelLoadFailure()

        var nextSettings = settings
        nextSettings.setModelID(modelID, for: slot)
        nextSettings = nextSettings.normalized()
        let normalizedModelID = nextSettings.modelID(for: slot)
        let selectionIsAlreadyApplied = settings.normalized().modelID(for: slot)
            == normalizedModelID
            && server.isRunning
            && !settingsRequireRestart
        guard !selectionIsAlreadyApplied else {
            return
        }

        settings = nextSettings
        modelSwitchInProgress = true
        modelSwitchTargetID = normalizedModelID
        notifyMenuStateChanged()

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            if self.server.isRunning {
                self.isStoppingForModelSwitch = true
                self.stopServer(preserveSessionStats: true)
                await Task.yield()
                self.isStoppingForModelSwitch = false
            }

            guard !self.server.isRunning else {
                self.appendLog("\nCould not stop the current server to switch models.\n")
                self.modelSwitchInProgress = false
                self.modelSwitchTargetID = nil
                self.clearPreservedSessionStats()
                self.notifyMenuStateChanged()
                return
            }
            self.startServer()
            if !self.server.isRunning {
                self.modelSwitchInProgress = false
                self.modelSwitchTargetID = nil
                self.clearPreservedSessionStats()
                self.notifyMenuStateChanged()
            }
        }
    }

    private func preloadMemoryWarning(
        for candidate: LocalModel,
        slot: ModelPreloadSlot,
        availableModels: [LocalModel]
    ) -> ModelPreloadMemoryWarning? {
        let totalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        guard let candidateEstimate = candidate.memoryEstimate(
            totalMemoryBytes: totalMemoryBytes
        ) else {
            return nil
        }

        let workingSetBytesByModelID = availableModels.reduce(
            into: [String: UInt64]()
        ) { estimates, localModel in
            guard let estimate = localModel.memoryEstimate(
                totalMemoryBytes: totalMemoryBytes
            ) else {
                return
            }
            estimates[localModel.repoID] = max(
                estimates[localModel.repoID] ?? 0,
                estimate.workingSetBytes
            )
        }
        var currentSelections = [ModelPreloadSlot: String]()
        let normalizedSettings = settings.normalized()
        for selectionSlot in ModelPreloadSlot.allCases {
            currentSelections[selectionSlot] = normalizedSettings.modelID(for: selectionSlot)
        }

        return ModelPreloadMemoryWarning.evaluate(
            candidateModelID: candidate.repoID,
            candidateSlot: slot,
            currentSelections: currentSelections,
            workingSetBytesByModelID: workingSetBytesByModelID,
            memoryBudgetBytes: candidateEstimate.memoryBudgetBytes,
            totalMemoryBytes: candidateEstimate.totalMemoryBytes
        )
    }

    func applicationWillTerminate() {
        mcpServers.stopAllSynchronously()
        stopMetricsPolling(clearSession: true)
        if server.isRunning {
            try? server.stop(timeout: 2)
        }
        isRunning = false
        settingsAppliedAtServerStart = nil
        huggingFaceTokenAppliedAtServerStart = nil
    }

    func resetSettings() {
        settings = NativSettings()
    }

    func clearLogs() {
        logText = ""
    }

    func reportModelLoadFailure(modelID: String?, error: Error) {
        reportModelLoadFailure(modelID: modelID, message: error.localizedDescription)
    }

    func reportModelLoadFailure(modelID: String?, message: String) {
        guard let message = NativServerErrorMessage.modelLoadFailure(in: message) else {
            return
        }
        setModelLoadFailure(modelID: modelID, message: message)
    }

    func clearModelLoadFailure(for modelID: String? = nil) {
        guard let currentFailure = modelLoadFailure else {
            return
        }
        if let modelID,
           let failedModelID = currentFailure.modelID,
           failedModelID != modelID {
            return
        }
        self.modelLoadFailure = nil
        notifyMenuStateChanged()
    }

    func refreshMetricsIfRunning(force: Bool = false) {
        isRunning = server.isRunning
        guard isRunning else {
            stopMetricsPolling(clearSession: true)
            notifyMenuStateChanged()
            return
        }
        guard metricsFetchTask == nil else {
            return
        }
        guard force || metricsAreStale else {
            return
        }

        let client = metricsClient
        let serverAPIKey = settingsAppliedAtServerStart?.serverAPIKey
        metricsFetchTask = Task { [weak self] in
            do {
                let fetchedMetrics = try await client.fetchMetrics(apiKey: serverAPIKey)
                await MainActor.run {
                    self?.handleMetricsFetchSuccess(fetchedMetrics)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.metricsFetchTask = nil
                }
            } catch {
                await MainActor.run {
                    self?.handleMetricsFetchFailure(error)
                }
            }
        }
    }

    private func configureServerCallbacks() {
        server.onOutput = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.handleServerOutput(text)
            }
        }
        server.onTermination = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, !self.server.isRunning else {
                    return
                }
                let wasLoadingModel = self.modelSwitchInProgress
                    || self.metricsLoading
                    || self.modelLoadingProgress != nil
                if wasLoadingModel,
                   status != 0,
                   !self.isStoppingForModelSwitch,
                   let message = NativServerErrorMessage.modelLoadFailure(
                       in: self.currentServerOutput
                    ) {
                    self.setModelLoadFailure(
                        modelID: self.modelSwitchTargetID,
                        message: message
                    )
                }
                self.appendLog("\nmlx-vlm-server stopped with status \(status)\n")
                self.isRunning = false
                self.settingsAppliedAtServerStart = nil
                self.huggingFaceTokenAppliedAtServerStart = nil
                self.stopMetricsPolling(clearSession: true)
                self.metricsLoading = false
                self.modelLoadingProgress = nil
                if !self.isStoppingForModelSwitch {
                    self.modelSwitchInProgress = false
                    self.modelSwitchTargetID = nil
                    self.clearPreservedSessionStats()
                }
                self.notifyMenuStateChanged()
            }
        }
    }

    private func startMetricsPolling() {
        lastMetricsError = nil
        metrics = nil
        metricsLoading = true
        sessionTokenActivity = []
        previousSessionPromptTokenCount = nil
        previousSessionGeneratedTokenCount = nil
        metricsStartupGraceUntil = Date().addingTimeInterval(20)

        if metricsTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    self.refreshMetricsIfRunning(force: self.metricsLoading)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            metricsTimer = timer
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.refreshMetricsIfRunning(force: true)
        }
    }

    private func stopMetricsPolling(clearSession: Bool) {
        metricsFetchTask?.cancel()
        metricsFetchTask = nil
        metricsTimer?.invalidate()
        metricsTimer = nil
        lastMetricsError = nil
        lastMetricsFetchAt = nil
        metricsStartupGraceUntil = nil
        metricsLoading = false
        modelLoadingProgress = nil

        if clearSession {
            metrics = nil
            sessionTokenActivity = []
            previousSessionPromptTokenCount = nil
            previousSessionGeneratedTokenCount = nil
        }
    }

    private func handleMetricsFetchSuccess(_ fetchedMetrics: NativMetrics) {
        metricsFetchTask = nil
        lastMetricsFetchAt = Date()
        guard server.isRunning else {
            isRunning = false
            metrics = nil
            notifyMenuStateChanged()
            return
        }

        isRunning = true
        lastMetricsError = nil
        metricsStartupGraceUntil = nil
        metricsLoading = false
        modelLoadingProgress = nil
        recordSessionActivity(
            promptTokenCount: fetchedMetrics.summary.promptTokensTotal,
            generatedTokenCount: fetchedMetrics.summary.generatedTokensTotal
        )
        metrics = fetchedMetrics
        modelSwitchInProgress = false
        modelSwitchTargetID = nil
        clearPreservedSessionStats()
        refreshAllTimeStats(runtimePath: fetchedMetrics.server.analyticsDatabasePath)

        if menuIsOpen {
            notifyMenuStateChanged()
        }
    }

    private func handleMetricsFetchFailure(_ error: Error) {
        metricsFetchTask = nil
        lastMetricsError = isTransientStartupMetricsError(error) ? nil : error.localizedDescription

        if !menuIsOpen {
            notifyMenuStateChanged()
        }
    }

    private func isTransientStartupMetricsError(_ error: Error) -> Bool {
        guard let metricsStartupGraceUntil, Date() < metricsStartupGraceUntil else {
            return false
        }
        guard let urlError = error as? URLError else {
            return false
        }

        switch urlError.code {
        case .cannotConnectToHost, .networkConnectionLost, .timedOut:
            return true
        default:
            return false
        }
    }

    private func appendLog(_ text: String) {
        logText.append(text)
        if logText.count > maxLogCharacters {
            logText.removeFirst(logText.count - maxLogCharacters)
        }
    }

    private func handleServerOutput(_ text: String) {
        let prefix = "__NATIV_MODEL_LOAD_PROGRESS__:"
        var visibleLines: [Substring] = []

        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline) {
            guard let markerRange = line.range(of: prefix) else {
                visibleLines.append(line)
                continue
            }

            let rawValue = line[markerRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Double(rawValue) {
                modelLoadingProgress = min(max(value, 0), 1)
                if menuIsOpen {
                    notifyMenuStateChanged()
                }
            }

            let leadingText = line[..<markerRange.lowerBound]
            if !leadingText.isEmpty {
                visibleLines.append(leadingText)
            }
        }

        let visibleText = visibleLines.joined(separator: "\n")
        if !visibleText.isEmpty {
            appendLog(visibleText)
            currentServerOutput.append(visibleText)
            if currentServerOutput.count > maxCurrentServerOutputCharacters {
                currentServerOutput.removeFirst(
                    currentServerOutput.count - maxCurrentServerOutputCharacters
                )
            }
        }
    }

    private func setModelLoadFailure(modelID: String?, message: String) {
        modelLoadFailure = ModelLoadFailure(modelID: modelID, message: message)
        appendLog("\n\(message)\n")
        notifyMenuStateChanged()
    }

    private func recordSessionActivity(promptTokenCount: Int, generatedTokenCount: Int) {
        let promptDelta = tokenDelta(
            current: promptTokenCount,
            previous: previousSessionPromptTokenCount
        )
        let generatedDelta = tokenDelta(
            current: generatedTokenCount,
            previous: previousSessionGeneratedTokenCount
        )

        sessionTokenActivity.append(SessionTokenActivitySample(
            recordedAt: Date(),
            promptTokens: promptDelta,
            generatedTokens: generatedDelta
        ))
        if sessionTokenActivity.count > maxSessionActivitySamples {
            sessionTokenActivity.removeFirst(sessionTokenActivity.count - maxSessionActivitySamples)
        }
        previousSessionPromptTokenCount = promptTokenCount
        previousSessionGeneratedTokenCount = generatedTokenCount
    }

    private func tokenDelta(current: Int, previous: Int?) -> Int {
        guard let previous, current >= previous else {
            return 0
        }
        return current - previous
    }

    private func preserveCurrentSessionStats() {
        if let metrics {
            preservedSessionMetrics = metrics
            preservedSessionTokenActivity = sessionTokenActivity
        }
    }

    private func clearPreservedSessionStats() {
        preservedSessionMetrics = nil
        preservedSessionTokenActivity = []
    }

    private func refreshAllTimeStats(runtimePath: String? = nil) {
        allTimeStats = NativAllTimeStats.load(
            from: currentAnalyticsDatabaseURL(runtimePath: runtimePath)
        )
    }

    private func currentAnalyticsDatabaseURL(runtimePath: String? = nil) -> URL {
        if let runtimePath = runtimePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !runtimePath.isEmpty {
            return URL(fileURLWithPath: runtimePath).standardizedFileURL
        }
        return NativAnalyticsStore.defaultDatabaseURL()
    }

    private func notifyMenuStateChanged() {
        onMenuStateChanged?()
    }
}
