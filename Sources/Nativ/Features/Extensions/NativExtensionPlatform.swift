import AppKit
import AVFoundation
@preconcurrency import ExtensionFoundation
import Foundation
import NativExtensionSDK
import Observation
import SwiftUI

enum NativExtensionOrigin: Hashable, Sendable {
    case included
    case external(URL)
    case system

    /// Extensions shipped inside Nativ sort ahead of ones that were installed,
    /// so a package manifest cannot order itself above first-party navigation.
    var precedence: Int {
        switch self {
        case .included: 0
        case .external, .system: 1
        }
    }
}

struct NativExtensionRecord: Identifiable, Hashable, Sendable {
    let manifest: NativExtensionManifest
    let origin: NativExtensionOrigin
    let state: NativExtensionInstallState
    let hasRuntime: Bool
    let runtimeBundleIdentifier: String?
    let errorMessage: String?

    var id: String { manifest.id }
    var isIncluded: Bool { origin == .included }
    var isEnabled: Bool { state == .enabled }
    var isRemoved: Bool { state == .removed }
}

struct NativExtensionPageContext {
    let model: NativModel
    let titleLeadingInset: CGFloat
    let openSpeechModels: () -> Void
}

struct NativExtensionHostContext {
    let transcriptionConfiguration:
        @MainActor @Sendable () -> VoiceTranscriptionConfiguration?
    let openSpeechModels: () -> Void
    let showMainWindow: () -> Void
}

@MainActor
protocol NativHostExtension: AnyObject {
    var manifest: NativExtensionManifest { get }
    func activate(context: NativExtensionHostContext)
    func deactivate()
    func makePage(id: String, context: NativExtensionPageContext) -> AnyView?
    func performCommand(id: String)
}

extension NativHostExtension {
    func performCommand(id: String) {}
}

/// Ordering for extension-contributed sidebar items.
///
/// `order` comes from a package manifest, so an external extension could
/// otherwise place itself above Nativ's own navigation. Included extensions are
/// always ordered ahead of external ones regardless of the value they declare.
enum NativExtensionSidebarOrdering {
    static func contributions(
        from records: [NativExtensionRecord]
    ) -> [NativSidebarContribution] {
        records
            .filter { $0.isEnabled && $0.hasRuntime }
            .flatMap { record in
                record.manifest.contributions.sidebar.map {
                    (precedence: record.origin.precedence, contribution: $0)
                }
            }
            .sorted { lhs, rhs in
                if lhs.precedence != rhs.precedence {
                    return lhs.precedence < rhs.precedence
                }
                if lhs.contribution.order != rhs.contribution.order {
                    return lhs.contribution.order < rhs.contribution.order
                }
                return lhs.contribution.title
                    .localizedStandardCompare(rhs.contribution.title) == .orderedAscending
            }
            .map(\.contribution)
    }
}

@MainActor
final class NativExtensionManager: ObservableObject {
    static let voiceDictationID = "com.nativ.voice-dictation"
    static let voiceAudioPageID = "com.nativ.voice-dictation.audio"

    @Published private(set) var records: [NativExtensionRecord] = [] {
        didSet {
            onRecordsChanged?()
        }
    }
    @Published private(set) var systemExtensionCount = 0
    @Published private(set) var permissionRevision = 0
    @Published private(set) var packageIssues: [NativExtensionPackageIssue] = []
    @Published var lastErrorMessage: String?
    var onRecordsChanged: (() -> Void)?

    private let stateStore: NativExtensionStateStore
    private let fileManager: FileManager
    private let extensionsDirectory: URL
    private let hostVersion: String
    private let installer: NativExtensionPackageInstaller
    private let builtIns: [String: any NativHostExtension]
    private var externalManifests: [String: NativExtensionInstalledPackage] = [:]
    private var activeExtensionIDs = Set<String>()
    private var hostContext: NativExtensionHostContext?
    private var systemMonitor: AppExtensionPoint.Monitor?
    private var systemIdentities: [String: AppExtensionIdentity] = [:]
    private var systemProcesses: [String: AppExtensionProcess] = [:]
    private var systemConnections: [String: NSXPCConnection] = [:]
    private var systemHostBrokers: [String: NativExtensionHostBroker] = [:]
    private var systemRuntimeStartTasks: [String: Task<Void, Never>] = [:]
    private var applicationActivationObserver: NSObjectProtocol?
    private let permissionDefaults: UserDefaults
    private static let permissionRequestKey =
        "nativ.extension-platform.requested-permissions.v1"
    private var requestedPermissions: Set<String>
    private var grantedPermissionSnapshot: Set<NativExtensionPermission> = []

