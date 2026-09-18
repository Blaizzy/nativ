import Foundation
import NativServerKit

struct MCPCatalogEntry: Decodable, Equatable, Identifiable, Sendable {
    struct LegacyLaunchConfiguration: Decodable, Equatable, Sendable {
        let command: String
        let arguments: [String]

        private enum CodingKeys: String, CodingKey {
            case command
            case arguments = "args"
        }

        init(command: String, arguments: [String] = []) {
            self.command = command
            self.arguments = arguments
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            command = try container.decode(String.self, forKey: .command)
            arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        }
    }

    let id: String
    let name: String
    let summary: String
    let command: String
    let arguments: [String]
    let symbol: String
    let tintName: String
    let requiredEnvironment: [String]
    let excludedEnvironment: [String]
    let legacyLaunchConfigurations: [LegacyLaunchConfiguration]
    let sourceURL: String?

    var logoAssetName: String { "MCPLogo-\(name)" }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, command, symbol, sourceURL
        case arguments = "args"
        case tintName = "tint"
        case requiredEnvironment = "requiredEnv"
        case excludedEnvironment = "excludedEnv"
        case legacyLaunchConfigurations
    }

    init(
        id: String,
        name: String,
        summary: String,
        command: String,
        arguments: [String] = [],
        symbol: String = "server.rack",
        tintName: String = "accent",
        requiredEnvironment: [String] = [],
        excludedEnvironment: [String] = [],
        legacyLaunchConfigurations: [LegacyLaunchConfiguration] = [],
        sourceURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.command = command
        self.arguments = arguments
        self.symbol = symbol
        self.tintName = tintName
        self.requiredEnvironment = requiredEnvironment
        self.excludedEnvironment = excludedEnvironment
        self.legacyLaunchConfigurations = legacyLaunchConfigurations
        self.sourceURL = sourceURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decode(String.self, forKey: .summary)
        command = try container.decode(String.self, forKey: .command)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "server.rack"
        tintName = try container.decodeIfPresent(String.self, forKey: .tintName) ?? "accent"
        requiredEnvironment = try container.decodeIfPresent(
            [String].self,
            forKey: .requiredEnvironment
        ) ?? []
        excludedEnvironment = try container.decodeIfPresent(
            [String].self,
            forKey: .excludedEnvironment
        ) ?? []
        legacyLaunchConfigurations = try container.decodeIfPresent(
            [LegacyLaunchConfiguration].self,
            forKey: .legacyLaunchConfigurations
        ) ?? []
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
    }

    func makeConfiguration(isEnabled: Bool = true) -> MCPServerConfig {
        MCPServerConfig(
            catalogID: id,
            name: name,
            command: command,
            arguments: arguments,
            isEnabled: isEnabled
        )
    }
}

enum MCPServerCatalogError: Error, Equatable {
    case duplicateIdentifier(String)
    case duplicateLaunchConfiguration(String)
}

/// Immutable index of the MCP servers supplied with Nativ.
///
/// Catalog identifiers are the durable identity. Launch configuration matching
/// exists only to adopt settings created before `MCPServerConfig.catalogID` was
/// introduced.
struct MCPServerCatalog: Sendable {
    static let bundled: MCPServerCatalog = {
        let resourceBundles = [Bundle.main, Bundle(for: BundleLocator.self)]
        guard let url = resourceBundles.lazy.compactMap({
            $0.url(forResource: "MCPCatalog", withExtension: "json")
        }).first else {
            assertionFailure("MCPCatalog.json is missing from the application bundle")
            return .empty
        }

        do {
            let entries = try JSONDecoder().decode(
                [MCPCatalogEntry].self,
                from: Data(contentsOf: url)
            )
            return try MCPServerCatalog(entries: entries)
        } catch {
            assertionFailure("Could not load MCPCatalog.json: \(error)")
            return .empty
        }
    }()

    static let empty = MCPServerCatalog(
        entries: [],
        entriesByID: [:],
        entryIDsByLaunchConfiguration: [:]
    )

    let entries: [MCPCatalogEntry]

    private let entriesByID: [String: MCPCatalogEntry]
    private let entryIDsByLaunchConfiguration: [LaunchConfiguration: String]

