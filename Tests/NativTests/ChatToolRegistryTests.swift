import XCTest
@testable import NativServerKit

private let nativeToolNames = [
    ChatSystemMonitorToolRegistry.toolName,
    ChatModelLibraryToolRegistry.toolName,
    ChatServerStatsToolRegistry.toolName,
    ChatSwitchModelToolRegistry.toolName,
]

private struct FakeToolError: Error, LocalizedError {
    var errorDescription: String? { "fake failure" }
}

private func makeContext(imageModelID: String? = nil) -> ChatToolExecutionContext {
    ChatToolExecutionContext(
        imageGenerationModelID: imageModelID,
        baseURL: URL(string: "http://127.0.0.1:8080")!,
        apiKey: nil,
        imageReferences: [],
        modelSearchPath: "",
        additionalModelSearchPaths: []
    )
}

private func makeCall(name: String, arguments: String = "{}") -> MLXChatToolCall {
    MLXChatToolCall(id: "1", function: MLXChatFunctionCall(name: name, arguments: arguments))
}

final class ChatToolRegistryTests: XCTestCase {
    func testDefinitionsOmitImageToolsWithNoImageModelConfigured() {
        let names = ChatToolRegistry.definitions(context: makeContext(), canEditImage: false)
            .map(\.function.name)

        XCTAssertFalse(names.contains("generate_image"))
        XCTAssertFalse(names.contains("edit_image"))
        for toolName in nativeToolNames {
            XCTAssertTrue(names.contains(toolName), "\(toolName) should be advertised without an image model")
        }
    }

    func testDefinitionsIncludeImageToolsOnlyWhenImageModelConfigured() {
        let withoutEdit = ChatToolRegistry.definitions(
            context: makeContext(imageModelID: "org/image"),
            canEditImage: false
        ).map(\.function.name)
        XCTAssertTrue(withoutEdit.contains("generate_image"))
        XCTAssertFalse(withoutEdit.contains("edit_image"))

        let withEdit = ChatToolRegistry.definitions(
            context: makeContext(imageModelID: "org/image"),
            canEditImage: true
        ).map(\.function.name)
        XCTAssertTrue(withEdit.contains("edit_image"))
    }

    func testDispatchRoutesToRegisteredHandler() async throws {
        let outcome = try await ChatToolDispatcher.execute(
            call: makeCall(name: ChatServerStatsToolRegistry.toolName),
            context: makeContext()
        )

        let data = try XCTUnwrap(outcome.content.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertNotNil(object["requests_completed"])
    }

    func testDispatchingUnknownToolThrows() async {
        do {
            _ = try await ChatToolDispatcher.execute(call: makeCall(name: "not_a_real_tool"), context: makeContext())
            XCTFail("dispatching an unregistered tool name must throw")
        } catch {}
    }

    func testRoundGateAdvertisesToolsUnderTheCapAndStopsAtIt() {
        XCTAssertEqual(ChatToolRoundGate.maximumRounds, 4)
        for round in 0..<ChatToolRoundGate.maximumRounds {
            XCTAssertTrue(ChatToolRoundGate.advertisesTools(atRound: round), "round \(round) should still advertise tools")
        }
        XCTAssertFalse(ChatToolRoundGate.advertisesTools(atRound: ChatToolRoundGate.maximumRounds))
        XCTAssertFalse(ChatToolRoundGate.advertisesTools(atRound: ChatToolRoundGate.maximumRounds + 3))
    }

    func testSwitchModelIsUnreachableThroughGenericDispatcherExecute() async {
        do {
            _ = try await ChatToolDispatcher.execute(
                call: makeCall(name: ChatSwitchModelToolRegistry.toolName, arguments: #"{"model_id":"org/model"}"#),
                context: makeContext()
            )
            XCTFail("switch_model must never execute through the generic dispatcher without the consent gate")
        } catch {}
    }

    func testConsentRouterTreatsCancellationAsHigherPriorityThanApproval() {
        XCTAssertEqual(ChatToolConsentRouter.outcome(approved: true, isCancelled: true), .cancelled)
        XCTAssertEqual(ChatToolConsentRouter.outcome(approved: false, isCancelled: true), .cancelled)
    }

    func testConsentRouterFallsBackToApprovalWhenNotCancelled() {
        XCTAssertEqual(ChatToolConsentRouter.outcome(approved: true, isCancelled: false), .approved)
        XCTAssertEqual(ChatToolConsentRouter.outcome(approved: false, isCancelled: false), .declined)
    }

    func testFailurePayloadCoveredForEveryNativeToolExecuteHandles() throws {
        for toolName in nativeToolNames {
            let payload = ChatToolDispatcher.failurePayload(toolName: toolName, error: FakeToolError())
            let data = try XCTUnwrap(payload.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["ok"] as? Bool, false, "\(toolName) failurePayload should report ok:false")
            XCTAssertNil(object["operation"], "\(toolName) failurePayload should not fall through to the image-tool shape (which always encodes a non-optional \"operation\" field)")
        }
    }

    func testSystemMonitorFailurePayloadShape() throws {
        let payload = ChatSystemMonitorToolExecutor().failurePayload(operation: "x", error: FakeToolError())
        let object = try decode(payload)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "fake failure")
        XCTAssertNil(object["cpu_usage_percent"])
    }

    func testModelLibraryFailurePayloadShape() throws {
        let payload = ChatModelLibraryToolExecutor().failurePayload(operation: "x", error: FakeToolError())
        let object = try decode(payload)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "fake failure")
        XCTAssertNil(object["models"])
    }

