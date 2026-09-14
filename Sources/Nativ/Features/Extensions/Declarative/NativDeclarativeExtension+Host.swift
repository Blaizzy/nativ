import SwiftUI

extension NativDeclarativeExtension: NativHostExtension {
    func activate(context: NativExtensionHostContext) {
        activate()
    }

    func makePage(id: String, context: NativExtensionPageContext) -> AnyView? {
        guard isActive, let dashboard,
              manifest.contributions.sidebar.contains(where: { $0.id == id }) else { return nil }
        return AnyView(NativDeclarativeDashboardView(
            runtime: self,
            dashboard: dashboard,
            titleLeadingInset: context.titleLeadingInset
        ).id(ObjectIdentifier(self)))
    }

}