    init(
        builtInExtensions: [any NativHostExtension],
        stateStore: NativExtensionStateStore = .init(),
        fileManager: FileManager = .default,
        extensionsDirectory: URL? = nil,
        hostVersion: String? = nil,
        permissionDefaults: UserDefaults = .standard
    ) {
        self.stateStore = stateStore
        self.fileManager = fileManager
        self.extensionsDirectory = extensionsDirectory
            ?? Self.defaultExtensionsDirectory(fileManager: fileManager)
        self.hostVersion = hostVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.1.0"
        self.permissionDefaults = permissionDefaults
        requestedPermissions = Set(
            permissionDefaults.stringArray(forKey: Self.permissionRequestKey) ?? []
        )
        installer = NativExtensionPackageInstaller(
            fileManager: fileManager,
            extensionsDirectory: self.extensionsDirectory,
            hostVersion: self.hostVersion
        )
        builtIns = Dictionary(uniqueKeysWithValues: builtInExtensions.map {
            ($0.manifest.id, $0)
        })
        reloadInstalledPackages()
    }

    var enabledSidebarContributions: [NativSidebarContribution] {
        NativExtensionSidebarOrdering.contributions(from: records)
    }

    func isEnabled(extensionID: String) -> Bool {
        records.contains {
            $0.id == extensionID && $0.isEnabled && $0.hasRuntime
        }
    }

