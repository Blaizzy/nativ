import Combine
import Foundation
import SwiftUI
import WebKit

@MainActor
final class ChatWorkBrowserPool {
    private var browsers: [UUID: [UUID: ChatWorkBrowser]] = [:]

    func browser(for item: ChatWorkItem, sessionID: UUID) -> ChatWorkBrowser {
        if let browser = browsers[sessionID]?[item.id] {
            browser.load(item)
            return browser
        }
        let browser = ChatWorkBrowser()
        browsers[sessionID, default: [:]][item.id] = browser
        browser.load(item)
        return browser
    }

    func remove(sessionID: UUID) {
        browsers.removeValue(forKey: sessionID)?.values.forEach { $0.stop() }
    }

    func remove(itemID: UUID, sessionID: UUID) {
        browsers[sessionID]?.removeValue(forKey: itemID)?.stop()
    }

    func elementLabel(_ elementID: String, itemID: UUID, sessionID: UUID) -> String? {
        browsers[sessionID]?[itemID]?.elementLabels[elementID]
    }

    func itemID(for elementID: String, sessionID: UUID) -> UUID? {
        let matches = browsers[sessionID]?.filter { $0.value.elementLabels[elementID] != nil } ?? [:]
        return matches.count == 1 ? matches.keys.first : nil
    }
}

