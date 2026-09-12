import AppKit
import Combine
import Observation
import SwiftUI

struct ChatLibrarySearchSession: Sendable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let inputs: [ChatSearchInput]

    init(summary: ChatSessionSummary, items: [ChatTranscriptItem]) {
        id = summary.id
        title = summary.title
        updatedAt = summary.updatedAt
        inputs = Array(ChatSearchInput.snapshots(from: items).reversed())
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

actor ChatLibrarySearchWorker {
    struct Result: Sendable {
        let messages: [ChatLibrarySearchResult]
        let hasMore: Bool
    }

    // Forks can share message IDs. Keep their prepared text in separate namespaces.
    private var workers: [UUID: ChatSearchWorker] = [:]

    func search(_ query: String, sessions: [ChatLibrarySearchSession], limit: Int = 200) async throws -> Result {
        try Task.checkCancellation()
        guard limit > 0 else { return Result(messages: [], hasMore: false) }
        let limit = min(limit, 200)
        let ids = Set(sessions.map(\.id))
        workers = workers.filter { ids.contains($0.key) }
        var messages: [ChatLibrarySearchResult] = []
        let ordered = sessions.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
        for session in ordered {
            try Task.checkCancellation()
            let worker = workers[session.id] ?? ChatSearchWorker()
            workers[session.id] = worker
            let result = try await worker.search(query, inputs: session.inputs, limit: limit + 1 - messages.count,
                                                 firstMatchOnly: true)
            guard !result.occurrences.isEmpty else { continue }
            let inputs = Dictionary(uniqueKeysWithValues: session.inputs.map { ($0.messageID, $0) })
            for occurrence in result.occurrences {
                messages.append(ChatLibrarySearchResult(sessionID: session.id, title: session.title,
                    updatedAt: session.updatedAt, isAssistant: inputs[occurrence.messageID]?.markdown == true,
                    occurrence: occurrence))
                if messages.count > limit { return Result(messages: Array(messages.prefix(limit)), hasMore: true) }
            }
        }
        return Result(messages: messages, hasMore: false)
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
    @ObservationIgnored private var worker = ChatLibrarySearchWorker()
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
        worker = ChatLibrarySearchWorker()
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
                let selected = self.results.indices.contains(self.selectedIndex) ? self.results[self.selectedIndex].id : nil
                let sessions = chat.sessions.map {
                    ChatLibrarySearchSession(summary: $0, items: chat.searchableTranscriptItems(in: $0.id))
                }
                let result = try await self.worker.search(self.query, sessions: sessions)
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
        .onReceive(chat.$sessions.dropFirst()) { _ in search.refresh(from: chat) }
        .onReceive(chat.$messages.dropFirst()) { _ in search.refresh(from: chat) }
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
