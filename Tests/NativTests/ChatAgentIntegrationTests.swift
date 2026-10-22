import XCTest
@testable import NativServerKit

@MainActor
final class ChatAgentIntegrationTests: XCTestCase {
    private func context() -> ChatToolExecutionContext {
        ChatToolExecutionContext(
            imageGenerationModelID: nil,
            baseURL: URL(string: "http://127.0.0.1:1")!, apiKey: nil,
            imageReferences: [], modelSearchPath: "", additionalModelSearchPaths: []
        )
    }

    private func completion(finish: String = "stop", calls: [MLXChatToolCall] = [], tokens: Int = 1) -> MLXChatCompletion {
        MLXChatCompletion(
            model: "worker", content: "worker result", reasoningContent: nil,
            toolCalls: calls, finishReason: finish,
            usage: MLXChatUsage(promptTokens: 0, completionTokens: tokens, totalTokens: tokens,
                               promptTokensPerSecond: nil, decodeTokensPerSecond: nil, peakMemoryGB: nil),
            requestElapsedSeconds: nil
        )
    }

    func testPreparationInheritsScopeButNotApprovals() async throws {
        var context = context()
        context.settings = NativSettings(languageModelID: "parent")
        context.fileReadRootPath = "/project"
        context.fileWriteRootPath = "/project"
        context.fileReadTracker = ChatReadFileTracker()
        context.fileSearchTracker = ChatSearchFilesTracker()
        context.fileWriteApprovalGranted = true
        context.terminalApprovalGranted = true
        context.subAgentToolDefinitions = [ChatReadFileToolRegistry.definition]
        context.subAgentSystemPrompt = "Project instructions"
        let prepared = try await ChatSpawnAgentToolExecutor().prepare(
            call: MLXChatToolCall(id: "spawn", function: MLXChatFunctionCall(
                name: "spawn_agent", arguments: #"{"task":"inspect"}"#)), context: context)
        XCTAssertEqual(prepared.modelID, "parent")
        XCTAssertEqual(prepared.subAgentContext.fileReadRootPath, "/project")
        XCTAssertEqual(prepared.subAgentContext.fileWriteRootPath, "/project")
        XCTAssertTrue(prepared.subAgentContext.fileReadTracker === context.fileReadTracker)
        XCTAssertTrue(prepared.subAgentContext.fileSearchTracker === context.fileSearchTracker)
        XCTAssertEqual(prepared.subAgentContext.subAgentSystemPrompt, "Project instructions")
        XCTAssertFalse(prepared.subAgentContext.fileWriteApprovalGranted)
        XCTAssertFalse(prepared.subAgentContext.terminalApprovalGranted)
        XCTAssertNil(prepared.subAgentContext.workAction)
        XCTAssertNil(prepared.subAgentContext.settings)
    }

    func testToolListPreservesParentRestrictionsAndExcludesApprovalTools() {
        var context = context()
        context.subAgentToolDefinitions = ChatToolRegistry.definitions(canEditImage: true)
        var settings = NativSettings()
        settings.disabledToolNames = [ChatSystemMonitorToolRegistry.toolName]
        let names = Set(ChatAgentLoop.subAgentToolDefinitions(settings: settings, canEditImage: true, context: context).map { $0.function.name })
        for forbidden in ["spawn_agent", "list_agents", "check_agent", "steer_agent", "switch_model",
                          ChatWorkToolRegistry.toolName, ChatTerminalToolRegistry.toolName,
                          ChatImageToolRegistry.generateToolName, ChatSystemMonitorToolRegistry.toolName] {
            XCTAssertFalse(names.contains(forbidden), forbidden)
        }
        context.subAgentToolDefinitions = []
        XCTAssertTrue(ChatAgentLoop.subAgentToolDefinitions(settings: settings, canEditImage: false, context: context).isEmpty)
    }

    func testUnadvertisedToolCannotExecuteEvenWhenModelCallsIt() async {
        let outcome = await ChatAgentLoop.executeToolCall(
            MLXChatToolCall(id: "x", function: MLXChatFunctionCall(name: "list_agents", arguments: "{}")),
            customTools: [], allowedToolNames: [], context: context())
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.content.contains("not available"))
    }

    func testRegistryIsScopedToConversation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let viewModel = ChatViewModel(sessionDirectory: directory)
        let firstID = UUID(), secondID = UUID()
        let first = viewModel.agentRegistry(for: firstID)
        let second = viewModel.agentRegistry(for: secondID)
        XCTAssertTrue(first === viewModel.agentRegistry(for: firstID))
        let id = first.register(task: "private task", modelID: "worker")
        XCTAssertTrue(second.allRecords().isEmpty)
        XCTAssertNil(second.record(for: id))
        XCTAssertFalse(second.queueSteerMessage("change task", for: id))
    }

    func testSelectedModelAndOutputBudgetReachRequest() async throws {
        var context = context()
        context.subAgentToolDefinitions = []
        let result = try await ChatAgentLoop.run(
            messages: [MLXChatMessage(role: "user", content: "task")], modelID: "small-worker",
            settings: NativSettings(maxTokens: 2048), canEditImage: false, context: context,
            limits: .init(maxTurns: 2, maxTokens: 100, maxWallTimeSeconds: 10),
            completionHandler: { request in
                XCTAssertEqual(request.model, "small-worker")
                XCTAssertEqual(request.maxTokens, 100)
                return self.completion()
            })
        XCTAssertEqual(result.completion.content, "worker result")
        XCTAssertNil(result.stopReason)
    }

    func testOutputTruncationIsNotReportedAsSuccessfulCompletion() async throws {
        let result = try await ChatAgentLoop.run(
            messages: [], modelID: "worker", settings: NativSettings(), canEditImage: false,
            context: context(), completionHandler: { _ in self.completion(finish: "length") })
        XCTAssertEqual(result.stopReason, .tokenLimit)
    }

    func testTurnLimitDoesNotMakeAnExtraInferenceRequest() async throws {
        var calls = 0
        let tool = MLXChatToolCall(id: "invalid", function: MLXChatFunctionCall(name: "not_advertised", arguments: "{}"))
        let result = try await ChatAgentLoop.run(
            messages: [], modelID: "worker", settings: NativSettings(), canEditImage: false,
            context: context(), limits: .init(maxTurns: 1, maxTokens: 100, maxWallTimeSeconds: 10),
            completionHandler: { _ in
                calls += 1
                return self.completion(finish: "tool_calls", calls: [tool])
            })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.stopReason, .turnLimit)
    }

