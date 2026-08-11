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
    var mcpHost: MCPHostManager? = nil
    var disabledToolNames: [String] = []
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

enum ChatConcurrentSpawnGate {
    static let maximumConcurrentSpawnsPerRound = 5

    static func allowsAnotherSpawn(alreadyStarted count: Int) -> Bool {
        count < maximumConcurrentSpawnsPerRound
    }
}

/// Runs every pending `spawn_agent` call in a round concurrently, capturing
/// each child's outcome (including its own cancellation) as a `Result`
/// rather than rethrowing and discarding already-settled siblings.
enum ChatConcurrentSpawnRunner {
    struct PendingSpawn {
        let toolMessageID: UUID
        let call: MLXChatToolCall
    }

    struct SpawnOutcome {
        let toolMessageID: UUID
        let result: Result<String, Error>
    }

    static func runAll(
        _ pending: [PendingSpawn],
        execute: @escaping (PendingSpawn) async throws -> String
    ) async -> [SpawnOutcome] {
        await withTaskGroup(of: SpawnOutcome.self) { group in
            for spawn in pending {
                group.addTask {
                    do {
                        let result = try await execute(spawn)
                        return SpawnOutcome(toolMessageID: spawn.toolMessageID, result: .success(result))
                    } catch {
                        return SpawnOutcome(toolMessageID: spawn.toolMessageID, result: .failure(error))
                    }
                }
            }

            var outcomes: [SpawnOutcome] = []
            outcomes.reserveCapacity(pending.count)
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }
}

enum ChatToolRegistry {
    @MainActor
    static func definitions(
        context: ChatToolExecutionContext? = nil,
        canEditImage: Bool,
        allowsSpawning: Bool = true
    ) -> [MLXChatToolDefinition] {
        descriptors(context: context, canEditImage: canEditImage, allowsSpawning: allowsSpawning).map(\.definition)
    }

    @MainActor
    static func descriptors(
        context: ChatToolExecutionContext? = nil,
        canEditImage: Bool,
        allowsSpawning: Bool = true
    ) -> [ChatNativeToolDescriptor] {
        var definitions = ChatImageToolRegistry.definitions(canEdit: canEditImage)
        definitions += ChatSystemMonitorToolRegistry.definitions()
        definitions += ChatModelLibraryToolRegistry.definitions()
        definitions += ChatServerStatsToolRegistry.definitions()
        definitions += ChatSwitchModelToolRegistry.definitions()
        definitions += context?.mcpHost?.toolDefinitions() ?? []
        if allowsSpawning, context != nil {
            definitions += ChatSpawnAgentToolRegistry.definitions()
        }
        var tools = definitions.map {
            ChatNativeToolDescriptor(definition: $0, configuration: nil)
        }
        tools.append(ChatNativeToolDescriptor(
            definition: ChatWebSearchToolRegistry.definition,
            configuration: .webSearch
        ))
        // Filtered here, once, rather than per-caller, so there's only one
        // place this can drift out of sync.
        if let disabledToolNames = context?.disabledToolNames, !disabledToolNames.isEmpty {
            tools.removeAll { disabledToolNames.contains($0.definition.function.name) }
        }
        return tools
    }
}

enum MCPToolNaming {
    static let qualifiedPrefix = "mcp__"
}

/// Adapts `MCPHostManager` into the shape the chat tool loop needs —
/// dispatch and, unconditionally, consent-gating.
struct ChatMCPHostBridge {
    let host: MCPHostManager

    @MainActor
    func canHandle(_ name: String) -> Bool {
        host.handlesTool(named: name)
    }

    @MainActor
    func requiresConsent(_ name: String) -> Bool {
        canHandle(name)
    }

    @MainActor
    func execute(call: MLXChatToolCall) async throws -> ChatToolExecutionOutcome {
        guard let name = call.function?.name else {
            throw ChatImageToolError.unsupportedTool(call.function?.name ?? "unknown")
        }
        let result = try await host.callTool(named: name, argumentsJSON: call.function?.arguments)
        return ChatToolExecutionOutcome(content: result, attachments: [])
    }

    static func declinedPayload() -> String {
        let payload = ChatMCPToolResultPayload(ok: false, declined: true, error: "The user declined this action.")
        return (try? encodedPayload(payload))
            ?? #"{"ok":false,"declined":true,"error":"The user declined this action."}"#
    }

