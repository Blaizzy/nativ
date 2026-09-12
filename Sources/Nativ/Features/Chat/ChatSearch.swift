import AppKit
import Observation
import QuartzCore
import SwiftUI

struct ChatSearchInput: Codable, Equatable, Sendable {
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
    struct Fragment: Codable, Equatable, Sendable {
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

struct ChatSearchIndex {
    struct Key: Codable, Hashable, Sendable {
        let sessionID: UUID?
        let messageID: UUID
    }

    struct Record: Codable {
        let key: Key
        let input: ChatSearchInput
        let fragments: [ChatSearchDocument.Fragment]
        let message: ChatTextSearch.Message
        var alternatives: [String: ChatTextSearch.Message] = [:]
    }

    struct Entry {
        let documentID: Int
        let record: Record
        let fragments: [(ChatSearchDocument.Fragment, NSRange)]
        var position: Int
        var input: ChatSearchInput { record.input }
        var message: ChatTextSearch.Message { record.message }
    }

    struct Changes {
        var updated: Set<Key> = []
        var removed: Set<Key> = []
        var moved: Set<Key> = []
    }

    private struct SingleWords {
        var index = ChatTextSearch.Index<Int>()
        var messages: [Key: ChatTextSearch.Message] = [:]
        var pending: Set<Key>
    }

    private(set) var entries: [Key: Entry] = [:]
    private var sessions: [UUID?: Set<Key>] = [:]
    private var index = ChatTextSearch.Index<Int>()
    private var languages: [String: Int] = [:]
    private var documents: [Int: Key] = [:]
    private var documentSessions: [UUID?: Set<Int>] = [:]
    private var nextDocumentID = 0
    private var singleWords: Set<Key> = []
    private var singleWordIndexes: [String: SingleWords] = [:]

    private(set) var changes = Changes()

    mutating func synchronize(_ inputs: [ChatSearchInput], sessionID: UUID? = nil) throws {
        try Task.checkCancellation()
        let keys = Set(inputs.map { Key(sessionID: sessionID, messageID: $0.messageID) })
        for key in (sessions[sessionID] ?? []).subtracting(keys) {
            remove(key)
            changes.removed.insert(key)
        }
        sessions[sessionID] = keys
        for (position, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let key = Key(sessionID: sessionID, messageID: input.messageID)
            if entries[key]?.input == input {
                if entries[key]?.position != position {
                    entries[key]?.position = position
                    changes.moved.insert(key)
                }
                continue
            }
            let fragments = ChatSearchDocument.fragments(for: input)
            let text = fragments.map(\.text).joined(separator: "\n\n")
            let message = try ChatTextSearch.Message(id: input.messageID, text: text)
            insert(Record(key: key, input: input, fragments: fragments, message: message), position: position)
            changes.updated.insert(key)
            changes.removed.remove(key)
        }
    }

    mutating func insert(_ record: Record, position: Int) {
        let key = record.key
        let documentID = entries[key]?.documentID ?? nextDocumentID
        if entries[key] == nil { nextDocumentID += 1 }
        remove(key)
        var offset = 0
        let fragments = record.fragments.map { fragment in
            let range = NSRange(location: offset, length: fragment.text.utf16.count)
            offset = NSMaxRange(range) + 2
            return (fragment, range)
        }
        documents[documentID] = key
        documentSessions[key.sessionID, default: []].insert(documentID)
        entries[key] = Entry(documentID: documentID, record: record, fragments: fragments, position: position)
        sessions[key.sessionID, default: []].insert(key)
        index.insert(record.message, id: documentID)
        languages[record.message.language?.rawValue ?? "", default: 0] += 1
        if record.message.isSingleWord {
            singleWords.insert(key)
            for language in singleWordIndexes.keys { singleWordIndexes[language]?.pending.insert(key) }
            for (language, message) in record.alternatives {
                if singleWordIndexes[language] == nil { singleWordIndexes[language] = SingleWords(pending: singleWords) }
                singleWordIndexes[language]?.pending.remove(key)
                singleWordIndexes[language]?.messages[key] = message
                singleWordIndexes[language]?.index.insert(message, id: documentID)
            }
        }
    }

    func record(for key: Key) -> Record? {
        guard var record = entries[key]?.record else { return nil }
        record.alternatives = singleWordIndexes.compactMapValues { $0.messages[key] }
        return record
    }

