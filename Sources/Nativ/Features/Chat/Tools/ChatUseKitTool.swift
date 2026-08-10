import Foundation
import NativServerKit

struct ChatKitDescriptor: Equatable {
    let id: String
    let name: String
    let summary: String
}

enum ChatUseKitToolRegistry {
    static let toolName = "use_kit"

    static func definitions(kits: [ChatKitDescriptor]) -> [MLXChatToolDefinition] {
        guard !kits.isEmpty else { return [] }
        let choices = kits.map { "\($0.id) (\($0.name)): \($0.summary)" }.joined(separator: "; ")
        return [MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName,
            description: "Enable one of the user's saved Kits. Use this only when the user explicitly asks to use or enable a Kit. Available Kits: \(choices). The app asks for confirmation before changing anything.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "kit_id": .object([
                        "type": .string("string"),
                        "enum": .array(kits.map { .string($0.id) }),
                        "description": .string("Identifier of the Kit to enable.")
                    ])
                ]),
                "required": .array([.string("kit_id")])
            ])
        ))]
    }
}

struct ChatUseKitToolArguments: Decodable {
    let kitID: String

    enum CodingKeys: String, CodingKey {
        case kitID = "kit_id"
    }
}

struct ChatUseKitToolResultPayload: Encodable {
    let ok: Bool
    let kitID: String?
    let kitName: String?
    let extensionsEnabled: Int?
    let mcpServersEnabled: Int?
    let toolsEnabled: Int?
    let skillsEnabled: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case kitID = "kit_id"
        case kitName = "kit_name"
        case extensionsEnabled = "extensions_enabled"
        case mcpServersEnabled = "mcp_servers_enabled"
        case toolsEnabled = "tools_enabled"
        case skillsEnabled = "skills_enabled"
        case error
    }
}

enum ChatUseKitToolError: LocalizedError {
    case invalidArguments
    case unknownKit(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "The use_kit arguments were not valid JSON."
        case .unknownKit(let id):
            "The Kit “\(id)” is not available."
        }
    }
}

struct ChatUseKitToolExecutor {
    func selectedKit(
        call: MLXChatToolCall,
        kits: [ChatKitDescriptor]
    ) throws -> ChatKitDescriptor {
        guard call.function?.name == ChatUseKitToolRegistry.toolName else {
            throw ChatImageToolError.unsupportedTool(call.function?.name ?? "unknown")
        }
        guard let argumentsData = call.function?.arguments?.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(ChatUseKitToolArguments.self, from: argumentsData),
              let kit = kits.first(where: { $0.id == arguments.kitID })
        else {
            if let arguments = call.function?.arguments,
               let data = arguments.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(ChatUseKitToolArguments.self, from: data) {
                throw ChatUseKitToolError.unknownKit(decoded.kitID)
            }
            throw ChatUseKitToolError.invalidArguments
        }

        return kit
    }

    func enabledPayload(
        kit: ChatKitDescriptor,
        extensionsEnabled: Int,
        mcpServersEnabled: Int,
        toolsEnabled: Int,
        skillsEnabled: Int
    ) throws -> String {
        try encodedPayload(ChatUseKitToolResultPayload(
            ok: true,
            kitID: kit.id,
            kitName: kit.name,
            extensionsEnabled: extensionsEnabled,
            mcpServersEnabled: mcpServersEnabled,
            toolsEnabled: toolsEnabled,
            skillsEnabled: skillsEnabled,
            error: nil
        ))
    }

    func declinedPayload() -> String {
        (try? encodedPayload(ChatUseKitToolResultPayload(
            ok: false,
            kitID: nil,
            kitName: nil,
            extensionsEnabled: nil,
            mcpServersEnabled: nil,
            toolsEnabled: nil,
            skillsEnabled: nil,
            error: "The user declined to enable this Kit."
        ))) ?? #"{"ok":false,"error":"The user declined to enable this Kit."}"#
    }

    func failurePayload(operation: String, error: Error) -> String {
        let payload = ChatUseKitToolResultPayload(
            ok: false,
            kitID: nil,
            kitName: nil,
            extensionsEnabled: nil,
            mcpServersEnabled: nil,
            toolsEnabled: nil,
            skillsEnabled: nil,
            error: error.localizedDescription
        )
        return (try? encodedPayload(payload))
            ?? #"{"ok":false,"error":"Kit activation failed."}"#
    }

    private func encodedPayload(_ payload: ChatUseKitToolResultPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}
