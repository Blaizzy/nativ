import Foundation
import NativServerKit

enum NativKitState: Equatable {
    case off
    case partial(active: Int, total: Int)
    case enabled
}

struct NativKitActivationResult {
    let kit: NativKit
    let enabledComponentCount: Int
    let skills: [NativSkill]
    let mcpTools: [MCPHostedTool]
    let builtInToolNames: [String]
    let customTools: [CustomTool]
    let unavailableComponents: [String]

    var toolDefinitions: [MLXChatToolDefinition] {
        mcpTools.map(\.definition)
    }
}

@MainActor
struct NativKitActivationCoordinator {
    let model: NativModel
    let manager: NativExtensionManager
    let host: MCPHostManager

    func activate(_ kit: NativKit) async -> NativKitActivationResult {
        var settings = model.settings
        var enabledCount = 0
        var unavailable: [String] = []
        var resolvedServerIDs: [UUID] = []
        var resolvedSkills: [NativSkill] = []
        var resolvedCustomTools: [CustomTool] = []

        for extensionID in kit.extensionIDs {
            guard manager.records.contains(where: { $0.id == extensionID && !$0.isRemoved }) else {
                unavailable.append("Extension \(extensionID)")
                continue
            }
            manager.setEnabled(true, extensionID: extensionID)
            if manager.isEnabled(extensionID: extensionID) {
                enabledCount += 1
            } else {
                unavailable.append("Extension \(extensionID)")
            }
        }

        for reference in kit.mcpServers {
            if let serverID = enableServer(reference, settings: &settings, unavailable: &unavailable) {
                resolvedServerIDs.append(serverID)
                enabledCount += 1
            }
        }

        for tool in kit.mcpTools where !resolvedServerIDs.contains(tool.serverID) {
            if enableServer(.configured(tool.serverID), settings: &settings, unavailable: &unavailable) != nil {
                resolvedServerIDs.append(tool.serverID)
            }
        }

        for reference in kit.skills {
            guard let skill = enableSkill(reference, settings: &settings) else {
                unavailable.append("Skill \(skillName(reference))")
                continue
            }
            resolvedSkills.append(skill)
            enabledCount += 1
        }

        for name in kit.builtInToolNames {
            guard availableBuiltInToolNames.contains(name) else {
                unavailable.append("Built-in tool \(name)")
                continue
            }
            settings.disabledToolNames.removeAll { $0 == name }
            enabledCount += 1
        }

        for id in kit.customToolIDs {
            guard let tool = settings.customTools.first(where: { $0.id == id }),
                  (try? tool.definition()) != nil
            else {
                unavailable.append("Custom tool \(id.uuidString)")
                continue
            }
            settings.disabledToolNames.removeAll { $0 == tool.toolName }
            resolvedCustomTools.append(tool)
            enabledCount += 1
        }

        model.settings = settings
        await host.ensureReloaded(servers: settings.mcpServers)

        let selectedToolsByServer = Dictionary(grouping: kit.mcpTools, by: \.serverID)
        var resolvedTools: [MCPHostedTool] = []
        for serverID in resolvedServerIDs.uniqued() {
            if let selectedTools = selectedToolsByServer[serverID], !selectedTools.isEmpty {
                for tool in selectedTools {
                    guard let hostedTool = host.hostedTool(serverID: serverID, name: tool.name) else {
                        unavailable.append("MCP tool \(tool.name)")
                        continue
                    }
                    settings.disabledToolNames.removeAll { $0 == hostedTool.runtimeName }
                    resolvedTools.append(hostedTool)
                    enabledCount += 1
                }
            } else {
                resolvedTools.append(contentsOf: host.hostedTools(forServer: serverID))
            }
        }

        if settings.disabledToolNames != model.settings.disabledToolNames {
            model.settings = settings
        }

        for serverID in resolvedServerIDs {
            if case .failed(let message) = host.states[serverID] {
                unavailable.append("MCP server: \(message)")
            }
        }

        return NativKitActivationResult(
            kit: kit,
            enabledComponentCount: enabledCount,
            skills: resolvedSkills.uniqued(by: \.id),
            mcpTools: resolvedTools.uniqued(by: \.id),
            builtInToolNames: kit.builtInToolNames,
            customTools: resolvedCustomTools,
            unavailableComponents: unavailable.uniqued()
        )
    }

