import Foundation
import NativServerKit

struct ChatToolExecutionContext {
    let imageGenerationModelID: String?
    let baseURL: URL
    let apiKey: String?
    let imageReferences: [ChatImageAttachment]
    let modelSearchPath: String
    let additionalModelSearchPaths: [String]
    var analyticsDatabaseURL: URL? = nil
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

enum ChatToolRegistry {
    static func definitions(
        context: ChatToolExecutionContext,
        canEditImage: Bool
    ) -> [MLXChatToolDefinition] {
        var tools: [MLXChatToolDefinition] = []
        if context.imageGenerationModelID?.isEmpty == false {
            tools.append(contentsOf: ChatImageToolRegistry.definitions(canEdit: canEditImage))
        }
        tools.append(contentsOf: ChatSystemMonitorToolRegistry.definitions())
        tools.append(contentsOf: ChatModelLibraryToolRegistry.definitions())
        tools.append(contentsOf: ChatServerStatsToolRegistry.definitions())
        tools.append(contentsOf: ChatSwitchModelToolRegistry.definitions())
        return tools
    }
}

enum ChatToolDispatcher {
    private typealias Handler = (MLXChatToolCall, ChatToolExecutionContext) async throws -> ChatToolExecutionOutcome
    private typealias FailureHandler = (String, Error) -> String

    private static let handlers: [String: Handler] = [
        "generate_image": executeImageTool,
        "edit_image": executeImageTool,
        ChatSystemMonitorToolRegistry.toolName: executeSystemMonitorTool,
        ChatModelLibraryToolRegistry.toolName: executeModelLibraryTool,
        ChatServerStatsToolRegistry.toolName: executeServerStatsTool,
    ]

    private static let failureHandlers: [String: FailureHandler] = [
        "generate_image": failurePayloadForImageTool,
        "edit_image": failurePayloadForImageTool,
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
        guard let imageModelID = context.imageGenerationModelID else {
            throw ChatImageToolError.unsupportedTool(call.function?.name ?? "image")
        }
        let result = try await ChatImageToolExecutor().execute(
            call: call,
            modelID: imageModelID,
            baseURL: context.baseURL,
            apiKey: context.apiKey,
            references: context.imageReferences
        )
        return ChatToolExecutionOutcome(content: result.content, attachments: result.attachments)
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
        case "generate_image":
            return imageTitle(isEdit: false, status: status)
        case "edit_image":
            return imageTitle(isEdit: true, status: status)
        case ChatSystemMonitorToolRegistry.toolName:
            return systemMonitorTitle(status: status)
        case ChatModelLibraryToolRegistry.toolName:
            return modelLibraryTitle(status: status)
        case ChatServerStatsToolRegistry.toolName:
            return serverStatsTitle(status: status)
        case ChatSwitchModelToolRegistry.toolName:
            return switchModelTitle(status: status)
        default:
            return genericTitle(toolName: toolName, status: status)
        }
    }

    static func symbolName(toolName: String?, status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .failed:
            return "exclamationmark.triangle.fill"
        case .cancelled, .declined:
            return "xmark.circle"
        case .awaitingConsent:
            return "questionmark.circle"
        case .succeeded, .running, nil:
            switch toolName {
            case "generate_image", "edit_image":
                return "photo"
            case ChatSystemMonitorToolRegistry.toolName:
                return "cpu"
            case ChatModelLibraryToolRegistry.toolName:
                return "shippingbox"
            case ChatServerStatsToolRegistry.toolName:
                return "chart.line.uptrend.xyaxis"
            case ChatSwitchModelToolRegistry.toolName:
                return "arrow.triangle.2.circlepath"
            default:
                return "wrench.and.screwdriver"
            }
        }
    }

    private static func imageTitle(isEdit: Bool, status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
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
        case .running:
            return "Checking system stats…"
        case .succeeded:
            return "Checked system stats"
        case .failed, .cancelled, .awaitingConsent, .declined:
            return "System stats"
        case nil:
            return "System tool"
        }
    }

    private static func modelLibraryTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .running:
            return "Listing downloaded models…"
        case .succeeded:
            return "Listed downloaded models"
        case .failed, .cancelled, .awaitingConsent, .declined:
            return "Model library"
        case nil:
            return "Model library tool"
        }
    }

    private static func serverStatsTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .running:
            return "Checking server stats…"
        case .succeeded:
            return "Checked server stats"
        case .failed, .cancelled, .awaitingConsent, .declined:
            return "Server stats"
        case nil:
            return "Server stats tool"
        }
    }

    private static func switchModelTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .awaitingConsent:
            return "Switch model?"
        case .running:
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

    private static func genericTitle(toolName: String?, status: ChatTranscriptMessage.ToolStatus?) -> String {
        let name = toolName ?? "tool"
        switch status {
        case .running:
            return "Running \(name)…"
        case .succeeded:
            return "Ran \(name)"
        case .failed, .cancelled, .awaitingConsent, .declined, nil:
            return name
        }
    }
}