    mutating func didSave() { changes = Changes() }

    mutating func removeSession(_ sessionID: UUID) {
        for key in sessions.removeValue(forKey: sessionID) ?? [] {
            remove(key)
            changes.removed.insert(key)
        }
    }

    private mutating func remove(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        documents[entry.documentID] = nil
        documentSessions[key.sessionID]?.remove(entry.documentID)
        index.remove(entry.message, id: entry.documentID)
        let language = entry.message.language?.rawValue ?? ""
        languages[language, default: 0] -= 1
        if languages[language] == 0 { languages[language] = nil }
        singleWords.remove(key)
        for language in singleWordIndexes.keys {
            singleWordIndexes[language]?.pending.remove(key)
            if let message = singleWordIndexes[language]?.messages.removeValue(forKey: key) {
                singleWordIndexes[language]?.index.remove(message, id: entry.documentID)
            }
        }
    }

    mutating func search(_ text: String, limit: Int, firstMatchOnly: Bool = false,
                         sessionID: UUID? = nil, messageID: UUID? = nil,
                         orderedBy: (Key, Entry, Key, Entry) -> Bool) throws -> [(Key, ChatSearchOccurrence)] {
        try Task.checkCancellation()
        guard limit > 0, !entries.isEmpty else { return [] }
        let automatic = try ChatTextSearch.Query(text)
        guard !automatic.text.isEmpty else { return [] }
        let scope: Set<Int>?
        if let sessionID, let messageID {
            scope = entries[Key(sessionID: sessionID, messageID: messageID)].map { [$0.documentID] } ?? []
        } else if let sessionID { scope = documentSessions[sessionID] ?? [] }
        else { scope = nil }
        var queries: [String: ChatTextSearch.Query] = [:]
        var candidates: Set<Int> = []
        for language in languages.keys {
            let query = try ChatTextSearch.Query(text, languageCode: language)
            queries[language] = query
            candidates.formUnion(try index.candidates(for: query, within: scope))
        }
        if let language = automatic.language, !singleWords.isEmpty {
            let code = language.rawValue
            if singleWordIndexes[code] == nil { singleWordIndexes[code] = SingleWords(pending: singleWords) }
            for key in singleWordIndexes[code]?.pending ?? [] where sessionID == nil || key.sessionID == sessionID {
                try Task.checkCancellation()
                guard let entry = entries[key] else { continue }
                if entry.message.language == language {
                    singleWordIndexes[code]?.pending.remove(key)
                    continue
                }
                let message = try ChatTextSearch.Message(id: key.messageID, text: entry.message.text,
                                                         language: language)
                singleWordIndexes[code]?.messages[key] = message
                singleWordIndexes[code]?.index.insert(message, id: entry.documentID)
                singleWordIndexes[code]?.pending.remove(key)
                changes.updated.insert(key)
            }
            if let additional = try singleWordIndexes[code]?.index.candidates(for: automatic, within: scope) {
                candidates.formUnion(additional)
            }
        }
        let ordered = candidates.compactMap { documents[$0] }.filter { sessionID == nil || $0.sessionID == sessionID }.sorted {
            guard let left = entries[$0], let right = entries[$1] else { return false }
            return orderedBy($0, left, $1, right)
        }
        var results: [(Key, ChatSearchOccurrence)] = []
        for key in ordered {
            try Task.checkCancellation()
            guard let entry = entries[key], let query = queries[entry.message.language?.rawValue ?? ""] else { continue }
            let matchLimit = firstMatchOnly ? 1 : limit - results.count
            var matches = try ChatTextSearch.matches(in: entry.message, query: query, limit: matchLimit)
            if matches.isEmpty, let code = automatic.language?.rawValue,
               let message = singleWordIndexes[code]?.messages[key] {
                matches = try ChatTextSearch.matches(in: message, query: automatic, limit: matchLimit)
            }
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
                results.append((key, ChatSearchOccurrence(messageID: key.messageID, rowID: entry.input.rowID,
                                                          fragment: first, continuations: Array(parts.dropFirst()))))
                if results.count == limit { return results }
            }
        }
        return results
    }
}

actor ChatSearchWorker {
    struct Result: Sendable {
        let occurrences: [ChatSearchOccurrence]
        let hasMore: Bool
    }

    private var index = ChatSearchIndex()

    func synchronize(_ inputs: [ChatSearchInput]) throws {
        try index.synchronize(inputs)
        index.didSave()
    }

    func search(_ query: String, limit: Int = 10_000, firstMatchOnly: Bool = false) throws -> Result {
        guard limit > 0 else { return Result(occurrences: [], hasMore: false) }
        let limit = min(limit, 10_000)
        let results = try index.search(query, limit: limit + 1, firstMatchOnly: firstMatchOnly) {
            $1.position < $3.position
        }
        return Result(occurrences: results.prefix(limit).map { $0.1 }, hasMore: results.count > limit)
    }

    func search(_ query: String, inputs: [ChatSearchInput], limit: Int = 10_000,
                firstMatchOnly: Bool = false) throws -> Result {
        try synchronize(inputs)
        return try search(query, limit: limit, firstMatchOnly: firstMatchOnly)
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
    @ObservationIgnored private var library: ChatSearchLibrary?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var inputs: [ChatSearchInput] = []
    @ObservationIgnored private var snapshotRevision: Int?
    @ObservationIgnored private var indexedRevision: Int?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var requestedMatch: (query: String, location: ChatSearchOccurrence.Location)?

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

    func reveal(_ occurrence: ChatSearchOccurrence, query: String, sessionID: UUID, items: [ChatTranscriptItem]) {
        reset(sessionID: sessionID)
        requestedMatch = (query, occurrence.location)
        self.query = query
        present()
        update(items: items, queryChanged: true)
    }

    func dismiss() {
        reset(sessionID: sessionID)
    }

    func reset(sessionID: UUID?, library: ChatSearchLibrary? = nil) {
        if let library { self.library = library }
        self.sessionID = sessionID
        isPresented = false
        clear()
    }

    private func clear() {
        stop()
        query = ""
        inputs = []
        snapshotRevision = nil
        indexedRevision = nil
        occurrences = []
        matchesByMessage = [:]
        selectedIndex = 0
        hasMore = false
        error = nil
        revealID = nil
        worker = ChatSearchWorker()
        requestedMatch = nil
    }

    func update(items: @autoclosure () -> [ChatTranscriptItem], contentRevision: Int? = nil,
                queryChanged: Bool = false) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clear()
            return
        }
        if library == nil, contentRevision == nil || snapshotRevision != contentRevision {
            inputs = ChatSearchInput.snapshots(from: items())
            snapshotRevision = contentRevision
            revision &+= 1
        }
        if library != nil { revision &+= 1 }
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
                let requested = self.requestedMatch.flatMap { $0.query == self.query ? $0.location : nil }
                let location = requested ?? previous?.location
                let resultWorker = self.library?.worker
                try await self.library?.ready()
                if resultWorker == nil, self.indexedRevision != revision {
                    try await self.worker.synchronize(self.inputs)
                    try Task.checkCancellation()
                    self.indexedRevision = revision
                }
                var result: ChatSearchWorker.Result
                if let resultWorker, let sessionID = self.sessionID {
                    result = try await resultWorker.search(self.query, sessionID: sessionID)
                } else {
                    result = try await self.worker.search(self.query)
                }
                if result.hasMore, let location,
                   !result.occurrences.contains(where: { $0.messageID == location.messageID }) {
                    let focused: ChatSearchWorker.Result?
                    if let resultWorker, let sessionID = self.sessionID {
                        focused = try await resultWorker.search(self.query, sessionID: sessionID,
                                                                 messageID: location.messageID, limit: 1)
                    } else if let input = self.inputs.first(where: { $0.messageID == location.messageID }) {
                        focused = try await ChatSearchWorker().search(self.query, inputs: [input], limit: 1)
                    } else { focused = nil }
                    if let focused {
                        result = ChatSearchWorker.Result(occurrences: result.occurrences + focused.occurrences, hasMore: true)
                    }
                }
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                self.occurrences = result.occurrences
                self.matchesByMessage = Dictionary(grouping: result.occurrences, by: \.messageID)
                self.hasMore = result.hasMore
                self.selectedIndex = location.flatMap { location in
                    self.occurrences.firstIndex { $0.location == location }
                        ?? self.occurrences.firstIndex { $0.messageID == location.messageID }
                } ?? 0
                self.requestedMatch = nil
                if previous?.location != self.selected?.location {
                    self.revealID = nil
                    self.navigationID = UUID()
                }
                self.task = nil
                self.isSearching = false
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
