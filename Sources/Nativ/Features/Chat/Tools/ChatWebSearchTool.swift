import Foundation
import NativServerKit

enum ChatWebSearchToolRegistry {
    static let toolName = "web_search"

    static func definitions() -> [MLXChatToolDefinition] {
        [MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName,
            description: "Search the public web for current sources. "
                + "Returns up to five titles, URLs, and short snippets.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("The web search query.")
                    ])
                ]),
                "required": .array([.string("query")])
            ])
        ))]
    }
}

enum BraveSearchCredential {
    private static let store = ServerAPIKeychain(
        service: "dev.local.Nativ.brave-search-api-key",
        account: "nativ-brave-search"
    )

    static func load() -> String? {
        try? store.load()
    }

    static func save(_ apiKey: String?) throws {
        try store.save(apiKey)
    }
}

enum ChatWebSearchToolError: LocalizedError {
    case unsupportedTool(String)
    case invalidArguments
    case emptyQuery
    case missingAPIKey
    case unexpectedResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedTool(let name):
            "Unsupported tool: \(name)."
        case .invalidArguments:
            "Web search needs a valid JSON query."
        case .emptyQuery:
            "Web search needs a non-empty query."
        case .missingAPIKey:
            "Add a Brave Search API key in Developer to use web search."
        case .unexpectedResponse:
            "Web search returned an unreadable response."
        case .requestFailed(let statusCode):
            "Web search failed with status \(statusCode)."
        }
    }
}

private struct ChatWebSearchToolArguments: Decodable {
    let query: String
}

struct ChatWebSearchToolRequest: Equatable {
    let query: String

    init(call: MLXChatToolCall) throws {
        guard call.function?.name == ChatWebSearchToolRegistry.toolName else {
            throw ChatWebSearchToolError.unsupportedTool(call.function?.name ?? "unknown")
        }
        guard let arguments = call.function?.arguments?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ChatWebSearchToolArguments.self, from: arguments)
        else {
            throw ChatWebSearchToolError.invalidArguments
        }

        let query = decoded.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ChatWebSearchToolError.emptyQuery
        }
        self.query = String(query.prefix(500))
    }
}

struct ChatWebSearchToolResultPayload: Encodable {
    struct Result: Encodable {
        let title: String
        let url: String
        let snippet: String
    }

    let ok: Bool
    let results: [Result]?
    let error: String?
}

struct ChatWebSearchToolExecutor {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport

    init(transport: @escaping Transport = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.transport = transport
    }

    func execute(call: MLXChatToolCall, apiKey: String?) async throws -> String {
        guard let apiKey = ServerAPIAuthentication.normalizedToken(apiKey) else {
            throw ChatWebSearchToolError.missingAPIKey
        }
        let search = try ChatWebSearchToolRequest(call: call)
        var request = try makeRequest(query: search.query, apiKey: apiKey)
        request.timeoutInterval = 20

        let (data, response) = try await transport(request)
        guard let response = response as? HTTPURLResponse else {
            throw ChatWebSearchToolError.unexpectedResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ChatWebSearchToolError.requestFailed(response.statusCode)
        }

        let payload = try JSONDecoder().decode(BraveSearchResponse.self, from: data)
        let results = payload.web?.results?.prefix(5).map { result in
            ChatWebSearchToolResultPayload.Result(
                title: Self.compact(result.title, limit: 160),
                url: result.url,
                snippet: Self.compact(result.description ?? "", limit: 280)
            )
        } ?? []
        return try encodedPayload(ChatWebSearchToolResultPayload(ok: true, results: results, error: nil))
    }

    func failurePayload(operation: String, error: Error) -> String {
        let payload = ChatWebSearchToolResultPayload(
            ok: false,
            results: nil,
            error: error.localizedDescription
        )
        return (try? encodedPayload(payload))
            ?? #"{"ok":false,"error":"Web search failed."}"#
    }

    func makeRequest(query: String, apiKey: String) throws -> URLRequest {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "5")
        ]
        guard let url = components?.url else {
            throw ChatWebSearchToolError.unexpectedResponse
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        return request
    }

    private func encodedPayload(_ payload: ChatWebSearchToolResultPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private static func compact(_ value: String, limit: Int) -> String {
        let singleSpaced = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(singleSpaced.prefix(limit))
    }
}

private struct BraveSearchResponse: Decodable {
    struct Web: Decodable {
        struct Result: Decodable {
            let title: String
            let url: String
            let description: String?
        }

        let results: [Result]?
    }

    let web: Web?
}
