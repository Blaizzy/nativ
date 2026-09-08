import SwiftUI

struct NativWindowRegistryReader: NSViewRepresentable {
    let state: NativWindowState
    let registry: NativWindowRegistry

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, registry: registry)
    }

    func makeNSView(context: Context) -> NativWindowReaderView {
        let view = NativWindowReaderView()
        view.onWindowChange = context.coordinator.windowDidChange
        return view
    }

    func updateNSView(_ view: NativWindowReaderView, context: Context) {
        view.onWindowChange = context.coordinator.windowDidChange
        view.reportWindowChange()
    }

    static func dismantleNSView(_ view: NativWindowReaderView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator {
        private let state: NativWindowState
        private let registry: NativWindowRegistry
        private weak var window: NSWindow?

        init(state: NativWindowState, registry: NativWindowRegistry) {
            self.state = state
            self.registry = registry
        }

        func windowDidChange(_ newWindow: NSWindow?) {
            guard window !== newWindow else {
                return
            }
            if let window {
                registry.unregister(stateID: state.id, window: window)
            }
            window = newWindow
            if let newWindow {
                registry.register(state: state, window: newWindow)
            }
        }

        func stopObserving() {
            guard let window else {
                return
            }
            registry.unregister(stateID: state.id, window: window)
            self.window = nil
        }
    }
}
