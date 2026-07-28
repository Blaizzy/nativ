import Foundation
import NativServerKit

struct ChatToolExecutionContext {
    let imageGenerationModelID: String?
    let baseURL: URL
    let apiKey: String?
    let imageReferences: [ChatImageAttachment]
    let modelSearchPath: String
    let additionalModelSearchPaths: [String]
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
    static func execute(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        switch call.function?.name {
        case "generate_image", "edit_image":
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
        case ChatSystemMonitorToolRegistry.toolName:
            let content = try await ChatSystemMonitorToolExecutor().execute(call: call)
            return ChatToolExecutionOutcome(content: content, attachments: [])
        case ChatModelLibraryToolRegistry.toolName:
            let content = try await ChatModelLibraryToolExecutor().execute(call: call, context: context)
            return ChatToolExecutionOutcome(content: content, attachments: [])
        case ChatServerStatsToolRegistry.toolName:
            let content = try ChatServerStatsToolExecutor().execute(call: call)
            return ChatToolExecutionOutcome(content: content, attachments: [])
        default:
            throw ChatImageToolError.unsupportedTool(call.function?.name ?? "unknown")
        }
    }

    static func failurePayload(toolName: String?, error: Error) -> String {
        switch toolName {
        case "generate_image", "edit_image":
            return ChatImageToolExecutor().failurePayload(operation: toolName ?? "image", error: error)
        case ChatSystemMonitorToolRegistry.toolName:
            return ChatSystemMonitorToolExecutor().failurePayload(
                operation: toolName ?? ChatSystemMonitorToolRegistry.toolName,
                error: error
            )
        case ChatModelLibraryToolRegistry.toolName:
            return ChatModelLibraryToolExecutor().failurePayload(
                operation: toolName ?? ChatModelLibraryToolRegistry.toolName,
                error: error
            )
        case ChatServerStatsToolRegistry.toolName:
            return ChatServerStatsToolExecutor().failurePayload(
                operation: toolName ?? ChatServerStatsToolRegistry.toolName,
                error: error
            )
        case ChatSwitchModelToolRegistry.toolName:
            return ChatSwitchModelToolExecutor().failurePayload(
                operation: toolName ?? ChatSwitchModelToolRegistry.toolName,
                error: error
            )
        default:
            return ChatImageToolExecutor().failurePayload(operation: toolName ?? "tool", error: error)
        }
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
