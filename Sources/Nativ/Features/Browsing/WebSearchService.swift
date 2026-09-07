import Foundation

struct WebSearchResult: Codable, Equatable, Sendable {
    let title: String
    let url: String
    let snippet: String

    init?(title: String?, url: String?, snippet: String?) {
        guard let rawURL = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              rawURL.count <= 2_048,
              let parsedURL = URL(string: rawURL),
              ["http", "https"].contains(parsedURL.scheme?.lowercased()),
              parsedURL.host?.isEmpty == false,
              parsedURL.user == nil,
              parsedURL.password == nil else {
            return nil
        }
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = String(
            (normalizedTitle?.isEmpty == false ? normalizedTitle : parsedURL.host) ?? "Search result"
        ).prefixString(160)
        self.url = rawURL
        self.snippet = String((snippet ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            .prefixString(500)
    }
}

struct WebSearchService: Sendable {
    private let providers: WebBrowsingProviderRegistry

    init(client: any WebBrowsingHTTPClient = URLSessionWebBrowsingHTTPClient()) {
        providers = WebBrowsingProviderRegistry(client: client)
    }

    init(providers: WebBrowsingProviderRegistry) {
        self.providers = providers
    }

    func validateCredential(provider: WebSearchProvider, apiKey: String) async throws {
        try await validate(provider: provider, access: .apiKey(apiKey))
    }

    func validate(
        provider: WebSearchProvider,
        access: WebSearchProviderAccess
    ) async throws {
        _ = try await search(
            provider: provider,
            access: access,
            query: "Nativ local AI",
            limit: 1
        )
    }

    func search(
        provider: WebSearchProvider,
        apiKey: String,
        query: String,
        limit: Int
    ) async throws -> [WebSearchResult] {
        try await search(
            provider: provider,
            access: .apiKey(apiKey),
            query: query,
            limit: limit
        )
    }

    func search(
        provider: WebSearchProvider,
        access: WebSearchProviderAccess,
        query: String,
        limit: Int
    ) async throws -> [WebSearchResult] {
        guard let query = normalizedQuery(query) else {
            throw WebBrowsingError.invalidArguments
        }
        return try await providers.client(for: provider).search(
            access: access,
            query: query,
            limit: min(max(limit, 1), 10)
        )
    }

    private func normalizedQuery(_ query: String) -> String? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return query.prefixString(300)
    }
}

private extension String {
    func prefixString(_ maximumLength: Int) -> String {
        String(prefix(maximumLength))
    }
}
