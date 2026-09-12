import AppKit
import Observation
import SwiftUI

struct ChatLibrarySearchSession: Sendable {
    let summary: ChatSessionSummary
    var id: UUID { summary.id }
    let inputs: [ChatSearchInput]

    init(summary: ChatSessionSummary, items: [ChatTranscriptItem]) {
        self.summary = summary
        inputs = ChatSearchInput.snapshots(from: items)
    }
}

struct ChatLibrarySearchResult: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let sessionID: UUID
        let messageID: UUID
    }

    let sessionID: UUID
    let title: String
    let updatedAt: Date
    let isAssistant: Bool
    let occurrence: ChatSearchOccurrence
    var id: ID { ID(sessionID: sessionID, messageID: occurrence.messageID) }

    func isCurrent(in items: [ChatTranscriptItem]) -> Bool {
        guard let input = ChatSearchInput.snapshots(from: items).first(where: { $0.messageID == occurrence.messageID }),
              input.rowID == occurrence.rowID else { return false }
        let fragments = ChatSearchDocument.fragments(for: input)
        return occurrence.fragments.allSatisfy { match in
            fragments.contains { $0.id == match.id && $0.text == match.text }
        }
    }

    var excerpt: AttributedString {
        let source = occurrence.text
        guard let match = Range(occurrence.range, in: source) else { return AttributedString(source.prefix(240)) }
        let lower = source.index(match.lowerBound, offsetBy: -70, limitedBy: source.startIndex) ?? source.startIndex
        let upper = source.index(lower, offsetBy: 240, limitedBy: source.endIndex) ?? source.endIndex
        let crop = NSRange(lower..<upper, in: source)
        let prefix = lower == source.startIndex ? "" : "…"
        let text = prefix + String(source[lower..<upper]).replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ") + (upper == source.endIndex ? "" : "…")
        var value = AttributedString(text)
        let intersection = NSIntersectionRange(crop, occurrence.range)
        let highlight = NSRange(location: intersection.location - crop.location + prefix.utf16.count,
                                length: intersection.length)
        if let range = Range(highlight, in: text),
           let start = AttributedString.Index(range.lowerBound, within: value),
           let end = AttributedString.Index(range.upperBound, within: value) {
            value[start..<end].backgroundColor = Color.yellow.opacity(0.25)
            value[start..<end].font = .body.bold()
        }
        return value
    }
}

@MainActor @Observable
final class ChatSearchLibrary {
    private enum Update {
        case snapshot(() -> ChatLibrarySearchSession?)
        case removal
    }

    let worker: ChatLibrarySearchWorker
    private(set) var revision = 0
    private(set) var error: String?
    @ObservationIgnored private var startup: Task<Void, Error>?
    @ObservationIgnored private var updateTask: Task<Void, Error>?
    @ObservationIgnored private var pending: [UUID: Update] = [:]
    @ObservationIgnored private var knownSessions: Set<UUID> = []
    @ObservationIgnored private var sources: [UUID: () -> ChatViewModel?] = [:]

    init(storageURL: URL? = nil) {
        worker = ChatLibrarySearchWorker(storageURL: storageURL)
    }

    func start(_ sessions: [ChatSession]) {
        guard startup == nil else { return }
        knownSessions.formUnion(sessions.map(\.id))
        let worker = worker
        startup = Task(priority: .utility) { [weak self] in
            do {
                try await worker.bootstrap(sessions)
                self?.revision &+= 1
            } catch {
                self?.error = "Search is unavailable. Try again."
                self?.revision &+= 1
                throw error
            }
        }
        schedule()
    }

    func ready() async throws {
        try await startup?.value
        schedule()
        try await updateTask?.value
    }

    func invalidate(_ sessionID: UUID?, from chat: ChatViewModel) {
        guard let sessionID, !chat.isLoadingSessions, acceptsUpdates(for: sessionID, from: chat) else { return }
        sources[sessionID] = { [weak chat] in chat }
        enqueue(sessionID) { [weak chat] in chat?.searchSnapshot(in: sessionID) }
    }

