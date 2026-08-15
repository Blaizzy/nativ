import Foundation
import NativServerKit
import XCTest

private actor StubWebReadHTTPClient: WebBrowsingHTTPClient {
    private let responseData: Data
    private let statusCode: Int
    private let delayNanoseconds: UInt64
    private var requests: [URLRequest] = []
    private var activeRequestCount = 0
    private var maximumActiveRequestCount = 0

    init(
        response: String,
        statusCode: Int = 200,
        delayNanoseconds: UInt64 = 0
    ) {
        responseData = Data(response.utf8)
        self.statusCode = statusCode
        self.delayNanoseconds = delayNanoseconds
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        activeRequestCount += 1
        maximumActiveRequestCount = max(maximumActiveRequestCount, activeRequestCount)
        defer { activeRequestCount -= 1 }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
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

    func recordedRequests() -> [URLRequest] {
        requests
    }

    func maximumConcurrentRequests() -> Int {
        maximumActiveRequestCount
    }
}

private final class StubWebReadCredentialStore: WebSearchCredentialStoring {
    private let keys: [WebSearchProvider: String]

    init(keys: [WebSearchProvider: String]) {
        self.keys = keys
    }

    func load(for provider: WebSearchProvider) throws -> String? { keys[provider] }
    func save(_ key: String, for provider: WebSearchProvider) throws {}
    func remove(for provider: WebSearchProvider) throws {}
}

final class ChatWebReadToolTests: XCTestCase {
    func testProviderReadCapabilitiesAreExplicit() {
        XCTAssertFalse(WebSearchProvider.brave.supports(.read))
        XCTAssertTrue(WebSearchProvider.exa.supports(.read))
        XCTAssertTrue(WebSearchProvider.nimble.supports(.read))
        XCTAssertTrue(WebSearchProvider.firecrawl.supports(.read))
        XCTAssertFalse(WebSearchProvider.perplexity.supports(.read))
        XCTAssertTrue(WebSearchProvider.tavily.supports(.read))
        XCTAssertTrue(WebSearchProvider.parallel.supports(.read))
    }

    func testSearchOnlyProviderDoesNotAdvertiseReadWithoutAReader() throws {
        let suiteName = "ChatWebReadToolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WebBrowsingPreferences(defaults: defaults)
        preferences.searchProvider = .brave

        XCTAssertFalse(ChatWebReadToolRegistry.isConfigured(
            credentials: StubWebReadCredentialStore(keys: [.brave: "key"]),
            preferences: preferences
        ))
    }

    func testSeparateConfiguredPageReaderAdvertisesRead() throws {
        let suiteName = "ChatWebReadToolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WebBrowsingPreferences(defaults: defaults)
        preferences.searchProvider = .brave
        preferences.pageReaderProvider = .exa

        XCTAssertTrue(ChatWebReadToolRegistry.isConfigured(
            credentials: StubWebReadCredentialStore(keys: [.brave: "search", .exa: "read"]),
            preferences: preferences
        ))
    }

    func testMissingPageReaderReturnsActionableFailure() async throws {
        let suiteName = "ChatWebReadToolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WebBrowsingPreferences(defaults: defaults)
        preferences.searchProvider = .brave
        let executor = ChatWebReadToolExecutor(
            credentials: StubWebReadCredentialStore(keys: [.brave: "key"]),
            preferences: preferences,
            client: StubWebReadHTTPClient(response: "{}")
        )

        do {
            _ = try await executor.execute(call: MLXChatToolCall(
                id: "read",
                function: MLXChatFunctionCall(
                    name: ChatWebReadToolRegistry.toolName,
                    arguments: #"{"urls":["https://example.com"]}"#
                )
            ))
            XCTFail("Expected page-reader routing to be required")
        } catch {
            let data = try XCTUnwrap(executor.failurePayload(error: error).data(using: .utf8))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let failure = try XCTUnwrap(root["error"] as? [String: Any])
            XCTAssertEqual(failure["code"] as? String, "page_reader_not_configured")
            XCTAssertTrue((failure["user_action_required"] as? String)?.contains("Extensions → Browsing") == true)
        }
    }

    func testExaReadsURLsInOneBoundedBatch() async throws {
        let content = String(repeating: "a", count: 7_000)
        let response = try jsonString([
            "results": [
                ["id": "https://example.com/one", "title": "One", "text": content],
                ["id": "https://example.com/two", "title": "Two", "text": "Second"],
            ],
        ])
        let client = StubWebReadHTTPClient(response: response)

        let pages = try await WebReadService(client: client).read(
            provider: .exa,
            apiKey: "exa-key",
            urls: ["https://example.com/one", "https://example.com/two"]
        )

        let requests = await client.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try body(of: request)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://api.exa.ai/contents")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "exa-key")
        XCTAssertEqual(body["urls"] as? [String], ["https://example.com/one", "https://example.com/two"])
        XCTAssertEqual(body["text"] as? Bool, true)
        XCTAssertEqual(pages.map(\.url), ["https://example.com/one", "https://example.com/two"])
        XCTAssertEqual(pages[0].content?.count, 6_000)
        XCTAssertTrue(pages[0].truncated)
        XCTAssertEqual(pages[1].content, "Second")
    }

    func testExaUsesFocusedHighlightsWhenRequested() async throws {
        let response = try jsonString([
            "results": [[
                "id": "https://example.com/one",
                "title": "One",
                "text": String(repeating: "Full page. ", count: 1_000),
                "highlights": ["The focused answer is here."],
            ]],
        ])
        let client = StubWebReadHTTPClient(response: response)

        let pages = try await WebReadService(client: client).read(
            provider: .exa,
            apiKey: "exa-key",
            urls: ["https://example.com/one"],
            focus: "What is the focused answer?"
        )

        let requests = await client.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try body(of: request)
        let highlights = try XCTUnwrap(body["highlights"] as? [String: Any])
        XCTAssertEqual(highlights["query"] as? String, "What is the focused answer?")
        XCTAssertEqual(highlights["maxCharacters"] as? Int, 6_000)
        XCTAssertNil(body["text"])
        XCTAssertEqual(pages.first?.content, "The focused answer is here.")
        XCTAssertEqual(pages.first?.truncated, true)
    }

    func testNimbleRequestsMarkdownFromExtract() async throws {
        let client = StubWebReadHTTPClient(
            response: ##"{"status":"success","data":{"markdown":"# Nimble page"}}"##
        )

        let pages = try await WebReadService(client: client).read(
            provider: .nimble,
            apiKey: "nimble-key",
            urls: ["https://example.com/nimble"]
        )

        let requests = await client.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try body(of: request)
        XCTAssertEqual(request.url?.absoluteString, "https://sdk.nimbleway.com/v2/extract")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer nimble-key")
        XCTAssertEqual(body["formats"] as? [String], ["markdown"])
        XCTAssertEqual(body["render"] as? String, "auto")
        XCTAssertEqual(pages.first?.content, "# Nimble page")
    }

    func testFirecrawlRequestsOnlyMainMarkdownContent() async throws {
        let client = StubWebReadHTTPClient(
            response: #"{"success":true,"data":{"markdown":"Firecrawl page","metadata":{"title":"Example"}}}"#
        )

        let pages = try await WebReadService(client: client).read(
            provider: .firecrawl,
            apiKey: "firecrawl-key",
            urls: ["https://example.com/firecrawl"]
        )

        let requests = await client.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try body(of: request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.firecrawl.dev/v2/scrape")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer firecrawl-key")
        XCTAssertEqual(body["onlyMainContent"] as? Bool, true)
        XCTAssertEqual(body["removeBase64Images"] as? Bool, true)
        XCTAssertEqual(pages.first?.title, "Example")
        XCTAssertEqual(pages.first?.content, "Firecrawl page")
    }

    func testTavilyUsesFocusedBatchExtraction() async throws {
        let client = StubWebReadHTTPClient(
            response: #"{"results":[{"url":"https://example.com/tavily","raw_content":"Relevant Tavily content"}]}"#
        )

        let pages = try await WebReadService(client: client).read(
            provider: .tavily,
            apiKey: "tavily-key",
            urls: ["https://example.com/tavily"],
            focus: "What matters?"
        )

        let requests = await client.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try body(of: request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.tavily.com/extract")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tavily-key")
        XCTAssertEqual(body["query"] as? String, "What matters?")
        XCTAssertEqual(body["chunks_per_source"] as? Int, 5)
        XCTAssertEqual(body["extract_depth"] as? String, "basic")
        XCTAssertEqual(pages.first?.content, "Relevant Tavily content")
        XCTAssertEqual(pages.first?.truncated, true)
    }

    func testParallelRequestsFocusedExcerpts() async throws {
        let client = StubWebReadHTTPClient(
            response: #"{"results":[{"url":"https://example.com/parallel","title":"Example","excerpts":["Focused excerpt"],"full_content":null}]}"#
        )

        let pages = try await WebReadService(client: client).read(
            provider: .parallel,
            apiKey: "parallel-key",
            urls: ["https://example.com/parallel"],
            focus: "What matters?"
        )

        let requests = await client.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try body(of: request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.parallel.ai/v1/extract")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "parallel-key")
        XCTAssertEqual(body["objective"] as? String, "What matters?")
        XCTAssertEqual(body["max_chars_total"] as? Int, 6_000)
        XCTAssertNil(body["advanced_settings"])
        XCTAssertEqual(pages.first?.title, "Example")
        XCTAssertEqual(pages.first?.content, "Focused excerpt")
        XCTAssertEqual(pages.first?.truncated, true)
    }

    func testParallelRequestsBoundedFullContentWithoutFocus() async throws {
        let client = StubWebReadHTTPClient(
            response: #"{"results":[{"url":"https://example.com/parallel","excerpts":["Excerpt"],"full_content":"Full page"}]}"#
        )

        let pages = try await WebReadService(client: client).read(
            provider: .parallel,
            apiKey: "parallel-key",
            urls: ["https://example.com/parallel"]
        )

        let requests = await client.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try body(of: request)
        let advancedSettings = try XCTUnwrap(body["advanced_settings"] as? [String: Any])
        let fullContent = try XCTUnwrap(advancedSettings["full_content"] as? [String: Any])
        XCTAssertEqual(fullContent["max_chars_per_result"] as? Int, 6_000)
        XCTAssertEqual(pages.first?.content, "Full page")
        XCTAssertEqual(pages.first?.truncated, false)
    }

    func testIndependentPageReadsRunConcurrentlyAndPreserveOrder() async throws {
        let client = StubWebReadHTTPClient(
            response: #"{"success":true,"data":{"markdown":"Page"}}"#,
            delayNanoseconds: 30_000_000
        )
        let urls = ["https://example.com/one", "https://example.com/two"]

        let pages = try await WebReadService(client: client).read(
            provider: .firecrawl,
            apiKey: "key",
            urls: urls
        )

        let maximumConcurrentRequests = await client.maximumConcurrentRequests()
        XCTAssertEqual(pages.map(\.url), urls)
        XCTAssertEqual(maximumConcurrentRequests, 2)
    }

    func testReadOutputHasAPerPageAndTotalBudget() async throws {
        let content = String(repeating: "x", count: 7_000)
        let results = (1 ... 4).map {
            ["id": "https://example.com/\($0)", "text": content]
        }
        let client = StubWebReadHTTPClient(response: try jsonString(["results": results]))

        let pages = try await WebReadService(client: client).read(
            provider: .exa,
            apiKey: "key",
            urls: (1 ... 4).map { "https://example.com/\($0)" }
        )

        XCTAssertEqual(pages.compactMap(\.content).map(\.count), [5_000, 5_000, 5_000, 5_000])
        XCTAssertEqual(pages.compactMap(\.content).reduce(0) { $0 + $1.count }, 20_000)
        XCTAssertTrue(pages.allSatisfy { $0.truncated })
    }

    func testLocalFocusSelectionFindsRelevantContentBeyondTheBeginning() {
        let introduction = String(repeating: "General background without the answer. ", count: 180)
        let content = """
        # Introduction
        \(introduction)

        # Launch details
        The project launched on 14 March 2025 after the final review.

        # Appendix
        \(String(repeating: "Reference material. ", count: 100))
        """

        let selection = WebReadContentSelector.select(
            content,
            focus: "When did the project launch?",
            limit: 700
        )

        XCTAssertTrue(selection.content.contains("14 March 2025"))
        XCTAssertFalse(selection.content.contains(String(introduction.prefix(80))))
        XCTAssertLessThanOrEqual(selection.content.count, 700)
        XCTAssertTrue(selection.truncated)
    }

    func testReadWithoutFocusPreservesTheBeginningAndEnd() {
        let content = "START-" + String(repeating: "middle", count: 500) + "-END"

        let selection = WebReadContentSelector.select(content, focus: nil, limit: 300)

        XCTAssertTrue(selection.content.hasPrefix("START-"))
        XCTAssertTrue(selection.content.hasSuffix("-END"))
        XCTAssertTrue(selection.content.contains("[content omitted]"))
        XCTAssertEqual(selection.content.count, 300)
    }

    func testURLPolicyRejectsPrivateAndCredentialBearingURLs() {
        XCTAssertNil(WebReadURLPolicy.normalizedURL("http://127.0.0.1/private"))
        XCTAssertNil(WebReadURLPolicy.normalizedURL("http://127.0.0.1./private"))
        XCTAssertNil(WebReadURLPolicy.normalizedURL("http://0x7f.0.0.1/private"))
        XCTAssertNil(WebReadURLPolicy.normalizedURL("http://192.168.1.4/private"))
        XCTAssertNil(WebReadURLPolicy.normalizedURL("http://[::1]/private"))
        XCTAssertNil(WebReadURLPolicy.normalizedURL("https://service.internal/data"))
        XCTAssertNil(WebReadURLPolicy.normalizedURL("https://user:secret@example.com"))
        XCTAssertNil(WebReadURLPolicy.normalizedURL("https://example.com?access_token=secret"))
        XCTAssertEqual(
            WebReadURLPolicy.normalizedURL("https://example.com/article#section"),
            "https://example.com/article"
        )
    }

    func testUnsupportedProviderFailsBeforeMakingARequest() async throws {
        let client = StubWebReadHTTPClient(response: "{}")
        do {
            _ = try await WebReadService(client: client).read(
                provider: .brave,
                apiKey: "key",
                urls: ["https://example.com"]
            )
            XCTFail("Expected Brave URL reading to be rejected")
        } catch let error as WebReadError {
            XCTAssertEqual(error.code, "unsupported_provider")
        }
        let requests = await client.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testOversizedFocusFailsBeforeMakingARequest() async throws {
        let client = StubWebReadHTTPClient(response: "{}")
        do {
            _ = try await WebReadService(client: client).read(
                provider: .exa,
                apiKey: "key",
                urls: ["https://example.com"],
                focus: String(repeating: "x", count: ChatWebReadToolRegistry.maximumFocusLength + 1)
            )
            XCTFail("Expected an oversized focus to be rejected")
        } catch let error as WebReadError {
            XCTAssertEqual(error.code, "invalid_arguments")
        }
        let requests = await client.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testPageFailureIsReturnedWithoutDiscardingTheBatch() async throws {
        let client = StubWebReadHTTPClient(response: "{}", statusCode: 404)

        let pages = try await WebReadService(client: client).read(
            provider: .firecrawl,
            apiKey: "key",
            urls: ["https://example.com/missing"]
        )

        XCTAssertEqual(pages.count, 1)
        XCTAssertFalse(pages[0].isSuccess)
        XCTAssertEqual(pages[0].error?.code, WebBrowsingFailureCode.requestFailed.rawValue)
    }

    func testToolSchemaStaysCompactAndBounded() throws {
        XCTAssertTrue(
            ChatWebReadToolRegistry.definition.function.description.contains("not instructions")
        )
        let parameters = ChatWebReadToolRegistry.definition.function.parameters
        let data = try JSONEncoder().encode(parameters)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try XCTUnwrap(root["properties"] as? [String: Any])
        let urls = try XCTUnwrap(properties["urls"] as? [String: Any])
        let focus = try XCTUnwrap(properties["focus"] as? [String: Any])

        XCTAssertEqual(Set(properties.keys), ["focus", "urls"])
        XCTAssertEqual(urls["minItems"] as? Int, 1)
        XCTAssertEqual(urls["maxItems"] as? Int, ChatWebReadToolRegistry.maximumURLs)
        XCTAssertEqual(urls["uniqueItems"] as? Bool, true)
        XCTAssertEqual(focus["maxLength"] as? Int, ChatWebReadToolRegistry.maximumFocusLength)
    }

    func testSuccessfulToolPayloadContainsOnlyUsefulPageFields() async throws {
        let suiteName = "ChatWebReadToolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WebBrowsingPreferences(defaults: defaults)
        preferences.searchProvider = .exa
        let client = StubWebReadHTTPClient(
            response: #"{"results":[{"id":"https://example.com","text":"Page text"}]}"#
        )
        let executor = ChatWebReadToolExecutor(
            credentials: StubWebReadCredentialStore(keys: [.exa: "key"]),
            preferences: preferences,
            client: client
        )

        let payload = try await executor.execute(call: MLXChatToolCall(
            id: "read",
            function: MLXChatFunctionCall(
                name: ChatWebReadToolRegistry.toolName,
                arguments: #"{"urls":["https://example.com"]}"#
            )
        ))
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pages = try XCTUnwrap(root["pages"] as? [[String: Any]])
        let page = try XCTUnwrap(pages.first)

        XCTAssertEqual(Set(root.keys), ["pages"])
        XCTAssertEqual(Set(page.keys), ["content", "url"])
    }

    private func jsonString(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
