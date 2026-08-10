import Combine
import Foundation
import NativServerKit

@MainActor
final class NativKitStore: ObservableObject {
    static let shared = NativKitStore()

    @Published private(set) var userKits: [UserNativKit]

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        userKits = Self.load(from: self.fileURL)
    }

    var availableKits: [NativKit] {
        NativKit.builtIns + userKits.map { $0.resolved() }
    }

    func kit(id: String) -> NativKit? {
        availableKits.first { $0.id == id }
    }

    func userKit(id: UUID) -> UserNativKit? {
        userKits.first { $0.id == id }
    }

    func upsert(_ kit: UserNativKit) {
        let kit = kit.normalized()
        guard kit.isComplete else { return }
        if let index = userKits.firstIndex(where: { $0.id == kit.id }) {
            userKits[index] = kit
        } else {
            userKits.append(kit)
        }
        persist()
    }

    func delete(id: UUID) {
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
            var serverIDs = legacy.mcpServerIDs
            let mcpTools = legacy.toolNames.compactMap { runtimeName -> NativKitMCPTool? in
                guard let parsed = Self.parseLegacyMCPTool(runtimeName, servers: mcpServers) else {
                    return nil
                }
                if !serverIDs.contains(parsed.serverID) { serverIDs.append(parsed.serverID) }
                return parsed
            }
            return UserNativKit(
                id: legacy.id,
                name: legacy.name,
                summary: legacy.summary,
                mcpServerIDs: serverIDs,
                mcpTools: mcpTools,
                builtInToolNames: legacy.toolNames.filter { !$0.hasPrefix("mcp__") },
                skillIDs: legacy.skillIDs,
                extensionIDs: legacy.extensionIDs
            ).normalized()
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(userKits) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> [UserNativKit] {
        guard let data = try? Data(contentsOf: url),
              let kits = try? JSONDecoder().decode([UserNativKit].self, from: data)
        else {
            return []
        }
        return kits.map { $0.normalized() }
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

    private static func parseLegacyMCPTool(
        _ runtimeName: String,
        servers: [MCPServerConfig]
    ) -> NativKitMCPTool? {
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
        return NativKitMCPTool(serverID: server.id, name: toolName)
    }

    private static func slug(_ value: String) -> String {
        let characters = value.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        let result = String(characters)
        return result.isEmpty ? "server" : result
    }

    private struct LegacySettings: Decodable {
        let userKits: [LegacyUserNativKit]?
    }

    private struct LegacyUserNativKit: Decodable {
        let id: UUID
        let name: String
        let summary: String
        let mcpServerIDs: [UUID]
        let toolNames: [String]
        let skillIDs: [UUID]
        let extensionIDs: [String]

        private enum CodingKeys: String, CodingKey {
            case id, name, summary, mcpServerIDs, toolNames, skillIDs, extensionIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
            mcpServerIDs = try container.decodeIfPresent([UUID].self, forKey: .mcpServerIDs) ?? []
            toolNames = try container.decodeIfPresent([String].self, forKey: .toolNames) ?? []
            skillIDs = try container.decodeIfPresent([UUID].self, forKey: .skillIDs) ?? []
            extensionIDs = try container.decodeIfPresent([String].self, forKey: .extensionIDs) ?? []
        }
    }
}
