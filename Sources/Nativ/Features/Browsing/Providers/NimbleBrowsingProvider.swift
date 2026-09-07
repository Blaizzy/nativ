import Foundation

struct NimbleBrowsingProvider: WebBrowsingProviderClient {
    let provider = WebSearchProvider.nimble
    let transport: WebBrowsingTransport

    func search(
        access: WebSearchProviderAccess,
        query: String,
        limit: Int
    ) async throws -> [WebSearchResult] {
        let apiKey = try access.apiKey(for: provider)
        let request = try transport.postRequest(
            url: "https://sdk.nimbleway.com/v2/search",
            provider: provider,
            apiKey: apiKey,
            authentication: .bearer,
            body: NimbleSearchRequest(query: query, maxResults: limit)
        )
        let response: NimbleSearchResponse = try await transport.response(for: request, provider: provider)
        return response.results.prefix(limit).compactMap {
            WebSearchResult(
                title: $0.title,
                url: $0.url,
                snippet: $0.description ?? $0.content
            )
        }
    }

    func read(
        apiKey: String,
        urls: [String],
        focus _: String?
    ) async throws -> [WebBrowsingProviderDocument] {
        try await readDocumentsIndividually(provider: provider, urls: urls) { url in
            let request = try self.transport.postRequest(
                url: "https://sdk.nimbleway.com/v2/extract",
                provider: self.provider,
                apiKey: apiKey,
                authentication: .bearer,
                body: NimbleReadRequest(url: url, formats: ["markdown"], render: "auto"),
                timeout: 30
            )
            let response: NimbleReadResponse = try await self.transport.response(
                for: request,
                provider: self.provider
            )
            guard response.status == "success",
                  let content = normalizedWebContent(response.data.markdown) else {
                throw WebReadError.pageUnavailable(self.provider)
            }
            return WebBrowsingProviderDocument(
                url: url,
                title: nil,
                content: content,
                error: nil
            )
        }
    }
}

private struct NimbleSearchRequest: Encodable {
    let query: String
    let maxResults: Int

    enum CodingKeys: String, CodingKey {
        case query
        case maxResults = "max_results"
    }
}

private struct NimbleSearchResponse: Decodable {
    let results: [NimbleSearchResult]
}

private struct NimbleSearchResult: Decodable {
    let title: String?
    let url: String?
    let description: String?
    let content: String?
}

private struct NimbleReadRequest: Encodable {
    let url: String
    let formats: [String]
    let render: String
}

private struct NimbleReadResponse: Decodable {
    let status: String
    let data: NimbleReadData
}

private struct NimbleReadData: Decodable {
    let markdown: String?
}
