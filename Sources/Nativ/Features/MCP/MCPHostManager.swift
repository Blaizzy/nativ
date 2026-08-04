import Combine
import Foundation
import NativServerKit

enum MCPServerConnectionState: Equatable {
    case disabled
    case connecting
    case connected(toolCount: Int)
    case failed(String)
}

@MainActor
final class MCPHostManager: ObservableObject {
    @Published private(set) var states: [UUID: MCPServerConnectionState] = [:]

    private struct Connection {
        let config: MCPServerConfig
        let client: MCPClient
        let slug: String
        let tools: [MCPToolInfo]
    }

    private var connections: [UUID: Connection] = [:]
    private var appliedServers: [MCPServerConfig] = []
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0

    func toolDefinitions() -> [MLXChatToolDefinition] {
        connections.values.flatMap { connection in
            connection.tools.map { tool in
                MLXChatToolDefinition(
                    function: MLXChatFunctionDefinition(
                        name: Self.toolName(slug: connection.slug, tool: tool.name),
                        description: tool.description,
                        parameters: tool.parameters
                    )
                )
            }
        }
    }

    func tools(forServer id: UUID) -> [(name: String, displayName: String)] {
        guard let connection = connections[id] else { return [] }
        return connection.tools.map {
            (name: Self.toolName(slug: connection.slug, tool: $0.name), displayName: $0.name)
        }
    }

    func handlesTool(named name: String) -> Bool {
        route(for: name) != nil
    }

    func callTool(named name: String, argumentsJSON: String?) async throws -> String {
        guard let route = route(for: name) else {
            throw MCPClientError.notConnected
        }
        return try await route.client.callTool(name: route.toolName, argumentsJSON: argumentsJSON)
    }

    func reload(servers: [MCPServerConfig]) {
        guard servers != appliedServers else { return }
        appliedServers = servers
        scheduleReload(servers: servers, debounce: true)
    }

    func reconnect(_ serverID: UUID) {
        if let connection = connections.removeValue(forKey: serverID) {
            states[serverID] = .connecting
            let client = connection.client
            Task { await client.disconnect() }
        }
        scheduleReload(servers: appliedServers, debounce: false)
    }

    func shutdown() {
        reloadTask?.cancel()
        let previous = connections
        connections = [:]
        states = [:]
        Task {
            for connection in previous.values {
                await connection.client.disconnect()
            }
        }
    }

    private func scheduleReload(servers: [MCPServerConfig], debounce: Bool) {
        reloadGeneration += 1
        let generation = reloadGeneration
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
            }
            await self?.applyReload(servers: servers, generation: generation)
        }
    }

    private func applyReload(servers: [MCPServerConfig], generation: Int) async {
        let enabled = servers.filter(\.isEnabled)
        let enabledByID = Dictionary(enabled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (id, connection) in connections {
            let reusable = enabledByID[id].map { Self.launchEquivalent($0, connection.config) } ?? false
            if !reusable {
                connections[id] = nil
                await connection.client.disconnect()
            }
        }
        guard generation == reloadGeneration else { return }

        for server in servers where !server.isEnabled {
            states[server.id] = .disabled
        }
        pruneStates(keeping: servers)

        let toConnect = enabled.filter { connections[$0.id] == nil }
        guard !toConnect.isEmpty else { return }

        for config in toConnect {
            states[config.id] = .connecting
        }
        let searchPath = await Task.detached(priority: .utility) {
            ShellEnvironment.resolveFromLoginShell(names: ["PATH"])["PATH"]
        }.value
        guard generation == reloadGeneration else { return }

        var pending: [(config: MCPServerConfig, client: MCPClient)] = []
        for config in toConnect where connections[config.id] == nil {
            guard let executable = Self.resolveExecutable(config.command, searchPath: searchPath) else {
                states[config.id] = .failed("Couldn’t find “\(config.command)”")
                continue
            }
            let client = MCPClient(
                executableURL: executable,
                arguments: config.arguments,
                environment: Self.childEnvironment(searchPath: searchPath, overrides: config.environment)
            )
            pending.append((config, client))
        }
        guard !pending.isEmpty else { return }

        // Connect every server concurrently so a slow or hung one can't hold up
        // the rest; each has its own handshake deadline.
        await withTaskGroup(of: ConnectOutcome.self) { group in
            for item in pending {
                group.addTask {
                    do {
                        let tools = try await item.client.connectAndListTools()
                        return ConnectOutcome(config: item.config, tools: tools, error: nil, client: item.client)
                    } catch {
                        return ConnectOutcome(config: item.config, tools: nil, error: error.localizedDescription, client: item.client)
                    }
                }
            }

            var usedSlugs = Set(connections.values.map(\.slug))
            for await outcome in group {
                guard generation == reloadGeneration else {
                    await outcome.client.disconnect()
                    continue
                }
                if let tools = outcome.tools {
                    let slug = Self.uniqueSlug(for: outcome.config, used: &usedSlugs)
                    connections[outcome.config.id] = Connection(
                        config: outcome.config,
                        client: outcome.client,
                        slug: slug,
                        tools: tools
                    )
                    states[outcome.config.id] = .connected(toolCount: tools.count)
                } else {
                    await outcome.client.disconnect()
                    states[outcome.config.id] = .failed(outcome.error ?? "Failed to connect")
                }
            }
        }
    }

    private struct ConnectOutcome: Sendable {
        let config: MCPServerConfig
        let tools: [MCPToolInfo]?
        let error: String?
        let client: MCPClient
    }

    private func route(for name: String) -> (client: MCPClient, toolName: String)? {
        for connection in connections.values {
            let prefix = "mcp__\(connection.slug)__"
            guard name.hasPrefix(prefix) else { continue }
            let toolName = String(name.dropFirst(prefix.count))
            if connection.tools.contains(where: { $0.name == toolName }) {
                return (connection.client, toolName)
            }
        }
        return nil
    }

    private func pruneStates(keeping servers: [MCPServerConfig]) {
        let ids = Set(servers.map(\.id))
        states = states.filter { ids.contains($0.key) }
    }

    private static func toolName(slug: String, tool: String) -> String {
        "mcp__\(slug)__\(tool)"
    }

    private static func launchEquivalent(_ lhs: MCPServerConfig, _ rhs: MCPServerConfig) -> Bool {
        lhs.command == rhs.command
            && lhs.arguments == rhs.arguments
            && lhs.environment == rhs.environment
    }

    private static func resolveExecutable(_ command: String, searchPath: String?) -> URL? {
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded)
                ? URL(fileURLWithPath: expanded)
                : nil
        }
        for directory in (searchPath ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func childEnvironment(
        searchPath: String?,
        overrides: [String: String]
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let searchPath, !searchPath.isEmpty {
            environment["PATH"] = searchPath
        }
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }

    private static func slug(_ raw: String) -> String {
        let characters = raw.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        let joined = String(characters)
        return joined.isEmpty ? "server" : joined
    }

    private static func uniqueSlug(for config: MCPServerConfig, used: inout Set<String>) -> String {
        let base = slug(config.name.isEmpty ? config.command : config.name)
        var candidate = base
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base)_\(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }
}
