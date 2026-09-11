import Foundation
import NativExtensionSDK
import Observation

@Observable
@MainActor
final class NativDeclarativeExtension {
    let manifest: NativExtensionManifest
    let workflow: NativExtensionWorkflow?
    let dashboard: NativExtensionDashboard?
    let workspace: NativWorkspaceState?
    private(set) var isActive = false
    private(set) var isRunning = false
    private(set) var completedSteps = 0
    private(set) var totalSteps = 0
    private(set) var status = "Ready"
    private(set) var runError: String?

    private let services: @MainActor () -> NativWorkflowServices
    private let onFailure: @MainActor (String) -> Void
    private var grantedPermissions: Set<NativExtensionPermission>
    private var activeRun: Task<Void, Never>?
    private var runID: UUID?

    init(
        manifest: NativExtensionManifest,
        workflow: NativExtensionWorkflow?,
        dashboard: NativExtensionDashboard? = nil,
        storageDirectory: URL? = nil,
        grantedPermissions: Set<NativExtensionPermission>,
        services: @escaping @MainActor () -> NativWorkflowServices,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        self.manifest = manifest
        self.workflow = workflow
        self.dashboard = dashboard
        workspace = storageDirectory.map { NativWorkspaceState(directory: $0, fields: dashboard?.storage ?? [:]) }
        self.grantedPermissions = grantedPermissions
        self.services = services
        self.onFailure = onFailure
    }

    func activate() {
        isActive = true
    }

    func deactivate() {
        isActive = false
        cancel()
        do { try workspace?.flush() }
        catch { onFailure(error.localizedDescription) }
    }

    func cancel() {
        activeRun?.cancel()
        activeRun = nil
        runID = nil
        if isRunning { status = "Cancelled" }
        isRunning = false
    }

    func setValue(_ value: NativWorkflowValue, for key: String) {
        guard isActive, !isRunning, grantedPermissions.contains(.namespacedStorage) else { return }
        do { try workspace?.stage(key, value: value) }
        catch { workspace?.errorMessage = error.localizedDescription }
    }

    func performCommand(id commandID: String) {
        guard isActive, !isRunning, let workflow,
              workflow.trigger(forCommand: commandID) != nil else { return }
        do { try workspace?.flush() }
        catch {
            runError = error.localizedDescription
            return
        }
        let id = UUID()
        runID = id
        isRunning = true
        completedSteps = 0
        totalSteps = workflow.steps(forCommand: commandID).count
        status = manifest.contributions.commands.first(where: { $0.id == commandID })?.title ?? "Running"
        runError = nil
        var services = services()
        services.readStorage = { [weak self] key in
            try Task.checkCancellation()
            guard let self, self.isActive, self.runID == id, let workspace = self.workspace else { throw CancellationError() }
            return try workspace.read(key)
        }
        services.writeStorage = { [weak self] key, value in
            try Task.checkCancellation()
            guard let self, self.isActive, self.runID == id, let workspace = self.workspace else { throw CancellationError() }
            try workspace.write(key, value: value)
        }
        let context = NativWorkflowRunContext(
            extensionID: manifest.id,
            grantedPermissions: grantedPermissions,
            services: services
        )
        activeRun = Task { [weak self] in
            do {
                _ = try await NativWorkflowRunner.run(workflow, commandID: commandID, context: context) { [weak self] completed, _ in
                    guard self?.runID == id else { return }
                    self?.completedSteps = completed
                }
                guard self?.runID == id else { return }
                self?.status = "Completed"
            } catch is CancellationError {
                guard self?.runID == id else { return }
                self?.status = "Cancelled"
            } catch {
                guard self?.runID == id else { return }
                self?.status = "Failed"
                self?.runError = error.localizedDescription
                self?.onFailure(error.localizedDescription)
            }
            guard self?.runID == id else { return }
            self?.isRunning = false
            self?.runID = nil
            self?.activeRun = nil
        }
    }

    func updateGrantedPermissions(_ granted: Set<NativExtensionPermission>) {
        if granted != grantedPermissions { cancel() }
        grantedPermissions = granted
    }
}
