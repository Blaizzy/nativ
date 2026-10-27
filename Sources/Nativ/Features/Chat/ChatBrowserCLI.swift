import AppKit
import Foundation
import NativServerKit
import WebKit

/// Opt-in JSON-lines bridge for measured browser experiments. One process owns one session.
@MainActor
final class ChatBrowserCLI {
    private var state = ChatWorkState()
    private let sessionID = UUID()
    private let pool: ChatWorkBrowserPool
    private var window: NSWindow?

    init() {
        // Benchmarks can isolate cookies without modifying the user's app profile.
        let profile = ProcessInfo.processInfo.environment["NATIV_BROWSER_PROFILE"].flatMap(UUID.init(uuidString:))
            .map { ChatWorkBrowserProfile(dataStore: WKWebsiteDataStore(forIdentifier: $0)) } ?? .shared
        pool = ChatWorkBrowserPool(profile: profile)
    }

    static func run() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let cli = ChatBrowserCLI()
        DispatchQueue.global().async {
            while let line = readLine() {
                let completed = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    do { print(try await cli.handle(Data(line.utf8))) }
                    catch { print(ChatWorkToolRegistry.failurePayload(error: error)) }
                    fflush(stdout)
                    completed.signal()
                }
                completed.wait()
            }
            Task { @MainActor in exit(EXIT_SUCCESS) }
        }
        RunLoop.main.run()
    }

    func handle(_ data: Data) async throws -> String {
        struct Input: Decodable {
            var name: String
            var arguments: MLXJSONValue?
            var context: Int?
        }
        let input = try JSONDecoder().decode(Input.self, from: data)
        if input.name == "tools" {
            let definitions = ["compact": ChatBrowserCommands.definitions, "work": [ChatWorkToolRegistry.definition]]
            return String(decoding: try JSONEncoder().encode(definitions), as: UTF8.self)
        }
        let arguments = try JSONEncoder().encode(input.arguments ?? .object([:]))
        var request = input.name == "chat_work"
            ? try JSONDecoder().decode(ChatWorkRequest.self, from: arguments)
            : try ChatBrowserCommands.request(name: input.name, arguments: arguments)
        if input.name == "browser_read", state.selectedItem?.url == request.url {
            request.action = .inspect
        }
        let maximumBytes = ChatBrowsingBudget.maximumBytes(context: input.context ?? 8192)
        if request.action == .list { return try state.itemListJSON() }
        guard request.action.isBrowserAction || request.action == .open else {
            throw ChatWorkError.invalid("This experimental CLI supports browser actions only.")
        }
        let item = try state.browserItem(for: request)
        request.id = item.id
        let browser = pool.browser(for: item, sessionID: sessionID)
        browser.webView.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        browser.onNavigate = { [weak self] url in
            guard let self, let index = state.items.firstIndex(where: { $0.id == item.id }) else { return }
            state.items[index].url = url
        }
        if ProcessInfo.processInfo.environment["NATIV_BROWSER_VISIBLE"] == "1" {
            if window == nil {
                window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 800),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window?.title = "Chat Work browser experiment"
                window?.isReleasedWhenClosed = false
            }
            window?.contentView = browser.webView
            window?.makeKeyAndOrderFront(nil)
        }
        var snapshot = try await browser.execute(request)
        // Google can finish navigation before inserting results. Apply the same readiness
        // wait to both interfaces so the comparison does not reward an empty early snapshot.
        if browser.webView.url?.host?.contains("google.") == true, browser.webView.url?.path == "/search" {
            for _ in 0..<32 {
                let ready = try await browser.webView.callAsyncJavaScript(
                    "return [...document.querySelectorAll('a h3')].some(h => h.innerText.trim().length > 0);",
                    arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool ?? false
                if ready { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            snapshot = try await browser.execute(ChatWorkRequest(action: .inspect, id: item.id))
        }
        if input.name == "chat_work" {
            return ChatBrowsingBudget.bound(try json(snapshot), maximumBytes: maximumBytes)
        }
        guard var extracted = try await browser.webView.callAsyncJavaScript(
            ChatBrowserCommands.extractionScript, arguments: [:], in: nil, contentWorld: .defaultClient
        ) as? [String: Any] else { throw ChatWorkError.invalid("Could not read the rendered page.") }
        extracted["id"] = item.id.uuidString
        if input.name == "browser_search" {
            let rows = extracted["results"] as? [[String: Any]] ?? []
            guard !rows.isEmpty else {
                return try json(["ok": false, "error": "No search results could be extracted. The browser may require consent or a challenge.",
                                 "id": item.id.uuidString, "url": extracted["url"] ?? "", "source_kind": "search"])
            }
            var result: [String: Any] = ["ok": true, "source_kind": "search", "untrusted_page_content": true,
                                         "id": item.id.uuidString, "url": extracted["url"] ?? "", "results": rows]
            while try json(result).utf8.count > maximumBytes, let values = result["results"] as? [[String: Any]], values.count > 1 {
                result["results"] = Array(values.dropLast())
                result["truncated"] = true
            }
            return ChatBrowsingBudget.bound(try json(result), maximumBytes: maximumBytes)
        }
        let args = try JSONSerialization.jsonObject(with: arguments) as? [String: Any]
        return try ChatBrowserCommands.pageResult(extracted, offset: args?["offset"] as? Int ?? 0, maximumBytes: maximumBytes)
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
