import NativServerKit
import SwiftUI

// A Kit is a ready-made setup: a curated bundle of MCP servers, their tools,
// skills, and extensions for a role or use-case. Enabling one fans out across
// all four primitives at once; each part stays individually manageable after.

struct NativKit: Identifiable {
    let id: String
    let name: String
    let summary: String
    let symbol: String
    let tint: Color
    let mcpServerIDs: [String]
    let extensionIDs: [String]
    let skills: [NativSkill]

    /// Catalog MCP entries this kit references, in listed order.
    var mcpEntries: [MCPCatalogEntry] {
        mcpServerIDs.compactMap { id in MCPCatalogEntry.catalog.first { $0.id == id } }
    }

    /// A one-line inventory of what the kit turns on.
    var inventory: String {
        var parts: [String] = []
        let servers = mcpEntries.count
        if servers > 0 { parts.append("\(servers) MCP server\(servers == 1 ? "" : "s")") }
        if !skills.isEmpty { parts.append("\(skills.count) skill\(skills.count == 1 ? "" : "s")") }
        if !extensionIDs.isEmpty { parts.append("\(extensionIDs.count) extension\(extensionIDs.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

private extension NativSkill {
    /// A kit skill with a stable identity so enabling a kit twice never duplicates it.
    static func kit(_ uuid: String, _ name: String, _ instructions: String) -> NativSkill {
        NativSkill(id: UUID(uuidString: uuid)!, name: name, instructions: instructions, isEnabled: true)
    }
}

extension NativKit {
    /// The curated kits shown at the top of the Extensions hub.
    static let all: [NativKit] = [
        NativKit(
            id: "engineering",
            name: "Engineering",
            summary: "Read code, work with Git and GitHub, and pull in docs while you build.",
            symbol: "chevron.left.forwardslash.chevron.right",
            tint: .indigo,
            mcpServerIDs: ["git", "github", "filesystem", "fetch"],
            extensionIDs: [],
            skills: [
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
            ]
        ),
        NativKit(
            id: "research",
            name: "Research",
            summary: "Gather sources from the web, keep notes, and query your own data.",
            symbol: "magnifyingglass",
            tint: .purple,
            mcpServerIDs: ["fetch", "memory", "sqlite"],
            extensionIDs: [],
            skills: [
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
            ]
        ),
        NativKit(
            id: "sales",
            name: "Sales",
            summary: "Research accounts, remember context, draft outreach, and dictate notes.",
            symbol: "chart.line.uptrend.xyaxis",
            tint: .blue,
            mcpServerIDs: ["fetch", "memory"],
            extensionIDs: ["com.nativ.voice-dictation"],
            skills: [
                .kit(
                    "A3000000-0000-4000-8000-000000000003",
                    "Sales outreach",
                    """
                    You're helping with sales. Be specific, concise, and grounded in \
                    what you can actually learn about the account.

                    - Use the fetch tool to research a company or contact before writing; \
                    reference concrete, current details.
                    - Keep account context in the memory tool so follow-ups stay \
                    consistent across the relationship.
                    - Draft outreach that is short, personalized, and value-first — no \
                    filler, no invented facts about the prospect.
                    - When the user dictates notes, capture the substance faithfully \
                    and offer clear next steps.
                    """
                )
            ]
        ),
        NativKit(
            id: "operations",
            name: "Operations",
            summary: "Work with files and structured data, and keep an operational memory.",
            symbol: "checklist",
            tint: .teal,
            mcpServerIDs: ["filesystem", "sqlite", "memory"],
            extensionIDs: [],
            skills: [
                .kit(
                    "A4000000-0000-4000-8000-000000000004",
                    "Operations and data hygiene",
                    """
                    You're helping run operations. Favor accuracy, repeatability, and \
                    clear audit trails.

                    - Use the filesystem and SQLite tools to read the real data before \
                    summarizing or changing anything.
                    - Prefer read-only queries; confirm explicitly before any write, \
                    delete, or bulk change.
                    - Record recurring facts, definitions, and process notes in the \
                    memory tool so they persist.
                    - Report numbers exactly as the data shows them and note any gaps \
                    or inconsistencies you find.
                    """
                )
            ]
        )
    ]
}

// MARK: - Activation

/// How much of a kit is currently switched on, derived from its live pieces.
enum NativKitState: Equatable {
    case off
    case partial
    case enabled
}

/// Turns a kit's MCP servers, skills, and extensions on or off together, driving
/// the same settings the individual sections do. Enabling appends any missing
/// pieces; disabling switches them off without deleting the user's edits.
@MainActor
enum NativKitActivation {
    static func setEnabled(
        _ enabled: Bool,
        kit: NativKit,
        model: NativModel,
        manager: NativExtensionManager
    ) {
        for entry in kit.mcpEntries {
            if let index = matchingServerIndex(for: entry, in: model.settings.mcpServers) {
                model.settings.mcpServers[index].isEnabled = enabled
            } else if enabled {
                model.settings.mcpServers.append(entry.makeConfig())
            }
        }

        for skill in kit.skills {
            if let index = model.settings.skills.firstIndex(where: { $0.id == skill.id }) {
                model.settings.skills[index].isEnabled = enabled
            } else if enabled {
                model.settings.skills.append(skill)
            }
        }

        for extensionID in kit.extensionIDs {
            manager.setEnabled(enabled, extensionID: extensionID)
        }
    }

    /// The kit's activation derived from the actual state of its pieces: enabled
    /// when every piece is on, partial when some are, off when none — so the UI
    /// can't drift out of sync with the individual switches.
    static func state(of kit: NativKit, model: NativModel, manager: NativExtensionManager) -> NativKitState {
        var total = 0
        var active = 0

        for entry in kit.mcpEntries {
            total += 1
            if isServerEnabled(entry, in: model) { active += 1 }
        }
        for skill in kit.skills {
            total += 1
            if model.settings.skills.first(where: { $0.id == skill.id })?.isEnabled == true { active += 1 }
        }
        for extensionID in kit.extensionIDs {
            total += 1
            if manager.isEnabled(extensionID: extensionID) { active += 1 }
        }

        guard total > 0, active > 0 else { return .off }
        return active == total ? .enabled : .partial
    }

    /// Matches a catalog entry to a configured server by launch identity
    /// (command + arguments), so a kit never toggles an unrelated server that
    /// merely shares a name.
    private static func matchingServerIndex(
        for entry: MCPCatalogEntry,
        in servers: [MCPServerConfig]
    ) -> Int? {
        servers.firstIndex { $0.command == entry.command && $0.arguments == entry.arguments }
    }

    private static func isServerEnabled(_ entry: MCPCatalogEntry, in model: NativModel) -> Bool {
        guard let index = matchingServerIndex(for: entry, in: model.settings.mcpServers) else { return false }
        return model.settings.mcpServers[index].isEnabled
    }
}
