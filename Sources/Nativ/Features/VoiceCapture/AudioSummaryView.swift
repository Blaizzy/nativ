import SwiftUI

struct AudioSummaryView: View {
    let document: AudioSummaryDocument
    var legacyReferences: [AudioSummaryReference] = []
    var onOpenLegacy: (TimeInterval) -> Void = { _ in }
    let onOpenLink: (URL) -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1_020 && document.sections.count > 2
            ScrollViewReader { reader in
                HStack(alignment: .top, spacing: 0) {
                    if wide {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                Text("ON THIS PAGE")
                                    .font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(.tertiary)
                                ForEach(document.sections) { section in
                                    Button {
                                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                            reader.scrollTo("summary.section.\(section.id)", anchor: .top)
                                        }
                                    } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                                            Text(String(format: "%02d", section.id + 1)).monospacedDigit().foregroundStyle(.tertiary)
                                            Text(section.title ?? "Overview").multilineTextAlignment(.leading)
                                        }
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Jump to \(section.title ?? "Overview")")
                                }
                            }
                            .padding(.leading, 26).padding(.trailing, 20).padding(.top, 40)
                        }
                        .frame(width: 205)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            heading
                                .padding(.bottom, 38)
                            ForEach(document.sections) { section in
                                sectionView(section, compact: geometry.size.width < 620)
                                    .id("summary.section.\(section.id)")
                            }
                            if !legacyReferences.isEmpty {
                                Text("Referenced moments").font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 85), alignment: .leading)], alignment: .leading) {
                                    ForEach(legacyReferences) { reference in
                                        Button { onOpenLegacy(reference.seconds) } label: {
                                            Label(reference.label, systemImage: "waveform").monospacedDigit()
                                        }
                                        .buttonStyle(SummarySourceButtonStyle())
                                        .accessibilityLabel("Open transcript at \(reference.label)")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, geometry.size.width < 620 ? 22 : 40)
                        .padding(.top, 36).padding(.bottom, 48)
                        .frame(maxWidth: 800, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                Text("MEETING NOTES").tracking(1.5)
                Text("·").padding(.horizontal, 2)
                Text("\(document.sections.count) sections").textCase(nil)
            }
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(document.title)
                .font(.system(size: 30, weight: .semibold)).tracking(-0.6)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { people }
                VStack(alignment: .leading, spacing: 8) { people }
            }
        }
    }

    @ViewBuilder private var people: some View {
        ForEach(document.people) { person in
            Button { _ = onOpenLink(person.url) } label: {
                HStack(spacing: 7) {
                    Text(person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.13), in: Circle())
                    Text(person.name).font(.system(size: 12, weight: .medium))
                    Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .medium)).foregroundStyle(.tertiary)
                }
                .padding(.leading, 5).padding(.trailing, 10).padding(.vertical, 4)
                .background(Color.primary.opacity(0.035), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.primary.opacity(0.06)) }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).help("Read \(person.name)’s passages")
        }
    }

    private func sectionView(_ section: AudioSummaryDocument.Section, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            if let title = section.title {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(String(format: "%02d", section.id + 1))
                        .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary)
                    Text(title).font(.system(size: 20, weight: .semibold)).tracking(-0.3).textSelection(.enabled).accessibilityAddTraits(.isHeader)
                }
                .padding(.top, 6)
            }
            if !section.markdown.isEmpty {
                MarkdownRenderer(content: MathPreprocessor.preprocess(section.markdown), fontSize: 15, listItemSpacing: 14, onOpenLink: onOpenLink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !section.moments.isEmpty {
                AudioSummarySourceRow(moments: section.moments, compact: compact, onOpenLink: onOpenLink)
                    .padding(.top, 2)
            }
        }
        .padding(.bottom, 34)
    }
}

private struct AudioSummarySourceRow: View {
    let moments: [AudioSummaryDocument.Moment]
    let compact: Bool
    let onOpenLink: (URL) -> Bool
    @State private var showsSources = false

