import SwiftUI

@MainActor
final class NativWindowState: Identifiable {
    let id: UUID
    let navigation = ControlPanelNavigation()
    let dependencies: ControlPanelDependencies

    init(
        sharedDependencies: ControlPanelSharedDependencies,
        id: UUID = UUID()
    ) {
        self.id = id
        dependencies = ControlPanelDependencies(
            shared: sharedDependencies,
            windowID: id
        )
    }

    func perform(_ intent: NativWindowIntent) {
        navigation.perform(intent)
    }
}

extension FocusedValues {
    @Entry var nativWindowState: NativWindowState?
}