    func enqueue(_ sessionID: UUID, snapshot: @escaping () -> ChatLibrarySearchSession?) {
        knownSessions.insert(sessionID)
        pending[sessionID] = .snapshot(snapshot)
        schedule()
    }

    func remove(_ sessionID: UUID) {
        knownSessions.remove(sessionID)
        sources[sessionID] = nil
        pending[sessionID] = .removal
        schedule()
    }

    func reconcile(_ sessions: [ChatSessionSummary], from chat: ChatViewModel) {
        let ids = Set(sessions.map(\.id))
        for id in knownSessions.subtracting(ids) where acceptsUpdates(for: id, from: chat) { remove(id) }
        for id in ids { invalidate(id, from: chat) }
    }

    private func acceptsUpdates(for sessionID: UUID, from chat: ChatViewModel) -> Bool {
        guard chat.canModifySession(sessionID) else { return false }
        if let source = sources[sessionID]?(), source !== chat, source.isSessionBusy(sessionID) { return false }
        return true
    }

    private func schedule() {
        guard startup != nil, updateTask == nil, !pending.isEmpty else { return }
        updateTask = Task(priority: .utility) { [weak self] in
            try await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            try await self.startup?.value
            let updates = self.pending
            self.pending = [:]
            var snapshots: [ChatLibrarySearchSession] = []
            var removed: Set<UUID> = []
            var reload: Set<UUID> = []
            for (id, update) in updates {
                switch update {
                case .snapshot(let read):
                    if let snapshot = read() { snapshots.append(snapshot) }
                    else { reload.insert(id) }
                case .removal: removed.insert(id)
                }
            }
            do {
                try await self.worker.update(snapshots, removed: removed, reload: reload)
                self.error = nil
                self.revision &+= 1
                self.updateTask = nil
                self.schedule()
            } catch {
                for (id, update) in updates where self.pending[id] == nil { self.pending[id] = update }
                self.error = "Search is unavailable. Try again."
                self.updateTask = nil
                throw error
            }
        }
    }
}

