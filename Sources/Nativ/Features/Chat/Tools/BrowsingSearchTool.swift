import Foundation
import NativServerKit

enum BrowsingSearchTool {
    static let name = "web_search"

    static let definition = MLXChatToolDefinition(function: MLXChatFunctionDefinition(
        name: name,
        description: "Search the web and return the most relevant sources.",
        parameters: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("A focused web search query.")
                ])
            ]),
            "required": .array([.string("query")])
        ])
    ))

    static var isConfigured: Bool {
        BrowsingCredentials.load(for: BrowsingProviderSettings.active) != nil
    }

    static func execute(call: MLXChatToolCall) async throws -> String {
        guard let rawArguments = call.function?.arguments?.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(Arguments.self, from: rawArguments),
              let query = normalizedQuery(arguments.query) else {
            throw BrowsingSearchError.invalidQuery
        }
        let provider = BrowsingProviderSettings.active
        guard let key = BrowsingCredentials.load(for: provider) else {
            throw BrowsingSearchError.missingAPIKey(provider)
        }
        do {
            let results = try await BrowsingSearchService.search(
                provider: provider,
                apiKey: key,
                query: query,
                limit: 3
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(
                decoding: try encoder.encode(ResultPayload(results: results)),
                as: UTF8.self
            )
        } catch {
            if BrowsingSearchError.invalidatesCredential(error) {
                BrowsingProviderSettings.markVerified(provider, verified: false)
            }
            throw error
        }
    }

    static func failurePayload(error: Error) -> String {
        let payload = FailurePayload(error: error.localizedDescription)
        guard let data = try? JSONEncoder().encode(payload) else {
            return "{\"error\":\"Web search failed.\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func normalizedQuery(_ query: String?) -> String? {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return nil
        }
        return String(query.prefix(300))
    }

    private struct Arguments: Decodable { let query: String? }
    private struct ResultPayload: Encodable { let results: [BrowsingSearchResult] }
    private struct FailurePayload: Encodable { let error: String }
}

struct BrowsingSearchResult: Codable, Equatable, Sendable {
    let title: String
    let url: String
    let description: String

    init(title: String?, url: String?, description: String?) {
        self.title = String((title ?? "Untitled result").prefix(160))
        self.url = url ?? ""
        self.description = String((description ?? "").prefix(300))
    }
}

protocol BrowsingHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionBrowsingHTTPClient: BrowsingHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

enum BrowsingSearchService {
    static func test(provider: BrowsingProvider, apiKey: String) async throws {
        let results = try await search(
            provider: provider,
            apiKey: apiKey,
            query: "Nativ",
            limit: 1
        )
        guard !results.isEmpty else { throw BrowsingSearchError.emptyResponse(provider) }
    }

    static func search(
        provider: BrowsingProvider,
        apiKey: String,
        query: String,
        limit: Int,
        client: any BrowsingHTTPClient = URLSessionBrowsingHTTPClient()
    ) async throws -> [BrowsingSearchResult] {
        switch provider {
        case .brave:
            try await searchBrave(apiKey: apiKey, query: query, limit: limit, client: client)
        case .exa:
            try await searchExa(apiKey: apiKey, query: query, limit: limit, client: client)
        case .nimble:
            try await searchNimble(apiKey: apiKey, query: query, limit: limit, client: client)
        case .firecrawl:
            try await searchFirecrawl(apiKey: apiKey, query: query, limit: limit, client: client)
        case .perplexity:
            try await searchPerplexity(apiKey: apiKey, query: query, limit: limit, client: client)
        }
    }

    private static func searchBrave(
        apiKey: String,
        query: String,
        limit: Int,
        client: any BrowsingHTTPClient
    ) async throws -> [BrowsingSearchResult] {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(limit)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        let data = try await data(for: request, provider: .brave, client: client)
        let response = try JSONDecoder().decode(BraveResponse.self, from: data)
        return response.web?.results.prefix(limit).map {
            BrowsingSearchResult(title: $0.title, url: $0.url, description: $0.description)
        } ?? []
    }

    private static func searchExa(
        apiKey: String,
        query: String,
        limit: Int,
        client: any BrowsingHTTPClient
    ) async throws -> [BrowsingSearchResult] {
        let request = try postRequest(
            url: "https://api.exa.ai/search",
            apiKey: apiKey,
            header: "x-api-key",
            body: ["query": query, "numResults": limit, "type": "fast"]
        )
        let data = try await data(for: request, provider: .exa, client: client)
        let response = try JSONDecoder().decode(ExaResponse.self, from: data)
        return response.results.prefix(limit).map {
            BrowsingSearchResult(
                title: $0.title,
                url: $0.url,
                description: $0.highlights?.first ?? $0.text
            )
        }
    }

