import XCTest
import WebKit
import Network

@MainActor
final class ChatWorkBrowserTests: XCTestCase {
    func testFirstRequestAndPageIdentifyTheInstalledSafariVersion() async throws {
        let server = try ChatWorkHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        let browser = ChatWorkBrowser()
        browser.load(ChatWorkItem(title: "Identity", kind: .website, content: "",
                                 url: base.appendingPathComponent("user-agent").absoluteString))
        _ = try await browser.execute(ChatWorkRequest(action: .inspect))
        let requestAgent = try await browser.webView.evaluateJavaScript(
            "document.getElementById('request-agent').textContent") as? String
        let pageAgent = try await browser.webView.evaluateJavaScript("navigator.userAgent") as? String
        let version = try XCTUnwrap(Bundle(path: "/Applications/Safari.app")?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let agent = try XCTUnwrap(pageAgent)
        XCTAssertEqual(requestAgent, agent, "The first request and page scripts must see the same browser identity")
        XCTAssertTrue(agent.contains("Version/\(version) Safari/"), agent)
        XCTAssertTrue(agent.contains("AppleWebKit/"), agent)
        XCTAssertFalse(agent.contains("Chrome/"), "WebKit must not claim to be Chromium")
        XCTAssertFalse(browser.webView.configuration.websiteDataStore.isPersistent)
    }

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

    func testGeneratedPageTranslationReadsTheMainPage() async throws {
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

    func testGeneratedWebsiteRunsScriptsStorageModulesCanvasAndAgentClicks() async throws {
        let browser = ChatWorkBrowser()
        browser.webView.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        browser.load(ChatWorkItem(title: "Game", kind: .website, content: """
            <!doctype html><title>Local game</title><canvas width="40" height="40"></canvas>
            <button onclick="localStorage.setItem('played', 'yes'); document.querySelector('p').textContent='Started';
                document.querySelector('canvas').getContext('2d').fillRect(0,0,20,20)">Start</button><p>Ready</p>
            <script type="module">
            localStorage.setItem('module', 'ready');
            const html = await (await fetch(location.href)).text();
            document.body.dataset.fetched = String(html.includes('Local game'));
            document.addEventListener('keydown', e => { document.body.dataset.key = e.key; });
            </script>
            """))
        let first = try decode(await browser.execute(ChatWorkRequest(action: .inspect)))
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(first["url"] as? String)))
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(first["title"] as? String, "Local game")
        let clicked = try decode(await browser.execute(ChatWorkRequest(action: .click, elementID: element("Start", in: first))))
        XCTAssertTrue((clicked["text"] as? String)?.contains("Started") == true)
        for _ in 0..<30 {
            if try await browser.webView.evaluateJavaScript("document.body.dataset.fetched === 'true'") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let state = try await browser.webView.callAsyncJavaScript("""
            document.dispatchEvent(new KeyboardEvent('keydown', {key: 'ArrowRight'}));
            return [window.top === window, location.origin, localStorage.getItem('played'), localStorage.getItem('module'),
                document.body.dataset.fetched, document.body.dataset.key,
                document.querySelector('canvas').getContext('2d').getImageData(0,0,1,1).data[3]];
            """, arguments: [:], in: nil, contentWorld: .page) as? [Any]
        let values = try XCTUnwrap(state)
        XCTAssertEqual(values[0] as? Bool, true)
        XCTAssertTrue((values[1] as? String)?.hasPrefix("http://127.0.0.1:") == true)
        XCTAssertEqual(values[2] as? String, "yes")
        XCTAssertEqual(values[3] as? String, "ready")
        XCTAssertEqual(values[4] as? String, "true")
        XCTAssertEqual(values[5] as? String, "ArrowRight")
        XCTAssertEqual(values[6] as? Int, 255)
        XCTAssertTrue(browser.runtimeErrors.isEmpty, browser.runtimeErrors.description)
    }

    func testGeneratedPageReportsScriptFailuresAndClearsThemAfterSourceRepair() async throws {
        let browser = ChatWorkBrowser()
        var item = ChatWorkItem(title: "Broken game", kind: .website, content: """
            <button onclick="throw new Error('Start failed')">Start</button>
            <script>const snake = []; snake[0].x;</script>
            """)
        browser.load(item)
        let first = try decode(await browser.execute(ChatWorkRequest(action: .inspect)))
        XCTAssertFalse(try XCTUnwrap(first["runtime_errors"] as? [String]).isEmpty)
        let clicked = try decode(await browser.execute(ChatWorkRequest(action: .click, elementID: element("Start", in: first))))
        XCTAssertTrue(try XCTUnwrap(clicked["runtime_errors"] as? [String]).contains { $0.contains("Start failed") })
        let originalURL = browser.localPageURL
        item.content = "<h1>Repaired</h1><script>localStorage.setItem('version','2')</script>"
        browser.load(item)
        let repaired = try decode(await browser.execute(ChatWorkRequest(action: .inspect)))
        XCTAssertEqual(browser.localPageURL, originalURL)
        XCTAssertEqual(repaired["text"] as? String, "Repaired")
        XCTAssertEqual(repaired["runtime_errors"] as? [String], [])
        let value = try await browser.webView.evaluateJavaScript("localStorage.getItem('version')")
        XCTAssertEqual(value as? String, "2")
    }

    func testGeneratedNavigationAndReloadKeepTheEditableSourceAndOrigin() async throws {
        let remote = try ChatWorkHTTPFixture()
        let base = try await remote.start()
        defer { remote.stop() }
        let browser = ChatWorkBrowser()
        let item = ChatWorkItem(title: "Local", kind: .website, content: """
            <a href="\(base.absoluteString)" target="_blank">Navigate</a>
            <script>localStorage.setItem('loads', String(Number(localStorage.getItem('loads') || 0) + 1));</script>
            """)
        var published: [String] = []
        browser.onNavigate = { published.append($0) }
        browser.load(item)
        let first = try decode(await browser.execute(ChatWorkRequest(action: .inspect)))
        let local = try XCTUnwrap(browser.localPageURL)
        _ = try await browser.execute(ChatWorkRequest(action: .click, elementID: element("Navigate", in: first)))
        browser.load(item)
        XCTAssertEqual(browser.webView.url, base)
        _ = try await browser.execute(ChatWorkRequest(action: .back))
        _ = try await browser.execute(ChatWorkRequest(action: .reload))
        XCTAssertEqual(browser.webView.url, local)
        let loads = try await browser.webView.evaluateJavaScript("Number(localStorage.getItem('loads'))")
        XCTAssertGreaterThan(loads as? Int ?? 0, 1)
        XCTAssertTrue(published.isEmpty, "Temporary URLs must never replace generated source in saved chat state")
    }

    func testPreviewServerRestrictsRoutesAndHostAndServesUpdatedUTF8() async throws {
        let server = try ChatWorkPreviewServer()
        server.update("<h1>🐍</h1>")
        let url = try await server.start()
        defer { server.stop() }
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "<h1>🐍</h1>")
        for path in ["/", "/etc/passwd", "/wrong/index.html"] {
            let (_, response) = try await URLSession.shared.data(from: URL(string: path, relativeTo: url)!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        }
        var request = URLRequest(url: url)
        request.setValue("attacker.invalid", forHTTPHeaderField: "Host")
        let (_, forbidden) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((forbidden as? HTTPURLResponse)?.statusCode, 403)
        request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, method) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((method as? HTTPURLResponse)?.statusCode, 405)
        server.update("Updated")
        let (updated, _) = try await URLSession.shared.data(from: url)
        XCTAssertEqual(String(decoding: updated, as: UTF8.self), "Updated")
    }