actor ChatLibrarySearchWorker {
    struct Result: Sendable {
        let messages: [ChatLibrarySearchResult]
        let hasMore: Bool
    }

    private var index = ChatSearchIndex()
    private var summaries: [UUID: ChatSearchStore.Session] = [:]
    private let storageURL: URL?
    private var store: ChatSearchStore?
    private var restored = false

    init(storageURL: URL? = nil) { self.storageURL = storageURL }

    func restore() throws {
        guard !restored else { return }
        if let storageURL {
            let store = try ChatSearchStore(url: storageURL)
            summaries = try store.restore(into: &index)
            self.store = store
        }
        restored = true
    }

    func bootstrap(_ sessions: [ChatSession]) throws {
        try restore()
        let snapshots = sessions.map {
            ChatLibrarySearchSession(summary: $0.summary, items: ChatTranscriptPresentation.items(from: $0.messages))
        }
        try synchronize(snapshots, summaries: sessions.map(\.summary))
    }

    func update(_ sessions: [ChatLibrarySearchSession], removed: Set<UUID> = [], reload: Set<UUID> = []) throws {
        try restore()
        var sessions = sessions
        var removed = removed
        if !reload.isEmpty {
            let source = ChatSessionStore()
            for id in reload {
                if let session = source.loadSession(id: id) {
                    sessions.append(ChatLibrarySearchSession(summary: session.summary,
                        items: ChatTranscriptPresentation.items(from: session.messages)))
                } else { removed.insert(id) }
            }
        }
        for id in removed { index.removeSession(id) }
        for session in sessions { try index.synchronize(session.inputs, sessionID: session.id) }
        let changed = sessions.map { ChatSearchStore.Session($0.summary) }.filter { summaries[$0.id] != $0 }
        try save(sessions: changed, removed: removed)
        for id in removed { summaries[id] = nil }
        for session in changed { summaries[session.id] = session }
    }

    func checkpoint() throws { try store?.checkpoint() }

    private func save(sessions: [ChatSearchStore.Session] = [], removed: Set<UUID> = []) throws {
        try store?.save(index, sessions: sessions, removedSessions: removed)
        index.didSave()
    }

    func search(_ query: String, sessionID: UUID, messageID: UUID? = nil, limit: Int = 10_000) throws -> ChatSearchWorker.Result {
        try restore()
        guard limit > 0 else { return ChatSearchWorker.Result(occurrences: [], hasMore: false) }
        let limit = min(limit, 10_000)
        let results = try index.search(query, limit: limit + 1, sessionID: sessionID, messageID: messageID) { _, left, _, right in
            left.position < right.position
        }
        try save()
        return ChatSearchWorker.Result(occurrences: results.prefix(limit).map { $0.1 }, hasMore: results.count > limit)
    }

    func synchronize(_ sessions: [ChatLibrarySearchSession], summaries: [ChatSessionSummary]) throws {
        try Task.checkCancellation()
        try restore()
        let updated = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, ChatSearchStore.Session($0)) })
        let removed = Set(self.summaries.keys).subtracting(updated.keys)
        let changed = updated.values.filter { self.summaries[$0.id] != $0 }
        for id in removed { index.removeSession(id) }
        for session in sessions { try index.synchronize(session.inputs, sessionID: session.id) }
        try save(sessions: changed, removed: removed)
        self.summaries = updated
    }

    func search(_ query: String, limit: Int = 200) throws -> Result {
        try restore()
        guard limit > 0 else { return Result(messages: [], hasMore: false) }
        let limit = min(limit, 200)
        let summaries = summaries
        let matches = try index.search(query, limit: limit + 1, firstMatchOnly: true) { left, lhs, right, rhs in
            if left.sessionID == right.sessionID { return lhs.position > rhs.position }
            let leftDate = left.sessionID.flatMap { summaries[$0]?.updatedAt } ?? .distantPast
            let rightDate = right.sessionID.flatMap { summaries[$0]?.updatedAt } ?? .distantPast
            return leftDate == rightDate
                ? (left.sessionID?.uuidString ?? "") < (right.sessionID?.uuidString ?? "")
                : leftDate > rightDate
        }
        let messages = matches.prefix(limit).compactMap { key, occurrence -> ChatLibrarySearchResult? in
            guard let id = key.sessionID, let summary = summaries[id] else { return nil }
            return ChatLibrarySearchResult(sessionID: id, title: summary.title, updatedAt: summary.updatedAt,
                                           isAssistant: index.entries[key]?.input.markdown == true,
                                           occurrence: occurrence)
        }
        try save()
        return Result(messages: messages, hasMore: matches.count > limit)
    }

    func search(_ query: String, sessions: [ChatLibrarySearchSession], limit: Int = 200) throws -> Result {
        try synchronize(sessions, summaries: sessions.map(\.summary))
        return try search(query, limit: limit)
    }
}

@MainActor @Observable
final class ChatLibrarySearchState {
    struct Destination: Equatable {
        let id = UUID()
        let query: String
        let result: ChatLibrarySearchResult
    }

    var isPresented = false
    var query = ""
    var selectedIndex = 0
    private(set) var results: [ChatLibrarySearchResult] = []
    private(set) var isSearching = false
    private(set) var hasMore = false
    private(set) var destination: Destination?
    var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var revision = 0

    func present() { isPresented = true }

    func dismiss() {
        stop()
        isPresented = false
        query = ""
        results = []
        selectedIndex = 0
        hasMore = false
        error = nil
    }

