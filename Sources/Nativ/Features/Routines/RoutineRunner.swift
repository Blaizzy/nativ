import Foundation
import NativServerKit

@MainActor
final class RoutineRunner {
    private struct CompletionResult {
        let completion: MLXChatCompletion
        let transcript: [ChatTranscriptMessage]
    }

    private struct ToolFailure: Encodable {
        let ok = false
        let error: String
    }

    private let model: NativModel
    private let store: RoutineStore
    private let sessionStore: ChatSessionStore
    private let kitStore: NativKitStore
    private let mcpHost: MCPHostManager

    var onRunCompleted: ((Routine, RoutineRun) -> Void)?

    private var queue: [(Routine, RoutineRunSource)] = []
    private var isExecuting = false

    init(
        model: NativModel,
        store: RoutineStore,
        sessionStore: ChatSessionStore,
        kitStore: NativKitStore,
        mcpHost: MCPHostManager
    ) {
        self.model = model
        self.store = store
        self.sessionStore = sessionStore
        self.kitStore = kitStore
        self.mcpHost = mcpHost
    }

    func run(_ routine: Routine, source: RoutineRunSource) {
        queue.append((routine, source))
        drain()
    }

    private func drain() {
        guard !isExecuting, !queue.isEmpty else { return }
        isExecuting = true
        let (routine, source) = queue.removeFirst()
        Task { @MainActor in
            await execute(routine, source: source)
            isExecuting = false
            drain()
        }
    }

    private func execute(_ routine: Routine, source: RoutineRunSource) async {
        var run = RoutineRun(routineID: routine.id, source: source, status: .running)
        store.recordRun(run)

        let settings = model.settings.normalized()
        let kitPlan: NativKitExecutionPlan?
        do {
            kitPlan = try await kitExecutionPlan(for: routine, settings: settings)
        } catch {
            finish(&run, routine: routine, status: .failed, summary: error.localizedDescription)
            return
        }

        if !model.isRunning { model.startServer() }
        await waitForServer()

        guard let baseURL = model.activeServerBaseURL else {
            finish(&run, routine: routine, status: .failed, summary: "The Nativ server isn’t running.")
            return
        }

        var messages: [MLXChatMessage] = []
        let systemPrompt = systemPrompt(settings: settings, kitPlan: kitPlan)
        if !systemPrompt.isEmpty {
            messages.append(MLXChatMessage(role: "system", content: systemPrompt))
        }
        messages.append(MLXChatMessage(role: "user", content: routine.instructions))

        do {
            let result = try await complete(
                routine: routine,
                messages: messages,
                settings: settings,
                baseURL: baseURL,
                kitPlan: kitPlan
            )
            let sessionID = appendRun(routine: routine, transcript: result.transcript)
            NotificationCenter.default.post(name: .routineDidSaveChatSession, object: nil)
            run.sessionID = sessionID
            finish(
                &run,
                routine: routine,
                status: .succeeded,
                summary: Self.summarize(result.completion.content)
            )
        } catch {
            finish(&run, routine: routine, status: .failed, summary: error.localizedDescription)
        }
    }

    private func kitExecutionPlan(
        for routine: Routine,
        settings: NativSettings
    ) async throws -> NativKitExecutionPlan? {
        guard let kitID = routine.kitID else { return nil }
        let kit = try RoutineKitResolver.resolve(id: kitID, from: kitStore.allKits)
        await mcpHost.ensureReloaded(servers: settings.mcpServers)
        let plan = NativKitCapabilityInventory(settings: settings, host: mcpHost)
            .plan(for: kit, context: .routine, canEditImage: false)
        guard plan.isReady else {
            throw NativKitExecutionError.notReady(kit.name, plan.issues)
        }
        return plan
    }

    private func complete(
        routine: Routine,
        messages initialMessages: [MLXChatMessage],
        settings: NativSettings,
        baseURL: URL,
        kitPlan: NativKitExecutionPlan?
    ) async throws -> CompletionResult {
        let client = NativChatClient(baseURL: baseURL, apiKey: settings.serverAPIKey)
        var messages = initialMessages
        var transcript = [ChatTranscriptMessage(role: .user, content: routine.instructions)]
        var toolRound = 0

        while true {
            let advertisesTools = ChatToolRoundGate.advertisesTools(atRound: toolRound)
            let tools = advertisesTools ? toolDefinitions(for: kitPlan) : []
            let request = MLXChatCompletionRequest(
                model: routine.modelID,
                messages: messages,
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
                tools: tools.isEmpty ? nil : tools,
                toolChoice: tools.isEmpty ? nil : "auto"
            )
            let completion = try await client.completeChat(request)
            let calls = normalizedToolCalls(completion.toolCalls)
            messages.append(MLXChatMessage(
                role: "assistant",
                content: completion.content,
                reasoningContent: completion.reasoningContent,
                toolCalls: calls.isEmpty ? nil : calls
            ))
            transcript.append(ChatTranscriptMessage(
                role: .assistant,
                content: completion.content,
                reasoningContent: completion.reasoningContent ?? "",
                modelID: routine.modelID,
                toolCalls: calls
            ))

            guard advertisesTools, !calls.isEmpty else {
                return CompletionResult(completion: completion, transcript: transcript)
            }

            for call in calls {
                let output: String
                let status: ChatTranscriptMessage.ToolStatus
                do {
                    output = try await execute(
                        call: call,
                        settings: settings,
                        baseURL: baseURL,
                        kitPlan: kitPlan
                    )
                    status = .succeeded
                } catch {
                    output = Self.toolFailurePayload(error)
                    status = .failed
                }
                let name = call.function?.name
                messages.append(MLXChatMessage(
                    role: "tool",
                    content: output,
                    toolCallID: call.id,
                    name: name
                ))
                transcript.append(ChatTranscriptMessage(
                    role: .tool,
                    content: output,
                    toolCallID: call.id,
                    toolName: name,
                    toolStatus: status,
                    toolArguments: call.function?.arguments
                ))
            }
            toolRound += 1
        }
    }

