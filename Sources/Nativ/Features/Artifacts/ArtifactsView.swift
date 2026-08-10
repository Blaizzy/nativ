import AppKit
import AVFoundation
import PDFKit
import SwiftUI
import Vision

enum ArtifactLayout {
    case grid
    case list
}

enum ArtifactDateFilter: String, CaseIterable, Identifiable {
    case all = "Any date"
    case today = "Today"
    case week = "Past 7 days"
    case month = "Past 30 days"

    var id: String { rawValue }

    func includes(_ date: Date) -> Bool {
        switch self {
        case .all:
            return true
        case .today:
            return Calendar.current.isDateInToday(date)
        case .week:
            return date >= Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        case .month:
            return date >= Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        }
    }
}

enum ArtifactSort: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case oldest = "Oldest"
    case name = "Name"
    case largest = "Largest"
    case type = "Type"

    var id: String { rawValue }

    var isChronological: Bool {
        self == .newest || self == .oldest
    }

    var comparator: (Artifact, Artifact) -> Bool {
        switch self {
        case .newest:
            return { $0.createdAt > $1.createdAt }
        case .oldest:
            return { $0.createdAt < $1.createdAt }
        case .name:
            return { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
        case .largest:
            return { $0.byteSize > $1.byteSize }
        case .type:
            return { $0.kind.rawValue < $1.kind.rawValue }
        }
    }
}

struct ArtifactGroup: Identifiable {
    let id: String
    let title: String
    let items: [Artifact]
}

struct ArtifactsView: View {
    @ObservedObject var store: ArtifactStore
    let semanticSearch: ArtifactSemanticSearchConfig?
    var titleLeadingInset: CGFloat = 0
    let onOpenChat: (Artifact) -> Void
    let onUseInChat: (Artifact) -> Void
    let onUseAsReference: (Artifact) -> Void

    @StateObject private var searchIndex = ArtifactSearchIndex()
    @State private var semanticMatches: [UUID]?
    @State private var searchDebounce: Task<Void, Never>?
    @State private var showsSemanticPopover = false
    @State private var isConfirmingSemanticModelRemoval = false
    @AppStorage("artifactSemanticSearchOffered") private var semanticSearchOffered = false
    @AppStorage("smartSearchEnabled") private var smartSearchEnabled = true

    @State private var search = ""
    @State private var kindFilter: ArtifactKind?
    @State private var sourceFilter: ArtifactSource?
    @State private var sort: ArtifactSort = .newest
    @State private var layout: ArtifactLayout = .grid
    @State private var previewID: Artifact.ID?
    @State private var isSelecting = false
    @State private var selection: Set<Artifact.ID> = []
    @State private var pendingDelete: [Artifact] = []
    @State private var isConfirmingDelete = false
    @State private var inspectorArtifact: Artifact?
    @State private var groupByChat = false
    @State private var albumSessionID: UUID?
    @State private var favoritesOnly = false
    @State private var dateFilter: ArtifactDateFilter = .all
    @State private var renameTarget: Artifact?
    @State private var renameText = ""
    @State private var cursorID: Artifact.ID?
    @FocusState private var gridFocused: Bool
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showingByChat: Bool {
        groupByChat && !isSearching
    }

    private var smartSearchActive: Bool {
        smartSearchEnabled && (semanticSearch?.isModelInstalled == true)
    }

    private var filtered: [Artifact] {
        var result = store.artifacts
        if let kindFilter {
            result = result.filter { $0.kind == kindFilter }
        }
        if let sourceFilter {
            result = result.filter { $0.source == sourceFilter }
        }
        if favoritesOnly {
            result = result.filter { store.isFavorite($0) }
        }
        if dateFilter != .all {
            result = result.filter { dateFilter.includes($0.createdAt) }
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return result.sorted(by: sort.comparator)
        }
        if let semanticMatches, smartSearchActive {
            var rank: [UUID: Int] = [:]
            for (position, id) in semanticMatches.enumerated() {
                rank[id] = position
            }
            return result
                .filter { rank[$0.id] != nil }
                .sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        }
        let lowered = query.lowercased()
        return result.filter { $0.searchText.contains(lowered) }.sorted(by: sort.comparator)
    }

