import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Filters `NativModel` down to values that can change control-panel chrome.
@MainActor
final class ControlPanelChromeState: ObservableObject {
    struct ArtifactSettings: Equatable {
        let serverPort: Int
        let serverAPIKey: String?
        let modelSearchPath: String
        let modelCacheVolumeIdentifier: String?
        let localModelSearchPaths: LocalModelSearchPaths
    }

    private struct SettingsProjection: Equatable {
        let languageModelID: String?
        let sidebarPinnedCollapsed: Bool
        let sidebarProjectsCollapsed: Bool
        let sidebarFoldersCollapsed: Bool
        let sidebarSessionsCollapsed: Bool
        let artifactSettings: ArtifactSettings
    }

    private struct Snapshot: Equatable {
        var isRunning: Bool
        var modelSwitchInProgress: Bool
        var modelLoadingPercentage: Int?
        var metricsLoading: Bool
        var modelLoadFailure: ModelLoadFailure?
        var modelPreloadMemoryWarning: ModelPreloadMemoryWarning?
        var languageModelID: String?
        var sidebarPinnedCollapsed: Bool
        var sidebarProjectsCollapsed: Bool
        var sidebarFoldersCollapsed: Bool
        var sidebarSessionsCollapsed: Bool
        var artifactSettings: ArtifactSettings
    }

    @Published private var snapshot: Snapshot
    private let model: NativModel

    init(model: NativModel) {
        self.model = model
        let settings = Self.settingsProjection(model.settings)
        snapshot = Snapshot(
            isRunning: model.isRunning,
            modelSwitchInProgress: model.modelSwitchInProgress,
            modelLoadingPercentage: Self.loadingPercentage(model.modelLoadingProgress),
            metricsLoading: model.metricsLoading,
            modelLoadFailure: model.modelLoadFailure,
            modelPreloadMemoryWarning: model.modelPreloadMemoryWarning,
            languageModelID: settings.languageModelID,
            sidebarPinnedCollapsed: settings.sidebarPinnedCollapsed,
            sidebarProjectsCollapsed: settings.sidebarProjectsCollapsed,
            sidebarFoldersCollapsed: settings.sidebarFoldersCollapsed,
            sidebarSessionsCollapsed: settings.sidebarSessionsCollapsed,
            artifactSettings: settings.artifactSettings
        )

        observeModel()
    }

    private func observeModel() {
        withObservationTracking { [weak self] in
            self?.captureModelSnapshot()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeModel() }
        }
    }

    private func captureModelSnapshot() {
        let settings = Self.settingsProjection(model.settings)
        update {
            $0.isRunning = model.isRunning
            $0.modelSwitchInProgress = model.modelSwitchInProgress
            $0.modelLoadingPercentage = Self.loadingPercentage(model.modelLoadingProgress)
            $0.metricsLoading = model.metricsLoading
            $0.modelLoadFailure = model.modelLoadFailure
            $0.modelPreloadMemoryWarning = model.modelPreloadMemoryWarning
            $0.languageModelID = settings.languageModelID
            $0.sidebarPinnedCollapsed = settings.sidebarPinnedCollapsed
            $0.sidebarProjectsCollapsed = settings.sidebarProjectsCollapsed
            $0.sidebarFoldersCollapsed = settings.sidebarFoldersCollapsed
            $0.sidebarSessionsCollapsed = settings.sidebarSessionsCollapsed
            $0.artifactSettings = settings.artifactSettings
        }
    }

    var isRunning: Bool { snapshot.isRunning }
    var modelSwitchInProgress: Bool { snapshot.modelSwitchInProgress }
    var modelLoadFailure: ModelLoadFailure? { snapshot.modelLoadFailure }
    var modelPreloadMemoryWarning: ModelPreloadMemoryWarning? {
        snapshot.modelPreloadMemoryWarning
    }
    var sidebarPinnedCollapsed: Bool { snapshot.sidebarPinnedCollapsed }
    var sidebarProjectsCollapsed: Bool { snapshot.sidebarProjectsCollapsed }
    var sidebarFoldersCollapsed: Bool { snapshot.sidebarFoldersCollapsed }
    var sidebarSessionsCollapsed: Bool { snapshot.sidebarSessionsCollapsed }
    var artifactSettings: ArtifactSettings { snapshot.artifactSettings }

    var isModelLoading: Bool {
        snapshot.modelSwitchInProgress
            || (snapshot.languageModelID != nil
                && (snapshot.metricsLoading || snapshot.modelLoadingPercentage != nil))
    }

    var modelLoadingPercentageText: String? {
        snapshot.modelLoadingPercentage.map { "\($0)%" }
    }

    private func update(_ mutate: (inout Snapshot) -> Void) {
        var next = snapshot
        mutate(&next)
        guard next != snapshot else { return }
        snapshot = next
    }

    private static func loadingPercentage(_ progress: Double?) -> Int? {
        progress.map { min(max(Int(($0 * 100).rounded()), 0), 100) }
    }

    private static func settingsProjection(_ value: NativSettings) -> SettingsProjection {
        let settings = value.normalized()
        return SettingsProjection(
            languageModelID: settings.languageModelID,
            sidebarPinnedCollapsed: settings.sidebarPinnedCollapsed,
            sidebarProjectsCollapsed: settings.sidebarProjectsCollapsed,
            sidebarFoldersCollapsed: settings.sidebarFoldersCollapsed,
            sidebarSessionsCollapsed: settings.sidebarSessionsCollapsed,
            artifactSettings: ArtifactSettings(
                serverPort: settings.serverPort,
                serverAPIKey: settings.serverAPIKey,
                modelSearchPath: settings.modelSearchPath,
                modelCacheVolumeIdentifier: settings.externalModelCache?.volumeIdentifier,
                localModelSearchPaths: settings.localModelSearchPaths
            )
        )
    }
}

/// Projects the remaining low-frequency global presentation state. High-frequency
/// page state remains observed by its leaf views.
@MainActor
final class ControlPanelContentState: ObservableObject {
    private struct Snapshot: Equatable {
        var extensionSidebarContributions: [NativSidebarContribution]
        var launchAtLoginErrorMessage: String?
    }

    @Published private var snapshot: Snapshot
    private var cancellables = Set<AnyCancellable>()

    init(
        dependencies: ControlPanelDependencies,
        extensionManager: NativExtensionManager
    ) {
        snapshot = Snapshot(
            extensionSidebarContributions: extensionManager.enabledSidebarContributions,
            launchAtLoginErrorMessage: dependencies.launchAtLogin.errorMessage
        )

        extensionManager.$records
            .map(NativExtensionSidebarOrdering.contributions(from:))
            .removeDuplicates()
            .sink { [weak self] value in
                self?.update { $0.extensionSidebarContributions = value }
            }
            .store(in: &cancellables)
        dependencies.launchAtLogin.$errorMessage
            .removeDuplicates()
            .sink { [weak self] value in
                self?.update { $0.launchAtLoginErrorMessage = value }
            }
            .store(in: &cancellables)
    }

    var extensionSidebarContributions: [NativSidebarContribution] {
        snapshot.extensionSidebarContributions
    }
    var launchAtLoginErrorMessage: String? { snapshot.launchAtLoginErrorMessage }

    private func update(_ mutate: (inout Snapshot) -> Void) {
        var next = snapshot
        mutate(&next)
        guard next != snapshot else { return }
        snapshot = next
    }
}
