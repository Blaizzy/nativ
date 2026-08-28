import Foundation
import NativServerKit

enum NativKitCapabilityReadiness: Equatable {
    case ready
    case off
    case connecting
    case needsConfiguration(String)
    case unavailable(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var label: String? {
        switch self {
        case .ready: nil
        case .off: "Off"
        case .connecting: "Connecting"
        case .needsConfiguration: "Needs setup"
        case .unavailable: "Unavailable"
        }
    }
}

enum NativKitIssueReason: Equatable {
    case kitDisabled
    case componentRemoved
    case globallyOff
    case connecting
    case needsConfiguration(String)
    case connectionFailed(String)
    case unsupportedInBackground
}

struct NativKitIssue: Equatable, Identifiable {
    let componentID: String
    let componentName: String
    let capability: NativKitCapabilityReference?
    let reason: NativKitIssueReason

    var id: String { "\(componentID):\(String(describing: reason))" }

    var message: String {
        switch reason {
        case .kitDisabled:
            "\(componentName) is turned off."
        case .componentRemoved:
            "\(componentName) is no longer available."
        case .globallyOff:
            "Turn on \(componentName) before using this Kit."
        case .connecting:
            "\(componentName) is still connecting."
        case .needsConfiguration(let detail):
            detail.isEmpty ? "Set up \(componentName) before using this Kit." : detail
        case .connectionFailed(let detail):
            detail.isEmpty ? "\(componentName) failed to connect." : "\(componentName): \(detail)"
        case .unsupportedInBackground:
            "\(componentName) requires an interactive chat."
        }
    }
}

enum NativKitAvailability: Equatable {
    case ready
    case needsSetup(Int)
    case unavailable(Int)
}

struct NativKitEvaluation: Equatable {
    let availability: NativKitAvailability
    let issues: [NativKitIssue]

    var isReady: Bool { issues.isEmpty }

    var summary: String? {
        issues.first?.message
    }
}

enum NativKitExecutionContext {
    case chat
    case routine
}

enum NativKitExecutionError: LocalizedError {
    case removed
    case notReady(String, [NativKitIssue])

    var errorDescription: String? {
        switch self {
        case .removed:
            return "The selected Kit is no longer available."
        case .notReady(let name, let issues):
            let details = issues.prefix(3).map(\.message).joined(separator: " ")
            return details.isEmpty ? "\(name) is not ready." : "\(name) is not ready. \(details)"
        }
    }
}

struct NativKitExecutionPlan {
    let kit: CustomNativKit
    let allowedToolNames: Set<String>
    let toolDefinitions: [MLXChatToolDefinition]
    let skills: [NativSkill]
    let customToolsByName: [String: CustomTool]
    let mcpToolsByName: [String: MCPHostedTool]
    let issues: [NativKitIssue]

    var isReady: Bool { issues.isEmpty }
}

struct NativKitMCPChoice: Identifiable {
    let reference: NativKitMCPServerReference
    let aliases: [NativKitMCPServerReference]
    let name: String
    let detail: String
    let readiness: NativKitCapabilityReadiness
    let tools: [MCPHostedTool]

    var id: NativKitMCPServerReference { reference }

    var allReferences: [NativKitMCPServerReference] {
        [reference] + aliases
    }
}

struct NativKitToolChoice: Identifiable {
    enum Source {
        case native
        case custom
    }

    let id: String
    let name: String
    let detail: String
    let readiness: NativKitCapabilityReadiness
    let source: Source
    let customToolID: UUID?
}

struct NativKitSkillChoice: Identifiable {
    let reference: NativKitSkillReference
    let aliases: [NativKitSkillReference]
    let name: String
    let detail: String
    let readiness: NativKitCapabilityReadiness

    var id: NativKitSkillReference { reference }

    var allReferences: [NativKitSkillReference] {
        [reference] + aliases
    }
}

@MainActor
struct NativKitCapabilityInventory {
    let settings: NativSettings
    let host: MCPHostManager