    static func failurePayload(error: Error) -> String {
        let payload = ChatMCPToolResultPayload(ok: false, declined: false, error: error.localizedDescription)
        return (try? encodedPayload(payload))
            ?? #"{"ok":false,"declined":false,"error":"MCP tool failed."}"#
    }

    private static func encodedPayload(_ payload: ChatMCPToolResultPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}

private struct ChatMCPToolResultPayload: Encodable {
    let ok: Bool
    let declined: Bool
    let error: String?
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
        ChatSpawnAgentToolRegistry.toolName: { name, error in
            ChatSpawnAgentToolExecutor().failurePayload(operation: name, error: error)
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
        guard let toolName else {
            return ChatImageToolExecutor().failurePayload(operation: "tool", error: error)
        }
        if let handler = failureHandlers[toolName] {
            return handler(toolName, error)
        }
        if toolName.hasPrefix(MCPToolNaming.qualifiedPrefix) {
            return ChatMCPHostBridge.failurePayload(error: error)
        }
        return ChatImageToolExecutor().failurePayload(operation: toolName, error: error)
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

enum ChatCompletionRequestBuilder {
    @MainActor
    static func make(
        modelID: String,
        precedingMessages: [ChatTranscriptMessage],
        settings: NativSettings,
        advertisesTools: Bool,
        languageModelSupportsTools: Bool,
        canEditImage: Bool,
        allowsSpawning: Bool,
        mcpHost: MCPHostManager? = nil
    ) -> MLXChatCompletionRequest {
        var requestMessages = precedingMessages.compactMap(\.apiMessage)

        let advertisesToolsForModel = advertisesTools && languageModelSupportsTools
        let toolDefinitions = advertisesToolsForModel
            ? ChatToolRegistry.definitions(
                context: ChatToolExecutionContext(
                    imageGenerationModelID: settings.imageGenerationModelID,
                    baseURL: settings.serverBaseURL,
                    apiKey: settings.serverAPIKey,
                    imageReferences: [],
                    modelSearchPath: settings.expandedModelSearchPath,
                    additionalModelSearchPaths: settings.additionalModelSearchPaths,
                    mcpHost: mcpHost,
                    disabledToolNames: settings.disabledToolNames
                ),
                canEditImage: canEditImage,
                allowsSpawning: allowsSpawning
            )
            : []
        let tools = toolDefinitions.isEmpty ? nil : toolDefinitions

        var systemParts: [String] = []
        if !settings.systemPrompt.isEmpty {
            systemParts.append(settings.systemPrompt)
        }
        if !toolDefinitions.isEmpty {
            systemParts.append(NativSkill.builtInToolGuide.instructions)
        }
        for skill in settings.skills where skill.isEnabled && !skill.instructions.isEmpty {
            systemParts.append(skill.instructions)
        }
        if !systemParts.isEmpty {
            requestMessages.insert(
                MLXChatMessage(role: "system", content: systemParts.joined(separator: "\n\n")),
                at: 0
            )
        }

        return MLXChatCompletionRequest(
            model: modelID,
            messages: requestMessages,
            maxTokens: settings.maxTokens,
            temperature: settings.temperature,
            topK: settings.topK,
            topP: settings.topP,
            minP: settings.minP,
            repetitionPenalty: settings.repetitionPenaltyEnabled ? settings.repetitionPenalty : nil,
            enableThinking: settings.thinkingEnabled,
            thinkingBudget: settings.thinkingEnabled
                && settings.thinkingBudgetEnabled
                && !settings.speculativeDecodingActive
                ? settings.thinkingBudget
                : nil,
            thinkingStartToken: settings.thinkingEnabled ? settings.thinkingStartToken : nil,
            thinkingEndToken: settings.thinkingEnabled ? settings.thinkingEndToken : nil,
            responseFormat: tools == nil ? settings.chatResponseFormat : nil,
            tools: tools,
            toolChoice: tools == nil ? nil : "auto",
            stream: true
        )
    }
}

enum ChatToolCallNormalizer {
    static func normalize(_ toolCalls: [MLXChatToolCall]) -> [MLXChatToolCall] {
        toolCalls.enumerated().map { index, call in
            var normalized = call
            normalized.index = index
            if normalized.id?.isEmpty != false {
                normalized.id = "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            }
            if normalized.type?.isEmpty != false {
                normalized.type = "function"
            }
            // Streamed name deltas can leave stray whitespace that fails
            // every exact-string dispatch check downstream — trim once here
            // rather than patching each comparison site.
            if let rawName = normalized.function?.name {
                normalized.function?.name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return normalized
        }
    }
}

enum ChatSpawnAgentToolRegistry {
    static let toolName = "spawn_agent"

    static func definitions() -> [MLXChatToolDefinition] {
        [MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName,
            description: "Delegate a focused sub-task to a fresh instance of yourself and get back its final answer. Use for a self-contained piece of work you can fully describe up front.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "task": .object([
                        "type": .string("string"),
                        "description": .string("What the sub-agent should do. This is the sub-agent's entire instruction — it does not see this conversation.")
                    ]),
                    "context": .object([
                        "type": .string("string"),
                        "description": .string("Optional: specific facts from this conversation the sub-agent needs. Omit if the task is fully self-contained.")
                    ]),
                    "model": .object([
                        "type": .string("string"),
                        "description": .string("Optional: run this sub-agent on a different model than your own (e.g. a smaller model for a simple task). Must be the exact full repo ID of a model already installed locally (e.g. \"mlx-community/Qwen3-0.6B-4bit\", not just \"Qwen3-0.6B-4bit\") — use list_models if unsure. Omit to use your own model. Loading a different model evicts whichever model is currently loaded, including your own — expect a reload pause on both the switch and the return.")
                    ])
                ]),
                "required": .array([.string("task")])
            ])
        ))]
    }
}

