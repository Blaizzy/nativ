import NativServerKit
import XCTest

private struct StubProvider: NativCapabilityProvider {
    let namespace: String
    let catalogRank: Int
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
        enabled: @escaping @Sendable (String) -> Bool = { _ in true }
    ) -> NativToolCatalogOptions {
        NativToolCatalogOptions(canEditImage: false, isToolEnabled: enabled)
    }

    func testEarlierProviderWinsWhenTwoProvidersShareAToolName() async throws {
        let router = NativToolRouter(providers: [
            StubProvider(namespace: "custom", catalogRank: 1, names: ["shared"], response: "custom"),
            StubProvider(namespace: "native", catalogRank: 0, names: ["shared"], response: "native"),
        ])

        let outcome = try await router.call("shared", argumentsJSON: nil, context: makeContext())
        XCTAssertEqual(
            outcome.content,
            "custom",
            "dispatch order must stay custom before native, as the chat turn did"
        )
    }

    func testCatalogOrderIsIndependentOfDispatchOrder() async {
        let router = NativToolRouter(providers: [
            StubProvider(namespace: "custom", catalogRank: 1, names: ["b"], response: ""),
            StubProvider(namespace: "mcp", catalogRank: 2, names: ["c"], response: ""),
            StubProvider(namespace: "native", catalogRank: 0, names: ["a"], response: ""),
        ])

        let names = await router.definitions(options()).map(\.function.name)
        XCTAssertEqual(names, ["a", "b", "c"], "advertised order must stay native, custom, host")
    }

    func testUnknownToolFailsTheSameWayTheDispatcherDid() async {
        let router = NativToolRouter(providers: [
            StubProvider(namespace: "native", catalogRank: 0, names: ["known"], response: "")
        ])

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
        let router = NativToolRouter(providers: [
            StubProvider(namespace: "native", catalogRank: 0, names: ["kept", "dropped"], response: "")
        ])

        let names = await router.definitions(options { $0 != "dropped" }).map(\.function.name)
        XCTAssertEqual(names, ["kept"])
    }

    func testWebToolsAreAdvertisedOnlyWhenConfigured() async {
        let router = NativToolRouter(providers: [
            StubProvider(
                namespace: "native",
                catalogRank: 0,
                names: [ChatWebSearchToolRegistry.toolName, ChatWebReadToolRegistry.toolName],
                response: ""
            )
        ])

        let names = await router.definitions(options()).map(\.function.name)
        XCTAssertEqual(
            names.contains(ChatWebSearchToolRegistry.toolName),
            ChatWebSearchToolRegistry.isConfigured()
        )
        XCTAssertEqual(
            names.contains(ChatWebReadToolRegistry.toolName),
            ChatWebReadToolRegistry.isConfigured()
        )
    }

    func testDuplicateToolNamesAreReported() {
        let definitions = ["a", "b", "a", "c", "b"].map { name in
            MLXChatToolDefinition(
                function: MLXChatFunctionDefinition(name: name, description: "", parameters: .object([:]))
            )
        }
        XCTAssertEqual(NativToolRouter.duplicateToolNames(in: definitions), ["a", "b"])
    }

    func testNativeProviderClaimsOnlyDispatchableTools() async {
        let provider = NativeToolProvider()
        XCTAssertTrue(await provider.handles(ChatModelLibraryToolRegistry.toolName))
        XCTAssertFalse(await provider.handles("definitely_not_a_tool"))
    }
}
