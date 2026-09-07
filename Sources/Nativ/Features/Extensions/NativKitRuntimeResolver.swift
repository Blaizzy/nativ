import Foundation
import NativServerKit

/// The settings-backed capabilities selected Kits can supply to a routine.
struct NativKitRuntimeResolution: Equatable, Sendable {
    let mcpServers: [MCPServerConfig]
    let tools: [ScheduledTool]
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
        var toolIDs = Set<String>()
        var tools: [ScheduledTool] = []
        var skillIDs = Set<UUID>()
        var skills: [NativSkill] = []
        var unavailable = Set<String>()

        func appendServer(_ server: MCPServerConfig, kitName: String) {
            guard server.isEnabled else {
                unavailable.insert("\(kitName): \(server.name.isEmpty ? "MCP server" : server.name) (disabled)")
                return
            }
            guard serverIDs.insert(server.id).inserted else { return }
            servers.append(server)
        }

        for kitID in kitIDs {
            guard let kit = kitCatalog.kit(id: kitID) else {
                unavailable.insert("Kit \(kitID) (unavailable)")
                continue
            }

            for component in kit.components {
                switch component {
                case .mcpServer(.catalog(let catalogID)):
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
                    appendServer(server, kitName: kit.name)

                case .mcpServer(.configured(let id)):
                    guard let server = settings.mcpServers.first(where: { $0.id == id }) else {
                        unavailable.insert("\(kit.name): MCP server \(id.uuidString) (not configured)")
                        continue
                    }
                    appendServer(server, kitName: kit.name)

                case .nativeTool(let name):
                    guard settings.isToolEnabled(name) else {
                        unavailable.insert("\(kit.name): \(name) (disabled)")
                        continue
                    }
                    guard toolIDs.insert(component.id).inserted else { continue }
                    tools.append(ScheduledTool(provider: .builtIn, name: name))

                case .customTool(let id):
                    guard let tool = settings.customTools.first(where: { $0.id == id }) else {
                        unavailable.insert("\(kit.name): Custom tool \(id.uuidString) (not configured)")
                        continue
                    }
                    guard settings.isToolEnabled(tool.toolName) else {
                        unavailable.insert("\(kit.name): \(tool.name) (disabled)")
                        continue
                    }
                    guard toolIDs.insert(component.id).inserted else { continue }
                    tools.append(ScheduledTool(provider: .custom(id), name: tool.toolName))

                case .skill(let id):
                    let definition = kitCatalog.skillDefinition(id: id)
                    guard let skill = settings.skills.first(where: { $0.id == id }) else {
                        let name = definition?.name ?? "Skill \(id.uuidString)"
                        unavailable.insert("\(kit.name): \(name) (not configured)")
                        continue
                    }
                    guard skill.isEnabled else {
                        let name = skill.name.isEmpty ? definition?.name ?? "Skill \(id.uuidString)" : skill.name
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
            tools: tools,
            skills: skills,
            unavailableCapabilities: unavailable.sorted()
        )
    }
}
