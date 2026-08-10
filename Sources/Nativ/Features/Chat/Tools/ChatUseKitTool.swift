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
            description: "Make an available Kit's capabilities ready for this chat. Use only when the user explicitly asks to use or enable a Kit. Available Kits: \(choices). Nativ asks for confirmation before changing anything.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "kit_id": .object([
                        "type": .string("string"),
                        "enum": .array(kits.map { .string($0.id) }),
                        "description": .string("Identifier of the Kit to make available.")
                    ])
                ]),
                "required": .array([.string("kit_id")])
            ])
        ))]
    }
}

private struct ChatUseKitToolArguments: Decodable {
    let kitID: String

    enum CodingKeys: String, CodingKey {
        case kitID = "kit_id"
    }
}

private struct ChatUseKitToolResultPayload: Encodable {
    let ok: Bool
    let kitID: String?
    let kitName: String?
    let componentsEnabled: Int?
    let unavailableComponents: [String]?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case kitID = "kit_id"
        case kitName = "kit_name"
        case componentsEnabled = "components_enabled"
        case unavailableComponents = "unavailable_components"
        case error
    }
}

enum ChatUseKitToolError: LocalizedError, Equatable {
    case invalidArguments
    case unknownKit(String)
    case activationUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "The use_kit arguments were not valid JSON."
        case .unknownKit(let id):
            "The Kit “\(id)” is no longer available."
        case .activationUnavailable:
            "Kit activation is unavailable in this chat."
        }
    }
}

struct ChatUseKitToolExecutor {
    func selectedKit(call: MLXChatToolCall, kits: [ChatKitDescriptor]) throws -> ChatKitDescriptor {
        guard call.function?.name == ChatUseKitToolRegistry.toolName else {
            throw ChatImageToolError.unsupportedTool(call.function?.name ?? "unknown")
        }
        guard let data = call.function?.arguments?.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(ChatUseKitToolArguments.self, from: data)
        else {
            throw ChatUseKitToolError.invalidArguments
        }
        guard let kit = kits.first(where: { $0.id == arguments.kitID }) else {
            throw ChatUseKitToolError.unknownKit(arguments.kitID)
        }
        return kit
    }

    func enabledPayload(
        kit: ChatKitDescriptor,
        componentsEnabled: Int,
        unavailableComponents: [String]
    ) -> String {
        encodedPayload(ChatUseKitToolResultPayload(
            ok: true,
            kitID: kit.id,
            kitName: kit.name,
            componentsEnabled: componentsEnabled,
            unavailableComponents: unavailableComponents.isEmpty
                ? nil
                : unavailableComponents,
            error: nil
        ))
    }

    func declinedPayload() -> String {
        encodedPayload(ChatUseKitToolResultPayload(
            ok: false,
            kitID: nil,
            kitName: nil,
            componentsEnabled: nil,
            unavailableComponents: nil,
            error: "The user declined to make this Kit available."
        ))
    }

    func failurePayload(operation: String, error: Error) -> String {
        encodedPayload(ChatUseKitToolResultPayload(
            ok: false,
            kitID: nil,
            kitName: nil,
            componentsEnabled: nil,
            unavailableComponents: nil,
            error: error.localizedDescription
        ))
    }

    private func encodedPayload(_ payload: ChatUseKitToolResultPayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else {
            return #"{"ok":false,"error":"Kit activation failed."}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