struct ChatSpawnAgentToolArguments: Decodable {
    let task: String
    let context: String?
    let model: String?
}

struct ChatSpawnAgentToolResultPayload: Encodable {
    let ok: Bool
    let result: String?
    let error: String?
}

enum ChatSpawnAgentToolError: LocalizedError {
    case invalidArguments
    case noModelConfigured
    case unknownModel(String)
    case tooManyPerRound
    case noFinalAnswer
    case insufficientMemory(modelID: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "The spawn_agent arguments were not valid JSON."
        case .noModelConfigured:
            return "No language model is configured to run the sub-agent."
        case .unknownModel(let modelID):
            return "Unknown model: \(modelID). This model is not installed locally — use one of the models already available, or omit \"model\" to use your own."
        case .tooManyPerRound:
            return "Only \(ChatConcurrentSpawnGate.maximumConcurrentSpawnsPerRound) sub-agents may run per round."
        case .noFinalAnswer:
            return "Sub-agent did not produce an answer."
        case .insufficientMemory(let modelID, let message):
            return "Not enough memory to load \(modelID): \(message)"
        }
    }

    /// Re-maps the server's structured HTTP 507 rejection to this error's
    /// own case, rather than letting the raw JSON body reach the user.
    static func from(_ error: Error, modelID: String) -> ChatSpawnAgentToolError? {
        guard case NativChatError.httpStatus(507, let body) = error,
              NativServerErrorMessage.errorKind(from: body) == ChatServerInsufficientMemory.errorKind,
              let message = NativServerErrorMessage.detail(from: body)
        else {
            return nil
        }
        return .insufficientMemory(modelID: modelID, message: message)
    }
}

/// Kept as a named constant so the Swift and Python sides can't drift apart.
enum ChatServerInsufficientMemory {
    static let errorKind = "insufficient_memory"
}

/// Decides whether an accumulating stream of text deltas should flush into
/// the visible message now or wait, at a capped cadence. Lives here, not in
/// `ChatViewModel`, so `NativTests` can compile it standalone.
enum ChatAgentStreamThrottle {
    static let flushInterval: TimeInterval = 1.0 / 15.0

    static func shouldFlush(elapsedSinceLastFlush: TimeInterval?) -> Bool {
        guard let elapsedSinceLastFlush else {
            return true
        }
        return elapsedSinceLastFlush >= flushInterval
    }
}

/// A sub-agent's own round-loop, over a private in-memory message array
/// instead of a session-backed one.
@MainActor
struct ChatAgentLoop {
    struct Configuration {
        let modelID: String
        let settings: NativSettings
        let languageModelSupportsTools: Bool
        let toolExecutionContext: ChatToolExecutionContext
        let consentGate: ChatToolConsentGate
        let appModel: NativModel?
    }

