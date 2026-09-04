import Foundation

struct SearXNGBrowsingProvider: WebBrowsingProviderClient {
    let provider = WebSearchProvider.searxng
    let transport: WebBrowsingTransport

    func search(
        access: WebSearchProviderAccess,
        query: String,
        limit: Int
    ) async throws -> [WebSearchResult] {
        let instanceURL = try access.instanceURL(for: provider)
        let searchURL = instanceURL.appendingPathComponent("search", isDirectory: false)
        guard var components = URLComponents(
            url: searchURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw WebBrowsingError.invalidResponse(provider)
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else {
            throw WebBrowsingError.invalidResponse(provider)
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response: SearXNGSearchResponse = try await transport.response(
            for: request,
            provider: provider
        )
        return response.results.prefix(limit).compactMap {
            WebSearchResult(title: $0.title, url: $0.url, snippet: $0.content)
        }
    }
}

private struct SearXNGSearchResponse: Decodable {
    let results: [SearXNGSearchResult]
}

private struct SearXNGSearchResult: Decodable {
    let title: String?
    let url: String?
    let content: String?
}
