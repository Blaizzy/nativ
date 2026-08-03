import Foundation
import NativExtensionSDK

enum NativExtensionInstallState: String, Codable, Hashable, Sendable {
    case enabled
    case disabled
    case removed
}

final class NativExtensionStateStore {
    private struct Payload: Codable {
        var states: [String: NativExtensionInstallState]
    }

    private let defaults: UserDefaults
    private let key: String
    private var states: [String: NativExtensionInstallState]

    init(
        defaults: UserDefaults = .standard,
        key: String = "nativ.extension-platform.install-state.v1"
    ) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            states = payload.states
        } else {
            states = [:]
        }
    }

    func state(for manifest: NativExtensionManifest) -> NativExtensionInstallState {
        states[manifest.id] ?? (manifest.included ? .enabled : .disabled)
    }

    func set(_ state: NativExtensionInstallState, for extensionID: String) {
        states[extensionID] = state
        persist()
    }

    func clear(extensionID: String) {
        states.removeValue(forKey: extensionID)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Payload(states: states)) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
