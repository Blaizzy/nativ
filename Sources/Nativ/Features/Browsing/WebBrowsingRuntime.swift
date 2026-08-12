import Foundation

struct WebBrowsingRuntime {
    private let credentials: any WebSearchCredentialStoring
    private let preferences: WebBrowsingPreferences
    private let searchService: WebSearchService
    private let readService: WebReadService

    init(
        credentials: any WebSearchCredentialStoring = KeychainWebSearchCredentialStore(),
        preferences: WebBrowsingPreferences = WebBrowsingPreferences(),
        client: any WebBrowsingHTTPClient = URLSessionWebBrowsingHTTPClient()
    ) {
        let providers = WebBrowsingProviderRegistry(client: client)
        self.credentials = credentials
        self.preferences = preferences
        searchService = WebSearchService(providers: providers)
        readService = WebReadService(providers: providers)
    }

    func isConfigured(_ capability: WebBrowsingCapability) -> Bool {
        guard let provider = preferences.provider(for: capability) else { return false }
        return preferences.credentialIssue(for: provider) == nil
            && (try? credentials.load(for: provider)) != nil
    }

    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        let provider = preferences.searchProvider
        let apiKey = try credential(for: provider)
        return try await execute(provider: provider) {
            try await searchService.search(
                provider: provider,
                apiKey: apiKey,
                query: query,
                limit: limit
            )
        }
    }

    func read(urls: [String], focus: String?) async throws -> [WebReadPage] {
        guard let provider = preferences.provider(for: .read) else {
            throw WebReadError.pageReaderNotConfigured(preferences.searchProvider)
        }
        let apiKey = try credential(for: provider)
        return try await execute(provider: provider) {
            try await readService.read(
                provider: provider,
                apiKey: apiKey,
                urls: urls,
                focus: focus
            )
        }
    }

    private func credential(for provider: WebSearchProvider) throws -> String {
        do {
            guard let apiKey = try credentials.load(for: provider) else {
                throw WebBrowsingError.missingAPIKey(provider)
            }
            return apiKey
        } catch let error as WebBrowsingError {
            throw error
        } catch {
            throw WebBrowsingError.credentialAccess(provider)
        }
    }

    private func execute<Value>(
        provider: WebSearchProvider,
        operation: () async throws -> Value
    ) async throws -> Value {
        do {
            let value = try await operation()
            preferences.setCredentialIssue(nil, for: provider)
            notifyConfigurationChanged()
            return value
        } catch {
            if let issue = (error as? WebBrowsingError)?.credentialIssue {
                preferences.setCredentialIssue(issue, for: provider)
                notifyConfigurationChanged()
            }
            throw error
        }
    }

    private func notifyConfigurationChanged() {
        NotificationCenter.default.post(name: .webBrowsingConfigurationDidChange, object: nil)
    }
}