    let configuration: Configuration
    let onMessagesChange: ([ChatTranscriptMessage]) -> Void

    func run(initialUserContent: String) async throws -> String {
        let client = NativChatClient(
            baseURL: configuration.settings.serverBaseURL,
            apiKey: configuration.settings.serverAPIKey
        )

        var messages: [ChatTranscriptMessage] = [
            ChatTranscriptMessage(role: .user, content: initialUserContent)
        ]
        onMessagesChange(messages)

        var toolRounds = 0
        while true {
            try Task.checkCancellation()
            let advertisesTools = ChatToolRoundGate.advertisesTools(atRound: toolRounds)
            let request = ChatCompletionRequestBuilder.make(
                modelID: configuration.modelID,
                precedingMessages: messages,
                settings: configuration.settings,
                advertisesTools: advertisesTools,
                languageModelSupportsTools: configuration.languageModelSupportsTools,
                canEditImage: messages.contains { !$0.imageAttachments.isEmpty },
                allowsSpawning: false,
                mcpHost: configuration.toolExecutionContext.mcpHost
            )

            let assistantMessageID = UUID()
            messages.append(ChatTranscriptMessage(
                id: assistantMessageID,
                role: .assistant,
                content: "",
                modelID: configuration.modelID,
                isStreaming: true,
                isThinkingEnabled: configuration.settings.thinkingEnabled
            ))
            onMessagesChange(messages)

            var pendingContent = ""
            var pendingReasoning = ""
            var lastFlushDate: Date?

            let completion: MLXChatCompletion
            do {
                completion = try await client.streamChat(request, repetitionDetector: .default, onEvent: { event in
                    await MainActor.run {
                        if let content = event.content, !content.isEmpty {
                            pendingContent += content
                        }
                        if let reasoning = event.reasoningContent, !reasoning.isEmpty {
                            pendingReasoning += reasoning
                        }
                        guard !pendingContent.isEmpty || !pendingReasoning.isEmpty else {
                            return
                        }

                        let elapsed = lastFlushDate.map { Date().timeIntervalSince($0) }
                        guard ChatAgentStreamThrottle.shouldFlush(elapsedSinceLastFlush: elapsed) else {
                            return
                        }
                        lastFlushDate = Date()

                        guard let index = messages.firstIndex(where: { $0.id == assistantMessageID }) else {
                            return
                        }
                        if !pendingContent.isEmpty, !messages[index].reasoningContent.isEmpty,
                           messages[index].thinkingDuration == nil {
                            messages[index].thinkingDuration = Date().timeIntervalSince(messages[index].createdAt)
                        }
                        messages[index].content += pendingContent
                        messages[index].reasoningContent += pendingReasoning
                        pendingContent = ""
                        pendingReasoning = ""
                        onMessagesChange(messages)
                    }
                })
            } catch {
                throw ChatSpawnAgentToolError.from(error, modelID: configuration.modelID) ?? error
            }
            let toolCalls = ChatToolCallNormalizer.normalize(completion.toolCalls)

            // Overwrite with the authoritative full content — covers
            // whatever was still unflushed in the throttle's buffer.
            if let index = messages.firstIndex(where: { $0.id == assistantMessageID }) {
                if !completion.content.isEmpty, !(completion.reasoningContent ?? "").isEmpty,
                   messages[index].thinkingDuration == nil {
                    messages[index].thinkingDuration = Date().timeIntervalSince(messages[index].createdAt)
                }
                messages[index].content = completion.content
                messages[index].reasoningContent = completion.reasoningContent ?? ""
                messages[index].isStreaming = false
            }
            onMessagesChange(messages)

            guard advertisesTools, !toolCalls.isEmpty else {
                let finalContent = completion.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !finalContent.isEmpty else {
                    throw ChatSpawnAgentToolError.noFinalAnswer
                }
                return finalContent
            }

            for toolCall in toolCalls {
                try Task.checkCancellation()
                try await runToolCall(toolCall, messages: &messages)
            }

            toolRounds += 1
        }
    }

