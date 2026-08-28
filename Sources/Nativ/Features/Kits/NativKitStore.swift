import Combine
import Foundation
import NativServerKit

@MainActor
final class NativKitStore: ObservableObject {
    static let shared = NativKitStore()

    @Published private(set) var userKits: [UserNativKit]
    @Published private(set) var builtInOverrides: [String: BuiltInOverride]

    struct BuiltInOverride: Codable, Equatable {
        var isEnabled: Bool
        var contents: NativKitContents
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        var userKits: [UserNativKit]
        var builtInOverrides: [String: BuiltInOverride]
    }

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        let loaded = Self.load(from: self.fileURL)
        userKits = loaded.userKits
        builtInOverrides = loaded.builtInOverrides
    }

    var allKits: [CustomNativKit] {
        CustomNativKitCatalog.builtInKits.map { kit in
            guard let override = builtInOverrides[kit.id] else { return kit }
            var resolved = kit
            resolved.isEnabled = override.isEnabled
            resolved.contents = override.contents
            return resolved.normalized()
        } + userKits.map { $0.resolved() }
    }

    var enabledKits: [CustomNativKit] {
        allKits.filter(\.isEnabled)
    }

    func kit(id: String) -> CustomNativKit? {
        allKits.first { $0.id == id }
    }

    func save(_ kit: CustomNativKit) {
        let kit = kit.normalized()
        guard !kit.name.isEmpty, !kit.contents.isEmpty else { return }
        if kit.isBuiltIn {
            builtInOverrides[kit.id] = BuiltInOverride(
                isEnabled: kit.isEnabled,
                contents: kit.contents
            )
        } else if let id = UUID(uuidString: kit.id) {
            let userKit = UserNativKit(
                id: id,
                name: kit.name,
                summary: kit.summary,
                isEnabled: kit.isEnabled,
                contents: kit.contents
            ).normalized()
            if let index = userKits.firstIndex(where: { $0.id == id }) {
                userKits[index] = userKit
            } else {
                userKits.append(userKit)
            }
        }
        persist()
    }

    func create(_ kit: UserNativKit) {
        let kit = kit.normalized()
        guard kit.isComplete else { return }
        if let index = userKits.firstIndex(where: { $0.id == kit.id }) {
            userKits[index] = kit
        } else {
            userKits.append(kit)
        }
        persist()
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard var kit = kit(id: id) else { return }
        kit.isEnabled = enabled
        save(kit)
    }

    func resetBuiltIn(id: String) {
        builtInOverrides[id] = nil
        persist()
    }

    func deleteUserKit(id: UUID) {
        userKits.removeAll { $0.id == id }
        persist()
    }

    func migrateLegacySettings(
        mcpServers: [MCPServerConfig],
        from settingsURL: URL? = nil
    ) {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let settingsURL = settingsURL ?? Self.legacySettingsURL
        guard let data = try? Data(contentsOf: settingsURL),
              let payload = try? PropertyListDecoder().decode(LegacySettings.self, from: data),
              let legacyKits = payload.userKits
        else {
            return
        }
        userKits = legacyKits.map { legacy in
            let migrated = Self.migrate(
                id: legacy.id,
                name: legacy.name,
                summary: legacy.summary,
                isEnabled: true,
                mcpServerIDs: legacy.mcpServerIDs,
                mcpTools: legacy.toolNames.compactMap {
                    Self.parseLegacyMCPTool($0, servers: mcpServers)
                },
                builtInToolNames: legacy.toolNames.filter { !$0.hasPrefix("mcp__") },
                customToolIDs: [],
                skillIDs: legacy.skillIDs
            )
            return migrated
        }
        persist()
    }

    private func persist() {
        let payload = Payload(
            schemaVersion: 2,
            userKits: userKits,
            builtInOverrides: builtInOverrides
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> Payload {
        guard let data = try? Data(contentsOf: url) else {
            return Payload(schemaVersion: 2, userKits: [], builtInOverrides: [:])
        }
        if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            return Payload(
                schemaVersion: 2,
                userKits: payload.userKits.map { $0.normalized() },
                builtInOverrides: payload.builtInOverrides
            )
        }
        if let legacy = try? JSONDecoder().decode([LegacyStoredKit].self, from: data) {
            return Payload(
                schemaVersion: 2,
                userKits: legacy.map {
                    migrate(
                        id: $0.id,
                        name: $0.name,
                        summary: $0.summary,
                        isEnabled: $0.isEnabled ?? true,
                        mcpServerIDs: $0.mcpServerIDs,
                        mcpTools: $0.mcpTools,
                        builtInToolNames: $0.builtInToolNames,
                        customToolIDs: $0.customToolIDs,
                        skillIDs: $0.skillIDs
                    )
                },
                builtInOverrides: [:]
            )
        }
        return Payload(schemaVersion: 2, userKits: [], builtInOverrides: [:])
    }

    private static func migrate(
        id: UUID,
        name: String,
        summary: String,
        isEnabled: Bool,
        mcpServerIDs: [UUID],
        mcpTools: [LegacyMCPTool],
        builtInToolNames: [String],
        customToolIDs: [UUID],
        skillIDs: [UUID]
    ) -> UserNativKit {
        let toolsByServer = Dictionary(grouping: mcpTools, by: \.serverID)
        let serverIDs = Set(mcpServerIDs).union(toolsByServer.keys)
        let selections = serverIDs.map { serverID -> NativKitMCPSelection in
            let names = toolsByServer[serverID]?.map(\.name) ?? []
            return NativKitMCPSelection(
                server: .configured(serverID),
                tools: names.isEmpty ? .all : .named(names)
            )
        }
        return UserNativKit(
            id: id,
            name: name,
            summary: summary,
            isEnabled: isEnabled,
            contents: NativKitContents(
                mcpSelections: selections,
                nativeToolNames: builtInToolNames,
                customToolIDs: customToolIDs,
                skillReferences: skillIDs.map(NativKitSkillReference.configured)
            )
        ).normalized()
    }

    private static func parseLegacyMCPTool(
        _ runtimeName: String,
        servers: [MCPServerConfig]
    ) -> LegacyMCPTool? {
        guard runtimeName.hasPrefix("mcp__") else { return nil }
        let remainder = runtimeName.dropFirst("mcp__".count)
        guard let separator = remainder.range(of: "__") else { return nil }
        let runtimeSlug = String(remainder[..<separator.lowerBound])
        let toolName = String(remainder[separator.upperBound...])
        guard !toolName.isEmpty,
              let server = servers.first(where: {
                  let base = slug($0.name.isEmpty ? $0.command : $0.name)
                  return runtimeSlug == base || runtimeSlug.hasPrefix("\(base)_")
              })
        else {
            return nil
        }
        return LegacyMCPTool(serverID: server.id, name: toolName)
    }

    private static func slug(_ value: String) -> String {
        let characters = value.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : Character("_")
        }
        let result = String(characters)
        return result.isEmpty ? "server" : result
    }

    private static var defaultFileURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Kits", isDirectory: true)
            .appendingPathComponent("kits.json")
    }

    private static var legacySettingsURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Settings.plist")
    }

    private struct LegacyMCPTool: Codable {
        let serverID: UUID
        let name: String
    }

    private struct LegacyStoredKit: Decodable {
        let id: UUID
        let name: String
        let summary: String
        let isEnabled: Bool?
        let mcpServerIDs: [UUID]
        let mcpTools: [LegacyMCPTool]
        let builtInToolNames: [String]
        let customToolIDs: [UUID]
        let skillIDs: [UUID]

        private enum CodingKeys: String, CodingKey {
            case id, name, summary, isEnabled, mcpServerIDs, mcpTools
            case builtInToolNames, customToolIDs, skillIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
            isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled)
            mcpServerIDs = try container.decodeIfPresent([UUID].self, forKey: .mcpServerIDs) ?? []
            mcpTools = try container.decodeIfPresent([LegacyMCPTool].self, forKey: .mcpTools) ?? []
            builtInToolNames = try container.decodeIfPresent([String].self, forKey: .builtInToolNames) ?? []
            customToolIDs = try container.decodeIfPresent([UUID].self, forKey: .customToolIDs) ?? []
            skillIDs = try container.decodeIfPresent([UUID].self, forKey: .skillIDs) ?? []
        }
    }

    private struct LegacySettings: Decodable {
        let userKits: [LegacySettingsKit]?
    }

    private struct LegacySettingsKit: Decodable {
        let id: UUID
        let name: String
        let summary: String
        let mcpServerIDs: [UUID]
        let toolNames: [String]
        let skillIDs: [UUID]
    }
}
