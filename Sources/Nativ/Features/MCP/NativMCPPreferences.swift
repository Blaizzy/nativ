import Foundation

@MainActor
final class NativMCPPreferences: ObservableObject {
    static let shared = NativMCPPreferences()

    private enum Key {
        static let enabled = "mcpEndpoint.enabled"
        static let localPort = "mcpEndpoint.localPort"
        static let outsideEnabled = "mcpEndpoint.outsideEnabled"
        static let outsidePort = "mcpEndpoint.outsidePort"
        static let publicHost = "mcpEndpoint.publicHost"
        static let localSecret = "mcpEndpoint.localSecret"
        static let outsideSecret = "mcpEndpoint.outsideSecret"
    }

    private let defaults: UserDefaults

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
    }

    @Published var localPort: Int {
        didSet { defaults.set(localPort, forKey: Key.localPort) }
    }

    @Published var outsideIsEnabled: Bool {
        didSet { defaults.set(outsideIsEnabled, forKey: Key.outsideEnabled) }
    }

    @Published var outsidePort: Int {
        didSet { defaults.set(outsidePort, forKey: Key.outsidePort) }
    }

    @Published var publicHost: String {
        didSet { defaults.set(publicHost, forKey: Key.publicHost) }
    }

    @Published private(set) var keyGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.enabled)
        localPort = defaults.object(forKey: Key.localPort) as? Int ?? 8765
        outsideIsEnabled = defaults.bool(forKey: Key.outsideEnabled)
        outsidePort = defaults.object(forKey: Key.outsidePort) as? Int ?? 8766
        publicHost = defaults.string(forKey: Key.publicHost) ?? ""
    }

    var localSecret: String {
        secret(forKey: Key.localSecret)
    }

    var outsideSecret: String {
        secret(forKey: Key.outsideSecret)
    }

    func regenerateSecrets() {
        defaults.removeObject(forKey: Key.localSecret)
        defaults.removeObject(forKey: Key.outsideSecret)
        keyGeneration += 1
    }

    var access: NativMCPAccess {
        NativMCPAccess(
            localPort: localPort,
            outsidePort: outsideIsEnabled ? outsidePort : nil,
            localSecret: localSecret,
            outsideSecret: outsideIsEnabled ? outsideSecret : nil,
            outsideAllowedTools: NativMCPAccess.defaultOutsideAllowedTools
        )
    }

    private func secret(forKey key: String) -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defaults.set(generated, forKey: key)
        return generated
    }
}