    func state(of kit: NativKit) -> NativKitState {
        var active = 0
        var total = 0

        for extensionID in kit.extensionIDs {
            total += 1
            if manager.isEnabled(extensionID: extensionID) { active += 1 }
        }
        for reference in kit.mcpServers {
            total += 1
            if serverID(for: reference, in: model.settings).flatMap({ id in
                model.settings.mcpServers.first { $0.id == id }
            })?.isEnabled == true {
                active += 1
            }
        }
        for tool in kit.mcpTools {
            total += 1
            if let hostedTool = host.hostedTool(serverID: tool.serverID, name: tool.name),
               !model.settings.disabledToolNames.contains(hostedTool.runtimeName) {
                active += 1
            }
        }
        for name in kit.builtInToolNames {
            total += 1
            if availableBuiltInToolNames.contains(name),
               !model.settings.disabledToolNames.contains(name) {
                active += 1
            }
        }
        for id in kit.customToolIDs {
            total += 1
            if let tool = model.settings.customTools.first(where: { $0.id == id }),
               !model.settings.disabledToolNames.contains(tool.toolName) {
                active += 1
            }
        }
        for reference in kit.skills {
            total += 1
            switch reference {
            case .builtIn(let builtIn):
                if model.settings.skills.first(where: { $0.id == builtIn.id })?.isEnabled == true {
                    active += 1
                }
            case .configured(let id):
                if model.settings.skills.first(where: { $0.id == id })?.isEnabled == true {
                    active += 1
                }
            }
        }

        guard total > 0, active > 0 else { return .off }
        return active == total ? .enabled : .partial(active: active, total: total)
    }

    func componentNames(of kit: NativKit) -> [String] {
        var names = kit.extensionIDs.map { extensionID in
            manager.records.first(where: { $0.id == extensionID })?.manifest.displayName
                ?? extensionID
        }
        names.append(contentsOf: kit.mcpServers.map(serverName))
        names.append(contentsOf: kit.mcpTools.map(\.name))
        names.append(contentsOf: kit.builtInToolNames)
        names.append(contentsOf: kit.customToolIDs.map { id in
            model.settings.customTools.first(where: { $0.id == id })?.name ?? id.uuidString
        })
        names.append(contentsOf: kit.skills.map(skillName))
        return names.uniqued()
    }

    func inactiveComponentNames(of kit: NativKit) -> [String] {
        var names: [String] = []
        for extensionID in kit.extensionIDs where !manager.isEnabled(extensionID: extensionID) {
            names.append(
                manager.records.first(where: { $0.id == extensionID })?.manifest.displayName
                    ?? extensionID
            )
        }
        for reference in kit.mcpServers {
            let enabled = serverID(for: reference, in: model.settings).flatMap { id in
                model.settings.mcpServers.first(where: { $0.id == id })
            }?.isEnabled == true
            if !enabled { names.append(serverName(reference)) }
        }
        for tool in kit.mcpTools {
            guard let hostedTool = host.hostedTool(serverID: tool.serverID, name: tool.name),
                  !model.settings.disabledToolNames.contains(hostedTool.runtimeName)
            else {
                names.append(tool.name)
                continue
            }
        }
        for name in kit.builtInToolNames {
            if !availableBuiltInToolNames.contains(name)
                || model.settings.disabledToolNames.contains(name) {
                names.append(name)
            }
        }
        for id in kit.customToolIDs {
            guard let tool = model.settings.customTools.first(where: { $0.id == id }),
                  !model.settings.disabledToolNames.contains(tool.toolName)
            else {
                names.append(
                    model.settings.customTools.first(where: { $0.id == id })?.name
                        ?? id.uuidString
                )
                continue
            }
        }
        for reference in kit.skills {
            let enabled: Bool
            switch reference {
            case .builtIn(let builtIn):
                enabled = model.settings.skills.first(where: { $0.id == builtIn.id })?.isEnabled == true
            case .configured(let id):
                enabled = model.settings.skills.first(where: { $0.id == id })?.isEnabled == true
            }
            if !enabled { names.append(skillName(reference)) }
        }
        return names.uniqued()
    }

