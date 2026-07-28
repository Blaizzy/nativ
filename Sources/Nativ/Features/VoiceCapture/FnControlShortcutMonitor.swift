import AppKit
import ApplicationServices

struct FnControlShortcutState {
    private(set) var isHeld = false

    mutating func update(functionIsDown: Bool, controlIsDown: Bool) -> Bool? {
        let nextValue = functionIsDown && controlIsDown
        guard nextValue != isHeld else {
            return nil
        }
        isHeld = nextValue
        return nextValue
    }
}

@MainActor
final class FnControlShortcutMonitor {
    var onChange: ((Bool) -> Void)?

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var state = FnControlShortcutState()

    func start() {
        guard localMonitor == nil, globalMonitor == nil else {
            return
        }

        requestAccessibilityAccessIfNeeded()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.consume(event.modifierFlags)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            Task { @MainActor in
                self?.consume(event.modifierFlags)
            }
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        localMonitor = nil
        globalMonitor = nil
        state = FnControlShortcutState()
    }

    private func consume(_ modifierFlags: NSEvent.ModifierFlags) {
        let deviceIndependentFlags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let isHeld = state.update(
            functionIsDown: deviceIndependentFlags.contains(.function),
            controlIsDown: deviceIndependentFlags.contains(.control)
        ) else {
            return
        }
        onChange?(isHeld)
    }

    private func requestAccessibilityAccessIfNeeded() {
        guard !AXIsProcessTrusted() else {
            return
        }
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
