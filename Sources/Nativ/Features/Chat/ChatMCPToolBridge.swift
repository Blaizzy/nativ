import Foundation
import NativServerKit

struct ChatMCPToolBridge {
    let manager: MCPServerManager

    @MainActor
    func definitions() -> [MLXChatToolDefinition] {
        manager.connections.flatMap { connection in
            connection.tools.map { tool in
                MLXChatToolDefinition(function: MLXChatFunctionDefinition(
                    name: MCPToolNameQualifier.qualify(server: connection.configuration.name, tool: tool.name),
                    description: tool.description,
                    parameters: tool.inputSchema
                ))
            }
        }
    }

    func canHandle(_ name: String) -> Bool {
        MCPToolNameQualifier.hasPrefix(name)
    }

    @MainActor
    func requiresConsent(_ qualifiedName: String) -> Bool {
        guard canHandle(qualifiedName) else {
            return false
        }
        guard let (serverName, toolName) = MCPToolNameQualifier.unqualify(qualifiedName),
              let connection = manager.connections.first(where: { $0.configuration.name == serverName })
        else {
            return true
        }
        return !connection.configuration.consentExemptTools.contains(toolName)
    }

    @MainActor
    func execute(call: MLXChatToolCall) async throws -> ChatToolExecutionOutcome {
        guard let qualifiedName = call.function?.name,
              let (serverName, toolName) = MCPToolNameQualifier.unqualify(qualifiedName)
        else {
            throw ChatImageToolError.unsupportedTool(call.function?.name ?? "unknown")
        }
        guard let connection = manager.connections.first(where: { $0.configuration.name == serverName }) else {
            throw ChatImageToolError.unsupportedTool(qualifiedName)
        }
        let resultText = try await connection.callTool(name: toolName, argumentsJSON: call.function?.arguments)
        return ChatToolExecutionOutcome(content: resultText, attachments: [])
    }

    static func declinedPayload(toolName: String) -> String {
        let payload = ChatMCPToolResultPayload(ok: false, declined: true, error: "The user declined this action.")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(decoding: encoder.encode(payload), as: UTF8.self))
            ?? #"{"ok":false,"declined":true,"error":"The user declined this action."}"#
    }

    static func failurePayload(toolName: String, error: Error) -> String {
        let payload = ChatMCPToolResultPayload(ok: false, declined: nil, error: error.localizedDescription)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(decoding: encoder.encode(payload), as: UTF8.self))
            ?? #"{"ok":false,"error":"MCP tool failed."}"#
    }
}

private struct ChatMCPToolResultPayload: Encodable {
    let ok: Bool
    let declined: Bool?
    let error: String?
}
