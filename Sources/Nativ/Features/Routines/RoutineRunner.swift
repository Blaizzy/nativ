import Foundation
import NativServerKit
import NativTrace

@MainActor
final class RoutineRunner {
    private let model: NativModel
    private let store: RoutineStore
    private let sessionStore: ChatSessionStore
    private let mcpHost: MCPHostManager

    var onRunCompleted: ((Routine, RoutineRun) -> Void)?

    private var queue: [(Routine, RoutineRunSource)] = []
    private var isExecuting = false
    private var activeRoutineID: String?
    private var activeTask: Task<Void, Never>?

    init(
        model: NativModel,
        store: RoutineStore,
        sessionStore: ChatSessionStore,
        mcpHost: MCPHostManager? = nil
    ) {
        self.model = model
        self.store = store
        self.sessionStore = sessionStore
        self.mcpHost = mcpHost ?? MCPHostManager()
    }

    func run(_ routine: Routine, source: RoutineRunSource) {
        guard store.routine(id: routine.id) != nil else { return }
        queue.append((routine, source))
        drain()
    }

    func cancel(routineID: String) {
        queue.removeAll { $0.0.id == routineID }
        guard activeRoutineID == routineID else { return }
        activeTask?.cancel()
    }

    private func drain() {
        guard !isExecuting, !queue.isEmpty else {
            return
        }
        isExecuting = true
        let (routine, source) = queue.removeFirst()
        activeRoutineID = routine.id
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.execute(routine, source: source)
            self.activeTask = nil
            self.activeRoutineID = nil
            self.isExecuting = false
            self.drain()
        }
    }

    private func execute(_ routine: Routine, source: RoutineRunSource) async {
        guard shouldContinue(routine) else { return }
        let startedAt = Date()
        let sessionID = UUID()
        let initialTranscript = [
            ChatTranscriptMessage(role: .user, content: routine.instructions)
        ]
        saveRunChat(
            routine: routine,
            sessionID: sessionID,
            createdAt: startedAt,
            messages: initialTranscript
        )
        var run = RoutineRun(
            routineID: routine.id,
            startedAt: startedAt,
            source: source,
            sessionID: sessionID,
            status: .running
        )
        store.recordRun(run)

        let settings = model.settings.normalized()
        let kitResolution = NativKitRuntimeResolver.resolve(
            kitIDs: routine.capabilities.compactMap { capability in
                guard case .kit(let id) = capability else { return nil }
                return id
            },
            settings: settings,
            kitCatalog: model.kitLibrary.catalog
        )
        guard kitResolution.unavailableCapabilities.isEmpty else {
            finishUnavailableCapabilities(
                kitResolution.unavailableCapabilities,
                run: &run,
                routine: routine,
                sessionID: sessionID,
                startedAt: startedAt,
                initialTranscript: initialTranscript
            )
            return
        }

        if !model.isRunning {
            model.startServer()
        }
        await waitForServer()
        guard shouldContinue(routine) else { return }

        guard let baseURL = model.activeServerBaseURL else {
            let message = "The Nativ server isn’t running."
            saveRunChat(
                routine: routine,
                sessionID: sessionID,
                createdAt: startedAt,
                messages: initialTranscript + [
                    ChatTranscriptMessage(role: .error, content: message)
                ]
            )
            finish(&run, routine: routine, status: .failed, summary: message)
            return
        }

        let selectedServers = Self.selectedMCPServers(
            for: routine,
            settings: settings,
            kitMCPServers: kitResolution.mcpServers
        )
        await mcpHost.prepare(servers: selectedServers)
        guard shouldContinue(routine) else { return }
        let capabilities = Self.resolveCapabilities(
            for: routine,
            settings: settings,
            mcpHost: mcpHost,
            kitResolution: kitResolution
        )
        guard capabilities.unavailable.isEmpty else {
            finishUnavailableCapabilities(
                capabilities.unavailable,
                run: &run,
                routine: routine,
                sessionID: sessionID,
                startedAt: startedAt,
                initialTranscript: initialTranscript
            )
            return
        }

        do {
            let result = try await complete(
                routine: routine,
                sessionID: sessionID,
                settings: settings,
                capabilities: capabilities,
                baseURL: baseURL
            )
            guard shouldContinue(routine) else { return }
            saveRunChat(
                routine: routine,
                sessionID: sessionID,
                createdAt: startedAt,
                messages: result.transcript
            )
            finish(
                &run,
                routine: routine,
                status: .succeeded,
                summary: Self.summarize(result.finalContent)
            )
        } catch let failure as ScheduledCompletionFailure {
            guard shouldContinue(routine) else { return }
            let errorMessage = failure.localizedDescription
            let transcript =
                failure.transcript + [
                    ChatTranscriptMessage(role: .error, content: errorMessage)
                ]
            saveRunChat(
                routine: routine,
                sessionID: sessionID,
                createdAt: startedAt,
                messages: transcript
            )
            finish(&run, routine: routine, status: .failed, summary: errorMessage)
        } catch {
            guard shouldContinue(routine) else { return }
            let errorMessage = error.localizedDescription
            saveRunChat(
                routine: routine,
                sessionID: sessionID,
                createdAt: startedAt,
                messages: initialTranscript + [
                    ChatTranscriptMessage(role: .error, content: errorMessage)
                ]
            )
            finish(&run, routine: routine, status: .failed, summary: errorMessage)
        }
    }

    private func complete(
        routine: Routine,
        sessionID: UUID,
        settings: NativSettings,
        capabilities: ResolvedCapabilities,
        baseURL: URL
    ) async throws -> ScheduledExecutionResult {
        let client = NativChatClient(baseURL: baseURL, apiKey: settings.serverAPIKey)
        var requestMessages: [MLXChatMessage] = []
        // Parallel to `requestMessages`, minus the system message: the trace
        // records system content as provenance-tagged sections, not as a
        // message. Each entry carries the id the trace knows that body by, so
        // an assistant turn resolves to its own text rather than the prompt's.
        var sentRefs: [TraceMessageRef] = []
        let systemPrompt = Self.systemPrompt(for: capabilities)
        if !systemPrompt.isEmpty {
            requestMessages.append(MLXChatMessage(role: "system", content: systemPrompt))
        }
        requestMessages.append(MLXChatMessage(role: "user", content: routine.instructions))

        let tracer = await TraceServices.shared.producer(
            enabled: settings.traceRecordingEnabled
        )
        let turn = ChatTraceTurn(sessionID: sessionID, turnID: UUID())
        let userMessageID = UUID()
        sentRefs.append(Self.messageRef(role: .user, id: userMessageID.uuidString, body: routine.instructions))
        await tracer?.turnStarted(
            turn,
            messageID: userMessageID,
            text: routine.instructions,
            modelID: routine.modelID
        )

        // FINDING 13: without this, cancellation or a throwing tool left the
        // turn open forever and a reader could not tell an aborted run from one
        // still in flight.
        var outcome = "completed"
        var recordedRounds = 0
        defer {
            let producer = tracer
            let endedTurn = turn
            let status = outcome
            let rounds = recordedRounds
            Task { @MainActor in
                producer?.turnEnded(endedTurn, status: status, roundCount: rounds)
            }
        }

        var transcript = [ChatTranscriptMessage(role: .user, content: routine.instructions)]
        var toolRound = 0
        let fileReadTracker = ChatReadFileTracker()
        let fileSearchTracker = ChatSearchFilesTracker()
        let fileOperationRunID = UUID()

        do {
        while true {
            try Task.checkCancellation()
            recordedRounds = toolRound + 1
            let advertisesTools =
                !capabilities.tools.isEmpty
                && ChatToolRoundGate.advertisesTools(atRound: toolRound)
            let toolDefinitions =
                advertisesTools
                ? capabilities.tools.map(\.definition)
                : nil
            let request = MLXChatCompletionRequest(
                model: routine.modelID,
                messages: requestMessages,
                maxTokens: settings.maxTokens,
                temperature: settings.temperature,
                topK: settings.topK,
                topP: settings.topP,
                minP: settings.minP,
                repetitionPenalty: settings.repetitionPenaltyEnabled
                    ? settings.repetitionPenalty
                    : nil,
                enableThinking: settings.thinkingEnabled,
                thinkingBudget: settings.thinkingEnabled
                    && settings.thinkingBudgetEnabled
                    && !settings.speculativeDecodingActive
                    ? settings.thinkingBudget
                    : nil,
                thinkingStartToken: settings.thinkingEnabled ? settings.thinkingStartToken : nil,
                thinkingEndToken: settings.thinkingEnabled ? settings.thinkingEndToken : nil,
                responseFormat: toolDefinitions == nil ? settings.chatResponseFormat : nil,
                tools: toolDefinitions,
                toolChoice: toolDefinitions == nil ? nil : "auto"
            )
            let call = ChatTraceCall(
                turn: turn,
                requestID: UUID(),
                round: toolRound,
                modelID: routine.modelID
            )
            await tracer?.requestComposed(
                Self.exposure(
                    capabilities: capabilities,
                    advertisesTools: advertisesTools,
                    toolDefinitions: toolDefinitions,
                    settings: settings,
                    messages: sentRefs
                ),
                in: call
            )

            let completion: MLXChatCompletion
            do {
                completion = try await client.completeChat(
                    request,
                    requestID: call.requestID.uuidString
                )
            } catch {
                await tracer?.responseFailed(
                    message: String(describing: error),
                    isCancellation: error is CancellationError,
                    in: call
                )
                await tracer?.turnEnded(turn, status: "failed", roundCount: toolRound + 1)
                throw ScheduledCompletionFailure(underlying: error, transcript: transcript)
            }
            let assistantMessageID = UUID()
            sentRefs.append(
                Self.messageRef(
                    role: .assistant,
                    id: assistantMessageID.uuidString,
                    body: completion.content
                )
            )
            await tracer?.responseCompleted(
                messageID: assistantMessageID,
                content: completion.content,
                reasoning: completion.reasoningContent,
                usage: TraceUsage(
                    promptTokens: completion.usage?.promptTokens,
                    completionTokens: completion.usage?.completionTokens
                ),
                finishReason: completion.finishReason,
                in: call
            )
            let toolCalls = Self.normalizedToolCalls(completion.toolCalls)

            guard advertisesTools, !toolCalls.isEmpty else {
                transcript.append(
                    ChatTranscriptMessage(
                        role: .assistant,
                        content: completion.content,
                        reasoningContent: completion.reasoningContent ?? "",
                        modelID: routine.modelID
                    ))
                await tracer?.turnEnded(turn, status: "completed", roundCount: toolRound + 1)
                return ScheduledExecutionResult(
                    finalContent: completion.content,
                    transcript: transcript
                )
            }

            requestMessages.append(
                MLXChatMessage(
                    role: "assistant",
                    content: completion.content,
                    reasoningContent: completion.reasoningContent,
                    toolCalls: toolCalls
                ))
            transcript.append(
                ChatTranscriptMessage(
                    role: .assistant,
                    content: completion.content,
                    reasoningContent: completion.reasoningContent ?? "",
                    modelID: routine.modelID,
                    toolCalls: toolCalls
                ))

            for toolCall in toolCalls {
                try Task.checkCancellation()
                // FINDING 9: the call and its result must agree on the id, or
                // the reducer cannot pair them and every result collapses onto
                // one orphan row.
                let traceCallID = toolCall.id ?? UUID().uuidString
                if let name = toolCall.function?.name {
                    await tracer?.toolCall(
                        callID: traceCallID,
                        name: name,
                        argumentsJSON: toolCall.function?.arguments,
                        in: call
                    )
                }
                let result = try await executeTool(
                    toolCall,
                    capabilities: capabilities,
                    settings: settings,
                    baseURL: baseURL,
                    fileReadTracker: fileReadTracker,
                    fileSearchTracker: fileSearchTracker,
                    fileOperationRunID: fileOperationRunID
                )
                await tracer?.toolResult(
                    callID: traceCallID,
                    name: toolCall.function?.name,
                    output: result.content,
                    isError: !result.succeeded,
                    in: call
                )
                sentRefs.append(
                    Self.messageRef(role: .tool, id: traceCallID, body: result.content)
                )
                requestMessages.append(
                    MLXChatMessage(
                        role: "tool",
                        content: result.content,
                        toolCallID: toolCall.id,
                        name: toolCall.function?.name
                    ))
                transcript.append(
                    ChatTranscriptMessage(
                        role: .tool,
                        content: result.content,
                        imageAttachments: result.attachments,
                        toolCallID: toolCall.id,
                        toolName: toolCall.function?.name,
                        toolStatus: result.succeeded ? .succeeded : .failed,
                        toolArguments: toolCall.function?.arguments
                    ))
            }
            toolRound += 1
        }
        } catch {
            outcome = ChatIsCancellation(error) ? "cancelled" : "failed"
            throw error
        }
    }

    private static func messageRef(
        role: TraceRole,
        id: String,
        body: String
    ) -> TraceMessageRef {
        TraceMessageRef(
            role: role,
            messageID: id,
            contentHash: TraceHash.content(body),
            byteCount: body.utf8.count
        )
    }

    private func executeTool(
        _ call: MLXChatToolCall,
        capabilities: ResolvedCapabilities,
        settings: NativSettings,
        baseURL: URL,
        fileReadTracker: ChatReadFileTracker,
        fileSearchTracker: ChatSearchFilesTracker,
        fileOperationRunID: UUID
    ) async throws -> ScheduledToolResult {
        do {
            try Task.checkCancellation()
            guard let name = call.function?.name,
                let tool = capabilities.tool(named: name)
            else {
                throw ScheduledToolExecutionError.notAllowed(call.function?.name ?? "unknown")
            }

            let outcome: ChatToolExecutionOutcome
            switch tool.provider {
            case .custom(let id):
                guard let customTool = settings.customTools.first(where: { $0.id == id }) else {
                    throw ScheduledToolExecutionError.unavailable(name)
                }
                let content = try await CustomToolExecutor.execute(
                    customTool,
                    argumentsJSON: call.function?.arguments
                )
                outcome = ChatToolExecutionOutcome(content: content, attachments: [])
            case .mcp:
                guard mcpHost.handlesTool(named: name) else {
                    throw ScheduledToolExecutionError.unavailable(name)
                }
                let content = try await mcpHost.callTool(
                    named: name,
                    argumentsJSON: call.function?.arguments
                )
                outcome = ChatToolExecutionOutcome(content: content, attachments: [])
            case .builtIn:
                let context = ChatToolExecutionContext(
                    imageGenerationModelID: settings.imageGenerationModelID,
                    baseURL: baseURL,
                    apiKey: settings.serverAPIKey,
                    imageReferences: [],
                    modelSearchPath: settings.expandedModelSearchPath,
                    additionalModelSearchPaths: settings.additionalModelSearchPaths,
                    huggingFaceToken: model.effectiveHuggingFaceToken,
                    fileReadRootPath: settings.fileReadRootPath,
                    fileReadTracker: fileReadTracker,
                    fileSearchTracker: fileSearchTracker,
                    fileOperationRunID: fileOperationRunID
                )
                outcome = try await ChatToolDispatcher.execute(call: call, context: context)
            }
            return ScheduledToolResult(
                content: outcome.content,
                attachments: outcome.attachments,
                succeeded: true
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ScheduledToolResult(
                content: ChatToolDispatcher.failurePayload(
                    toolName: call.function?.name,
                    error: error
                ),
                attachments: [],
                succeeded: false
            )
        }
    }

    private func saveRunChat(
        routine: Routine,
        sessionID: UUID,
        createdAt: Date,
        messages: [ChatTranscriptMessage]
    ) {
        guard shouldContinue(routine) else { return }
        var session = ScheduledTaskChatLinker.makeRunSession(
            for: routine,
            messages: messages,
            id: sessionID,
            createdAt: createdAt
        )
        session.updatedAt = Date()
        sessionStore.saveSession(session)
        NotificationCenter.default.post(name: .routineDidSaveChatSession, object: nil)
    }

    private func finish(
        _ run: inout RoutineRun,
        routine: Routine,
        status: RoutineRunStatus,
        summary: String
    ) {
        guard shouldContinue(routine) else { return }
        run.status = status
        run.finishedAt = Date()
        run.resultSummary = summary
        store.recordRun(run)
        onRunCompleted?(routine, run)
    }

    private func waitForServer(timeout: TimeInterval = 120) async {
        let deadline = Date().addingTimeInterval(timeout)
        while model.activeServerBaseURL == nil, Date() < deadline {
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
        }
        guard let baseURL = model.activeServerBaseURL else {
            return
        }
        let healthURL = baseURL.appendingPathComponent("v1/models")
        while Date() < deadline {
            guard !Task.isCancelled else { return }
            if await Self.isReachable(healthURL) {
                return
            }
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
        }
    }

    private func shouldContinue(_ routine: Routine) -> Bool {
        !Task.isCancelled && store.routine(id: routine.id) != nil
    }

    private static func isReachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    private static func exposure(
        capabilities: ResolvedCapabilities,
        advertisesTools: Bool,
        toolDefinitions: [MLXChatToolDefinition]?,
        settings: NativSettings,
        messages: [TraceMessageRef]
    ) -> RequestComposedPayload {
        var sections: [PromptSection] = []
        if !capabilities.tools.isEmpty {
            sections.append(PromptSection(
                origin: .toolGuide,
                label: NativSkill.builtInToolGuide.name,
                body: NativSkill.builtInToolGuide.instructions
            ))
        }
        for skill in capabilities.skills where !skill.instructions.isEmpty {
            sections.append(PromptSection(
                origin: .skill, label: skill.name, body: skill.instructions
            ))
        }

        let origins = Dictionary(
            capabilities.tools.map { ($0.definition.function.name, $0.provider) },
            uniquingKeysWith: { first, _ in first }
        )

        return RequestComposedPayload(
            systemSections: sections,
            tools: (toolDefinitions ?? []).map { definition in
                ToolDescriptor(
                    name: definition.function.name,
                    origin: traceOrigin(for: origins[definition.function.name]),
                    summary: definition.function.description,
                    parameters: try? TraceJSON(encoding: definition.function.parameters)
                )
            },
            parameters: SamplingParameters(
                temperature: settings.temperature,
                topP: settings.topP,
                topK: settings.topK,
                minP: settings.minP,
                maxTokens: settings.maxTokens,
                repetitionPenalty: settings.repetitionPenaltyEnabled
                    ? settings.repetitionPenalty
                    : nil,
                thinkingEnabled: settings.thinkingEnabled,
                thinkingBudget: settings.thinkingEnabled
                    && settings.thinkingBudgetEnabled
                    && !settings.speculativeDecodingActive
                    ? settings.thinkingBudget
                    : nil,
                toolChoice: toolDefinitions == nil ? nil : "auto",
                responseFormat: toolDefinitions == nil
                    ? settings.chatResponseFormat.flatMap { try? TraceJSON(encoding: $0) }
                    : nil
            ),
            messages: messages,
            advertisesTools: advertisesTools
        )
    }

    private static func traceOrigin(for provider: ScheduledTool.Provider?) -> ToolOrigin {
        switch provider {
        case .custom: .custom
        case .mcp: .mcp
        case .builtIn, nil: .builtIn
        }
    }

    private static func systemPrompt(for capabilities: ResolvedCapabilities) -> String {
        var instructions: [String] = []
        if !capabilities.tools.isEmpty {
            instructions.append(NativSkill.builtInToolGuide.instructions)
        }
        instructions.append(
            contentsOf: capabilities.skills.map(\.instructions).filter { !$0.isEmpty })
        return instructions.joined(separator: "\n\n")
    }

    private static func summarize(_ content: String) -> String {
        let firstLine =
            content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return firstLine.count > 140 ? String(firstLine.prefix(139)) + "…" : firstLine
    }

    private static func selectedMCPServers(
        for routine: Routine,
        settings: NativSettings,
        kitMCPServers: [MCPServerConfig]
    ) -> [MCPServerConfig] {
        var ids = Set(kitMCPServers.map(\.id))
        for capability in routine.capabilities {
            switch capability {
            case .kit:
                break
            case .mcpServer(let id):
                ids.insert(id)
            case .tool(let tool):
                if case .mcp(let id) = tool.provider {
                    ids.insert(id)
                }
            case .skill:
                break
            }
        }
        return settings.mcpServers.filter { ids.contains($0.id) && $0.isEnabled }
    }

    private static func resolveCapabilities(
        for routine: Routine,
        settings: NativSettings,
        mcpHost: MCPHostManager,
        kitResolution: NativKitRuntimeResolution
    ) -> ResolvedCapabilities {
        var toolsByName: [String: ResolvedTool] = [:]
        var conflictingToolNames = Set<String>()
        var skillsByID: [UUID: NativSkill] = [:]
        var unavailable = kitResolution.unavailableCapabilities
        var wholeMCPServers = Set(kitResolution.mcpServers.map(\.id))
        var selectedTools = kitResolution.tools

        for skill in kitResolution.skills {
            skillsByID[skill.id] = skill
        }

        func registerTool(
            _ definition: MLXChatToolDefinition,
            provider: ScheduledTool.Provider
        ) {
            let name = definition.function.name
            guard !conflictingToolNames.contains(name) else { return }
            if let existing = toolsByName[name], existing.provider != provider {
                toolsByName[name] = nil
                conflictingToolNames.insert(name)
                unavailable.append("Conflicting tools named \(name)")
                return
            }
            toolsByName[name] = ResolvedTool(definition: definition, provider: provider)
        }

        for capability in routine.capabilities {
            switch capability {
            case .kit:
                break
            case .mcpServer(let id):
                wholeMCPServers.insert(id)
            case .tool(let tool):
                selectedTools.append(tool)
            case .skill(let id):
                if let skill = settings.skills.first(where: { $0.id == id }) {
                    if skill.isEnabled {
                        skillsByID[id] = skill
                    } else {
                        unavailable.append(
                            skill.name.isEmpty ? "Skill \(id.uuidString)" : skill.name)
                    }
                } else {
                    unavailable.append("Skill \(id.uuidString)")
                }
            }
        }

        for serverID in wholeMCPServers {
            let definitions = mcpHost.toolDefinitions(forServer: serverID)
            if definitions.isEmpty {
                let configuredName = settings.mcpServers.first(where: { $0.id == serverID })?.name
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let name =
                    configuredName.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "MCP server \(serverID.uuidString)"
                unavailable.append(name)
            }
            for definition in definitions {
                let name = definition.function.name
                guard !settings.disabledToolNames.contains(name) else { continue }
                registerTool(definition, provider: .mcp(serverID))
            }
        }

        let nativeDefinitions = ChatToolRegistry.descriptors(canEditImage: false)
            .filter {
                $0.configuration != .fileWrite
                    && $0.definition.function.name != ChatTerminalToolRegistry.toolName
            }
            .map(\.definition)
            .filter { $0.function.name != ChatSwitchModelToolRegistry.toolName }
        for tool in selectedTools {
            switch tool.provider {
            case .builtIn:
                if let definition = nativeDefinitions.first(where: {
                    $0.function.name == tool.name
                }), !settings.disabledToolNames.contains(tool.name),
                    !ChatFileWriteToolRegistry.toolNames.contains(tool.name),
                    tool.name != ChatTerminalToolRegistry.toolName,
                    tool.name != ChatWebSearchToolRegistry.toolName
                        || ChatWebSearchToolRegistry.isConfigured(),
                    tool.name != ChatReadFileToolRegistry.toolName
                        || FileReadAccessPolicy.isConfigured(rootPath: settings.fileReadRootPath)
                {
                    registerTool(definition, provider: .builtIn)
                } else {
                    unavailable.append(
                        tool.name.isEmpty ? "Built-in tool" : tool.name
                    )
                }
            case .custom(let id):
                if let customTool = settings.customTools.first(where: { $0.id == id }),
                    !settings.disabledToolNames.contains(customTool.toolName),
                    let definition = try? customTool.definition()
                {
                    registerTool(definition, provider: .custom(id))
                } else {
                    unavailable.append(
                        tool.name.isEmpty ? "Custom tool \(id.uuidString)" : tool.name
                    )
                }
            case .mcp(let serverID):
                guard
                    let exposedName = mcpHost.tools(forServer: serverID)
                        .first(where: { $0.displayName == tool.name })?.name,
                    !settings.disabledToolNames.contains(exposedName),
                    let definition = mcpHost.toolDefinitions(forServer: serverID)
                        .first(where: { $0.function.name == exposedName })
                else {
                    unavailable.append(
                        tool.name.isEmpty ? "MCP tool on \(serverID.uuidString)" : tool.name
                    )
                    continue
                }
                registerTool(definition, provider: .mcp(serverID))
            }
        }

        return ResolvedCapabilities(
            tools: toolsByName.values.sorted {
                $0.definition.function.name < $1.definition.function.name
            },
            skills: skillsByID.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            unavailable: Array(Set(unavailable)).sorted()
        )
    }

    private func finishUnavailableCapabilities(
        _ unavailable: [String],
        run: inout RoutineRun,
        routine: Routine,
        sessionID: UUID,
        startedAt: Date,
        initialTranscript: [ChatTranscriptMessage]
    ) {
        let message = "Unavailable capabilities: \(unavailable.joined(separator: ", "))."
        saveRunChat(
            routine: routine,
            sessionID: sessionID,
            createdAt: startedAt,
            messages: initialTranscript + [ChatTranscriptMessage(role: .error, content: message)]
        )
        finish(&run, routine: routine, status: .failed, summary: message)
    }

    private static func normalizedToolCalls(_ calls: [MLXChatToolCall]) -> [MLXChatToolCall] {
        calls.enumerated().map { index, call in
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

private struct ResolvedCapabilities {
    let tools: [ResolvedTool]
    let skills: [NativSkill]
    let unavailable: [String]

    func tool(named name: String) -> ResolvedTool? {
        tools.first { $0.definition.function.name == name }
    }
}

private struct ResolvedTool {
    let definition: MLXChatToolDefinition
    let provider: ScheduledTool.Provider
}

private struct ScheduledExecutionResult {
    let finalContent: String
    let transcript: [ChatTranscriptMessage]
}

private struct ScheduledCompletionFailure: LocalizedError {
    let underlying: Error
    let transcript: [ChatTranscriptMessage]

    var errorDescription: String? {
        underlying.localizedDescription
    }
}

private struct ScheduledToolResult {
    let content: String
    let attachments: [ChatImageAttachment]
    let succeeded: Bool
}

private enum ScheduledToolExecutionError: LocalizedError {
    case notAllowed(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notAllowed(let name):
            "The scheduled task is not allowed to use \(name)."
        case .unavailable(let name):
            "\(name) is no longer available."
        }
    }
}

extension Notification.Name {
    static let routineDidSaveChatSession = Notification.Name("RoutineDidSaveChatSession")
}
