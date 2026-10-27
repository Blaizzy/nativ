import Foundation
import NativServerKit
import XCTest

private actor StubWebSearchHTTPClient: WebBrowsingHTTPClient {
    private let responseData: Data
    private let statusCode: Int
    private var requests: [URLRequest] = []

    init(response: String, statusCode: Int = 200) {
        responseData = Data(response.utf8)
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard let url = request.url else { throw URLError(.badURL) }
        return (
            responseData,
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func recordedRequest() -> URLRequest? {
        requests.first
    }
}

private final class StubWebSearchCredentialStore: WebSearchCredentialStoring {
    private var keys: [WebSearchProvider: String]

    init(keys: [WebSearchProvider: String] = [:]) {
        self.keys = keys
    }

    func load(for provider: WebSearchProvider) throws -> String? {
        keys[provider]
    }

    func save(_ key: String, for provider: WebSearchProvider) throws {
        keys[provider] = key
    }

    func remove(for provider: WebSearchProvider) throws {
        keys.removeValue(forKey: provider)
    }

    func storedKey(for provider: WebSearchProvider) -> String? {
        keys[provider]
    }
}

final class ChatWebSearchToolTests: XCTestCase {
    func testBraveRequestAndResultMapping() async throws {
        let client = StubWebSearchHTTPClient(
            response: #"{"web":{"results":[{"title":"Nativ","url":"https://nativ.dev","description":"Local AI"}]}}"#
        )

        let results = try await WebSearchService(client: client).search(
            provider: .brave,
            apiKey: "brave-key",
            query: "local ai",
            limit: 2
        )

        let capturedRequest = await client.recordedRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.host, "api.search.brave.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-Token"), "brave-key")
        XCTAssertEqual(request.url?.query, "q=local%20ai&count=2")
        XCTAssertEqual(
            results,
            [WebSearchResult(title: "Nativ", url: "https://nativ.dev", snippet: "Local AI")!]
        )
    }

    func testSearXNGRequestAndResultMapping() async throws {
        let client = StubWebSearchHTTPClient(
            response: #"{"results":[{"title":"SearXNG result","url":"https://example.com/result","content":"Private metasearch"}]}"#
        )
        let instanceURL = try XCTUnwrap(URL(string: "https://search.example.com/searx/"))

        let results = try await WebSearchService(client: client).search(
            provider: .searxng,
            access: .instance(instanceURL),
            query: "local ai",
            limit: 2
        )

        let capturedRequest = await client.recordedRequest()
        let request = try XCTUnwrap(capturedRequest)
        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(request.url),
            resolvingAgainstBaseURL: false
        ))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(components.path, "/searx/search")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }),
            ["q": "local ai", "format": "json"]
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            results,
            [WebSearchResult(
                title: "SearXNG result",
                url: "https://example.com/result",
                snippet: "Private metasearch"
            )!]
        )
    }

    func testSearXNGInstanceURLValidation() {
        XCTAssertEqual(
            WebSearchInstanceURL.normalized(" HTTPS://search.example.com/searx/// ")?.absoluteString,
            "https://search.example.com/searx"
        )
        XCTAssertEqual(
            WebSearchInstanceURL.normalized("http://localhost:8080")?.absoluteString,
            "http://localhost:8080"
        )
        XCTAssertNil(WebSearchInstanceURL.normalized("file:///tmp/searxng"))
        XCTAssertNil(WebSearchInstanceURL.normalized("https://user:secret@example.com"))
        XCTAssertNil(WebSearchInstanceURL.normalized("https://search.example.com?format=json"))
    }

    func testExaRequestAndResultMapping() async throws {
        let client = StubWebSearchHTTPClient(
            response: #"{"results":[{"title":"Exa result","url":"https://exa.ai","highlights":["A highlight"]}]}"#
        )

        let results = try await WebSearchService(client: client).search(
            provider: .exa,
            apiKey: "exa-key",
            query: "search",
            limit: 1
        )

        let capturedRequest = await client.recordedRequest()
        let request = try XCTUnwrap(capturedRequest)
        let body = try body(of: request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.exa.ai/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "exa-key")
        XCTAssertEqual(body["numResults"] as? Int, 1)
        XCTAssertEqual((body["contents"] as? [String: Any])?["highlights"] as? Bool, true)
        XCTAssertEqual(results.first?.snippet, "A highlight")
    }

    func testNimbleRequestAndResultMapping() async throws {
        let client = StubWebSearchHTTPClient(
            response: #"{"results":[{"title":"Nimble result","url":"https://nimbleway.com","content":"Result body"}]}"#
        )

        let results = try await WebSearchService(client: client).search(
            provider: .nimble,
            apiKey: "nimble-key",
            query: "search",
            limit: 1
        )

        let capturedRequest = await client.recordedRequest()
        let request = try XCTUnwrap(capturedRequest)
        let body = try body(of: request)
        XCTAssertEqual(request.url?.absoluteString, "https://sdk.nimbleway.com/v2/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer nimble-key")
        XCTAssertEqual(Set(body.keys), ["max_results", "query"])
        XCTAssertEqual(body["max_results"] as? Int, 1)
        XCTAssertEqual(results.first?.snippet, "Result body")
    }

    func testFirecrawlRequestAndResultMapping() async throws {
        let client = StubWebSearchHTTPClient(
            response: #"{"data":{"web":[{"title":"Firecrawl result","url":"https://firecrawl.dev","markdown":"Page text"}]}}"#
        )

        let results = try await WebSearchService(client: client).search(
            provider: .firecrawl,
            apiKey: "firecrawl-key",
            query: "search",
            limit: 1
        )

        let capturedRequest = await client.recordedRequest()
        let request = try XCTUnwrap(capturedRequest)
        let body = try body(of: request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.firecrawl.dev/v2/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer firecrawl-key")
        XCTAssertEqual(Set(body.keys), ["limit", "query", "sources"])
        XCTAssertEqual(body["sources"] as? [String], ["web"])
        XCTAssertEqual(results.first?.snippet, "Page text")
    }

    func testPerplexityRequestAndResultMapping() async throws {
        let client = StubWebSearchHTTPClient(
            response: #"{"results":[{"title":"Perplexity result","url":"https://perplexity.ai","snippet":"A snippet"}]}"#
        )

        let results = try await WebSearchService(client: client).search(
            provider: .perplexity,
            apiKey: "perplexity-key",
            query: "search",
            limit: 1
        )

        let capturedRequest = await client.recordedRequest()
        let request = try XCTUnwrap(capturedRequest)
        let body = try body(of: request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.perplexity.ai/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer perplexity-key")
        XCTAssertEqual(Set(body.keys), ["max_results", "query"])
        XCTAssertEqual(body["max_results"] as? Int, 1)
        XCTAssertEqual(results.first?.snippet, "A snippet")
    }

    func testTavilyRequestAndResultMapping() async throws {
        let client = StubWebSearchHTTPClient(
            response: #"{"results":[{"title":"Tavily result","url":"https://tavily.com","content":"A focused result"}]}"#
        )

        let results = try await WebSearchService(client: client).search(
            provider: .tavily,
            apiKey: "tavily-key",
            query: "search",
            limit: 2
        )

        let capturedRequest = await client.recordedRequest()
        let request = try XCTUnwrap(capturedRequest)
        let body = try body(of: request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.tavily.com/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tavily-key")
        XCTAssertEqual(body["max_results"] as? Int, 2)
        XCTAssertEqual(body["search_depth"] as? String, "fast")
        XCTAssertEqual(body["include_answer"] as? Bool, false)
        XCTAssertEqual(body["include_raw_content"] as? Bool, false)
        XCTAssertEqual(results.first?.snippet, "A focused result")
    }

    func testParallelRequestAndResultMapping() async throws {
        let client = StubWebSearchHTTPClient(
            response: #"{"results":[{"title":"Parallel result","url":"https://parallel.ai","excerpts":["First","Second"]}]}"#
        )

        let results = try await WebSearchService(client: client).search(
            provider: .parallel,
            apiKey: "parallel-key",
            query: "search",
            limit: 2
        )

        let capturedRequest = await client.recordedRequest()
        let request = try XCTUnwrap(capturedRequest)
        let body = try body(of: request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.parallel.ai/v1/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "parallel-key")
        XCTAssertEqual(body["search_queries"] as? [String], ["search"])
        XCTAssertEqual(body["mode"] as? String, "basic")
        XCTAssertEqual(body["max_chars_total"] as? Int, 1_000)
        XCTAssertEqual(results.first?.snippet, "First\n\nSecond")
    }

    func testCredentialValidationAcceptsAnEmptyResultSet() async throws {
        let client = StubWebSearchHTTPClient(response: #"{"web":{"results":[]}}"#)

        try await WebSearchService(client: client).validateCredential(
            provider: .brave,
            apiKey: "valid-key"
        )
    }

    func testHTTPFailuresHaveStableSemantics() async throws {
        let expected: [(Int, WebBrowsingFailureCode)] = [
            (401, .invalidAuthentication),
            (402, .insufficientFunds),
            (403, .planAccess),
            (429, .rateLimited),
            (503, .providerUnavailable),
        ]

        for (statusCode, expectedCode) in expected {
            let client = StubWebSearchHTTPClient(response: "{}", statusCode: statusCode)
            do {
                _ = try await WebSearchService(client: client).search(
                    provider: .brave,
                    apiKey: "key",
                    query: "search",
                    limit: 1
                )
                XCTFail("Expected HTTP \(statusCode) to fail")
            } catch let error as WebBrowsingError {
                XCTAssertEqual(error.code, expectedCode)
            }
        }
    }

    func testRuntimeTracksCredentialHealthAcrossRequests() async throws {
        let suiteName = "ChatWebSearchToolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WebBrowsingPreferences(defaults: defaults)
        let credentials = StubWebSearchCredentialStore(keys: [.brave: "key"])
        let rejectedRuntime = WebBrowsingRuntime(
            credentials: credentials,
            preferences: preferences,
            client: StubWebSearchHTTPClient(response: "{}", statusCode: 401)
        )

        do {
            _ = try await rejectedRuntime.search(query: "Nativ", limit: 1)
            XCTFail("Expected the rejected credential to fail")
        } catch {}
        XCTAssertEqual(preferences.credentialIssue(for: .brave), .invalidAuthentication)
        XCTAssertFalse(rejectedRuntime.isConfigured(.search))

        let acceptedRuntime = WebBrowsingRuntime(
            credentials: credentials,
            preferences: preferences,
            client: StubWebSearchHTTPClient(response: #"{"web":{"results":[]}}"#)
        )
        _ = try await acceptedRuntime.search(query: "Nativ", limit: 1)

        XCTAssertNil(preferences.credentialIssue(for: .brave))
        XCTAssertTrue(acceptedRuntime.isConfigured(.search))
    }

    func testSearXNGRuntimeUsesPersistedEndpointWithoutCredential() async throws {
        let suiteName = "ChatWebSearchToolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WebBrowsingPreferences(defaults: defaults)
        preferences.searchProvider = .searxng
        preferences.setEndpoint(
            try XCTUnwrap(URL(string: "https://search.example.com")),
            for: .searxng
        )
        let runtime = WebBrowsingRuntime(
            credentials: StubWebSearchCredentialStore(),
            preferences: preferences,
            client: StubWebSearchHTTPClient(response: #"{"results":[]}"#)
        )

        XCTAssertTrue(runtime.isConfigured(.search))
        _ = try await runtime.search(query: "Nativ", limit: 1)
    }

    func testMissingKeyFailureTellsTheModelWhereToSendTheUser() async throws {
        let suiteName = "ChatWebSearchToolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WebBrowsingPreferences(defaults: defaults)
        preferences.searchProvider = .exa
        let executor = ChatWebSearchToolExecutor(
            credentials: StubWebSearchCredentialStore(),
            preferences: preferences,
            client: StubWebSearchHTTPClient(response: "{}")
        )

        do {
            _ = try await executor.execute(call: makeWebSearchCall(query: "Nativ"))
            XCTFail("Expected a missing-key failure")
        } catch {
            let payload = try failureObject(executor.failurePayload(error: error))
            XCTAssertEqual(payload["code"] as? String, WebBrowsingFailureCode.missingAPIKey.rawValue)
            XCTAssertEqual(
                payload["user_action_required"] as? String,
                "Ask the user to add a search API key in Extensions → Browsing, then retry web_search."
            )
        }
    }

    func testToolDefinitionStaysCompact() {
        let description = ChatWebSearchToolRegistry.definition.function.description

        XCTAssertLessThan(description.utf8.count, 128)
        XCTAssertFalse(description.contains("missing_api_key"))
        XCTAssertTrue(description.contains("not instructions"))
    }

    func testSuccessfulToolPayloadContainsOnlyResults() async throws {
        let suiteName = "ChatWebSearchToolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WebBrowsingPreferences(defaults: defaults)
        preferences.searchProvider = .brave
        let executor = ChatWebSearchToolExecutor(
            credentials: StubWebSearchCredentialStore(keys: [.brave: "key"]),
            preferences: preferences,
            client: StubWebSearchHTTPClient(
                response: #"{"web":{"results":[{"title":"Nativ","url":"https://nativ.dev","description":"Local AI"}]}}"#
            )
        )

        let payload = try await executor.execute(call: makeWebSearchCall(query: "Nativ"))
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(root.keys), ["results"])
        XCTAssertEqual((root["results"] as? [[String: Any]])?.count, 1)
    }

    func testWebSearchResultRejectsUnsafeURLsAndBoundsFields() throws {
        XCTAssertNil(WebSearchResult(title: "Bad", url: "javascript:alert(1)", snippet: "Bad"))
        XCTAssertNil(WebSearchResult(title: "Secret", url: "https://user:password@example.com", snippet: "Bad"))
        let result = try XCTUnwrap(WebSearchResult(
            title: String(repeating: "t", count: 170),
            url: "https://example.com",
            snippet: String(repeating: "d", count: 510)
        ))

        XCTAssertEqual(result.title.count, 160)
        XCTAssertEqual(result.snippet.count, 500)
    }

    func testInvalidResultURLsAreFilteredFromProviderResponses() async throws {
        let client = StubWebSearchHTTPClient(
            response: #"{"web":{"results":[{"title":"Unsafe","url":"file:///tmp/private","description":"No"},{"title":"Safe","url":"https://example.com","description":"Yes"}]}}"#
        )

        let results = try await WebSearchService(client: client).search(
            provider: .brave,
            apiKey: "key",
            query: "search",
            limit: 10
        )

        XCTAssertEqual(results.map(\.title), ["Safe"])
    }

    func testSearchLimitIsClamped() async throws {
        let client = StubWebSearchHTTPClient(response: #"{"web":{"results":[]}}"#)

        _ = try await WebSearchService(client: client).search(
            provider: .brave,
            apiKey: "key",
            query: "search",
            limit: 100
        )

        let capturedRequest = await client.recordedRequest()
        let request = try XCTUnwrap(capturedRequest)
        let query = try XCTUnwrap(request.url?.query)
        XCTAssertTrue(query.contains("count=10"))
    }

    func testProviderSetupLinksAreSecure() {
        for provider in WebSearchProvider.allCases {
            XCTAssertEqual(provider.metadata.setupURL.scheme, "https")
        }
    }

    @MainActor
    func testSettingsNeverLoadStoredKeyIntoEditableState() throws {
        let suiteName = "ChatWebSearchToolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WebBrowsingPreferences(defaults: defaults)
        preferences.searchProvider = .exa
        let credentials = StubWebSearchCredentialStore(keys: [.exa: "stored-secret"])

        let viewModel = WebBrowsingSettingsViewModel(
            preferences: preferences,
            credentials: credentials,
            service: WebSearchService(client: StubWebSearchHTTPClient(response: "{}"))
        )

        XCTAssertEqual(viewModel.selectedProvider, .exa)
        XCTAssertEqual(viewModel.selectedConnectionState, .connected)
        XCTAssertTrue(viewModel.draftConfiguration.isEmpty)
    }

    @MainActor
    func testSelectingACredentialDoesNotChangeProviderRouting() throws {
        let suiteName = "ChatWebSearchToolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WebBrowsingPreferences(defaults: defaults)
        let credentials = StubWebSearchCredentialStore(keys: [.nimble: "stored-key"])
        let viewModel = WebBrowsingSettingsViewModel(
            preferences: preferences,
            credentials: credentials,
            service: WebSearchService(client: StubWebSearchHTTPClient(response: "{}"))
        )

        viewModel.select(.nimble)

        XCTAssertEqual(preferences.searchProvider, .brave)
        XCTAssertTrue(viewModel.draftConfiguration.isEmpty)
    }

    func testPageReaderDefaultsToSearchProviderWhenSupported() throws {
        let suiteName = "ChatWebSearchToolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WebBrowsingPreferences(defaults: defaults)

        preferences.searchProvider = .exa

        XCTAssertNil(preferences.pageReaderProvider)
        XCTAssertEqual(preferences.provider(for: .search), .exa)
        XCTAssertEqual(preferences.provider(for: .read), .exa)
    }

    func testPageReaderCanBeRoutedSeparatelyFromSearch() throws {
        let suiteName = "ChatWebSearchToolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WebBrowsingPreferences(defaults: defaults)

        preferences.searchProvider = .brave
        XCTAssertNil(preferences.provider(for: .read))

        preferences.pageReaderProvider = .firecrawl

        XCTAssertEqual(preferences.provider(for: .search), .brave)
        XCTAssertEqual(preferences.provider(for: .read), .firecrawl)
    }

    @MainActor
    func testSettingsSaveAndActivateOnlyAfterValidation() async throws {
        let suiteName = "ChatWebSearchToolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WebBrowsingPreferences(defaults: defaults)
        let credentials = StubWebSearchCredentialStore()
        let client = StubWebSearchHTTPClient(response: #"{"results":[]}"#)
        let viewModel = WebBrowsingSettingsViewModel(
            preferences: preferences,
            credentials: credentials,
            service: WebSearchService(client: client)
        )
        viewModel.select(.exa)
        viewModel.draftConfiguration = "new-key"

        _ = await viewModel.testAndConnect()

        XCTAssertEqual(credentials.storedKey(for: .exa), "new-key")
        XCTAssertEqual(preferences.searchProvider, .exa)
        XCTAssertEqual(viewModel.selectedConnectionState, .connected)
        XCTAssertTrue(viewModel.draftConfiguration.isEmpty)
    }

    @MainActor
    func testConnectingAReaderDoesNotReplaceConfiguredSearchProvider() async throws {
        let suiteName = "ChatWebSearchToolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WebBrowsingPreferences(defaults: defaults)
        preferences.searchProvider = .brave
        let credentials = StubWebSearchCredentialStore(keys: [.brave: "brave-key"])
        let viewModel = WebBrowsingSettingsViewModel(
            initialCapability: .read,
            preferences: preferences,
            credentials: credentials,
            service: WebSearchService(client: StubWebSearchHTTPClient(response: #"{"results":[]}"#))
        )
        XCTAssertEqual(viewModel.selectedProvider, .exa)
        XCTAssertEqual(viewModel.availableProviders, WebSearchProvider.pageReaders)
        viewModel.select(.exa)
        viewModel.draftConfiguration = "exa-key"

        _ = await viewModel.testAndConnect()

        XCTAssertEqual(preferences.searchProvider, .brave)
        XCTAssertEqual(preferences.pageReaderProvider, .exa)
        XCTAssertEqual(preferences.provider(for: .read), .exa)
    }

    @MainActor
    func testFailedReplacementDoesNotOverwriteStoredCredential() async throws {
        let suiteName = "ChatWebSearchToolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WebBrowsingPreferences(defaults: defaults)
        preferences.searchProvider = .brave
        let credentials = StubWebSearchCredentialStore(keys: [.brave: "working-key"])
        let client = StubWebSearchHTTPClient(response: "{}", statusCode: 401)
        let viewModel = WebBrowsingSettingsViewModel(
            preferences: preferences,
            credentials: credentials,
            service: WebSearchService(client: client)
        )
        viewModel.draftConfiguration = "bad-replacement"

        _ = await viewModel.testAndConnect()

        XCTAssertEqual(credentials.storedKey(for: .brave), "working-key")
        XCTAssertEqual(viewModel.selectedConnectionState, .connected)
        guard case .failure = viewModel.status else {
            return XCTFail("Expected the rejected replacement to show an error")
        }
    }

    @MainActor
    func testSettingsValidateAndActivateSearXNGInstance() async throws {
        let suiteName = "ChatWebSearchToolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WebBrowsingPreferences(defaults: defaults)
        let viewModel = WebBrowsingSettingsViewModel(
            preferences: preferences,
            credentials: StubWebSearchCredentialStore(),
            service: WebSearchService(
                client: StubWebSearchHTTPClient(response: #"{"results":[]}"#)
            )
        )
        viewModel.select(.searxng)
        viewModel.draftConfiguration = "https://search.example.com/"

        let connected = await viewModel.testAndConnect()

        XCTAssertTrue(connected)
        XCTAssertEqual(preferences.searchProvider, .searxng)
        XCTAssertEqual(
            preferences.endpoint(for: .searxng)?.absoluteString,
            "https://search.example.com/"
        )
        XCTAssertEqual(viewModel.selectedConnectionState, .connected)
        XCTAssertEqual(viewModel.draftConfiguration, "https://search.example.com/")
    }

    private func makeWebSearchCall(query: String) -> MLXChatToolCall {
        MLXChatToolCall(
            id: "web-search",
            function: MLXChatFunctionCall(
                name: ChatWebSearchToolRegistry.toolName,
                arguments: #"{"query":"\#(query)"}"#
            )
        )
    }

    private func failureObject(_ payload: String) throws -> [String: Any] {
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["error"] as? [String: Any])
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
