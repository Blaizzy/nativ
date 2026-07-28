import AppKit
import ApplicationServices
import Carbon.HIToolbox

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

struct FnRetryShortcutState {
    private(set) var isPressed = false

    mutating func update(isPressed nextValue: Bool) -> Bool {
        defer {
            isPressed = nextValue
        }
        return nextValue && !isPressed
    }
}

private let fnRetryHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    let monitor = Unmanaged<FnControlShortcutMonitor>
        .fromOpaque(userData)
        .takeUnretainedValue()
    let eventKind = GetEventKind(event)
    Task { @MainActor in
        monitor.consumeRetryHotKeyEvent(kind: eventKind)
    }
    return noErr
}

@MainActor
final class FnControlShortcutMonitor {
    var onChange: ((Bool) -> Void)?
    var onRetry: (() -> Void)?

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var state = FnControlShortcutState()
    private var retryState = FnRetryShortcutState()
    private var retryHotKey: EventHotKeyRef?
    private var retryEventHandler: EventHandlerRef?
    private let retryHotKeyID = EventHotKeyID(
        signature: OSType(0x4E_41_54_52),
        id: 1
    )

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
        installRetryHotKey()
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
        uninstallRetryHotKey()
        retryState = FnRetryShortcutState()
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

    fileprivate func consumeRetryHotKeyEvent(kind: UInt32) {
        let isPressed: Bool
        switch kind {
        case UInt32(kEventHotKeyPressed):
            isPressed = true
        case UInt32(kEventHotKeyReleased):
            isPressed = false
        default:
            return
        }

        if retryState.update(isPressed: isPressed) {
            onRetry?()
        }
    }

    private func installRetryHotKey() {
        guard retryHotKey == nil, retryEventHandler == nil else {
            return
        }

        let eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]
        var eventHandler: EventHandlerRef?
        let handlerStatus = eventTypes.withUnsafeBufferPointer { events in
            InstallEventHandler(
                GetApplicationEventTarget(),
                fnRetryHotKeyHandler,
                events.count,
                events.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandler
            )
        }
        guard handlerStatus == noErr, let eventHandler else {
            NSLog("Nativ could not install the Fn + R event handler: %d", handlerStatus)
            return
        }
        retryEventHandler = eventHandler

        var hotKey: EventHotKeyRef?
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(kEventKeyModifierFnMask),
            retryHotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard hotKeyStatus == noErr, let hotKey else {
            NSLog("Nativ could not register Fn + R: %d", hotKeyStatus)
            RemoveEventHandler(eventHandler)
            retryEventHandler = nil
            return
        }
        retryHotKey = hotKey
    }

    private func uninstallRetryHotKey() {
        if let retryHotKey {
            UnregisterEventHotKey(retryHotKey)
        }
        if let retryEventHandler {
            RemoveEventHandler(retryEventHandler)
        }
        retryHotKey = nil
        retryEventHandler = nil
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
