import Foundation

@MainActor
final class NativMCPPreferences: ObservableObject {
    static let shared = NativMCPPreferences()

    private enum Key {
        static let enabled = "mcpEndpoint.enabled"
        static let port = "mcpEndpoint.port"
        static let publicHost = "mcpEndpoint.publicHost"
        static let keys = "mcpEndpoint.keys"
    }

    private let defaults: UserDefaults

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
    }

    @Published var port: Int {
        didSet { defaults.set(port, forKey: Key.port) }
    }

    @Published var publicHost: String {
        didSet { defaults.set(publicHost, forKey: Key.publicHost) }
    }

    @Published private(set) var keys: [NativMCPKey] {
        didSet { save(keys) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.enabled)
        port = defaults.object(forKey: Key.port) as? Int ?? 8765
        publicHost = defaults.string(forKey: Key.publicHost) ?? ""
        if let data = defaults.data(forKey: Key.keys),
           let stored = try? JSONDecoder().decode([NativMCPKey].self, from: data),
           !stored.isEmpty {
            keys = stored
        } else {
            keys = [NativMCPKey(name: "This Mac", scope: .full)]
        }
    }

    var access: NativMCPAccess {
        NativMCPAccess(keys: keys, readOnlyTools: NativMCPAccess.defaultReadOnlyTools)
    }

    var configurationFingerprint: String {
        ([isEnabled ? "on" : "off", String(port), publicHost]
            + keys.map { "\($0.id)\($0.scope.rawValue)\($0.secret.prefix(6))" })
            .joined(separator: "|")
    }

    func addKey(name: String, scope: NativMCPScope) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        keys.append(NativMCPKey(name: trimmed.isEmpty ? "Agent" : trimmed, scope: scope))
    }

    func removeKey(_ id: UUID) {
        keys.removeAll { $0.id == id }
    }

    func replaceSecret(for id: UUID) {
        guard let index = keys.firstIndex(where: { $0.id == id }) else {
            return
        }
        keys[index].secret = NativMCPKey.newSecret()
    }

    private func save(_ keys: [NativMCPKey]) {
        guard let data = try? JSONEncoder().encode(keys) else {
            return
        }
        defaults.set(data, forKey: Key.keys)
    }
}