    private func execute(
        call: MLXChatToolCall,
        settings: NativSettings,
        baseURL: URL,
        kitPlan: NativKitExecutionPlan?
    ) async throws -> String {
        guard let name = call.function?.name,
              kitPlan?.allowedToolNames.contains(name) == true
        else {
            throw RoutineKitError.invalidToolCall
        }
        if kitPlan?.mcpToolsByName[name] != nil {
            return try await mcpHost.callTool(named: name, argumentsJSON: call.function?.arguments)
        }
        if let customTool = kitPlan?.customToolsByName[name] {
            return try await CustomToolExecutor.execute(
                customTool,
                argumentsJSON: call.function?.arguments
            )
        }
        let outcome = try await ChatToolDispatcher.execute(
            call: call,
            context: ChatToolExecutionContext(
                imageGenerationModelID: settings.imageGenerationModelID,
                baseURL: baseURL,
                apiKey: settings.serverAPIKey,
                imageReferences: [],
                modelSearchPath: settings.expandedModelSearchPath,
                additionalModelSearchPaths: settings.additionalModelSearchPaths
            )
        )
        return outcome.content
    }

    private func toolDefinitions(for kitPlan: NativKitExecutionPlan?) -> [MLXChatToolDefinition] {
        kitPlan?.toolDefinitions ?? []
    }

    private func systemPrompt(
        settings: NativSettings,
        kitPlan: NativKitExecutionPlan?
    ) -> String {
        var parts: [String] = []
        if !settings.systemPrompt.isEmpty { parts.append(settings.systemPrompt) }
        let tools = toolDefinitions(for: kitPlan)
        if !tools.isEmpty { parts.append(NativSkill.builtInToolGuide.instructions) }
        parts.append(contentsOf: kitPlan?.skills.map(\.instructions).filter { !$0.isEmpty } ?? [])
        return parts.joined(separator: "\n\n")
    }

    private func appendRun(routine: Routine, transcript: [ChatTranscriptMessage]) -> UUID {
        if let sessionID = routine.sourceSessionID,
           var session = sessionStore.loadSession(id: sessionID) {
            session.messages.append(contentsOf: transcript)
            session.updatedAt = Date()
            sessionStore.saveSession(session)
            return sessionID
        }
        let now = Date()
        let session = ChatSession(
            id: UUID(),
            title: routine.name.isEmpty ? "Routine" : routine.name,
            customTitle: nil,
            createdAt: now,
            updatedAt: now,
            messages: transcript,
            pinned: nil,
            pinnedOrder: nil,
            sessionOrder: nil,
            folderID: nil,
            kitID: routine.kitID
        )
        sessionStore.saveSession(session)
        return session.id
    }

    private func finish(
        _ run: inout RoutineRun,
        routine: Routine,
        status: RoutineRunStatus,
        summary: String
    ) {
        run.status = status
        run.finishedAt = Date()
        run.resultSummary = summary
        store.recordRun(run)
        onRunCompleted?(routine, run)
    }

    private func waitForServer(timeout: TimeInterval = 120) async {
        let deadline = Date().addingTimeInterval(timeout)
        while model.activeServerBaseURL == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard let baseURL = model.activeServerBaseURL else { return }
        let healthURL = baseURL.appendingPathComponent("v1/models")
        while Date() < deadline {
            if await Self.isReachable(healthURL) { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
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

    private func normalizedToolCalls(_ calls: [MLXChatToolCall]) -> [MLXChatToolCall] {
        calls.enumerated().map { index, call in
            var call = call
            if call.id?.isEmpty != false { call.id = "routine-tool-\(index)-\(UUID().uuidString)" }
            return call
        }
    }

    private static func toolFailurePayload(_ error: Error) -> String {
        guard let data = try? JSONEncoder().encode(ToolFailure(error: error.localizedDescription)) else {
            return #"{"ok":false,"error":"Tool execution failed."}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func summarize(_ content: String) -> String {
        let firstLine = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return firstLine.count > 140 ? String(firstLine.prefix(139)) + "…" : firstLine
    }
}

extension Notification.Name {
    static let routineDidSaveChatSession = Notification.Name("RoutineDidSaveChatSession")
}