    var body: some View {
        HStack(spacing: 8) {
            Text("Sources").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            ForEach(moments.prefix(compact ? 1 : 2)) { moment in
                Button { _ = onOpenLink(moment.url) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform").foregroundStyle(Color.accentColor)
                        Text(moment.time).monospacedDigit()
                    }
                }
                .help("\(moment.speaker) · \(moment.excerpt)")
                .accessibilityLabel("Open \(moment.speaker) at \(moment.time)")
            }
            if moments.count > (compact ? 1 : 2) {
                Button { showsSources.toggle() } label: {
                    HStack(spacing: 5) {
                        Text("All \(moments.count) moments")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                }
                .popover(isPresented: $showsSources, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Source moments").font(.headline).padding(16)
                        Divider()
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(moments) { moment in
                                    Button {
                                        showsSources = false
                                        _ = onOpenLink(moment.url)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 7) {
                                            HStack {
                                                Text(moment.speaker.isEmpty ? "Transcript" : moment.speaker).fontWeight(.medium)
                                                Spacer()
                                                Text(moment.time).monospacedDigit().foregroundStyle(Color.accentColor)
                                                Image(systemName: "arrow.up.right").foregroundStyle(Color.accentColor)
                                            }
                                            .font(.system(size: 12))
                                            Text(moment.excerpt).font(.system(size: 12)).foregroundStyle(.secondary)
                                                .lineLimit(3).multilineTextAlignment(.leading)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(14).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    Divider().padding(.horizontal, 14)
                                }
                            }
                        }
                        .frame(maxHeight: 340)
                    }
                    .frame(width: 360)
                }
            }
        }
        .buttonStyle(SummarySourceButtonStyle())
    }
}

private struct SummarySourceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color.primary.opacity(configuration.isPressed ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.06)) }
    }
}

/// Presentation only. Saved notes and exports keep their original Markdown.
struct AudioSummaryDocument {
    struct Moment: Identifiable {
        let id: String
        let url: URL
        let time: String
        let seconds: TimeInterval
        let speaker: String
        let excerpt: String
    }
    struct Person: Identifiable {
        let id: Int
        let name: String
        let url: URL
    }
    struct Section: Identifiable {
        let id: Int
        let title: String?
        let markdown: String
        let moments: [Moment]
    }
    let title: String
    let sections: [Section]
    let people: [Person]

    init(record: AudioTranscriptionRecord, summary: String) {
        let sources = AudioSummarySources(record: record)
        let markdown = sources.renderedMarkdown(summary)
        let nodes = MarkdownParser.parse(markdown)
        let lines = markdown.components(separatedBy: "\n")
        // Reference definitions have no rendered AST node. Retain these gaps
        // when individual sections are rendered as independent documents.
        let coveredLines = Set(nodes.flatMap { max(1, $0.startLine)...max(1, $0.endLine) })
        let definitions = lines.enumerated().filter { !coveredLines.contains($0.offset + 1) }
            .map(\.element).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let titleNode = nodes.first.flatMap { $0.kind == "heading" && $0.level == 1 ? $0 : nil }
        title = titleNode.map(Self.plainText) ?? "Meeting notes"
        let diarization = record.diarization?.groupedByProfile
        people = (diarization?.speakerIDs ?? []).compactMap { speaker in
            guard let passage = sources.passages.first(where: { $0.turn.speakers.contains(speaker) }),
                  let url = URL(string: "nativ://recording/speaker/\(passage.id)?id=\(speaker)") else { return nil }
            return Person(id: speaker, name: diarization?.speakerName(speaker) ?? "Speaker \(speaker + 1)", url: url)
        }
        var groups: [(title: String?, nodes: [MarkdownNode])] = []
        for node in nodes where node.startLine != titleNode?.startLine {
            if node.kind == "heading", node.level <= 2 {
                groups.append((Self.plainText(node), []))
            } else {
                if groups.isEmpty { groups.append((nil, [])) }
                groups[groups.count - 1].nodes.append(node)
            }
        }
        sections = groups.enumerated().map { index, group in
            let links = group.nodes.flatMap(Self.links)
            var moments: [Moment] = []
            for link in links {
                guard let url = URL(string: link.destination), case .passage(let seconds) = sources.target(for: url),
                      let passage = sources.passages.first(where: { $0.url == link.destination }),
                      !moments.contains(where: { $0.id == passage.id }) else { continue }
                moments.append(Moment(id: passage.id, url: url, time: passage.label, seconds: seconds,
                    speaker: passage.turn.speakers.map { diarization?.speakerName($0) ?? "Speaker \($0 + 1)" }.joined(separator: " + "),
                    excerpt: passage.turn.text))
            }
            let validLinks = Set(links.compactMap { link -> String? in
                guard let url = URL(string: link.destination), sources.target(for: url) != nil else { return nil }
                return link.destination
            })
            var body = group.nodes.map { node in
                let first = max(0, node.startLine - 1), last = min(lines.count, node.endLine)
                guard first < last else { return "" }
                let source = lines[first..<last].joined(separator: "\n")
                // Code samples, tables and blockquotes retain their literal text.
                return ["paragraph", "list"].contains(node.kind) ? Self.cleanReferences(source, validLinks: validLinks) : source
            }.map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !definitions.isEmpty { body += "\n\n" + definitions }
            return Section(id: index, title: group.title, markdown: body, moments: moments.sorted { $0.seconds < $1.seconds })
        }
    }

