import XCTest

@testable import NativServerKit

@MainActor
final class ChatToolModelTests: XCTestCase {
    func testProjectTaskWithDirectTools() async throws {
        try await runProjectTask(mode: .on)
    }

    func testProjectTaskWithDiscoveredTools() async throws {
        try await runProjectTask(mode: .automatic)
    }

    func testProjectTaskRecoversFromUnknownTool() async throws {
        try await runProjectTask(mode: .on, includeUnknownCall: true)
    }

    private func runProjectTask(mode: ToolExposureMode, includeUnknownCall: Bool = false) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["NATIV_TOOL_TEST_URL"], let url = URL(string: endpoint),
            let modelID = environment["NATIV_TOOL_TEST_MODEL"]
        else {
            throw XCTSkip("Set NATIV_TOOL_TEST_URL and NATIV_TOOL_TEST_MODEL to run real-model checks.")
        }
        guard ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else {
            throw XCTSkip("Real-model tool tests require a loopback endpoint.")
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = NativSettings()
        settings.setToolExposureMode(mode, toolNames: Array(ChatToolScope.projectToolNames))
        let runtime = ChatToolRuntime(settings: settings)
        let scope = ChatToolScope(
            projectID: UUID(), projectName: "Regression", rootPath: root.path, projectToolsEnabled: true)
        var selection = ChatToolSelection(toolNames: [])
        let context = ChatToolExecutionContext(
            imageGenerationModelID: nil, baseURL: url, apiKey: nil,
            imageReferences: [], modelSearchPath: "", additionalModelSearchPaths: []
        )
        let client = NativChatClient(baseURL: url, idleTimeout: 90, resourceTimeout: 180)
        var messages = [
            MLXChatMessage(
                role: "system",
                content: [scope.systemPrompt!, NativSkill.builtInToolGuide.instructions].joined(
                    separator: "\n\n")),
            MLXChatMessage(
                role: "user",
                content:
                    "Create index.html containing a self-contained browser clicker game with a visible score and Reset button. No external assets. Actually save it in the project."
            ),
        ]
        if includeUnknownCall {
            let call = MLXChatToolCall(
                id: UUID().uuidString,
                function: MLXChatFunctionCall(name: "bash", arguments: #"{"command":"pwd"}"#))
            let request = runtime.prepareRequest(
                scope: scope, canEditImage: false, selection: selection, mcpHost: nil)
            messages.append(MLXChatMessage(role: "assistant", content: "", toolCalls: [call]))
            do {
                _ = try await runtime.execute(call: call, request: request, context: context)
                XCTFail("Unknown tool executed")
            } catch {
                messages.append(
                    MLXChatMessage(
                        role: "tool", content: error.localizedDescription, toolCallID: call.id,
                        name: call.function?.name))
            }
        }

        var calls: [String] = []
        var inputTokens = 0
        var outputTokens = 0
        var rounds = 0
        var failures: [String] = []
        let started = Date()
        for _ in 0..<8 {
            let request = runtime.prepareRequest(
                scope: scope, canEditImage: false, selection: selection, mcpHost: nil)
            let completion = try await client.streamChat(
                MLXChatCompletionRequest(
                    model: modelID, messages: messages, maxTokens: 2048,
                    temperature: 0, topK: 0, topP: 1, minP: 0, enableThinking: false,
                    tools: request.definitions, toolChoice: "auto", stream: true
                ), onDelta: { _ in })
            rounds += 1
            inputTokens += try XCTUnwrap(completion.usage?.promptTokens)
            outputTokens += try XCTUnwrap(completion.usage?.completionTokens)
            messages.append(
                MLXChatMessage(
                    role: "assistant", content: completion.content,
                    toolCalls: completion.toolCalls.isEmpty ? nil : completion.toolCalls
                ))
            if completion.toolCalls.isEmpty { break }
            for call in completion.toolCalls {
                let name = call.function?.name ?? "unknown"
                calls.append(name)
                let content: String
                do {
                    let outcome = try await runtime.execute(
                        call: call, request: request, context: context,
                        requestApproval: {
                            if ChatFileWriteToolRegistry.toolNames.contains(name) { return true }
                            guard name == "terminal", let command = try? ChatTerminalToolRequest(call: call),
                                ["pwd", "ls", "ls -la"].contains(command.command),
                                command.cwd == nil || command.cwd == root.path || command.cwd == "."
                            else { return false }
                            return true
                        }
                    )
                    content = outcome.content
                    selection.record(call: call, outcome: outcome, request: request)
                } catch ChatToolExecutionError.declined(let payload) {
                    content = payload
                } catch {
                    content = ChatToolDispatcher.failurePayload(toolName: name, error: error)
                    failures.append(content)
                }
                messages.append(
                    MLXChatMessage(role: "tool", content: content, toolCallID: call.id, name: name))
            }
        }
        let report =
            "model=\(modelID) mode=\(mode) recovery=\(includeUnknownCall) rounds=\(rounds) input=\(inputTokens) output=\(outputTokens) seconds=\(Date().timeIntervalSince(started)) calls=\(calls) failures=\(failures)"
        print(report)
        let attachment = XCTAttachment(
            string: report + "\n" + String(decoding: try JSONEncoder().encode(messages), as: UTF8.self))
        attachment.lifetime = .keepAlways
        add(attachment)
        let file = root.appendingPathComponent("index.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), report)
        if FileManager.default.fileExists(atPath: file.path) {
            let html = try String(contentsOf: file, encoding: .utf8).lowercased()
            XCTAssertTrue(html.contains("<script"), report)
            XCTAssertTrue(html.contains("reset"), report)
        }
        XCTAssertTrue(calls.contains("write_file"), report)
        XCTAssertFalse(calls.contains("generate_image"), report)
        XCTAssertTrue(failures.isEmpty, report)
        if mode == .automatic { XCTAssertTrue(calls.contains("tool_search"), report) }
    }
}
