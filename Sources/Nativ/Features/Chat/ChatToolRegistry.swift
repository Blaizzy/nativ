import Foundation
import NativServerKit

typealias ChatImageModelSelectionHandler = @MainActor @Sendable (
    ChatImageModelSelectionRequest
) async throws -> String

struct ChatToolExecutionContext {
    let imageGenerationModelID: String?
    let baseURL: URL
    let apiKey: String?
    let imageReferences: [ChatImageAttachment]
    let modelSearchPath: String
    let additionalModelSearchPaths: [String]
    var huggingFaceToken: String? = nil
    var analyticsDatabaseURL: URL? = nil
    var imageToolDependencies = ChatImageToolDependencies.live
    var imageModelSelection: ChatImageModelSelectionHandler? = nil
    var imageExecutionWillStart: (@MainActor @Sendable (String) -> Void)? = nil
}

struct ChatToolExecutionOutcome {
    let content: String
    let attachments: [ChatImageAttachment]
}

enum ChatToolRoundGate {
    static let maximumRounds = 4

    static func advertisesTools(atRound round: Int) -> Bool {
        round < maximumRounds
    }
}

enum ChatNativeToolConfiguration: Equatable {
    case webSearch

    var displayName: String {
        switch self {
        case .webSearch:
            "Web Search"
        }
    }
}

struct ChatNativeToolDescriptor {
    let definition: MLXChatToolDefinition
    let configuration: ChatNativeToolConfiguration?
}

enum ChatToolRegistry {
    static func definitions(canEditImage: Bool) -> [MLXChatToolDefinition] {
        descriptors(canEditImage: canEditImage).map(\.definition)
    }

    static func descriptors(canEditImage: Bool) -> [ChatNativeToolDescriptor] {
        var definitions = ChatImageToolRegistry.definitions(canEdit: canEditImage)
        definitions += ChatSystemMonitorToolRegistry.definitions()
        definitions += ChatModelLibraryToolRegistry.definitions()
        definitions += ChatServerStatsToolRegistry.definitions()
        definitions += ChatSwitchModelToolRegistry.definitions()
        var tools = definitions.map {
            ChatNativeToolDescriptor(definition: $0, configuration: nil)
        }
        tools.append(ChatNativeToolDescriptor(
            definition: ChatWebSearchToolRegistry.definition,
            configuration: .webSearch
        ))
        return tools
    }
}

enum ChatToolDispatcher {
    private typealias Handler = (MLXChatToolCall, ChatToolExecutionContext) async throws -> ChatToolExecutionOutcome
    private typealias FailureHandler = (String, Error) -> String

    private static let handlers: [String: Handler] = [
        ChatImageToolRegistry.generateToolName: executeImageTool,
        ChatImageToolRegistry.editToolName: executeImageTool,
        ChatSystemMonitorToolRegistry.toolName: executeSystemMonitorTool,
        ChatModelLibraryToolRegistry.toolName: executeModelLibraryTool,
        ChatServerStatsToolRegistry.toolName: executeServerStatsTool,
        ChatWebSearchToolRegistry.toolName: executeWebSearchTool,
    ]

    private static let failureHandlers: [String: FailureHandler] = [
        ChatImageToolRegistry.generateToolName: failurePayloadForImageTool,
        ChatImageToolRegistry.editToolName: failurePayloadForImageTool,
        ChatSystemMonitorToolRegistry.toolName: { name, error in
            ChatSystemMonitorToolExecutor().failurePayload(operation: name, error: error)
        },
        ChatModelLibraryToolRegistry.toolName: { name, error in
            ChatModelLibraryToolExecutor().failurePayload(operation: name, error: error)
        },
        ChatServerStatsToolRegistry.toolName: { name, error in
            ChatServerStatsToolExecutor().failurePayload(operation: name, error: error)
        },
        ChatSwitchModelToolRegistry.toolName: { name, error in
            ChatSwitchModelToolExecutor().failurePayload(operation: name, error: error)
        },
        ChatWebSearchToolRegistry.toolName: { _, error in
            ChatWebSearchToolExecutor().failurePayload(error: error)
        },
    ]

