import XCTest
@testable import NativServerKit

@MainActor
private final class RuntimeMCPHost: ChatToolMCPHost {
    let server = MCPServerConfig(name: "Test", command: "test-mcp")
    var definitions = [MLXChatToolDefinition(function: MLXChatFunctionDefinition(
        name: "mcp__test__history",
        description: "Read repository commit history",
        parameters: .object(["type": .string("object")])
    ))]
    var calls: [String] = []
    var operation: (() async throws -> String)?

    func toolDefinitions(forServer id: UUID) -> [MLXChatToolDefinition] {
        id == server.id ? definitions : []
    }

    func callTool(named name: String, argumentsJSON: String?) async throws -> String {
        calls.append(name)
        return try await operation?() ?? #"{"commits":["first"]}"#
    }
}

@MainActor
final class ChatToolRuntimeTests: XCTestCase {
    private let toolName = "mcp__test__history"

    func testOldRequestCannotExecuteAfterToolIsOff() async throws {
        let host = RuntimeMCPHost()
        var settings = settings(host: host, mode: .on)
        let runtime = ChatToolRuntime(settings: settings)
        let request = prepare(runtime, host: host)
        settings.setToolExposureMode(.off, toolName: toolName)
        runtime.updateSettings(settings)

        await assertUnavailable {
            try await runtime.execute(call: self.call(), request: request, context: self.context(), mcpHost: host)
        }
        XCTAssertTrue(host.calls.isEmpty)
        XCTAssertFalse(prepare(runtime, host: host).definitions.contains { $0.function.name == toolName })
    }

    func testServerOffOverridesIndividualToolOn() async throws {
        let host = RuntimeMCPHost()
        var settings = settings(host: host, mode: .automatic)
        settings.setToolExposureMode(.on, toolName: toolName)
        let runtime = ChatToolRuntime(settings: settings)
        let request = prepare(runtime, host: host)
        settings.setMCPServerExposureMode(.off, serverID: host.server.id)
        runtime.updateSettings(settings)

        await assertUnavailable {
            try await runtime.execute(call: self.call(), request: request, context: self.context(), mcpHost: host)
        }
        XCTAssertTrue(host.calls.isEmpty)
    }

