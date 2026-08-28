import Foundation

@MainActor
final class NativMCPPreferences: ObservableObject {
    static let shared = NativMCPPreferences()

    private enum Key {
        static let enabled = "mcpEndpoint.enabled"
        static let port = "mcpEndpoint.port"
        static let agents = "mcpEndpoint.agents"
    }

    private let defaults: UserDefaults
    private let secrets: CustomToolCredentialStoring

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
    }

    @Published var port: Int {
        didSet { defaults.set(port, forKey: Key.port) }
    }

    @Published private(set) var agents: [NativMCPAgent] {
        didSet { save(agents) }
    }

    init(
        defaults: UserDefaults = .standard,
        secrets: CustomToolCredentialStoring = CustomToolKeychain(
            service: "dev.local.Nativ.agent-access"
        )
    ) {
        self.defaults = defaults
        self.secrets = secrets
        isEnabled = defaults.bool(forKey: Key.enabled)
        port = defaults.object(forKey: Key.port) as? Int ?? 8765
        if let data = defaults.data(forKey: Key.agents),
           let stored = try? JSONDecoder().decode([NativMCPAgent].self, from: data),
           !stored.isEmpty {
            agents = stored
        } else {
            agents = [NativMCPAgent(name: "This Mac", scope: .full)]
            save(agents)
        }
    }

    var access: NativMCPAccess {
        NativMCPAccess(
            keys: agents.compactMap { agent in
                secret(for: agent.id).map { NativMCPKey(agent: agent, secret: $0) }
            },
            readOnlyTools: NativMCPAccess.defaultReadOnlyTools
        )
    }

    func secret(for agentID: UUID) -> String? {
        if let existing = (try? secrets.load(for: agentID)) ?? nil, !existing.isEmpty {
            return existing
        }
        let generated = NativMCPKey.newSecret()
        guard (try? secrets.save(generated, for: agentID)) != nil else {
            return nil
        }
        return generated
    }

    func addAgent(name: String, scope: NativMCPScope) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let agent = NativMCPAgent(name: trimmed.isEmpty ? "Agent" : trimmed, scope: scope)
        _ = secret(for: agent.id)
        agents.append(agent)
    }

    func removeAgent(_ id: UUID) {
        guard agents.count > 1 else {
            return
        }
        try? secrets.save(nil, for: id)
        agents.removeAll { $0.id == id }
    }

    private func save(_ agents: [NativMCPAgent]) {
        guard let data = try? JSONEncoder().encode(agents) else {
            return
        }
        defaults.set(data, forKey: Key.agents)
    }
}
