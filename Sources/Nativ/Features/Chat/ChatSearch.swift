import AppKit
import NaturalLanguage
import Observation
import QuartzCore
import SwiftUI

struct ChatSearchInput: Equatable, Sendable {
    let messageID: UUID
    let rowID: UUID
    let text: String
    let markdown: Bool

    static func snapshots(from items: [ChatTranscriptItem]) -> [Self] {
        items.compactMap { item in
            let message: ChatTranscriptMessage
            switch item {
            case .message(let value): message = value
            case .agentTurn(let turn):
                guard let value = turn.finalAssistantMessage else { return nil }
                message = value
            }
            guard message.role == .user || message.role == .assistant,
                  !message.content.isEmpty else { return nil }
            return Self(messageID: message.id, rowID: item.id, text: message.content,
                        markdown: message.role == .assistant)
        }
    }
}

struct ChatSearchOccurrence: Equatable, Sendable {
    struct Fragment: Equatable, Sendable {
        let id: String
        let text: String
        let range: NSRange
    }

    struct Location: Equatable {
        let messageID: UUID
        let fragmentID: String
        let range: NSRange
    }

    let messageID: UUID
    let rowID: UUID
    let fragment: Fragment
    let continuations: [Fragment]
    var fragmentID: String { fragment.id }
    var text: String { fragment.text }
    var range: NSRange { fragment.range }
    var fragments: [Fragment] { [fragment] + continuations }
    var location: Location { Location(messageID: messageID, fragmentID: fragmentID, range: range) }
}

enum ChatSearchDocument {
    struct Fragment: Equatable, Sendable {
        let id: String
        let text: String
    }

    static func fragments(for input: ChatSearchInput) -> [Fragment] {
        guard input.markdown else { return [Fragment(id: "plain/text", text: input.text)] }
        return blocks(MarkdownParser.parse(MathPreprocessor.preprocess(input.text)), path: "root")
    }

    private static func blocks(_ nodes: [MarkdownNode], path: String) -> [Fragment] {
        nodes.enumerated().flatMap { index, node -> [Fragment] in
            let id = "\(path).\(index)"
            switch node.kind {
            case "list":
                return node.children.enumerated().flatMap { offset, item in
                    blocks(item.children, path: "\(id).\(offset)")
                }
            case "block_quote": return blocks(node.children, path: id)
            case "table":
                return node.children.enumerated().flatMap { row, value in
                    value.children.enumerated().map { column, cell in
                        Fragment(id: "\(id)/\(row).\(column)", text: inline(cell.children))
                    }
                }
            case "thematic_break": return []
            case "code_block":
                let text = node.literal.hasSuffix("\n") ? String(node.literal.dropLast()) : node.literal
                return [Fragment(id: id + "/text", text: text)]
            case "paragraph", "heading", "html_block":
                return [Fragment(id: id + "/text", text: node.children.isEmpty ? node.literal : inline(node.children))]
            default:
                return node.children.isEmpty
                    ? [Fragment(id: id + "/text", text: node.literal)]
                    : blocks(node.children, path: id)
            }
        }
    }