/// The pane and the agent use this exact WebKit instance, including its navigation state.
@MainActor
final class ChatWorkBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let annotator = ChatWorkAnnotator()
    @Published private(set) var address = ""
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var runtimeErrors: [String] = []
    @Published private(set) var localPageURL: URL?
    var onNavigate: ((String) -> Void)?
    private var loadedContent: String?
    private var loadedURL: String?
    private var modelURL: String?
    private var previewServer: ChatWorkPreviewServer?
    private var previewLoad: Task<Void, Never>?
    private var previewGeneration = UUID()
    private var isStartingPreview = false
    private var pendingNavigation: WKNavigation?
    private var observations: [NSKeyValueObservation] = []
    private(set) var elementLabels: [String: String] = [:]

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.diagnosticsScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Bare WKWebView identifies only AppleWebKit, which sites such as Gmail
        // mistake for an unsupported browser. Match the installed Safari version
        // while letting WebKit supply its own platform and engine identity.
        if let version = Bundle(path: "/Applications/Safari.app")?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           version.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil {
            // Safari's compatibility token is frozen, like WebKit's engine token.
            configuration.applicationNameForUserAgent = "Version/\(version) Safari/605.1.15"
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        annotator.attach(to: webView)
        configuration.userContentController.add(ChatWorkScriptErrors(browser: self), name: "nativWorkError")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.isLoading) { [weak self] _, _ in
                Task { @MainActor in self?.refreshNavigation() }
            },
            webView.observe(\.url) { [weak self] _, _ in
                Task { @MainActor in self?.refreshNavigation() }
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in
                Task { @MainActor in self?.refreshNavigation() }
            },
            webView.observe(\.canGoForward) { [weak self] _, _ in
                Task { @MainActor in self?.refreshNavigation() }
            }
        ]
    }

    func load(_ item: ChatWorkItem) {
        if let rawURL = item.url {
            guard modelURL != rawURL else { return }
            stopPreview()
            loadedContent = nil
            modelURL = rawURL
            do { try navigate(rawURL) } catch { errorMessage = error.localizedDescription }
        } else if loadedContent != item.content {
            annotator.cancel()
            loadedContent = item.content
            modelURL = nil
            errorMessage = nil
            runtimeErrors = []
            elementLabels = [:]
            previewLoad?.cancel()
            let generation = UUID()
            previewGeneration = generation
            do {
                let server = try previewServer ?? ChatWorkPreviewServer()
                previewServer = server
                server.update(item.content)
                isStartingPreview = true
                isLoading = true
                previewLoad = Task { @MainActor [weak self] in
                    do {
                        let url = try await server.start()
                        try Task.checkCancellation()
                        guard let self, self.previewGeneration == generation else { return }
                        self.localPageURL = url
                        self.isStartingPreview = false
                        self.loadedURL = url.absoluteString
                        self.pendingNavigation = self.webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
                    } catch {
                        guard let self, self.previewGeneration == generation else { return }
                        self.isStartingPreview = false
                        self.errorMessage = error.localizedDescription
                        self.refreshNavigation()
                    }
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func stopPreview() {
        previewLoad?.cancel()
        previewLoad = nil
        previewGeneration = UUID()
        isStartingPreview = false
        previewServer?.stop()
        previewServer = nil
        localPageURL = nil
    }

    func stop() {
        annotator.cancel()
        stopPreview()
        webView.stopLoading()
    }

    fileprivate func recordScriptError(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let text = message.body as? String,
              runtimeErrors.count < 20 else { return }
        let bounded = String(text.prefix(2_000))
        if !runtimeErrors.contains(bounded) { runtimeErrors.append(bounded) }
    }

    func navigate(_ rawURL: String) throws {
        let url = try ChatWorkState.webURL(rawURL)
        annotator.cancel()
        loadedURL = url.absoluteString
        errorMessage = nil
        elementLabels = [:]
        pendingNavigation = webView.load(URLRequest(url: url, timeoutInterval: 30))
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        let isWeb = (try? ChatWorkState.webURL(url.absoluteString)) != nil
        let isEmbeddedDocument = navigationAction.targetFrame?.isMainFrame == false
            && ["about", "data", "blob"].contains(scheme)
        let isPreviewDocument = loadedURL == nil && ["about", "data", "blob"].contains(scheme)
        return isWeb || isEmbeddedDocument || isPreviewDocument ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A user-activated target="_blank" link should open instead of disappearing.
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url,
           (try? ChatWorkState.webURL(url.absoluteString)) != nil {
            pendingNavigation = webView.load(navigationAction.request)
        }
        return nil
    }

    func textForTranslation() async throws -> String {
        try await waitForPage()
        let text = try await webView.callAsyncJavaScript("""
            const selected = window.getSelection()?.toString().trim();
            return selected || (document.querySelector('main,article') || document.body)?.innerText || '';
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        guard let text = text as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatWorkError.invalid("Select some text on the page to translate.")
        }
        return text
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if navigation === pendingNavigation { pendingNavigation = nil }
        if (error as NSError).code != NSURLErrorCancelled { errorMessage = error.localizedDescription }
        refreshNavigation()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        annotator.cancel()
        pendingNavigation = navigation
        runtimeErrors = []
        errorMessage = nil
        elementLabels = [:]
        refreshNavigation()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if navigation === pendingNavigation { pendingNavigation = nil }
        errorMessage = nil
        refreshNavigation()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        publishCommittedAddress()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation === pendingNavigation { pendingNavigation = nil }
        if (error as NSError).code != NSURLErrorCancelled { errorMessage = error.localizedDescription }
        refreshNavigation()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        annotator.cancel()
        pendingNavigation = nil
        errorMessage = "The page stopped responding. Reload to try again."
    }

    private func refreshNavigation() {
        address = webView.url?.absoluteString ?? loadedURL ?? ""
        // isLoading changes before WebKit replaces its old URL. Publishing that old URL
        // would save it back to the item and make SwiftUI load the previous page again.
        if pendingNavigation == nil && !webView.isLoading { publishCommittedAddress() }
        isLoading = isStartingPreview || webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func publishCommittedAddress() {
        // Generated source remains editable and persists without its temporary loopback URL.
        guard loadedContent == nil, loadedURL != nil, let url = webView.url?.absoluteString,
              (try? ChatWorkState.webURL(url)) != nil else { return }
        loadedURL = url
        guard modelURL != url else { return }
        modelURL = url
        onNavigate?(url)
    }

    func execute(_ request: ChatWorkRequest) async throws -> String {
        try Task.checkCancellation()
        switch request.action {
        case .navigate:
            guard let url = request.url else { throw ChatWorkError.invalid("navigate requires url.") }
            try navigate(url)
        case .back:
            guard webView.canGoBack else { throw ChatWorkError.invalid("This tab has no previous page.") }
            pendingNavigation = webView.goBack()
        case .forward:
            guard webView.canGoForward else { throw ChatWorkError.invalid("This tab has no next page.") }
            pendingNavigation = webView.goForward()
        case .reload:
            pendingNavigation = webView.reload()
        default: break
        }
        try await waitForPage()
        if request.action == .click || request.action == .type {
            guard let elementID = request.elementID else {
                throw ChatWorkError.invalid("Inspect the page, then supply an element_id.")
            }
            if request.action == .type && request.text == nil {
                throw ChatWorkError.invalid("type requires text.")
            }
            let result = try await webView.callAsyncJavaScript(Self.actionScript, arguments: [
                "elementID": elementID, "action": request.action.rawValue, "text": request.text ?? ""
            ], in: nil, contentWorld: .defaultClient)
            if let error = result as? String, !error.isEmpty { throw ChatWorkError.invalid(error) }
            // Let click/input event handlers and resulting navigations begin before observing again.
            try await Task.sleep(for: .milliseconds(150))
            try await waitForPage()
        }
        try Task.checkCancellation()
        guard let snapshot = try await webView.callAsyncJavaScript(
            Self.inspectScript, arguments: ["snapshotID": UUID().uuidString,
                                           "tabID": request.id?.uuidString ?? "",
                                           "canGoBack": webView.canGoBack,
                                           "canGoForward": webView.canGoForward], in: nil, contentWorld: .defaultClient
        ) as? String else { throw ChatWorkError.invalid("The page could not be inspected.") }
        guard var object = try JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as? [String: Any] else {
            throw ChatWorkError.invalid("The page could not be inspected.")
        }
        object["runtime_errors"] = runtimeErrors
        object["local_page_url"] = localPageURL?.absoluteString
        if let elements = object["elements"] as? [[String: Any]] {
            elementLabels = Dictionary(elements.compactMap { element in
                guard let id = element["id"] as? String, let label = element["label"] as? String else { return nil }
                return (id, label.isEmpty ? (element["tag"] as? String ?? "control") : label)
            }, uniquingKeysWith: { first, _ in first })
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func waitForPage() async throws {
        let deadline = Date().addingTimeInterval(20)
        while isStartingPreview || pendingNavigation != nil || webView.isLoading {
            try Task.checkCancellation()
            guard Date() < deadline else {
                throw ChatWorkError.invalid("The page is still loading. Inspect it again shortly.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let errorMessage { throw ChatWorkError.invalid(errorMessage) }
    }

    private static let diagnosticsScript = """
        (() => {
            let count = 0;
            const report = message => {
                if (count++ < 20) window.webkit.messageHandlers.nativWorkError.postMessage(String(message).slice(0, 2000));
            };
            window.addEventListener('error', event => {
                if (event.message) report(event.message + (event.lineno ? ' (line ' + event.lineno + ')' : ''));
            });
            window.addEventListener('unhandledrejection', event => {
                report('Unhandled promise rejection: ' + (event.reason?.message || event.reason));
            });
        })();
        """

    private static let inspectScript = """
        const visible = el => {
            const r = el.getBoundingClientRect(), s = getComputedStyle(el);
            return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
        };
        const token = snapshotID;
        const refs = new Map();
        const elements = [...document.querySelectorAll('a[href],button,input,textarea,select,[role="button"],[contenteditable="true"]')]
            .filter(visible).slice(0, 150).map((el, i) => {
                const id = token + ':' + i;
                const label = (el.getAttribute('aria-label') || el.labels?.[0]?.innerText || el.innerText
                    || el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('name') || '').slice(0, 180);
                refs.set(id, {el, label, value: el.value, type: el.getAttribute('type'), href: el.getAttribute('href')});
                const value = ['password','file','hidden'].includes(el.type) ? undefined : el.value;
                return {id, tag: el.tagName.toLowerCase(), type: el.getAttribute('type'), label, value,
                    href: el.getAttribute('href'), disabled: !!el.disabled};
            });
        globalThis.__nativWorkRefs = refs;
        return JSON.stringify({id: tabID, kind: 'website', url: location.href, title: document.title,
            can_go_back: canGoBack, can_go_forward: canGoForward, untrusted_page_content: true,
            text: (document.body?.innerText || '').slice(0, 18000), elements});
        """

    private static let actionScript = """
        const ref = globalThis.__nativWorkRefs?.get(elementID);
        if (!ref || !ref.el.isConnected) return 'The element is stale. Inspect the page again.';
        const el = ref.el;
        const label = (el.getAttribute('aria-label') || el.labels?.[0]?.innerText || el.innerText
            || el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('name') || '').slice(0, 180);
        const r = el.getBoundingClientRect(), s = getComputedStyle(el);
        if (el.disabled || !r.width || !r.height || s.visibility === 'hidden' || s.display === 'none'
            || label !== ref.label || el.value !== ref.value || el.getAttribute('type') !== ref.type || el.getAttribute('href') !== ref.href)
            return 'The element changed. Inspect the page again.';
        globalThis.__nativWorkRefs = null;
        el.scrollIntoView({block:'center'});
        if (action === 'click') { el.click(); return ''; }
        if (el instanceof HTMLInputElement && ['password','file','hidden'].includes(el.type))
            return 'This input must be filled by the user.';
        if (el.readOnly) return 'This input is read-only.';
        el.focus();
        if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement) {
            const prototype = el instanceof HTMLInputElement ? HTMLInputElement.prototype
                : el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLSelectElement.prototype;
            Object.getOwnPropertyDescriptor(prototype, 'value').set.call(el, text);
        } else if (el.isContentEditable) { el.textContent = text; }
        else return 'This element does not accept text.';
        el.dispatchEvent(new Event('input', {bubbles:true}));
        el.dispatchEvent(new Event('change', {bubbles:true}));
        return '';
        """
}

/// Web content can report bounded diagnostics only; it cannot invoke application actions.
@MainActor
private final class ChatWorkScriptErrors: NSObject, WKScriptMessageHandler {
    weak var browser: ChatWorkBrowser?
    init(browser: ChatWorkBrowser) { self.browser = browser }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        browser?.recordScriptError(message)
    }
}

struct ChatWorkWebView: NSViewRepresentable {
    let browser: ChatWorkBrowser

    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Address entry is separate from the web view, so every page has one compact toolbar.
struct ChatWorkAddressField: View {
    let address: String
    let onSubmit: (String) throws -> Void
    @State private var text = ""
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if !address.isEmpty {
                Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            TextField("Search or enter a URL", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)
                .onSubmit {
                    do {
                        try onSubmit(text)
                        errorMessage = nil
                        isFocused = false
                    } catch { errorMessage = error.localizedDescription }
                }
                .accessibilityLabel("Search or enter a URL")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.primary.opacity(isFocused ? 0.12 : 0.07), in: Capsule())
        .overlay { Capsule().strokeBorder(isFocused ? Color.primary.opacity(0.2) : .clear) }
        .onAppear { text = address }
        .onChange(of: address) { _, value in if !isFocused { text = value } }
        .onChange(of: isFocused) { _, focused in
            if !focused { text = address }
        }
        .alert("Could not open page", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

struct ChatWorkNavigationButtons: View {
    var canGoBack = false
    var canGoForward = false
    var canReload = false
    var isLoading = false
    var back: () -> Void = {}
    var forward: () -> Void = {}
    var reload: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            Button(action: back) { Image(systemName: "arrow.left").frame(width: 27, height: 30) }
                .disabled(!canGoBack).help("Back").accessibilityLabel("Back")
            Button(action: forward) { Image(systemName: "arrow.right").frame(width: 27, height: 30) }
                .disabled(!canGoForward).help("Forward").accessibilityLabel("Forward")
            Button(action: reload) {
                Image(systemName: isLoading ? "xmark" : "arrow.clockwise").frame(width: 27, height: 30)
            }
            .disabled(!canReload)
            .help(isLoading ? "Stop loading" : "Reload")
            .accessibilityLabel(isLoading ? "Stop loading" : "Reload")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

struct ChatWorkBrowserToolbar<PageActions: View>: View {
    @ObservedObject var browser: ChatWorkBrowser
    let isShowingSource: Bool
    let onAnnotate: (ChatWorkPageAnnotation) -> Void
    let onAnnotationError: (String) -> Void
    @ViewBuilder let pageActions: () -> PageActions

    var body: some View {
        HStack(spacing: 8) {
            ChatWorkNavigationButtons(
                canGoBack: browser.canGoBack, canGoForward: browser.canGoForward,
                canReload: true, isLoading: browser.isLoading,
                back: { browser.webView.goBack() }, forward: { browser.webView.goForward() },
                reload: { if browser.isLoading { browser.webView.stopLoading() } else { browser.webView.reload() } }
            )
            .disabled(isShowingSource)
            ChatWorkAnnotateButton(annotator: browser.annotator, onSelect: onAnnotate, onError: onAnnotationError)
                .disabled(browser.isLoading || isShowingSource)
                .fixedSize()
            ChatWorkAddressField(address: browser.address) { text in
                try browser.navigate(ChatWorkState.addressURL(text).absoluteString)
            }
            .disabled(isShowingSource)
            pageActions().fixedSize()
            if let url = browser.localPageURL {
                Button { try? browser.navigate(url.absoluteString) } label: {
                    Image(systemName: "house").frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .disabled(isShowingSource)
                .help("Open local webpage")
                .accessibilityLabel("Open local webpage")
            }
        }
        .padding(8)
    }
}

struct ChatWorkBrowserView: View {
    @ObservedObject var browser: ChatWorkBrowser

    var body: some View {
        VStack(spacing: 0) {
            if let error = browser.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(10)
            }
            if let error = browser.runtimeErrors.first {
                Text("JavaScript: \(error)").font(.caption).foregroundStyle(.orange)
                    .lineLimit(2).textSelection(.enabled).padding(10)
                    .help(browser.runtimeErrors.joined(separator: "\n"))
            }
            ChatWorkWebView(browser: browser)
                .overlay(alignment: .top) {
                    if browser.isLoading { ProgressView().controlSize(.small).padding(8) }
                }
        }
        .onDisappear { browser.annotator.cancel() }
    }
}
