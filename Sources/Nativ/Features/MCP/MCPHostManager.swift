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

    private var clients: [UUID: MCPClient] = [:]
    private var routes: [String: (client: MCPClient, toolName: String)] = [:]
    private var definitions: [MLXChatToolDefinition] = []
    private var appliedServers: [MCPServerConfig] = []
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0

    func toolDefinitions() -> [MLXChatToolDefinition] {
        definitions
    }

    func handlesTool(named name: String) -> Bool {
        routes[name] != nil
    }

    func callTool(named name: String, argumentsJSON: String?) async throws -> String {
        guard let route = routes[name] else {
            throw MCPClientError.notConnected
        }
        return try await route.client.callTool(name: route.toolName, argumentsJSON: argumentsJSON)
    }

    func reload(servers: [MCPServerConfig]) {
        guard servers != appliedServers else { return }
        appliedServers = servers
        reloadGeneration += 1
        let generation = reloadGeneration
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            await self?.applyReload(servers: servers, generation: generation)
        }
    }

    func shutdown() {
        reloadTask?.cancel()
        let previous = clients
        clients = [:]
        routes = [:]
        definitions = []
        states = [:]
        Task {
            for client in previous.values {
                await client.disconnect()
            }
        }
    }

    private func applyReload(servers: [MCPServerConfig], generation: Int) async {
        let previous = clients
        clients = [:]
        routes = [:]
        definitions = []
        for server in servers {
            states[server.id] = server.isEnabled ? .connecting : .disabled
        }
        pruneStates(keeping: servers)

        for client in previous.values {
            await client.disconnect()
        }
        guard generation == reloadGeneration else { return }

        let enabled = servers.filter(\.isEnabled)
        guard !enabled.isEmpty else { return }

        var usedSlugs: Set<String> = []
        let searchPath = await Task.detached(priority: .utility) {
            ShellEnvironment.resolveFromLoginShell(names: ["PATH"])["PATH"]
        }.value
        guard generation == reloadGeneration else { return }

        for config in enabled {
            guard let executable = Self.resolveExecutable(config.command, searchPath: searchPath) else {
                states[config.id] = .failed("Couldn’t find “\(config.command)”")
                continue
            }
            let client = MCPClient(
                executableURL: executable,
                arguments: config.arguments,
                environment: Self.childEnvironment(searchPath: searchPath, overrides: config.environment)
            )
            do {
                try await client.connect()
                let tools = try await client.listTools()
                guard generation == reloadGeneration else {
                    await client.disconnect()
                    return
                }
                let slug = Self.uniqueSlug(for: config, used: &usedSlugs)
                register(tools: tools, client: client, slug: slug)
                clients[config.id] = client
                states[config.id] = .connected(toolCount: tools.count)
            } catch {
                await client.disconnect()
                guard generation == reloadGeneration else { return }
                states[config.id] = .failed(error.localizedDescription)
            }
        }
    }

    private func register(tools: [MCPToolInfo], client: MCPClient, slug: String) {
        for tool in tools {
            let name = "mcp__\(slug)__\(tool.name)"
            guard routes[name] == nil else { continue }
            routes[name] = (client: client, toolName: tool.name)
            definitions.append(
                MLXChatToolDefinition(
                    function: MLXChatFunctionDefinition(
                        name: name,
                        description: tool.description,
                        parameters: tool.parameters
                    )
                )
            )
        }
    }

    private func pruneStates(keeping servers: [MCPServerConfig]) {
        let ids = Set(servers.map(\.id))
        states = states.filter { ids.contains($0.key) }
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
