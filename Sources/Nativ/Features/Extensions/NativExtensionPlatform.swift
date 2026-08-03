import AppKit
import AVFoundation
import ExtensionFoundation
import Foundation
import NativExtensionSDK
import Observation
import SwiftUI

enum NativExtensionOrigin: Hashable, Sendable {
    case included
    case external(URL)
    case system
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
    let transcriptionConfiguration: () -> VoiceTranscriptionConfiguration?
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

enum NativExtensionPackageError: LocalizedError {
    case packageMustBeDirectory
    case missingManifest
    case duplicateIdentifier(String)
    case externalPackageClaimsIncluded
    case runtimeUnavailable

    var errorDescription: String? {
        switch self {
        case .packageMustBeDirectory:
            "Choose a .nativextension package."
        case .missingManifest:
            "The extension package does not contain Manifest.json."
        case .duplicateIdentifier(let identifier):
            "An extension with the identifier “\(identifier)” is already included with Nativ."
        case .externalPackageClaimsIncluded:
            "Only extensions shipped inside Nativ can declare themselves as included."
        case .runtimeUnavailable:
            "The extension was installed, but its ExtensionFoundation runtime is not available yet."
        }
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
    @Published var lastErrorMessage: String?
    var onRecordsChanged: (() -> Void)?

    private let stateStore: NativExtensionStateStore
    private let fileManager: FileManager
    private let extensionsDirectory: URL
    private let hostVersion: String
    private let builtIns: [String: any NativHostExtension]
    private var externalManifests: [String: (NativExtensionManifest, URL)] = [:]
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
    private let permissionRequestKey = "nativ.extension-platform.requested-permissions.v1"
    private var requestedPermissions: Set<String>
    private var permissionSnapshot: [NativExtensionPermission: NativExtensionPermissionStatus] = [:]

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
            permissionDefaults.stringArray(
                forKey: "nativ.extension-platform.requested-permissions.v1"
            ) ?? []
        )
        builtIns = Dictionary(uniqueKeysWithValues: builtInExtensions.map {
            ($0.manifest.id, $0)
        })
        reloadInstalledPackages()
    }

