import Foundation

struct FirecrawlBrowsingProvider: WebBrowsingProviderClient {
    let provider = WebSearchProvider.firecrawl
    let transport: WebBrowsingTransport

    func search(apiKey: String, query: String, limit: Int) async throws -> [WebSearchResult] {
        let request = try transport.postRequest(
            url: "https://api.firecrawl.dev/v2/search",
            provider: provider,
            apiKey: apiKey,
            authentication: .bearer,
            body: FirecrawlSearchRequest(query: query, limit: limit, sources: ["web"])
        )
        let response: FirecrawlSearchResponse = try await transport.response(for: request, provider: provider)
        return response.data.web.prefix(limit).compactMap {
            WebSearchResult(
                title: $0.title,
                url: $0.url,
                snippet: $0.description ?? $0.markdown
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
                url: "https://api.firecrawl.dev/v2/scrape",
                provider: self.provider,
                apiKey: apiKey,
                authentication: .bearer,
                body: FirecrawlReadRequest(
                    url: url,
                    formats: ["markdown"],
                    onlyMainContent: true,
                    removeBase64Images: true
                ),
                timeout: 30
            )
            let response: FirecrawlReadResponse = try await self.transport.response(
                for: request,
                provider: self.provider
            )
            guard response.success,
                  let content = normalizedWebContent(response.data.markdown) else {
                throw WebReadError.pageUnavailable(self.provider)
            }
            return WebBrowsingProviderDocument(
                url: url,
                title: normalizedWebTitle(response.data.metadata?.title),
                content: content,
                error: nil
            )
        }
    }
}

private struct FirecrawlSearchRequest: Encodable {
    let query: String
    let limit: Int
    let sources: [String]
}

private struct FirecrawlSearchResponse: Decodable {
    let data: FirecrawlSearchData
}

private struct FirecrawlSearchData: Decodable {
    let web: [FirecrawlSearchResult]
}

private struct FirecrawlSearchResult: Decodable {
    let title: String?
    let url: String?
    let description: String?
    let markdown: String?
}

private struct FirecrawlReadRequest: Encodable {
    let url: String
    let formats: [String]
    let onlyMainContent: Bool
    let removeBase64Images: Bool
}

private struct FirecrawlReadResponse: Decodable {
    let success: Bool
    let data: FirecrawlReadData
}

private struct FirecrawlReadData: Decodable {
    let markdown: String?
    let metadata: FirecrawlReadMetadata?
}

private struct FirecrawlReadMetadata: Decodable {
    let title: String?
}
