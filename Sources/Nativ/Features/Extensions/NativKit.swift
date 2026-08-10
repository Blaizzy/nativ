import NativServerKit
import SwiftUI

enum NativKitMCP: Equatable {
    case catalog(String)
    case configured(UUID)
}

enum NativKitSkill: Equatable {
    case builtIn(NativSkill)
    case configured(UUID)
}

struct UserNativKit: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var summary: String
    var mcpServerIDs: [UUID]
    var toolNames: [String]
    var skillIDs: [UUID]
    var extensionIDs: [String]

    init(
        id: UUID = UUID(),
        name: String = "",
        summary: String = "",
        mcpServerIDs: [UUID] = [],
        toolNames: [String] = [],
        skillIDs: [UUID] = [],
        extensionIDs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.mcpServerIDs = mcpServerIDs
        self.toolNames = toolNames
        self.skillIDs = skillIDs
        self.extensionIDs = extensionIDs
    }

    enum CodingKeys: String, CodingKey {
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

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!mcpServerIDs.isEmpty || !toolNames.isEmpty || !skillIDs.isEmpty || !extensionIDs.isEmpty)
    }

    func resolved() -> NativKit {
        NativKit(
            id: id.uuidString,
            name: name,
            summary: summary,
            symbol: "shippingbox",
            tint: .teal,
            isBuiltIn: false,
            mcpServers: mcpServerIDs.map(NativKitMCP.configured),
            toolNames: toolNames,
            skills: skillIDs.map(NativKitSkill.configured),
            extensionIDs: extensionIDs
        )
    }
}

struct NativKit: Identifiable {
    let id: String
    let name: String
    let summary: String
    let symbol: String
    let tint: Color
    let isBuiltIn: Bool
    let mcpServers: [NativKitMCP]
    let toolNames: [String]
    let skills: [NativKitSkill]
    let extensionIDs: [String]

