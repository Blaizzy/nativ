import AppKit
import SwiftUI

struct BrowsingSectionView: View {
    var body: some View {
        HubSectionScaffold(
            title: "Browsing",
            subtitle: "Choose a provider and connect the API key that web search uses."
        ) {
            EmptyView()
        } content: {
            BrowsingSettingsView()
        }
    }
}

struct BrowsingSettingsView: View {
    @State private var selectedProvider = BrowsingProviderSettings.active
    @State private var apiKey = BrowsingCredentials.load(for: BrowsingProviderSettings.active) ?? ""
    @State private var revealsKey = false
    @State private var isTesting = false
    @State private var status: Status?

    private enum Status {
        case connected
        case failure(String)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            providerPicker
                .frame(width: 238)
            keySetup
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Providers")
                .font(.system(size: 13, weight: .semibold))

            ForEach(BrowsingProvider.allCases) { provider in
                Button { select(provider) } label: {
                    HStack(spacing: 10) {
                        ProviderLogo(provider: provider, size: 24)
                        Text(provider.name)
                            .font(.system(size: 12, weight: provider == selectedProvider ? .semibold : .regular))
                        Spacer(minLength: 0)
                        if BrowsingProviderSettings.isVerified(provider) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        provider == selectedProvider ? Color.accentColor.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var keySetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                keyField
                Button { revealsKey.toggle() } label: {
                    Image(systemName: revealsKey ? "eye.slash" : "eye")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(revealsKey ? "Hide API key" : "Show API key")
            }

            HStack {
                Button(isTesting ? "Testing…" : "Test & connect") { testAndConnect() }
                    .disabled(isTesting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if BrowsingCredentials.load(for: selectedProvider) != nil {
                    Button("Remove key", role: .destructive, action: removeKey)
                        .disabled(isTesting)
                }
                Spacer()
            }

            statusView
        }
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var keyField: some View {
        if revealsKey {
            TextField("API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
        } else {
            SecureField("API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if let status {
            switch status {
            case .connected:
                Label("Connected to \(selectedProvider.name).", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private func select(_ provider: BrowsingProvider) {
        selectedProvider = provider
        apiKey = BrowsingCredentials.load(for: provider) ?? ""
        revealsKey = false
        status = nil
    }

    private func testAndConnect() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isTesting = true
        status = nil
        Task {
            do {
                try await BrowsingSearchService.test(provider: selectedProvider, apiKey: key)
                try BrowsingCredentials.save(key, for: selectedProvider)
                BrowsingProviderSettings.setActive(selectedProvider)
                BrowsingProviderSettings.markVerified(selectedProvider, verified: true)
                apiKey = ""
                revealsKey = false
                status = .connected
            } catch {
                BrowsingProviderSettings.markVerified(selectedProvider, verified: false)
                status = .failure(error.localizedDescription)
            }
            isTesting = false
        }
    }

    private func removeKey() {
        do {
            try BrowsingCredentials.remove(for: selectedProvider)
            apiKey = ""
            revealsKey = false
            status = nil
        } catch {
            status = .failure(error.localizedDescription)
        }
    }
}

private struct ProviderLogo: View {
    let provider: BrowsingProvider
    let size: CGFloat

    var body: some View {
        Group {
            if let image = NSImage(contentsOf: logoURL) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
    }

    private var logoURL: URL {
        Bundle.main.resourceURL!
            .appendingPathComponent("Browsing/Assets/\(provider.logoFileName).png")
    }
}
