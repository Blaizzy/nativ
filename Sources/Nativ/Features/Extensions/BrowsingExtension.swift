import Foundation
import NativExtensionSDK
import NativServerKit
import SwiftUI

@MainActor
final class BrowsingExtension: NativHostExtension {
    static let extensionID = "com.nativ.browsing"

    let manifest: NativExtensionManifest

    init(bundle: Bundle = .main) {
        manifest = Self.loadBundledManifest(bundle: bundle) ?? Self.fallbackManifest
    }

    func activate(context: NativExtensionHostContext) {
        BrowsingCredentials.migrateLegacyBraveKeyIfNeeded()
    }

    func deactivate() {}

    func makePage(
        id: String,
        context: NativExtensionPageContext
    ) -> AnyView? {
        nil
    }

    func makeConfigurationView() -> AnyView? {
        AnyView(BrowsingConfigurationView())
    }

    func toolDefinitions() -> [MLXChatToolDefinition] {
        BrowsingCredentials.load(for: BrowsingProviderSettings.active) == nil
            ? []
            : [BrowsingSearchTool.definition]
    }

    func executeTool(call: MLXChatToolCall) async throws -> String? {
        guard call.function?.name == BrowsingSearchTool.name else { return nil }
        return try await BrowsingSearchTool.execute(call: call)
    }

    private static func loadBundledManifest(bundle: Bundle) -> NativExtensionManifest? {
        let candidates = [
            bundle.resourceURL?
                .appendingPathComponent("Browsing", isDirectory: true)
                .appendingPathComponent("Manifest.json"),
            bundle.url(forResource: "Manifest", withExtension: "json"),
        ]
        for case let url? in candidates {
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(
                    NativExtensionManifest.self,
                    from: data
                  ) else {
                continue
            }
            return manifest
        }
        return nil
    }

    private static let fallbackManifest = NativExtensionManifest(
        id: extensionID,
        version: "1.0.0",
        minimumNativVersion: "0.2.2",
        displayName: "Browsing",
        summary: "Connect a search provider for tool-capable models.",
        developer: "Nativ",
        systemImage: "globe",
        included: true,
        enabledByDefault: true,
        runtime: .builtIn,
        permissions: [.namespacedStorage]
    )
}

private enum BrowsingProvider: String, CaseIterable, Identifiable, Sendable {
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

    var summary: String {
        switch self {
        case .brave: "Fast web results from an independent search index."
        case .exa: "Semantic web search tuned for research and discovery."
        case .nimble: "Search with concise results and optional extracted content."
        case .firecrawl: "Web search with clean page extraction when you need it."
        case .perplexity: "Fresh ranked web results with concise snippets."
        }
    }

    var documentationURL: URL {
        switch self {
        case .brave:
            URL(string: "https://api-dashboard.search.brave.com/documentation/quickstart")!
        case .exa:
            URL(string: "https://exa.ai/docs/reference/search")!
        case .nimble:
            URL(string: "https://docs.nimbleway.com/api-reference/search/search")!
        case .firecrawl:
            URL(string: "https://docs.firecrawl.dev/api-reference/endpoint/search")!
        case .perplexity:
            URL(string: "https://docs.perplexity.ai/docs/search/quickstart")!
        }
    }

    var symbol: String {
        switch self {
        case .brave: "B"
        case .exa: "E"
        case .nimble: "N"
        case .firecrawl: "F"
        case .perplexity: "P"
        }
    }

    var color: Color {
        switch self {
        case .brave: Color(red: 0.94, green: 0.29, blue: 0.15)
        case .exa: Color(red: 0.26, green: 0.33, blue: 0.93)
        case .nimble: Color(red: 0.15, green: 0.63, blue: 0.43)
        case .firecrawl: Color(red: 0.93, green: 0.37, blue: 0.13)
        case .perplexity: Color(red: 0.09, green: 0.61, blue: 0.63)
        }
    }
}

private enum BrowsingProviderSettings {
    private static let activeProviderKey = "nativ.browsing.active-provider.v1"

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
}

private enum BrowsingCredentials {
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