    var mcpChoices: [NativKitMCPChoice] {
        let servers = settings.mcpServers
            .filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return servers.compactMap { server in
            if let catalogEntry = MCPCatalogEntry.catalog.first(where: {
                $0.configuredServer(in: [server]) != nil
            }) {
                guard catalogEntry.configuredServer(in: servers)?.id == server.id else {
                    return nil
                }
                return NativKitMCPChoice(
                    reference: .catalog(catalogEntry.id),
                    aliases: servers
                        .filter { catalogEntry.configuredServer(in: [$0]) != nil }
                        .map { .configured($0.id) },
                    name: server.name.isEmpty ? catalogEntry.name : server.name,
                    detail: server.command,
                    readiness: readiness(of: server),
                    tools: host.hostedTools(forServer: server.id)
                )
            }
            return NativKitMCPChoice(
                reference: .configured(server.id),
                aliases: [],
                name: server.name.isEmpty ? server.command : server.name,
                detail: server.command,
                readiness: readiness(of: server),
                tools: host.hostedTools(forServer: server.id)
            )
        }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    var toolChoices: [NativKitToolChoice] {
        let native = ChatToolRegistry.descriptors(canEditImage: true).map { descriptor in
            let name = descriptor.definition.function.name
            let ready = descriptor.configuration?.isReady ?? true
            let readiness: NativKitCapabilityReadiness
            if !ready {
                readiness = .needsConfiguration("Configure \(descriptor.configuration?.displayName ?? name) before using it.")
            } else if settings.disabledToolNames.contains(name) {
                readiness = .off
            } else {
                readiness = .ready
            }
            return NativKitToolChoice(
                id: "native:\(name)",
                name: humanized(name),
                detail: descriptor.definition.function.description,
                readiness: readiness,
                source: .native,
                customToolID: nil
            )
        }
        let custom = settings.customTools.map { tool in
            let readiness: NativKitCapabilityReadiness
            if (try? tool.definition()) == nil {
                readiness = .needsConfiguration("Finish configuring \(tool.name) before using it.")
            } else if settings.disabledToolNames.contains(tool.toolName) {
                readiness = .off
            } else {
                readiness = .ready
            }
            return NativKitToolChoice(
                id: "custom:\(tool.id.uuidString)",
                name: tool.name,
                detail: tool.displaySummary,
                readiness: readiness,
                source: .custom,
                customToolID: tool.id
            )
        }
        return (native + custom).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var skillChoices: [NativKitSkillChoice] {
        let builtInSkillIDs = Set(CustomNativKitCatalog.builtInSkills.map(\.skill.id))
        let builtIn = CustomNativKitCatalog.builtInSkills.map { skill in
            NativKitSkillChoice(
                reference: .builtIn(skill.id),
                aliases: settings.skills
                    .filter { $0.id == skill.skill.id }
                    .map { .configured($0.id) },
                name: skill.name,
                detail: "Included with Nativ",
                readiness: .ready
            )
        }
        let configured = settings.skills
            .filter {
                $0.id != NativSkill.builtInToolGuideID
                    && !builtInSkillIDs.contains($0.id)
            }
            .map { skill in
                NativKitSkillChoice(
                    reference: .configured(skill.id),
                    aliases: [],
                    name: skill.name,
                    detail: skill.instructions,
                    readiness: skill.isEnabled ? .ready : .off
                )
            }
        return (builtIn + configured).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func evaluation(of kit: CustomNativKit) -> NativKitEvaluation {
        let plan = plan(for: kit, context: .chat, canEditImage: true)
        let unavailable = plan.issues.filter {
            if case .componentRemoved = $0.reason { return true }
            return false
        }
        let availability: NativKitAvailability
        if plan.issues.isEmpty {
            availability = .ready
        } else if unavailable.isEmpty {
            availability = .needsSetup(plan.issues.count)
        } else {
            availability = .unavailable(plan.issues.count)
        }
        return NativKitEvaluation(availability: availability, issues: plan.issues)
    }

    func plan(
        for kit: CustomNativKit,
        context: NativKitExecutionContext,
        canEditImage: Bool
    ) -> NativKitExecutionPlan {
        var definitions: [MLXChatToolDefinition] = []
        var skills: [NativSkill] = []
        var customTools: [String: CustomTool] = [:]
        var mcpTools: [String: MCPHostedTool] = [:]
        var issues: [NativKitIssue] = []

        if !kit.isEnabled {
            issues.append(NativKitIssue(
                componentID: kit.id,
                componentName: kit.name,
                capability: nil,
                reason: .kitDisabled
            ))
        }

        let nativeByName = Dictionary(
            uniqueKeysWithValues: ChatToolRegistry.descriptors(canEditImage: canEditImage).map {
                ($0.definition.function.name, $0)
            }
        )
        for name in kit.contents.nativeToolNames {
            guard let descriptor = nativeByName[name] else {
                if name == ChatImageToolRegistry.editToolName, !canEditImage { continue }
                issues.append(issue(.nativeTool(name), name: humanized(name), reason: .componentRemoved))
                continue
            }
            if context == .routine && !Self.backgroundToolNames.contains(name) {
                issues.append(issue(.nativeTool(name), name: humanized(name), reason: .unsupportedInBackground))
            } else if descriptor.configuration?.isReady == false {
                issues.append(issue(
                    .nativeTool(name),
                    name: humanized(name),
                    reason: .needsConfiguration("Configure \(descriptor.configuration?.displayName ?? humanized(name)) before using this Kit.")
                ))
            } else if settings.disabledToolNames.contains(name) {
                issues.append(issue(.nativeTool(name), name: humanized(name), reason: .globallyOff))
            } else {
                definitions.append(descriptor.definition)
            }
        }

        for id in kit.contents.customToolIDs {
            guard let tool = settings.customTools.first(where: { $0.id == id }) else {
                issues.append(issue(.customTool(id), name: "Custom tool", reason: .componentRemoved))
                continue
            }
            guard let definition = try? tool.definition() else {
                issues.append(issue(
                    .customTool(id),
                    name: tool.name,
                    reason: .needsConfiguration("Finish configuring \(tool.name) before using this Kit.")
                ))
                continue
            }
            if context == .routine && tool.kind == .script {
                issues.append(issue(.customTool(id), name: tool.name, reason: .unsupportedInBackground))
            } else if settings.disabledToolNames.contains(tool.toolName) {
                issues.append(issue(.customTool(id), name: tool.name, reason: .globallyOff))
            } else {
                definitions.append(definition)
                customTools[tool.toolName] = tool
            }
        }

        for reference in kit.contents.skillReferences {
            switch reference {
            case .builtIn(let id):
                guard let skill = CustomNativKitCatalog.builtInSkill(id: id)?.skill else {
                    issues.append(issue(.skill(reference), name: "Skill", reason: .componentRemoved))
                    continue
                }
                skills.append(skill)
            case .configured(let id):
                guard let skill = settings.skills.first(where: { $0.id == id }) else {
                    issues.append(issue(.skill(reference), name: "Skill", reason: .componentRemoved))
                    continue
                }
                if skill.isEnabled {
                    skills.append(skill)
                } else {
                    issues.append(issue(.skill(reference), name: skill.name, reason: .globallyOff))
                }
            }
        }

        for selection in kit.contents.mcpSelections {
            guard let server = configuredServer(for: selection.server) else {
                issues.append(issue(
                    .mcp(selection.server),
                    name: serverName(selection.server),
                    reason: .needsConfiguration("Add \(serverName(selection.server)) from MCP before using this Kit.")
                ))
                continue
            }
            let displayName = server.name.isEmpty ? server.command : server.name
            guard server.isEnabled else {
                issues.append(issue(.mcp(selection.server), name: displayName, reason: .globallyOff))
                continue
            }
            switch host.states[server.id] {
            case .connected:
                let hosted = host.hostedTools(forServer: server.id)
                let selected: [MCPHostedTool]
                switch selection.tools {
                case .all:
                    selected = hosted
                case .named(let names):
                    selected = names.compactMap { name in
                        guard let tool = hosted.first(where: { $0.name == name }) else {
                            issues.append(issue(
                                .mcp(selection.server),
                                name: name,
                                reason: .componentRemoved
                            ))
                            return nil
                        }
                        return tool
                    }
                }
                for tool in selected {
                    if settings.disabledToolNames.contains(tool.runtimeName) {
                        issues.append(issue(
                            .mcpTool(server: selection.server, name: tool.name),
                            name: tool.name,
                            reason: .globallyOff
                        ))
                    } else {
                        definitions.append(tool.definition)
                        mcpTools[tool.runtimeName] = tool
                    }
                }
            case .connecting:
                issues.append(issue(.mcp(selection.server), name: displayName, reason: .connecting))
            case .failed(let detail):
                issues.append(issue(.mcp(selection.server), name: displayName, reason: .connectionFailed(detail)))
            case .disabled:
                issues.append(issue(.mcp(selection.server), name: displayName, reason: .globallyOff))
            case nil:
                issues.append(issue(
                    .mcp(selection.server),
                    name: displayName,
                    reason: .needsConfiguration("Connect \(displayName) before using this Kit.")
                ))
            }
        }

        let uniqueDefinitions = definitions.uniqued(by: { $0.function.name })
        let allowed = Set(uniqueDefinitions.map { $0.function.name })
        return NativKitExecutionPlan(
            kit: kit,
            allowedToolNames: allowed,
            toolDefinitions: uniqueDefinitions,
            skills: skills.uniqued(by: { $0.id }),
            customToolsByName: customTools,
            mcpToolsByName: mcpTools,
            issues: issues.uniqued(by: { $0.id })
        )
    }

    func configuredServer(for reference: NativKitMCPServerReference) -> MCPServerConfig? {
        switch reference {
        case .catalog(let id):
            return MCPCatalogEntry.catalog.first(where: { $0.id == id })?
                .configuredServer(in: settings.mcpServers)
        case .configured(let id):
            return settings.mcpServers.first { $0.id == id }
        }
    }

    func serverName(_ reference: NativKitMCPServerReference) -> String {
        if let server = configuredServer(for: reference) {
            return server.name.isEmpty ? server.command : server.name
        }
        if case .catalog(let id) = reference {
            return MCPCatalogEntry.catalog.first(where: { $0.id == id })?.name ?? id
        }
        return "MCP server"
    }

    private func readiness(of server: MCPServerConfig) -> NativKitCapabilityReadiness {
        guard server.isEnabled else { return .off }
        switch host.states[server.id] {
        case .connected: return .ready
        case .connecting: return .connecting
        case .failed(let detail): return .unavailable(detail)
        case .disabled: return .off
        case nil: return .needsConfiguration("Not connected")
        }
    }

    private func issue(
        _ capability: NativKitCapabilityReference,
        name: String,
        reason: NativKitIssueReason
    ) -> NativKitIssue {
        NativKitIssue(
            componentID: capability.id,
            componentName: name,
            capability: capability,
            reason: reason
        )
    }

    private func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private static let backgroundToolNames: Set<String> = [
        ChatSystemMonitorToolRegistry.toolName,
        ChatModelLibraryToolRegistry.toolName,
        ChatServerStatsToolRegistry.toolName,
        ChatWebSearchToolRegistry.toolName,
    ]
}

private extension Array {
    func uniqued<ID: Hashable>(by identifier: (Element) -> ID) -> [Element] {
        var seen = Set<ID>()
        return filter { seen.insert(identifier($0)).inserted }
    }
}
