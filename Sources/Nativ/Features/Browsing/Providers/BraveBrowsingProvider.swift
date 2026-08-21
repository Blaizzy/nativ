import Foundation

struct BraveBrowsingProvider: WebBrowsingProviderClient {
    let provider = WebSearchProvider.brave
    let transport: WebBrowsingTransport

    func search(apiKey: String, query: String, limit: Int) async throws -> [WebSearchResult] {
        guard var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search") else {
            throw WebBrowsingError.invalidResponse(provider)
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(limit)),
        ]
        guard let url = components.url else {
            throw WebBrowsingError.invalidResponse(provider)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        let response: BraveResponse = try await transport.response(for: request, provider: provider)
        return response.web?.results.prefix(limit).compactMap {
            WebSearchResult(title: $0.title, url: $0.url, snippet: $0.description)
        } ?? []
    }
}

private struct BraveResponse: Decodable {
    let web: BraveWeb?
}

private struct BraveWeb: Decodable {
    let results: [BraveResult]
}

private struct BraveResult: Decodable {
    let title: String?
    let url: String?
    let description: String?
}