    private func runToolCall(
        _ toolCall: MLXChatToolCall,
        messages: inout [ChatTranscriptMessage]
    ) async throws {
        let toolMessageID = UUID()
        messages.append(ChatTranscriptMessage(
            id: toolMessageID,
            role: .tool,
            content: "",
            toolCallID: toolCall.id,
            toolName: toolCall.function?.name,
            toolStatus: .running,
            toolArguments: toolCall.function?.arguments
        ))
        onMessagesChange(messages)

        if let consentGatedAction = ChatConsentGatedAction.detect(
            call: toolCall,
            mcpHost: configuration.toolExecutionContext.mcpHost
        ) {
            try await runConsentGatedToolCall(
                toolCall,
                action: consentGatedAction,
                toolMessageID: toolMessageID,
                messages: &messages
            )
            return
        }

        do {
            let outcome = try await ChatToolDispatcher.execute(call: toolCall, context: configuration.toolExecutionContext)
            update(&messages, id: toolMessageID) {
                $0.toolStatus = .succeeded
                $0.content = outcome.content
                $0.imageAttachments = outcome.attachments
            }
        } catch is CancellationError {
            update(&messages, id: toolMessageID) {
                $0.toolStatus = .cancelled
                $0.content = ChatToolDispatcher.failurePayload(toolName: toolCall.function?.name, error: CancellationError())
            }
            onMessagesChange(messages)
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            update(&messages, id: toolMessageID) {
                $0.toolStatus = .cancelled
                $0.content = ChatToolDispatcher.failurePayload(toolName: toolCall.function?.name, error: CancellationError())
            }
            onMessagesChange(messages)
            throw CancellationError()
        } catch {
            update(&messages, id: toolMessageID) {
                $0.toolStatus = .failed
                $0.content = ChatToolDispatcher.failurePayload(toolName: toolCall.function?.name, error: error)
            }
        }
        onMessagesChange(messages)
    }

    private func runConsentGatedToolCall(
        _ toolCall: MLXChatToolCall,
        action: ChatConsentGatedAction,
        toolMessageID: UUID,
        messages: inout [ChatTranscriptMessage]
    ) async throws {
        update(&messages, id: toolMessageID) { $0.toolStatus = .awaitingConsent }
        onMessagesChange(messages)

        let approved = await configuration.consentGate.awaitDecision(for: toolMessageID)
        switch ChatToolConsentRouter.outcome(approved: approved, isCancelled: Task.isCancelled) {
        case .cancelled:
            update(&messages, id: toolMessageID) {
                $0.toolStatus = .cancelled
                $0.content = ChatToolDispatcher.failurePayload(
                    toolName: toolCall.function?.name,
                    error: CancellationError()
                )
            }
            onMessagesChange(messages)
            throw CancellationError()
        case .declined:
            update(&messages, id: toolMessageID) {
                $0.toolStatus = .declined
                $0.content = action.declinedPayload()
            }
            onMessagesChange(messages)
            return
        case .approved:
            update(&messages, id: toolMessageID) { $0.toolStatus = .running }
            onMessagesChange(messages)
        }

        if case .switchModel = action, configuration.appModel == nil {
            update(&messages, id: toolMessageID) {
                $0.toolStatus = .failed
                $0.content = ChatSwitchModelToolExecutor().failurePayload(
                    operation: ChatSwitchModelToolRegistry.toolName,
                    error: ChatSwitchModelToolError.appModelUnavailable
                )
            }
            onMessagesChange(messages)
            return
        }

        do {
            let content = try await action.execute(appModel: configuration.appModel)
            update(&messages, id: toolMessageID) {
                $0.toolStatus = .succeeded
                $0.content = content
            }
        } catch is CancellationError {
            update(&messages, id: toolMessageID) {
                $0.toolStatus = .cancelled
                $0.content = action.failurePayload(error: CancellationError())
            }
            onMessagesChange(messages)
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            update(&messages, id: toolMessageID) {
                $0.toolStatus = .cancelled
                $0.content = action.failurePayload(error: CancellationError())
            }
            onMessagesChange(messages)
            throw CancellationError()
        } catch {
            update(&messages, id: toolMessageID) {
                $0.toolStatus = .failed
                $0.content = action.failurePayload(error: error)
            }
        }
        onMessagesChange(messages)
    }

    private func update(
        _ messages: inout [ChatTranscriptMessage],
        id: UUID,
        mutate: (inout ChatTranscriptMessage) -> Void
    ) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&messages[index])
    }
}

