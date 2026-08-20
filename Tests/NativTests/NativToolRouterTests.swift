import NativServerKit
import XCTest

private struct StubProvider: NativCapabilityProvider {
    let namespace: String
    let names: [String]
    let response: String

    func definitions(_ options: NativToolCatalogOptions) async -> [MLXChatToolDefinition] {
        names.map { name in
            MLXChatToolDefinition(
                function: MLXChatFunctionDefinition(
                    name: name,
                    description: namespace,
                    parameters: .object([:])
                )
            )
        }
    }

    func handles(_ name: String) async -> Bool {
        names.contains(name)
    }

    func call(
        _ name: String,
        argumentsJSON: String?,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        ChatToolExecutionOutcome(content: response, attachments: [])
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
            providers: [StubProvider(namespace: "custom", names: ["shared"], response: "custom")],
            fallback: StubProvider(namespace: "native", names: ["shared"], response: "native")
        )

        let outcome = try await router.call("shared", argumentsJSON: nil, context: makeContext())
        XCTAssertEqual(
            outcome.content,
            "custom",
            "a custom tool must shadow a built-in of the same name, as the chat turn did"
        )
    }

    func testBuiltInToolsAreAdvertisedFirst() async {
        let router = NativToolRouter(
            providers: [
                StubProvider(namespace: "custom", names: ["b"], response: ""),
                StubProvider(namespace: "mcp", names: ["c"], response: ""),
            ],
            fallback: StubProvider(namespace: "native", names: ["a"], response: "")
        )

        let names = await router.definitions(options()).map(\.function.name)
        XCTAssertEqual(names, ["a", "b", "c"], "advertised order must stay native, custom, host")
    }

    func testUnknownToolsReachTheFallbackWhichReportsThem() async {
        let router = NativToolRouter(
            providers: [StubProvider(namespace: "custom", names: ["known"], response: "")],
            fallback: NativeToolProvider()
        )

        do {
            _ = try await router.call("missing", argumentsJSON: nil, context: makeContext())
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
            fallback: StubProvider(namespace: "native", names: ["kept", "dropped"], response: "")
        )

        let names = await router.definitions(options(disabled: ["dropped"])).map(\.function.name)
        XCTAssertEqual(names, ["kept"])
    }

    func testWebToolsAreAdvertisedOnlyWhenConfigured() async {
        let router = NativToolRouter(
            providers: [],
            fallback: StubProvider(
                namespace: "native",
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
        XCTAssertTrue(await provider.handles(ChatModelLibraryToolRegistry.toolName))
        XCTAssertFalse(await provider.handles("definitely_not_a_tool"))
    }
}