    private static func inline(_ nodes: [MarkdownNode]) -> String {
        nodes.map { node in
            switch node.kind {
            case "softbreak": return " "
            case "linebreak": return "\n"
            case "image":
                if URL(string: node.destination)?.scheme == "swiftmath" { return "\u{FFFC}" }
                let label = inline(node.children)
                return label.isEmpty ? node.destination : label
            case "html_inline":
                return node.literal.range(of: #"^<br\s*/?>$"#, options: [.regularExpression, .caseInsensitive]) != nil
                    ? "\n" : node.literal
            default: return node.children.isEmpty ? node.literal : inline(node.children)
            }
        }.joined()
    }
}

actor ChatSearchWorker {
    struct Result: Sendable {
        let occurrences: [ChatSearchOccurrence]
        let hasMore: Bool
    }

    private struct Entry {
        let input: ChatSearchInput
        let fragments: [(ChatSearchDocument.Fragment, NSRange)]
        let message: ChatTextSearch.Message
        let language: NLLanguage?
    }

    private var entries: [UUID: Entry] = [:]

    func search(_ query: String, inputs: [ChatSearchInput], limit: Int = 10_000) throws -> Result {
        try Task.checkCancellation()
        guard limit > 0 else { return Result(occurrences: [], hasMore: false) }
        let limit = min(limit, 10_000)
        let ids = Set(inputs.map(\.messageID))
        entries = entries.filter { ids.contains($0.key) }
        var queries: [String: ChatTextSearch.Query] = [:]
        var results: [ChatSearchOccurrence] = []
        for input in inputs {
            try Task.checkCancellation()
            let entry: Entry
            if let cached = entries[input.messageID], cached.input == input {
                entry = cached
            } else {
                let fragments = ChatSearchDocument.fragments(for: input)
                let text = fragments.map(\.text).joined(separator: "\n\n")
                let language = NLLanguageRecognizer.dominantLanguage(for: text)
                var offset = 0
                let positioned = fragments.map { fragment in
                    let range = NSRange(location: offset, length: fragment.text.utf16.count)
                    offset = NSMaxRange(range) + 2
                    return (fragment, range)
                }
                entry = Entry(input: input, fragments: positioned,
                              message: try ChatTextSearch.Message(id: input.messageID, text: text, language: language),
                              language: language)
                entries[input.messageID] = entry
            }
            let languageKey = entry.language?.rawValue ?? ""
            let preparedQuery: ChatTextSearch.Query
            if let cached = queries[languageKey] { preparedQuery = cached }
            else {
                preparedQuery = try ChatTextSearch.Query(query, language: entry.language)
                queries[languageKey] = preparedQuery
            }
            let matches = try ChatTextSearch.matches(in: entry.message, query: preparedQuery,
                                                    limit: max(1, limit + 1 - results.count))
            var firstFragment = 0
            for match in matches {
                while firstFragment < entry.fragments.count,
                      NSMaxRange(entry.fragments[firstFragment].1) <= match.range.location { firstFragment += 1 }
                var parts: [ChatSearchOccurrence.Fragment] = []
                for (fragment, range) in entry.fragments.dropFirst(firstFragment) {
                    if range.location >= NSMaxRange(match.range) { break }
                    let intersection = NSIntersectionRange(range, match.range)
                    if intersection.length > 0 {
                        parts.append(.init(id: fragment.id, text: fragment.text,
                                           range: NSRange(location: intersection.location - range.location,
                                                          length: intersection.length)))
                    }
                }
                guard let first = parts.first else { continue }
                results.append(ChatSearchOccurrence(messageID: input.messageID, rowID: input.rowID,
                                                    fragment: first, continuations: Array(parts.dropFirst())))
                if results.count > limit {
                    return Result(occurrences: Array(results.prefix(limit)), hasMore: true)
                }
            }
        }
        return Result(occurrences: results, hasMore: false)
    }
}

struct ChatSearchNavigationRequest: Equatable {
    let id: UUID
    let rowID: UUID
}

@MainActor @Observable
final class ChatSearchState {
    var query = ""
    private(set) var isPresented = false
    private(set) var focusID = UUID()
    private(set) var occurrences: [ChatSearchOccurrence] = []
    private(set) var selectedIndex = 0
    private(set) var isSearching = false
    private(set) var hasMore = false
    private(set) var error: String?
    private(set) var navigationID = UUID()
    private(set) var revealID: UUID?
    private var matchesByMessage: [UUID: [ChatSearchOccurrence]] = [:]
    @ObservationIgnored private var worker = ChatSearchWorker()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var inputs: [ChatSearchInput] = []
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var revision = 0

    var selected: ChatSearchOccurrence? {
        occurrences.indices.contains(selectedIndex) ? occurrences[selectedIndex] : nil
    }

    var navigationRequest: ChatSearchNavigationRequest? {
        guard let selected else { return nil }
        return ChatSearchNavigationRequest(id: navigationID, rowID: selected.rowID)
    }

