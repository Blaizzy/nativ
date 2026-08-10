import Foundation

enum WebSearchProvider: String, CaseIterable, Identifiable, Sendable {
    case brave
    case exa
    case nimble
    case firecrawl
    case perplexity

    var id: String { rawValue }

    var metadata: WebSearchProviderMetadata {
        switch self {
        case .brave:
            WebSearchProviderMetadata(
                displayName: "Brave",
                logoResourceName: "Brave",
                apiKeySetupURL: .webSearchURL("https://api-dashboard.search.brave.com/app/keys")
            )
        case .exa:
            WebSearchProviderMetadata(
                displayName: "Exa",
                logoResourceName: "Exa",
                apiKeySetupURL: .webSearchURL("https://dashboard.exa.ai/api-keys")
            )
        case .nimble:
            WebSearchProviderMetadata(
                displayName: "Nimble",
                logoResourceName: "Nimble",
                apiKeySetupURL: .webSearchURL("https://online.nimbleway.com/settings/api-keys")
            )
        case .firecrawl:
            WebSearchProviderMetadata(
                displayName: "Firecrawl",
                logoResourceName: "Firecrawl",
                apiKeySetupURL: .webSearchURL("https://www.firecrawl.dev/app/api-keys")
            )
        case .perplexity:
            WebSearchProviderMetadata(
                displayName: "Perplexity",
                logoResourceName: "Perplexity",
                apiKeySetupURL: .webSearchURL("https://console.perplexity.ai/group/keys")
            )
        }
    }
}

struct WebSearchProviderMetadata: Sendable {
    let displayName: String
    let logoResourceName: String
    let apiKeySetupURL: URL
}

enum WebSearchCredentialIssue: String, Sendable {
    case invalidAuthentication = "invalid_authentication"
    case insufficientFunds = "insufficient_funds"
    case planAccess = "plan_access"
}

struct WebSearchPreferences {
    private let defaults: UserDefaults
    private let activeProviderKey = "nativ.web-search.active-provider.v1"
    private let credentialIssueKeyPrefix = "nativ.web-search.credential-issue.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var activeProvider: WebSearchProvider {
        get {
            guard let rawValue = defaults.string(forKey: activeProviderKey),
                  let provider = WebSearchProvider(rawValue: rawValue) else {
                return .brave
            }
            return provider
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: activeProviderKey)
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

    private func credentialIssueKey(for provider: WebSearchProvider) -> String {
        credentialIssueKeyPrefix + provider.rawValue
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
            preconditionFailure("Invalid web search URL")
        }
        return url
    }
}