    func testGeneratedPagesStayIsolatedAndClosingStopsTheirServer() async throws {
        let pool = ChatWorkBrowserPool()
        let session = UUID()
        var item = ChatWorkItem(title: "Page", kind: .website, content: "<p>First</p>")
        let first = pool.browser(for: item, sessionID: session)
        item.content = "<p>Latest source</p>"
        _ = pool.browser(for: item, sessionID: session)
        let latest = try decode(await first.execute(ChatWorkRequest(action: .inspect)))
        XCTAssertEqual(latest["text"] as? String, "Latest source")
        let firstURL = try XCTUnwrap(first.localPageURL)
        _ = try await first.webView.evaluateJavaScript("localStorage.setItem('private','first page')")
        let second = pool.browser(for: item, sessionID: UUID())
        _ = try await second.execute(ChatWorkRequest(action: .inspect))
        XCTAssertNotEqual(first.localPageURL?.port, second.localPageURL?.port)
        let value = try await second.webView.evaluateJavaScript("localStorage.getItem('private')")
        XCTAssertTrue(value is NSNull)
        pool.remove(itemID: item.id, sessionID: session)
        do {
            _ = try await URLSession.shared.data(for: URLRequest(url: firstURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2))
            XCTFail("Closing the tab must stop its loopback server even if a view still retains the browser")
        } catch { XCTAssertTrue(error is URLError) }
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
            if path == "/user-agent" {
                let agent = header.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("user-agent:") }?
                    .dropFirst("user-agent:".count).trimmingCharacters(in: .whitespaces) ?? ""
                let escaped = agent.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                html = "<title>Browser identity</title><pre id='request-agent'>\(escaped)</pre>"
            } else if path.hasPrefix("/result") {
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