    private static func searchNimble(
        apiKey: String,
        query: String,
        limit: Int,
        client: any BrowsingHTTPClient
    ) async throws -> [BrowsingSearchResult] {
        let request = try postRequest(
            url: "https://sdk.nimbleway.com/v2/search",
            apiKey: apiKey,
            header: "Authorization",
            body: [
                "query": query,
                "max_results": limit,
                "search_depth": "lite",
                "output_format": "plain_text",
            ]
        )
        let data = try await data(for: request, provider: .nimble, client: client)
        let response = try JSONDecoder().decode(NimbleResponse.self, from: data)
        return response.results.prefix(limit).map {
            BrowsingSearchResult(
                title: $0.title,
                url: $0.url,
                description: $0.description ?? $0.content
            )
        }
    }

    private static func searchFirecrawl(
        apiKey: String,
        query: String,
        limit: Int,
        client: any BrowsingHTTPClient
    ) async throws -> [BrowsingSearchResult] {
        let request = try postRequest(
            url: "https://api.firecrawl.dev/v2/search",
            apiKey: apiKey,
            header: "Authorization",
            body: ["query": query, "limit": limit, "sources": ["web"], "highlights": false]
        )
        let data = try await data(for: request, provider: .firecrawl, client: client)
        let response = try JSONDecoder().decode(FirecrawlResponse.self, from: data)
        return response.data.web.prefix(limit).map {
            BrowsingSearchResult(
                title: $0.title,
                url: $0.url,
                description: $0.description ?? $0.markdown
            )
        }
    }

    private static func searchPerplexity(
        apiKey: String,
        query: String,
        limit: Int,
        client: any BrowsingHTTPClient
    ) async throws -> [BrowsingSearchResult] {
        let request = try postRequest(
            url: "https://api.perplexity.ai/search",
            apiKey: apiKey,
            header: "Authorization",
            body: ["query": query, "max_results": limit, "search_context_size": "low"]
        )
        let data = try await data(for: request, provider: .perplexity, client: client)
        let response = try JSONDecoder().decode(PerplexityResponse.self, from: data)
        return response.results.prefix(limit).map {
            BrowsingSearchResult(title: $0.title, url: $0.url, description: $0.snippet)
        }
    }

    private static func postRequest(
        url: String,
        apiKey: String,
        header: String,
        body: [String: Any]
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            header == "Authorization" ? "Bearer \(apiKey)" : apiKey,
            forHTTPHeaderField: header
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func data(
        for request: URLRequest,
        provider: BrowsingProvider,
        client: any BrowsingHTTPClient
    ) async throws -> Data {
        let (data, response) = try await client.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw BrowsingSearchError.invalidResponse(provider)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw BrowsingSearchError.requestFailed(provider, response.statusCode)
        }
        return data
    }

    private struct BraveResponse: Decodable { let web: BraveWeb? }
    private struct BraveWeb: Decodable { let results: [BraveResult] }
    private struct BraveResult: Decodable {
        let title: String?
        let url: String?
        let description: String?
    }
    private struct ExaResponse: Decodable { let results: [ExaResult] }
    private struct ExaResult: Decodable {
        let title: String?
        let url: String?
        let highlights: [String]?
        let text: String?
    }
    private struct NimbleResponse: Decodable { let results: [NimbleResult] }
    private struct NimbleResult: Decodable {
        let title: String?
        let url: String?
        let description: String?
        let content: String?
    }
    private struct FirecrawlResponse: Decodable { let data: FirecrawlData }
    private struct FirecrawlData: Decodable { let web: [FirecrawlResult] }
    private struct FirecrawlResult: Decodable {
        let title: String?
        let url: String?
        let description: String?
        let markdown: String?
    }
    private struct PerplexityResponse: Decodable { let results: [PerplexityResult] }
    private struct PerplexityResult: Decodable {
        let title: String?
        let url: String?
        let snippet: String?
    }
}

enum BrowsingSearchError: LocalizedError {
    case invalidQuery
    case missingAPIKey(BrowsingProvider)
    case invalidResponse(BrowsingProvider)
    case emptyResponse(BrowsingProvider)
    case requestFailed(BrowsingProvider, Int)

    static func invalidatesCredential(_ error: Error) -> Bool {
        guard let browsingError = error as? BrowsingSearchError,
              case .requestFailed(_, let status) = browsingError else {
            return false
        }
        return [401, 402, 403].contains(status)
    }

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            "web_search needs a non-empty query."
        case .missingAPIKey(let provider):
            "Add a \(provider.name) API key in Browsing first."
        case .invalidResponse(let provider):
            "\(provider.name) did not return an HTTP response."
        case .emptyResponse(let provider):
            "\(provider.name) connected but returned no search results."
        case .requestFailed(let provider, let status):
            "\(provider.name) returned HTTP \(status)."
        }
    }
}
