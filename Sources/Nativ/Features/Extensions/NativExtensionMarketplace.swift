import Foundation
import NativExtensionSDK
import Observation
import SwiftUI

@MainActor
@Observable
final class NativExtensionCatalogStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded([NativExtensionCatalogEntry])
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    var query = ""

    var entries: [NativExtensionCatalogEntry] {
        guard case .loaded(let entries) = phase else { return [] }
        return entries
    }

    var filteredEntries: [NativExtensionCatalogEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return entries }
        return entries.filter {
            $0.displayName.localizedStandardContains(trimmedQuery)
                || $0.summary.localizedStandardContains(trimmedQuery)
                || $0.category.rawValue.localizedStandardContains(trimmedQuery)
        }
    }

    func refresh(catalogURLOverride: String) async {
        let usesProductionCatalog = catalogURLOverride
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        phase = .loading
        do {
            let sourceURL = try NativExtensionCatalogPreferences.sourceURL(
                override: catalogURLOverride
            )
            let catalog = try await NativExtensionCatalogClient().fetch(from: sourceURL)
            try Task.checkCancellation()
            phase = .loaded(catalog.extensions)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            guard usesProductionCatalog,
                  let bundledEntries = loadBundledCatalog() else {
                phase = .failed(error.localizedDescription)
                return
            }
            phase = .loaded(bundledEntries)
        }
    }

    private func loadBundledCatalog() -> [NativExtensionCatalogEntry]? {
        guard let url = Bundle.main.url(
            forResource: "NativExtensionCatalog",
            withExtension: "json"
        ), let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let catalog = try? JSONDecoder().decode(NativExtensionCatalog.self, from: data),
              (try? NativExtensionCatalogValidator.validate(
                  catalog,
                  sourceURL: NativExtensionCatalogPreferences.productionURL
              )) != nil else {
            return nil
        }
        return catalog.extensions
    }
}

struct NativExtensionMarketplaceView: View {
    @State private var store = NativExtensionCatalogStore()
    @AppStorage(NativExtensionCatalogPreferences.overrideKey)
    private var catalogURLOverride = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchField
            content
        }
        .task(id: catalogURLOverride) {
            await store.refresh(catalogURLOverride: catalogURLOverride)
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
        case .failed(let message):
            VStack(spacing: 10) {
                Text(message)
                    .nativTextStyle(.supporting)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    Task {
                        await store.refresh(catalogURLOverride: catalogURLOverride)
                    }
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
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.displayName)
                        .nativTextStyle(.compactCardTitle)
                    Text(entry.category.rawValue)
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
                    destination: entry.homepage
                        ?? URL(string: "https://blaizzy.github.io/nativ/extensions/")!
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

private extension NativExtensionCatalogEntry.Status {
    var title: String {
        switch self {
        case .preview: "Preview"
        case .available: "Available"
        }
    }
}
