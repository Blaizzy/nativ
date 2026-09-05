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

    func testProjectEssentialsAreDirectWithoutStandaloneFolders() throws {
        for settings in [NativSettings(), try JSONDecoder().decode(NativSettings.self, from: Data("{}".utf8))] {
            let runtime = ChatToolRuntime(settings: settings)
            let request = prepareProject(runtime)
            XCTAssertTrue(ChatToolScope.projectToolNames.isSubset(of: Set(request.definitions.map(\.function.name))))
            XCTAssertNil(settings.fileReadRootPath)
            XCTAssertNil(settings.fileWriteRootPath)
        }
    }

    func testProjectPreservesExplicitModesAcrossSettingsRoundTrip() async throws {
        var settings = NativSettings()
        settings.setToolExposureMode(.off, toolName: "terminal")
        settings.setToolExposureMode(.automatic, toolName: "write_file")
        settings = try JSONDecoder().decode(NativSettings.self, from: JSONEncoder().encode(settings))
        let runtime = ChatToolRuntime(settings: settings)
        let first = prepareProject(runtime)
        let names = Set(first.definitions.map(\.function.name))
        XCTAssertFalse(names.contains("terminal"))
        XCTAssertFalse(names.contains("write_file"))
        XCTAssertTrue(names.contains("read_file"))

        let discovery = try await runtime.execute(
            call: call(name: "tool_search", arguments: #"{"query":"write_file"}"#),
            request: first, context: context()
        )
        XCTAssertTrue(discovery.activatedToolNames.contains("write_file"))
        let next = prepareProject(runtime, activated: discovery.activatedToolNames)
        XCTAssertTrue(next.definitions.contains { $0.function.name == "write_file" })
        await assertUnavailable {
            try await runtime.execute(
                call: self.call(name: "terminal", arguments: #"{"command":"pwd"}"#),
                request: next, context: self.context(),
                requestApproval: { XCTFail("Off tool requested approval"); return true }
            )
        }
    }

    func testProjectToolsRequireBothFolderAndProjectPermission() async {
        var settings = NativSettings()
        settings.projectToolsEnabled = false
        for request in [prepareProject(ChatToolRuntime(), rootPath: nil), prepareProject(ChatToolRuntime(settings: settings))] {
            XCTAssertTrue(ChatToolScope.projectToolNames.isDisjoint(with: Set(request.definitions.map(\.function.name))))
        }
        let runtime = ChatToolRuntime()
        let request = prepareProject(runtime)
        runtime.updateSettings(settings)
        await assertUnavailable {
            try await runtime.execute(
                call: self.call(name: "terminal", arguments: #"{"command":"pwd"}"#),
                request: request, context: self.context(),
                requestApproval: { XCTFail("Disabled project requested approval"); return true }
            )
        }
    }

    func testProjectWriteUsesItsRootWithoutStandaloneFileAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ChatToolRuntime()
        let request = prepareProject(runtime, rootPath: root.path)
        let result = try await runtime.execute(
            call: call(name: "write_file", arguments: #"{"path":"index.html","content":"<html>Test</html>"}"#),
            request: request, context: context(), requestApproval: { true }
        )
        XCTAssertTrue(result.content.contains("\"ok\":true"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("index.html"), encoding: .utf8), "<html>Test</html>")
    }

    func testDiscoveryPointsToAlreadyProvidedToolsWithoutActivatingThem() async throws {
        let runtime = ChatToolRuntime()
        let request = prepareProject(runtime)
        for query in ["create HTML file with game code", "file creation HTML file", "terminal"] {
            let result = try await runtime.execute(
                call: call(name: "tool_search", arguments: #"{"query":"\#(query)"}"#),
                request: request, context: context()
            )
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
            let available = try XCTUnwrap(payload["already_available"] as? [String])
            XCTAssertTrue(available.contains(query == "terminal" ? "terminal" : "write_file"))
            XCTAssertTrue(result.activatedToolNames.isEmpty)
            XCTAssertFalse(result.content.contains("generate_image"))
        }
    }

    func testUnknownNamesDoNotAliasToolsOrReportDisabledPermissions() async {
        let runtime = ChatToolRuntime()
        let request = prepareProject(runtime)
        for _ in 0..<2 {
            do {
                _ = try await runtime.execute(
                    call: call(name: "bash", arguments: #"{"command":"pwd"}"#),
                    request: request, context: context(),
                    requestApproval: { XCTFail("Unknown tool requested approval"); return true }
                )
                XCTFail("Unknown tool executed")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Unknown tool"))
                XCTAssertFalse(error.localizedDescription.contains("Off"))
            }
        }
    }

    func testAccessErrorsDistinguishDiscoveryOffAndMissingConfiguration() async {
        var settings = NativSettings()
        settings.setToolExposureMode(.automatic, toolName: "terminal")
        let runtime = ChatToolRuntime(settings: settings)
        let request = prepare(runtime)
        do {
            _ = try await runtime.execute(call: call(name: "terminal"), request: request, context: context())
            XCTFail("Undiscovered tool executed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("tool_search"))
            XCTAssertFalse(error.localizedDescription.contains("Off"))
        }
        settings.setToolExposureMode(.off, toolName: "tool_search")
        runtime.updateSettings(settings)
        do {
            _ = try await runtime.execute(call: call(name: "terminal"), request: request, context: context())
            XCTFail("Undiscovered tool executed")
        } catch {
            XCTAssertEqual(error as? ChatToolAccessError, .notAdvertised("terminal"))
        }
        settings.setToolExposureMode(.off, toolName: "terminal")
        runtime.updateSettings(settings)
        do {
            _ = try await runtime.execute(call: call(name: "terminal"), request: request, context: context())
            XCTFail("Disabled tool executed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Off"))
            XCTAssertFalse(error.localizedDescription.contains("discovered"))
        }
        do {
            _ = try await runtime.execute(call: call(name: "read_file"), request: request, context: context())
            XCTFail("Unconfigured tool executed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unavailable"))
            XCTAssertFalse(error.localizedDescription.contains("Off"))
            XCTAssertFalse(error.localizedDescription.contains("Unknown"))
        }
    }

    func testProjectSwitchRevokesPendingTerminalApproval() async {
        var settings = NativSettings()
        let runtime = ChatToolRuntime(settings: settings)
        let request = prepareProject(runtime)
        let gate = ChatToolConsentGate()
        let id = UUID()
        let execution = Task {
            try await runtime.execute(
                call: call(name: "terminal", arguments: #"{"command":"pwd"}"#),
                request: request, context: context(), requestApproval: { await gate.awaitDecision(for: id) }
            )
        }
        await waitUntil { gate.pendingCount == 1 }
        settings.projectToolsEnabled = false
        runtime.updateSettings(settings)
        gate.confirm(id)
        await assertUnavailable { try await execution.value }
        XCTAssertEqual(gate.pendingCount, 0)
    }

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

    func testUnrelatedSettingsDoNotCancelAnActiveTool() async throws {
        let host = RuntimeMCPHost()
        var settings = settings(host: host, mode: .on)
        let runtime = ChatToolRuntime(settings: settings)
        let request = prepare(runtime, host: host)
        let gate = ChatToolConsentGate()
        let id = UUID()
        host.operation = {
            let approved = await gate.awaitDecision(for: id)
            try Task.checkCancellation()
            return approved ? "complete" : "unexpected"
        }
        let execution = Task {
            try await runtime.execute(call: call(), request: request, context: context(), mcpHost: host)
        }
        await waitUntil { gate.pendingCount == 1 }
        settings.setToolExposureMode(.off, toolName: "get_system_stats")
        settings.fileReadRootPath = FileManager.default.temporaryDirectory.path
        runtime.updateSettings(settings)
        gate.confirm(id)
        let result = try await execution.value
        XCTAssertEqual(result.content, "complete")
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
        let request = runtime.prepareRequest(allowing: [host.definitions[0]], mcpHost: host)
        XCTAssertEqual(request.definitions.map(\.function.name), [toolName])
        await assertUnavailable {
            try await runtime.execute(
                call: self.call(name: "terminal", arguments: #"{"command":"pwd"}"#),
                request: request, context: self.context(), mcpHost: host,
                requestApproval: { XCTFail("Unselected tool requested approval"); return true }
            )
        }
    }

    func testRestrictedDiscoveryDoesNotExposeUnselectedCapabilities() async throws {
        let host = RuntimeMCPHost()
        let runtime = ChatToolRuntime(settings: settings(host: host, mode: .automatic))
        let request = runtime.prepareRequest(allowing: [ChatToolDiscoveryRegistry.definition], mcpHost: host)
        let result = try await runtime.execute(
            call: call(name: "tool_search", arguments: #"{"query":"repository history"}"#),
            request: request, context: context(), mcpHost: host
        )
        XCTAssertTrue(result.activatedToolNames.isEmpty)
        XCTAssertFalse(result.content.contains(toolName))
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

    func testFollowUpReusesOnlySuccessfulToolsFromThePreviousTurn() {
        let history = [
            ChatTranscriptMessage(role: .user, content: "Earlier task"),
            ChatTranscriptMessage(role: .tool, content: "old", toolName: "old_tool", toolStatus: .succeeded),
            ChatTranscriptMessage(role: .user, content: "Read history"),
            ChatTranscriptMessage(role: .tool, content: "found", toolName: "tool_search", toolStatus: .succeeded),
            ChatTranscriptMessage(role: .tool, content: "history", toolName: toolName, toolStatus: .succeeded),
            ChatTranscriptMessage(role: .tool, content: "failed", toolName: "failed_tool", toolStatus: .failed),
        ]
        let selection = ChatToolSelection(history: history)
        XCTAssertEqual(selection.toolNames, [toolName])
        let host = RuntimeMCPHost()
        var settings = settings(host: host, mode: .automatic)
        let runtime = ChatToolRuntime(settings: settings)
        let followUp = runtime.prepareRequest(
            scope: .standalone(settings: settings), canEditImage: false, selection: selection, mcpHost: host
        )
        XCTAssertTrue(followUp.definitions.contains { $0.function.name == toolName })
        settings.setToolExposureMode(.off, toolName: toolName)
        runtime.updateSettings(settings)
        let disabled = runtime.prepareRequest(
            scope: .standalone(settings: settings), canEditImage: false, selection: selection, mcpHost: host
        )
        XCTAssertFalse(disabled.definitions.contains { $0.function.name == toolName })
        XCTAssertTrue(ChatToolSelection(history: []).toolNames.isEmpty)
        XCTAssertTrue(ChatToolSelection(history: history + [
            ChatTranscriptMessage(role: .user, content: "Unrelated task"),
            ChatTranscriptMessage(role: .assistant, content: "No tools needed"),
        ]).toolNames.isEmpty)
    }

    func testRepeatedDiscoveryIsStableAndNewSearchReplacesAutoSchemas() async throws {
        let host = RuntimeMCPHost()
        host.definitions = (0..<8).map { index in
            MLXChatToolDefinition(function: MLXChatFunctionDefinition(
                name: "mcp__test__tool_\(index)",
                description: index < 4 ? "Astronomy observations" : "Botany specimens",
                parameters: .object(["type": .string("object")])
            ))
        }
        let runtime = ChatToolRuntime(settings: settings(host: host, mode: .automatic))
        var selection = ChatToolSelection()
        var matches = Set<String>()
        for query in ["astronomy", "astronomy", "botany"] {
            let request = runtime.prepareRequest(
                scope: .standalone(settings: NativSettings()), canEditImage: false,
                selection: selection, mcpHost: host
            )
            let call = call(name: "tool_search", arguments: #"{"query":"\#(query)"}"#)
            let result = try await runtime.execute(call: call, request: request, context: context(), mcpHost: host)
            if query == "astronomy" && !matches.isEmpty {
                XCTAssertEqual(result.activatedToolNames, matches)
            }
            matches = result.activatedToolNames
            selection.record(call: call, outcome: result, request: request)
        }
        let request = runtime.prepareRequest(
            scope: .standalone(settings: NativSettings()), canEditImage: false,
            selection: selection, mcpHost: host
        )
        let exposed = request.definitions.filter { $0.function.name.hasPrefix("mcp__test__") }
        XCTAssertEqual(exposed.count, ChatToolDiscoveryRegistry.maximumResults)
        XCTAssertTrue(exposed.allSatisfy { $0.function.description.contains("Botany") })
        XCTAssertEqual(Set(exposed.map(\.function.name)), matches)
    }

    func testPreparedPayloadKeepsLargeAutoCatalogOutOfInitialRequest() throws {
        let host = RuntimeMCPHost()
        host.definitions = (0..<100).map { index in
            MLXChatToolDefinition(function: MLXChatFunctionDefinition(
                name: "mcp__test__tool_\(index)", description: String(repeating: "description ", count: 100),
                parameters: .object(["type": .string("object")])
            ))
        }
        let runtime = ChatToolRuntime(settings: settings(host: host, mode: .automatic))
        let initial = prepare(runtime, host: host)
        let initialBytes = try JSONEncoder().encode(initial.definitions)
        let fullBytes = try JSONEncoder().encode(host.definitions)
        XCTAssertFalse(initial.definitions.contains { $0.function.name.hasPrefix("mcp__test__") })
        XCTAssertLessThan(initialBytes.count, fullBytes.count)

        let activated = prepare(runtime, host: host, activated: Set(host.definitions.map(\.function.name)))
        XCTAssertEqual(
            activated.definitions.filter { $0.function.name.hasPrefix("mcp__test__") }.count,
            ChatToolDiscoveryRegistry.maximumResults
        )
    }

    private func settings(host: RuntimeMCPHost, mode: ToolExposureMode) -> NativSettings {
        var settings = NativSettings(mcpServers: [host.server])
        settings.setMCPServerExposureMode(mode, serverID: host.server.id)
        return settings
    }

    private func prepareProject(
        _ runtime: ChatToolRuntime,
        rootPath: String? = FileManager.default.temporaryDirectory.path,
        activated: Set<String> = []
    ) -> ChatToolRequest {
        runtime.prepareRequest(
            scope: ChatToolScope(projectID: UUID(), projectName: "Test", rootPath: rootPath, projectToolsEnabled: true),
            canEditImage: false, selection: ChatToolSelection(toolNames: activated.sorted()), mcpHost: nil
        )
    }

    private func prepare(
        _ runtime: ChatToolRuntime, host: RuntimeMCPHost? = nil, activated: Set<String> = []
    ) -> ChatToolRequest {
        runtime.prepareRequest(
            scope: .standalone(settings: NativSettings()), canEditImage: false,
            selection: ChatToolSelection(toolNames: activated.sorted()), mcpHost: host
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
