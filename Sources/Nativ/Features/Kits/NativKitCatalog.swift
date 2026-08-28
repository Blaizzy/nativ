import Foundation

struct NativKitBuiltInSkill: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let instructions: String

    var skill: NativSkill {
        NativSkill(
            id: Self.stableUUID(for: id),
            name: name,
            instructions: instructions,
            isEnabled: true
        )
    }

    private static func stableUUID(for id: String) -> UUID {
        switch id {
        case "working-in-codebase":
            UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!
        case "researching-with-sources":
            UUID(uuidString: "A2000000-0000-4000-8000-000000000002")!
        default:
            preconditionFailure("Missing stable UUID for built-in skill \(id)")
        }
    }
}

enum CustomNativKitCatalog {
    static let builtInSkills: [NativKitBuiltInSkill] = [
        NativKitBuiltInSkill(
            id: "working-in-codebase",
            name: "Working in a codebase",
            instructions: """
            You're helping with software. Ground every answer in the actual repository, not assumptions.

            - Use Git and filesystem tools to read real files, history, and diffs before proposing changes.
            - Prefer read-only GitHub queries and summarize concrete findings.
            - Match the project's existing style and keep changes focused.
            - Fetch documentation when an API or library detail is uncertain.
            """
        ),
        NativKitBuiltInSkill(
            id: "researching-with-sources",
            name: "Researching with sources",
            instructions: """
            You're doing careful research. Prioritize accuracy and traceability.

            - Read primary sources and connect claims to where they came from.
            - Record durable findings before repeating work.
            - Query the user's data instead of estimating.
            - Separate sourced facts from inference and flag uncertainty.
            """
        ),
    ]

    static let builtInKits: [CustomNativKit] = [
        CustomNativKit(
            id: "engineering",
            name: "Engineering",
            summary: "A focused set of code, Git, and documentation capabilities.",
            isEnabled: true,
            origin: .builtIn,
            contents: NativKitContents(
                mcpSelections: ["git", "github", "filesystem", "fetch"].map {
                    NativKitMCPSelection(server: .catalog($0), tools: .all)
                },
                skillReferences: [.builtIn("working-in-codebase")]
            )
        ),
        CustomNativKit(
            id: "research",
            name: "Research",
            summary: "Sources, durable notes, and structured data for careful research.",
            isEnabled: true,
            origin: .builtIn,
            contents: NativKitContents(
                mcpSelections: ["fetch", "memory", "sqlite"].map {
                    NativKitMCPSelection(server: .catalog($0), tools: .all)
                },
                skillReferences: [.builtIn("researching-with-sources")]
            )
        ),
    ]

    static func builtInSkill(id: String) -> NativKitBuiltInSkill? {
        builtInSkills.first { $0.id == id }
    }
}
