import Foundation
import NativExtensionSDK
import NativServerKit
import SwiftUI

@MainActor
final class BrowsingExtension: NativHostExtension {
    static let extensionID = "com.nativ.browsing"
    static let pageID = "com.nativ.browsing.page"

    let manifest: NativExtensionManifest

    init(bundle: Bundle = .main) {
        manifest = Self.loadBundledManifest(bundle: bundle) ?? Self.fallbackManifest
    }

    func activate(context: NativExtensionHostContext) {
        BraveSearchCredentials.migrateLegacyKeyIfNeeded()
    }

    func deactivate() {}

    func makePage(
        id: String,
        context: NativExtensionPageContext
    ) -> AnyView? {
        guard id == Self.pageID else { return nil }
        return AnyView(BrowsingExtensionView(titleLeadingInset: context.titleLeadingInset))
    }

    func toolDefinitions() -> [MLXChatToolDefinition] {
        BraveSearchCredentials.load() == nil ? [] : [BraveSearchTool.definition]
    }

    func executeTool(call: MLXChatToolCall) async throws -> String? {
        guard call.function?.name == BraveSearchTool.name else { return nil }
        return try await BraveSearchTool.execute(call: call)
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
        summary: "Fast, compact web search for tool-capable models.",
        developer: "Nativ",
        systemImage: "globe",
        included: true,
        enabledByDefault: true,
        runtime: .builtIn,
        contributions: .init(
            sidebar: [
                .init(
                    id: pageID,
                    title: "Browsing",
                    systemImage: "globe",
                    order: 260
                )
            ]
        ),
        permissions: [.namespacedStorage]
    )
}

private enum BraveSearchCredentials {
    private static let keychain = ServerAPIKeychain(
        service: "dev.local.Nativ.extension.com.nativ.browsing.credential.brave-api-key",
        account: "api-key"
    )
    private static let legacyKeychain = ServerAPIKeychain(
        service: "dev.local.Nativ.browsing.brave",
        account: "api-key"
    )

    static func load() -> String? {
        try? keychain.load()
    }

    static func save(_ key: String?) throws {
        try keychain.save(key)
    }

    static func migrateLegacyKeyIfNeeded() {
        guard load() == nil, let key = try? legacyKeychain.load() else { return }
        try? keychain.save(key)
        try? legacyKeychain.save(nil)
    }
}

private struct BrowsingExtensionView: View {
    let titleLeadingInset: CGFloat
    @State private var apiKey = ""
    @State private var message: String?

    private var isConnected: Bool { BraveSearchCredentials.load() != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Browsing")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Search the web with concise results built for local models.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        NativTintedIconTile(symbol: "magnifyingglass", size: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text("Brave Search")
                                    .font(.system(size: 14, weight: .semibold))
                                statusBadge
                            }
                            Text("One reliable search tool backed by Brave’s independent web index.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Link("API docs", destination: URL(string: "https://api.search.brave.com/app/documentation/web-search/get-started")!)
                            .font(.system(size: 11))
                    }

                    HStack(spacing: 8) {
                        SecureField(isConnected ? "Brave API key saved in Keychain" : "Brave Search API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        Button("Save key") { saveKey() }
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if isConnected {
                            Button("Remove", role: .destructive) { removeKey() }
                                .buttonStyle(.borderless)
                        }
                    }
                    .controlSize(.small)

                    HStack(spacing: 7) {
                        capabilityPill("web_search(query)")
                        Text("Up to 3 sources, compacted before they reach the model.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Text("Your key stays in this Mac’s Keychain. Models receive search results, never your key.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    if let message {
                        Text(message)
                            .font(.system(size: 10))
                            .foregroundStyle(message == "Brave Search is connected." ? .green : .red)
                    }
                }
                .padding(16)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
            .padding(.top, 28)
            .padding(.leading, titleLeadingInset + 28)
            .padding(.trailing, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var statusBadge: some View {
        Text(isConnected ? "CONNECTED" : "SETUP REQUIRED")
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(isConnected ? Color.green : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background((isConnected ? Color.green : Color.primary).opacity(isConnected ? 0.12 : 0.06), in: Capsule())
    }

    private func capabilityPill(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.1), in: Capsule())
    }

    private func saveKey() {
        do {
            let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try BraveSearchCredentials.save(normalized)
            apiKey = ""
            message = "Brave Search is connected."
        } catch {
            message = "Nativ could not save the API key to the Keychain."
        }
    }

    private func removeKey() {
        do {
            try BraveSearchCredentials.save(nil)
            apiKey = ""
            message = nil
        } catch {
            message = "Nativ could not remove the API key from the Keychain."
        }
    }
}

private enum BraveSearchTool {
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
        guard let key = BraveSearchCredentials.load() else {
            throw BraveSearchToolError.missingAPIKey
        }
        guard let rawArguments = call.function?.arguments?.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(Arguments.self, from: rawArguments),
              let query = normalizedQuery(arguments.query) else {
            throw BraveSearchToolError.invalidQuery
        }

        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "3"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw BraveSearchToolError.invalidResponse
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw BraveSearchToolError.requestFailed(response.statusCode)
        }
        let result = try JSONDecoder().decode(Response.self, from: data)
        let payload = ResultPayload(results: (result.web?.results ?? []).prefix(3).map {
            .init(
                title: String($0.title.prefix(160)),
                url: $0.url,
                description: String(($0.description ?? "").prefix(300))
            )
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private static func normalizedQuery(_ query: String?) -> String? {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return nil
        }
        return String(query.prefix(300))
    }

    private struct Arguments: Decodable { let query: String? }
    private struct Response: Decodable { let web: Web? }
    private struct Web: Decodable { let results: [Result] }
    private struct Result: Decodable {
        let title: String
        let url: String
        let description: String?
    }
    private struct ResultPayload: Encodable {
        struct Item: Encodable {
            let title: String
            let url: String
            let description: String
        }
        let results: [Item]
    }
}

private enum BraveSearchToolError: LocalizedError {
    case missingAPIKey
    case invalidQuery
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add a Brave Search API key in Browsing first."
        case .invalidQuery:
            "web_search needs a non-empty query."
        case .invalidResponse:
            "Brave Search did not return an HTTP response."
        case .requestFailed(let status):
            "Brave Search returned HTTP \(status)."
        }
    }
}