    func launch(context: NativExtensionHostContext) {
        hostContext = context
        grantedPermissionSnapshot = currentGrantedPermissions()
        if applicationActivationObserver == nil {
            applicationActivationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshPermissionStatuses()
                }
            }
        }
        reconcileLifecycle()
        Task {
            await discoverSystemExtensions()
        }
    }

    func shutdown() {
        for extensionID in activeExtensionIDs {
            builtIns[extensionID]?.deactivate()
        }
        activeExtensionIDs.removeAll()
        hostContext = nil
        if let applicationActivationObserver {
            NotificationCenter.default.removeObserver(applicationActivationObserver)
        }
        applicationActivationObserver = nil
        systemMonitor = nil
        systemIdentities.removeAll()
        systemRuntimeStartTasks.values.forEach { $0.cancel() }
        systemRuntimeStartTasks.removeAll()
        for connection in systemConnections.values {
            connection.invalidate()
        }
        systemConnections.removeAll()
        systemHostBrokers.removeAll()
        for process in systemProcesses.values {
            process.invalidate()
        }
        systemProcesses.removeAll()
    }

    func refresh() {
        reloadInstalledPackages()
        Task {
            await discoverSystemExtensions()
        }
    }

    func setEnabled(_ enabled: Bool, extensionID: String) {
        guard let record = records.first(where: { $0.id == extensionID }),
              !record.isRemoved else {
            return
        }
        let shouldRequestMicrophone = enabled
            && !record.isEnabled
            && record.manifest.permissions.contains(.microphone)
        stateStore.set(enabled ? .enabled : .disabled, for: extensionID)
        rebuildRecords()
        reconcileLifecycle()
        if shouldRequestMicrophone {
            requestPermission(.microphone)
        }
    }

    func remove(extensionID: String) {
        guard let record = records.first(where: { $0.id == extensionID }) else {
            return
        }

        if case .external(let packageURL) = record.origin {
            builtIns[extensionID]?.deactivate()
            stopSystemRuntime(extensionID: extensionID)
            activeExtensionIDs.remove(extensionID)
            do {
                try installer.removePackage(at: packageURL)
                stateStore.clear(extensionID: extensionID)
                    lastErrorMessage = nil
                reloadInstalledPackages()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            return
        }

        stateStore.set(.removed, for: extensionID)
        rebuildRecords()
        reconcileLifecycle()
    }

    func restore(extensionID: String) {
        guard let record = records.first(where: { $0.id == extensionID }),
              record.isRemoved else {
            return
        }
        let shouldRequestMicrophone = record.manifest.permissions.contains(.microphone)
        stateStore.set(.enabled, for: extensionID)
        rebuildRecords()
        reconcileLifecycle()
        if shouldRequestMicrophone {
            requestPermission(.microphone)
        }
    }

    func installPackage(at sourceURL: URL) {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let result = try installer.install(
                from: sourceURL,
                reservedIdentifiers: Set(builtIns.keys)
            )
            // Installing code and granting it permission to run are separate
            // decisions. A first install, or an update that asks for more than
            // the last one, returns to disabled so the user reviews it.
            if result.requiresReconsent {
                stateStore.set(.disabled, for: result.manifest.id)
            }
            setLastError(nil)
            reloadInstalledPackages()
            reconcileLifecycle()
        } catch {
            setLastError(error.localizedDescription)
        }
    }

    private func setLastError(_ message: String?) {
        guard lastErrorMessage != message else {
            return
        }
        lastErrorMessage = message
    }

    func makePage(
        id pageID: String,
        context: NativExtensionPageContext
    ) -> AnyView? {
        guard let record = record(containingPage: pageID),
              record.isEnabled,
              record.hasRuntime else {
            return nil
        }
        return builtIns[record.id]?.makePage(id: pageID, context: context)
    }

    func performCommand(id commandID: String) {
        guard let record = records.first(where: {
            $0.isEnabled
                && $0.hasRuntime
                && $0.manifest.contributions.commands.contains(where: { $0.id == commandID })
        }) else {
            return
        }
        builtIns[record.id]?.performCommand(id: commandID)
    }

    func record(containingPage pageID: String) -> NativExtensionRecord? {
        records.first {
            $0.manifest.contributions.sidebar.contains(where: { $0.id == pageID })
        }
    }

    /// Whether the host itself holds the grant. System grants are process-wide,
    /// so this is independent of which extension is asking.
    private func isPermissionGranted(_ permission: NativExtensionPermission) -> Bool {
        switch permission {
        case .microphone:
            NativSystemPermissionController.hasMicrophoneAccess()
        case .systemAudioCapture:
            NativSystemPermissionController.hasScreenCaptureAccess()
        case .accessibilityInsertText:
            NativSystemPermissionController.hasInsertTextAccess()
        case .readSelection:
            NativSystemPermissionController.hasAccessibilityAccess()
        // Nothing outside Nativ gates these, so consent is the manifest
        // declaration the user reviewed before enabling the extension.
        case .readClipboard, .writeClipboard, .saveFile, .overlay, .namespacedStorage,
             .modelsLanguage, .modelsVision, .modelsImageGeneration,
             .modelsImageEditing, .modelsSpeechToText, .modelsTextToSpeech,
             .modelsEmbedding:
            true
        case .screenCapture:
            NativSystemPermissionController.hasScreenCaptureAccess()
        case .notifications:
            false
        }
    }

    func permissionStatus(
        _ permission: NativExtensionPermission
    ) -> NativExtensionPermissionStatus {
        switch permission {
        case .microphone:
            if isPermissionGranted(permission) {
                return .granted
            }
            return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
                ? .notRequested
                : .denied
        case .systemAudioCapture, .accessibilityInsertText, .readSelection, .screenCapture:
            if isPermissionGranted(permission) {
                return .granted
            }
            // macOS gives no way to tell "declined" from "never asked", so the
            // distinction comes from whether this extension has prompted before.
            return requestedPermissions.contains(permission.rawValue)
                ? .denied
                : .notRequested
        case .readClipboard, .writeClipboard, .saveFile, .overlay, .namespacedStorage,
             .modelsLanguage, .modelsVision, .modelsImageGeneration,
             .modelsImageEditing, .modelsSpeechToText, .modelsTextToSpeech,
             .modelsEmbedding:
            return .granted
        case .notifications:
            return .notRequested
        }
    }

    func permissionActionTitle(
        _ permission: NativExtensionPermission,
        status: NativExtensionPermissionStatus
    ) -> String? {
        guard status != .granted else {
            return nil
        }
        switch permission {
        case .microphone, .systemAudioCapture, .accessibilityInsertText,
             .readSelection, .screenCapture:
            return status == .denied ? "Open Settings" : "Request"
        case .notifications, .readClipboard, .writeClipboard, .saveFile, .overlay,
             .namespacedStorage, .modelsLanguage, .modelsVision,
             .modelsImageGeneration, .modelsImageEditing, .modelsSpeechToText,
             .modelsTextToSpeech, .modelsEmbedding:
            return nil
        }
    }

    func requestPermission(_ permission: NativExtensionPermission) {
        switch permission {
        case .microphone:
            markPermissionRequested(permission)
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                Task { [weak self] in
                    _ = await NativSystemPermissionController.requestMicrophone()
                    self?.refreshPermissionStatuses()
                }
            case .denied, .restricted:
                NativSystemPermissionController.openMicrophoneSettings()
                refreshPermissionStatuses()
            case .authorized:
                refreshPermissionStatuses()
            @unknown default:
                refreshPermissionStatuses()
            }
        case .systemAudioCapture:
            markPermissionRequested(permission)
            if NativSystemPermissionController.requestScreenCaptureAccess() {
                refreshPermissionStatuses()
            } else {
                NativSystemPermissionController.openScreenCaptureSettings()
                refreshPermissionStatuses()
            }
        case .accessibilityInsertText, .readSelection:
            markPermissionRequested(permission)
            _ = NativSystemPermissionController.requestInsertTextAccess()
            refreshPermissionStatuses()
            if !NativSystemPermissionController.hasInsertTextAccess() {
                NativSystemPermissionController.openAccessibilitySettings()
            }
        case .screenCapture:
            markPermissionRequested(permission)
            if !NativSystemPermissionController.requestScreenCaptureAccess() {
                NativSystemPermissionController.openScreenCaptureSettings()
            }
            refreshPermissionStatuses()
        case .notifications:
            // No included extension currently requests notifications. Keep the
            // declaration visible without prompting for an unused capability.
            break
        case .readClipboard, .writeClipboard, .saveFile, .overlay, .namespacedStorage,
             .modelsLanguage, .modelsVision, .modelsImageGeneration,
             .modelsImageEditing, .modelsSpeechToText, .modelsTextToSpeech,
             .modelsEmbedding:
            break
        }
    }

    func refreshPermissionStatuses() {
        permissionRevision &+= 1
        let nextSnapshot = currentGrantedPermissions()
        guard nextSnapshot != grantedPermissionSnapshot else {
            return
        }
        grantedPermissionSnapshot = nextSnapshot

        // An extension runtime receives its granted permissions at activation.
        // Restart active runtimes when a system grant changes so their broker
        // and activation context cannot retain stale permission state.
        for extensionID in activeExtensionIDs
        where systemIdentities[
            records.first(where: { $0.id == extensionID })?
                .manifest.runtimeBundleIdentifier ?? ""
        ] != nil {
            stopSystemRuntime(extensionID: extensionID)
            startSystemRuntimeIfAvailable(extensionID: extensionID)
        }
    }

    private func markPermissionRequested(_ permission: NativExtensionPermission) {
        guard requestedPermissions.insert(permission.rawValue).inserted else {
            return
        }
        permissionDefaults.set(
            requestedPermissions.sorted(),
            forKey: Self.permissionRequestKey
        )
        permissionRevision &+= 1
    }

    private func currentGrantedPermissions() -> Set<NativExtensionPermission> {
        Set(NativExtensionPermission.allCases.filter(isPermissionGranted))
    }

    private func reconcileLifecycle() {
        guard let hostContext else {
            return
        }
        let shouldBeActive = Set(
            records
                .filter { $0.isEnabled && $0.hasRuntime }
                .map(\.id)
        )

        for extensionID in activeExtensionIDs.subtracting(shouldBeActive) {
            builtIns[extensionID]?.deactivate()
            stopSystemRuntime(extensionID: extensionID)
            activeExtensionIDs.remove(extensionID)
        }
        for extensionID in shouldBeActive.subtracting(activeExtensionIDs) {
            if let hostExtension = builtIns[extensionID] {
                hostExtension.activate(context: hostContext)
            }
            activeExtensionIDs.insert(extensionID)
            startSystemRuntimeIfAvailable(extensionID: extensionID)
        }
    }

    private func reloadInstalledPackages() {
        let result = installer.loadInstalledPackages(
            reservedIdentifiers: Set(builtIns.keys)
        )
        externalManifests = result.manifests
        if packageIssues != result.issues {
            packageIssues = result.issues
        }
        rebuildRecords()
    }

    private func rebuildRecords() {
        var nextRecords = builtIns.values.map { hostExtension in
            let manifest = hostExtension.manifest
            return NativExtensionRecord(
                manifest: manifest,
                origin: .included,
                state: stateStore.state(for: manifest),
                hasRuntime: true,
                runtimeBundleIdentifier: nil,
                errorMessage: nil
            )
        }

        nextRecords += externalManifests.values.map { installed in
            let manifest = installed.manifest
            let systemIdentity = manifest.runtimeBundleIdentifier.flatMap {
                systemIdentities[$0]
            }
            return NativExtensionRecord(
                manifest: manifest,
                origin: .external(installed.packageURL),
                state: stateStore.state(for: manifest),
                hasRuntime: systemIdentity != nil,
                runtimeBundleIdentifier:
                    systemIdentity?.bundleIdentifier
                    ?? manifest.runtimeBundleIdentifier,
                errorMessage: systemIdentity == nil
                    ? NativExtensionPackageError.runtimeUnavailable.localizedDescription
                    : nil
            )
        }

        let knownManifestIDs = Set(nextRecords.map(\.id))
        let claimedRuntimeBundleIdentifiers = Set(
            nextRecords.compactMap(\.manifest.runtimeBundleIdentifier)
        )
        nextRecords += systemIdentities.compactMap { bundleIdentifier, identity in
            let manifestID = bundleIdentifier
            guard !knownManifestIDs.contains(manifestID),
                  !claimedRuntimeBundleIdentifiers.contains(bundleIdentifier) else {
                return nil
            }
            let manifest = NativExtensionManifest(
                id: manifestID,
                version: "1.0.0",
                minimumNativVersion: "0.1.0",
                displayName: identity.localizedName,
                summary: "A system extension available to Nativ.",
                developer: "Third-party developer",
                systemImage: "puzzlepiece.extension",
                included: false,
                runtime: .extensionFoundation,
                runtimeBundleIdentifier: identity.bundleIdentifier
            )
            return NativExtensionRecord(
                manifest: manifest,
                origin: .system,
                state: stateStore.state(for: manifest),
                hasRuntime: true,
                runtimeBundleIdentifier: identity.bundleIdentifier,
                errorMessage: nil
            )
        }

        records = nextRecords.sorted {
            if $0.origin.precedence != $1.origin.precedence {
                return $0.origin.precedence < $1.origin.precedence
            }
            return $0.manifest.displayName.localizedStandardCompare(
                $1.manifest.displayName
            ) == .orderedAscending
        }
    }

    private func discoverSystemExtensions() async {
        do {
            let monitor: AppExtensionPoint.Monitor
            if let systemMonitor {
                monitor = systemMonitor
            } else {
                monitor = try await AppExtensionPoint.Monitor(
                    appExtensionPoint: .nativExtensions
                )
                systemMonitor = monitor
            }
            systemExtensionCount = monitor.identities.count
            systemIdentities = Dictionary(
                monitor.identities.map {
                    ($0.bundleIdentifier, $0)
                },
                uniquingKeysWith: { discovered, _ in discovered }
            )
            rebuildRecords()
            reconcileLifecycle()
            for extensionID in activeExtensionIDs {
                startSystemRuntimeIfAvailable(extensionID: extensionID)
            }
        } catch {
            NSLog(
                "Nativ ExtensionFoundation discovery failed: %@",
                error.localizedDescription
            )
        }
    }

    private func startSystemRuntimeIfAvailable(extensionID: String) {
        guard systemProcesses[extensionID] == nil,
              systemRuntimeStartTasks[extensionID] == nil,
              let record = records.first(where: { $0.id == extensionID }),
              record.manifest.runtime == .extensionFoundation,
              let runtimeBundleIdentifier = record.manifest.runtimeBundleIdentifier,
              let identity = systemIdentities[runtimeBundleIdentifier] else {
            return
        }

        systemRuntimeStartTasks[extensionID] = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.systemRuntimeStartTasks[extensionID] = nil
            }
            do {
                let process = try await AppExtensionProcess(
                    configuration: .init(
                        appExtensionIdentity: identity,
                        onInterruption: { [weak self] in
                            Task { @MainActor in
                                self?.systemConnections[extensionID]?.invalidate()
                                self?.systemConnections[extensionID] = nil
                                self?.systemProcesses[extensionID] = nil
                            }
                        }
                    )
                )
                guard !Task.isCancelled else {
                    process.invalidate()
                    return
                }
                let connection = try process.makeXPCConnection()
                connection.remoteObjectInterface = NSXPCInterface(
                    with: NativExtensionXPCProtocol.self
                )

                let dataDirectory = Self.defaultExtensionsDirectory(
                    fileManager: fileManager
                )
                .appendingPathComponent("Data", isDirectory: true)
                .appendingPathComponent(extensionID, isDirectory: true)
                try fileManager.createDirectory(
                    at: dataDirectory,
                    withIntermediateDirectories: true
                )
                let grantedPermissions = Set(
                    record.manifest.permissions.filter {
                        self.isPermissionGranted($0)
                    }
                )
                guard let hostContext = self.hostContext else {
                    throw NativExtensionPackageError.runtimeUnavailable
                }
                let hostBroker = NativExtensionHostBroker(
                    extensionID: extensionID,
                    hostVersion: hostVersion,
                    grantedPermissions: grantedPermissions,
                    storageDirectory: dataDirectory,
                    transcriptionConfiguration: hostContext.transcriptionConfiguration
                )
                connection.exportedInterface = NSXPCInterface(
                    with: NativExtensionHostXPCProtocol.self
                )
                connection.exportedObject = hostBroker
                connection.resume()
                let activationData = try JSONEncoder().encode(
                    NativExtensionActivationContext(
                        hostVersion: hostVersion,
                        extensionID: extensionID,
                        dataDirectoryPath: dataDirectory.path,
                        grantedPermissions: grantedPermissions
                    )
                )
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    NSLog(
                        "Nativ extension runtime %@ failed: %@",
                        extensionID,
                        error.localizedDescription
                    )
                }) as? NativExtensionXPCProtocol else {
                    throw NativExtensionPackageError.runtimeUnavailable
                }
                proxy.activate(with: activationData) { errorMessage in
                    if let errorMessage {
                        NSLog(
                            "Nativ extension runtime %@ rejected activation: %@",
                            extensionID,
                            errorMessage
                        )
                    }
                }
                systemProcesses[extensionID] = process
                systemConnections[extensionID] = connection
                systemHostBrokers[extensionID] = hostBroker
            } catch {
                NSLog(
                    "Nativ could not launch extension runtime %@: %@",
                    extensionID,
                    error.localizedDescription
                )
            }
        }
    }

    private func stopSystemRuntime(extensionID: String) {
        systemRuntimeStartTasks[extensionID]?.cancel()
        systemRuntimeStartTasks[extensionID] = nil
        if let connection = systemConnections.removeValue(forKey: extensionID) {
            if let proxy = connection.remoteObjectProxy as? NativExtensionXPCProtocol {
                proxy.deactivate {}
            }
            connection.invalidate()
        }
        systemHostBrokers[extensionID] = nil
        systemProcesses.removeValue(forKey: extensionID)?.invalidate()
    }

    private static func defaultExtensionsDirectory(fileManager: FileManager) -> URL {
        let applicationSupport =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
    }
}

enum NativExtensionPermissionStatus: Hashable {
    case granted
    case denied
    case notRequested

    var title: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Denied"
        case .notRequested: "Not requested"
        }
    }

}

extension AppExtensionPoint {
    @AppExtensionPoint.Definition
    static var nativExtensions: AppExtensionPoint {
        AppExtensionPoint.Name("nativ-extension")
        AppExtensionPoint.Scope(restriction: .none)
    }
}
