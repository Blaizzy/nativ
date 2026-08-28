import Foundation

/// A capability included in a Kit definition.
enum NativKitComponent: Equatable, Identifiable, Sendable {
    case mcpServer(catalogID: String)
    case skill(NativSkill)
    case extensionPackage(id: String)

    var id: String {
        switch self {
        case .mcpServer(let catalogID):
            "mcp:\(catalogID)"
        case .skill(let skill):
            "skill:\(skill.id.uuidString)"
        case .extensionPackage(let id):
            "extension:\(id)"
        }
    }
}

/// A ready-made, additive bundle of capabilities for a role or workflow.
struct NativKit: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
    let symbol: String
    let tintName: String
    let components: [NativKitComponent]

    var mcpServerIDs: [String] {
        components.compactMap { component in
            guard case .mcpServer(let catalogID) = component else { return nil }
            return catalogID
        }
    }

    var skills: [NativSkill] {
        components.compactMap { component in
            guard case .skill(let skill) = component else { return nil }
            return skill
        }
    }

    var extensionIDs: [String] {
        components.compactMap { component in
            guard case .extensionPackage(let id) = component else { return nil }
            return id
        }
    }

    /// Catalog MCP entries this Kit references, in definition order.
    func mcpEntries(in catalog: MCPServerCatalog) -> [MCPCatalogEntry] {
        mcpServerIDs.compactMap(catalog.entry(id:))
    }

    /// A one-line inventory of the components in this Kit definition.
    var inventory: String {
        var parts: [String] = []
        let serverCount = mcpServerIDs.count
        if serverCount > 0 {
            parts.append("\(serverCount) MCP server\(serverCount == 1 ? "" : "s")")
        }
        if !skills.isEmpty {
            parts.append("\(skills.count) skill\(skills.count == 1 ? "" : "s")")
        }
        if !extensionIDs.isEmpty {
            parts.append("\(extensionIDs.count) extension\(extensionIDs.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    /// Names the capabilities supplied by this Kit in definition order.
    func capabilityNames(in catalog: MCPServerCatalog) -> [String] {
        components.map { component in
            switch component {
            case .mcpServer(let catalogID):
                catalog.entry(id: catalogID)?.name ?? catalogID
            case .skill(let skill):
                skill.name
            case .extensionPackage(let id):
                id
            }
        }
    }
}

enum NativKitCatalogError: Error, Equatable {
    case duplicateKitIdentifier(String)
    case duplicateComponent(kitID: String, componentID: String)
    case conflictingSkillIdentifier(UUID)
    case unknownMCPServer(kitID: String, catalogID: String)
}

/// An immutable, validated collection of Kit definitions.
struct NativKitCatalog: Sendable {
    static let bundled: NativKitCatalog = {
        do {
            return try NativKitCatalog(
                kits: NativKit.bundledDefinitions,
                mcpCatalog: .bundled
            )
        } catch {
            preconditionFailure("Invalid bundled Kit catalog: \(error)")
        }
    }()

    let kits: [NativKit]
    private let kitsByID: [String: NativKit]

    init(kits: [NativKit], mcpCatalog: MCPServerCatalog) throws {
        var kitsByID: [String: NativKit] = [:]
        var skillsByID: [UUID: NativSkill] = [:]

        for kit in kits {
            guard kitsByID.updateValue(kit, forKey: kit.id) == nil else {
                throw NativKitCatalogError.duplicateKitIdentifier(kit.id)
            }

            var componentIDs = Set<String>()
            for component in kit.components {
                guard componentIDs.insert(component.id).inserted else {
                    throw NativKitCatalogError.duplicateComponent(
                        kitID: kit.id,
                        componentID: component.id
                    )
                }

                switch component {
                case .mcpServer(let catalogID):
                    guard mcpCatalog.entry(id: catalogID) != nil else {
                        throw NativKitCatalogError.unknownMCPServer(
                            kitID: kit.id,
                            catalogID: catalogID
                        )
                    }
                case .skill(let skill):
                    if let existing = skillsByID[skill.id], existing != skill {
                        throw NativKitCatalogError.conflictingSkillIdentifier(skill.id)
                    }
                    skillsByID[skill.id] = skill
                case .extensionPackage:
                    break
                }
            }
        }

        self.kits = kits
        self.kitsByID = kitsByID
    }

    func kit(id: String) -> NativKit? {
        kitsByID[id]
    }
}

private extension NativSkill {
    /// Creates a built-in Kit skill with a stable identity.
    static func kit(_ identifier: String, _ name: String, _ instructions: String) -> NativSkill {
        guard let id = UUID(uuidString: identifier) else {
            preconditionFailure("Invalid built-in Kit skill identifier: \(identifier)")
        }
        return NativSkill(id: id, name: name, instructions: instructions, isEnabled: true)
    }
}

private extension NativKit {
    /// Built-in examples that ship in Nativ's Kit catalog.
    static let bundledDefinitions: [NativKit] = [
        NativKit(
            id: "engineering",
            name: "Engineering",
            summary: "Read code, work with Git and GitHub, and pull in docs while you build.",
            symbol: "chevron.left.forwardslash.chevron.right",
            tintName: "indigo",
            components: [
                .mcpServer(catalogID: "git"),
                .mcpServer(catalogID: "github"),
                .mcpServer(catalogID: "filesystem"),
                .mcpServer(catalogID: "fetch"),
                .skill(
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
            ]
        ),
        NativKit(
            id: "research",
            name: "Research",
            summary: "Gather sources from the web, keep notes, and query your own data.",
            symbol: "magnifyingglass",
            tintName: "purple",
            components: [
                .mcpServer(catalogID: "fetch"),
                .mcpServer(catalogID: "memory"),
                .mcpServer(catalogID: "sqlite"),
                .skill(
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
            ]
        ),
    ]
}

// MARK: - Activation

/// How much of a Kit is currently active, derived from its live components.
enum NativKitState: Equatable {
    case off
    case partial
    case enabled
}

struct NativKitActivationSnapshot: Equatable {
    let state: NativKitState
    let inactivePartNames: [String]
}

/// Additively enables Kit components and derives status from their live state.
@MainActor
enum NativKitActivation {
    /// Enables every missing component without disabling or taking ownership of shared components.
    static func enableMissing(
        in kit: NativKit,
        model: NativModel,
        mcpCatalog: MCPServerCatalog = .bundled,
        isExtensionEnabled: (String) -> Bool,
        enableExtension: (String) -> Void
    ) {
        var settings = model.settings
        let extensionIDs = enableMissing(in: kit, settings: &settings, mcpCatalog: mcpCatalog)
        if settings != model.settings {
            model.settings = settings
        }

        for extensionID in extensionIDs where !isExtensionEnabled(extensionID) {
            enableExtension(extensionID)
        }
    }

    /// Enables settings-backed components and returns extension identifiers to enable.
    @discardableResult
    static func enableMissing(
        in kit: NativKit,
        settings: inout NativSettings,
        mcpCatalog: MCPServerCatalog
    ) -> [String] {
        for catalogID in kit.mcpServerIDs {
            guard let entry = mcpCatalog.entry(id: catalogID) else { continue }
            mcpCatalog.setEnabled(true, for: entry, in: &settings.mcpServers)
        }

        for skill in kit.skills {
            if let index = settings.skills.firstIndex(where: { $0.id == skill.id }) {
                settings.skills[index].isEnabled = true
            } else {
                settings.skills.append(skill)
            }
        }

        return kit.extensionIDs
    }

    static func state(
        of kit: NativKit,
        model: NativModel,
        mcpCatalog: MCPServerCatalog = .bundled,
        isExtensionEnabled: (String) -> Bool
    ) -> NativKitState {
        snapshot(
            of: kit,
            settings: model.settings,
            extensionName: { $0 },
            isExtensionEnabled: isExtensionEnabled,
            mcpCatalog: mcpCatalog
        ).state
    }

    static func state(
        of kit: NativKit,
        settings: NativSettings,
        isExtensionEnabled: (String) -> Bool,
        mcpCatalog: MCPServerCatalog
    ) -> NativKitState {
        snapshot(
            of: kit,
            settings: settings,
            extensionName: { $0 },
            isExtensionEnabled: isExtensionEnabled,
            mcpCatalog: mcpCatalog
        ).state
    }

    static func snapshot(
        of kit: NativKit,
        model: NativModel,
        mcpCatalog: MCPServerCatalog = .bundled,
        extensionName: (String) -> String,
        isExtensionEnabled: (String) -> Bool
    ) -> NativKitActivationSnapshot {
        snapshot(
            of: kit,
            settings: model.settings,
            extensionName: extensionName,
            isExtensionEnabled: isExtensionEnabled,
            mcpCatalog: mcpCatalog
        )
    }

    static func snapshot(
        of kit: NativKit,
        settings: NativSettings,
        extensionName: (String) -> String,
        isExtensionEnabled: (String) -> Bool,
        mcpCatalog: MCPServerCatalog
    ) -> NativKitActivationSnapshot {
        let inactivePartNames = kit.components.compactMap { component in
            switch component {
            case .mcpServer(let catalogID):
                guard let entry = mcpCatalog.entry(id: catalogID) else { return catalogID }
                return mcpCatalog.isEnabled(entry, in: settings.mcpServers) ? nil : entry.name
            case .skill(let skill):
                let isEnabled = settings.skills.first(where: { $0.id == skill.id })?.isEnabled == true
                return isEnabled ? nil : skill.name
            case .extensionPackage(let id):
                return isExtensionEnabled(id) ? nil : extensionName(id)
            }
        }
        let state: NativKitState
        if kit.components.isEmpty {
            state = .off
        } else if inactivePartNames.isEmpty {
            state = .enabled
        } else if inactivePartNames.count == kit.components.count {
            state = .off
        } else {
            state = .partial
        }
        return NativKitActivationSnapshot(
            state: state,
            inactivePartNames: inactivePartNames
        )
    }
}