    var countLabel: String {
        if error != nil { return "Unavailable" }
        if isSearching && occurrences.isEmpty { return "Searching…" }
        guard !occurrences.isEmpty else { return "No matches" }
        return "\(selectedIndex + 1)/\(occurrences.count)\(hasMore ? "+" : "")"
    }

    func present() {
        isPresented = true
        focusID = UUID()
    }

    func dismiss() {
        reset(sessionID: sessionID)
    }

    func reset(sessionID: UUID?) {
        self.sessionID = sessionID
        isPresented = false
        clear()
    }

    private func clear() {
        stop()
        query = ""
        inputs = []
        occurrences = []
        matchesByMessage = [:]
        selectedIndex = 0
        hasMore = false
        error = nil
        revealID = nil
        worker = ChatSearchWorker()
    }

    func update(items: [ChatTranscriptItem], queryChanged: Bool = false) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clear()
            return
        }
        inputs = ChatSearchInput.snapshots(from: items)
        revision &+= 1
        if queryChanged {
            stop()
            occurrences = []
            matchesByMessage = [:]
            selectedIndex = 0
            revealID = nil
        }
        schedule()
    }

    func move(_ offset: Int) {
        guard !occurrences.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + occurrences.count) % occurrences.count
        revealID = nil
        navigationID = UUID()
    }

    func finishNavigation(_ id: UUID) {
        guard id == navigationID, selected != nil, revealID == nil else { return }
        revealID = id
    }

    func highlight(for messageID: UUID) -> ChatSearchHighlight? {
        guard let matches = matchesByMessage[messageID] else { return nil }
        return ChatSearchHighlight(matches: matches, selected: selected?.messageID == messageID ? selected : nil,
                                   revealID: revealID)
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        isSearching = false
    }

    private func schedule() {
        guard task == nil else { return }
        isSearching = true
        error = nil
        let generation = generation
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard let self, self.generation == generation else { return }
                let revision = self.revision
                let previous = self.selected
                let result = try await self.worker.search(self.query, inputs: self.inputs)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                self.occurrences = result.occurrences
                self.matchesByMessage = Dictionary(grouping: result.occurrences, by: \.messageID)
                self.hasMore = result.hasMore
                self.selectedIndex = previous.flatMap { previous in
                    self.occurrences.firstIndex { $0.location == previous.location }
                } ?? 0
                if previous?.location != self.selected?.location {
                    self.revealID = nil
                    self.navigationID = UUID()
                }
                self.task = nil
                self.isSearching = false
                // Streaming updates are throttled, not endlessly postponed by a trailing debounce.
                if self.revision != revision { self.schedule() }
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == generation else { return }
                self.error = "Search is unavailable. Try again."
                self.task = nil
                self.isSearching = false
            }
        }
    }
}

extension FocusedValues {
    @Entry var chatSearch: ChatSearchState?
}

struct ChatSearchCommands: Commands {
    @FocusedValue(\.chatSearch) private var search

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find in Chat…") { search?.present() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(search == nil)
        }
    }
}

struct ChatSearchBar: View {
    @Bindable var search: ChatSearchState
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button("Find in chat", systemImage: "magnifyingglass") { search.present() }
                .help("Find in chat (⌘F)")
            TextField("Find in chat", text: $search.query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { search.move(1) }
                .onExitCommand { search.dismiss() }
                .accessibilityLabel("Find in this chat")
                .frame(minWidth: 100, idealWidth: 220)
            if !search.query.isEmpty {
                Text(search.countLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Search results: \(search.countLabel)")
                Button("Previous match", systemImage: "chevron.up") { search.move(-1) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(search.occurrences.isEmpty)
                    .help("Previous match (⇧⌘G)")
                Button("Next match", systemImage: "chevron.down") { search.move(1) }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(search.occurrences.isEmpty)
                    .help("Next match (⌘G)")
            }
            Button("Close search", systemImage: "xmark.circle.fill") { search.dismiss() }
                .help("Close search (Esc)")
        }
        .task(id: search.focusID) { isFocused = true }
        .font(.body)
        .buttonStyle(.plain)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 38)
        .frame(maxWidth: search.query.isEmpty ? 340 : 420)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.35), lineWidth: 1) }
        .help(search.error ?? "Search this conversation by words or phrases")
    }
}

