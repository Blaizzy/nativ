import XCTest
import WebKit
import Network

@MainActor
final class ChatWorkBrowserTests: XCTestCase {
    func testNavigationDoesNotPublishThePreviousURLDuringLoading() async throws {
        let server = try ChatWorkHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        let browser = ChatWorkBrowser()
        var item = ChatWorkItem(title: "Fixture", kind: .website, content: "", url: base.absoluteString)
        var addresses: [String] = []
        browser.onNavigate = { url in addresses.append(url); item.url = url }
        browser.load(item)
        let first = try await browser.execute(ChatWorkRequest(action: .inspect))
        XCTAssertTrue(first.contains("Browser fixture"))
        let next = base.appendingPathComponent("next").absoluteString
        try browser.navigate(next)
        browser.load(item) // A SwiftUI update can occur before the next page commits.
        let result = try await browser.execute(ChatWorkRequest(action: .inspect))
        XCTAssertEqual(try decode(result)["url"] as? String, next)
        XCTAssertEqual(addresses, [next])
        XCTAssertEqual(item.url, next)
        browser.load(item)
        XCTAssertEqual(browser.webView.url?.absoluteString, next)
    }

    func testTargetBlankLinkOpensInTheSharedBrowser() async throws {
        let server = try ChatWorkHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        let browser = ChatWorkBrowser()
        browser.load(ChatWorkItem(title: "Fixture", kind: .website, content: "", url: base.absoluteString))
        let first = try decode(await browser.execute(ChatWorkRequest(action: .inspect)))
        let result = try await browser.execute(ChatWorkRequest(action: .click, elementID: element("New window", in: first)))
        XCTAssertEqual(try decode(result)["title"] as? String, "Next page")
    }

    func testRemotePagesCanRenderInlineFrames() async throws {
        let browser = ChatWorkBrowser()
        browser.load(ChatWorkItem(title: "Remote", kind: .website, content: "", url: "http://127.0.0.1:1"))
        browser.webView.stopLoading()
        browser.webView.loadHTMLString("""
            <main>Host page</main><iframe srcdoc="<p>Embedded chart labels</p>"></iframe>
            """, baseURL: URL(string: "https://fixture.invalid"))
        _ = try await inspect(browser)
        let frameText = try await browser.webView.evaluateJavaScript("document.querySelector('iframe').contentDocument.body.innerText")
        XCTAssertEqual(frameText as? String, "Embedded chart labels")
    }

    func testTranslationUsesSelectedTextOrPageProseWithoutFormValues() async throws {
        let browser = ChatWorkBrowser()
        browser.webView.loadHTMLString("""
            <nav>Navigation</nav><main><h1>Hello</h1><p>Translate this sentence.</p></main>
            <input type="password" value="do-not-translate">
            """, baseURL: nil)
        _ = try await inspect(browser)
        let page = try await browser.textForTranslation()
        XCTAssertTrue(page.contains("Hello"))
        XCTAssertFalse(page.contains("Navigation"))
        XCTAssertFalse(page.contains("do-not-translate"))
        _ = try await browser.webView.evaluateJavaScript("""
            var range = document.createRange(); range.selectNodeContents(document.querySelector('p'));
            window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
            """)
        let selected = try await browser.textForTranslation()
        XCTAssertEqual(selected, "Translate this sentence.")
    }

    func testGeneratedPreviewTranslationReadsThePreviewFrame() async throws {
        let browser = ChatWorkBrowser()
        browser.load(ChatWorkItem(title: "Preview", kind: .website, content: "<h1>Hello from the preview</h1>"))
        _ = try await inspect(browser)
        let text = try await browser.textForTranslation()
        XCTAssertEqual(text, "Hello from the preview")
    }

