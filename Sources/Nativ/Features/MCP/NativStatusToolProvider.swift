import Foundation
import NativServerKit

struct NativStatusToolProvider: NativCapabilityProvider {
    static let toolName = "get_nativ_status"

    let model: NativModel

    func definitions(_ options: NativToolCatalogOptions) async -> [MLXChatToolDefinition] {
        [MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: Self.toolName,
            description: "Report whether Nativ's local model server is running, which model is loaded, and the base URL to send OpenAI-compatible requests to.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([:]),
            ])
        ))]
    }

    func handles(_ name: String) async -> Bool {
        name == Self.toolName
    }

    func requiresConsent(_ name: String) async -> Bool {
        false
    }

    func call(
        _ name: String,
        argumentsJSON: String?,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let payload = await Payload(
            ok: true,
            serverIsRunning: model.isRunning,
            baseURL: model.activeServerBaseURL?.absoluteString,
            loadedModel: model.settings.normalized().languageModelID,
            imageModel: model.settings.normalized().imageGenerationModelID,
            speechToTextModel: model.settings.normalized().speechToTextModelID
        )
        let data = try JSONEncoder().encode(payload)
        return ChatToolExecutionOutcome(
            content: String(decoding: data, as: UTF8.self),
            attachments: []
        )
    }

    private struct Payload: Encodable {
        let ok: Bool
        let serverIsRunning: Bool
        let baseURL: String?
        let loadedModel: String?
        let imageModel: String?
        let speechToTextModel: String?

        enum CodingKeys: String, CodingKey {
            case ok
            case serverIsRunning = "server_is_running"
            case baseURL = "base_url"
            case loadedModel = "loaded_model"
            case imageModel = "image_model"
            case speechToTextModel = "speech_to_text_model"
        }
    }
}
