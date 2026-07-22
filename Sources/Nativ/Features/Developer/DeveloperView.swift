import AppKit
import Darwin
import NativServerKit
import SwiftUI

struct DeveloperView: View {
    private static let configurationToggleClearance: CGFloat = 36

    @ObservedObject var model: NativModel
    @ObservedObject var runtime: SystemRuntimeMonitor
    @Binding var showsConfiguration: Bool
    @State private var logQuery = ""
    @State private var logLevelFilter: LogLevelFilter = .all
    @State private var selectedEndpointCategory: ServerEndpointCategory = .openAI
    @State private var isSelectedPortAvailable = true

    var body: some View {
        ModelConfigurationLayout(
            model: model,
            isConfigurationVisible: $showsConfiguration
        ) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        pageHeader
                        runtimeGrid
                        serverEndpointsPanel
                        huggingFaceAuthenticationPanel
                        logPanel
                            .frame(height: max(320, geometry.size.height - 550))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .padding(.bottom, 22)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Developer")
                    .font(.title2.weight(.semibold))
                Text("Runtime diagnostics, Hub authentication, API endpoints, and live server output.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(model.isRunning ? "Live" : "Offline", systemImage: "circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.isRunning ? .green : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.secondary.opacity(0.10)))
        }
        .padding(.trailing, Self.configurationToggleClearance)
    }

    private var runtimeGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 165), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            RuntimeInfoCard(
                value: runtime.chipName,
                systemImage: "cpu",
                tint: .blue
            )

            RuntimeInfoCard(
                value: "\(byteCount(runtime.usedMemoryBytes)) of \(byteCount(runtime.totalMemoryBytes))",
                systemImage: "memorychip",
                tint: memoryUsageTint,
                progress: runtime.memoryUsageFraction,
                progressLabel: "\(memoryUsagePercent)%"
            )

            RuntimeInfoCard(
                value: "macOS \(runtime.macOSVersion)",
                systemImage: "macbook",
                tint: .teal
            )

            RuntimeInfoCard(
                value: "mlx-vlm \(runtime.mlxVLMVersion)",
                systemImage: "shippingbox",
                tint: .orange
            )
        }
    }

    private var logPanel: some View {
        let output = LogOutput.filtered(
            model.logText,
            query: logQuery,
            level: logLevelFilter
        )

        return VStack(spacing: 0) {
            logPanelToolbar(output)

            Divider()

            ZStack {
                LogTextView(text: output.text, searchQuery: logQuery)

                if model.logText.isEmpty {
                    ContentUnavailableView(
                        "No server output",
                        systemImage: "terminal",
                        description: Text("Server logs will appear here as they arrive.")
                    )
                } else if output.visibleLineCount == 0 {
                    ContentUnavailableView(
                        "No matching logs",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Try another search or severity filter.")
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var huggingFaceAuthenticationPanel: some View {
        HuggingFaceAuthenticationPanel(
            customToken: Binding(
                get: { model.settings.huggingFaceToken ?? "" },
                set: { model.settings.huggingFaceToken = $0.isEmpty ? nil : $0 }
            ),
            hasEnvironmentToken: model.environmentHuggingFaceToken != nil
        )
    }

    private var serverEndpointsPanel: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    endpointPanelTitle

                    endpointCategoryPicker
                        .frame(width: 300, alignment: .leading)

                    serverPortField
                }
                .frame(width: 660, alignment: .leading)

                VStack(alignment: .leading, spacing: 9) {
                    endpointPanelTitle

                    HStack(spacing: 10) {
                        endpointCategoryPicker
                            .frame(width: 320)

                        serverPortField

                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if showsPortInUseWarning {
                Label(
                    "Port \(String(model.settings.normalized().serverPort)) is already in use — that port can’t be used.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            Divider()

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 245), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(ServerEndpoint.endpoints(in: selectedEndpointCategory)) { endpoint in
                    ServerEndpointRow(endpoint: endpoint, baseURL: model.settings.serverBaseURL) {
                        copyEndpoint(endpoint)
                    }
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var endpointPanelTitle: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 1) {
                Text("Server Endpoints")
                    .font(.callout.weight(.semibold))
                Text(model.settings.serverBaseURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var serverPortField: some View {
        HStack(spacing: 6) {
            Text("Port")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("", value: $model.settings.serverPort, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .onChange(of: model.settings.serverPort) { _, newValue in
                    model.settings.serverPort = min(max(newValue, 1), 65_535)
                }
        }
        .help("The local server listens at 127.0.0.1 on this port. Changing it requires a server restart.")
        .task(id: model.settings.normalized().serverPort) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let port = model.settings.normalized().serverPort
            let available = await Task.detached { ServerPortProbe.isAvailable(port) }.value
            guard !Task.isCancelled else { return }
            isSelectedPortAvailable = available
        }
    }

    private var showsPortInUseWarning: Bool {
        !isSelectedPortAvailable && model.settings.normalized().serverPort != model.activeServerPort
    }

    private var endpointCategoryPicker: some View {
        Picker("Endpoint category", selection: $selectedEndpointCategory) {
            ForEach(ServerEndpointCategory.allCases) { category in
                Text(category.shortTitle).tag(category)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private func logPanelToolbar(_ output: LogOutput) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    logPanelTitle(output)

                    severityPicker
                }
                .frame(width: 560, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    logPanelTitle(output)
                    severityPicker
                }
            }

            HStack(spacing: 10) {
                LogSearchField(text: $logQuery)
                    .frame(maxWidth: 360)

                logPanelActions(output)

                Spacer(minLength: 0)

                Text("\(output.visibleLineCount) shown")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func logPanelTitle(_ output: LogOutput) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Server Output")
                    .font(.callout.weight(.semibold))
                Text(logSummary(output))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }

    private func logPanelActions(_ output: LogOutput) -> some View {
        HStack(spacing: 8) {
            LogToolbarActionButton(
                title: "Copy visible logs",
                systemImage: "doc.on.doc",
                hoverTint: .blue,
                isDisabled: output.visibleLineCount == 0
            ) {
                copyLogs(output.text)
            }

            LogToolbarActionButton(
                title: "Clear logs",
                systemImage: "trash",
                hoverTint: .red,
                isDisabled: model.logText.isEmpty
            ) {
                model.clearLogs()
            }
        }
    }

    private var severityPicker: some View {
        Picker("Severity", selection: $logLevelFilter) {
            ForEach(LogLevelFilter.allCases) { level in
                Text(level.rawValue).tag(level)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 270, alignment: .leading)
    }

    private func logSummary(_ output: LogOutput) -> String {
        if model.logText.isEmpty {
            return "No output yet"
        }
        if !logQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || logLevelFilter != .all {
            return "\(output.visibleLineCount) of \(output.totalLineCount) lines"
        }
        return "Following new output"
    }

    private var memoryUsagePercent: Int {
        Int((runtime.memoryUsageFraction * 100).rounded())
    }

    private var memoryUsageTint: Color {
        switch runtime.memoryUsageFraction {
        case 0.85...: .red
        case 0.70...: .orange
        default: .green
        }
    }

    private func byteCount(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private func copyLogs(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func copyEndpoint(_ endpoint: ServerEndpoint) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(endpoint.absoluteURL(baseURL: model.settings.serverBaseURL), forType: .string)
    }
}

private struct HuggingFaceAuthenticationPanel: View {
    @Binding var customToken: String
    let hasEnvironmentToken: Bool
    @State private var isCustomTokenExpanded: Bool
    @State private var hasSelectedDisclosureState = false

    init(customToken: Binding<String>, hasEnvironmentToken: Bool) {
        _customToken = customToken
        self.hasEnvironmentToken = hasEnvironmentToken
        _isCustomTokenExpanded = State(initialValue: !hasEnvironmentToken)
    }

    private var hasCustomToken: Bool {
        HuggingFaceAuthentication.normalizedToken(customToken) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal")
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Hugging Face Authentication")
                        .font(.callout.weight(.semibold))
                    Text("Authenticate Hub requests and downloads for gated models.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label(authenticationStatus, systemImage: authenticationStatusImage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(authenticationStatusColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isCustomTokenExpanded.toggle()
                        hasSelectedDisclosureState = true
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isCustomTokenExpanded ? 90 : 0))
                            .frame(width: 10)

                        Text("Use Custom Token")
                            .font(.callout.weight(.medium))

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use Custom Token")
                .accessibilityValue(isCustomTokenExpanded ? "Expanded" : "Collapsed")

                if isCustomTokenExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            SecureField("Enter token", text: $customToken)
                                .textFieldStyle(.roundedBorder)
                                .font(.callout.monospaced())
                                .privacySensitive()
                                .accessibilityLabel("Custom Hugging Face token")

                            if hasCustomToken {
                                Button {
                                    customToken = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Clear custom token")
                            }

                            Link(destination: URL(string: "https://huggingface.co/settings/tokens")!) {
                                Label("Manage Tokens", systemImage: "arrow.up.right")
                            }
                            .buttonStyle(.bordered)
                        }

                        Text(authenticationDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .onChange(of: hasEnvironmentToken) { wasAvailable, isAvailable in
            if !wasAvailable && isAvailable && !hasSelectedDisclosureState {
                isCustomTokenExpanded = false
            }
        }
        .onChange(of: customToken) { oldValue, newValue in
            if oldValue != newValue {
                hasSelectedDisclosureState = true
            }
        }
    }

    private var authenticationStatus: String {
        if hasCustomToken { return "Custom Token" }
        if hasEnvironmentToken { return "HF_TOKEN" }
        return "Not Configured"
    }

    private var authenticationStatusImage: String {
        hasCustomToken || hasEnvironmentToken ? "checkmark.circle.fill" : "circle.dashed"
    }

    private var authenticationStatusColor: Color {
        hasCustomToken || hasEnvironmentToken ? .green : .secondary
    }

    private var authenticationDetail: String {
        if hasCustomToken && hasEnvironmentToken {
            return "The custom token overrides HF_TOKEN from your environment. Access to a gated model must also be approved on Hugging Face."
        }
        if hasCustomToken {
            return "Using the custom token. Access to a gated model must also be approved on Hugging Face."
        }
        if hasEnvironmentToken {
            return "Using HF_TOKEN from your process or login-shell environment. Enter a custom token above to override it."
        }
        return "Set HF_TOKEN in your environment or enter a custom token. Access to a gated model must also be approved on Hugging Face."
    }
}

private struct ServerEndpoint: Identifiable {
    let method: ServerEndpointMethod
    let path: String
    let category: ServerEndpointCategory

    var id: String { "\(method.rawValue):\(path)" }

    func absoluteURL(baseURL: URL) -> String { baseURL.absoluteString + path }

    static func endpoints(in category: ServerEndpointCategory) -> [ServerEndpoint] {
        supported.filter { $0.category == category }
    }

    static let supported: [ServerEndpoint] = [
        .init(method: .post, path: "/v1/chat/completions", category: .openAI),
        .init(method: .post, path: "/v1/responses", category: .openAI),
        .init(method: .post, path: "/v1/responses/input_tokens", category: .openAI),
        .init(method: .get, path: "/v1/responses/{response_id}", category: .openAI),
        .init(method: .delete, path: "/v1/responses/{response_id}", category: .openAI),
        .init(method: .post, path: "/v1/responses/{response_id}/cancel", category: .openAI),
        .init(method: .get, path: "/v1/responses/{response_id}/input_items", category: .openAI),
        .init(method: .post, path: "/v1/images/generations", category: .openAI),
        .init(method: .post, path: "/v1/images/edits", category: .openAI),
        .init(method: .get, path: "/v1/models", category: .openAI),
        .init(method: .post, path: "/v1/audio/speech", category: .openAI),
        .init(method: .post, path: "/v1/audio/transcriptions", category: .openAI),
        .init(method: .post, path: "/v1/audio/translations", category: .openAI),
        .init(method: .post, path: "/v1/messages", category: .anthropic),
        .init(method: .post, path: "/v1/messages/count_tokens", category: .anthropic),
        .init(method: .get, path: "/health", category: .metrics),
        .init(method: .get, path: "/metrics", category: .metrics),
        .init(method: .get, path: "/v1/cache/stats", category: .metrics),
        .init(method: .post, path: "/v1/cache/reset", category: .metrics),
        .init(method: .post, path: "/unload", category: .metrics),
    ]
}

private enum ServerEndpointCategory: String, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case metrics

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .metrics: "Metrics"
        }
    }

}

private enum ServerEndpointMethod: String {
    case get = "GET"
    case post = "POST"
    case delete = "DELETE"

    var tint: Color {
        switch self {
        case .get: .blue
        case .post: .green
        case .delete: .red
        }
    }
}

private struct ServerEndpointRow: View {
    let endpoint: ServerEndpoint
    let baseURL: URL
    let copyAction: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: copyAction) {
            HStack(spacing: 8) {
                Text(endpoint.method.rawValue)
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(endpoint.method.tint)
                    .frame(width: 42, alignment: .leading)

                Text(endpoint.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 2)

                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
                    .opacity(isHovering ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 9)
        .frame(height: 30)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.secondary.opacity(0.08) : .clear)
        )
        .onHover { isHovering = $0 }
        .help("Copy \(endpoint.absoluteURL(baseURL: baseURL))")
    }
}

private enum LogSeverity {
    case info
    case warning
    case error
    case other

    static func classify(_ line: String) -> LogSeverity {
        let uppercased = line.uppercased()
        if uppercased.contains("ERROR")
            || uppercased.contains("FATAL")
            || uppercased.contains("TRACEBACK")
            || uppercased.contains("EXCEPTION")
            || uppercased.contains("FAILED TO")
        {
            return .error
        }
        if uppercased.contains("WARNING") || uppercased.contains("WARN:") {
            return .warning
        }
        if uppercased.contains("INFO") || uppercased.contains("DEBUG") {
            return .info
        }
        return .other
    }
}

private enum LogLevelFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case info = "Info"
    case warnings = "Warnings"
    case errors = "Errors"

    var id: String { rawValue }

    func includes(_ severity: LogSeverity) -> Bool {
        switch self {
        case .all:
            true
        case .info:
            severity == .info
        case .warnings:
            severity == .warning
        case .errors:
            severity == .error
        }
    }
}

private struct LogOutput {
    let text: String
    let totalLineCount: Int
    let visibleLineCount: Int

    static func filtered(_ text: String, query: String, level: LogLevelFilter) -> LogOutput {
        guard !text.isEmpty else {
            return LogOutput(text: "", totalLineCount: 0, visibleLineCount: 0)
        }

        let lines = text.components(separatedBy: .newlines)
        let totalLineCount = lines.lazy.filter { !$0.isEmpty }.count
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleLines = lines.filter { line in
            guard !line.isEmpty else {
                return level == .all && query.isEmpty
            }
            return level.includes(LogSeverity.classify(line))
                && (query.isEmpty || line.localizedCaseInsensitiveContains(query))
        }

        return LogOutput(
            text: visibleLines.joined(separator: "\n"),
            totalLineCount: totalLineCount,
            visibleLineCount: visibleLines.lazy.filter { !$0.isEmpty }.count
        )
    }
}

private struct LogSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search logs", text: $text)
                .textFieldStyle(.plain)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

private struct LogToolbarActionButton: View {
    let title: String
    let systemImage: String
    let hoverTint: Color
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundColor)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(borderColor, lineWidth: 0.5)
        )
        .onHover { isHovering = $0 }
        .disabled(isDisabled)
        .help(title)
        .accessibilityLabel(title)
    }

    private var foregroundColor: Color {
        if isDisabled { return .secondary.opacity(0.45) }
        return isHovering ? hoverTint : .primary
    }

    private var backgroundColor: Color {
        if isDisabled { return .secondary.opacity(0.04) }
        return isHovering ? hoverTint.opacity(0.14) : .secondary.opacity(0.08)
    }

    private var borderColor: Color {
        if isDisabled { return .clear }
        return isHovering ? hoverTint.opacity(0.32) : Color(nsColor: .separatorColor)
    }
}

private struct RuntimeInfoCard: View {
    let value: String
    let systemImage: String
    let tint: Color
    var progress: Double?
    var progressLabel: String?

    var body: some View {
        HStack(alignment: progress == nil ? .center : .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))

            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let progress {
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(tint)

                        if let progressLabel {
                            Text(progressLabel)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 64, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

@MainActor
final class SystemRuntimeMonitor: ObservableObject {
    @Published private(set) var usedMemoryBytes: UInt64 = 0

    let chipName = SystemRuntimeInfo.chipName
    let totalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    let macOSVersion = SystemRuntimeInfo.macOSVersion
    let macOSBuild = SystemRuntimeInfo.macOSBuild
    let mlxVLMVersion = SystemRuntimeInfo.mlxVLMVersion

    private var timer: Timer?

    var memoryUsageFraction: Double {
        guard totalMemoryBytes > 0 else { return 0 }
        return min(max(Double(usedMemoryBytes) / Double(totalMemoryBytes), 0), 1)
    }

    func start() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        usedMemoryBytes = SystemRuntimeInfo.usedMemoryBytes
    }
}

private enum SystemRuntimeInfo {
    static let chipName: String = {
        sysctlString("machdep.cpu.brand_string")
            ?? sysctlString("hw.model")
            ?? "Apple silicon"
    }()

    static let macOSVersion: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var components = ["\(version.majorVersion)", "\(version.minorVersion)"]
        if version.patchVersion > 0 {
            components.append("\(version.patchVersion)")
        }
        return "macOS " + components.joined(separator: ".")
    }()

    static let macOSBuild: String = {
        let fullVersion = ProcessInfo.processInfo.operatingSystemVersionString
        guard let openParenthesis = fullVersion.firstIndex(of: "("),
              let closeParenthesis = fullVersion[openParenthesis...].firstIndex(of: ")")
        else {
            return "System version"
        }
        return String(fullVersion[fullVersion.index(after: openParenthesis)..<closeParenthesis])
    }()

    static let mlxVLMVersion: String = {
        guard let distributionURL = try? Nativ.distributionURL() else {
            return "Unavailable"
        }
        let libraryURL = distributionURL.appendingPathComponent("python/lib", isDirectory: true)
        guard let pythonDirectories = try? FileManager.default.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "Unavailable"
        }

        for pythonDirectory in pythonDirectories where pythonDirectory.lastPathComponent.hasPrefix("python") {
            let sitePackagesURL = pythonDirectory.appendingPathComponent("site-packages", isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: sitePackagesURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            if let metadataDirectory = entries.first(where: {
                $0.lastPathComponent.hasPrefix("mlx_vlm-")
                    && $0.lastPathComponent.hasSuffix(".dist-info")
            }) {
                let name = metadataDirectory.lastPathComponent
                return String(name.dropFirst("mlx_vlm-".count).dropLast(".dist-info".count))
            }
        }
        return "Unavailable"
    }()

    static var usedMemoryBytes: UInt64 {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let usedPages = UInt64(statistics.active_count)
            + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        let usedBytes = usedPages * UInt64(vm_kernel_page_size)
        return min(usedBytes, ProcessInfo.processInfo.physicalMemory)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: value)
    }
}

private struct LogTextView: NSViewRepresentable {
    let text: String
    let searchQuery: String

    final class Coordinator {
        var renderedText = ""
        var renderedQuery = ""
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        render(text, searchQuery: searchQuery, in: textView)
        context.coordinator.renderedText = text
        context.coordinator.renderedQuery = searchQuery

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        DispatchQueue.main.async { [weak textView] in
            textView?.scrollToEndOfDocument(nil)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        guard context.coordinator.renderedText != text
            || context.coordinator.renderedQuery != searchQuery
        else {
            return
        }

        let shouldFollowOutput = isNearBottom(scrollView)
        render(text, searchQuery: searchQuery, in: textView)
        context.coordinator.renderedText = text
        context.coordinator.renderedQuery = searchQuery
        if shouldFollowOutput {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func render(_ text: String, searchQuery: String, in textView: NSTextView) {
        textView.textStorage?.setAttributedString(
            LogTextStyler.attributedString(text, searchQuery: searchQuery)
        )
    }

    private func isNearBottom(_ scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else {
            return true
        }
        let distance = documentView.bounds.maxY - scrollView.contentView.bounds.maxY
        return distance <= 24
    }
}

private enum LogTextStyler {
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static func attributedString(_ text: String, searchQuery: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let attributedLine = NSMutableAttributedString(
                string: line,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            styleSeverity(in: attributedLine, line: line)
            styleHTTPStatus(in: attributedLine)
            result.append(attributedLine)
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
        }

        highlightSearch(in: result, query: searchQuery)
        return result
    }

    private static func styleSeverity(in text: NSMutableAttributedString, line: String) {
        let fullRange = NSRange(location: 0, length: text.length)
        switch LogSeverity.classify(line) {
        case .error:
            text.addAttribute(.foregroundColor, value: NSColor.systemRed, range: fullRange)
        case .warning:
            text.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: fullRange)
        case .info:
            colorOccurrences(of: "INFO", in: text, color: .systemBlue)
            colorOccurrences(of: "DEBUG", in: text, color: .systemPurple)
        case .other:
            if line.localizedCaseInsensitiveContains("started")
                || line.localizedCaseInsensitiveContains("ready")
            {
                text.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: fullRange)
            }
        }
    }

    private static func styleHTTPStatus(in text: NSMutableAttributedString) {
        colorOccurrences(of: "200 OK", in: text, color: .systemGreen)
        colorOccurrences(of: "201 Created", in: text, color: .systemGreen)
        colorOccurrences(of: "307 Temporary Redirect", in: text, color: .systemOrange)
        colorOccurrences(of: "400 Bad Request", in: text, color: .systemRed)
        colorOccurrences(of: "401 Unauthorized", in: text, color: .systemRed)
        colorOccurrences(of: "403 Forbidden", in: text, color: .systemRed)
        colorOccurrences(of: "404 Not Found", in: text, color: .systemRed)
        colorOccurrences(of: "500 Internal Server Error", in: text, color: .systemRed)
    }

    private static func colorOccurrences(
        of token: String,
        in text: NSMutableAttributedString,
        color: NSColor
    ) {
        let string = text.string as NSString
        var searchRange = NSRange(location: 0, length: string.length)
        while searchRange.length > 0 {
            let match = string.range(of: token, options: .caseInsensitive, range: searchRange)
            guard match.location != NSNotFound else { break }
            text.addAttribute(.foregroundColor, value: color, range: match)
            let nextLocation = NSMaxRange(match)
            searchRange = NSRange(location: nextLocation, length: string.length - nextLocation)
        }
    }

    private static func highlightSearch(in text: NSMutableAttributedString, query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        let string = text.string as NSString
        var searchRange = NSRange(location: 0, length: string.length)
        while searchRange.length > 0 {
            let match = string.range(of: query, options: .caseInsensitive, range: searchRange)
            guard match.location != NSNotFound else { break }
            text.addAttributes(
                [
                    .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.45),
                    .foregroundColor: NSColor.labelColor,
                ],
                range: match
            )
            let nextLocation = NSMaxRange(match)
            searchRange = NSRange(location: nextLocation, length: string.length - nextLocation)
        }
    }
}

#Preview {
    DeveloperView(
        model: .init(),
        runtime: .init(),
        showsConfiguration: .constant(true)
    )
        .frame(width: 950, height: 650)
}