    func testDiscoveryRequiresANewModelRequestBeforeExecution() async throws {
        let host = RuntimeMCPHost()
        let runtime = ChatToolRuntime(settings: settings(host: host, mode: .automatic))
        let first = prepare(runtime, host: host)
        let discovery = try await runtime.execute(
            call: call(name: "tool_search", arguments: #"{"query":"repository history"}"#),
            request: first, context: context(), mcpHost: host
        )
        XCTAssertEqual(discovery.activatedToolNames, [toolName])
        await assertUnavailable {
            try await runtime.execute(call: self.call(), request: first, context: self.context(), mcpHost: host)
        }
        XCTAssertTrue(host.calls.isEmpty)

        let second = prepare(runtime, host: host, activated: discovery.activatedToolNames)
        let response = try await runtime.execute(call: call(), request: second, context: context(), mcpHost: host)
        XCTAssertTrue(response.content.contains("first"))
        XCTAssertEqual(host.calls, [toolName])
    }

    func testChangedSchemaCannotExecuteThroughAnOldRequest() async throws {
        let host = RuntimeMCPHost()
        let runtime = ChatToolRuntime(settings: settings(host: host, mode: .on))
        let request = prepare(runtime, host: host)
        host.definitions = [MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName, description: "A different operation", parameters: .object([:])
        ))]
        await assertUnavailable {
            try await runtime.execute(call: self.call(), request: request, context: self.context(), mcpHost: host)
        }
        XCTAssertTrue(host.calls.isEmpty)
    }

    func testOffCancelsAnActiveExecutionWithoutCancellingOtherCalls() async throws {
        let host = RuntimeMCPHost()
        var settings = settings(host: host, mode: .on)
        let runtime = ChatToolRuntime(settings: settings)
        let request = prepare(runtime, host: host)
        host.operation = { try await Task.sleep(for: .seconds(30)); return "unexpected" }
        let execution = Task {
            try await runtime.execute(call: call(), request: request, context: context(), mcpHost: host)
        }
        await waitUntil { !host.calls.isEmpty }
        settings.setToolExposureMode(.off, toolName: toolName)
        runtime.updateSettings(settings)
        settings.setToolExposureMode(.on, toolName: toolName)
        runtime.updateSettings(settings)
        await assertUnavailable { try await execution.value }

        host.operation = nil
        _ = try await runtime.execute(call: call(), request: prepare(runtime, host: host), context: context(), mcpHost: host)
        XCTAssertEqual(host.calls.count, 2)
    }

    func testOffInvalidatesPendingConsentAndLateApproval() async throws {
        let custom = try CustomTool.make(
            name: "Consent Test", summary: "Test", kind: .script,
            script: "exit 99", parametersJSON: CustomTool.defaultParametersJSON
        )
        var settings = NativSettings(customTools: [custom])
        settings.setToolExposureMode(.on, toolName: custom.toolName)
        let runtime = ChatToolRuntime(settings: settings)
        let request = prepare(runtime)
        let gate = ChatToolConsentGate()
        let id = UUID()
        let execution = Task {
            try await runtime.execute(
                call: call(name: custom.toolName), request: request, context: context(),
                requestApproval: { await gate.awaitDecision(for: id) }
            )
        }
        await waitUntil { gate.pendingCount == 1 }
        settings.setToolExposureMode(.off, toolName: custom.toolName)
        runtime.updateSettings(settings)
        gate.confirm(id)
        await assertUnavailable { try await execution.value }
        XCTAssertEqual(gate.pendingCount, 0)
    }

    func testCallerCancellationReachesExecutor() async throws {
        let host = RuntimeMCPHost()
        let runtime = ChatToolRuntime(settings: settings(host: host, mode: .on))
        let request = prepare(runtime, host: host)
        host.operation = { try await Task.sleep(for: .seconds(30)); return "unexpected" }
        let execution = Task {
            try await runtime.execute(call: call(), request: request, context: context(), mcpHost: host)
        }
        await waitUntil { !host.calls.isEmpty }
        execution.cancel()
        do {
            _ = try await execution.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDuplicateNamesAreUnavailableInsteadOfRoutingToAnArbitraryTool() {
        let host = RuntimeMCPHost()
        host.definitions.append(host.definitions[0])
        let runtime = ChatToolRuntime(settings: settings(host: host, mode: .on))
        XCTAssertFalse(prepare(runtime, host: host).definitions.contains { $0.function.name == toolName })
    }

    func testTerminalCannotBypassApprovalWithAnOldContext() async throws {
        let runtime = ChatToolRuntime()
        var context = context()
        context.terminalApprovalGranted = true
        context.terminalToolDependencies = ChatTerminalToolDependencies(run: { _ in
            XCTFail("Declined terminal command executed")
            throw CancellationError()
        })
        do {
            _ = try await runtime.execute(
                call: call(name: "terminal", arguments: #"{"command":"pwd"}"#),
                request: prepare(runtime), context: context
            )
            XCTFail("Expected fresh approval")
        } catch ChatToolExecutionError.declined {} catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRestrictedRequestCannotExecuteAnUnselectedOnTool() async {
        let host = RuntimeMCPHost()
        let runtime = ChatToolRuntime(settings: settings(host: host, mode: .on))
        let request = prepare(runtime, host: host).restricted(to: [host.definitions[0]])
        XCTAssertEqual(request.definitions.map(\.function.name), [toolName])
        await assertUnavailable {
            try await runtime.execute(
                call: self.call(name: "terminal", arguments: #"{"command":"pwd"}"#),
                request: request, context: self.context(), mcpHost: host,
                requestApproval: { XCTFail("Unselected tool requested approval"); return true }
            )
        }
    }

    func testSettingsChangeDuringApprovalCannotAuthorizeAnEditedCustomTool() async throws {
        var custom = try CustomTool.make(
            name: "Edit During Approval", summary: "Test", kind: .script,
            script: "exit 99", parametersJSON: CustomTool.defaultParametersJSON
        )
        var settings = NativSettings(customTools: [custom])
        settings.setToolExposureMode(.on, toolName: custom.toolName)
        let runtime = ChatToolRuntime(settings: settings)
        let request = prepare(runtime)
        await assertUnavailable {
            try await runtime.execute(
                call: self.call(name: custom.toolName), request: request, context: self.context(),
                requestApproval: {
                    custom.script = "exit 98"
                    settings.customTools = [custom]
                    runtime.updateSettings(settings)
                    return true
                }
            )
        }
    }

    private func settings(host: RuntimeMCPHost, mode: ToolExposureMode) -> NativSettings {
        var settings = NativSettings(mcpServers: [host.server])
        settings.setMCPServerExposureMode(mode, serverID: host.server.id)
        return settings
    }

    private func prepare(
        _ runtime: ChatToolRuntime, host: RuntimeMCPHost? = nil, activated: Set<String> = []
    ) -> ChatToolRequest {
        runtime.prepareRequest(
            scope: .standalone(settings: NativSettings()), canEditImage: false,
            activatedToolNames: activated, mcpHost: host
        )
    }

    private func call(name: String = "mcp__test__history", arguments: String = "{}") -> MLXChatToolCall {
        MLXChatToolCall(id: UUID().uuidString, function: MLXChatFunctionCall(name: name, arguments: arguments))
    }

    private func context() -> ChatToolExecutionContext {
        ChatToolExecutionContext(
            imageGenerationModelID: nil, baseURL: URL(string: "http://127.0.0.1:1")!, apiKey: nil,
            imageReferences: [], modelSearchPath: "", additionalModelSearchPaths: []
        )
    }

    private func assertUnavailable(_ operation: () async throws -> ChatToolExecutionOutcome) async {
        do {
            _ = try await operation()
            XCTFail("An unavailable tool executed")
        } catch is ChatToolAccessError {} catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Execution did not reach the expected state")
    }
}
