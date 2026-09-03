import Foundation
import Observation
import SwiftUI

struct NativExtensionCatalogDocument: Decodable, Sendable {
    let schemaVersion: Int
    let extensions: [NativExtensionCatalogEntry]
}

struct NativExtensionCatalogEntry: Decodable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let summary: String
    let developer: String
    let version: String
    let category: String
    let systemImage: String
    let status: Status

    enum Status: String, Decodable, Sendable {
        case preview
        case available

        var title: String {
            switch self {
            case .preview: "Preview"
            case .available: "Available"
            }
        }
    }
}

@MainActor
@Observable
final class NativExtensionCatalogStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    private(set) var entries: [NativExtensionCatalogEntry] = []
    private(set) var phase: Phase = .idle
    var query = ""

    var filteredEntries: [NativExtensionCatalogEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return entries }
        return entries.filter {
            $0.displayName.localizedStandardContains(trimmedQuery)
                || $0.summary.localizedStandardContains(trimmedQuery)
                || $0.category.localizedStandardContains(trimmedQuery)
        }
    }

    func load() async {
        guard phase == .idle else { return }
        await refresh()
    }

    func refresh() async {
        phase = .loading
        do {
            entries = try await fetchRemoteCatalog()
            phase = .loaded
        } catch {
            guard let bundledEntries = loadBundledCatalog() else {
                phase = .failed
                return
            }
            entries = bundledEntries
            phase = .loaded
        }
    }

    private func fetchRemoteCatalog() async throws -> [NativExtensionCatalogEntry] {
        let url = URL(
            string: "https://blaizzy.github.io/nativ/extensions/catalog.json"
        )!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try decode(data)
    }

    private func loadBundledCatalog() -> [NativExtensionCatalogEntry]? {
        guard let url = Bundle.main.url(
            forResource: "NativExtensionCatalog",
            withExtension: "json"
        ), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decode(data)
    }

    private func decode(_ data: Data) throws -> [NativExtensionCatalogEntry] {
        let document = try JSONDecoder().decode(NativExtensionCatalogDocument.self, from: data)
        guard document.schemaVersion == 1 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unsupported extension catalog schema")
            )
        }
        return document.extensions
    }
}

struct NativExtensionMarketplaceView: View {
    @State private var store = NativExtensionCatalogStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchField
            content
        }
        .task {
            await store.load()
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Nativ MarketPlace", text: $store.query)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ProgressView("Loading extensions…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        case .failed:
            VStack(spacing: 10) {
                Text("The extension marketplace could not be loaded.")
                    .nativTextStyle(.supporting)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    Task { await store.refresh() }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        case .loaded:
            if store.filteredEntries.isEmpty {
                VStack(spacing: 14) {
                    HubEmptyHint(
                        icon: store.entries.isEmpty ? "square.grid.2x2" : "magnifyingglass",
                        text: store.entries.isEmpty
                            ? "The Nativ MarketPlace is opening soon. Reviewed extensions will appear here."
                            : "No extensions match your search."
                    )
                    Link(
                        "Open Nativ MarketPlace",
                        destination: URL(string: "https://blaizzy.github.io/nativ/extensions/")!
                    )
                    .controlSize(.small)
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(store.filteredEntries) { entry in
                        NativExtensionMarketplaceCard(entry: entry)
                    }
                }
            }
        }
    }
}

private struct NativExtensionMarketplaceCard: View {
    let entry: NativExtensionCatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                NativTintedIconTile(symbol: entry.systemImage, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.displayName)
                        .nativTextStyle(.compactCardTitle)
                    Text(entry.category)
                        .nativTextStyle(.metadata)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                NativStatusBadge(text: entry.status.title, tone: .active)
            }

            Text(entry.summary)
                .nativTextStyle(.supporting)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("By \(entry.developer) · Version \(entry.version)")
                    .nativTextStyle(.metadata)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Link(
                    "View on Web",
                    destination: URL(string: "https://blaizzy.github.io/nativ/extensions/")!
                )
                .controlSize(.small)
            }
        }
        .padding(16)
        .background(
            Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }
}
