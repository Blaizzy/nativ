import Foundation
import NativServerKit

/// The settings-backed capabilities selected Kits can supply to a routine.
struct NativKitRuntimeResolution: Equatable, Sendable {
    let mcpServers: [MCPServerConfig]
    let skills: [NativSkill]
    let unavailableCapabilities: [String]
}

/// Resolves selected Kit identities and deduplicates their shared capabilities.
enum NativKitRuntimeResolver {
    static func resolve(
        kitIDs: [String],
        settings: NativSettings,
        kitCatalog: NativKitCatalog = .bundled,
        mcpCatalog: MCPServerCatalog = .bundled
    ) -> NativKitRuntimeResolution {
        var serverIDs = Set<UUID>()
        var servers: [MCPServerConfig] = []
        var skillIDs = Set<UUID>()
        var skills: [NativSkill] = []
        var unavailable = Set<String>()

        for kitID in kitIDs {
            guard let kit = kitCatalog.kit(id: kitID) else {
                unavailable.insert("Kit \(kitID) (unavailable)")
                continue
            }

            for component in kit.components {
                switch component {
                case .mcpServer(let catalogID):
                    guard let entry = mcpCatalog.entry(id: catalogID) else {
                        unavailable.insert("\(kit.name): \(catalogID) (unavailable)")
                        continue
                    }
                    guard let server = mcpCatalog.configuredServer(
                        for: entry,
                        in: settings.mcpServers
                    ) else {
                        unavailable.insert("\(kit.name): \(entry.name) (not configured)")
                        continue
                    }
                    guard server.isEnabled else {
                        unavailable.insert("\(kit.name): \(entry.name) (disabled)")
                        continue
                    }
                    guard serverIDs.insert(server.id).inserted else { continue }
                    servers.append(server)

                case .skill(let definition):
                    guard let skill = settings.skills.first(where: { $0.id == definition.id }) else {
                        unavailable.insert("\(kit.name): \(definition.name) (not configured)")
                        continue
                    }
                    guard skill.isEnabled else {
                        let name = skill.name.isEmpty ? definition.name : skill.name
                        unavailable.insert("\(kit.name): \(name) (disabled)")
                        continue
                    }
                    guard skillIDs.insert(skill.id).inserted else { continue }
                    skills.append(skill)

                case .extensionPackage:
                    break
                }
            }
        }

        return NativKitRuntimeResolution(
            mcpServers: servers,
            skills: skills,
            unavailableCapabilities: unavailable.sorted()
        )
    }
}