struct ChatSearchHighlight: Equatable {
    let matches: [ChatSearchOccurrence]
    let selected: ChatSearchOccurrence?
    let revealID: UUID?

}

extension EnvironmentValues {
    @Entry var chatSearchState: ChatSearchState? = nil
    @Entry var chatSearchHighlight: ChatSearchHighlight? = nil
}

@MainActor
extension MarkdownSurface {
    func setSearchHighlight(_ value: ChatSearchHighlight?) {
        guard searchHighlight != value else { return }
        if value?.revealID != nil, value?.revealID != searchHighlight?.revealID, value?.selected != nil {
            pendingSearchReveal = true
        }
        searchHighlight = value
        if value?.selected == nil || value?.revealID == nil { pendingSearchReveal = false }
        if value == nil {
            for view in visibleTextViews { view.searchRanges = []; view.activeSearchRange = nil }
        }
        applySearchHighlights()
        needsLayout = true
    }

    func applySearchHighlights() {
        guard let searchHighlight else { return }
        let fragments = Dictionary(grouping: searchHighlight.matches.flatMap(\.fragments), by: \.id)
        for view in visibleTextViews {
            let matches = fragments[view.fragmentID]?.filter { $0.text == view.string } ?? []
            view.searchRanges = matches.map(\.range)
            view.activeSearchRange = searchHighlight.selected?.fragments.first {
                $0.id == view.fragmentID && $0.text == view.string
            }?.range
        }
    }

    func revealSearchMatchIfNeeded() {
        guard pendingSearchReveal, window != nil, let selected = searchHighlight?.selected,
              let snapshot, let scroll = enclosingScrollView else { return }
        var target: CGRect?
        var fragmentTargets: [(id: String, rect: CGRect)] = []
        for block in snapshot.blocks {
            for fragment in block.text {
                let id = block.id + "/" + fragment.id
                guard let match = selected.fragments.first(where: { $0.id == id && $0.text == fragment.text.string }) else { continue }
                let system = visibleTextViews.first { $0.fragmentID == id }?.system
                    ?? MarkdownTextSystem(fragment.text, width: fragment.frame.width)
                guard let start = system.storage.location(system.storage.documentRange.location, offsetBy: match.range.location),
                      let end = system.storage.location(start, offsetBy: match.range.length),
                      let range = NSTextRange(location: start, end: end) else { return }
                system.manager.ensureLayout(for: system.storage.documentRange)
                var local: CGRect?
                system.manager.enumerateTextSegments(in: range, type: .selection, options: []) { _, rect, _, _ in
                    local = local.map { $0.union(rect) } ?? rect
                    return true
                }
                guard let local else { return }
                fragmentTargets.append((id, local))
                let rect = local.offsetBy(dx: block.frame.minX + fragment.frame.minX,
                                          dy: block.frame.minY + fragment.frame.minY)
                target = target.map { $0.union(rect) } ?? rect
            }
        }
        guard let target else { return }
        pendingSearchReveal = false
        scrollToVisible(target)
        refreshVisibleBlocks()
        for fragment in fragmentTargets {
            visibleTextViews.first { $0.fragmentID == fragment.id }?.scrollToVisible(fragment.rect)
        }
        // Finish with the outer transcript's position, including when a code block
        // has its own horizontal scroller or the finding was already visible.
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin.y = convert(target, to: clip).midY - bounds.height / 2
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
        refreshVisibleBlocks()
        for view in visibleTextViews where view.activeSearchRange != nil {
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { view.wantsLayer = true }
            view.pendingSearchPulse = true
            view.needsDisplay = true
        }
    }

