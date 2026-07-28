import AppKit
import Foundation
import NativServerKit

enum ChatImageToolRegistry {
    static func definitions(canEdit: Bool) -> [MLXChatToolDefinition] {
        var tools = [tool(
            name: "generate_image",
            description: "Create one or more new images from a detailed text prompt."
        )]
        if canEdit {
            tools.append(tool(
                name: "edit_image",
                description: "Edit the most recently attached or generated image using a text instruction."
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
    let error: String?
}

struct ChatImageToolExecution {
    let content: String
    let attachments: [ChatImageAttachment]
}

enum ChatImageToolError: LocalizedError {
    case unsupportedTool(String)
    case invalidArguments
    case emptyPrompt
    case missingReference

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
        }
    }
}

struct ChatImageToolExecutor {
    func execute(
        call: MLXChatToolCall,
        modelID: String,
        baseURL: URL,
        apiKey: String?,
        references: [ChatImageAttachment]
    ) async throws -> ChatImageToolExecution {
        guard let name = call.function?.name else {
            throw ChatImageToolError.unsupportedTool("unknown")
        }
        guard name == "generate_image" || name == "edit_image" else {
            throw ChatImageToolError.unsupportedTool(name)
        }
        guard let arguments = call.function?.arguments?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ChatImageToolArguments.self, from: arguments)
        else {
            throw ChatImageToolError.invalidArguments
        }

        let prompt = decoded.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw ChatImageToolError.emptyPrompt
        }
        if name == "edit_image", references.isEmpty {
            throw ChatImageToolError.missingReference
        }

        let sourceSize = name == "edit_image" ? imageSize(for: references.first) : nil
        let settings = ImageRequestSettings(
            count: min(max(decoded.count ?? 1, 1), 4),
            width: boundedDimension(decoded.width ?? sourceSize?.width ?? 512),
            height: boundedDimension(decoded.height ?? sourceSize?.height ?? 512),
            steps: 4,
            guidance: 1,
            seedText: decoded.seed.map(String.init) ?? ""
        )
        let outputs = try await ImageGenerationExecutor().run(
            baseURL: baseURL,
            apiKey: apiKey,
            modelID: modelID,
            prompt: prompt,
            references: name == "edit_image" ? references : [],
            settings: settings,
            seed: decoded.seed
        )
        let attachments = outputs.map(\.attachment)
        let payload = ChatImageToolResultPayload(
            ok: true,
            operation: name == "edit_image" ? "edit" : "generate",
            images: outputs.map {
                ChatImageToolResultPayload.Image(
                    attachmentID: $0.id.uuidString,
                    width: $0.width,
                    height: $0.height,
                    seed: $0.seed
                )
            },
            error: nil
        )
        return ChatImageToolExecution(
            content: try encodedPayload(payload),
            attachments: attachments
        )
    }

    func failurePayload(operation: String, error: Error) -> String {
        let payload = ChatImageToolResultPayload(
            ok: false,
            operation: operation,
            images: nil,
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
