import AppKit
import Foundation
import NativServerKit

enum ChatImageToolRegistry {
    static let generateToolName = "generate_image"
    static let editToolName = "edit_image"

    static func definitions(canEdit: Bool) -> [MLXChatToolDefinition] {
        var tools = [tool(
            name: generateToolName,
            description: "Create one or more new images from a detailed text prompt. Image-model selection is handled by the app; do not ask for or provide a model identifier."
        )]
        if canEdit {
            tools.append(tool(
                name: editToolName,
                description: "Edit the most recently attached or generated image using a text instruction. Image-model selection is handled by the app; do not ask for or provide a model identifier."
            ))
        }
        return tools
    }

    private static func tool(name: String, description: String) -> MLXChatToolDefinition {
        MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: name,
            description: description,
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "prompt": .object([
                        "type": .string("string"),
                        "description": .string("A specific visual description or edit instruction.")
                    ]),
                    "width": .object([
                        "type": .string("integer"),
                        "minimum": .number(256),
                        "maximum": .number(2048)
                    ]),
                    "height": .object([
                        "type": .string("integer"),
                        "minimum": .number(256),
                        "maximum": .number(2048)
                    ]),
                    "count": .object([
                        "type": .string("integer"),
                        "minimum": .number(1),
                        "maximum": .number(4)
                    ]),
                    "seed": .object([
                        "type": .array([.string("integer"), .string("null")])
                    ])
                ]),
                "required": .array([.string("prompt")])
            ])
        ))
    }
}

struct ChatImageToolArguments: Decodable {
    let prompt: String
    let width: Int?
    let height: Int?
    let count: Int?
    let seed: Int?

    static func decode(call: MLXChatToolCall) throws -> Self {
        guard let arguments = call.function?.arguments?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: arguments)
        else {
            throw ChatImageToolError.invalidArguments
        }
        return decoded
    }
}

struct ChatImageToolRequest: Equatable, Sendable {
    let operation: ChatImageOperation
    let prompt: String
    let width: Int?
    let height: Int?
    let count: Int?
    let seed: Int?

    init(call: MLXChatToolCall, hasImageReference: Bool) throws {
        operation = try ChatImageOperation(toolName: call.function?.name)
        let arguments = try ChatImageToolArguments.decode(call: call)
        let prompt = arguments.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw ChatImageToolError.emptyPrompt
        }
        guard operation != .edit || hasImageReference else {
            throw ChatImageToolError.missingReference
        }

        self.prompt = prompt
        width = arguments.width
        height = arguments.height
        count = arguments.count
        seed = arguments.seed
    }
}

struct ChatImageToolResultPayload: Encodable {
    struct Image: Encodable {
        let attachmentID: String
        let width: Int
        let height: Int
        let seed: Int

        enum CodingKeys: String, CodingKey {
            case attachmentID = "attachment_id"
            case width
            case height
            case seed
        }
    }

    let ok: Bool
    let operation: String
    let images: [Image]?
    let installationRequired: Bool?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case operation
        case images
        case installationRequired = "installation_required"
        case error
    }
}

struct ChatImageToolExecution: Sendable {
    let content: String
    let attachments: [ChatImageAttachment]
}

struct ChatImageToolDependencies: Sendable {
    typealias ModelDiscovery = @Sendable (
        ChatImageOperation,
        String,
        [String],
        String?,
        String?
    ) async throws -> [ChatImageModelOption]
    typealias Execution = @Sendable (
        ChatImageToolRequest,
        String,
        URL,
        String?,
        [ChatImageAttachment]
    ) async throws -> ChatImageToolExecution

    let discoverModels: ModelDiscovery
    let execute: Execution