enum ChatSpawnAgentModelResolver {
    static func resolve(argumentModel: String?, coordinatorModelID: String?) -> String? {
        trimmedNonBlank(argumentModel) ?? coordinatorModelID
    }

    static func isExplicitOverride(argumentModel: String?) -> Bool {
        trimmedNonBlank(argumentModel) != nil
    }

    static func isKnownModel(_ modelID: String, among knownModels: [LocalModel]) -> Bool {
        knownModels.contains { $0.repoID == modelID }
    }

    private static func trimmedNonBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

struct ChatSpawnAgentToolExecutor {
    @MainActor
    func execute(
        call: MLXChatToolCall,
        settings: NativSettings,
        languageModelSupportsTools: Bool,
        toolExecutionContext: ChatToolExecutionContext,
        consentGate: ChatToolConsentGate,
        appModel: NativModel?,
        onSubMessagesChange: @escaping ([ChatTranscriptMessage]) -> Void
    ) async throws -> String {
        guard call.function?.name == ChatSpawnAgentToolRegistry.toolName else {
            throw ChatImageToolError.unsupportedTool(call.function?.name ?? "unknown")
        }
        guard let argumentsData = call.function?.arguments?.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(ChatSpawnAgentToolArguments.self, from: argumentsData),
              !arguments.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ChatSpawnAgentToolError.invalidArguments
        }
        // The server holds one text-generation model at a time and swaps on
        // every request's own `model` field, so a sub-agent needs no explicit
        // swap orchestration -- just its own `model` on each request.
        guard let modelID = ChatSpawnAgentModelResolver.resolve(
            argumentModel: arguments.model,
            coordinatorModelID: settings.languageModelID
        ) else {
            throw ChatSpawnAgentToolError.noModelConfigured
        }

        // A hallucinated model argument would otherwise 401 minutes later
        // instead of failing fast locally. Only the explicit-override path
        // needs this — the coordinator's own model is already known-good.
        if ChatSpawnAgentModelResolver.isExplicitOverride(argumentModel: arguments.model) {
            let knownModels = try await LocalModelDiscovery.scan(
                path: toolExecutionContext.modelSearchPath,
                additionalPaths: toolExecutionContext.additionalModelSearchPaths
            )
            guard ChatSpawnAgentModelResolver.isKnownModel(modelID, among: knownModels) else {
                throw ChatSpawnAgentToolError.unknownModel(modelID)
            }
        }

        var initialContent = arguments.task
        if let context = arguments.context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            initialContent += "\n\nContext:\n\(context)"
        }

        let loop = ChatAgentLoop(
            configuration: ChatAgentLoop.Configuration(
                modelID: modelID,
                settings: settings,
                languageModelSupportsTools: languageModelSupportsTools,
                toolExecutionContext: toolExecutionContext,
                consentGate: consentGate,
                appModel: appModel
            ),
            onMessagesChange: onSubMessagesChange
        )

