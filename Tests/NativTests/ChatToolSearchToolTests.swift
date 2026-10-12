import XCTest
@testable import NativServerKit

final class ChatToolSearchToolTests: XCTestCase {
    private let webTool = MLXChatToolDefinition(
        function: MLXChatFunctionDefinition(
            name: "web_search",
            description: "Search the web for current information.",
            parameters: .object(["type": .string("object")])
        ))

    private var webCapability: ChatToolCapability {
        ChatToolCapability(definition: webTool, source: .native)
    }

    func testSearchReturnsMatchingSchema() throws {
        let result = try ChatToolSearchToolExecutor.search(
            query: "current web information",
            capabilities: [webCapability]
        )

        XCTAssertTrue(result.contains("web_search"))
        XCTAssertTrue(result.contains("arguments_schema"))
        XCTAssertTrue(result.contains("action=invoke"))
    }

    func testInvokeBuildsNestedToolCall() throws {
        let outer = MLXChatToolCall(
            id: "outer",
            function: MLXChatFunctionCall(
                name: ChatToolSearchToolRegistry.toolName,
                arguments: #"{"action":"invoke","name":"web_search","arguments":{"query":"MLX"}}"#
            )
        )
        guard case .invocation(let nested) = try ChatToolSearchToolExecutor.resolve(
            call: outer,
            capabilities: [webCapability]
        ) else {
            return XCTFail("Expected an invocation")
        }

        XCTAssertEqual(nested.function?.name, "web_search")
        XCTAssertEqual(nested.function?.arguments, #"{"query":"MLX"}"#)
    }

    func testInvokeRejectsUnavailableTool() throws {
        let outer = MLXChatToolCall(
            id: "outer",
            function: MLXChatFunctionCall(
                name: ChatToolSearchToolRegistry.toolName,
                arguments: #"{"action":"invoke","name":"missing","arguments":{}}"#
            )
        )

        XCTAssertThrowsError(
            try ChatToolSearchToolExecutor.resolve(call: outer, capabilities: [webCapability])
        )
    }

    func testResolveReturnsSearchContentAndInvocation() throws {
        let searchCall = MLXChatToolCall(
            id: "search",
            function: MLXChatFunctionCall(
                name: ChatToolSearchToolRegistry.toolName,
                arguments: #"{"action":"search","query":"web"}"#
            )
        )
        guard case .searchResult(let content) = try ChatToolSearchToolExecutor.resolve(
            call: searchCall,
            capabilities: [webCapability]
        ) else {
            return XCTFail("Expected a search result")
        }
        XCTAssertTrue(content.contains("web_search"))

        let invokeCall = MLXChatToolCall(
            id: "invoke",
            function: MLXChatFunctionCall(
                name: ChatToolSearchToolRegistry.toolName,
                arguments: #"{"action":"invoke","name":"web_search","arguments":{"query":"MLX"}}"#
            )
        )
        guard case .invocation(let nested) = try ChatToolSearchToolExecutor.resolve(
            call: invokeCall,
            capabilities: [webCapability]
        ) else {
            return XCTFail("Expected an invocation")
        }
        XCTAssertEqual(nested.function?.name, "web_search")
    }

    func testSearchRanksExactNameFirstAndCapsResults() throws {
        let capabilities = (0..<7).map { index in
            ChatToolCapability(definition: MLXChatToolDefinition(
                function: MLXChatFunctionDefinition(
                    name: index == 6 ? "web_search" : "web_helper_\(index)",
                    description: "Search the web.",
                    parameters: .object(["type": .string("object")])
                )
            ), source: .native)
        }

        let result = try ChatToolSearchToolExecutor.search(
            query: "web_search",
            capabilities: capabilities
        )
        let data = try XCTUnwrap(result.data(using: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let matches = try XCTUnwrap(object["matches"] as? [[String: Any]])

        XCTAssertEqual(matches.first?["name"] as? String, "web_search")
        XCTAssertLessThanOrEqual(matches.count, 5)
    }

    func testSearchIncludesMCPProviderMetadata() throws {
        let capability = ChatToolCapability(
            definition: webTool,
            source: .mcp(serverID: UUID(), name: "GitHub")
        )

        let result = try ChatToolSearchToolExecutor.search(
            query: "github",
            capabilities: [capability]
        )

        XCTAssertTrue(result.contains(#""source":"mcp""#))
        XCTAssertTrue(result.contains(#""provider":"GitHub""#))
    }
}
