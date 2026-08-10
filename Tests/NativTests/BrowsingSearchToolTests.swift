import Foundation
import XCTest

private actor StubBrowsingHTTPClient: BrowsingHTTPClient {
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

final class BrowsingSearchToolTests: XCTestCase {
    func testBraveRequestAndResultMapping() async throws {
        let client = StubBrowsingHTTPClient(
            response: #"{"web":{"results":[{"title":"Nativ","url":"https://nativ.dev","description":"Local AI"}]}}"#
        )

        let results = try await BrowsingSearchService.search(
            provider: .brave,
            apiKey: "brave-key",
            query: "local ai",
            limit: 2,
            client: client
        )

        let capturedRequest = await client.recordedRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.host, "api.search.brave.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-Token"), "brave-key")
        XCTAssertEqual(request.url?.query, "q=local%20ai&count=2")
        XCTAssertEqual(results, [BrowsingSearchResult(title: "Nativ", url: "https://nativ.dev", description: "Local AI")])
    }

    func testExaRequestAndResultMapping() async throws {
        let client = StubBrowsingHTTPClient(
            response: #"{"results":[{"title":"Exa result","url":"https://exa.ai","highlights":["A highlight"]}]}"#
        )

        let results = try await BrowsingSearchService.search(
            provider: .exa,
            apiKey: "exa-key",
            query: "search",
            limit: 1,
            client: client
        )

        let capturedRequest = await client.recordedRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.exa.ai/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "exa-key")
        XCTAssertEqual(try body(of: request)["numResults"] as? Int, 1)
        XCTAssertEqual(results.first?.description, "A highlight")
    }

    func testNimbleRequestAndResultMapping() async throws {
        let client = StubBrowsingHTTPClient(
            response: #"{"results":[{"title":"Nimble result","url":"https://nimbleway.com","content":"Result body"}]}"#
        )

        let results = try await BrowsingSearchService.search(
            provider: .nimble,
            apiKey: "nimble-key",
            query: "search",
            limit: 1,
            client: client
        )

        let capturedRequest = await client.recordedRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://sdk.nimbleway.com/v2/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer nimble-key")
        XCTAssertEqual(try body(of: request)["search_depth"] as? String, "lite")
        XCTAssertEqual(results.first?.description, "Result body")
    }

    func testFirecrawlRequestAndResultMapping() async throws {
        let client = StubBrowsingHTTPClient(
            response: #"{"data":{"web":[{"title":"Firecrawl result","url":"https://firecrawl.dev","markdown":"Page text"}]}}"#
        )

        let results = try await BrowsingSearchService.search(
            provider: .firecrawl,
            apiKey: "firecrawl-key",
            query: "search",
            limit: 1,
            client: client
        )

        let capturedRequest = await client.recordedRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.firecrawl.dev/v2/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer firecrawl-key")
        XCTAssertEqual(try body(of: request)["sources"] as? [String], ["web"])
        XCTAssertEqual(results.first?.description, "Page text")
    }

    func testPerplexityRequestAndResultMapping() async throws {
        let client = StubBrowsingHTTPClient(
            response: #"{"results":[{"title":"Perplexity result","url":"https://perplexity.ai","snippet":"A snippet"}]}"#
        )

        let results = try await BrowsingSearchService.search(
            provider: .perplexity,
            apiKey: "perplexity-key",
            query: "search",
            limit: 1,
            client: client
        )

        let capturedRequest = await client.recordedRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.perplexity.ai/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer perplexity-key")
        XCTAssertEqual(try body(of: request)["search_context_size"] as? String, "low")
        XCTAssertEqual(results.first?.description, "A snippet")
    }

    func testNonSuccessResponseReportsProviderAndStatus() async throws {
        let client = StubBrowsingHTTPClient(response: "{}", statusCode: 401)

        do {
            _ = try await BrowsingSearchService.search(
                provider: .brave,
                apiKey: "bad-key",
                query: "search",
                limit: 1,
                client: client
            )
            XCTFail("expected request failure")
        } catch let error as BrowsingSearchError {
            XCTAssertEqual(error.errorDescription, "Brave returned HTTP 401.")
            XCTAssertTrue(BrowsingSearchError.invalidatesCredential(error))
        }
    }

    func testSearchResultBoundsFields() {
        let result = BrowsingSearchResult(
            title: String(repeating: "t", count: 170),
            url: "https://example.com",
            description: String(repeating: "d", count: 310)
        )

        XCTAssertEqual(result.title.count, 160)
        XCTAssertEqual(result.description.count, 300)
    }

    func testBrowsingFailurePayloadUsesTheToolErrorShape() throws {
        let data = try XCTUnwrap(
            BrowsingSearchTool.failurePayload(error: BrowsingSearchError.invalidQuery).data(using: .utf8)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["error"] as? String, "web_search needs a non-empty query.")
        XCTAssertNil(object["operation"])
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
