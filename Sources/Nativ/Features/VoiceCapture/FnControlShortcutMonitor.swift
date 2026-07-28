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

private let voiceHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    let monitor = Unmanaged<FnControlShortcutMonitor>
        .fromOpaque(userData)
        .takeUnretainedValue()
    var hotKeyID = EventHotKeyID()
    let parameterStatus = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard parameterStatus == noErr else {
        return parameterStatus
    }
    let eventKind = GetEventKind(event)
    Task { @MainActor in
        monitor.consumeHotKeyEvent(id: hotKeyID.id, kind: eventKind)
    }
    return noErr
}

@MainActor
final class FnControlShortcutMonitor {
    var onChange: ((Bool) -> Void)?
    var onRetry: (() -> Void)?

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var modifierPollTimer: Timer?
    private var preferenceObserver: NSObjectProtocol?
    private var recordIsHeld = false
    private var retryModifierIsHeld = false
    private var retryState = FnRetryShortcutState()
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var hotKeyEventHandler: EventHandlerRef?
    private let preferences: VoiceShortcutPreferences
    private let hotKeySignature = OSType(0x4E_41_54_56)
    private let recordHotKeyID: UInt32 = 1
    private let retryHotKeyID: UInt32 = 2

    init(preferences: VoiceShortcutPreferences? = nil) {
        self.preferences = preferences ?? .shared
    }

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
        startModifierPolling()
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .voiceShortcutPreferencesDidChange,
            object: preferences,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadShortcuts()
            }
        }
        installHotKeys()
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
        modifierPollTimer?.invalidate()
        modifierPollTimer = nil
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
        }
        preferenceObserver = nil
        if recordIsHeld {
            onChange?(false)
        }
        recordIsHeld = false
        retryModifierIsHeld = false
        uninstallHotKeys()
        retryState = FnRetryShortcutState()
    }

    func resynchronizeAfterModalInteraction() {
        let recordWasHeld = recordIsHeld
        recordIsHeld = false
        retryModifierIsHeld = false
        retryState = FnRetryShortcutState()

        if recordWasHeld {
            onChange?(false)
        }
        consumeCurrentModifierFlags()
    }

    private func startModifierPolling() {
        modifierPollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.consumeCurrentModifierFlags()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierPollTimer = timer
        consumeCurrentModifierFlags()
    }

    private func consumeCurrentModifierFlags() {
        consume(
            VoiceShortcutModifiers(
                cgEventFlags: CGEventSource.flagsState(.combinedSessionState)
            )
        )
    }

    private func consume(_ modifierFlags: NSEvent.ModifierFlags) {
        consume(
            VoiceShortcutModifiers(
                eventFlags: modifierFlags.intersection(.deviceIndependentFlagsMask)
            )
        )
    }

    private func consume(_ activeModifiers: VoiceShortcutModifiers) {
        if preferences.recordShortcut.keyCode == nil {
            let isHeld =
                activeModifiers == preferences.recordShortcut.modifiers
                && !activeModifiers.isEmpty
            updateRecordState(isHeld)
        }

        if preferences.retryShortcut.keyCode == nil {
            let isHeld =
                activeModifiers == preferences.retryShortcut.modifiers
                && !activeModifiers.isEmpty
            if isHeld && !retryModifierIsHeld {
                onRetry?()
            }
            retryModifierIsHeld = isHeld
        }
    }

    fileprivate func consumeHotKeyEvent(id: UInt32, kind: UInt32) {
        let isPressed: Bool
        switch kind {
        case UInt32(kEventHotKeyPressed):
            isPressed = true
        case UInt32(kEventHotKeyReleased):
            isPressed = false
        default:
            return
        }

        switch id {
        case recordHotKeyID:
            updateRecordState(isPressed)
        case retryHotKeyID:
            if retryState.update(isPressed: isPressed) {
                onRetry?()
            }
        default:
            break
        }
    }

    private func updateRecordState(_ isHeld: Bool) {
        guard isHeld != recordIsHeld else {
            return
        }
        recordIsHeld = isHeld
        onChange?(isHeld)
    }

    private func reloadShortcuts() {
        if recordIsHeld {
            updateRecordState(false)
        }
        retryModifierIsHeld = false
        retryState = FnRetryShortcutState()
        uninstallHotKeys()
        installHotKeys()
        consumeCurrentModifierFlags()
    }

    private func installHotKeys() {
        guard hotKeys.isEmpty, hotKeyEventHandler == nil else {
            return
        }

        let keyedShortcuts = [
            (recordHotKeyID, preferences.recordShortcut),
            (retryHotKeyID, preferences.retryShortcut),
        ].filter { $0.1.keyCode != nil }
        guard !keyedShortcuts.isEmpty else {
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
                voiceHotKeyHandler,
                events.count,
                events.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandler
            )
        }
        guard handlerStatus == noErr, let eventHandler else {
            NSLog("Nativ could not install the voice shortcut handler: %d", handlerStatus)
            return
        }
        hotKeyEventHandler = eventHandler

        for (id, shortcut) in keyedShortcuts {
            guard let keyCode = shortcut.keyCode else {
                continue
            }
            var hotKey: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                shortcut.modifiers.carbonFlags,
                EventHotKeyID(signature: hotKeySignature, id: id),
                GetApplicationEventTarget(),
                0,
                &hotKey
            )
            if status == noErr, let hotKey {
                hotKeys[id] = hotKey
            } else {
                NSLog(
                    "Nativ could not register voice shortcut %@: %d",
                    shortcut.displayName,
                    status
                )
            }
        }

        if hotKeys.isEmpty {
            RemoveEventHandler(eventHandler)
            hotKeyEventHandler = nil
        }
    }

    private func uninstallHotKeys() {
        for hotKey in hotKeys.values {
            UnregisterEventHotKey(hotKey)
        }
        hotKeys.removeAll()
        if let hotKeyEventHandler {
            RemoveEventHandler(hotKeyEventHandler)
        }
        hotKeyEventHandler = nil
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
