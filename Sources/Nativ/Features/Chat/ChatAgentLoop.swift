import Foundation
import NativServerKit

enum ChatAgentLoopError: LocalizedError {
    case timedOut
    case recursiveSpawnNotAllowed
    case unavailableTool(String)

    var errorDescription: String? {
        switch self {
        case .timedOut: "The sub-agent reached its time limit."
        case .recursiveSpawnNotAllowed: "A sub-agent can't spawn further sub-agents."
        case .unavailableTool(let name): "The tool \(name) is not available to this sub-agent. Ask the parent agent to perform actions requiring approval."
        }
    }
}

struct ChatAgentLoopResult: Sendable {
    let completion: MLXChatCompletion
    let stopReason: ChatSpawnedAgentStopReason?
}

@MainActor
enum ChatAgentLoop {
    static func withTimeout(
        seconds: TimeInterval,
        operation: @escaping @MainActor @Sendable () async throws -> ChatAgentLoopResult
    ) async throws -> ChatAgentLoopResult {
        try await withThrowingTaskGroup(of: ChatAgentLoopResult.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ChatAgentLoopError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    static func run(
        messages initialMessages: [MLXChatMessage],
        modelID: String,
        settings: NativSettings,
        canEditImage: Bool,
        context: ChatToolExecutionContext,
        agentID: String? = nil,
        limits: ChatSpawnAgentResourceLimits = .default,
        onUpdate: (@MainActor @Sendable ([ChatTranscriptMessage]) -> Void)? = nil,
        completionHandler: (@MainActor (MLXChatCompletionRequest) async throws -> MLXChatCompletion)? = nil
    ) async throws -> ChatAgentLoopResult {
        let client = NativChatClient(baseURL: context.baseURL, apiKey: context.apiKey)
        let toolDefinitions = subAgentToolDefinitions(settings: settings, canEditImage: canEditImage, context: context)
        let systemPrompt = context.subAgentSystemPrompt
            ?? subAgentSystemPrompt(settings: settings, hasTools: !toolDefinitions.isEmpty)
        let customTools = settings.customTools.filter { $0.kind != .script }
        let transcript = ChatAgentDisplayTranscript(onUpdate: onUpdate)
        let startedAt = Date()

        var messages = initialMessages
        if let systemPrompt {
            messages.insert(MLXChatMessage(role: "system", content: systemPrompt), at: 0)
        }

        var round = 0
        var totalTokensUsed = 0
        var lastCompletion: MLXChatCompletion?
        while true {
            try Task.checkCancellation()

            if let agentID, let steerMessages = context.agentRegistry?.drainSteerMessages(for: agentID),
               !steerMessages.isEmpty {
                for steerMessage in steerMessages {
                    messages.append(MLXChatMessage(role: "user", content: steerMessage))
                    transcript.appendSteerMessage(steerMessage)
                }
            }

            let stopReason: ChatSpawnedAgentStopReason? =
                if round >= limits.maxTurns { .turnLimit }
                else if totalTokensUsed >= limits.maxTokens { .tokenLimit }
                else if Date().timeIntervalSince(startedAt) >= limits.maxWallTimeSeconds { .timeout }
                else { nil }
            if let stopReason, let lastCompletion {
                return ChatAgentLoopResult(completion: lastCompletion, stopReason: stopReason)
            }
            let advertisesTools = !toolDefinitions.isEmpty

            let request = MLXChatCompletionRequest(
                model: modelID,
                messages: messages,
                maxTokens: min(settings.maxTokens, max(1, limits.maxTokens - totalTokensUsed)),
                temperature: settings.temperature,
                topK: settings.topK,
                topP: settings.topP,
                minP: settings.minP,
                repetitionPenalty: settings.repetitionPenaltyEnabled ? settings.repetitionPenalty : nil,
                enableThinking: settings.thinkingEnabled,
                thinkingBudget: settings.thinkingEnabled && settings.thinkingBudgetEnabled
                    && !settings.speculativeDecodingActive ? settings.thinkingBudget : nil,
                thinkingStartToken: settings.thinkingEnabled ? settings.thinkingStartToken : nil,
                thinkingEndToken: settings.thinkingEnabled ? settings.thinkingEndToken : nil,
                responseFormat: advertisesTools ? nil : settings.chatResponseFormat,
                tools: advertisesTools ? toolDefinitions : nil,
                toolChoice: advertisesTools ? "auto" : nil
            )

            let assistantDisplayID = transcript.appendAssistantPlaceholder()
            let completion: MLXChatCompletion
            if let completionHandler {
                completion = try await completionHandler(request)
            } else {
                let relay = ChatStreamEventRelay { event in
                    transcript.appendDelta(event, to: assistantDisplayID)
                }
                do {
                    completion = try await client.streamChat(request, onEvent: { event in
                        relay.submit(event)
                    })
                    relay.finish()
                } catch {
                    relay.cancel()
                    throw error
                }
            }
            try Task.checkCancellation()
            lastCompletion = completion
            transcript.finishAssistant(assistantDisplayID, completion: completion)
            totalTokensUsed += completion.usage?.totalTokens ?? 0

            if completion.finishReason == "length" {
                return ChatAgentLoopResult(completion: completion, stopReason: .tokenLimit)
            }
            let toolCalls = normalizedToolCalls(completion.toolCalls)
            guard advertisesTools, !toolCalls.isEmpty else {
                return ChatAgentLoopResult(completion: completion, stopReason: stopReason)
            }

            messages.append(MLXChatMessage(
                role: "assistant",
                content: completion.content,
                reasoningContent: completion.reasoningContent,
                toolCalls: toolCalls
            ))

            for toolCall in toolCalls {
                try Task.checkCancellation()
                let toolDisplayID = transcript.appendToolPlaceholder(for: toolCall)
                let (content, succeeded) = await executeToolCall(
                    toolCall,
                    customTools: customTools,
                    allowedToolNames: Set(toolDefinitions.map { $0.function.name }),
                    context: context
                )
                transcript.finishTool(toolDisplayID, content: content, succeeded: succeeded)
                messages.append(MLXChatMessage(
                    role: "tool",
                    content: content,
                    toolCallID: toolCall.id
                ))
            }

            round += 1
        }
    }

    static func executeToolCall(
        _ toolCall: MLXChatToolCall,
        customTools: [CustomTool],
        allowedToolNames: Set<String>,
        context: ChatToolExecutionContext
    ) async -> (content: String, succeeded: Bool) {
        let name = toolCall.function?.name
        if name == ChatSpawnAgentToolRegistry.toolName {
            return (ChatSpawnAgentToolExecutor().failurePayload(error: ChatAgentLoopError.recursiveSpawnNotAllowed), false)
        }
        guard let name, allowedToolNames.contains(name) else {
            return (ChatToolDispatcher.failurePayload(toolName: name,
                error: ChatAgentLoopError.unavailableTool(name ?? "unknown")), false)
        }
        do {
            if let customTool = customTools.first(where: { $0.toolName == name }) {
                let result = try await CustomToolExecutor.execute(customTool, argumentsJSON: toolCall.function?.arguments)
                return (result, true)
            }
            if let host = context.mcpHost, host.handlesTool(named: name) {
                return (try await host.callTool(named: name, argumentsJSON: toolCall.function?.arguments,
                                               projectScope: context.projectScope), true)
            }
            let outcome = try await ChatToolDispatcher.execute(call: toolCall, context: context)
            return (outcome.content, true)
        } catch {
            return (ChatToolDispatcher.failurePayload(toolName: name, error: error), false)
        }
    }

    static func subAgentToolDefinitions(
        settings: NativSettings,
        canEditImage: Bool,
        context: ChatToolExecutionContext
    ) -> [MLXChatToolDefinition] {
        var definitions = context.subAgentToolDefinitions ?? ChatToolRegistry.definitions(canEditImage: canEditImage)
        if context.subAgentToolDefinitions == nil {
            definitions += settings.customTools.filter { $0.kind != .script }.compactMap { try? $0.definition() }
            definitions += context.mcpHost?.toolDefinitions() ?? []
        }
        let webSearchIsConfigured = ChatWebSearchToolRegistry.isConfigured()
        let webReadIsConfigured = ChatWebReadToolRegistry.isConfigured()
        definitions.removeAll { definition in
            definition.function.name == ChatSwitchModelToolRegistry.toolName
                || definition.function.name == ChatSpawnAgentToolRegistry.toolName
                || definition.function.name == ChatListAgentsToolRegistry.toolName
                || definition.function.name == ChatCheckAgentToolRegistry.toolName
                || definition.function.name == ChatSteerAgentToolRegistry.toolName
                // These tools require parent-owned approval/selection UI.
                || definition.function.name == ChatTerminalToolRegistry.toolName
                || definition.function.name == ChatWorkToolRegistry.toolName
                || definition.function.name == ChatImageToolRegistry.generateToolName
                || definition.function.name == ChatImageToolRegistry.editToolName
                || settings.customTools.contains { tool in tool.kind == .script && tool.toolName == definition.function.name }
                || (!ChatToolRegistry.alwaysOnToolNames.contains(definition.function.name) && !settings.isToolEnabled(definition.function.name))
                || (definition.function.name == ChatWebSearchToolRegistry.toolName && !webSearchIsConfigured)
                || (definition.function.name == ChatWebReadToolRegistry.toolName && !webReadIsConfigured)
        }
        return definitions
    }

    private static func subAgentSystemPrompt(settings: NativSettings, hasTools: Bool) -> String? {
        var parts: [String] = []
        if !settings.systemPrompt.isEmpty {
            parts.append(settings.systemPrompt)
        }
        if hasTools {
            parts.append(NativSkill.builtInToolGuide.instructions)
        }
        for skill in settings.skills where skill.isEnabled && !skill.instructions.isEmpty {
            parts.append(skill.instructions)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private static func normalizedToolCalls(_ toolCalls: [MLXChatToolCall]) -> [MLXChatToolCall] {
        toolCalls.enumerated().map { index, call in
            var normalized = call
            normalized.index = index
            if normalized.id?.isEmpty != false {
                normalized.id = "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            }
            if normalized.type?.isEmpty != false {
                normalized.type = "function"
            }
            return normalized
        }
    }
}

@MainActor
private final class ChatAgentDisplayTranscript {
    private static let publishInterval: TimeInterval = 0.05

    private var messages: [ChatTranscriptMessage] = []
    private let onUpdate: (@MainActor @Sendable ([ChatTranscriptMessage]) -> Void)?
    private var lastPublishedAt: Date?

    init(onUpdate: (@MainActor @Sendable ([ChatTranscriptMessage]) -> Void)?) {
        self.onUpdate = onUpdate
    }

    func appendSteerMessage(_ content: String) {
        messages.append(ChatTranscriptMessage(role: .user, content: content))
        onUpdate?(messages)
    }

    func appendAssistantPlaceholder() -> UUID {
        let id = UUID()
        messages.append(ChatTranscriptMessage(id: id, role: .assistant, content: "", isStreaming: true))
        onUpdate?(messages)
        return id
    }

    func appendDelta(_ event: MLXChatStreamDelta, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[index].content += event.content ?? ""
        messages[index].reasoningContent += event.reasoningContent ?? ""
        if event.generatedTokens != nil || event.decodeTokensPerSecond != nil {
            messages[index].responseMetrics = ChatResponseMetrics(
                generatedTokens: event.generatedTokens,
                decodeTokensPerSecond: event.decodeTokensPerSecond
            )
        }
        publish(throttled: true)
    }

    func finishAssistant(_ id: UUID, completion: MLXChatCompletion) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[index].content = completion.content
        messages[index].reasoningContent = completion.reasoningContent ?? ""
        messages[index].isStreaming = false
        messages[index].responseMetrics = ChatResponseMetrics(completion: completion)
        publish(throttled: false)
    }

    private func publish(throttled: Bool) {
        let now = Date()
        if throttled, let last = lastPublishedAt, now.timeIntervalSince(last) < Self.publishInterval {
            return
        }
        lastPublishedAt = now
        onUpdate?(messages)
    }

    func appendToolPlaceholder(for call: MLXChatToolCall) -> UUID {
        let id = UUID()
        messages.append(ChatTranscriptMessage(
            id: id,
            role: .tool,
            content: "",
            isStreaming: true,
            toolCallID: call.id,
            toolName: call.function?.name,
            toolStatus: .running,
            toolArguments: call.function?.arguments
        ))
        onUpdate?(messages)
        return id
    }

    func finishTool(_ id: UUID, content: String, succeeded: Bool) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[index].content = content
        messages[index].isStreaming = false
        messages[index].toolStatus = succeeded ? .succeeded : .failed
        onUpdate?(messages)
    }
}
