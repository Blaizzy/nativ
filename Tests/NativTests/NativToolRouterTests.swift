import NativServerKit
import XCTest

private struct StubProvider: NativCapabilityProvider {
    let names: [String]
    let response: String
    var needsConsent = false
    var ran = Ran()

    final class Ran: @unchecked Sendable {
        var count = 0
    }

    func definitions(_ options: NativToolCatalogOptions) async -> [MLXChatToolDefinition] {
        names.map { name in
            MLXChatToolDefinition(
                function: MLXChatFunctionDefinition(
                    name: name,
                    description: "",
                    parameters: .object([:])
                )
            )
        }
    }

    func handles(_ name: String) async -> Bool {
        names.contains(name)
    }

    func requiresConsent(_ name: String) async -> Bool {
        needsConsent
    }

    func call(
        _ name: String,
        argumentsJSON: String?,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        ran.count += 1
        return ChatToolExecutionOutcome(content: response, attachments: [])
    }
}

private struct StubAsker: NativInteraction {
    let outcome: ChatToolConsentOutcome

    @MainActor
    func requestConsent(for toolName: String, requestID: UUID) async -> ChatToolConsentOutcome {
        outcome
    }
}

final class NativToolRouterTests: XCTestCase {
    private func makeContext() -> ChatToolExecutionContext {
        ChatToolExecutionContext(
            imageGenerationModelID: nil,
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            apiKey: nil,
            imageReferences: [],
            modelSearchPath: "",
            additionalModelSearchPaths: []
        )
    }

    private func options(
        disabled: Set<String> = [],
        webSearch: Bool = true,
        webRead: Bool = true
    ) -> NativToolCatalogOptions {
        NativToolCatalogOptions(
            canEditImage: false,
            disabledToolNames: disabled,
            webSearchIsConfigured: webSearch,
            webReadIsConfigured: webRead
        )
    }

    func testProvidersShadowTheFallbackForSharedToolNames() async throws {
        let router = NativToolRouter(
            providers: [StubProvider(names: ["shared"], response: "custom")],
            fallback: StubProvider(names: ["shared"], response: "native")
        )

        let result = try await router.call(
            "shared",
            argumentsJSON: nil,
            context: makeContext(),
            requestID: UUID(),
            asking: StubAsker(outcome: .approved)
        )
        XCTAssertEqual(
            content(of: result),
            "custom",
            "a custom tool must shadow a built-in of the same name, as the chat turn did"
        )
    }

    func testBuiltInToolsAreAdvertisedFirst() async {
        let router = NativToolRouter(
            providers: [
                StubProvider(names: ["b"], response: ""),
                StubProvider(names: ["c"], response: ""),
            ],
            fallback: StubProvider(names: ["a"], response: "")
        )

        let names = await router.definitions(options()).map(\.function.name)
        XCTAssertEqual(names, ["a", "b", "c"], "advertised order must stay native, custom, host")
    }

    func testUnknownToolsReachTheFallbackWhichReportsThem() async {
        let router = NativToolRouter(
            providers: [StubProvider(names: ["known"], response: "")],
            fallback: NativeToolProvider()
        )

        do {
            _ = try await router.call(
                "missing",
                argumentsJSON: nil,
                context: makeContext(),
                requestID: UUID(),
                asking: StubAsker(outcome: .approved)
            )
            XCTFail("expected an unsupported tool error")
        } catch ChatImageToolError.unsupportedTool(let name) {
            XCTAssertEqual(name, "missing")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDisabledToolsAreNotAdvertised() async {
        let router = NativToolRouter(
            providers: [],
            fallback: StubProvider(names: ["kept", "dropped"], response: "")
        )

        let names = await router.definitions(options(disabled: ["dropped"])).map(\.function.name)
        XCTAssertEqual(names, ["kept"])
    }

    func testWebToolsAreAdvertisedOnlyWhenConfigured() async {
        let router = NativToolRouter(
            providers: [],
            fallback: StubProvider(
                names: [ChatWebSearchToolRegistry.toolName, ChatWebReadToolRegistry.toolName],
                response: ""
            )
        )

        let configured = await router.definitions(options()).map(\.function.name)
        XCTAssertEqual(
            configured,
            [ChatWebSearchToolRegistry.toolName, ChatWebReadToolRegistry.toolName]
        )

        let unconfigured = await router.definitions(
            options(webSearch: false, webRead: false)
        ).map(\.function.name)
        XCTAssertEqual(unconfigured, [])
    }

    func testNativeProviderClaimsOnlyDispatchableTools() async {
        let provider = NativeToolProvider()
        let claimsKnownTool = await provider.handles(ChatModelLibraryToolRegistry.toolName)
        let claimsUnknownTool = await provider.handles("definitely_not_a_tool")
        XCTAssertTrue(claimsKnownTool)
        XCTAssertFalse(claimsUnknownTool)
    }
    func testADeclinedToolDoesNotRun() async throws {
        let provider = StubProvider(names: ["risky"], response: "ran", needsConsent: true)
        let router = NativToolRouter(providers: [provider], fallback: NativeToolProvider())

        let result = try await router.call(
            "risky",
            argumentsJSON: nil,
            context: makeContext(),
            requestID: UUID(),
            asking: StubAsker(outcome: .declined)
        )

        guard case .declined = result else {
            XCTFail("expected the call to be reported as declined")
            return
        }
        XCTAssertEqual(provider.ran.count, 0, "a declined tool must never execute")
    }

    func testAnApprovedToolRuns() async throws {
        let provider = StubProvider(names: ["risky"], response: "ran", needsConsent: true)
        let router = NativToolRouter(providers: [provider], fallback: NativeToolProvider())

        let result = try await router.call(
            "risky",
            argumentsJSON: nil,
            context: makeContext(),
            requestID: UUID(),
            asking: StubAsker(outcome: .approved)
        )

        XCTAssertEqual(content(of: result), "ran")
        XCTAssertEqual(provider.ran.count, 1)
    }

    private func content(of result: NativToolCallResult) -> String? {
        guard case .completed(let outcome) = result else {
            return nil
        }
        return outcome.content
    }

}
