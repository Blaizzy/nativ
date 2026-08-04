import Foundation

struct NativSkill: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var instructions: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        instructions: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.isEnabled = isEnabled
    }
}

extension NativSkill {
    /// Stable identity for the hard-built-in tool-use skill (non-deletable).
    static let builtInToolGuideID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    /// A single built-in skill that teaches the model how to use Nativ's tools.
    /// Shown at the top of Skills (non-deletable) and injected into the system
    /// prompt whenever tools are available.
    static let builtInToolGuide = NativSkill(
        id: builtInToolGuideID,
        name: "Using Nativ Tools",
        instructions: """
        You have access to tools provided by connected MCP servers and Nativ's \
        built-in capabilities. Use them to give accurate, grounded answers \
        instead of guessing.

        - Reach for a tool whenever it can retrieve facts, files, code, or live \
        data — or perform an action — that you can't reliably answer from memory.
        - Read each tool's name and description, pick the most specific one, and \
        pass complete, valid JSON arguments that match its schema.
        - Chain tools when a task needs several steps: use each result to decide \
        the next call, and stop once you can fully answer.
        - Ground your reply in the results — reference concrete values (paths, \
        numbers, names) rather than restating the call.
        - Prefer read-only tools. Only use tools that create, modify, or delete \
        when the user clearly asked for it, and confirm before anything \
        destructive or irreversible.
        - If a tool fails or returns nothing useful, say so briefly and either \
        try another approach or answer from what you know. Never invent tool \
        output.
        - Don't call a tool when you can already answer correctly and directly.
        """,
        isEnabled: true
    )
}
