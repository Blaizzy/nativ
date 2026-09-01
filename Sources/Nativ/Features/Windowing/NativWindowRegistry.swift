import AppKit

@MainActor
final class NativWindowRegistry {
    private final class Entry {
        weak var state: NativWindowState?
        weak var window: (any NativWindowHandle)?

        init(state: NativWindowState, window: any NativWindowHandle) {
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

    func register(state: NativWindowState, window: any NativWindowHandle) {
        entries[state.id] = Entry(state: state, window: window)
        removeReleasedEntries()

        guard let pendingIntent else {
            return
        }
        self.pendingIntent = nil
        activate(state: state, window: window, intent: pendingIntent)
    }

    func unregister(stateID: NativWindowState.ID, window: any NativWindowHandle) {
        guard let registeredWindow = entries[stateID]?.window,
              ObjectIdentifier(registeredWindow) == ObjectIdentifier(window)
        else {
            return
        }
        entries[stateID] = nil
    }

    func perform(_ intent: NativWindowIntent) {
        removeReleasedEntries()
        if let entry = targetEntry(),
           let state = entry.state,
           let window = entry.window
        {
            activate(state: state, window: window, intent: intent)
            return
        }

        pendingIntent = intent
        openWindow?()
        NSApplication.shared.activate()
    }

    private func targetEntry() -> Entry? {
        if let keyWindow = NSApplication.shared.keyWindow,
           let entry = entry(for: keyWindow)
        {
            return entry
        }
        if let mainWindow = NSApplication.shared.mainWindow,
           let entry = entry(for: mainWindow)
        {
            return entry
        }
        for window in NSApplication.shared.orderedWindows {
            if let entry = entry(for: window) {
                return entry
            }
        }
        return entries.values.first
    }

    private func entry(for window: NSWindow) -> Entry? {
        entries.values.first { $0.window?.appKitWindow === window }
    }

    private func activate(
        state: NativWindowState,
        window: any NativWindowHandle,
        intent: NativWindowIntent
    ) {
        state.perform(intent)
        window.activate()
    }

    private func removeReleasedEntries() {
        entries = entries.filter { _, entry in
            entry.state != nil && entry.window != nil
        }
    }
}
