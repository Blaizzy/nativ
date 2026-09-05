import Foundation
import NativExtensionSDK
import SwiftUI

/// One installed declarative package, presented to the platform as an ordinary
/// host extension.
///
/// There is deliberately one of these per package rather than a single object
/// owning them all: `deactivate()` carries no identifier, so an aggregate host
/// could never tell which package to stop when one is disabled or removed.
@MainActor
final class NativDeclarativeExtension: NativHostExtension {
    let manifest: NativExtensionManifest
    let workflow: NativExtensionWorkflow

    private let services: @MainActor () -> NativWorkflowServices
    private let onFailure: @MainActor (String) -> Void
    private var grantedPermissions: Set<NativExtensionPermission>
    private var isActive = false
    private var activeRun: Task<Void, Never>?

    init(
        manifest: NativExtensionManifest,
        workflow: NativExtensionWorkflow,
        grantedPermissions: Set<NativExtensionPermission>,
        services: @escaping @MainActor () -> NativWorkflowServices,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        self.manifest = manifest
        self.workflow = workflow
        self.grantedPermissions = grantedPermissions
        self.services = services
        self.onFailure = onFailure
    }

    func activate(context: NativExtensionHostContext) {
        isActive = true
    }

    func deactivate() {
        isActive = false
        activeRun?.cancel()
        activeRun = nil
    }

    /// Dashboard.json is not implemented yet, so a declarative package
    /// contributes commands but no page.
    func makePage(id: String, context: NativExtensionPageContext) -> AnyView? {
        nil
    }

    func performCommand(id commandID: String) {
        guard isActive else { return }
        // Dropped rather than queued: a rewrite waiting behind another rewrite
        // would fire into a selection that no longer exists.
        guard activeRun == nil else { return }

        let workflow = workflow
        let context = NativWorkflowRunContext(
            extensionID: manifest.id,
            grantedPermissions: grantedPermissions,
            services: services()
        )
        activeRun = Task { [weak self] in
            do {
                _ = try await NativWorkflowRunner.run(
                    workflow,
                    commandID: commandID,
                    context: context
                )
            } catch is CancellationError {
                // Disabled or removed mid-run; nothing to report.
            } catch {
                self?.onFailure(error.localizedDescription)
            }
            self?.activeRun = nil
        }
    }

    /// A grant can be revoked while an extension is enabled, so the frozen set
    /// the runner checks against has to be refreshed rather than left stale.
    func updateGrantedPermissions(_ granted: Set<NativExtensionPermission>) {
        grantedPermissions = granted
    }
}
