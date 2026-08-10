import Foundation

enum BrowsingProvider: String, CaseIterable, Identifiable, Sendable {
    case brave
    case exa
    case nimble
    case firecrawl
    case perplexity

    var id: String { rawValue }

    var name: String {
        switch self {
        case .brave: "Brave"
        case .exa: "Exa"
        case .nimble: "Nimble"
        case .firecrawl: "Firecrawl"
        case .perplexity: "Perplexity"
        }
    }

    var logoFileName: String {
        switch self {
        case .brave: "Brave"
        case .exa: "Exa"
        case .nimble: "Nimble"
        case .firecrawl: "Firecrawl"
        case .perplexity: "Perplexity"
        }
    }
}

enum BrowsingProviderSettings {
    private static let activeProviderKey = "nativ.browsing.active-provider.v1"
    private static let verificationKeyPrefix = "nativ.browsing.provider-verified.v1."

    static var active: BrowsingProvider {
        guard let rawValue = UserDefaults.standard.string(forKey: activeProviderKey),
              let provider = BrowsingProvider(rawValue: rawValue) else {
            return .brave
        }
        return provider
    }

    static func setActive(_ provider: BrowsingProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: activeProviderKey)
    }

    static func isVerified(_ provider: BrowsingProvider) -> Bool {
        UserDefaults.standard.bool(forKey: verificationKey(for: provider))
    }

    static func markVerified(_ provider: BrowsingProvider, verified: Bool) {
        UserDefaults.standard.set(verified, forKey: verificationKey(for: provider))
    }

    private static func verificationKey(for provider: BrowsingProvider) -> String {
        verificationKeyPrefix + provider.rawValue
    }
}

enum BrowsingCredentials {
    private static let legacyBraveKeychain = ServerAPIKeychain(
        service: "dev.local.Nativ.browsing.brave",
        account: "api-key"
    )

    static func load(for provider: BrowsingProvider) -> String? {
        try? keychain(for: provider).load()
    }

    static func save(_ key: String?, for provider: BrowsingProvider) throws {
        try keychain(for: provider).save(key)
    }

    static func remove(for provider: BrowsingProvider) throws {
        try save(nil, for: provider)
        BrowsingProviderSettings.markVerified(provider, verified: false)
    }

    static func migrateLegacyBraveKeyIfNeeded() {
        guard load(for: .brave) == nil,
              let key = try? legacyBraveKeychain.load() else {
            return
        }
        try? save(key, for: .brave)
        try? legacyBraveKeychain.save(nil)
    }

    private static func keychain(for provider: BrowsingProvider) -> ServerAPIKeychain {
        ServerAPIKeychain(
            service: "dev.local.Nativ.browsing.\(provider.rawValue)",
            account: "api-key"
        )
    }
}
