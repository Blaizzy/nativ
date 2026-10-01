import SwiftUI
import WebKit

/// A presentation owns a snapshot so it cannot use a different tab or revision
/// if the selected work changes while the feedback sheet is being presented.
struct ChatWorkFeedback: Identifiable {
    let id = UUID()
    let item: ChatWorkItem
    let sessionID: UUID?
    let annotation: ChatWorkPageAnnotation?
    let selectedText: String

    func message(comment: String) -> String {
        var context = "Regarding \(item.title) (work item \(item.id), revision \(item.revision)):\n"
        if let annotation { context += annotation.context + "\n" }
        else if !selectedText.isEmpty { context += "Selected text:\n\(selectedText)\n\n" }
        return context + "Comment: \(comment)"
    }
}

struct ChatWorkFeedbackSheet: View {
    let target: ChatWorkFeedback
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var comment = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(target.annotation == nil ? "Discuss" : "Annotate") \(target.item.title)").font(.headline)
            if let annotation = target.annotation {
                Text(annotation.selector).font(.caption.monospaced()).textSelection(.enabled)
                if !annotation.text.isEmpty {
                    Text(annotation.text).font(.caption).lineLimit(5).foregroundStyle(.secondary)
                }
            } else if !target.selectedText.isEmpty {
                Text(target.selectedText).font(.caption.monospaced()).lineLimit(5).foregroundStyle(.secondary)
            }
            TextField("What would you like to change?", text: $comment, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(3...6)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to chat") { onSubmit(comment) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 440)
    }
}

struct ChatWorkPageAnnotation: Decodable, Equatable {
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
        .help(annotator.isActive ? "Cancel annotation" : "Select part of this page to discuss in chat")
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