    init(entries: [MCPCatalogEntry]) throws {
        var entriesByID: [String: MCPCatalogEntry] = [:]
        var entryIDsByLaunchConfiguration: [LaunchConfiguration: String] = [:]

        for entry in entries {
            guard entriesByID.updateValue(entry, forKey: entry.id) == nil else {
                throw MCPServerCatalogError.duplicateIdentifier(entry.id)
            }

            let launchConfigurations = [LaunchConfiguration(entry: entry)]
                + entry.legacyLaunchConfigurations.map(LaunchConfiguration.init)
            for launchConfiguration in launchConfigurations {
                guard entryIDsByLaunchConfiguration.updateValue(
                    entry.id,
                    forKey: launchConfiguration
                ) == nil else {
                    throw MCPServerCatalogError.duplicateLaunchConfiguration(
                        launchConfiguration.command
                    )
                }
            }
        }

        self.init(
            entries: entries,
            entriesByID: entriesByID,
            entryIDsByLaunchConfiguration: entryIDsByLaunchConfiguration
        )
    }

    func entry(id: String) -> MCPCatalogEntry? {
        entriesByID[id]
    }

    func entry(matching server: MCPServerConfig) -> MCPCatalogEntry? {
        if let catalogID = server.catalogID {
            return entriesByID[catalogID]
        }

        let launchConfiguration = LaunchConfiguration(server: server)
        guard let entryID = entryIDsByLaunchConfiguration[launchConfiguration] else {
            return nil
        }
        return entriesByID[entryID]
    }

    func configuredServer(
        for entry: MCPCatalogEntry,
        in servers: [MCPServerConfig]
    ) -> MCPServerConfig? {
        configurationIndex(for: entry, in: servers).map { servers[$0] }
    }

    func isEnabled(_ entry: MCPCatalogEntry, in servers: [MCPServerConfig]) -> Bool {
        configuredServer(for: entry, in: servers)?.isEnabled == true
    }

    /// Enables or disables a built-in server without duplicating legacy settings.
    /// Disabling an unconfigured server is a no-op; enabling it installs the
    /// catalog defaults and records its stable catalog identity.
    func setEnabled(
        _ enabled: Bool,
        for entry: MCPCatalogEntry,
        in servers: inout [MCPServerConfig]
    ) {
        if let index = configurationIndex(for: entry, in: servers) {
            synchronizeConfiguration(at: index, with: entry, in: &servers)
            servers[index].isEnabled = enabled
        } else if enabled {
            servers.append(entry.makeConfiguration())
        }
    }

    /// Refreshes built-in settings to their current catalog launch configuration.
    /// This lets catalog entries move to a new server without changing their
    /// durable identity or the user's enabled state.
    @discardableResult
    func migrateConfigurations(in servers: inout [MCPServerConfig]) -> Bool {
        var changed = false
        for entry in entries {
            guard let index = configurationIndex(for: entry, in: servers) else { continue }
            let original = servers[index]
            synchronizeConfiguration(at: index, with: entry, in: &servers)
            changed = changed || servers[index] != original
        }
        return changed
    }

    func customServers(in servers: [MCPServerConfig]) -> [MCPServerConfig] {
        servers.filter { entry(matching: $0) == nil }
    }

    private init(
        entries: [MCPCatalogEntry],
        entriesByID: [String: MCPCatalogEntry],
        entryIDsByLaunchConfiguration: [LaunchConfiguration: String]
    ) {
        self.entries = entries
        self.entriesByID = entriesByID
        self.entryIDsByLaunchConfiguration = entryIDsByLaunchConfiguration
    }

    private func configurationIndex(
        for entry: MCPCatalogEntry,
        in servers: [MCPServerConfig]
    ) -> Int? {
        if let index = servers.firstIndex(where: { $0.catalogID == entry.id }) {
            return index
        }

        let expectedLaunchConfiguration = LaunchConfiguration(entry: entry)
        return servers.firstIndex {
            guard $0.catalogID == nil else { return false }
            let launchConfiguration = LaunchConfiguration(server: $0)
            return launchConfiguration == expectedLaunchConfiguration
                || entry.legacyLaunchConfigurations.contains {
                    LaunchConfiguration($0) == launchConfiguration
                }
        }
    }

    private func synchronizeConfiguration(
        at index: Int,
        with entry: MCPCatalogEntry,
        in servers: inout [MCPServerConfig]
    ) {
        servers[index].catalogID = entry.id
        servers[index].name = entry.name
        servers[index].command = entry.command
        servers[index].arguments = entry.arguments
        for name in entry.excludedEnvironment {
            servers[index].environment[name] = nil
        }
    }

    private struct LaunchConfiguration: Hashable, Sendable {
        let command: String
        let arguments: [String]

        init(entry: MCPCatalogEntry) {
            command = entry.command
            arguments = entry.arguments
        }

        init(server: MCPServerConfig) {
            command = server.command
            arguments = server.arguments
        }

        init(_ legacy: MCPCatalogEntry.LegacyLaunchConfiguration) {
            command = legacy.command
            arguments = legacy.arguments
        }
    }

    private final class BundleLocator {}
}
