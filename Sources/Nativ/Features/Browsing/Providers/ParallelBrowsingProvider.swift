import Foundation

struct ParallelBrowsingProvider: WebBrowsingProviderClient {
    let provider = WebSearchProvider.parallel
    let transport: WebBrowsingTransport

    func search(
        access: WebSearchProviderAccess,
        query: String,
        limit: Int
    ) async throws -> [WebSearchResult] {
        let apiKey = try access.apiKey(for: provider)
        let request = try transport.postRequest(
            url: "https://api.parallel.ai/v1/search",
            provider: provider,
            apiKey: apiKey,
            authentication: .header("x-api-key"),
            body: ParallelSearchRequest(
                objective: query,
                searchQueries: [String(query.prefix(200))],
                mode: "basic",
                maxCharactersTotal: limit * 500
            )
        )
        let response: ParallelSearchResponse = try await transport.response(
            for: request,
            provider: provider
        )
        return response.results.prefix(limit).compactMap {
            WebSearchResult(
                title: $0.title,
                url: $0.url,
                snippet: $0.excerpts.joined(separator: "\n\n")
            )
        }
    }

    func read(
        apiKey: String,
        urls: [String],
        focus: String?
    ) async throws -> [WebBrowsingProviderDocument] {
        let request = try transport.postRequest(
            url: "https://api.parallel.ai/v1/extract",
            provider: provider,
            apiKey: apiKey,
            authentication: .header("x-api-key"),
            body: ParallelExtractRequest(
                urls: urls,
                objective: focus,
                maxCharactersTotal: min(
                    WebReadService.maximumCharactersPerPage * urls.count,
                    20_000
                ),
                advancedSettings: focus == nil
                    ? ParallelExtractAdvancedSettings(
                        fullContent: ParallelFullContentSettings(
                            maxCharactersPerResult: WebReadService.maximumCharactersPerPage
                        )
                    )
                    : nil
            ),
            timeout: 30
        )
        let response: ParallelExtractResponse = try await transport.response(
            for: request,
            provider: provider
        )
        return urls.map { requestedURL in
            guard let result = response.results.first(where: { $0.url == requestedURL }) else {
                return unavailableDocument(url: requestedURL)
            }
            let excerpts = normalizedWebContent(result.excerpts.joined(separator: "\n\n"))
            let fullContent = normalizedWebContent(result.fullContent)
            guard let content = focus == nil ? (fullContent ?? excerpts) : (excerpts ?? fullContent) else {
                return unavailableDocument(url: requestedURL)
            }
            return WebBrowsingProviderDocument(
                url: requestedURL,
                title: normalizedWebTitle(result.title),
                content: content,
                isExcerpt: focus != nil || fullContent == nil,
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
                message: "Parallel could not read this page."
            )
        )
    }
}

private struct ParallelSearchRequest: Encodable {
    let objective: String
    let searchQueries: [String]
    let mode: String
    let maxCharactersTotal: Int

    enum CodingKeys: String, CodingKey {
        case objective, mode
        case searchQueries = "search_queries"
        case maxCharactersTotal = "max_chars_total"
    }
}

private struct ParallelSearchResponse: Decodable {
    let results: [ParallelSearchResult]
}

private struct ParallelSearchResult: Decodable {
    let url: String?
    let title: String?
    let excerpts: [String]
}

private struct ParallelExtractRequest: Encodable {
    let urls: [String]
    let objective: String?
    let maxCharactersTotal: Int
    let advancedSettings: ParallelExtractAdvancedSettings?

    enum CodingKeys: String, CodingKey {
        case urls, objective
        case maxCharactersTotal = "max_chars_total"
        case advancedSettings = "advanced_settings"
    }
}

private struct ParallelExtractAdvancedSettings: Encodable {
    let fullContent: ParallelFullContentSettings

    enum CodingKeys: String, CodingKey {
        case fullContent = "full_content"
    }
}

private struct ParallelFullContentSettings: Encodable {
    let maxCharactersPerResult: Int

    enum CodingKeys: String, CodingKey {
        case maxCharactersPerResult = "max_chars_per_result"
    }
}

private struct ParallelExtractResponse: Decodable {
    let results: [ParallelExtractResult]
}

private struct ParallelExtractResult: Decodable {
    let url: String
    let title: String?
    let excerpts: [String]
    let fullContent: String?

    enum CodingKeys: String, CodingKey {
        case url, title, excerpts
        case fullContent = "full_content"
    }
}
