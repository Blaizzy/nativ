import SwiftUI

struct NativWindowRoot: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
    @State private var windowState: NativWindowState

    let appDelegate: AppDelegate

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        _windowState = State(initialValue: appDelegate.makeWindowState())
    }

    var body: some View {
        appDelegate.rootView(for: windowState)
            .focusedSceneValue(\.nativWindowState, windowState)
            .background {
                NativWindowRegistryReader(
                    state: windowState,
                    registry: appDelegate.windowRegistry
                )
                .frame(width: 0, height: 0)
            }
            .onAppear {
                applyAppearance(appearance)
                appDelegate.registerWindowOpener(openMainWindow)
            }
            .onChange(of: appearance) { _, newAppearance in
                applyAppearance(newAppearance)
            }
    }

    private func openMainWindow() {
        openWindow(id: "main")
    }

    private func applyAppearance(_ appearance: AppAppearance) {
        NSApplication.shared.appearance = appearance.appKitAppearance
    }
}
