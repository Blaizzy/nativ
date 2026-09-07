import Foundation

extension Notification.Name {
    static let webBrowsingConfigurationDidChange = Notification.Name(
        "nativ.web-browsing.configuration-did-change"
    )
}

enum WebBrowsingCapability: Hashable, Sendable {
    case search
    case read
}

enum WebSearchProviderConfigurationKind: Equatable, Sendable {
    case apiKey
    case instanceURL
}

enum WebSearchProvider: String, CaseIterable, Identifiable, Sendable {
    case brave
    case exa
    case nimble
    case firecrawl
    case perplexity
    case tavily
    case parallel
    case searxng

    var id: String { rawValue }

    static var pageReaders: [Self] {
        allCases.filter { $0.supports(.read) }
    }

    func supports(_ capability: WebBrowsingCapability) -> Bool {
        switch capability {
        case .search:
            true
        case .read:
            switch self {
            case .exa, .nimble, .firecrawl, .tavily, .parallel:
                true
            case .brave, .perplexity, .searxng:
                false
            }
        }
    }

    var metadata: WebSearchProviderMetadata {
        switch self {
        case .brave:
            WebSearchProviderMetadata(
                displayName: "Brave",
                logoResourceName: "Brave",
                setupURL: .webSearchURL("https://api-dashboard.search.brave.com/app/keys")
            )
        case .exa:
            WebSearchProviderMetadata(
                displayName: "Exa",
                logoResourceName: "Exa",
                setupURL: .webSearchURL("https://dashboard.exa.ai/api-keys")
            )
        case .nimble:
            WebSearchProviderMetadata(
                displayName: "Nimble",
                logoResourceName: "Nimble",
                setupURL: .webSearchURL("https://online.nimbleway.com/settings/api-keys")
            )
        case .firecrawl:
            WebSearchProviderMetadata(
                displayName: "Firecrawl",
                logoResourceName: "Firecrawl",
                setupURL: .webSearchURL("https://www.firecrawl.dev/app/api-keys")
            )
        case .perplexity:
            WebSearchProviderMetadata(
                displayName: "Perplexity",
                logoResourceName: "Perplexity",
                setupURL: .webSearchURL("https://console.perplexity.ai/group/keys")
            )
        case .tavily:
            WebSearchProviderMetadata(
                displayName: "Tavily",
                logoResourceName: "Tavily",
                rendersLogoAsTemplate: true,
                setupURL: .webSearchURL("https://app.tavily.com")
            )
        case .parallel:
            WebSearchProviderMetadata(
                displayName: "Parallel",
                logoResourceName: "Parallel",
                rendersLogoAsTemplate: true,
                setupURL: .webSearchURL("https://platform.parallel.ai")
            )
        case .searxng:
            WebSearchProviderMetadata(
                displayName: "SearXNG",
                logoResourceName: "SearXNG",
                configurationKind: .instanceURL,
                setupURL: .webSearchURL("https://docs.searxng.org/dev/search_api.html")
            )
        }
    }
}

struct WebSearchProviderMetadata: Sendable {
    let displayName: String
    let logoResourceName: String
    var rendersLogoAsTemplate = false
    var configurationKind = WebSearchProviderConfigurationKind.apiKey
    let setupURL: URL
}

enum WebSearchCredentialIssue: String, Sendable {
    case invalidAuthentication = "invalid_authentication"
    case insufficientFunds = "insufficient_funds"
    case planAccess = "plan_access"
}

struct WebBrowsingPreferences {
    private let defaults: UserDefaults
    private let searchProviderKey = "nativ.web-search.active-provider.v1"
    private let pageReaderProviderKey = "nativ.web-browsing.page-reader-provider.v1"
    private let credentialIssueKeyPrefix = "nativ.web-search.credential-issue.v1."
    private let endpointKeyPrefix = "nativ.web-search.endpoint.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var searchProvider: WebSearchProvider {
        get {
            guard let rawValue = defaults.string(forKey: searchProviderKey),
                  let provider = WebSearchProvider(rawValue: rawValue) else {
                return .brave
            }
            return provider
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: searchProviderKey)
        }
    }

    var pageReaderProvider: WebSearchProvider? {
        get {
            guard let rawValue = defaults.string(forKey: pageReaderProviderKey),
                  let provider = WebSearchProvider(rawValue: rawValue),
                  provider.supports(.read) else {
                return nil
            }
            return provider
        }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: pageReaderProviderKey)
                return
            }
            guard newValue.supports(.read) else { return }
            defaults.set(newValue.rawValue, forKey: pageReaderProviderKey)
        }
    }

    func provider(for capability: WebBrowsingCapability) -> WebSearchProvider? {
        switch capability {
        case .search:
            searchProvider
        case .read:
            pageReaderProvider ?? (searchProvider.supports(.read) ? searchProvider : nil)
        }
    }

    func credentialIssue(for provider: WebSearchProvider) -> WebSearchCredentialIssue? {
        defaults.string(forKey: credentialIssueKey(for: provider))
            .flatMap(WebSearchCredentialIssue.init(rawValue:))
    }

    func setCredentialIssue(_ issue: WebSearchCredentialIssue?, for provider: WebSearchProvider) {
        let key = credentialIssueKey(for: provider)
        if let issue {
            defaults.set(issue.rawValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func endpoint(for provider: WebSearchProvider) -> URL? {
        guard provider.metadata.configurationKind == .instanceURL,
              let value = defaults.string(forKey: endpointKey(for: provider)) else {
            return nil
        }
        return WebSearchInstanceURL.normalized(value)
    }

    func setEndpoint(_ endpoint: URL?, for provider: WebSearchProvider) {
        guard provider.metadata.configurationKind == .instanceURL else { return }
        let key = endpointKey(for: provider)
        if let endpoint {
            defaults.set(endpoint.absoluteString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func credentialIssueKey(for provider: WebSearchProvider) -> String {
        credentialIssueKeyPrefix + provider.rawValue
    }

    private func endpointKey(for provider: WebSearchProvider) -> String {
        endpointKeyPrefix + provider.rawValue
    }
}

enum WebSearchInstanceURL {
    static func normalized(_ value: String) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        components.scheme = scheme
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url
    }
}

protocol WebSearchCredentialStoring {
    func load(for provider: WebSearchProvider) throws -> String?
    func save(_ key: String, for provider: WebSearchProvider) throws
    func remove(for provider: WebSearchProvider) throws
}

struct KeychainWebSearchCredentialStore: WebSearchCredentialStoring {
    private let servicePrefix = "dev.local.Nativ.web-search."

    func load(for provider: WebSearchProvider) throws -> String? {
        try keychain(for: provider).load()
    }

    func save(_ key: String, for provider: WebSearchProvider) throws {
        guard let key = ServerAPIAuthentication.normalizedToken(key) else {
            throw WebSearchCredentialError.emptyKey
        }
        try keychain(for: provider).save(key)
    }

    func remove(for provider: WebSearchProvider) throws {
        try keychain(for: provider).save(nil)
    }

    private func keychain(for provider: WebSearchProvider) -> ServerAPIKeychain {
        ServerAPIKeychain(
            service: servicePrefix + provider.rawValue,
            account: "api-key"
        )
    }
}

enum WebSearchCredentialError: LocalizedError {
    case emptyKey

    var errorDescription: String? {
        "Enter an API key before connecting."
    }
}

private extension URL {
    static func webSearchURL(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            // These are hardcoded literals; flag a bad one in debug but degrade
            // gracefully in release rather than crashing the whole app.
            assertionFailure("Invalid web search URL: \(value)")
            return URL(string: "https://example.com")!
        }
        return url
    }
}
