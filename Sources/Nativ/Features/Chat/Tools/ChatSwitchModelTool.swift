import Foundation
import NativServerKit

enum ChatSwitchModelToolRegistry {
    static let toolName = "switch_model"

    static func definitions() -> [MLXChatToolDefinition] {
        [MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName,
            description: "Switch the active local language model. Requires user confirmation before it runs.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "model_id": .object([
                        "type": .string("string"),
                        "description": .string("Exact model identifier to switch to, e.g. mlx-community/Qwen3-1.7B-4bit")
                    ])
                ]),
                "required": .array([.string("model_id")])
            ])
        ))]
    }
}

struct ChatSwitchModelToolArguments: Decodable {
    let modelID: String

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
    }
}

struct ChatSwitchModelToolResultPayload: Encodable {
    let ok: Bool
    let previousModelID: String?
    let newModelID: String?
    let changed: Bool?
    let declined: Bool?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case previousModelID = "previous_model_id"
        case newModelID = "new_model_id"
        case changed
        case declined
        case error
    }
}

enum ChatSwitchModelToolError: LocalizedError {
    case invalidArguments
    case timedOut
    case switchFailed
    case mismatchedModel(requested: String, active: String?)
    case appModelUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "The switch_model arguments were not valid JSON."
        case .timedOut:
            return "The model switch did not finish in time."
        case .switchFailed:
            return "The server failed to start with the requested model."
        case .mismatchedModel(let requested, let active):
            return "Requested \(requested) but the active model is now \(active ?? "unknown")."
        case .appModelUnavailable:
            return "The app isn't ready to switch models right now."
        }
    }
}

@MainActor
protocol ChatModelSwitchingSurface {
    var settings: NativSettings { get }
    var modelSwitchInProgress: Bool { get }
    var isRunning: Bool { get }
    func switchLanguageModel(to modelID: String?)
}

struct ChatSwitchModelToolExecutor {
    @MainActor
    func execute(call: MLXChatToolCall, appModel: some ChatModelSwitchingSurface) async throws -> String {
        guard call.function?.name == ChatSwitchModelToolRegistry.toolName else {
            throw ChatImageToolError.unsupportedTool(call.function?.name ?? "unknown")
        }
        guard let argumentsData = call.function?.arguments?.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(ChatSwitchModelToolArguments.self, from: argumentsData)
        else {
            throw ChatSwitchModelToolError.invalidArguments
        }

        let requestedModelID = arguments.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousModelID = appModel.settings.normalized().languageModelID
        if previousModelID == requestedModelID {
            return try encodedPayload(ChatSwitchModelToolResultPayload(
                ok: true,
                previousModelID: previousModelID,
                newModelID: requestedModelID,
                changed: false,
                declined: false,
                error: nil
            ))
        }

        appModel.switchLanguageModel(to: requestedModelID)

        let deadline = Date().addingTimeInterval(60)
        while appModel.modelSwitchInProgress, Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard !appModel.modelSwitchInProgress else {
            throw ChatSwitchModelToolError.timedOut
        }
        guard appModel.isRunning else {
            throw ChatSwitchModelToolError.switchFailed
        }

        let activeModelID = appModel.settings.normalized().languageModelID
        guard activeModelID == requestedModelID else {
            throw ChatSwitchModelToolError.mismatchedModel(
                requested: requestedModelID,
                active: activeModelID
            )
        }

        return try encodedPayload(ChatSwitchModelToolResultPayload(
            ok: true,
            previousModelID: previousModelID,
            newModelID: activeModelID,
            changed: true,
            declined: false,
            error: nil
        ))
    }

    func declinedPayload() -> String {
        (try? encodedPayload(ChatSwitchModelToolResultPayload(
            ok: false,
            previousModelID: nil,
            newModelID: nil,
            changed: nil,
            declined: true,
            error: "The user declined this model switch."
        ))) ?? #"{"ok":false,"declined":true,"error":"The user declined this model switch."}"#
    }

    func failurePayload(operation: String, error: Error) -> String {
        let payload = ChatSwitchModelToolResultPayload(
            ok: false,
            previousModelID: nil,
            newModelID: nil,
            changed: nil,
            declined: false,
            error: error.localizedDescription
        )
        return (try? encodedPayload(payload))
            ?? #"{"ok":false,"error":"Model switch failed."}"#
    }

    private func encodedPayload(_ payload: ChatSwitchModelToolResultPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}
