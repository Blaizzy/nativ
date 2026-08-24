import AppKit
import SwiftUI

enum NativWindowIntent: Equatable {
    case activate
    case newChat
    case openChat(UUID)
    case openTab(ControlPanelTab)
    case openExtensionPage(String)
    case openSpeechModels
    case toggleSidebar
    case collapseSidebarSections
}

@MainActor
final class NativWindowState: ObservableObject, Identifiable {
    let id: UUID
    let navigation = ControlPanelNavigation()
    let dependencies: ControlPanelDependencies

    init(sharedDependencies: ControlPanelSharedDependencies) {
        let id = UUID()
        self.id = id
        dependencies = ControlPanelDependencies(
            shared: sharedDependencies,
            windowID: id
        )
    }

    func perform(_ intent: NativWindowIntent) {
        switch intent {
        case .activate:
            break
        case .newChat:
            navigation.createChat()
        case .openChat(let sessionID):
            navigation.openChatSession(sessionID)
        case .openTab(let tab):
            navigation.open(tab)
        case .openExtensionPage(let pageID):
            navigation.openExtensionPage(pageID)
        case .openSpeechModels:
            navigation.openSpeechModelDiscovery()
        case .toggleSidebar:
            navigation.toggleSidebar()
        case .collapseSidebarSections:
            navigation.collapseAllSections()
        }
    }
}

extension FocusedValues {
    @Entry var nativWindowState: NativWindowState?
}

@MainActor
final class NativWindowRegistry {
    private final class Entry {
        weak var state: NativWindowState?
        weak var window: NSWindow?

        init(state: NativWindowState, window: NSWindow) {
            self.state = state
            self.window = window
        }
    }

    private var entries: [NativWindowState.ID: Entry] = [:]
    private var pendingIntent: NativWindowIntent?
    private var openWindow: (() -> Void)?

    func registerWindowOpener(_ opener: @escaping () -> Void) {
        openWindow = opener
    }

    func register(state: NativWindowState, window: NSWindow) {
        entries[state.id] = Entry(state: state, window: window)
        removeReleasedEntries()

        guard let pendingIntent else { return }
        self.pendingIntent = nil
        activate(state: state, window: window, intent: pendingIntent)
    }

    func unregister(stateID: NativWindowState.ID, window: NSWindow) {
        guard entries[stateID]?.window === window else { return }
        entries[stateID] = nil
    }

    func perform(_ intent: NativWindowIntent) {
        removeReleasedEntries()
        if let entry = targetEntry() {
            guard let state = entry.state, let window = entry.window else { return }
            activate(state: state, window: window, intent: intent)
            return
        }

        pendingIntent = intent
        openWindow?()
        NSApplication.shared.activate()
    }

    private func targetEntry() -> Entry? {
        if let keyWindow = NSApplication.shared.keyWindow,
           let match = entries.values.first(where: { $0.window === keyWindow }) {
            return match
        }
        return entries.values.first { entry in
            entry.window?.isVisible == true
        }
    }

    private func activate(
        state: NativWindowState,
        window: NSWindow,
        intent: NativWindowIntent
    ) {
        state.perform(intent)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    private func removeReleasedEntries() {
        entries = entries.filter { _, entry in
            entry.state != nil && entry.window != nil
        }
    }
}

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
            guard window !== newWindow else { return }
            if let window {
                registry.unregister(stateID: state.id, window: window)
            }
            window = newWindow
            if let newWindow {
                registry.register(state: state, window: newWindow)
            }
        }

        func stopObserving() {
            guard let window else { return }
            registry.unregister(stateID: state.id, window: window)
            self.window = nil
        }
    }
}

@MainActor
final class NativWindowReaderView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportWindowChange()
    }

    func reportWindowChange() {
        onWindowChange?(window)
    }
}

struct NativApplicationCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.nativWindowState) private var focusedWindow

    let appDelegate: AppDelegate

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommand(updater: appDelegate.softwareUpdater.updater)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                perform(.newChat)
            }
            .keyboardShortcut("n")

            Button("New Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") {
                perform(.toggleSidebar)
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
        }

        CommandGroup(after: .sidebar) {
            Button("Collapse All Sections") {
                perform(.collapseSidebarSections)
            }
            .keyboardShortcut(".", modifiers: [.command, .option])

            Button("Increase Chat Font Size") {
                appDelegate.increaseChatFontSize()
            }
            .keyboardShortcut("+", modifiers: .command)
            Button("Decrease Chat Font Size") {
                appDelegate.decreaseChatFontSize()
            }
            .keyboardShortcut("-", modifiers: .command)
            Button("Reset Chat Font Size") {
                appDelegate.resetChatFontSize()
            }
            .keyboardShortcut("0", modifiers: .command)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                perform(.openTab(.settings))
            }
            .keyboardShortcut(",")
        }
    }

    private func perform(_ intent: NativWindowIntent) {
        if let focusedWindow {
            focusedWindow.perform(intent)
        } else {
            appDelegate.performWindowIntent(intent)
        }
    }
}
