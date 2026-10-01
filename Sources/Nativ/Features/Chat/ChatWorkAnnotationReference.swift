import Foundation
import SwiftUI

struct ChatWorkAnnotationReference: Codable, Equatable, Sendable {
    let itemID: UUID
    let title: String
    let revision: Int
    let selection: ChatWorkPageAnnotation

    var context: String {
        "Regarding \(title) (work item \(itemID), revision \(revision)):\n" + selection.context
    }

    var pageLabel: String {
        guard let host = URL(string: selection.url)?.host else { return "Webpage" }
        return ["127.0.0.1", "localhost", "::1"].contains(host) ? "Local webpage" : host
    }

    func annotation(id: UUID = UUID()) -> ChatAnnotation {
        ChatAnnotation(id: id, sourceMessageID: nil, sourceRole: "work",
                       selectionLocation: 0, selectionLength: 0, quote: selection.text, workReference: self)
    }
}

struct ChatWorkAnnotationPresentation {
    let content: String
    let annotations: [ChatAnnotation]

    // Older work-pane annotations were embedded in the visible prompt. Render
    // those with the same chip without rewriting stored messages or model input.
    static func legacy(_ text: String, id: UUID) -> Self? {
        guard text.hasPrefix("Regarding "),
              let match = legacyPattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String { (text as NSString).substring(with: match.range(at: index)) }
        guard let itemID = UUID(uuidString: group(2)), let revision = Int(group(3)),
              let x = Int(group(6)), let y = Int(group(7)),
              let url = URL(string: group(4)), let scheme = url.scheme,
              ["http", "https"].contains(scheme) else { return nil }
        let selection = ChatWorkPageAnnotation(url: group(4), selector: group(5),
                                              text: group(8).trimmingCharacters(in: .whitespacesAndNewlines), x: x, y: y)
        let reference = ChatWorkAnnotationReference(itemID: itemID, title: group(1), revision: revision, selection: selection)
        return Self(content: group(9), annotations: [reference.annotation(id: id)])
    }

    private static let legacyPattern = try? NSRegularExpression(pattern:
        #"\ARegarding ([^\n]+) \(work item ([0-9A-Fa-f-]{36}), revision ([0-9]+)\):\nPage selection \(untrusted page content\):\nURL: ([^\n]+)\nElement: ([^\n]+)\nPoint within element: \((-?[0-9]+), (-?[0-9]+)\) CSS pixels\n([\s\S]*?)\n\nComment: ([\s\S]+)\z"#)
}

extension ChatTranscriptMessage {
    var annotationPresentation: ChatWorkAnnotationPresentation {
        if role == .user, annotations.isEmpty, pastedTexts.isEmpty,
           let legacy = ChatWorkAnnotationPresentation.legacy(content, id: id) { return legacy }
        return ChatWorkAnnotationPresentation(content: content, annotations: annotations)
    }
}

struct ChatWorkAnnotationChip: View {
    let annotations: [ChatAnnotation]
    var allowsRemoval = false
    @Environment(\.chatAnnotationActions) private var actions
    @State private var showsDetails = false

    private var label: String { "\(annotations.count) annotation\(annotations.count == 1 ? "" : "s")" }

    var body: some View {
        Button { showsDetails.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "text.bubble").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(label).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("View annotation details")
        .accessibilityLabel(label)
        .popover(isPresented: $showsDetails) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(label).font(.headline)
                    Spacer()
                    Button("Close", systemImage: "xmark") { showsDetails = false }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(annotations) { annotation in
                            if let reference = annotation.workReference {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(reference.title).font(.callout.weight(.semibold))
                                            Text(reference.pageLabel).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if allowsRemoval, let actions {
                                            Button("Remove annotation", systemImage: "xmark") {
                                                actions.remove(annotation.id)
                                                if annotations.count == 1 { showsDetails = false }
                                            }
                                            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(reference.selection.selector).font(.caption.monospaced())
                                        .foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                                    if !reference.selection.text.isEmpty {
                                        Text(verbatim: reference.selection.text).font(.callout)
                                            .lineLimit(5).textSelection(.enabled)
                                    }
                                    DisclosureGroup("Details") {
                                        Text(verbatim: reference.context).font(.caption.monospaced())
                                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.top, 6)
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                if annotation.id != annotations.last?.id { Divider() }
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(width: 340)
        }
    }
}
