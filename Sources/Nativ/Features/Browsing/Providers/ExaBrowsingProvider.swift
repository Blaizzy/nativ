import Foundation

struct ExaBrowsingProvider: WebBrowsingProviderClient {
    let provider = WebSearchProvider.exa
    let transport: WebBrowsingTransport

    func search(apiKey: String, query: String, limit: Int) async throws -> [WebSearchResult] {
        let request = try transport.postRequest(
            url: "https://api.exa.ai/search",
            provider: provider,
            apiKey: apiKey,
            authentication: .header("x-api-key"),
            body: ExaSearchRequest(
                query: query,
                numResults: limit,
                type: "fast",
                contents: ExaSearchContents(highlights: true)
            )
        )
        let response: ExaSearchResponse = try await transport.response(for: request, provider: provider)
        return response.results.prefix(limit).compactMap {
            WebSearchResult(
                title: $0.title,
                url: $0.url,
                snippet: $0.highlights?.first ?? $0.text
            )
        }
    }

    func read(
        apiKey: String,
        urls: [String],
        focus: String?
    ) async throws -> [WebBrowsingProviderDocument] {
        let highlights = focus.map {
            ExaHighlightsRequest(query: $0, maxCharacters: WebReadService.maximumCharactersPerPage)
        }
        let request = try transport.postRequest(
            url: "https://api.exa.ai/contents",
            provider: provider,
            apiKey: apiKey,
            authentication: .header("x-api-key"),
            body: ExaReadRequest(
                urls: urls,
                text: highlights == nil ? true : nil,
                highlights: highlights
            ),
            timeout: 30
        )
        let response: ExaReadResponse = try await transport.response(for: request, provider: provider)
        return urls.map { requestedURL in
            guard let result = response.results.first(where: {
                $0.id == requestedURL || $0.url == requestedURL
            }) else {
                return unavailableDocument(url: requestedURL, title: nil)
            }
            let highlightedContent = normalizedWebContent(
                result.highlights?
                    .compactMap(normalizedWebContent)
                    .joined(separator: "\n\n")
            )
            guard let content = highlightedContent ?? normalizedWebContent(result.text) else {
                return unavailableDocument(url: requestedURL, title: result.title)
            }
            return WebBrowsingProviderDocument(
                url: requestedURL,
                title: normalizedWebTitle(result.title),
                content: content,
                isExcerpt: highlightedContent != nil,
                error: nil
            )
        }
    }

    private func unavailableDocument(url: String, title: String?) -> WebBrowsingProviderDocument {
        WebBrowsingProviderDocument(
            url: url,
            title: normalizedWebTitle(title),
            content: nil,
            error: WebReadPageError(
                code: "page_unavailable",
                message: "Exa could not read this page."
            )
        )
    }
}

private struct ExaSearchRequest: Encodable {
    let query: String
    let numResults: Int
    let type: String
    let contents: ExaSearchContents
}

private struct ExaSearchContents: Encodable {
    let highlights: Bool
}

private struct ExaSearchResponse: Decodable {
    let results: [ExaSearchResult]
}

private struct ExaSearchResult: Decodable {
    let title: String?
    let url: String?
    let highlights: [String]?
    let text: String?
}

private struct ExaReadRequest: Encodable {
    let urls: [String]
    let text: Bool?
    let highlights: ExaHighlightsRequest?
}

private struct ExaHighlightsRequest: Encodable {
    let query: String
    let maxCharacters: Int
}

private struct ExaReadResponse: Decodable {
    let results: [ExaReadResult]
}

private struct ExaReadResult: Decodable {
    let id: String?
    let title: String?
    let url: String?
    let text: String?
    let highlights: [String]?
}
