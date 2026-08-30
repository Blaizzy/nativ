import Foundation

struct TavilyBrowsingProvider: WebBrowsingProviderClient {
    let provider = WebSearchProvider.tavily
    let transport: WebBrowsingTransport

    func search(apiKey: String, query: String, limit: Int) async throws -> [WebSearchResult] {
        let request = try transport.postRequest(
            url: "https://api.tavily.com/search",
            provider: provider,
            apiKey: apiKey,
            authentication: .bearer,
            body: TavilySearchRequest(
                query: query,
                maxResults: limit,
                searchDepth: "fast",
                includeAnswer: false,
                includeRawContent: false,
                includeImages: false
            )
        )
        let response: TavilySearchResponse = try await transport.response(
            for: request,
            provider: provider
        )
        return response.results.prefix(limit).compactMap {
            WebSearchResult(title: $0.title, url: $0.url, snippet: $0.content)
        }
    }

    func read(
        apiKey: String,
        urls: [String],
        focus: String?
    ) async throws -> [WebBrowsingProviderDocument] {
        let request = try transport.postRequest(
            url: "https://api.tavily.com/extract",
            provider: provider,
            apiKey: apiKey,
            authentication: .bearer,
            body: TavilyExtractRequest(
                urls: urls,
                query: focus,
                chunksPerSource: focus == nil ? nil : 5,
                extractDepth: "basic",
                includeImages: false,
                format: "markdown"
            ),
            timeout: 30
        )
        let response: TavilyExtractResponse = try await transport.response(
            for: request,
            provider: provider
        )
        return urls.map { requestedURL in
            guard let result = response.results.first(where: { $0.url == requestedURL }),
                  let content = normalizedWebContent(result.rawContent) else {
                return unavailableDocument(url: requestedURL)
            }
            return WebBrowsingProviderDocument(
                url: requestedURL,
                title: nil,
                content: content,
                isExcerpt: focus != nil,
                error: nil
            )
        }
    }

    private func unavailableDocument(url: String) -> WebBrowsingProviderDocument {
        WebBrowsingProviderDocument(
            url: url,
            title: nil,
            content: nil,
            error: WebReadPageError(
                code: "page_unavailable",
                message: "Tavily could not read this page."
            )
        )
    }
}

private struct TavilySearchRequest: Encodable {
    let query: String
    let maxResults: Int
    let searchDepth: String
    let includeAnswer: Bool
    let includeRawContent: Bool
    let includeImages: Bool

    enum CodingKeys: String, CodingKey {
        case query
        case maxResults = "max_results"
        case searchDepth = "search_depth"
        case includeAnswer = "include_answer"
        case includeRawContent = "include_raw_content"
        case includeImages = "include_images"
    }
}

private struct TavilySearchResponse: Decodable {
    let results: [TavilySearchResult]
}

private struct TavilySearchResult: Decodable {
    let title: String?
    let url: String?
    let content: String?
}

private struct TavilyExtractRequest: Encodable {
    let urls: [String]
    let query: String?
    let chunksPerSource: Int?
    let extractDepth: String
    let includeImages: Bool
    let format: String

    enum CodingKeys: String, CodingKey {
        case urls, query, format
        case chunksPerSource = "chunks_per_source"
        case extractDepth = "extract_depth"
        case includeImages = "include_images"
    }
}

private struct TavilyExtractResponse: Decodable {
    let results: [TavilyExtractResult]
}

private struct TavilyExtractResult: Decodable {
    let url: String
    let rawContent: String?

    enum CodingKeys: String, CodingKey {
        case url
        case rawContent = "raw_content"
    }
}