    func server(for reference: NativKitMCPServer) -> MCPServerConfig? {
        serverID(for: reference, in: model.settings).flatMap { id in
            model.settings.mcpServers.first { $0.id == id }
        }
    }

    func skill(for reference: NativKitSkillReference) -> NativSkill? {
        skill(reference, in: model.settings)
    }

    private func enableServer(
        _ reference: NativKitMCPServer,
        settings: inout NativSettings,
        unavailable: inout [String]
    ) -> UUID? {
        switch reference {
        case .catalog(let catalogID):
            guard let entry = MCPCatalogEntry.catalog.first(where: { $0.id == catalogID }) else {
                unavailable.append("MCP catalog server \(catalogID)")
                return nil
            }
            if let index = matchingServerIndex(for: entry, in: settings.mcpServers) {
                settings.mcpServers[index].isEnabled = true
                return settings.mcpServers[index].id
            }
            let config = entry.makeConfig()
            settings.mcpServers.append(config)
            return config.id
        case .configured(let id):
            guard let index = settings.mcpServers.firstIndex(where: { $0.id == id }) else {
                unavailable.append("MCP server \(id.uuidString)")
                return nil
            }
            settings.mcpServers[index].isEnabled = true
            return id
        }
    }

    private func enableSkill(
        _ reference: NativKitSkillReference,
        settings: inout NativSettings
    ) -> NativSkill? {
        switch reference {
        case .builtIn(var skill):
            skill.isEnabled = true
            if let index = settings.skills.firstIndex(where: { $0.id == skill.id }) {
                settings.skills[index].isEnabled = true
                return settings.skills[index]
            }
            settings.skills.append(skill)
            return skill
        case .configured(let id):
            guard let index = settings.skills.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            settings.skills[index].isEnabled = true
            return settings.skills[index]
        }
    }

    private func serverID(for reference: NativKitMCPServer, in settings: NativSettings) -> UUID? {
        switch reference {
        case .catalog(let catalogID):
            guard let entry = MCPCatalogEntry.catalog.first(where: { $0.id == catalogID }),
                  let index = matchingServerIndex(for: entry, in: settings.mcpServers)
            else {
                return nil
            }
            return settings.mcpServers[index].id
        case .configured(let id):
            return settings.mcpServers.contains(where: { $0.id == id }) ? id : nil
        }
    }

    private func skill(_ reference: NativKitSkillReference, in settings: NativSettings) -> NativSkill? {
        switch reference {
        case .builtIn(let builtIn):
            return settings.skills.first(where: { $0.id == builtIn.id }) ?? builtIn
        case .configured(let id):
            return settings.skills.first { $0.id == id }
        }
    }

    private func skillName(_ reference: NativKitSkillReference) -> String {
        switch reference {
        case .builtIn(let skill): skill.name
        case .configured(let id): id.uuidString
        }
    }

    private func serverName(_ reference: NativKitMCPServer) -> String {
        switch reference {
        case .catalog(let catalogID):
            return MCPCatalogEntry.catalog.first(where: { $0.id == catalogID })?.name
                ?? catalogID
        case .configured(let id):
            guard let server = model.settings.mcpServers.first(where: { $0.id == id }) else {
                return id.uuidString
            }
            return server.name.isEmpty ? server.command : server.name
        }
    }

    private func matchingServerIndex(
        for entry: MCPCatalogEntry,
        in servers: [MCPServerConfig]
    ) -> Int? {
        servers.firstIndex {
            $0.command == entry.command && $0.arguments == entry.arguments
        }
    }

    private var availableBuiltInToolNames: Set<String> {
        Set(ChatToolRegistry.definitions(canEditImage: true).map(\.function.name))
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension Array {
    func uniqued<ID: Hashable>(by keyPath: KeyPath<Element, ID>) -> [Element] {
        var seen = Set<ID>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
