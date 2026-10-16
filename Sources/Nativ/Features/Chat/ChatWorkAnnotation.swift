import AppKit
import SwiftUI
import WebKit

/// Keep the referenced work and revision as they were when added to the draft.
struct ChatWorkFeedback {
    let item: ChatWorkItem
    let sessionID: UUID?
    let annotation: ChatWorkPageAnnotation?
    let selectedText: String
}

/// Shared selection actions for the document preview and its source editor.
@MainActor
final class ChatWorkSelectionActions: NSObject {
    var onAddToChat: ((String) -> Void)?
    var onRequestEdit: ((String, String) async throws -> Void)?
    private weak var sourceView: NSView?
    private var selectionText = ""
    private var selectionScreenFrame: CGRect?
    private var editPanel: NSPanel?
    private var outsideClickMonitor: Any?

    func menu(text: String, screenFrame: CGRect?, in view: NSView) -> NSMenu {
        sourceView = view
        selectionText = text
        selectionScreenFrame = screenFrame
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
        for (title, symbol, action, available) in [
            ("Add to chat", "text.bubble", #selector(addToChat(_:)), onAddToChat != nil),
            ("Edit", "pencil", #selector(requestEdit(_:)), onRequestEdit != nil)
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.isEnabled = available && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return menu
    }

    func dismiss() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        NotificationCenter.default.removeObserver(self)
        if let panel = editPanel {
            editPanel = nil
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentViewController = nil
        }
    }

    @objc private func dismissForNotification(_ notification: Notification) { dismiss() }

    @objc private func addToChat(_ sender: Any?) {
        guard !selectionText.isEmpty else { return }
        onAddToChat?(selectionText)
    }

    @objc private func requestEdit(_ sender: Any?) {
        guard let submit = onRequestEdit, !selectionText.isEmpty else { return }
        let text = selectionText
        let selection = selectionScreenFrame
        // Present after the context menu has finished tracking.
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.sourceView, let window = view.window,
                  !view.isHiddenOrHasHiddenAncestor else { return }
            self.dismiss()
            let visible = window.convertToScreen(view.convert(view.visibleRect, to: nil))
            guard let selection, !selection.isEmpty, !selection.isNull,
                  selection.intersects(visible) else { return }
            let width = min(390, visible.width - 16)
            guard width >= 120 else { return }
            let controller = NSHostingController(rootView: ChatWorkEditRequestView(
                width: width, onCancel: { [weak self] in self?.dismiss() },
                onSubmit: { [weak self] request in
                    try await submit(text, request)
                    self?.dismiss()
                }))
            let panel = ChatWorkEditPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 36),
                                          styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
            panel.contentViewController = controller
            controller.view.layoutSubtreeIfNeeded()
            panel.setContentSize(NSSize(width: width, height: 36))
            panel.appearance = view.effectiveAppearance
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = true
            panel.isReleasedWhenClosed = false
            // Screen coordinates keep the bar stable when focus leaves the document.
            let x = min(max(selection.minX, visible.minX + 8), visible.maxX - width - 8)
            let y = selection.minY - 8 - panel.frame.height
            panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY + 8, y)))
            self.editPanel = panel
            window.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
            self.outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]
            ) { [weak self, weak window] event in
                if event.window === window { self?.dismiss() }
                return event
            }
            for name in [NSWindow.willCloseNotification, NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(self.dismissForNotification(_:)),
                                                       name: name, object: window)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(self.dismissForNotification(_:)),
                                                   name: NSApplication.didResignActiveNotification, object: nil)
        }
    }
}