    func testAgentInspectsTypesAndClicksTheSharedPage() async throws {
        let browser = ChatWorkBrowser()
        browser.webView.loadHTMLString("""
            <html><head><title>Shared fixture</title></head><body>
            <input aria-label="Name"><input type="password" value="do-not-expose" aria-label="Password">
            <button onclick="document.getElementById('result').innerText='Clicked'">Apply</button>
            <p id="result">Ready</p></body></html>
            """, baseURL: nil)
        let first = try await inspect(browser)
        XCTAssertEqual(first["title"] as? String, "Shared fixture")
        let input = try element("Name", in: first)
        let typed = try await browser.execute(ChatWorkRequest(action: .type, elementID: input, text: "Nativ"))
        XCTAssertTrue(typed.contains("Nativ"))
        XCTAssertFalse(typed.contains("do-not-expose"))
        let typedState = try decode(typed)
        let button = try element("Apply", in: typedState)
        let clicked = try await browser.execute(ChatWorkRequest(action: .click, elementID: button))
        XCTAssertTrue(clicked.contains("Clicked"))
        let rendered = try await browser.webView.evaluateJavaScript("document.getElementById('result').innerText")
        XCTAssertEqual(rendered as? String, "Clicked")
        do {
            _ = try await browser.execute(ChatWorkRequest(action: .click, elementID: button))
            XCTFail("An element from an earlier snapshot must be rejected")
        } catch { XCTAssertTrue(error is ChatWorkError) }
    }

    func testAnInterveningUserInputPreventsAgentOverwrite() async throws {
        let browser = ChatWorkBrowser()
        browser.webView.loadHTMLString("<input aria-label='Name' value='Original'>", baseURL: nil)
        let state = try await inspect(browser)
        let id = try element("Name", in: state)
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('input').value='User edit'")
        do {
            _ = try await browser.execute(ChatWorkRequest(action: .type, elementID: id, text: "Stale edit"))
            XCTFail("An agent must inspect again after a user edits the input")
        } catch { XCTAssertTrue(error is ChatWorkError) }
        let value = try await browser.webView.evaluateJavaScript("document.querySelector('input').value")
        XCTAssertEqual(value as? String, "User edit")
    }

    func testBrowserPoolKeepsSessionIsolationAndTabState() {
        let pool = ChatWorkBrowserPool()
        let item = ChatWorkItem(title: "Page", kind: .website, content: "<h1>Page</h1>")
        let session = UUID()
        let first = pool.browser(for: item, sessionID: session)
        XCTAssertTrue(first === pool.browser(for: item, sessionID: session))
        XCTAssertFalse(first === pool.browser(for: item, sessionID: UUID()))
        pool.remove(itemID: item.id, sessionID: session)
        XCTAssertFalse(first === pool.browser(for: item, sessionID: session))
    }

    private func inspect(_ browser: ChatWorkBrowser) async throws -> [String: Any] {
        // WebKit commits the queued HTML load on the next main run-loop turn.
        try await Task.sleep(for: .milliseconds(100))
        return try decode(await browser.execute(ChatWorkRequest(action: .inspect)))
    }

    private func decode(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func element(_ label: String, in snapshot: [String: Any]) throws -> String {
        let elements = try XCTUnwrap(snapshot["elements"] as? [[String: Any]])
        return try XCTUnwrap(elements.first { $0["label"] as? String == label }?["id"] as? String)
    }
}

/// Real loopback HTTP pages exercise WebKit navigation, redirects, and form submissions.
@MainActor
final class ChatWorkHTTPFixture {
    private let listener: NWListener

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Self.receive(connection, buffered: Data())
        }
    }

    func start() async throws -> URL {
        listener.start(queue: .global())
        for _ in 0..<500 {
            if case .ready = listener.state, let port = listener.port {
                return URL(string: "http://127.0.0.1:\(port.rawValue)/")!
            }
            if case .failed(let error) = listener.state { throw error }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }

    func stop() { listener.cancel() }

    nonisolated private static func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
            let request = buffered + (data ?? Data())
            guard let header = String(data: request, encoding: .utf8), header.contains("\r\n\r\n") else {
                if complete || error != nil || request.count > 16_384 { connection.cancel() }
                else { receive(connection, buffered: request) }
                return
            }
            let path = header.components(separatedBy: " ").dropFirst().first ?? "/"
            let html: String
            if path.hasPrefix("/result") {
                html = "<title>Search results</title><h1>Search results</h1><a href='/next'>Next</a>"
            } else if path.hasPrefix("/next") {
                html = "<title>Next page</title><h1>Next page loaded</h1><a href='/'>Home</a>"
            } else {
                html = """
                    <title>Browser fixture</title><h1>Browser fixture</h1>
                    <form action='/result'><label for='q'>Search terms</label><input id='q' name='q'>
                    <button type='submit'>Search</button></form><a href='/next' target='_blank'>New window</a>
                    """
            }
            let body = Data("<!doctype html><html><body>\(html)</body></html>".utf8)
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