    static let live = Self(
        discoverModels: { operation, path, additionalPaths, token, preferredModelID in
            try await ChatImageModelSelection.availableOptions(
                for: operation,
                modelSearchPath: path,
                additionalModelSearchPaths: additionalPaths,
                huggingFaceToken: token,
                preferredInstalledModelID: preferredModelID
            )
        },
        execute: { request, modelID, baseURL, apiKey, references in
            try await ChatImageToolExecutor().execute(
                request: request,
                modelID: modelID,
                baseURL: baseURL,
                apiKey: apiKey,
                references: references
            )
        }
    )
}

enum ChatImageToolError: LocalizedError {
    case unsupportedTool(String)
    case invalidArguments
    case emptyPrompt
    case missingReference
    case modelSelectionUnavailable(ChatImageOperation)
    case noCompatibleModels(ChatImageOperation)

    var errorDescription: String? {
        switch self {
        case .unsupportedTool(let name):
            "Unsupported image tool: \(name)"
        case .invalidArguments:
            "The image tool arguments were not valid JSON."
        case .emptyPrompt:
            "The image prompt cannot be empty."
        case .missingReference:
            "No earlier image is available to edit."
        case .modelSelectionUnavailable(let operation):
            "The app could not present the \(operation.capabilityName) model picker."
        case .noCompatibleModels(let operation):
            "No compatible \(operation.capabilityName) model is installed. Download one from the Models tab, then try again."
        }
    }
}

struct ChatImageToolExecutor {
    func execute(
        request: ChatImageToolRequest,
        modelID: String,
        baseURL: URL,
        apiKey: String?,
        references: [ChatImageAttachment]
    ) async throws -> ChatImageToolExecution {
        let sourceSize = request.operation == .edit
            ? imageSize(for: references.first)
            : nil
        let settings = ImageRequestSettings(
            count: min(max(request.count ?? 1, 1), 4),
            width: boundedDimension(request.width ?? sourceSize?.width ?? 512),
            height: boundedDimension(request.height ?? sourceSize?.height ?? 512),
            steps: 4,
            guidance: 1,
            seedText: request.seed.map(String.init) ?? ""
        )
        let outputs = try await ImageGenerationExecutor().run(
            baseURL: baseURL,
            apiKey: apiKey,
            modelID: modelID,
            prompt: request.prompt,
            references: request.operation == .edit ? references : [],
            supportsEditing: request.operation == .edit,
            settings: settings,
            seed: request.seed
        )
        let attachments = outputs.map(\.attachment)
        let payload = ChatImageToolResultPayload(
            ok: true,
            operation: request.operation.rawValue,
            images: outputs.map {
                ChatImageToolResultPayload.Image(
                    attachmentID: $0.id.uuidString,
                    width: $0.width,
                    height: $0.height,
                    seed: $0.seed
                )
            },
            installationRequired: nil,
            error: nil
        )
        return ChatImageToolExecution(
            content: try encodedPayload(payload),
            attachments: attachments
        )
    }

    func failurePayload(operation: String, error: Error) -> String {
        let installationRequired: Bool? = if case ChatImageToolError.noCompatibleModels = error {
            true
        } else {
            nil
        }
        let payload = ChatImageToolResultPayload(
            ok: false,
            operation: operation == ChatImageToolRegistry.editToolName ? "edit" : "generate",
            images: nil,
            installationRequired: installationRequired,
            error: error.localizedDescription
        )
        return (try? encodedPayload(payload))
            ?? #"{"ok":false,"error":"Image tool failed."}"#
    }

    private func boundedDimension(_ value: Int) -> Int {
        min(max((value / 16) * 16, 256), 2_048)
    }

    private func imageSize(for attachment: ChatImageAttachment?) -> ImageGenerationPixelSize? {
        guard let data = attachment?.imageData,
              let image = NSImage(data: data),
              image.size.width > 0,
              image.size.height > 0
        else {
            return nil
        }
        return ImageGenerationPixelSize(
            width: Int(image.size.width.rounded()),
            height: Int(image.size.height.rounded())
        )
    }

    private func encodedPayload(_ payload: ChatImageToolResultPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}