    static func maskedKey(for provider: BrowsingProvider) -> String? {
        guard let key = load(for: provider) else { return nil }
        let suffix = key.count > 4 ? String(key.suffix(4)) : key
        return "••••••••(suffix)"
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
            service: "dev.local.Nativ.extension.com.nativ.browsing.credential.\(provider.rawValue)-api-key",
            account: "api-key"
        )
    }
}

private struct BrowsingConfigurationView: View {
    @State private var selectedProvider = BrowsingProviderSettings.active
    @State private var apiKey = ""
    @State private var revealsKey = false
    @State private var isTesting = false
    @State private var status: Status?
    @State private var showsRemoveConfirmation = false

    private enum Status {
        case connected
        case failure(String)
    }

    private var savedKey: String? { BrowsingCredentials.maskedKey(for: selectedProvider) }

    var body: some View {
        HStack(spacing: 0) {
            providerRail
            Divider()
            setupPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.nativMainContentBackground)
        .alert("Remove API key?", isPresented: $showsRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { removeKey() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("This disconnects \(selectedProvider.name) from Browsing on this Mac.")
        }
    }

    private var providerRail: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("SEARCH PROVIDERS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            ForEach(BrowsingProvider.allCases) { provider in
                Button { select(provider) } label: {
                    HStack(spacing: 10) {
                        ProviderMark(provider: provider, size: 28)
                        Text(provider.name)
                            .font(.system(size: 12, weight: provider == selectedProvider ? .semibold : .regular))
                        Spacer(minLength: 0)
                        if BrowsingCredentials.load(for: provider) != nil {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        provider == selectedProvider ? Color.accentColor.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 18)
        .frame(width: 176)
    }

    private var setupPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                ProviderMark(provider: selectedProvider, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect \(selectedProvider.name)")
                        .font(.system(size: 18, weight: .semibold))
                    Text(selectedProvider.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Link("API docs", destination: selectedProvider.documentationURL)
                    .font(.system(size: 11))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API key")
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 8) {
                    keyField
                    Button { revealsKey.toggle(); revealSavedKeyIfNeeded() } label: {
                        Image(systemName: revealsKey ? "eye.slash" : "eye")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .help(revealsKey ? "Hide API key" : "Show API key")
                }
                Text(savedKey == nil
                    ? "Paste a key, then test the connection."
                    : "Saved key: \(savedKey!).")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                Button(isTesting ? "Testing…" : "Test & connect") { testAndConnect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isTesting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if savedKey != nil {
                    Button("Remove key", role: .destructive) {
                        showsRemoveConfirmation = true
                    }
                }
                Spacer()
                Text("One compact web_search(query) tool")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }

            statusView
            Spacer()
            Text("Nativ sends your key only to \(selectedProvider.name). It stays in this Mac’s Keychain and is never shown to models.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var keyField: some View {
        if revealsKey {
            TextField("\(selectedProvider.name) API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
        } else {
            SecureField("\(selectedProvider.name) API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if let status {
            switch status {
            case .connected:
                Label("Connected to \(selectedProvider.name).", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private func select(_ provider: BrowsingProvider) {
        selectedProvider = provider
        apiKey = ""
        revealsKey = false
        status = nil
    }

    private func revealSavedKeyIfNeeded() {
        guard revealsKey, apiKey.isEmpty else { return }
        apiKey = BrowsingCredentials.load(for: selectedProvider) ?? ""
    }

    private func testAndConnect() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isTesting = true
        status = nil
        Task {
            do {
                try await BrowsingSearchService.test(provider: selectedProvider, apiKey: key)
                try BrowsingCredentials.save(key, for: selectedProvider)
                BrowsingProviderSettings.setActive(selectedProvider)
                apiKey = ""
                revealsKey = false
                status = .connected
            } catch {
                status = .failure(error.localizedDescription)
            }
            isTesting = false
        }
    }

    private func removeKey() {
        do {
            try BrowsingCredentials.save(nil, for: selectedProvider)
            apiKey = ""
            revealsKey = false
            status = nil
        } catch {
            status = .failure("Nativ could not remove the API key from Keychain.")
        }
    }
}

private struct ProviderMark: View {
    let provider: BrowsingProvider
    let size: CGFloat

    var body: some View {
        Text(provider.symbol)
            .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(provider.color, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

private enum BrowsingSearchTool {
    static let name = "web_search"

    static let definition = MLXChatToolDefinition(function: MLXChatFunctionDefinition(
        name: name,
        description: "Search the web and return the most relevant sources.",
        parameters: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("A focused web search query.")
                ])
            ]),
            "required": .array([.string("query")])
        ])
    ))

    static func execute(call: MLXChatToolCall) async throws -> String {
        guard let rawArguments = call.function?.arguments?.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(Arguments.self, from: rawArguments),
              let query = normalizedQuery(arguments.query) else {
            throw BrowsingSearchError.invalidQuery
        }
        let provider = BrowsingProviderSettings.active
        guard let key = BrowsingCredentials.load(for: provider) else {
            throw BrowsingSearchError.missingAPIKey(provider)
        }
        let results = try await BrowsingSearchService.search(
            provider: provider,
            apiKey: key,
            query: query,
            limit: 3
        )
        let payload = ResultPayload(results: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private static func normalizedQuery(_ query: String?) -> String? {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return nil
        }
        return String(query.prefix(300))
    }

    private struct Arguments: Decodable { let query: String? }
    private struct ResultPayload: Encodable { let results: [BrowsingSearchResult] }
}

private struct BrowsingSearchResult: Codable, Sendable {
    let title: String
    let url: String
    let description: String

    init(title: String?, url: String?, description: String?) {
        self.title = String((title ?? "Untitled result").prefix(160))
        self.url = url ?? ""
        self.description = String((description ?? "").prefix(300))
    }
}

private enum BrowsingSearchService {
    static func test(provider: BrowsingProvider, apiKey: String) async throws {
        let results = try await search(
            provider: provider,
            apiKey: apiKey,
            query: "Nativ",
            limit: 1
        )
        guard !results.isEmpty else { throw BrowsingSearchError.emptyResponse(provider) }
    }

    static func search(
        provider: BrowsingProvider,
        apiKey: String,
        query: String,
        limit: Int
    ) async throws -> [BrowsingSearchResult] {
        switch provider {
        case .brave:
            try await searchBrave(apiKey: apiKey, query: query, limit: limit)
        case .exa:
            try await searchExa(apiKey: apiKey, query: query, limit: limit)
        case .nimble:
            try await searchNimble(apiKey: apiKey, query: query, limit: limit)
        case .firecrawl:
            try await searchFirecrawl(apiKey: apiKey, query: query, limit: limit)
        case .perplexity:
            try await searchPerplexity(apiKey: apiKey, query: query, limit: limit)
        }
    }

    private static func searchBrave(
        apiKey: String,
        query: String,
        limit: Int
    ) async throws -> [BrowsingSearchResult] {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(limit)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        let data = try await data(for: request, provider: .brave)
        let response = try JSONDecoder().decode(BraveResponse.self, from: data)
        return response.web?.results.prefix(limit).map {
            BrowsingSearchResult(title: $0.title, url: $0.url, description: $0.description)
        } ?? []
    }

    private static func searchExa(
        apiKey: String,
        query: String,
        limit: Int
    ) async throws -> [BrowsingSearchResult] {
        let request = try postRequest(
            url: "https://api.exa.ai/search",
            apiKey: apiKey,
            header: "x-api-key",
            body: ["query": query, "numResults": limit, "type": "fast"]
        )
        let data = try await data(for: request, provider: .exa)
        let response = try JSONDecoder().decode(ExaResponse.self, from: data)
        return response.results.prefix(limit).map {
            BrowsingSearchResult(
                title: $0.title,
                url: $0.url,
                description: $0.highlights?.first ?? $0.text
            )
        }
    }

    private static func searchNimble(
        apiKey: String,
        query: String,
        limit: Int
    ) async throws -> [BrowsingSearchResult] {
        let request = try postRequest(
            url: "https://sdk.nimbleway.com/v2/search",
            apiKey: apiKey,
            header: "Authorization",
            body: ["query": query, "max_results": limit, "search_depth": "lite", "output_format": "plain_text"]
        )
        let data = try await data(for: request, provider: .nimble)
        let response = try JSONDecoder().decode(NimbleResponse.self, from: data)
        return response.results.prefix(limit).map {
            BrowsingSearchResult(title: $0.title, url: $0.url, description: $0.description ?? $0.content)
        }
    }

    private static func searchFirecrawl(
        apiKey: String,
        query: String,
        limit: Int
    ) async throws -> [BrowsingSearchResult] {
        let request = try postRequest(
            url: "https://api.firecrawl.dev/v2/search",
            apiKey: apiKey,
            header: "Authorization",
            body: ["query": query, "limit": limit, "sources": ["web"], "highlights": false]
        )
        let data = try await data(for: request, provider: .firecrawl)
        let response = try JSONDecoder().decode(FirecrawlResponse.self, from: data)
        return response.data.web.prefix(limit).map {
            BrowsingSearchResult(title: $0.title, url: $0.url, description: $0.description ?? $0.markdown)
        }
    }

    private static func searchPerplexity(
        apiKey: String,
        query: String,
        limit: Int
    ) async throws -> [BrowsingSearchResult] {
        let request = try postRequest(
            url: "https://api.perplexity.ai/search",
            apiKey: apiKey,
            header: "Authorization",
            body: ["query": query, "max_results": limit, "search_context_size": "low"]
        )
        let data = try await data(for: request, provider: .perplexity)
        let response = try JSONDecoder().decode(PerplexityResponse.self, from: data)
        return response.results.prefix(limit).map {
            BrowsingSearchResult(title: $0.title, url: $0.url, description: $0.snippet)
        }
    }

    private static func postRequest(
        url: String,
        apiKey: String,
        header: String,
        body: [String: Any]
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            header == "Authorization" ? "Bearer \(apiKey)" : apiKey,
            forHTTPHeaderField: header
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func data(
        for request: URLRequest,
        provider: BrowsingProvider
    ) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw BrowsingSearchError.invalidResponse(provider)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw BrowsingSearchError.requestFailed(provider, response.statusCode)
        }
        return data
    }

    private struct BraveResponse: Decodable {
        let web: BraveWeb?
    }
    private struct BraveWeb: Decodable { let results: [BraveResult] }
    private struct BraveResult: Decodable {
        let title: String?
        let url: String?
        let description: String?
    }
    private struct ExaResponse: Decodable { let results: [ExaResult] }
    private struct ExaResult: Decodable {
        let title: String?
        let url: String?
        let highlights: [String]?
        let text: String?
    }
    private struct NimbleResponse: Decodable { let results: [NimbleResult] }
    private struct NimbleResult: Decodable {
        let title: String?
        let url: String?
        let description: String?
        let content: String?
    }
    private struct FirecrawlResponse: Decodable { let data: FirecrawlData }
    private struct FirecrawlData: Decodable { let web: [FirecrawlResult] }
    private struct FirecrawlResult: Decodable {
        let title: String?
        let url: String?
        let description: String?
        let markdown: String?
    }
    private struct PerplexityResponse: Decodable { let results: [PerplexityResult] }
    private struct PerplexityResult: Decodable {
        let title: String?
        let url: String?
        let snippet: String?
    }
}

private enum BrowsingSearchError: LocalizedError {
    case invalidQuery
    case missingAPIKey(BrowsingProvider)
    case invalidResponse(BrowsingProvider)
    case emptyResponse(BrowsingProvider)
    case requestFailed(BrowsingProvider, Int)

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            "web_search needs a non-empty query."
        case .missingAPIKey(let provider):
            "Add a \(provider.name) API key in Extensions first."
        case .invalidResponse(let provider):
            "\(provider.name) did not return an HTTP response."
        case .emptyResponse(let provider):
            "\(provider.name) connected but returned no search results."
        case .requestFailed(let provider, let status):
            "\(provider.name) returned HTTP \(status)."
        }
    }
}