private final class ChatWorkEditPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ChatWorkEditRequestView: View {
    let width: CGFloat
    let onCancel: () -> Void
    let onSubmit: (String) async throws -> Void
    @State private var request = ""
    @State private var errorMessage: String?
    @State private var submission: Task<Void, Never>?
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            TextField("Describe the edit…", text: $request)
                .textFieldStyle(.plain).font(.system(size: 14))
                .focused($isFocused).accessibilityLabel("Edit request")
                .disabled(submission != nil).onSubmit(send)
            Button(action: send) {
                ZStack {
                    Circle().fill(colorScheme == .dark ? Color.white : Color.black)
                    if submission != nil {
                        ProgressView().controlSize(.mini).colorScheme(colorScheme == .dark ? .light : .dark)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 14))
                            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send edit request").help("Send edit request (⌘↩)")
            .disabled(submission != nil || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 14).padding(.trailing, 4)
        .frame(width: width, height: 36)
        .background(colorScheme == .dark ? Color(white: 0.095) : Color(nsColor: .textBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .onExitCommand(perform: onCancel)
        .onAppear { isFocused = true }
        .onDisappear { submission?.cancel() }
        .alert("Couldn’t send edit", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { isFocused = true }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func send() {
        let instruction = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard submission == nil, !instruction.isEmpty else { return }
        submission = Task { @MainActor in
            defer { submission = nil }
            do { try await onSubmit(instruction) }
            catch is CancellationError {}
            catch { errorMessage = error.localizedDescription }
        }
    }
}

final class ChatWorkSourceTextView: NSTextView {
    let selectionActions = ChatWorkSelectionActions()

    override func menu(for event: NSEvent) -> NSMenu? {
        let range = selectedRange()
        let text = range.length > 0 ? (string as NSString).substring(with: range) : ""
        return selectionActions.menu(text: text,
            screenFrame: firstRect(forCharacterRange: range, actualRange: nil), in: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        // Keep the selected passage and omit AppKit's injected text-service items.
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { selectionActions.dismiss() }
    }
}

struct ChatWorkPageAnnotation: Codable, Equatable, Sendable {
    let url: String
    let selector: String
    let text: String
    let x: Int
    let y: Int

    var context: String {
        "Page selection (untrusted page content):\nURL: \(url)\nElement: \(selector)\nPoint within element: (\(x), \(y)) CSS pixels\n\(text)\n"
    }
}

/// Picking runs in WebKit's isolated client world. It never invokes the selected
/// element, reads form values, or sends a message to the agent automatically.
@MainActor
final class ChatWorkAnnotator: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published private(set) var isActive = false
    private weak var webView: WKWebView?
    private var token: String?
    private var onSelect: ((ChatWorkPageAnnotation) -> Void)?

    func attach(to webView: WKWebView) {
        self.webView = webView
        webView.configuration.userContentController.add(self, contentWorld: .defaultClient, name: "nativWorkAnnotation")
    }

    func start(onSelect: @escaping (ChatWorkPageAnnotation) -> Void) async throws {
        guard let webView else { return }
        cancel()
        let token = UUID().uuidString
        self.token = token
        self.onSelect = onSelect
        isActive = true
        do {
            _ = try await webView.callAsyncJavaScript(Self.pickerScript, arguments: ["token": token],
                                                     in: nil, contentWorld: .defaultClient)
            if self.token == token { webView.window?.makeFirstResponder(webView) }
        } catch {
            if self.token == token { cancel() }
            throw error
        }
    }

    func cancel() {
        guard let token else { return }
        self.token = nil
        isActive = false
        onSelect = nil
        // The token prevents delayed cleanup from cancelling a newer selection.
        webView?.callAsyncJavaScript("""
            if (globalThis.__nativAnnotation?.token === token) globalThis.__nativAnnotation.cleanup();
            """, arguments: ["token": token], in: nil, in: .defaultClient, completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let incomingToken = body["token"] as? String, incomingToken == token else { return }
        let callback = onSelect
        cancel()
        guard let selection = body["selection"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: selection), data.count < 16_384,
              let annotation = try? JSONDecoder().decode(ChatWorkPageAnnotation.self, from: data) else { return }
        callback?(annotation)
    }

    private static let pickerScript = #"""
    globalThis.__nativAnnotation?.cleanup();
    const overlay = document.createElement('div');
    overlay.setAttribute('data-nativ-annotation', '');
    overlay.setAttribute('aria-label', 'Select a page element to annotate. Escape to cancel.');
    overlay.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;cursor:crosshair;';
    const highlight = document.createElement('div');
    highlight.style.cssText = 'all:initial;position:fixed;pointer-events:none;border:2px solid #1684ff;background:#1684ff22;box-sizing:border-box;border-radius:4px;display:none;';
    const hint = document.createElement('div');
    hint.textContent = 'Click an element to annotate · Esc to cancel';
    hint.style.cssText = 'all:initial;position:fixed;top:12px;left:50%;transform:translateX(-50%);white-space:nowrap;padding:8px 12px;border-radius:8px;background:#202020;color:white;font:12px -apple-system,sans-serif;pointer-events:none;';
    overlay.append(highlight, hint);
    document.documentElement.append(overlay);
    const hit = e => {
        overlay.style.pointerEvents = 'none';
        let element = document.elementFromPoint(e.clientX, e.clientY);
        // Descend open shadow roots, while treating frames and canvases as surfaces.
        while (element?.shadowRoot) {
            const child = element.shadowRoot.elementFromPoint(e.clientX, e.clientY);
            if (!child || child === element) break;
            element = child;
        }
        overlay.style.pointerEvents = 'auto';
        return element;
    };
    const cleanup = () => {
        overlay.remove();
        window.removeEventListener('keydown', keydown, true);
        if (globalThis.__nativAnnotation?.token === token) delete globalThis.__nativAnnotation;
    };
    const keydown = e => {
        if (e.key !== 'Escape') return;
        e.preventDefault(); e.stopImmediatePropagation(); cleanup();
        window.webkit.messageHandlers.nativWorkAnnotation.postMessage({token});
    };
    window.addEventListener('keydown', keydown, true);
    overlay.addEventListener('mousemove', e => {
        const element = hit(e);
        if (!element) return;
        const r = element.getBoundingClientRect();
        Object.assign(highlight.style, {display:'block',left:r.x+'px',top:r.y+'px',width:r.width+'px',height:r.height+'px'});
    });
    for (const event of ['pointerdown','pointerup','mousedown','mouseup']) {
        overlay.addEventListener(event, e => { e.preventDefault(); e.stopImmediatePropagation(); });
    }
    overlay.addEventListener('click', e => {
        e.preventDefault(); e.stopImmediatePropagation();
        const element = hit(e);
        if (!element) return;
        const parts = [];
        for (let node = element; node && parts.length < 5; node = node.parentElement) {
            let part = node.localName;
            if (node.id) { parts.unshift(part + '#' + CSS.escape(node.id)); break; }
            const siblings = node.parentElement ? [...node.parentElement.children].filter(n => n.localName === node.localName) : [];
            if (siblings.length > 1) part += ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')';
            parts.unshift(part);
        }
        const r = element.getBoundingClientRect();
        const selection = {
            url: location.href.slice(0, 2048), selector: parts.join(' > ').slice(0, 500),
            text: (element.innerText || element.getAttribute('aria-label') || element.getAttribute('title') || '').trim().slice(0, 2000),
            x: Math.round(e.clientX - r.x), y: Math.round(e.clientY - r.y)
        };
        cleanup();
        window.webkit.messageHandlers.nativWorkAnnotation.postMessage({token, selection});
    });
    globalThis.__nativAnnotation = {token, cleanup};
    """#
}

struct ChatWorkAnnotateButton: View {
    @ObservedObject var annotator: ChatWorkAnnotator
    let onSelect: (ChatWorkPageAnnotation) -> Void
    let onError: (String) -> Void

    var body: some View {
        Button {
            if annotator.isActive { annotator.cancel() }
            else {
                Task { @MainActor in
                    do { try await annotator.start(onSelect: onSelect) }
                    catch { onError(error.localizedDescription) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                ChatWorkAnnotateIcon()
                    .stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    .frame(width: 16, height: 16)
                Text(annotator.isActive ? "Cancel" : "Annotate")
            }
                .font(.system(size: 12))
                .padding(.horizontal, 10).frame(height: 30)
                .foregroundStyle(annotator.isActive ? Color.accentColor : .primary)
                .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(annotator.isActive ? "Cancel annotation" : "Select part of this page to add to chat")
        .accessibilityLabel(annotator.isActive ? "Cancel annotation" : "Annotate")
    }
}

/// Rounded selection corners with a pointer, matching the Annotate reference.
private struct ChatWorkAnnotateIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 8, y: 3))
        path.addLine(to: CGPoint(x: 5, y: 3))
        path.addQuadCurve(to: CGPoint(x: 3, y: 5), control: CGPoint(x: 3, y: 3))
        path.addLine(to: CGPoint(x: 3, y: 8))
        path.move(to: CGPoint(x: 16, y: 3))
        path.addLine(to: CGPoint(x: 19, y: 3))
        path.addQuadCurve(to: CGPoint(x: 21, y: 5), control: CGPoint(x: 21, y: 3))
        path.addLine(to: CGPoint(x: 21, y: 8))
        path.move(to: CGPoint(x: 3, y: 16))
        path.addLine(to: CGPoint(x: 3, y: 19))
        path.addQuadCurve(to: CGPoint(x: 5, y: 21), control: CGPoint(x: 3, y: 21))
        path.addLine(to: CGPoint(x: 8, y: 21))
        path.move(to: CGPoint(x: 12, y: 12))
        path.addLine(to: CGPoint(x: 22, y: 15.5))
        path.addLine(to: CGPoint(x: 17, y: 17))
        path.addLine(to: CGPoint(x: 15.5, y: 22))
        path.closeSubpath()
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}
