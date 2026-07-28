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
