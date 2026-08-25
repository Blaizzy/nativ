import Foundation
import NativServerKit

enum ChatAgentLoopError: LocalizedError {
    case recursiveSpawnNotAllowed

    var errorDescription: String? {
        "A sub-agent can't spawn further sub-agents."
    }
}

@MainActor
enum ChatAgentLoop {
    static func run(
        messages initialMessages: [MLXChatMessage],
        modelID: String,
        settings: NativSettings,
        canEditImage: Bool,
        context: ChatToolExecutionContext,
        agentID: String? = nil,
        onUpdate: (@MainActor @Sendable ([ChatTranscriptMessage]) -> Void)? = nil
    ) async throws -> MLXChatCompletion {
        let client = NativChatClient(baseURL: context.baseURL, apiKey: context.apiKey)
        let toolDefinitions = subAgentToolDefinitions(settings: settings, canEditImage: canEditImage, context: context)
        let systemPrompt = subAgentSystemPrompt(settings: settings, hasTools: !toolDefinitions.isEmpty)
        let customTools = settings.customTools.filter { $0.kind != .script }
        let transcript = ChatAgentDisplayTranscript(onUpdate: onUpdate)

        var messages = initialMessages
        if let systemPrompt {
            messages.insert(MLXChatMessage(role: "system", content: systemPrompt), at: 0)
        }

        var round = 0
        while true {
            try Task.checkCancellation()

            if let agentID, let steerMessages = context.agentRegistry?.drainSteerMessages(for: agentID),
               !steerMessages.isEmpty {
                for steerMessage in steerMessages {
                    messages.append(MLXChatMessage(role: "user", content: steerMessage))
                    transcript.appendSteerMessage(steerMessage)
                }
            }

            let advertisesTools = ChatToolRoundGate.advertisesTools(atRound: round) && !toolDefinitions.isEmpty
            let request = MLXChatCompletionRequest(
                model: modelID,
                messages: messages,
                maxTokens: settings.maxTokens,
                temperature: settings.temperature,
                topK: settings.topK,
                topP: settings.topP,
                minP: settings.minP,
                repetitionPenalty: settings.repetitionPenaltyEnabled ? settings.repetitionPenalty : nil,
                enableThinking: settings.thinkingEnabled,
                responseFormat: advertisesTools ? nil : settings.chatResponseFormat,
                tools: advertisesTools ? toolDefinitions : nil,
                toolChoice: advertisesTools ? "auto" : nil
            )

            let assistantDisplayID = transcript.appendAssistantPlaceholder()
            let completion = try await client.streamChat(request, onEvent: { event in
                await transcript.appendDelta(event, to: assistantDisplayID)
            })
            transcript.finishAssistant(assistantDisplayID, completion: completion)

            let toolCalls = normalizedToolCalls(completion.toolCalls)
            guard advertisesTools, !toolCalls.isEmpty else {
                return completion
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

    private static func executeToolCall(
        _ toolCall: MLXChatToolCall,
        customTools: [CustomTool],
        context: ChatToolExecutionContext
    ) async -> (content: String, succeeded: Bool) {
        let name = toolCall.function?.name
        if name == ChatSpawnAgentToolRegistry.toolName {
            return (ChatSpawnAgentToolExecutor().failurePayload(error: ChatAgentLoopError.recursiveSpawnNotAllowed), false)
        }
        do {
            if let customTool = name.flatMap({ toolName in customTools.first { $0.toolName == toolName } }) {
                let result = try await CustomToolExecutor.execute(customTool, argumentsJSON: toolCall.function?.arguments)
                return (result, true)
            }
            if let host = context.mcpHost, let name, host.handlesTool(named: name) {
                return (try await host.callTool(named: name, argumentsJSON: toolCall.function?.arguments), true)
            }
            let outcome = try await ChatToolDispatcher.execute(call: toolCall, context: context)
            return (outcome.content, true)
        } catch {
            return (ChatToolDispatcher.failurePayload(toolName: name, error: error), false)
        }
    }

    private static func subAgentToolDefinitions(
        settings: NativSettings,
        canEditImage: Bool,
        context: ChatToolExecutionContext
    ) -> [MLXChatToolDefinition] {
        var definitions = ChatToolRegistry.definitions(canEditImage: canEditImage)
        definitions += settings.customTools.filter { $0.kind != .script }.compactMap { try? $0.definition() }
        definitions += context.mcpHost?.toolDefinitions() ?? []
        let webSearchIsConfigured = ChatWebSearchToolRegistry.isConfigured()
        let webReadIsConfigured = ChatWebReadToolRegistry.isConfigured()
        definitions.removeAll {
            $0.function.name == ChatSwitchModelToolRegistry.toolName
                || $0.function.name == ChatSpawnAgentToolRegistry.toolName
                || $0.function.name == ChatListAgentsToolRegistry.toolName
                || $0.function.name == ChatCheckAgentToolRegistry.toolName
                || $0.function.name == ChatSteerAgentToolRegistry.toolName
                || !settings.isToolEnabled($0.function.name)
                || ($0.function.name == ChatWebSearchToolRegistry.toolName && !webSearchIsConfigured)
                || ($0.function.name == ChatWebReadToolRegistry.toolName && !webReadIsConfigured)
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
    private var messages: [ChatTranscriptMessage] = []
    private let onUpdate: (@MainActor @Sendable ([ChatTranscriptMessage]) -> Void)?

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
        onUpdate?(messages)
    }

    func finishAssistant(_ id: UUID, completion: MLXChatCompletion) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[index].content = completion.content
        messages[index].reasoningContent = completion.reasoningContent ?? ""
        messages[index].isStreaming = false
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