    private var groups: [ArtifactGroup] {
        let items = filtered
        guard sort.isChronological else {
            return [ArtifactGroup(id: "all", title: "", items: items)]
        }
        var buckets: [String: [Artifact]] = [:]
        var order: [String] = []
        for artifact in items {
            let key = Self.bucketTitle(for: artifact.createdAt)
            if buckets[key] == nil {
                order.append(key)
            }
            buckets[key, default: []].append(artifact)
        }
        return order.map { ArtifactGroup(id: $0, title: $0, items: buckets[$0] ?? []) }
    }

    @ViewBuilder
    private var semanticBanner: some View {
        if let config = semanticSearch, !config.isModelInstalled, !config.isDownloading,
           config.canInstall, !semanticSearchOffered, !store.artifacts.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Turn on Smart search")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Install a \(config.sizeLabel) on-device model to find artifacts by what's inside them. You can also do this later from the settings.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Install") {
                    config.onEnable()
                    semanticSearchOffered = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Not now") {
                    semanticSearchOffered = true
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
        }
    }

    @ViewBuilder
    private func semanticSettingsButton(_ config: ArtifactSemanticSearchConfig) -> some View {
        Button {
            showsSemanticPopover = true
        } label: {
            Image(systemName: "gearshape")
        }
        .help("Smart search settings")
        .popover(isPresented: $showsSemanticPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Smart search", systemImage: "sparkle.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                if config.isModelInstalled {
                    Toggle("Enabled", isOn: $smartSearchEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Text(smartSearchEnabled
                        ? "Searching by image, video and document contents."
                        : "Turned off. The model stays installed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Runs on-device — results are fastest when your Mac isn't busy generating.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Divider()
                    Button("Remove model", role: .destructive) {
                        isConfirmingSemanticModelRemoval = true
                    }
                    .controlSize(.small)
                    .help("Deletes the model and turns Smart search off")
                } else if config.isDownloading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Downloading model… \(Int((config.downloadProgress * 100).rounded()))%")
                            .font(.system(size: 11))
                    }
                } else {
                    Text("Install a \(config.sizeLabel) on-device model to search artifacts by what's inside them.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Install") {
                        config.onEnable()
                        semanticSearchOffered = true
                        showsSemanticPopover = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!config.canInstall)
                    if let reason = config.insufficientReason {
                        Text(reason)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(14)
            .frame(width: 264)
        }
    }

    private func scheduleSemanticSearch() {
        searchDebounce?.cancel()
        guard smartSearchEnabled, let config = semanticSearch, config.isModelInstalled else {
            semanticMatches = nil
            return
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            semanticMatches = nil
            return
        }
        searchDebounce = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled {
                return
            }
            await Task.detached { config.prepareModel() }.value
            let matches = await searchIndex.search(query: query, model: config.modelID, client: config.client)
            if Task.isCancelled {
                return
            }
            semanticMatches = matches
        }
    }

    private func warmSemanticIndex() {
        guard smartSearchEnabled, let config = semanticSearch, config.isModelInstalled else {
            return
        }
        Task {
            await Task.detached { config.prepareModel() }.value
            await searchIndex.index(
                artifacts: store.artifacts,
                model: config.modelID,
                client: config.client,
                visualURLs: visualDataURLs(for:),
                textChunks: documentTextChunks(for:)
            )
        }
    }

    private func documentTextChunks(for artifact: Artifact) async -> [String] {
        let url = store.fileURL(for: artifact)
        switch artifact.kind {
        case .image:
            // On-device OCR (Apple Vision) so text inside screenshots/photos is searchable.
            if let text = await Self.recognizeText(in: url), !text.isEmpty {
                return Self.chunkedText(text, maxChunks: 4, chunkSize: 1200)
            }
            return []
        case .video:
            return []
        case .document:
            let ext = artifact.fileExtension.lowercased()
            return await Task.detached(priority: .utility) {
                let raw: String
                if ext == "pdf" {
                    guard let document = PDFDocument(url: url), let string = document.string else {
                        return []
                    }
                    raw = string
                } else {
                    guard let string = try? String(contentsOf: url, encoding: .utf8) else {
                        return []
                    }
                    raw = string
                }
                return Self.chunkedText(raw, maxChunks: 8, chunkSize: 1200)
            }.value
        }
    }

    private static func recognizeText(in url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }.value
    }

    private static func chunkedText(_ text: String, maxChunks: Int, chunkSize: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }
        var chunks: [String] = []
        var start = trimmed.startIndex
        while start < trimmed.endIndex, chunks.count < maxChunks {
            let end = trimmed.index(start, offsetBy: chunkSize, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            let piece = trimmed[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                chunks.append(piece)
            }
            start = end
        }
        return chunks
    }

    private func visualDataURLs(for artifact: Artifact) async -> [String] {
        let url = store.fileURL(for: artifact)
        switch artifact.kind {
        case .image:
            let mimeType = artifact.mimeType
            return await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url) else {
                    return []
                }
                return ["data:\(mimeType);base64,\(data.base64EncodedString())"]
            }.value
        case .video:
            return await Self.videoFrameDataURLs(url: url, count: 4)
        case .document:
            return []
        }
    }

    private static func videoFrameDataURLs(url: URL, count: Int) async -> [String] {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else {
                return []
            }
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else {
                return []
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 512, height: 512)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity

            var urls: [String] = []
            for index in 0..<count {
                let fraction = (Double(index) + 0.5) / Double(count)
                let time = CMTime(seconds: seconds * fraction, preferredTimescale: 600)
                guard let cgImage = try? await generator.image(at: time).image else {
                    continue
                }
                let rep = NSBitmapImageRep(cgImage: cgImage)
                if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                    urls.append("data:image/jpeg;base64,\(data.base64EncodedString())")
                }
            }
            return urls
        }.value
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            semanticBanner
            if isSelecting {
                selectionBar
            }
            filterBar
            Divider()
            contentView
        }
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onKeyPress(action: handleKey)
        .task {
            warmSemanticIndex()
        }
        .onChange(of: search) { _, _ in
            scheduleSemanticSearch()
        }
        .onChange(of: smartSearchActive) { _, _ in
            warmSemanticIndex()
            scheduleSemanticSearch()
        }
        .onChange(of: store.artifacts.count) { _, _ in
            warmSemanticIndex()
        }
        .onChange(of: searchIndex.indexedCount) { _, _ in
            scheduleSemanticSearch()
        }
        .overlay {
            if previewID != nil {
                ArtifactPreview(
                    artifacts: filtered,
                    selectedID: $previewID,
                    fileURL: store.fileURL,
                    onClose: { previewID = nil },
                    onOpenChat: { artifact in
                        previewID = nil
                        onOpenChat(artifact)
                    }
                )
            }
        }
        .alert("Delete \(pendingDelete.count) \(pendingDelete.count == 1 ? "item" : "items")?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                store.delete(pendingDelete)
                selection.subtract(pendingDelete.map(\.id))
                pendingDelete = []
                if selection.isEmpty {
                    isSelecting = false
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("This removes the file from the artifact and from its chat history. It can't be undone.")
        }
        .alert("Remove Smart Search model?", isPresented: $isConfirmingSemanticModelRemoval) {
            Button("Remove Model", role: .destructive) {
                semanticSearch?.onRemove()
                showsSemanticPopover = false
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the on-device Smart Search model and turns Smart Search off.")
        }
        .overlay {
            if let albumSessionID {
                ArtifactAlbum(
                    title: filtered.first { $0.sessionID == albumSessionID }?.sessionTitle ?? "Chat",
                    artifacts: filtered.filter { $0.sessionID == albumSessionID },
                    store: store,
                    onOpen: { artifact in
                        self.albumSessionID = nil
                        previewID = artifact.id
                    },
                    onGoToChat: { artifact in
                        self.albumSessionID = nil
                        onOpenChat(artifact)
                    },
                    onInspect: { artifact in
                        self.albumSessionID = nil
                        inspectorArtifact = artifact
                    },
                    onClose: { self.albumSessionID = nil }
                )
            }
        }
        .sheet(item: $inspectorArtifact) { artifact in
            ArtifactInspector(
                artifact: artifact,
                store: store,
                onOpenPreview: {
                    inspectorArtifact = nil
                    previewID = artifact.id
                },
                onGoToChat: {
                    inspectorArtifact = nil
                    onOpenChat(artifact)
                },
                onClose: { inspectorArtifact = nil }
            )
        }
        .alert("Rename artifact", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let target = renameTarget {
                    store.rename(target, to: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    @ViewBuilder
    private var contentView: some View {
        if store.artifacts.isEmpty {
            emptyState(
                title: "No artifacts yet",
                message: "Images, videos, and documents from your chats will collect here."
            )
        } else if filtered.isEmpty {
            emptyState(title: "Nothing matches", message: "Try a different filter or search term.")
        } else if showingByChat {
            deckGrid
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            if layout == .grid {
                                grid(group.items)
                            } else {
                                list(group.items)
                            }
                        } header: {
                            if !group.title.isEmpty {
                                sectionHeader(group.title, count: group.items.count)
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private var chatGroups: [ArtifactGroup] {
        var order: [UUID] = []
        var buckets: [UUID: [Artifact]] = [:]
        for artifact in filtered {
            if buckets[artifact.sessionID] == nil {
                order.append(artifact.sessionID)
            }
            buckets[artifact.sessionID, default: []].append(artifact)
        }
        return order.map { id in
            let items = buckets[id] ?? []
            return ArtifactGroup(id: id.uuidString, title: items.first?.sessionTitle ?? "Chat", items: items)
        }
    }

    private var deckGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 24)],
                spacing: 28
            ) {
                ForEach(chatGroups) { group in
                    ChatDeck(group: group, store: store) {
                        albumSessionID = UUID(uuidString: group.id)
                    }
                }
            }
            .padding(28)
        }
    }

    private func grid(_ artifacts: [Artifact]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 24)],
            spacing: 24
        ) {
            ForEach(artifacts) { artifact in
                ArtifactTile(
                    artifact: artifact,
                    store: store,
                    isSelecting: isSelecting,
                    isSelected: selection.contains(artifact.id),
                    isFavorite: store.isFavorite(artifact),
                    onInspect: { inspectorArtifact = artifact },
                    onToggleFavorite: { store.toggleFavorite(artifact) }
                )
                .onTapGesture { activate(artifact) }
                .modifier(ArtifactDrag(store: store, artifact: artifact, enabled: !isSelecting))
                .overlay {
                    if isSelecting {
                        SelectionDrag(
                            onToggle: { activate(artifact) },
                            fileURLs: { selectedFileURLs(including: artifact) }
                        )
                    }
                }
                .overlay {
                    if cursorID == artifact.id, !isSelecting {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.9), lineWidth: 2.5)
                    }
                }
                .contextMenu { menu(for: artifact) }
            }
        }
    }

    private func list(_ artifacts: [Artifact]) -> some View {
        VStack(spacing: 0) {
            ForEach(artifacts) { artifact in
                ArtifactRow(
                    artifact: artifact,
                    store: store,
                    isSelecting: isSelecting,
                    isSelected: selection.contains(artifact.id)
                )
                .onTapGesture { activate(artifact) }
                .modifier(ArtifactDrag(store: store, artifact: artifact, enabled: !isSelecting))
                .contextMenu { menu(for: artifact) }
                Divider()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Artifacts")
                    .font(.title2.weight(.semibold))
                Text("\(filtered.count) \(filtered.count == 1 ? "item" : "items")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(isSelecting ? "Done" : "Select") {
                isSelecting.toggle()
                if !isSelecting {
                    selection.removeAll()
                }
            }

            Toggle(isOn: Binding(get: { showingByChat }, set: { groupByChat = $0 })) {
                Label("By Chat", systemImage: "bubble.left.and.bubble.right")
            }
            .toggleStyle(.button)
            .disabled(isSearching)
            .help(isSearching ? "Grouping is off while searching" : "Group artifacts by chat")

            if !showingByChat {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(ArtifactSort.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(sort.rawValue)
                }
                .fixedSize()

                Picker("", selection: $layout) {
                    Image(systemName: "square.grid.2x2").tag(ArtifactLayout.grid)
                    Image(systemName: "list.bullet").tag(ArtifactLayout.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 84)
            }

            Button(action: store.refresh) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: store.isRefreshing)
            }
            .help("Rescan chats for new artifacts")

            if let config = semanticSearch {
                semanticSettingsButton(config)
            }
        }
        .padding(.horizontal, 22)
        .padding(.leading, titleLeadingInset)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(selection.count) selected")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Button(selection.count == filtered.count ? "Deselect All" : "Select All") {
                if selection.count == filtered.count {
                    selection.removeAll()
                } else {
                    selection = Set(filtered.map(\.id))
                }
            }
            .font(.system(size: 12))

            Spacer(minLength: 0)

            Button {
                ArtifactShare.present(urls: selectedArtifacts.map { store.fileURL(for: $0) })
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Share")
            .disabled(selection.isEmpty)

            Button {
                store.exportToDirectory(selectedArtifacts)
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Export")
            .disabled(selection.isEmpty)

            Button(role: .destructive) {
                pendingDelete = selectedArtifacts
                isConfirmingDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete")
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
            filterChip(title: "All", isOn: kindFilter == nil && sourceFilter == nil) {
                kindFilter = nil
                sourceFilter = nil
            }

            ForEach(ArtifactKind.allCases) { kind in
                let count = store.artifacts.filter { $0.kind == kind }.count
                filterChip(title: "\(kind.pluralLabel) \(count)", systemImage: kind.systemImage, isOn: kindFilter == kind) {
                    kindFilter = kindFilter == kind ? nil : kind
                }
            }

            Divider().frame(height: 16)

            ForEach(ArtifactSource.allCases) { source in
                let count = store.artifacts.filter { $0.source == source }.count
                filterChip(title: "\(source.label) \(count)", systemImage: source.systemImage, isOn: sourceFilter == source) {
                    sourceFilter = sourceFilter == source ? nil : source
                }
            }

            Divider().frame(height: 16)

            filterChip(title: "Favorites", systemImage: favoritesOnly ? "star.fill" : "star", isOn: favoritesOnly) {
                favoritesOnly.toggle()
            }

            Menu {
                Picker("Date", selection: $dateFilter) {
                    ForEach(ArtifactDateFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(dateFilter == .all ? "Date" : dateFilter.rawValue)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(dateFilter != .all ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(dateFilter != .all ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: Capsule())
            }
            .menuIndicator(.hidden)
            .fixedSize()
                }
                .padding(.vertical, 2)
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                if smartSearchActive {
                    Circle()
                        .fill(Color.green.opacity(0.7))
                        .frame(width: 7, height: 7)
                        .help("Smart search is on")
                }
                TextField("Search name or prompt", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .frame(width: 200)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 6, x: -3, y: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .background(Color.nativMainContentBackground)
    }

    @ViewBuilder
    private func menu(for artifact: Artifact) -> some View {
        Button("Open Preview") { previewID = artifact.id }
        Button("Open in Default App") { store.open(artifact) }
        Divider()
        Button(store.isFavorite(artifact) ? "Remove from Favorites" : "Add to Favorites") {
            store.toggleFavorite(artifact)
        }
        Button("Rename…") {
            renameText = store.displayName(for: artifact)
            renameTarget = artifact
        }
        Divider()
        if artifact.kind == .image {
            Button("Use in Chat") { onUseInChat(artifact) }
            Button("Use as Image Reference") { onUseAsReference(artifact) }
        }
        Button("Go to Chat") { onOpenChat(artifact) }
        Divider()
        Button("Share…") { ArtifactShare.present(urls: [store.fileURL(for: artifact)]) }
        Button("Reveal in Finder") { store.revealInFinder(artifact) }
        Button("Export…") { store.export(artifact) }
        Button("Copy") { store.copyToPasteboard(artifact) }
        Divider()
        Button("Delete", role: .destructive) {
            pendingDelete = [artifact]
            isConfirmingDelete = true
        }
    }

    private func selectedFileURLs(including artifact: Artifact) -> [URL] {
        let ids = selection.contains(artifact.id) && !selection.isEmpty ? selection : [artifact.id]
        return store.artifacts
            .filter { ids.contains($0.id) }
            .map { store.fileURL(for: $0) }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !searchFocused else { return .ignored }
        let items = filtered
        guard !items.isEmpty else { return .ignored }
        let index = cursorID.flatMap { id in items.firstIndex { $0.id == id } }

        if press.modifiers.contains(.command), press.characters.lowercased() == "a" {
            isSelecting = true
            selection = Set(items.map(\.id))
            return .handled
        }

        switch press.key {
        case .leftArrow, .upArrow:
            cursorID = items[index.map { max(0, $0 - 1) } ?? 0].id
            return .handled
        case .rightArrow, .downArrow:
            cursorID = items[index.map { min(items.count - 1, $0 + 1) } ?? 0].id
            return .handled
        case .space, .return:
            if let cursorID {
                previewID = cursorID
            }
            return .handled
        case .delete:
            if let index {
                pendingDelete = [items[index]]
                isConfirmingDelete = true
            }
            return .handled
        default:
            return .ignored
        }
    }

    private func filterChip(title: String, systemImage: String? = nil, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOn ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: Capsule())
            .foregroundStyle(isOn ? .white : .primary)
            .overlay(
                Capsule().stroke(Color(nsColor: .separatorColor).opacity(isOn ? 0 : 1), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.system(size: 42))
                .foregroundStyle(.secondary.opacity(0.5))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var selectedArtifacts: [Artifact] {
        store.artifacts.filter { selection.contains($0.id) }
    }

    private func activate(_ artifact: Artifact) {
        if isSelecting {
            if selection.contains(artifact.id) {
                selection.remove(artifact.id)
            } else {
                selection.insert(artifact.id)
            }
        } else {
            previewID = artifact.id
        }
    }

    private static func bucketTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day {
            if days < 7 {
                return "This Week"
            }
            if days < 30 {
                return "This Month"
            }
        }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

private struct ArtifactDrag: ViewModifier {
    let store: ArtifactStore
    let artifact: Artifact
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag { store.dragProvider(for: artifact) }
        } else {
            content
        }
    }
}

enum ArtifactShare {
    @MainActor
    static func present(urls: [URL]) {
        guard !urls.isEmpty,
              let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let view = window.contentView else {
            return
        }
        let picker = NSSharingServicePicker(items: urls)
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }
}

private struct SelectionDrag: NSViewRepresentable {
    let onToggle: () -> Void
    let fileURLs: () -> [URL]

    func makeNSView(context: Context) -> NSView {
        SelectionDragNSView(onToggle: onToggle, fileURLs: fileURLs)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? SelectionDragNSView else { return }
        view.onToggle = onToggle
        view.fileURLs = fileURLs
    }
}

private final class SelectionDragNSView: NSView, NSDraggingSource {
    var onToggle: () -> Void
    var fileURLs: () -> [URL]
    private var mouseDownPoint: NSPoint?

    init(onToggle: @escaping () -> Void, fileURLs: @escaping () -> [URL]) {
        self.onToggle = onToggle
        self.fileURLs = fileURLs
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        guard (dx * dx + dy * dy) > 25 else { return }
        mouseDownPoint = nil
        let items = fileURLs().map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownPoint != nil {
            onToggle()
        }
        mouseDownPoint = nil
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }
}

struct ArtifactTile: View {
    let artifact: Artifact
    let store: ArtifactStore
    let isSelecting: Bool
    let isSelected: Bool
    let isFavorite: Bool
    var onInspect: () -> Void = {}
    var onToggleFavorite: () -> Void = {}

    @State private var isHovering = false

    var body: some View {
        ArtifactThumbnail(artifact: artifact, store: store, size: CGSize(width: 240, height: 165))
            .frame(height: 165)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [.clear, .white.opacity(0.16)],
                            center: .center,
                            startRadius: 60,
                            endRadius: 170
                        )
                    )
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if isHovering, !isSelecting {
                    Text(store.displayName(for: artifact))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(radius: 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(
                                colors: [.black.opacity(0.55), .clear],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    selectionMark.padding(8)
                } else if isHovering {
                    Button(action: onInspect) {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.white, .black.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                if !isSelecting, isHovering || isFavorite {
                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 14))
                            .foregroundStyle(isFavorite ? Color.yellow : Color.white, .black.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
    }

    private var selectionMark: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18))
            .foregroundStyle(isSelected ? Color.accentColor : Color.white)
            .background(Circle().fill(.black.opacity(0.35)))
    }
}

struct ArtifactRow: View {
    let artifact: Artifact
    let store: ArtifactStore
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }

            ArtifactThumbnail(artifact: artifact, store: store, size: CGSize(width: 44, height: 44))
                .frame(width: 44, height: 44)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.filename)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(artifact.typeLabel) · \(artifact.source.label)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(Int64(artifact.byteSize).formatted(.byteCount(style: .file)))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)

            Text(artifact.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private struct ArtifactThumbnail: View {
    let artifact: Artifact
    let store: ArtifactStore
    let size: CGSize

    @State private var image: NSImage?
    @State private var textPreview: String?

    static let textPreviewExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt", "text", "log", "json", "csv", "tsv",
        "py", "js", "ts", "jsx", "tsx", "swift", "java", "kt", "c", "cpp", "cc", "h",
        "hpp", "rb", "go", "rs", "sh", "bash", "zsh", "php", "html", "htm", "css",
        "scss", "xml", "yaml", "yml", "toml",
    ]

    private var isTextDocument: Bool {
        artifact.kind == .document
            && Self.textPreviewExtensions.contains(artifact.fileExtension.lowercased())
    }

    var body: some View {
        Group {
            if isTextDocument, let textPreview {
                textCard(textPreview)
            } else if let image {
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: artifact.id) {
            if isTextDocument {
                textPreview = await store.textPreview(for: artifact)
            } else {
                image = await store.thumbnail(for: artifact, size: size)
            }
        }
    }

    private func textCard(_ text: String) -> some View {
        ZStack(alignment: .bottom) {
            Color(nsColor: .textBackgroundColor)
            Text(text)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineSpacing(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
            LinearGradient(
                colors: [Color(nsColor: .textBackgroundColor).opacity(0), Color(nsColor: .textBackgroundColor)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 44)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            FileTypeIcon(fileExtension: artifact.fileExtension, size: 20).padding(6)
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if artifact.kind == .document {
                VStack(spacing: 8) {
                    FileTypeIcon(fileExtension: artifact.fileExtension, size: min(size.width, size.height) * 0.42)
                    Text(FileTypeStyle.resolve(fileExtension: artifact.fileExtension).label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: artifact.kind == .video ? "play.circle.fill" : artifact.kind.systemImage)
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    if !artifact.fileExtension.isEmpty {
                        Text(artifact.fileExtension)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct ArtifactInspector: View {
    let artifact: Artifact
    let store: ArtifactStore
    let onOpenPreview: () -> Void
    let onGoToChat: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Details")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ArtifactThumbnail(artifact: artifact, store: store, size: CGSize(width: 340, height: 200))
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 8) {
                        detailRow("Name", artifact.filename)
                        detailRow("Type", artifact.typeLabel)
                        detailRow("Source", artifact.source.label)
                        detailRow("Size", Int64(artifact.byteSize).formatted(.byteCount(style: .file)))
                        detailRow("Created", artifact.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if let prompt = artifact.prompt, !prompt.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Prompt")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Text(prompt)
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    VStack(spacing: 8) {
                        action("Open Preview", "arrow.up.left.and.arrow.down.right", onOpenPreview)
                        action(artifact.source == .generated ? "Go to Image Session" : "Go to Chat", "bubble.left.and.bubble.right", onGoToChat)
                        action("Reveal in Finder", "folder", { store.revealInFinder(artifact) })
                        action("Export…", "square.and.arrow.down", { store.export(artifact) })
                        action("Copy", "doc.on.doc", { store.copyToPasteboard(artifact) })
                    }
                }
                .padding()
            }
        }
        .frame(width: 380, height: 540)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func action(_ title: String, _ icon: String, _ handler: @escaping () -> Void) -> some View {
        Button(action: handler) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }
}

struct ChatDeck: View {
    let group: ArtifactGroup
    let store: ArtifactStore
    let onOpen: () -> Void

    @State private var frontIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                ZStack {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, artifact in
                        let depth = (index - frontIndex + group.items.count) % group.items.count
                        if depth <= 3 {
                            deckCard(
                                artifact,
                                offset: CGFloat(min(depth, 2)) * 6,
                                rotation: Double(min(depth, 2)) * 3,
                                opacity: depth <= 2 ? 1 - Double(depth) * 0.28 : 0
                            )
                            .overlay(alignment: .topTrailing) {
                                if depth == 0 {
                                    countBadge
                                }
                            }
                            .zIndex(Double(group.items.count - depth))
                            .allowsHitTesting(depth == 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.spring(response: 0.34, dampingFraction: 0.72), value: frontIndex)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard case .active(let location) = phase, group.items.count > 1 else {
                        return
                    }
                    let ratio = max(0, min(1, location.x / geo.size.width))
                    frontIndex = min(group.items.count - 1, Int(ratio * CGFloat(group.items.count)))
                }
                .onTapGesture(perform: onOpen)
                .onDrag { store.dragProvider(for: group.items[min(frontIndex, group.items.count - 1)]) }
            }
            .frame(height: 190)

            Text(group.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text("\(group.items.count) \(group.items.count == 1 ? "item" : "items")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func deckCard(_ artifact: Artifact, offset: CGFloat, rotation: Double, opacity: Double) -> some View {
        ArtifactThumbnail(artifact: artifact, store: store, size: CGSize(width: 220, height: 190))
            .frame(width: 168, height: 190)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.75), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .rotationEffect(.degrees(rotation))
            .offset(x: offset, y: -offset / 2)
            .opacity(opacity)
    }

    private var countBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "square.on.square")
            Text("\(group.items.count)")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor, in: Capsule())
        .padding(8)
    }
}

struct ArtifactAlbum: View {
    let title: String
    let artifacts: [Artifact]
    let store: ArtifactStore
    let onOpen: (Artifact) -> Void
    let onGoToChat: (Artifact) -> Void
    let onInspect: (Artifact) -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                HStack {
                    Button(action: onClose) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    Spacer()
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if let first = artifacts.first {
                        Button("Go to Chat") { onGoToChat(first) }
                    }
                }
                .padding()
                Divider()

                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(artifacts) { artifact in
                            ArtifactThumbnail(artifact: artifact, store: store, size: CGSize(width: 190, height: 140))
                                .frame(height: 140)
                                .frame(maxWidth: .infinity)
                                .background(Color(nsColor: .textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        onInspect(artifact)
                                    } label: {
                                        Image(systemName: "ellipsis.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white, .black.opacity(0.4))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Details")
                                    .padding(6)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { onOpen(artifact) }
                                .onDrag { store.dragProvider(for: artifact) }
                        }
                    }
                    .padding(20)
                }
            }
            .frame(width: 720, height: 560)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(radius: 30)
        }
    }
}
