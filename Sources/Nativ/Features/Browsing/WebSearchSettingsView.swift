import AppKit
import SwiftUI

@MainActor
final class WebBrowsingSettingsViewModel: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connected
        case issue(WebSearchCredentialIssue)
    }

    enum Status: Equatable {
        case connected(String)
        case failure(String)
    }

    @Published var selectedProvider: WebSearchProvider
    @Published private(set) var selectedCapability: WebBrowsingCapability
    @Published private(set) var searchProvider: WebSearchProvider
    @Published private(set) var pageReaderProvider: WebSearchProvider?
    @Published var draftAPIKey = ""
    @Published var revealsKey = false
    @Published private(set) var isTesting = false
    @Published private(set) var status: Status?
    @Published private(set) var connectionStates: [WebSearchProvider: ConnectionState] = [:]

    private let preferences: WebBrowsingPreferences
    private let credentials: any WebSearchCredentialStoring
    private let service: WebSearchService

    init(
        initialCapability: WebBrowsingCapability = .search,
        preferences: WebBrowsingPreferences = WebBrowsingPreferences(),
        credentials: any WebSearchCredentialStoring = KeychainWebSearchCredentialStore(),
        service: WebSearchService = WebSearchService()
    ) {
        self.preferences = preferences
        self.credentials = credentials
        self.service = service
        selectedCapability = initialCapability
        selectedProvider = preferences.searchProvider
        searchProvider = preferences.searchProvider
        pageReaderProvider = preferences.pageReaderProvider
        refreshConnectionStates()
        select(initialCapability)
    }

    var selectedConnectionState: ConnectionState {
        connectionStates[selectedProvider] ?? .disconnected
    }

    var canConnect: Bool {
        !isTesting && !draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func select(_ provider: WebSearchProvider) {
        guard !isTesting else { return }
        selectedProvider = provider
        draftAPIKey = ""
        revealsKey = false
        status = nil
    }

    func select(_ capability: WebBrowsingCapability) {
        guard !isTesting else { return }
        selectedCapability = capability
        switch capability {
        case .search:
            select(searchProvider)
        case .read:
            select(
                resolvedPageReaderProvider
                    ?? WebSearchProvider.pageReaders.first { hasCredential(for: $0) }
                    ?? .exa
            )
        }
    }

    private var initialPageReaderProvider: WebSearchProvider {
        // Prefer the actually-configured page reader, then the saved choice,
        // so opening or switching to "Page reading" doesn't reset to Exa and
        // route a newly entered key to the wrong provider.
        resolvedPageReaderProvider
            ?? pageReaderProvider
            ?? WebSearchProvider.pageReaders.first
            ?? .exa
    }
    var availableProviders: [WebSearchProvider] {
        switch selectedCapability {
        case .search:
            WebSearchProvider.allCases
        case .read:
            WebSearchProvider.pageReaders
        }
    }

    func setSearchProvider(_ provider: WebSearchProvider) {
        guard !isTesting else { return }
        searchProvider = provider
        preferences.searchProvider = provider
        select(provider)
        notifyConfigurationChanged()
    }

    func setPageReaderProvider(_ provider: WebSearchProvider?) {
        guard !isTesting, provider?.supports(.read) != false else { return }
        pageReaderProvider = provider
        preferences.pageReaderProvider = provider
        if let provider {
            select(provider)
        }
        notifyConfigurationChanged()
    }

    func testAndConnect() async -> Bool {
        let apiKey = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !isTesting else { return false }
        let provider = selectedProvider
        let hadConfiguredSearch = hasCredential(for: searchProvider)
        let hadConfiguredReader = resolvedPageReaderProvider.map {
            hasCredential(for: $0)
        } ?? false
        isTesting = true
        status = nil

        defer { isTesting = false }
        do {
            try await service.validateCredential(provider: provider, apiKey: apiKey)
            try credentials.save(apiKey, for: provider)
            preferences.setCredentialIssue(nil, for: provider)
            connectionStates[provider] = .connected
            switch selectedCapability {
            case .search where !hadConfiguredSearch:
                searchProvider = provider
                preferences.searchProvider = provider
            case .read where !hadConfiguredReader:
                pageReaderProvider = provider
                preferences.pageReaderProvider = provider
            default:
                break
            }
            if selectedProvider == provider {
                draftAPIKey = ""
                revealsKey = false
                status = .connected("Connected to \(provider.metadata.displayName).")
            }
            notifyConfigurationChanged()
            return true
        } catch {
            if selectedProvider == provider {
                status = .failure(error.localizedDescription)
            }
            return false
        }
    }

    var resolvedPageReaderProvider: WebSearchProvider? {
        preferences.provider(for: .read)
    }

    var pageReaderStatus: String? {
        guard resolvedPageReaderProvider == selectedProvider else {
            switch selectedConnectionState {
            case .disconnected:
                return "Connect \(selectedProvider.metadata.displayName) to enable page reading."
            case .connected:
                return "Use \(selectedProvider.metadata.displayName) for page reading."
            case .issue:
                return "\(selectedProvider.metadata.displayName) needs attention before it can read pages."
            }
        }
        switch selectedConnectionState {
        case .connected:
            return nil
        case .disconnected:
            return "Connect \(selectedProvider.metadata.displayName) to enable page reading."
        case .issue:
            return "\(selectedProvider.metadata.displayName) needs attention before it can read pages."
        }
    }

    func removeKey() -> Bool {
        let provider = selectedProvider
        do {
            try credentials.remove(for: provider)
            preferences.setCredentialIssue(nil, for: provider)
            connectionStates[provider] = .disconnected
            draftAPIKey = ""
            revealsKey = false
            status = nil
            notifyConfigurationChanged()
            return true
        } catch {
            status = .failure(error.localizedDescription)
            return false
        }
    }

    func refreshConnectionStates() {
        connectionStates.removeAll(keepingCapacity: true)
        for provider in WebSearchProvider.allCases {
            do {
                guard try credentials.load(for: provider) != nil else {
                    connectionStates[provider] = .disconnected
                    continue
                }
                if let issue = preferences.credentialIssue(for: provider) {
                    connectionStates[provider] = .issue(issue)
                } else {
                    connectionStates[provider] = .connected
                }
            } catch {
                connectionStates[provider] = .disconnected
                if provider == selectedProvider {
                    status = .failure("Nativ could not read this provider’s API key from Keychain.")
                }
            }
        }
    }

    private func hasCredential(for provider: WebSearchProvider) -> Bool {
        switch connectionStates[provider] ?? .disconnected {
        case .connected, .issue:
            true
        case .disconnected:
            false
        }
    }

    private func notifyConfigurationChanged() {
        NotificationCenter.default.post(name: .webBrowsingConfigurationDidChange, object: nil)
    }
}