    func testServerStatsFailurePayloadShape() throws {
        let payload = ChatServerStatsToolExecutor().failurePayload(operation: "x", error: FakeToolError())
        let object = try decode(payload)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "fake failure")
        XCTAssertNil(object["requests_completed"])
    }

    func testSwitchModelFailurePayloadShape() throws {
        let payload = ChatSwitchModelToolExecutor().failurePayload(operation: "x", error: FakeToolError())
        let object = try decode(payload)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["declined"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "fake failure")
    }

    func testSwitchModelDeclinedPayloadShape() throws {
        let payload = ChatSwitchModelToolExecutor().declinedPayload()
        let object = try decode(payload)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["declined"] as? Bool, true)
        XCTAssertNotNil(object["error"])
    }

    private func decode(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@MainActor
final class ChatToolConsentGateTests: XCTestCase {
    func testConfirmResolvesAwaitingDecisionTrue() async {
        let gate = ChatToolConsentGate()
        let id = UUID()

        async let result = gate.awaitDecision(for: id)
        await waitUntilPending(gate, count: 1)
        gate.confirm(id)

        let decision = await result
        XCTAssertTrue(decision)
        XCTAssertEqual(gate.pendingCount, 0)
    }

    func testDenyResolvesAwaitingDecisionFalse() async {
        let gate = ChatToolConsentGate()
        let id = UUID()

        async let result = gate.awaitDecision(for: id)
        await waitUntilPending(gate, count: 1)
        gate.deny(id)

        let decision = await result
        XCTAssertFalse(decision)
    }

    func testCancellingTheWaitingTaskResolvesFalse() async {
        let gate = ChatToolConsentGate()
        let id = UUID()

        let task = Task<Bool, Never> {
            await gate.awaitDecision(for: id)
        }
        await waitUntilPending(gate, count: 1)
        task.cancel()

        let decision = await task.value
        XCTAssertFalse(decision, "a cancelled wait must resolve false, not hang or resolve true")
        XCTAssertEqual(gate.pendingCount, 0)
    }

    func testDenyThenReaskAllowsAFreshConsentCycleForTheSameID() async {
        let gate = ChatToolConsentGate()
        let id = UUID()

        async let firstResult = gate.awaitDecision(for: id)
        await waitUntilPending(gate, count: 1)
        gate.deny(id)
        let first = await firstResult
        XCTAssertFalse(first)
        XCTAssertEqual(gate.pendingCount, 0)

        async let secondResult = gate.awaitDecision(for: id)
        await waitUntilPending(gate, count: 1)
        gate.confirm(id)
        let second = await secondResult
        XCTAssertTrue(second, "re-offering the same tool message id must start a fresh, independent wait")
    }

    func testConfirmAndDenyAreSafeNoOpsForAnUnregisteredID() {
        let gate = ChatToolConsentGate()
        gate.confirm(UUID())
        gate.deny(UUID())
        XCTAssertEqual(gate.pendingCount, 0)
    }

    private func waitUntilPending(_ gate: ChatToolConsentGate, count: Int) async {
        for _ in 0..<200 where gate.pendingCount < count {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