    func move(_ offset: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + results.count) % results.count
    }

    func select(_ result: ChatLibrarySearchResult) {
        destination = Destination(query: query, result: result)
        dismiss()
    }

    func takeDestination(for sessionID: UUID?) -> Destination? {
        guard let destination, destination.result.sessionID == sessionID else { return nil }
        self.destination = nil
        return destination
    }

    func refresh(from chat: ChatViewModel, queryChanged: Bool = false) {
        guard isPresented else { return }
        guard !chat.isLoadingSessions else { isSearching = true; return }
        revision &+= 1
        if queryChanged {
            stop()
            results = []
            selectedIndex = 0
            hasMore = false
        }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stop()
            results = []
            hasMore = false
            error = nil
            return
        }
        guard task == nil else { return }
        isSearching = true
        error = nil
        let generation = generation
        task = Task { [weak self, weak chat] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard let self, let chat, self.generation == generation else { return }
                let revision = self.revision
                try await chat.searchLibrary.ready()
                let worker = chat.searchLibrary.worker
                let selected = self.results.indices.contains(self.selectedIndex) ? self.results[self.selectedIndex].id : nil
                let result = try await worker.search(self.query)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                self.results = result.messages
                self.hasMore = result.hasMore
                self.selectedIndex = selected.flatMap { selected in self.results.firstIndex { $0.id == selected } } ?? 0
                self.isSearching = false
                self.task = nil
                if self.revision != revision { self.refresh(from: chat) }
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == generation else { return }
                self.error = "Search is unavailable. Try again."
                self.isSearching = false
                self.task = nil
            }
        }
    }

    private func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        isSearching = false
    }
}

extension EnvironmentValues {
    @Entry var chatLibrarySearch: ChatLibrarySearchState? = nil
}

struct ChatLibrarySearchPopup: View {
    @Bindable var search: ChatLibrarySearchState
    @ObservedObject var chat: ChatViewModel
    let onSelect: (ChatLibrarySearchResult) -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chats", text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                    .onSubmit(openSelected)
                    .onKeyPress(.downArrow) { search.move(1); return .handled }
                    .onKeyPress(.upArrow) { search.move(-1); return .handled }
                    .onExitCommand { search.dismiss() }
                    .accessibilityLabel("Search all chats")
                if search.isSearching { ProgressView().controlSize(.small).frame(width: 16) }
                Button("Close search", systemImage: "xmark") { search.dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close search (Esc)")
            }
            .padding(20)
            Divider()
            if search.results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(emptyTitle).font(.headline)
                    Text(search.query.isEmpty ? "Find messages from any conversation." : "Try another word or phrase.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(search.results.enumerated()), id: \.element.id) { index, result in
                                Button { onSelect(result) } label: {
                                    resultRow(result)
                                        .padding(12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(index == search.selectedIndex ? Color.primary.opacity(0.07) : .clear,
                                                    in: .rect(cornerRadius: 8))
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .onHover { if $0 { search.selectedIndex = index } }
                                .id(result.id)
                                .accessibilityHint("Open this chat at the matching message")
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: search.selectedIndex) { _, index in
                        if search.results.indices.contains(index) { proxy.scrollTo(search.results[index].id) }
                    }
                }
            }
            Divider()
            HStack {
                Text(search.hasMore ? "Showing the first 200 matching messages" : "\(search.results.count) matching messages")
                Spacer()
                Text("↑↓ Navigate   ↵ Open   Esc Close")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 640, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { isFocused = true; search.refresh(from: chat) }
        .onChange(of: search.query) { _, _ in search.refresh(from: chat, queryChanged: true) }
        .onChange(of: chat.searchLibrary.revision) { _, _ in search.refresh(from: chat) }
        .onDisappear { search.dismiss() }
    }

    private var emptyTitle: String {
        if let error = search.error { return error }
        if chat.isLoadingSessions { return "Loading chats…" }
        if search.isSearching { return "Searching…" }
        return search.query.isEmpty ? "Search all chats" : "No matching messages"
    }

    private func resultRow(_ result: ChatLibrarySearchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left").foregroundStyle(.secondary)
                Text(result.title).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 8)
                Text(result.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            Text(result.excerpt).lineLimit(2).multilineTextAlignment(.leading)
            Text(result.isAssistant ? "Assistant" : "You").font(.caption).foregroundStyle(.secondary)
        }
        .font(.body)
    }

    private func openSelected() {
        guard search.results.indices.contains(search.selectedIndex) else { return }
        onSelect(search.results[search.selectedIndex])
    }
}
