import Foundation

/// Which tool calls stop and ask before they run.
///
/// MCP tools are matched on their name prefix rather than on whether the host
/// can currently route them. Connections reload asynchronously and debounced,
/// so a name the host cannot route when the gate runs may well be routable by
/// the time the call is dispatched — matching on the name alone closes that
/// window, and keeps an unrecognized or misconfigured server gated rather than
/// letting it through ungated.
enum ChatToolConsentRequirement: Equatable {
    case notRequired
    case switchModel
    case mcpTool(qualifiedName: String)

    static func resolve(toolName: String?) -> ChatToolConsentRequirement {
        guard let toolName else { return .notRequired }
        if toolName == ChatSwitchModelToolRegistry.toolName {
            return .switchModel
        }
        if toolName.hasPrefix(MCPHostManager.toolNamePrefix) {
            return .mcpTool(qualifiedName: toolName)
        }
        return .notRequired
    }

    var isRequired: Bool {
        self != .notRequired
    }

    /// What the model is told when the user declines.
    func declinedPayload() -> String {
        switch self {
        case .switchModel:
            return ChatSwitchModelToolExecutor().declinedPayload()
        case .mcpTool, .notRequired:
            return "The user declined to run this tool."
        }
    }
}

/// Splits a qualified MCP tool name for display.
enum MCPToolDisplayName {
    /// Best-effort split of `mcp__<server>__<tool>` for the consent prompt.
    ///
    /// Splits on the *last* separator: a server slug can contain one, since
    /// every non-alphanumeric character becomes an underscore and two adjacent
    /// ones produce `__`, while MCP tool names conventionally do not. Returns
    /// `nil` rather than guessing when the name is not shaped as expected, so
    /// callers can fall back to showing it verbatim.
    static func split(_ qualifiedName: String) -> (server: String, tool: String)? {
        guard qualifiedName.hasPrefix(MCPHostManager.toolNamePrefix) else { return nil }
        let body = String(qualifiedName.dropFirst(MCPHostManager.toolNamePrefix.count))
        guard let separator = body.range(of: MCPHostManager.toolNameSeparator, options: .backwards) else {
            return nil
        }
        let server = String(body[body.startIndex..<separator.lowerBound])
        let tool = String(body[separator.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server: server, tool: tool)
    }
}
