import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

struct VoiceShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt

    static let command = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)
    static let function = Self(rawValue: 1 << 4)

    static let supported: Self = [.command, .option, .control, .shift, .function]

    init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    init(eventFlags: NSEvent.ModifierFlags) {
        var value: Self = []
        if eventFlags.contains(.command) { value.insert(.command) }
        if eventFlags.contains(.option) { value.insert(.option) }
        if eventFlags.contains(.control) { value.insert(.control) }
        if eventFlags.contains(.shift) { value.insert(.shift) }
        if eventFlags.contains(.function) { value.insert(.function) }
        self = value
    }

    init(cgEventFlags: CGEventFlags) {
        var value: Self = []
        if cgEventFlags.contains(.maskCommand) { value.insert(.command) }
        if cgEventFlags.contains(.maskAlternate) { value.insert(.option) }
        if cgEventFlags.contains(.maskControl) { value.insert(.control) }
        if cgEventFlags.contains(.maskShift) { value.insert(.shift) }
        if cgEventFlags.contains(.maskSecondaryFn) { value.insert(.function) }
        self = value
    }

    var carbonFlags: UInt32 {
        var value: UInt32 = 0
        if contains(.command) { value |= UInt32(cmdKey) }
        if contains(.option) { value |= UInt32(optionKey) }
        if contains(.control) { value |= UInt32(controlKey) }
        if contains(.shift) { value |= UInt32(shiftKey) }
        if contains(.function) { value |= UInt32(kEventKeyModifierFnMask) }
        return value
    }

    var displayParts: [String] {
        var parts: [String] = []
        if contains(.function) { parts.append("Fn") }
        if contains(.control) { parts.append("Control") }
        if contains(.option) { parts.append("Option") }
        if contains(.shift) { parts.append("Shift") }
        if contains(.command) { parts.append("Command") }
        return parts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct VoiceShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt16?
    let keyDisplay: String?
    let modifiers: VoiceShortcutModifiers

    static let recordDefault = VoiceShortcut(
        keyCode: nil,
        keyDisplay: nil,
        modifiers: [.function, .control]
    )
    static let retryDefault = VoiceShortcut(
        keyCode: UInt16(kVK_ANSI_R),
        keyDisplay: "R",
        modifiers: [.function]
    )
    static let handsFreeDefault = VoiceShortcut(
        keyCode: nil,
        keyDisplay: nil,
        modifiers: [.option]
    )

    var displayName: String {
        let parts = modifiers.displayParts + (keyDisplay.map { [$0] } ?? [])
        return parts.isEmpty ? "Not set" : parts.joined(separator: " + ")
    }

    var isValid: Bool {
        !modifiers.isEmpty
    }

    static func keyDisplay(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Space: return "Space"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_Escape: return "Escape"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            let value = event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            return value?.isEmpty == false ? value! : "Key \(event.keyCode)"
        }
    }
}

extension Notification.Name {
    static let voiceShortcutPreferencesDidChange = Notification.Name(
        "VoiceShortcutPreferencesDidChange"
    )
}

@MainActor
final class VoiceShortcutPreferences: ObservableObject {
    static let shared = VoiceShortcutPreferences()

    @Published var recordShortcut: VoiceShortcut {
        didSet { preferencesDidChange() }
    }
    @Published var retryShortcut: VoiceShortcut {
        didSet { preferencesDidChange() }
    }
    @Published var handsFreeShortcut: VoiceShortcut {
        didSet { preferencesDidChange() }
    }

    private struct Payload: Codable {
        let recordShortcut: VoiceShortcut
        let retryShortcut: VoiceShortcut
        let handsFreeShortcut: VoiceShortcut?
    }

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "voiceShortcutPreferences.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let payload = try? JSONDecoder().decode(Payload.self, from: data),
           payload.recordShortcut.isValid,
           payload.retryShortcut.isValid
        {
            recordShortcut = payload.recordShortcut
            retryShortcut = payload.retryShortcut
            handsFreeShortcut = payload.handsFreeShortcut.flatMap {
                $0.isValid ? $0 : nil
            } ?? .handsFreeDefault
        } else {
            recordShortcut = .recordDefault
            retryShortcut = .retryDefault
            handsFreeShortcut = .handsFreeDefault
        }
    }

    func resetRecordShortcut() {
        recordShortcut = .recordDefault
    }

    func resetRetryShortcut() {
        retryShortcut = .retryDefault
    }

    func resetHandsFreeShortcut() {
        handsFreeShortcut = .handsFreeDefault
    }

    private func preferencesDidChange() {
        let payload = Payload(
            recordShortcut: recordShortcut,
            retryShortcut: retryShortcut,
            handsFreeShortcut: handsFreeShortcut
        )
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: storageKey)
        }
        NotificationCenter.default.post(
            name: .voiceShortcutPreferencesDidChange,
            object: self
        )
    }
}
