import Foundation

struct PerplexityBrowsingProvider: WebBrowsingProviderClient {
    let provider = WebSearchProvider.perplexity
    let transport: WebBrowsingTransport

    func search(apiKey: String, query: String, limit: Int) async throws -> [WebSearchResult] {
        let request = try transport.postRequest(
            url: "https://api.perplexity.ai/search",
            provider: provider,
            apiKey: apiKey,
            authentication: .bearer,
            body: PerplexitySearchRequest(query: query, maxResults: limit)
        )
        let response: PerplexitySearchResponse = try await transport.response(for: request, provider: provider)
        return response.results.prefix(limit).compactMap {
            WebSearchResult(title: $0.title, url: $0.url, snippet: $0.snippet)
        }
    }
}

private struct PerplexitySearchRequest: Encodable {
    let query: String
    let maxResults: Int

    enum CodingKeys: String, CodingKey {
        case query
        case maxResults = "max_results"
    }
}

private struct PerplexitySearchResponse: Decodable {
    let results: [PerplexitySearchResult]
}

private struct PerplexitySearchResult: Decodable {
    let title: String?
    let url: String?
    let snippet: String?
}