    var inventory: String {
        var parts: [String] = []
        let servers = mcpServers.count
        let extensions = extensionIDs.count
        let tools = toolNames.count
        if extensions > 0 { parts.append("\(extensions) extension\(extensions == 1 ? "" : "s")") }
        if servers > 0 { parts.append("\(servers) MCP server\(servers == 1 ? "" : "s")") }
        if tools > 0 { parts.append("\(tools) tool\(tools == 1 ? "" : "s")") }
        if !skills.isEmpty { parts.append("\(skills.count) skill\(skills.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

private extension NativSkill {
    static func kit(_ uuid: String, _ name: String, _ instructions: String) -> NativSkill {
        NativSkill(id: UUID(uuidString: uuid)!, name: name, instructions: instructions, isEnabled: true)
    }
}

extension NativKit {
    static let all: [NativKit] = [
        NativKit(
            id: "engineering",
            name: "Engineering",
            summary: "Read code, work with Git and GitHub, and pull in docs while you build.",
            symbol: "chevron.left.forwardslash.chevron.right",
            tint: .indigo,
            isBuiltIn: true,
            mcpServers: ["git", "github", "filesystem", "fetch"].map(NativKitMCP.catalog),
            toolNames: [],
            skills: [
                .builtIn(
                    .kit(
                        "A1000000-0000-4000-8000-000000000001",
                        "Working in a codebase",
                        """
                        You're helping with software. Ground every answer in the actual \
                        repository, not assumptions.

                        - Use the Git and filesystem tools to read real files, history, and \
                        diffs before proposing changes; cite concrete paths and symbols.
                        - When you touch GitHub, prefer read-only queries (issues, PRs, code \
                        search) and summarize findings precisely.
                        - Match the project's existing style and conventions. Keep changes \
                        minimal and explain the reasoning.
                        - Fetch documentation when an API or library detail is uncertain \
                        rather than guessing.
                        """
                    )
                ),
            ],
            extensionIDs: []
        ),
        NativKit(
            id: "research",
            name: "Research",
            summary: "Gather sources from the web, keep notes, and query your own data.",
            symbol: "magnifyingglass",
            tint: .purple,
            isBuiltIn: true,
            mcpServers: ["fetch", "memory", "sqlite"].map(NativKitMCP.catalog),
            toolNames: [],
            skills: [
                .builtIn(
                    .kit(
                        "A2000000-0000-4000-8000-000000000002",
                        "Researching with sources",
                        """
                        You're doing careful research. Prioritize accuracy and traceability.

                        - Use the fetch tool to read primary sources; quote or paraphrase \
                        with a link back to where each claim came from.
                        - Record durable findings in the memory tool so they carry across \
                        the conversation, and recall them before re-fetching.
                        - Query the SQLite tool for anything in the user's own dataset \
                        instead of estimating.
                        - Separate what the sources say from your own inference, and flag \
                        uncertainty plainly.
                        """
                    )
                ),
            ],
            extensionIDs: []
        ),
    ]
}

enum NativKitState: Equatable {
    case off
    case partial(active: Int, total: Int)
    case enabled
}

@MainActor
enum NativKitActivation {
    static func setEnabled(
        _ enabled: Bool,
        kit: NativKit,
        model: NativModel,
        manager: NativExtensionManager
    ) {
        for extensionID in kit.extensionIDs {
            manager.setEnabled(enabled, extensionID: extensionID)
        }
        for server in kit.mcpServers {
            setServerEnabled(enabled, target: server, model: model)
        }
        for name in kit.toolNames {
            setToolEnabled(enabled, name: name, model: model)
        }
        for skill in kit.skills {
            setSkillEnabled(enabled, target: skill, model: model)
        }
    }

    static func state(of kit: NativKit, model: NativModel, manager: NativExtensionManager) -> NativKitState {
        var total = 0
        var active = 0

        for extensionID in kit.extensionIDs {
            total += 1
            if manager.isEnabled(extensionID: extensionID) { active += 1 }
        }
        for server in kit.mcpServers {
            total += 1
            if isServerEnabled(server, model: model) { active += 1 }
        }
        for name in kit.toolNames {
            total += 1
            if isToolEnabled(name, model: model) { active += 1 }
        }
        for skill in kit.skills {
            total += 1
            if isSkillEnabled(skill, model: model) { active += 1 }
        }

        guard total > 0, active > 0 else { return .off }
        return active == total ? .enabled : .partial(active: active, total: total)
    }

    static func setServerEnabled(_ enabled: Bool, target: NativKitMCP, model: NativModel) {
        switch target {
        case .catalog(let catalogID):
            guard let entry = MCPCatalogEntry.catalog.first(where: { $0.id == catalogID }) else { return }
            if let index = matchingServerIndex(for: entry, in: model.settings.mcpServers) {
                model.settings.mcpServers[index].isEnabled = enabled
            } else if enabled {
                model.settings.mcpServers.append(entry.makeConfig())
            }
        case .configured(let id):
            guard let index = model.settings.mcpServers.firstIndex(where: { $0.id == id }) else { return }
            model.settings.mcpServers[index].isEnabled = enabled
        }
    }

    static func setSkillEnabled(_ enabled: Bool, target: NativKitSkill, model: NativModel) {
        switch target {
        case .builtIn(let skill):
            if let index = model.settings.skills.firstIndex(where: { $0.id == skill.id }) {
                model.settings.skills[index].isEnabled = enabled
            } else if enabled {
                model.settings.skills.append(skill)
            }
        case .configured(let id):
            guard let index = model.settings.skills.firstIndex(where: { $0.id == id }) else { return }
            model.settings.skills[index].isEnabled = enabled
        }
    }

    static func setToolEnabled(_ enabled: Bool, name: String, model: NativModel) {
        if enabled {
            model.settings.disabledToolNames.removeAll { $0 == name }
        } else if !model.settings.disabledToolNames.contains(name) {
            model.settings.disabledToolNames.append(name)
        }
    }

    static func isServerEnabled(_ target: NativKitMCP, model: NativModel) -> Bool {
        switch target {
        case .catalog(let catalogID):
            guard let entry = MCPCatalogEntry.catalog.first(where: { $0.id == catalogID }),
                  let index = matchingServerIndex(for: entry, in: model.settings.mcpServers)
            else { return false }
            return model.settings.mcpServers[index].isEnabled
        case .configured(let id):
            return model.settings.mcpServers.first(where: { $0.id == id })?.isEnabled ?? false
        }
    }

    static func isSkillEnabled(_ target: NativKitSkill, model: NativModel) -> Bool {
        skill(for: target, model: model)?.isEnabled ?? false
    }

    static func isToolEnabled(_ name: String, model: NativModel) -> Bool {
        !model.settings.disabledToolNames.contains(name)
    }

    static func skill(for target: NativKitSkill, model: NativModel) -> NativSkill? {
        switch target {
        case .builtIn(let skill):
            return model.settings.skills.first(where: { $0.id == skill.id })
        case .configured(let id):
            return model.settings.skills.first(where: { $0.id == id })
        }
    }

    private static func matchingServerIndex(
        for entry: MCPCatalogEntry,
        in servers: [MCPServerConfig]
    ) -> Int? {
        servers.firstIndex { $0.command == entry.command && $0.arguments == entry.arguments }
    }
}
