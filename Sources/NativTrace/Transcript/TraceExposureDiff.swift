import Foundation

/// What changed in the model's exposure between one call and the call before it.
///
/// The round gate withholds tools on the last round, MCP servers connect and
/// drop, and a skill can be toggled mid-session — so two calls in one turn can
/// show the model different things. That difference is invisible unless
/// something computes it.
public struct TraceExposureDiff: Sendable, Hashable {
    public let addedTools: [ToolDescriptor]
    public let removedTools: [ToolDescriptor]
    /// Same name, different schema or origin — a silently swapped tool.
    public let redefinedTools: [ToolDescriptor]
    public let addedSections: [PromptSection]
    public let removedSections: [PromptSection]
    public let editedSections: [PromptSection]

    public static let none = TraceExposureDiff(
        addedTools: [], removedTools: [], redefinedTools: [],
        addedSections: [], removedSections: [], editedSections: []
    )

    public var isEmpty: Bool {
        addedTools.isEmpty && removedTools.isEmpty && redefinedTools.isEmpty
            && addedSections.isEmpty && removedSections.isEmpty && editedSections.isEmpty
    }

    /// `nil` previous means this is the first call, which is not a change.
    public static func between(
        _ previous: RequestComposedPayload?,
        and current: RequestComposedPayload
    ) -> TraceExposureDiff {
        guard let previous else { return .none }

        let previousTools = Dictionary(previous.tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let currentTools = Dictionary(current.tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        let added = current.tools.filter { previousTools[$0.name] == nil }
        let removed = previous.tools.filter { currentTools[$0.name] == nil }
        let redefined = current.tools.filter { tool in
            guard let before = previousTools[tool.name] else { return false }
            return before.fingerprint != tool.fingerprint
        }

        let previousSections = Dictionary(
            previous.systemSections.map { (sectionKey($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentSections = Dictionary(
            current.systemSections.map { (sectionKey($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return TraceExposureDiff(
            addedTools: added,
            removedTools: removed,
            redefinedTools: redefined,
            addedSections: current.systemSections.filter { previousSections[sectionKey($0)] == nil },
            removedSections: previous.systemSections.filter { currentSections[sectionKey($0)] == nil },
            editedSections: current.systemSections.filter { section in
                guard let before = previousSections[sectionKey(section)] else { return false }
                return before.body != section.body
            }
        )
    }

    /// Sections are matched on origin and label, so re-ordering the prompt does
    /// not read as an edit.
    private static func sectionKey(_ section: PromptSection) -> String {
        "\(section.origin.rawValue)|\(section.label)"
    }
}
