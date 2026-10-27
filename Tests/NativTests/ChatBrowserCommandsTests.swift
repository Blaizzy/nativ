import XCTest
import WebKit

final class ChatBrowserCommandsTests: XCTestCase {
    func testPageChunksPreserveUnicodeAndCanBeReadToTheEnd() throws {
        let text = String(repeating: "piña 🍍 漢字\n", count: 1500)
        var offset = 0, reconstructed = ""
        repeat {
            let result = try ChatBrowserCommands.pageResult(
                ["text": text, "url": "https://example.com/source", "title": "Source", "id": "tab"],
                offset: offset, maximumBytes: 4096)
            XCTAssertLessThanOrEqual(result.utf8.count, 4096)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
            reconstructed += try XCTUnwrap(object["content"] as? String)
            guard let next = object["next_offset"] as? Int else { break }
            XCTAssertGreaterThan(next, offset)
            offset = next
        } while offset < text.count
        XCTAssertEqual(reconstructed, text)
    }

    func testReadReusesTheSelectedBrowserInsteadOfOpeningATabPerPage() throws {
        let request = try ChatBrowserCommands.request(name: "browser_read", arguments: Data(#"{"url":"http://localhost:8080/page"}"#.utf8))
        XCTAssertEqual(request.action, .navigate)
        XCTAssertEqual(request.url, "http://localhost:8080/page")
    }

    func testInvalidReadNeverProducesANavigationRequest() {
        for args in [#"{"url":"file:///etc/passwd"}"#, #"{"url":"https://example.com","offset":-1}"#, #"{}"#] {
            XCTAssertThrowsError(try ChatBrowserCommands.request(name: "browser_read", arguments: Data(args.utf8)))
        }
    }

    @MainActor
    func testSearchExtractionUsesRenderedHeadingsAndExcludesGoogleNavigation() async throws {
        let browser = ChatWorkBrowser(profile: ChatWorkBrowserProfile(dataStore: .nonPersistent()))
        browser.load(ChatWorkItem(title: "Search fixture", kind: .website, content: """
            <html><body><main><a href="https://accounts.google.com"><h3>Account</h3></a>
            <div class="g"><a href="https://example.com/ocr"><h3>Local OCR</h3></a><p>Source description.</p></div>
            <a href="https://example.com/ocr"><h3>Duplicate</h3></a>
            <a href="https://www.google.com/url?q=https%3A%2F%2Fexample.com%2Fother&amp;sa=U"><h3>Redirected source</h3></a>
            <a href="https://www.google.com/goto?url=opaque"><h3>Browser redirect</h3></a></main></body></html>
            """))
        defer { browser.stop() }
        _ = try await browser.execute(ChatWorkRequest(action: .inspect))
        let snapshot = try await browser.webView.callAsyncJavaScript(
            ChatBrowserCommands.extractionScript, arguments: [:], in: nil, contentWorld: .defaultClient
        ) as? [String: Any]
        let results = try XCTUnwrap(snapshot?["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.first?["url"] as? String, "https://example.com/ocr")
        XCTAssertEqual(results.first?["title"] as? String, "Local OCR")
        XCTAssertEqual(results[1]["url"] as? String, "https://example.com/other")
        XCTAssertEqual(results.last?["url"] as? String, "https://www.google.com/goto?url=opaque")
        XCTAssertTrue(results.first?["snippet"] as? String == "Local OCR\n\nSource description.")
    }
}