        let result = try await loop.run(initialUserContent: initialContent)
        return try encodedPayload(ChatSpawnAgentToolResultPayload(ok: true, result: result, error: nil))
    }

    func tooManyPerRoundPayload() -> String {
        (try? encodedPayload(ChatSpawnAgentToolResultPayload(
            ok: false,
            result: nil,
            error: ChatSpawnAgentToolError.tooManyPerRound.errorDescription
        ))) ?? #"{"ok":false,"error":"Only \#(ChatConcurrentSpawnGate.maximumConcurrentSpawnsPerRound) sub-agents may run per round."}"#
    }

    func failurePayload(operation: String, error: Error) -> String {
        let payload = ChatSpawnAgentToolResultPayload(ok: false, result: nil, error: error.localizedDescription)
        return (try? encodedPayload(payload))
            ?? #"{"ok":false,"error":"Sub-agent delegation failed."}"#
    }

    private func encodedPayload(_ payload: ChatSpawnAgentToolResultPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
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

enum ChatConsentGatedAction {
    case switchModel(call: MLXChatToolCall)
    case mcpTool(call: MLXChatToolCall, bridge: ChatMCPHostBridge)

    @MainActor
    static func detect(call: MLXChatToolCall, mcpHost: MCPHostManager?) -> ChatConsentGatedAction? {
        guard let name = call.function?.name else { return nil }
        if name == ChatSwitchModelToolRegistry.toolName {
            return .switchModel(call: call)
        }
        if let mcpHost {
            let bridge = ChatMCPHostBridge(host: mcpHost)
            if bridge.requiresConsent(name) {
                return .mcpTool(call: call, bridge: bridge)
            }
        }
        return nil
    }

    @MainActor
    func execute(appModel: NativModel?) async throws -> String {
        switch self {
        case .switchModel(let call):
            guard let appModel else {
                throw ChatSwitchModelToolError.appModelUnavailable
            }
            return try await ChatSwitchModelToolExecutor().execute(call: call, appModel: appModel)
        case .mcpTool(let call, let bridge):
            let outcome = try await bridge.execute(call: call)
            return outcome.content
        }
    }

    func declinedPayload() -> String {
        switch self {
        case .switchModel:
            return ChatSwitchModelToolExecutor().declinedPayload()
        case .mcpTool:
            return ChatMCPHostBridge.declinedPayload()
        }
    }

    func failurePayload(error: Error) -> String {
        switch self {
        case .switchModel(let call):
            return ChatSwitchModelToolExecutor().failurePayload(
                operation: call.function?.name ?? ChatSwitchModelToolRegistry.toolName,
                error: error
            )
        case .mcpTool:
            return ChatMCPHostBridge.failurePayload(error: error)
        }
    }
}

enum ChatToolPresentation {
    static func showsThinkingBubble(
        reasoningContent: String,
        isThinkingEnabled: Bool,
        isStreaming: Bool,
        content: String
    ) -> Bool {
        !reasoningContent.isEmpty || (isThinkingEnabled && isStreaming && content.isEmpty)
    }

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
        case ChatSpawnAgentToolRegistry.toolName:
            return spawnAgentTitle(status: status)
        case let name? where name.hasPrefix(MCPToolNaming.qualifiedPrefix):
            return mcpTitle(toolName: name, status: status)
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
            case ChatSpawnAgentToolRegistry.toolName:
                return "person.2.badge.gearshape"
            case let name? where name.hasPrefix(MCPToolNaming.qualifiedPrefix):
                return "puzzlepiece.extension"
            default:
                return "wrench.and.screwdriver"
            }
        }
    }

    static func showsDetailsWhileRunning(toolName: String?, status: ChatTranscriptMessage.ToolStatus?) -> Bool {
        toolName == ChatSpawnAgentToolRegistry.toolName && status == .running
    }

    static func shouldAutoExpandOnSettle(
        toolName: String?,
        previousStatus: ChatTranscriptMessage.ToolStatus?,
        newStatus: ChatTranscriptMessage.ToolStatus?
    ) -> Bool {
        guard toolName == ChatSpawnAgentToolRegistry.toolName, previousStatus == .running else {
            return false
        }
        return newStatus == .succeeded || newStatus == .failed
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

    private static func spawnAgentTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .preparing, .running:
            return "Delegating to sub-agent…"
        case .succeeded:
            return "Sub-agent finished"
        case .failed, .cancelled, .awaitingConsent, .awaitingImageModelSelection, .declined:
            return "Sub-agent delegation"
        case nil:
            return "Sub-agent tool"
        }
    }

    private static func mcpTitle(toolName: String, status: ChatTranscriptMessage.ToolStatus?) -> String {
        let name = mcpDisplayName(for: toolName) ?? toolName
        switch status {
        case .awaitingConsent:
            return "Run \(name)?"
        case .preparing, .running:
            return "Running \(name)…"
        case .succeeded:
            return "Ran \(name)"
        case .declined:
            return "\(name) declined"
        case .failed, .cancelled, .awaitingImageModelSelection, nil:
            return name
        }
    }

    private static func mcpDisplayName(for qualifiedName: String) -> String? {
        guard qualifiedName.hasPrefix(MCPToolNaming.qualifiedPrefix) else { return nil }
        let remainder = qualifiedName.dropFirst(MCPToolNaming.qualifiedPrefix.count)
        guard let separatorRange = remainder.range(of: "__") else { return nil }
        let server = remainder[..<separatorRange.lowerBound]
        let tool = remainder[separatorRange.upperBound...]
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return "\(tool) (\(server))"
    }

    static func mcpConsentDescription(toolName: String?) -> String {
        guard let toolName, let display = mcpDisplayName(for: toolName) else {
            return "The model wants to run this tool."
        }
        return "The model wants to run \(display)."
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