    private static func plainText(_ node: MarkdownNode) -> String {
        ["softbreak", "linebreak"].contains(node.kind) ? " " : (node.children.isEmpty ? node.literal : node.children.map(plainText).joined())
    }

    private static func links(_ node: MarkdownNode) -> [MarkdownNode] {
        node.kind == "link" ? [node] : node.children.flatMap(links)
    }

    private static func cleanReferences(_ source: String, validLinks: Set<String>) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!!)\[((?:\\.|[^\]\\\n])*)\]\((nativ://[^\s)]+)\)"#) else { return source }
        return source.components(separatedBy: "\n").compactMap { line -> String? in
            let text = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: text.length))
                .filter { validLinks.contains(text.substring(with: $0.range(at: 2))) }
            guard !matches.isEmpty else { return line }
            let result = NSMutableString(string: line)
            let withoutLinks = NSMutableString(string: line)
            for match in matches.reversed() { withoutLinks.replaceCharacters(in: match.range, with: "") }
            let remainder = (withoutLinks as String).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "·,;")))
            if ["Sources:", "Source:", "References:", ""].contains(remainder) { return nil }
            // Move a trailing citation cluster into the source row, but preserve
            // an inline timestamp that is part of the sentence itself.
            var tailStart = text.length
            var trailing: [NSTextCheckingResult] = []
            let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "·,;"))
            for match in matches.reversed() {
                let after = NSMaxRange(match.range)
                guard text.substring(with: match.range(at: 2)).contains("/passage/"),
                      text.substring(with: NSRange(location: after, length: tailStart - after)).trimmingCharacters(in: separators).isEmpty else { break }
                trailing.append(match)
                tailStart = match.range.location
            }
            let prefix = text.substring(to: tailStart).trimmingCharacters(in: .whitespaces)
            let citationStarts = prefix.last.map { ".!?;".contains($0) } == true ? Set(trailing.map { $0.range.location }) : []
            for match in matches.reversed() {
                result.replaceCharacters(in: match.range, with: citationStarts.contains(match.range.location) ? "" : text.substring(with: match.range(at: 1)))
            }
            return (result as String).replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }
}

/// An explicit timestamp already present in a saved summary, not an inferred citation.
struct AudioSummaryReference: Equatable, Identifiable, Sendable {
    let seconds: TimeInterval
    let label: String

    var id: TimeInterval { seconds }

    /// Accepts bracketed elapsed times, including Markdown link labels. Two-part
    /// timestamps use total minutes, matching AudioDiarization's long recordings.
    static func references(in summary: String, duration: TimeInterval) -> [Self] {
        guard duration.isFinite, duration > 0,
              let pattern = try? NSRegularExpression(pattern: #"\[([0-9]+:[0-9]{2}(?::[0-9]{2})?)\]"#)
        else { return [] }

        let text = summary as NSString
        var seen = Set<TimeInterval>()
        return pattern.matches(in: summary, range: NSRange(location: 0, length: text.length)).compactMap { match in
            let label = text.substring(with: match.range(at: 1))
            let components = label.split(separator: ":")
            let fields = components.compactMap { Double($0) }
            guard fields.count == components.count,
                  fields.count == 2 || fields.count == 3,
                  let last = fields.last, last < 60,
                  fields.count != 3 || fields[1] < 60
            else { return nil }

            let seconds = fields.reduce(0) { $0 * 60 + $1 }
            guard seconds.isFinite, seconds <= duration, seen.insert(seconds).inserted else { return nil }
            return Self(seconds: seconds, label: label)
        }
    }
}