@MainActor
struct WebBrowsingSettingsView: View {
    @StateObject private var viewModel: WebBrowsingSettingsViewModel
    private let showsCapabilityPicker: Bool
    private let onConfigurationChanged: (Bool) -> Void

    init(
        initialCapability: WebBrowsingCapability = .search,
        showsCapabilityPicker: Bool = false,
        onConfigurationChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _viewModel = StateObject(
            wrappedValue: WebBrowsingSettingsViewModel(initialCapability: initialCapability)
        )
        self.showsCapabilityPicker = showsCapabilityPicker
        self.onConfigurationChanged = onConfigurationChanged
    }

    init(
        viewModel: WebBrowsingSettingsViewModel,
        showsCapabilityPicker: Bool = false,
        onConfigurationChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.showsCapabilityPicker = showsCapabilityPicker
        self.onConfigurationChanged = onConfigurationChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsCapabilityPicker {
                capabilityPicker
            }
            HStack(alignment: .top, spacing: 16) {
                providerPicker
                    .frame(width: 270)
                keySetup
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .webBrowsingConfigurationDidChange)) { _ in
            viewModel.refreshConnectionStates()
        }
    }

    private var capabilityPicker: some View {
        Picker(
            "Browsing capability",
            selection: Binding(
                get: { viewModel.selectedCapability },
                set: { viewModel.select($0) }
            )
        ) {
            Text("Search").tag(WebBrowsingCapability.search)
            Text("Page reading").tag(WebBrowsingCapability.read)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240)
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Providers")
                .font(.system(size: 13, weight: .semibold))

            ForEach(viewModel.availableProviders) { provider in
                providerRow(provider)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func providerRow(_ provider: WebSearchProvider) -> some View {
        HStack(spacing: 4) {
            Button {
                viewModel.select(provider)
                if viewModel.selectedConnectionState == .connected {
                    onConfigurationChanged(true)
                }
            } label: {
                HStack(spacing: 10) {
                    ProviderLogo(provider: provider, size: 24)
                    Text(provider.metadata.displayName)
                        .font(.system(
                            size: 12,
                            weight: provider == viewModel.selectedProvider ? .semibold : .regular
                        ))
                    Spacer(minLength: 0)
                    routeIndicators(for: provider)
                    connectionIndicator(for: provider)
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.vertical, 7)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isTesting)

            Link(destination: provider.metadata.apiKeySetupURL) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open \(provider.metadata.displayName) API key setup")
            .accessibilityLabel("Open \(provider.metadata.displayName) API key setup")
        }
        .background(
            provider == viewModel.selectedProvider ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    @ViewBuilder
    private func routeIndicators(for provider: WebSearchProvider) -> some View {
        switch viewModel.selectedCapability {
        case .search:
            if viewModel.searchProvider == provider {
                routeBadge("Active")
            }
        case .read:
            if viewModel.resolvedPageReaderProvider == provider {
                routeBadge("Active")
            }
        }
    }

    private func routeBadge(_ text: String) -> some View {
        NativStatusBadge(text: text, tone: .active)
    }

    @ViewBuilder
    private func connectionIndicator(for provider: WebSearchProvider) -> some View {
        switch viewModel.connectionStates[provider] ?? .disconnected {
        case .disconnected:
            EmptyView()
        case .connected:
            NativStatusDot(tone: .success, diameter: 6)
                .help("Connected")
                .accessibilityLabel("Connected")
        case .issue:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(NativStatusTone.warning.color)
                .help("This connection needs attention")
                .accessibilityLabel("Connection needs attention")
        }
    }

    private var keySetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.selectedProvider.metadata.displayName)
                .font(.system(size: 13, weight: .semibold))

            routingActions

            HStack(spacing: 8) {
                keyField
                Button { viewModel.revealsKey.toggle() } label: {
                    Image(systemName: viewModel.revealsKey ? "eye.slash" : "eye")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(viewModel.revealsKey ? "Hide API key" : "Show API key")
            }

            HStack {
                Button(viewModel.isTesting ? "Testing…" : "Test & Connect") {
                    Task {
                        if await viewModel.testAndConnect() {
                            onConfigurationChanged(true)
                        }
                    }
                }
                .disabled(!viewModel.canConnect)

                if viewModel.selectedConnectionState != .disconnected {
                    Button("Remove Key", role: .destructive) {
                        if viewModel.removeKey() {
                            onConfigurationChanged(false)
                        }
                    }
                    .disabled(viewModel.isTesting)
                }
                Spacer()
            }

            statusView

            if viewModel.selectedCapability == .read,
               let status = viewModel.pageReaderStatus {
                Label(status, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            Text("Browsing requests are sent to the selected third-party providers. API keys stay in Keychain.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var routingActions: some View {
        HStack(spacing: 8) {
            switch viewModel.selectedCapability {
            case .search:
                if viewModel.searchProvider == viewModel.selectedProvider {
                    Label("Search", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Use for Search") {
                        viewModel.setSearchProvider(viewModel.selectedProvider)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            case .read:
                if viewModel.resolvedPageReaderProvider == viewModel.selectedProvider {
                    Label("Page reading", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Use for Page Reading") {
                        let provider = viewModel.selectedProvider
                        viewModel.setPageReaderProvider(
                            provider == viewModel.searchProvider ? nil : provider
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .disabled(
            viewModel.isTesting
                || viewModel.selectedConnectionState == .disconnected
        )
    }

    @ViewBuilder
    private var keyField: some View {
        let prompt = "Enter \(viewModel.selectedProvider.metadata.displayName) API key"
        if viewModel.revealsKey {
            TextField(prompt, text: $viewModel.draftAPIKey)
                .textFieldStyle(.roundedBorder)
        } else {
            SecureField(prompt, text: $viewModel.draftAPIKey)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var keyFieldPrompt: String {
        let provider = viewModel.selectedProvider.metadata.displayName
        switch viewModel.selectedConnectionState {
        case .disconnected:
            return "Enter \(provider) API key"
        case .connected:
            return "Enter a new key to replace the saved \(provider) key"
        case .issue:
            return "Enter a new \(provider) API key"
        }
    }

    private var connectionActionTitle: String {
        if viewModel.isTesting {
            return "Testing…"
        }
        switch viewModel.selectedConnectionState {
        case .disconnected:
            return "Test & Connect"
        case .connected:
            return "Test & Replace"
        case .issue:
            return "Test & Reconnect"
        }
    }
    @ViewBuilder
    private var statusView: some View {
        if let status = viewModel.status {
            switch status {
            case .connected(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        } else {
            switch viewModel.selectedConnectionState {
            case .disconnected:
                EmptyView()
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            case .issue(let issue):
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct ProviderLogo: View {
    let provider: WebSearchProvider
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(
                        provider.metadata.rendersLogoAsTemplate ? .template : .original
                    )
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
    }

    private var image: NSImage? {
        Bundle.main.url(
            forResource: provider.metadata.logoResourceName,
            withExtension: "png"
        ).flatMap(NSImage.init(contentsOf:))
    }
}

private extension WebSearchCredentialIssue {
    var message: String {
        switch self {
        case .invalidAuthentication:
            "Replace this provider’s API key."
        case .insufficientFunds:
            "This provider needs additional credits."
        case .planAccess:
            "This provider’s plan does not allow API search."
        }
    }
}
