import AppKit
import SwiftUI

enum ArtifactLayout {
    case grid
    case list
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
    let onOpenChat: (Artifact) -> Void
    let onUseInChat: (Artifact) -> Void
    let onUseAsReference: (Artifact) -> Void

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

    private var filtered: [Artifact] {
        let query = search.lowercased()
        var result = store.artifacts
        if let kindFilter {
            result = result.filter { $0.kind == kindFilter }
        }
        if let sourceFilter {
            result = result.filter { $0.source == sourceFilter }
        }
        if !query.isEmpty {
            result = result.filter { $0.searchText.contains(query) }
        }
        return result.sorted(by: sort.comparator)
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

    var body: some View {
        VStack(spacing: 0) {
            header
            if isSelecting {
                selectionBar
            }
            filterBar
            Divider()
            contentView
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
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("This removes the file from the artifact and from its chat history. It can't be undone.")
        }
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

    private func grid(_ artifacts: [Artifact]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 172, maximum: 220), spacing: 14)],
            spacing: 14
        ) {
            ForEach(artifacts) { artifact in
                ArtifactTile(
                    artifact: artifact,
                    store: store,
                    isSelecting: isSelecting,
                    isSelected: selection.contains(artifact.id)
                )
                .onTapGesture { activate(artifact) }
                .modifier(ArtifactDrag(store: store, artifact: artifact, enabled: !isSelecting))
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Artifacts")
                    .font(.system(size: 20, weight: .semibold))
                Text("\(filtered.count) \(filtered.count == 1 ? "item" : "items")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(isSelecting ? "Done" : "Select") {
                isSelecting.toggle()
                if !isSelecting {
                    selection.removeAll()
                }
            }

            Picker("", selection: $sort) {
                ForEach(ArtifactSort.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            Picker("", selection: $layout) {
                Image(systemName: "square.grid.2x2").tag(ArtifactLayout.grid)
                Image(systemName: "list.bullet").tag(ArtifactLayout.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 84)

            Button(action: store.refresh) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: store.isRefreshing)
            }
            .help("Rescan chats for new artifacts")
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
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
                store.exportToDirectory(selectedArtifacts)
            } label: {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            .disabled(selection.isEmpty)

            Button(role: .destructive) {
                pendingDelete = selectedArtifacts
                isConfirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            filterChip(title: "All", isOn: kindFilter == nil && sourceFilter == nil) {
                kindFilter = nil
                sourceFilter = nil
            }

            ForEach(ArtifactKind.allCases) { kind in
                filterChip(title: kind.pluralLabel, systemImage: kind.systemImage, isOn: kindFilter == kind) {
                    kindFilter = kindFilter == kind ? nil : kind
                }
            }

            Divider().frame(height: 16)

            ForEach(ArtifactSource.allCases) { source in
                filterChip(title: source.label, systemImage: source.systemImage, isOn: sourceFilter == source) {
                    sourceFilter = sourceFilter == source ? nil : source
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search name or prompt", text: $search)
                    .textFieldStyle(.plain)
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
        .background(.bar)
    }

    @ViewBuilder
    private func menu(for artifact: Artifact) -> some View {
        Button("Open Preview") { previewID = artifact.id }
        Button("Open in Default App") { store.open(artifact) }
        Divider()
        if artifact.kind == .image {
            Button("Use in Chat") { onUseInChat(artifact) }
            Button("Use as Image Reference") { onUseAsReference(artifact) }
        }
        Button("Go to Chat") { onOpenChat(artifact) }
        Divider()
        Button("Reveal in Finder") { store.revealInFinder(artifact) }
        Button("Export…") { store.export(artifact) }
        Button("Copy") { store.copyToPasteboard(artifact) }
        Divider()
        Button("Delete", role: .destructive) {
            pendingDelete = [artifact]
            isConfirmingDelete = true
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

struct ArtifactTile: View {
    let artifact: Artifact
    let store: ArtifactStore
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtifactThumbnail(artifact: artifact, store: store, size: CGSize(width: 200, height: 132))
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    sourceBadge.padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    typeBadge.padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        selectionMark.padding(6)
                    }
                }

            Text(artifact.filename)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            HStack(spacing: 4) {
                Text(Int64(artifact.byteSize).formatted(.byteCount(style: .file)))
                Spacer(minLength: 0)
                Text(artifact.createdAt.formatted(date: .abbreviated, time: .omitted))
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 0.5)
        )
        .contentShape(Rectangle())
    }

    private var sourceBadge: some View {
        Image(systemName: artifact.source.systemImage)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(5)
            .background(artifact.source == .generated ? Color.accentColor : Color.black.opacity(0.55), in: Circle())
            .help(artifact.source.label)
    }

    private var typeBadge: some View {
        Text(artifact.fileExtension.isEmpty ? artifact.kind.label.uppercased() : artifact.fileExtension)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.6), in: Capsule())
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

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .clipped()
        .task(id: artifact.id) {
            image = await store.thumbnail(for: artifact, size: size)
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
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