    var enabledSidebarContributions: [NativSidebarContribution] {
        records
            .filter { $0.isEnabled && $0.hasRuntime }
            .flatMap(\.manifest.contributions.sidebar)
            .sorted {
                if $0.order == $1.order {
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                return $0.order < $1.order
            }
    }

    func isEnabled(extensionID: String) -> Bool {
        records.contains {
            $0.id == extensionID && $0.isEnabled && $0.hasRuntime
        }
    }

    func launch(context: NativExtensionHostContext) {
        hostContext = context
        permissionSnapshot = currentPermissionSnapshot()
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
        stateStore.set(enabled ? .enabled : .disabled, for: extensionID)
        rebuildRecords()
        reconcileLifecycle()
    }

    func remove(extensionID: String) {
        guard let record = records.first(where: { $0.id == extensionID }) else {
            return
        }

        if case .external(let packageURL) = record.origin {
            builtIns[extensionID]?.deactivate()
            activeExtensionIDs.remove(extensionID)
            do {
                try fileManager.removeItem(at: packageURL)
                stateStore.clear(extensionID: extensionID)
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
        guard records.contains(where: { $0.id == extensionID }) else {
            return
        }
        stateStore.set(.enabled, for: extensionID)
        rebuildRecords()
        reconcileLifecycle()
    }

    func installPackage(at sourceURL: URL) {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  sourceURL.pathExtension == "nativextension" else {
                throw NativExtensionPackageError.packageMustBeDirectory
            }
            let manifest = try Self.loadManifest(
                from: sourceURL,
                hostVersion: hostVersion
            )
            guard builtIns[manifest.id] == nil else {
                throw NativExtensionPackageError.duplicateIdentifier(manifest.id)
            }
            guard !manifest.included else {
                throw NativExtensionPackageError.externalPackageClaimsIncluded
            }

            try fileManager.createDirectory(
                at: extensionsDirectory,
                withIntermediateDirectories: true
            )
            let stagingURL = extensionsDirectory
                .appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
            let destinationURL = extensionsDirectory
                .appendingPathComponent("\(manifest.id).nativextension", isDirectory: true)
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
            } else {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            }
            // Installing code and granting it permission to run are separate
            // decisions. The user enables the extension after reviewing the
            // manifest and permission badges in Extensions.
            stateStore.set(.disabled, for: manifest.id)
            reloadInstalledPackages()
            reconcileLifecycle()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
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

    func permissionStatus(
        _ permission: NativExtensionPermission
    ) -> NativExtensionPermissionStatus {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return .granted
            case .denied, .restricted:
                return .denied
            case .notDetermined:
                return .notRequested
            @unknown default:
                return .notRequested
            }
        case .systemAudioCapture:
            if NativSystemPermissionController.hasScreenCaptureAccess() {
                return .granted
            }
            return requestedPermissions.contains(permission.rawValue)
                ? .denied
                : .notRequested
        case .accessibilityInsertText:
            if NativSystemPermissionController.hasInsertTextAccess() {
                return .granted
            }
            return requestedPermissions.contains(permission.rawValue)
                ? .denied
                : .notRequested
        case .modelsSpeechToText, .overlay, .namespacedStorage:
            return .granted
        case .notifications:
            return .notRequested
        }
    }

    func permissionActionTitle(
        _ permission: NativExtensionPermission
    ) -> String? {
        let status = permissionStatus(permission)
        guard status != .granted else {
            return nil
        }
        switch permission {
        case .microphone, .systemAudioCapture, .accessibilityInsertText:
            return status == .denied ? "Open Settings" : "Request"
        case .notifications:
            return nil
        case .modelsSpeechToText, .overlay, .namespacedStorage:
            return nil
        }
    }

    func requestPermission(_ permission: NativExtensionPermission) {
        switch permission {
        case .microphone:
            markPermissionRequested(permission)
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                NativSystemPermissionController.requestMicrophone { [weak self] _ in
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
        case .accessibilityInsertText:
            markPermissionRequested(permission)
            _ = NativSystemPermissionController.requestInsertTextAccess()
            refreshPermissionStatuses()
            if !NativSystemPermissionController.hasInsertTextAccess() {
                NativSystemPermissionController.openAccessibilitySettings()
            }
        case .notifications:
            // No included extension currently requests notifications. Keep the
            // declaration visible without prompting for an unused capability.
            break
        case .modelsSpeechToText, .overlay, .namespacedStorage:
            break
        }
    }

    func refreshPermissionStatuses() {
        permissionRevision &+= 1
        let nextSnapshot = currentPermissionSnapshot()
        guard nextSnapshot != permissionSnapshot else {
            return
        }
        permissionSnapshot = nextSnapshot

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
        requestedPermissions.insert(permission.rawValue)
        permissionDefaults.set(
            requestedPermissions.sorted(),
            forKey: permissionRequestKey
        )
        permissionRevision &+= 1
    }

    private func currentPermissionSnapshot()
        -> [NativExtensionPermission: NativExtensionPermissionStatus]
    {
        Dictionary(
            uniqueKeysWithValues: NativExtensionPermission.allCases.map {
                ($0, permissionStatus($0))
            }
        )
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
        externalManifests.removeAll()
        if let packageURLs = try? fileManager.contentsOfDirectory(
            at: extensionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for packageURL in packageURLs where packageURL.pathExtension == "nativextension" {
                do {
                    let manifest = try Self.loadManifest(
                        from: packageURL,
                        hostVersion: hostVersion
                    )
                    guard builtIns[manifest.id] == nil else {
                        continue
                    }
                    externalManifests[manifest.id] = (manifest, packageURL)
                } catch {
                    NSLog(
                        "Nativ ignored extension package at %@: %@",
                        packageURL.path,
                        error.localizedDescription
                    )
                }
            }
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

        nextRecords += externalManifests.values.map { manifest, packageURL in
            let systemIdentity = manifest.runtimeBundleIdentifier.flatMap {
                systemIdentities[$0]
            }
            return NativExtensionRecord(
                manifest: manifest,
                origin: .external(packageURL),
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
            if $0.isIncluded != $1.isIncluded {
                return $0.isIncluded
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
                        self.permissionStatus($0) == .granted
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

    private static func loadManifest(
        from packageURL: URL,
        hostVersion: String
    ) throws -> NativExtensionManifest {
        let manifestURL = packageURL.appendingPathComponent("Manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw NativExtensionPackageError.missingManifest
        }
        let manifest = try JSONDecoder().decode(
            NativExtensionManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        try NativExtensionManifestValidator.validate(
            manifest,
            hostVersion: hostVersion
        )
        return manifest
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

    var color: Color {
        switch self {
        case .granted: .green
        case .denied: .red
        case .notRequested: .secondary
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
