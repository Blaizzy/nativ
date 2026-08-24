import Combine
import Foundation
import NativServerKit

enum MCPServerConnectionState: Equatable {
    case disabled
    case connecting
    case authorizingGitHub(code: String, verificationURL: URL)
    case installingGitHub(URL)
    case connected(toolCount: Int)
    case failed(MCPConnectionFailure)
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
    private let githubOAuth: (any GitHubOAuthAuthorizing)?

    init(
        githubOAuth: (any GitHubOAuthAuthorizing)? = GitHubOAuthManager.configured()
    ) {
        self.githubOAuth = githubOAuth
    }

    func toolDefinitions() -> [MLXChatToolDefinition] {
        connections.values.flatMap { connection in
            Self.toolDefinitions(for: connection)
        }
    }

    func toolDefinitions(forServer id: UUID) -> [MLXChatToolDefinition] {
        guard let connection = connections[id] else { return [] }
        return Self.toolDefinitions(for: connection)
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

    func prepare(servers: [MCPServerConfig]) async {
        reloadGeneration += 1
        let generation = reloadGeneration
        reloadTask?.cancel()
        appliedServers = servers
        await applyReload(servers: servers, generation: generation)
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
        var githubPending: [(config: MCPServerConfig, executable: URL)] = []
        for config in toConnect where connections[config.id] == nil {
            guard let executable = Self.resolveExecutable(config.command, searchPath: searchPath) else {
                states[config.id] = .failed(
                    MCPConnectionFailure(message: "Couldn’t find “\(config.command)”")
                )
                continue
            }
            let catalogEntry = MCPServerCatalog.bundled.entry(matching: config)
            if catalogEntry?.id == "github" {
                githubPending.append((config, executable))
                continue
            }
            let client = MCPClient(
                executableURL: executable,
                arguments: config.arguments,
                environment: Self.childEnvironment(
                    searchPath: searchPath,
                    overrides: config.environment,
                    excluding: catalogEntry?.excludedEnvironment ?? []
                ),
                workingDirectory: Self.workingDirectory(for: config.id.uuidString)
            )
            pending.append((config, client))
        }

        // Connect every server concurrently so a slow or hung one can't hold up
        // the rest; each has its own handshake deadline.
        if !pending.isEmpty {
            await connect(pending, generation: generation)
        }
        guard generation == reloadGeneration else { return }

        // GitHub needs a user token before its local MCP process starts. Nativ
        // obtains that token once, keeps it in Keychain, and refreshes it
        // silently on later launches. Other MCP servers are already connected
        // while the user completes this first-run authorization.
        for item in githubPending where connections[item.config.id] == nil {
            await connectGitHub(
                config: item.config,
                executable: item.executable,
                searchPath: searchPath,
                generation: generation
            )
            guard generation == reloadGeneration else { return }
        }
    }

    private func connect(
        _ pending: [(config: MCPServerConfig, client: MCPClient)],
        generation: Int
    ) async {
        await withTaskGroup(of: ConnectOutcome.self) { group in
            for item in pending {
                group.addTask {
                    do {
                        let tools = try await item.client.connectAndListTools()
                        return ConnectOutcome(
                            config: item.config,
                            tools: tools,
                            error: nil,
                            client: item.client
                        )
                    } catch {
                        return ConnectOutcome(
                            config: item.config,
                            tools: nil,
                            error: Self.connectionFailure(from: error),
                            client: item.client
                        )
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
                    let slug = Self.uniqueSlug(
                        for: outcome.config,
                        used: &usedSlugs
                    )
                    connections[outcome.config.id] = Connection(
                        config: outcome.config,
                        client: outcome.client,
                        slug: slug,
                        tools: tools
                    )
                    states[outcome.config.id] = .connected(toolCount: tools.count)
                } else {
                    await outcome.client.disconnect()
                    states[outcome.config.id] = .failed(
                        outcome.error ?? MCPConnectionFailure(message: "Failed to connect")
                    )
                }
            }
        }
    }

    private func connectGitHub(
        config: MCPServerConfig,
        executable: URL,
        searchPath: String?,
        generation: Int
    ) async {
        guard let githubOAuth else {
            states[config.id] = .failed(
                MCPConnectionFailure(message: GitHubOAuthError.notConfigured.localizedDescription)
            )
            return
        }

        let showDeviceAuthorization: @MainActor @Sendable (
            GitHubOAuthDeviceAuthorization
        ) -> Void = { [weak self] authorization in
            guard let self, generation == self.reloadGeneration else {
                return
            }
            self.states[config.id] = .authorizingGitHub(
                code: authorization.userCode,
                verificationURL: authorization.verificationURL
            )
        }
        let showInstallationRequired: @MainActor @Sendable (URL) -> Void = {
            [weak self] installationURL in
            guard let self, generation == self.reloadGeneration else {
                return
            }
            self.states[config.id] = .installingGitHub(installationURL)
        }

        do {
            let token = try await githubOAuth.accessToken(
                onDeviceAuthorization: { authorization in
                    await showDeviceAuthorization(authorization)
                },
                onInstallationRequired: { installationURL in
                    await showInstallationRequired(installationURL)
                }
            )
            guard generation == reloadGeneration else { return }

            let catalogEntry = MCPServerCatalog.bundled.entry(matching: config)
            var environment = Self.childEnvironment(
                searchPath: searchPath,
                overrides: config.environment,
                excluding: catalogEntry?.excludedEnvironment ?? []
            )
            environment["GITHUB_PERSONAL_ACCESS_TOKEN"] = token

            states[config.id] = .connecting
            let client = MCPClient(
                executableURL: executable,
                arguments: config.arguments,
                environment: environment,
                workingDirectory: Self.workingDirectory(
                    for: config.id.uuidString
                )
            )
            do {
                let tools = try await client.connectAndListTools()
                guard generation == reloadGeneration else {
                    await client.disconnect()
                    return
                }
                var usedSlugs = Set(connections.values.map(\.slug))
                let slug = Self.uniqueSlug(for: config, used: &usedSlugs)
                connections[config.id] = Connection(
                    config: config,
                    client: client,
                    slug: slug,
                    tools: tools
                )
                states[config.id] = .connected(toolCount: tools.count)
            } catch {
                await client.disconnect()
                states[config.id] = .failed(Self.connectionFailure(from: error))
            }
        } catch {
            guard generation == reloadGeneration else { return }
            states[config.id] = .failed(Self.connectionFailure(from: error))
        }
    }

    private struct ConnectOutcome: Sendable {
        let config: MCPServerConfig
        let tools: [MCPToolInfo]?
        let error: MCPConnectionFailure?
        let client: MCPClient
    }

    nonisolated private static func connectionFailure(from error: Error) -> MCPConnectionFailure {
        if let failure = error as? MCPConnectionFailure {
            return failure
        }
        return MCPConnectionFailure(message: error.localizedDescription)
    }

    private static func toolDefinitions(for connection: Connection) -> [MLXChatToolDefinition] {
        connection.tools.map { tool in
            MLXChatToolDefinition(
                function: MLXChatFunctionDefinition(
                    name: toolName(slug: connection.slug, tool: tool.name),
                    description: tool.description,
                    parameters: tool.parameters
                )
            )
        }
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
        let bundledPrefix = "@bundled/"
        if command.hasPrefix(bundledPrefix) {
            let name = String(command.dropFirst(bundledPrefix.count))
            guard !name.isEmpty, !name.contains("/") else { return nil }
            guard let url = Bundle.main.url(
                forResource: name,
                withExtension: nil,
                subdirectory: "MCPServers"
            ) else {
                return nil
            }
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

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
        overrides: [String: String],
        excluding excludedNames: [String]
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let searchPath, !searchPath.isEmpty {
            environment["PATH"] = searchPath
        }
        for (key, value) in overrides {
            environment[key] = value
        }
        for name in excludedNames {
            environment[name] = nil
        }
        return environment
    }

    private static func workingDirectory(for id: String) -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return support
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent(slug(id), isDirectory: true)
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
