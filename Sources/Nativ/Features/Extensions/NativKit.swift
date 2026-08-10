import Foundation

enum NativKitMCPServer: Equatable, Sendable {
    case catalog(String)
    case configured(UUID)
}

struct NativKitMCPTool: Codable, Equatable, Hashable, Sendable {
    let serverID: UUID
    let name: String
}

enum NativKitSkillReference: Equatable, Sendable {
    case builtIn(NativSkill)
    case configured(UUID)
}

struct UserNativKit: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var summary: String
    var mcpServerIDs: [UUID]
    var mcpTools: [NativKitMCPTool]
    var builtInToolNames: [String]
    var customToolIDs: [UUID]
    var skillIDs: [UUID]
    var extensionIDs: [String]

    init(
        id: UUID = UUID(),
        name: String = "",
        summary: String = "",
        mcpServerIDs: [UUID] = [],
        mcpTools: [NativKitMCPTool] = [],
        builtInToolNames: [String] = [],
        customToolIDs: [UUID] = [],
        skillIDs: [UUID] = [],
        extensionIDs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.mcpServerIDs = mcpServerIDs
        self.mcpTools = mcpTools
        self.builtInToolNames = builtInToolNames
        self.customToolIDs = customToolIDs
        self.skillIDs = skillIDs
        self.extensionIDs = extensionIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, mcpServerIDs, mcpTools, builtInToolNames
        case customToolIDs, skillIDs, extensionIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        mcpServerIDs = try container.decodeIfPresent([UUID].self, forKey: .mcpServerIDs) ?? []
        mcpTools = try container.decodeIfPresent([NativKitMCPTool].self, forKey: .mcpTools) ?? []
        builtInToolNames = try container.decodeIfPresent([String].self, forKey: .builtInToolNames) ?? []
        customToolIDs = try container.decodeIfPresent([UUID].self, forKey: .customToolIDs) ?? []
        skillIDs = try container.decodeIfPresent([UUID].self, forKey: .skillIDs) ?? []
        extensionIDs = try container.decodeIfPresent([String].self, forKey: .extensionIDs) ?? []
    }

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!mcpServerIDs.isEmpty
                || !mcpTools.isEmpty
                || !builtInToolNames.isEmpty
                || !customToolIDs.isEmpty
                || !skillIDs.isEmpty
                || !extensionIDs.isEmpty)
    }

    func normalized() -> UserNativKit {
        var kit = self
        kit.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        kit.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        kit.mcpTools = mcpTools.uniqued()
        kit.mcpServerIDs = (mcpServerIDs + kit.mcpTools.map(\.serverID)).uniqued()
        kit.builtInToolNames = builtInToolNames.uniqued()
        kit.customToolIDs = customToolIDs.uniqued()
        kit.skillIDs = skillIDs.uniqued()
        kit.extensionIDs = extensionIDs.uniqued()
        return kit
    }

    func resolved() -> NativKit {
        let normalized = normalized()
        return NativKit(
            id: normalized.id.uuidString,
            name: normalized.name,
            summary: normalized.summary,
            isBuiltIn: false,
            mcpServers: normalized.mcpServerIDs.map(NativKitMCPServer.configured),
            mcpTools: normalized.mcpTools,
            builtInToolNames: normalized.builtInToolNames,
            customToolIDs: normalized.customToolIDs,
            skills: normalized.skillIDs.map(NativKitSkillReference.configured),
            extensionIDs: normalized.extensionIDs
        )
    }
}

struct NativKit: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    let isBuiltIn: Bool
    let mcpServers: [NativKitMCPServer]
    let mcpTools: [NativKitMCPTool]
    let builtInToolNames: [String]
    let customToolIDs: [UUID]
    let skills: [NativKitSkillReference]
    let extensionIDs: [String]

    var inventory: String {
        var parts: [String] = []
        if !extensionIDs.isEmpty {
            parts.append(Self.count(extensionIDs.count, singular: "extension"))
        }
        if !mcpServers.isEmpty {
            parts.append(Self.count(mcpServers.count, singular: "MCP server"))
        }
        let toolCount = mcpTools.count + builtInToolNames.count + customToolIDs.count
        if toolCount > 0 {
            parts.append(Self.count(toolCount, singular: "tool"))
        }
        if !skills.isEmpty {
            parts.append(Self.count(skills.count, singular: "skill"))
        }
        return parts.joined(separator: " · ")
    }

    private static func count(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }
}

private extension NativSkill {
    static func kit(_ uuid: String, _ name: String, _ instructions: String) -> NativSkill {
        NativSkill(
            id: UUID(uuidString: uuid)!,
            name: name,
            instructions: instructions,
            isEnabled: true
        )
    }
}

extension NativKit {
    static let builtIns: [NativKit] = [engineering, research]

    private static let engineering = NativKit(
        id: "engineering",
        name: "Engineering",
        summary: "Read code, work with Git and GitHub, and pull in docs while you build.",
        isBuiltIn: true,
        mcpServers: ["git", "github", "filesystem", "fetch"].map(NativKitMCPServer.catalog),
        mcpTools: [],
        builtInToolNames: [],
        customToolIDs: [],
        skills: [
            .builtIn(.kit(
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
            )),
        ],
        extensionIDs: []
    )

    private static let research = NativKit(
        id: "research",
        name: "Research",
        summary: "Gather sources from the web, keep notes, and query your own data.",
        isBuiltIn: true,
        mcpServers: ["fetch", "memory", "sqlite"].map(NativKitMCPServer.catalog),
        mcpTools: [],
        builtInToolNames: [],
        customToolIDs: [],
        skills: [
            .builtIn(.kit(
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
            )),
        ],
        extensionIDs: []
    )
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
