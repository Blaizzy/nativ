import Foundation

struct WebBrowsingProviderDocument: Sendable {
    let url: String
    let title: String?
    let content: String?
    let isExcerpt: Bool
    let error: WebReadPageError?

    init(
        url: String,
        title: String?,
        content: String?,
        isExcerpt: Bool = false,
        error: WebReadPageError?
    ) {
        self.url = url
        self.title = title
        self.content = content
        self.isExcerpt = isExcerpt
        self.error = error
    }
}

protocol WebBrowsingProviderClient: Sendable {
    var provider: WebSearchProvider { get }

    func search(apiKey: String, query: String, limit: Int) async throws -> [WebSearchResult]
    func read(apiKey: String, urls: [String], focus: String?) async throws -> [WebBrowsingProviderDocument]
}

extension WebBrowsingProviderClient {
    func read(
        apiKey _: String,
        urls _: [String],
        focus _: String?
    ) async throws -> [WebBrowsingProviderDocument] {
        throw WebReadError.unsupportedProvider(provider)
    }
}

struct WebBrowsingProviderRegistry: Sendable {
    private let transport: WebBrowsingTransport

    init(client: any WebBrowsingHTTPClient = URLSessionWebBrowsingHTTPClient()) {
        transport = WebBrowsingTransport(client: client)
    }

    func client(for provider: WebSearchProvider) -> any WebBrowsingProviderClient {
        switch provider {
        case .brave:
            BraveBrowsingProvider(transport: transport)
        case .exa:
            ExaBrowsingProvider(transport: transport)
        case .nimble:
            NimbleBrowsingProvider(transport: transport)
        case .firecrawl:
            FirecrawlBrowsingProvider(transport: transport)
        case .perplexity:
            PerplexityBrowsingProvider(transport: transport)
        case .tavily:
            TavilyBrowsingProvider(transport: transport)
        case .parallel:
            ParallelBrowsingProvider(transport: transport)
        }
    }
}

func readDocumentsIndividually(
    provider: WebSearchProvider,
    urls: [String],
    operation: @escaping @Sendable (String) async throws -> WebBrowsingProviderDocument
) async throws -> [WebBrowsingProviderDocument] {
    try await withThrowingTaskGroup(
        of: IndexedWebBrowsingDocument.self,
        returning: [WebBrowsingProviderDocument].self
    ) { group in
        for (index, url) in urls.enumerated() {
            group.addTask {
                do {
                    return IndexedWebBrowsingDocument(
                        index: index,
                        document: try await operation(url)
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return IndexedWebBrowsingDocument(
                        index: index,
                        document: try failedDocument(
                            provider: provider,
                            url: url,
                            error: error
                        )
                    )
                }
            }
        }

        var documents: [IndexedWebBrowsingDocument] = []
        documents.reserveCapacity(urls.count)
        for try await document in group {
            documents.append(document)
        }
        return documents.sorted { $0.index < $1.index }.map(\.document)
    }
}

func normalizedWebContent(_ content: String?) -> String? {
    let content = content?
        .replacingOccurrences(of: "\0", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return content?.isEmpty == false ? content : nil
}

func normalizedWebTitle(_ title: String?) -> String? {
    let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard title?.isEmpty == false else { return nil }
    return title.map { String($0.prefix(200)) }
}

private struct IndexedWebBrowsingDocument: Sendable {
    let index: Int
    let document: WebBrowsingProviderDocument
}

private func failedDocument(
    provider: WebSearchProvider,
    url: String,
    error: Error
) throws -> WebBrowsingProviderDocument {
    if let error = error as? WebBrowsingError {
        if error.shouldAbortReadBatch {
            throw error
        }
        return WebBrowsingProviderDocument(
            url: url,
            title: nil,
            content: nil,
            error: WebReadPageError(
                code: error.code.rawValue,
                message: "\(provider.metadata.displayName) could not read this page."
            )
        )
    }
    if let error = error as? WebReadError {
        return WebBrowsingProviderDocument(
            url: url,
            title: nil,
            content: nil,
            error: WebReadPageError(code: error.code, message: error.localizedDescription)
        )
    }
    return WebBrowsingProviderDocument(
        url: url,
        title: nil,
        content: nil,
        error: WebReadPageError(
            code: WebReadError.unexpectedFailure.code,
            message: WebReadError.unexpectedFailure.localizedDescription
        )
    )
}

extension WebBrowsingError {
    var shouldAbortReadBatch: Bool {
        switch self {
        case .providerUnavailable:
            true
        case .requestFailed(_, let status):
            [401, 402, 403, 429].contains(status)
        case .invalidArguments, .missingAPIKey, .credentialAccess, .invalidResponse, .responseTooLarge,
             .unexpectedFailure:
            false
        }
    }
}
