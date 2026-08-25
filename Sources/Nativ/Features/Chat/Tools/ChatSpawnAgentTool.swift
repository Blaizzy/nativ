import Foundation
import NativServerKit

enum ChatSpawnAgentToolRegistry {
    static let toolName = "spawn_agent"

    static func definitions() -> [MLXChatToolDefinition] {
        [MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName,
            description: "Delegate a sub-task to a separate, independent agent.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "task": .object([
                        "type": .string("string"),
                        "description": .string("The sub-agent's instruction.")
                    ]),
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("fresh"), .string("branch")]),
                        "description": .string(
                            "'fresh' (default): starts with just the task. 'branch': clones this conversation's history first, then adds the task."
                        )
                    ]),
                    "context": .object([
                        "type": .string("string"),
                        "description": .string("Facts the sub-agent needs, without full history. Ignored in 'branch' mode.")
                    ]),
                    "model": .object([
                        "type": .string("string"),
                        "description": .string("A downloaded model ID, e.g. 'mlx-community/Qwen3-4B-4bit'. Omit to use the current model.")
                    ])
                ]),
                "required": .array([.string("task")])
            ])
        ))]
    }
}

enum ChatSpawnAgentMode: String, Decodable {
    case fresh
    case branch
}

struct ChatSpawnAgentToolArguments: Decodable {
    let task: String
    let mode: ChatSpawnAgentMode
    let context: String?
    let modelID: String?

    enum CodingKeys: String, CodingKey {
        case task
        case mode
        case context
        case modelID = "model"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        task = try container.decode(String.self, forKey: .task)
        mode = try container.decodeIfPresent(ChatSpawnAgentMode.self, forKey: .mode) ?? .fresh
        context = try container.decodeIfPresent(String.self, forKey: .context)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
    }
}

struct ChatSpawnAgentToolResultPayload: Encodable {
    let ok: Bool
    let answer: String?
    let error: String?
}

enum ChatSpawnAgentToolError: LocalizedError {
    case invalidArguments
    case emptyTask
    case modelUnavailable(modelID: String?)
    case modelKindNotSupported(modelID: String)
    case noParentHistory

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "The spawn_agent arguments were not valid JSON."
        case .emptyTask:
            return "spawn_agent requires a non-empty task."
        case .modelUnavailable(let modelID):
            if let modelID {
                return "\(modelID) isn't a downloaded model."
            }
            return "No language model is available to run the sub-agent."
        case .modelKindNotSupported(let modelID):
            return "\(modelID) doesn't support text generation, so it can't run as a spawn_agent sub-agent yet."
        case .noParentHistory:
            return "No conversation history is available to branch from."
        }
    }
}

enum ChatSpawnAgentModelKind: Equatable {
    case textGeneration
    case unsupported

    static func resolve(_ model: LocalModel) -> ChatSpawnAgentModelKind {
        model.isEligibleForLanguageModelPicker ? .textGeneration : .unsupported
    }
}

enum ChatSpawnAgentModelResolver {
    static func resolve(
        requestedModelID: String?,
        fallbackModelID: String?,
        searchPaths: LocalModelSearchPaths
    ) async throws -> String {
        guard let requestedModelID, !requestedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard let fallbackModelID else {
                throw ChatSpawnAgentToolError.modelUnavailable(modelID: nil)
            }
            return fallbackModelID
        }

        let models = try await LocalModelDiscovery.scan(searchPaths: searchPaths)
        guard let model = models.first(where: { $0.repoID == requestedModelID }) else {
            throw ChatSpawnAgentToolError.modelUnavailable(modelID: requestedModelID)
        }
        guard ChatSpawnAgentModelKind.resolve(model) == .textGeneration else {
            throw ChatSpawnAgentToolError.modelKindNotSupported(modelID: requestedModelID)
        }
        return requestedModelID
    }
}

enum ChatSpawnAgentTranscriptBuilder {
    static func initialMessages(
        arguments: ChatSpawnAgentToolArguments,
        parentMessages: [ChatTranscriptMessage]
    ) throws -> [MLXChatMessage] {
        switch arguments.mode {
        case .fresh:
            let content = arguments.context.map { "Context:\n\($0)\n\nTask:\n\(arguments.task)" }
                ?? arguments.task
            return [MLXChatMessage(role: "user", content: content)]
        case .branch:
            guard !parentMessages.isEmpty else {
                throw ChatSpawnAgentToolError.noParentHistory
            }
            var cloned = parentMessages.compactMap { $0.apiMessage }
            cloned.append(MLXChatMessage(role: "user", content: arguments.task))
            return cloned
        }
    }
}

struct ChatSpawnAgentToolExecutor {
    func execute(call: MLXChatToolCall, context: ChatToolExecutionContext) async throws -> String {
        guard call.function?.name == ChatSpawnAgentToolRegistry.toolName else {
            throw ChatImageToolError.unsupportedTool(call.function?.name ?? "unknown")
        }
        guard let argumentsData = call.function?.arguments?.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(ChatSpawnAgentToolArguments.self, from: argumentsData)
        else {
            throw ChatSpawnAgentToolError.invalidArguments
        }
        guard !arguments.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatSpawnAgentToolError.emptyTask
        }
        guard let settings = context.settings else {
            throw ChatSpawnAgentToolError.modelUnavailable(modelID: nil)
        }

        let modelID = try await ChatSpawnAgentModelResolver.resolve(
            requestedModelID: arguments.modelID,
            fallbackModelID: settings.languageModelID,
            searchPaths: LocalModelSearchPaths(
                primary: context.modelSearchPath,
                additional: context.additionalModelSearchPaths
            )
        )
        let messages = try ChatSpawnAgentTranscriptBuilder.initialMessages(
            arguments: arguments,
            parentMessages: context.spawnAgentParentMessages
        )
        let parentImages = context.spawnAgentParentMessages.reversed().lazy
            .map { $0.imageAttachments.filter { $0.chatAttachmentKind == .image } }
            .first { !$0.isEmpty } ?? []

        var subAgentContext = ChatToolExecutionContext(
            imageGenerationModelID: context.imageGenerationModelID,
            baseURL: context.baseURL,
            apiKey: context.apiKey,
            imageReferences: parentImages,
            modelSearchPath: context.modelSearchPath,
            additionalModelSearchPaths: context.additionalModelSearchPaths,
            huggingFaceToken: context.huggingFaceToken,
            mcpHost: context.mcpHost
        )
        subAgentContext.fileReadRootPath = context.fileReadRootPath
        subAgentContext.fileReadTracker = context.fileReadTracker
        subAgentContext.fileReadMaximumResultCharacters = context.fileReadMaximumResultCharacters
        subAgentContext.fileReadToolDependencies = context.fileReadToolDependencies

        let completion = try await ChatAgentLoop.run(
            messages: messages,
            modelID: modelID,
            settings: settings,
            canEditImage: !parentImages.isEmpty,
            context: subAgentContext
        )

        return try encodedPayload(ChatSpawnAgentToolResultPayload(
            ok: true,
            answer: completion.content,
            error: nil
        ))
    }

    func failurePayload(error: Error) -> String {
        let payload = ChatSpawnAgentToolResultPayload(
            ok: false,
            answer: nil,
            error: error.localizedDescription
        )
        return (try? encodedPayload(payload))
            ?? #"{"ok":false,"error":"spawn_agent failed."}"#
    }

    private func encodedPayload(_ payload: ChatSpawnAgentToolResultPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}
