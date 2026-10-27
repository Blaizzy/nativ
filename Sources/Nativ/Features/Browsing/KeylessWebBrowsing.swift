import Foundation
import WebKit

/// HTTP retrieval plus an inert HTML parser. No page scripts, cookies or visible tab.
struct KeylessWebBrowsing: Sendable {
    let client: any WebBrowsingHTTPClient

    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 300 else { throw WebBrowsingError.invalidArguments }
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let html = try await fetch(components.url!)
        let parsed = try await Self.parse(html, search: true)
        let results = parsed.results.compactMap { item in
            guard let href = item["url"],
                  let url = URL(string: href, relativeTo: components.url)?.absoluteURL else { return nil as WebSearchResult? }
            let destination = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "uddg" })?.value ?? url.absoluteString
            guard WebReadURLPolicy.normalizedURL(destination) != nil else { return nil }
            return WebSearchResult(title: item["title"], url: destination, snippet: item["snippet"])
        }
        // A challenge page must never masquerade as a successful empty search.
        guard !results.isEmpty else { throw KeylessWebBrowsingError.unavailable }
        return Array(results.prefix(min(max(limit, 1), 10)))
    }

    func read(urls: [String], focus: String?) async throws -> [WebReadPage] {
        guard (1...WebReadService.maximumURLs).contains(urls.count),
              focus?.count ?? 0 <= WebReadService.maximumFocusLength else { throw WebReadError.invalidArguments }
        let normalized = try urls.map { value -> String in
            guard let url = WebReadURLPolicy.normalizedURL(value) else { throw WebReadError.invalidURL }
            return url
        }
        guard Set(normalized).count == normalized.count else { throw WebReadError.invalidArguments }
        var pages: [WebReadPage] = []
        for url in normalized {
            do {
                let html = try await fetch(URL(string: url)!)
                let parsed = try await Self.parse(html, search: false)
                guard let text = normalizedWebContent(parsed.text) else {
                    throw KeylessWebBrowsingError.unreadable
                }
                let selection = WebReadContentSelector.select(text, focus: focus, limit: 6_000)
                pages.append(WebReadPage(url: url, title: normalizedWebTitle(parsed.title),
                                         content: selection.content, truncated: selection.truncated, error: nil))
            } catch is CancellationError { throw CancellationError() }
            catch {
                pages.append(WebReadPage(url: url, title: nil, content: nil, truncated: false,
                                         error: WebReadPageError(code: "page_unavailable", message: error.localizedDescription)))
            }
        }
        return pages
    }

    private func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("text/html, text/plain;q=0.9", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let (data, response) = try await client.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              let finalURL = response.url,
              WebReadURLPolicy.normalizedURL(finalURL.absoluteString) != nil,
              data.count <= 2_000_000 else { throw KeylessWebBrowsingError.unavailable }
        let mime = response.mimeType?.lowercased()
        guard mime == nil || ["text/html", "application/xhtml+xml", "text/plain"].contains(mime!) else {
            throw KeylessWebBrowsingError.unreadable
        }
        guard let text = String(data: data, encoding: .utf8) else { throw KeylessWebBrowsingError.unreadable }
        if mime == "text/plain" {
            return "<pre>" + text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;") + "</pre>"
        }
        return text
    }

    private struct ParsedPage: Sendable {
        let title: String?
        let text: String?
        let results: [[String: String]]
    }

    @MainActor
    private static func parse(_ html: String, search: Bool) async throws -> ParsedPage {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let parser = WKWebView(frame: .zero, configuration: configuration)
        // A detached <template> keeps scripts, images, frames and styles inert.
        // It also lets us parse malformed real-world HTML without regex stripping.
        let value = try await parser.callAsyncJavaScript("""
            const template = document.createElement('template');
            template.innerHTML = html;
            const root = template.content;
            const clean = text => (text || '').replace(/\\s+/g, ' ').trim();
            if (search) {
                return {results: [...root.querySelectorAll('.result')].slice(0, 20).map(result => {
                    const link = result.querySelector('a.result__a');
                    return {title: clean(link?.textContent), url: link?.getAttribute('href') || '',
                            snippet: clean(result.querySelector('.result__snippet')?.textContent)};
                })};
            }
            const title = clean(root.querySelector('title')?.textContent);
            root.querySelectorAll('script,style,noscript,nav,header,footer,aside,form,svg,iframe,[hidden],[aria-hidden="true"],[role="dialog"],[role="navigation"]').forEach(el => el.remove());
            const content = root.querySelector('main,article,[role="main"]') || root;
            content.querySelectorAll('p,div,section,article,li,h1,h2,h3,h4,br,tr').forEach(el => el.append('\\n'));
            const text = (content.textContent || '').split('\\n').map(clean).filter(Boolean).join('\\n');
            return {title, text};
            """, arguments: ["html": html, "search": search], in: nil, contentWorld: .defaultClient)
        guard let object = value as? [String: Any] else { throw KeylessWebBrowsingError.unreadable }
        return ParsedPage(title: object["title"] as? String, text: object["text"] as? String,
                          results: object["results"] as? [[String: String]] ?? [])
    }
}

enum KeylessWebBrowsingError: LocalizedError {
    case unavailable, unreadable
    var errorDescription: String? {
        switch self {
        case .unavailable: "Text browsing is unavailable or was blocked by the website. Use the shared browser or configure a browsing provider."
        case .unreadable: "This page has no readable text. Use the shared browser for pages that require JavaScript."
        }
    }
}
