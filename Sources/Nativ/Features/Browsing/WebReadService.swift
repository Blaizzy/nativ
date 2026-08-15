import Foundation

struct WebReadPage: Encodable, Equatable, Sendable {
    let url: String
    let title: String?
    let content: String?
    let truncated: Bool
    let error: WebReadPageError?

    var isSuccess: Bool { content != nil && error == nil }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(content, forKey: .content)
        if truncated {
            try container.encode(true, forKey: .truncated)
        }
        try container.encodeIfPresent(error, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey {
        case url, title, content, truncated, error
    }
}

struct WebReadPageError: Codable, Equatable, Sendable {
    let code: String
    let message: String
}

struct WebReadService: Sendable {
    static let maximumURLs = 4
    static let maximumFocusLength = 500
    static let maximumCharactersPerPage = 6_000
    private static let maximumTotalCharacters = 20_000
    private let providers: WebBrowsingProviderRegistry

    init(client: any WebBrowsingHTTPClient = URLSessionWebBrowsingHTTPClient()) {
        providers = WebBrowsingProviderRegistry(client: client)
    }

    init(providers: WebBrowsingProviderRegistry) {
        self.providers = providers
    }

    func read(
        provider: WebSearchProvider,
        apiKey: String,
        urls: [String],
        focus: String? = nil
    ) async throws -> [WebReadPage] {
        guard provider.supports(.read) else {
            throw WebReadError.unsupportedProvider(provider)
        }
        guard (1 ... Self.maximumURLs).contains(urls.count) else {
            throw WebReadError.invalidArguments
        }

        let normalizedURLs = try urls.map {
            guard let url = WebReadURLPolicy.normalizedURL($0) else {
                throw WebReadError.invalidURL
            }
            return url
        }
        guard Set(normalizedURLs).count == normalizedURLs.count else {
            throw WebReadError.invalidArguments
        }
        let focus = focus?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard focus?.count ?? 0 <= Self.maximumFocusLength else {
            throw WebReadError.invalidArguments
        }
        let normalizedFocus = focus?.isEmpty == false ? focus : nil

        let documents = try await providers.client(for: provider).read(
            apiKey: apiKey,
            urls: normalizedURLs,
            focus: normalizedFocus
        )

        return boundedPages(documents, focus: normalizedFocus)
    }

    private func boundedPages(
        _ documents: [WebBrowsingProviderDocument],
        focus: String?
    ) -> [WebReadPage] {
        let successfulDocumentCount = max(
            documents.filter { $0.content != nil && $0.error == nil }.count,
            1
        )
        let perPageLimit = min(
            Self.maximumCharactersPerPage,
            Self.maximumTotalCharacters / successfulDocumentCount
        )
        var remainingCharacters = Self.maximumTotalCharacters
        return documents.map { document in
            guard let content = document.content, document.error == nil else {
                // Never report a content-less page as a silent success: synthesize
                // an error when the provider returned neither content nor an error
                // so the caller can tell "empty page" from "read failed".
                return WebReadPage(
                    url: document.url,
                    title: document.title,
                    content: nil,
                    truncated: false,
                    error: document.error ?? WebReadPageError(
                        code: "empty_content",
                        message: "The provider returned no readable content for this URL."
                    )
                )
            }

            let limit = min(perPageLimit, remainingCharacters)
            let selection = WebReadContentSelector.select(content, focus: focus, limit: limit)
            remainingCharacters -= selection.content.count
            return WebReadPage(
                url: document.url,
                title: document.title,
                content: selection.content,
                truncated: document.isExcerpt || selection.truncated,
                error: nil
            )
        }
    }

}

enum WebReadURLPolicy {
    private static let sensitiveQueryNames: Set<String> = [
        "access_token", "api_key", "apikey", "auth", "authorization", "key", "password",
        "secret", "signature", "sig", "token",
    ]

    static func normalizedURL(
        _ value: String,
        rejectsSensitiveQuery: Bool = true
    ) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2_048,
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              isPublicHost(host),
              (!rejectsSensitiveQuery || !containsSensitiveQuery(components.queryItems)) else {
            return nil
        }
        components.fragment = nil
        return components.url?.absoluteString
    }

    private static func containsSensitiveQuery(_ items: [URLQueryItem]?) -> Bool {
        items?.contains { sensitiveQueryNames.contains($0.name.lowercased()) } == true
    }

    private static func isPublicHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        let blockedNames = ["localhost", "localhost.localdomain"]
        guard !blockedNames.contains(host),
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"),
              !host.hasSuffix(".lan"),
              !host.hasSuffix(".home") else {
            return false
        }
        if let octets = ipv4Octets(host) {
            return isPublicIPv4(octets)
        }
        if isAmbiguousNumericHost(host) {
            return false
        }
        if host.contains(":") {
            return isPublicIPv6(host)
        }
        return host.contains(".")
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0 ... 255).contains($0) }) else {
            return nil
        }
        return octets
    }

    private static func isAmbiguousNumericHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return !labels.isEmpty && labels.allSatisfy { label in
            let label = label.lowercased()
            if label.hasPrefix("0x") {
                return !label.dropFirst(2).isEmpty
                    && label.dropFirst(2).allSatisfy { $0.isHexDigit }
            }
            return label.allSatisfy { $0.isNumber }
        }
    }

    private static func isPublicIPv4(_ octets: [Int]) -> Bool {
        let first = octets[0]
        let second = octets[1]
        switch first {
        case 0, 10, 127, 224 ... 255:
            return false
        case 100 where (64 ... 127).contains(second):
            return false
        case 169 where second == 254:
            return false
        case 172 where (16 ... 31).contains(second):
            return false
        case 192 where second == 168 || (second == 0 && octets[2] == 0):
            return false
        case 198 where (18 ... 19).contains(second):
            return false
        default:
            return true
        }
    }

    private static func isPublicIPv6(_ host: String) -> Bool {
        let host = host.lowercased()
        guard host != "::", host != "::1", !host.hasPrefix("::ffff:") else {
            return false
        }
        return !host.hasPrefix("fc")
            && !host.hasPrefix("fd")
            && !host.hasPrefix("fe8")
            && !host.hasPrefix("fe9")
            && !host.hasPrefix("fea")
            && !host.hasPrefix("feb")
    }
}

enum WebReadError: LocalizedError {
    case invalidArguments
    case invalidURL
    case pageReaderNotConfigured(WebSearchProvider)
    case unsupportedProvider(WebSearchProvider)
    case pageUnavailable(WebSearchProvider)
    case unexpectedFailure

    var code: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .invalidURL: "invalid_url"
        case .pageReaderNotConfigured: "page_reader_not_configured"
        case .unsupportedProvider: "unsupported_provider"
        case .pageUnavailable: "page_unavailable"
        case .unexpectedFailure: "unexpected_failure"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "web_read needs one to four unique URLs and an optional focus no longer than \(WebReadService.maximumFocusLength) characters."
        case .invalidURL:
            "web_read accepts only public HTTP or HTTPS URLs without embedded credentials."
        case .pageReaderNotConfigured(let searchProvider):
            "\(searchProvider.metadata.displayName) supports web search but not page reading."
        case .unsupportedProvider(let provider):
            "\(provider.metadata.displayName) does not support reading arbitrary URLs."
        case .pageUnavailable(let provider):
            "\(provider.metadata.displayName) could not read this page."
        case .unexpectedFailure:
            "Web read failed unexpectedly."
        }
    }
}