    static func execute(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        guard let name = call.function?.name, let handler = handlers[name] else {
            throw ChatImageToolError.unsupportedTool(call.function?.name ?? "unknown")
        }
        return try await handler(call, context)
    }

    static func failurePayload(toolName: String?, error: Error) -> String {
        guard let toolName, let handler = failureHandlers[toolName] else {
            return ChatImageToolExecutor().failurePayload(operation: toolName ?? "tool", error: error)
        }
        return handler(toolName, error)
    }

    private static func executeImageTool(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let imageRequest = try ChatImageToolRequest(
            call: call,
            hasImageReference: !context.imageReferences.isEmpty
        )
        let availableModels = try await context.imageToolDependencies.discoverModels(
            imageRequest.operation,
            context.modelSearchPath,
            context.additionalModelSearchPaths,
            context.huggingFaceToken,
            context.imageGenerationModelID
        )
        let imageModelID: String
        switch ChatImageModelSelection.resolve(
            operation: imageRequest.operation,
            selectedModelID: context.imageGenerationModelID,
            availableModels: availableModels
        ) {
        case .selected(let model):
            imageModelID = model.modelID
        case .selectionRequired(let selectionRequest):
            guard let requestSelection = context.imageModelSelection else {
                throw selectionRequest.models.isEmpty
                    ? ChatImageToolError.noCompatibleModels(imageRequest.operation)
                    : ChatImageToolError.modelSelectionUnavailable(imageRequest.operation)
            }
            let selectedModelID = try await requestSelection(selectionRequest)
            guard let selectedModel = ChatImageModelSelection.selectedModel(
                withID: selectedModelID,
                from: selectionRequest
            ) else {
                throw ChatImageToolError.modelSelectionUnavailable(imageRequest.operation)
            }
            imageModelID = selectedModel.modelID
        }
        await context.imageExecutionWillStart?(imageModelID)
        let result = try await context.imageToolDependencies.execute(
            imageRequest,
            imageModelID,
            context.baseURL,
            context.apiKey,
            context.imageReferences
        )
        return ChatToolExecutionOutcome(
            content: result.content,
            attachments: result.attachments
        )
    }

    private static func executeSystemMonitorTool(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let content = try await ChatSystemMonitorToolExecutor().execute(call: call)
        return ChatToolExecutionOutcome(content: content, attachments: [])
    }

    private static func executeModelLibraryTool(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let content = try await ChatModelLibraryToolExecutor().execute(call: call, context: context)
        return ChatToolExecutionOutcome(content: content, attachments: [])
    }

    private static func executeServerStatsTool(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let content = try ChatServerStatsToolExecutor().execute(call: call, context: context)
        return ChatToolExecutionOutcome(content: content, attachments: [])
    }

    private static func executeWebSearchTool(
        call: MLXChatToolCall,
        context _: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let content = try await ChatWebSearchToolExecutor().execute(call: call)
        return ChatToolExecutionOutcome(content: content, attachments: [])
    }

    private static func failurePayloadForImageTool(name: String, error: Error) -> String {
        ChatImageToolExecutor().failurePayload(operation: name, error: error)
    }
}

@MainActor
final class ChatToolConsentGate {
    private var pending: [UUID: CheckedContinuation<Bool, Never>] = [:]

    var pendingCount: Int {
        pending.count
    }

    func confirm(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(returning: true)
    }

    func deny(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(returning: false)
    }

    func awaitDecision(for id: UUID) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                pending[id] = continuation
                if Task.isCancelled {
                    pending.removeValue(forKey: id)?.resume(returning: false)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.pending.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }
}

enum ChatToolConsentOutcome: Equatable {
    case cancelled
    case declined
    case approved
}

enum ChatToolConsentRouter {
    static func outcome(approved: Bool, isCancelled: Bool) -> ChatToolConsentOutcome {
        if isCancelled {
            return .cancelled
        }
        return approved ? .approved : .declined
    }
}