    static func searchPlainTextLayout(_ text: String, width: CGFloat, style: MarkdownStyle) -> MarkdownLayout {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: style.fontSize), .foregroundColor: style.foreground,
            .paragraphStyle: paragraph,
        ])
        let compact = text.count <= 72 && !text.contains(where: \.isNewline)
        let width = compact ? min(width, MarkdownTextSystem(attributed, width: .greatestFiniteMagnitude).measure().width) : width
        let size = MarkdownTextSystem(attributed, width: width).measure()
        let frame = CGRect(x: 0, y: 0, width: width, height: size.height)
        return MarkdownLayout(blocks: [MarkdownBlock(id: "plain", frame: frame, contentSize: frame.size,
            text: [MarkdownTextFragment(id: "text", text: attributed, frame: frame)])],
            decorations: [], size: frame.size)
    }
}

@MainActor
extension MarkdownSelectableTextView {
    func updateSearchFocus(previous: NSRange?) {
        for (range, color) in [(previous, nil), (activeSearchRange, NSColor(calibratedWhite: 0.12, alpha: 1))] {
            guard let range,
                  let start = system.storage.location(system.storage.documentRange.location, offsetBy: range.location),
                  let end = system.storage.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { continue }
            if let color {
                system.manager.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
            } else {
                system.manager.removeRenderingAttribute(.foregroundColor, for: textRange)
            }
        }
        searchPulseLayer?.removeFromSuperlayer()
        searchPulseLayer = nil
        pendingSearchPulse = false
        needsDisplay = true
    }

    func drawSearchHighlights(in dirtyRect: CGRect) {
        guard !searchRanges.isEmpty else { return }
        let clip = dirtyRect.intersection(visibleRect)
        guard !clip.isEmpty, !clip.isNull else { return }
        system.manager.ensureLayout(for: clip)
        guard let lower = lineBoundary(at: clip.minY, upper: false),
              let upper = lineBoundary(at: clip.maxY.nextDown, upper: true) else { return }
        let pulsePath = CGMutablePath()
        for range in searchRanges {
            if NSMaxRange(range) <= lower { continue }
            if range.location >= upper { break }
            let active = range == activeSearchRange
            let fill = active ? NSColor(calibratedRed: 1, green: 0.74, blue: 0.18, alpha: 1)
                : NSColor.systemYellow.withAlphaComponent(0.25)
            fill.setFill()
            for rect in selectionRects(for: range, clippedTo: clip) {
                let padded = active ? rect.insetBy(dx: -3, dy: -1).intersection(bounds.insetBy(dx: 1, dy: 1)) : rect
                let path = NSBezierPath(roundedRect: padded, xRadius: 3, yRadius: 3)
                path.fill()
                if active {
                    NSColor(calibratedRed: 0.9, green: 0.36, blue: 0.02, alpha: 1).setStroke()
                    path.lineWidth = 2
                    path.stroke()
                    pulsePath.addRoundedRect(in: padded, cornerWidth: 3, cornerHeight: 3)
                }
            }
        }
        if pendingSearchPulse, !pulsePath.isEmpty { pulseSearchFocus(path: pulsePath) }
    }

    private func pulseSearchFocus(path: CGPath) {
        pendingSearchPulse = false
        searchPulseLayer?.removeFromSuperlayer()
        searchPulseLayer = nil
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let halo = CAShapeLayer()
        halo.frame = bounds
        halo.path = path
        halo.fillColor = nil
        halo.strokeColor = NSColor.systemOrange.cgColor
        halo.lineWidth = 5
        halo.shadowColor = NSColor.systemOrange.cgColor
        halo.shadowPath = path
        halo.shadowOpacity = 0.8
        halo.shadowRadius = 6
        halo.shadowOffset = .zero
        halo.opacity = 0
        layer?.addSublayer(halo)
        searchPulseLayer = halo
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 0.85, 0]
        pulse.keyTimes = [0, 0.18, 1]
        pulse.duration = 0.55
        halo.add(pulse, forKey: "searchFocus")
    }
}