    func testDeadlineCancelsAnInFlightWorker() async {
        var cancelled = false
        do {
            _ = try await ChatAgentLoop.withTimeout(seconds: 0.02) {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { cancelled = true; throw error }
                return ChatAgentLoopResult(completion: self.completion(), stopReason: nil)
            }
            XCTFail("Expected timeout")
        } catch ChatAgentLoopError.timedOut {
            XCTAssertTrue(cancelled)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testFinishedRegistryRejectsLateTaskRegistration() {
        let registry = ChatAgentRegistry()
        let id = registry.register(task: "done", modelID: nil)
        registry.complete(id, result: "done")
        let task = Task<Void, Never> {}
        registry.setTask(task, for: id)
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(registry.record(for: id)?.status, .completed)
    }
    func testSameModelWorkersShareSlotAndDifferentModelWaits() async throws {
        let gate = ChatAgentModelGate()
        let endpoint = URL(string: "http://localhost:1234")!
        try await gate.acquire(modelID: "large", endpoint: endpoint)
        try await gate.acquire(modelID: "large", endpoint: endpoint)
        var entered = false
        let worker = Task {
            try await gate.acquire(modelID: "small", endpoint: endpoint)
            entered = true
            gate.release(endpoint: endpoint)
        }
        await Task.yield()
        XCTAssertFalse(entered)
        gate.release(endpoint: endpoint)
        await Task.yield()
        XCTAssertFalse(entered)
        gate.release(endpoint: endpoint)
        try await worker.value
        XCTAssertTrue(entered)
    }

    func testCancelledModelWaiterDoesNotOccupySlot() async throws {
        let gate = ChatAgentModelGate()
        let endpoint = URL(string: "http://localhost:1234")!
        try await gate.acquire(modelID: "large", endpoint: endpoint)
        let waiter = Task { try await gate.acquire(modelID: "small", endpoint: endpoint) }
        await Task.yield()
        waiter.cancel()
        do { try await waiter.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        gate.release(endpoint: endpoint)
        try await gate.acquire(modelID: "third", endpoint: endpoint)
        gate.release(endpoint: endpoint)
    }

    func testCancelledAndLimitedWorkersAreNotShownAsSuccess() {
        let registry = ChatAgentRegistry()
        let id = registry.register(task: "task", modelID: nil)
        registry.stop(id, reason: .cancelled, partialResult: nil)
        XCTAssertEqual(registry.record(for: id)?.toolStatus, .cancelled)
        let limited = registry.register(task: "task", modelID: nil)
        registry.stop(limited, reason: .tokenLimit, partialResult: "partial")
        XCTAssertEqual(registry.record(for: limited)?.toolStatus, .failed)
    }

}