enum ChatToolPresentation {
    static func title(toolName: String?, status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch toolName {
        case ChatImageToolRegistry.generateToolName:
            return imageTitle(isEdit: false, status: status)
        case ChatImageToolRegistry.editToolName:
            return imageTitle(isEdit: true, status: status)
        case ChatSystemMonitorToolRegistry.toolName:
            return systemMonitorTitle(status: status)
        case ChatModelLibraryToolRegistry.toolName:
            return modelLibraryTitle(status: status)
        case ChatServerStatsToolRegistry.toolName:
            return serverStatsTitle(status: status)
        case ChatSwitchModelToolRegistry.toolName:
            return switchModelTitle(status: status)
        case ChatWebSearchToolRegistry.toolName:
            return webSearchTitle(status: status)
        default:
            return genericTitle(toolName: toolName, status: status)
        }
    }

    static func symbolName(toolName: String?, status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .preparing:
            return "magnifyingglass"
        case .awaitingImageModelSelection:
            return "photo.badge.checkmark"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .cancelled, .declined:
            return "xmark.circle"
        case .awaitingConsent:
            return "questionmark.circle"
        case .succeeded, .running, nil:
            switch toolName {
            case ChatImageToolRegistry.generateToolName,
                 ChatImageToolRegistry.editToolName:
                return "photo"
            case ChatSystemMonitorToolRegistry.toolName:
                return "cpu"
            case ChatModelLibraryToolRegistry.toolName:
                return "shippingbox"
            case ChatServerStatsToolRegistry.toolName:
                return "chart.line.uptrend.xyaxis"
            case ChatSwitchModelToolRegistry.toolName:
                return "arrow.triangle.2.circlepath"
            case ChatWebSearchToolRegistry.toolName:
                return "globe"
            default:
                return "wrench.and.screwdriver"
            }
        }
    }

    private static func imageTitle(isEdit: Bool, status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .preparing:
            return "Checking image model…"
        case .awaitingImageModelSelection:
            return "Choose image model"
        case .running:
            return isEdit ? "Editing image…" : "Generating image…"
        case .succeeded:
            return isEdit ? "Edited image" : "Generated image"
        case .failed, .cancelled, .awaitingConsent, .declined:
            return isEdit ? "Image edit" : "Image generation"
        case nil:
            return "Image tool"
        }
    }

    private static func systemMonitorTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .preparing, .running:
            return "Checking system stats…"
        case .succeeded:
            return "Checked system stats"
        case .failed, .cancelled, .awaitingConsent, .awaitingImageModelSelection, .declined:
            return "System stats"
        case nil:
            return "System tool"
        }
    }

    private static func modelLibraryTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .preparing, .running:
            return "Listing downloaded models…"
        case .succeeded:
            return "Listed downloaded models"
        case .failed, .cancelled, .awaitingConsent, .awaitingImageModelSelection, .declined:
            return "Model library"
        case nil:
            return "Model library tool"
        }
    }

    private static func serverStatsTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .preparing, .running:
            return "Checking server stats…"
        case .succeeded:
            return "Checked server stats"
        case .failed, .cancelled, .awaitingConsent, .awaitingImageModelSelection, .declined:
            return "Server stats"
        case nil:
            return "Server stats tool"
        }
    }

    private static func switchModelTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .awaitingConsent:
            return "Switch model?"
        case .awaitingImageModelSelection:
            return "Model switch"
        case .preparing, .running:
            return "Switching model…"
        case .succeeded:
            return "Switched model"
        case .declined:
            return "Model switch declined"
        case .failed, .cancelled:
            return "Model switch"
        case nil:
            return "Model switch tool"
        }
    }

    private static func webSearchTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .preparing, .running:
            return "Searching the web…"
        case .succeeded:
            return "Searched the web"
        case .failed, .cancelled, .awaitingConsent, .awaitingImageModelSelection, .declined:
            return "Web search"
        case nil:
            return "Web search"
        }
    }

    private static func genericTitle(toolName: String?, status: ChatTranscriptMessage.ToolStatus?) -> String {
        let name = toolName ?? "tool"
        switch status {
        case .preparing, .running:
            return "Running \(name)…"
        case .succeeded:
            return "Ran \(name)"
        case .failed, .cancelled, .awaitingConsent, .awaitingImageModelSelection, .declined, nil:
            return name
        }
    }
}
