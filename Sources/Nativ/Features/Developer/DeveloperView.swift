import AppKit
import Darwin
import IOKit
import NativServerKit
import SwiftUI

private enum EndpointEditorField: Hashable {
    case host
    case port
}

struct DeveloperView: View {
    private static let configurationToggleClearance: CGFloat = 36

    @ObservedObject var model: NativModel
    @ObservedObject var runtime: SystemRuntimeMonitor
    @Binding var showsConfiguration: Bool
    var titleLeadingInset: CGFloat = 0
    @State private var logQuery = ""
    @State private var logLevelFilter: LogLevelFilter = .all
    @State private var selectedEndpointCategory: ServerEndpointCategory = .openAI
    @State private var selectedEndpointAvailability: ServerEndpointAvailability = .available
    @FocusState private var focusedEndpointField: EndpointEditorField?

    var body: some View {
        ModelConfigurationLayout(
            model: model,
            isConfigurationVisible: $showsConfiguration
        ) {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    pageHeader
                        .padding(.horizontal, 22)
                        .padding(.top, 20)
                        .padding(.bottom, 16)

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            runtimeGrid
                            serverEndpointsPanel
                            authenticationPanels
                            logPanel
                                .frame(height: max(320, geometry.size.height - 550))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 18)
                        .padding(.bottom, 22)
                    }
                }
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .topLeading
                )
                .background(Color.nativMainContentBackground)
            }
        }
    }

    private var pageHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                pageHeaderTitle
                    .frame(minWidth: 420, alignment: .leading)

                Spacer()

                runtimeStatus
            }

            VStack(alignment: .leading, spacing: 10) {
                pageHeaderTitle
                runtimeStatus
            }
        }
        .padding(.leading, titleLeadingInset)
        .padding(.trailing, Self.configurationToggleClearance)
    }

    private var pageHeaderTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Developer")
                .font(.title2.weight(.semibold))
            Text("Runtime diagnostics, server authentication, API endpoints, and live server output.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var runtimeStatus: some View {
        Label(model.isRunning ? "Live" : "Offline", systemImage: "circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(model.isRunning ? .green : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.secondary.opacity(0.10)))
            .fixedSize()
    }

    private var runtimeGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 165), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            RuntimeInfoCard(
                title: "Apple chip",
                value: chipDisplayName,
                detail: nil,
                systemImage: "cpu",
                tint: .blue
            )

            RuntimeInfoCard(
                title: "Memory",
                value: "\(byteCount(runtime.usedMemoryBytes)) of \(byteCount(runtime.totalMemoryBytes))",
                detail: "\(memoryUsagePercent)%",
                systemImage: "memorychip",
                tint: memoryUsageTint,
                progress: runtime.memoryUsageFraction
            )

            RuntimeInfoCard(
                title: "macOS",
                value: runtime.macOSVersion,
                detail: runtime.macOSBuild,
                systemImage: "macbook",
                tint: .teal
            )

            RuntimeInfoCard(
                title: "mlx-vlm",
                value: runtime.mlxVLMVersion,
                detail: nil,
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
            customToken: model.settings.huggingFaceToken,
            systemCredential: model.systemHuggingFaceCredential,
            onLogIn: model.logInToHuggingFace,
            onSetCustomToken: model.setCustomHuggingFaceToken,
            onLogOutSystemCredential: model.logOutSystemHuggingFaceCredential
        )
    }

    private var serverAPIAuthenticationPanel: some View {
        ServerAPIAuthenticationPanel(
            token: model.settings.serverAPIKey,
            onSetToken: model.setServerAPIKey
        )
    }

    private var authenticationPanels: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                huggingFaceAuthenticationPanel
                    .frame(minWidth: 300, maxWidth: .infinity)

                serverAPIAuthenticationPanel
                    .frame(minWidth: 300, maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 12) {
                huggingFaceAuthenticationPanel
                    .frame(maxWidth: .infinity)

                serverAPIAuthenticationPanel
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var serverEndpointsPanel: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    endpointPanelTitle

                    endpointCategoryPicker
                        .frame(width: 300, alignment: .leading)

                    serverHostField

                    serverPortField
                }
                .frame(width: 850, alignment: .leading)

                VStack(alignment: .leading, spacing: 9) {
                    endpointPanelTitle

                    HStack(spacing: 10) {
                        endpointCategoryPicker
                            .frame(width: 320)

                        serverHostField

                        serverPortField

                        Spacer()
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    endpointPanelTitle

                    endpointCategoryPicker
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        serverHostField
                        serverPortField
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(PanelHeaderAccent(tint: .blue))

            serverRestartIndicator

            if let endpointAvailabilityWarning {
                Label(
                    endpointAvailabilityWarning,
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
        .onChange(of: serverEndpointProbeID) {
            model.scheduleServerRestartForEndpointChange()
        }
    }

    @ViewBuilder
    private var serverRestartIndicator: some View {
        if let countdown = model.serverRestartCountdown {
            let timeUnit = countdown == 1 ? "second" : "seconds"

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text("Applying endpoint change — restarting server in \(countdown) \(timeUnit)…")
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(.blue)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)
        }
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
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
            TextField("", value: $model.settings.serverPort, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .font(.callout.monospaced())
                .multilineTextAlignment(.trailing)
                .focused($focusedEndpointField, equals: .port)
                .editableFieldChrome(
                    isFocused: focusedEndpointField == .port
                )
                .frame(width: 78)
                .accessibilityLabel("Server port")
                .onChange(of: model.settings.serverPort) { _, newValue in
                    model.settings.serverPort = min(max(newValue, 1), 65_535)
                }
        }
        .help("The port the local server listens on. Changes restart a running server after 3 seconds.")
        .task(id: serverEndpointAvailabilityProbeID) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let settings = model.settings.normalized()
            let availability = await Task.detached {
                ServerPortProbe.availability(host: settings.serverHost, port: settings.serverPort)
            }.value
            guard !Task.isCancelled else { return }
            selectedEndpointAvailability = availability
        }
    }

    private var serverHostField: some View {
        HStack(spacing: 6) {
            Text("Host")
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
            TextField("", text: $model.settings.serverHost)
                .textFieldStyle(.plain)
                .font(.callout.monospaced())
                .focused($focusedEndpointField, equals: .host)
                .editableFieldChrome(
                    isFocused: focusedEndpointField == .host
                )
                .frame(width: 144)
                .accessibilityLabel("Server host")
                .onSubmit {
                    model.settings.serverHost = model.settings.normalized().serverHost
                }
        }
        .help("The host or IP address the local server binds to. Changes restart a running server after 3 seconds.")
    }

    private var serverEndpointProbeID: String {
        let settings = model.settings.normalized()
        return "\(settings.serverHost):\(settings.serverPort)"
    }

    private var serverEndpointAvailabilityProbeID: String {
        let activeEndpoint = model.activeServerBaseURL?.absoluteString ?? "offline"
        return "\(serverEndpointProbeID):\(activeEndpoint)"
    }

    private var endpointAvailabilityWarning: String? {
        let settings = model.settings.normalized()
        let isActiveEndpoint = settings.serverHost == model.activeServerHost
            && settings.serverPort == model.activeServerPort
        guard !isActiveEndpoint, model.serverRestartCountdown == nil else {
            return nil
        }

        switch selectedEndpointAvailability {
        case .available:
            return nil
        case .addressInUse:
            return "\(settings.serverBaseURL.absoluteString) is already in use — Nativ can’t bind to that address."
        case .invalidAddress:
            return "\(settings.serverBaseURL.absoluteString) can’t be used — check the host and port."
        }
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

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    LogSearchField(text: $logQuery)
                        .frame(minWidth: 180, maxWidth: 360)

                    logPanelActions(output)

                    Spacer(minLength: 0)

                    visibleLogCount(output)
                }

                VStack(alignment: .leading, spacing: 8) {
                    LogSearchField(text: $logQuery)

                    HStack(spacing: 10) {
                        logPanelActions(output)
                        Spacer(minLength: 0)
                        visibleLogCount(output)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(PanelHeaderAccent(tint: .blue))
    }

    private func visibleLogCount(_ output: LogOutput) -> some View {
        Text("\(output.visibleLineCount) shown")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize()
    }

    private func logPanelTitle(_ output: LogOutput) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.blue)

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

    private var chipDisplayName: String {
        let applePrefix = "Apple "
        guard runtime.chipName.hasPrefix(applePrefix) else {
            return runtime.chipName
        }
        return String(runtime.chipName.dropFirst(applePrefix.count))
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

private struct PanelHeaderAccent: View {
    let tint: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [tint.opacity(0.12), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(maxWidth: 420)

                Spacer(minLength: 0)
            }

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.85), tint.opacity(0.25)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 120, height: 3)
                .padding(.top, 2)
                .padding(.leading, 16)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct EditableFieldChrome: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        isFocused
                            ? Color.blue.opacity(0.08)
                            : Color(nsColor: .textBackgroundColor)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        isFocused ? Color.blue : Color.primary.opacity(0.22),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            )
            .shadow(
                color: isFocused ? Color.blue.opacity(0.16) : .clear,
                radius: 3
            )
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

private extension View {
    func editableFieldChrome(isFocused: Bool) -> some View {
        modifier(EditableFieldChrome(isFocused: isFocused))
    }
}

private struct ServerAPIAuthenticationPanel: View {
    let token: String?
    let onSetToken: (String?) -> Void
    @State private var tokenEntry = ""
    @State private var isEditingToken = false
    @State private var showsRemovalConfirmation = false
    @FocusState private var tokenFieldIsFocused: Bool

    private var activeToken: String? {
        ServerAPIAuthentication.normalizedToken(token)
    }

    private var tokenInfo: ServerAPITokenInfo? {
        ServerAPIAuthentication.tokenInfo(activeToken)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            authenticationHeader
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(PanelHeaderAccent(tint: .blue))

            Divider()

            Group {
                if isEditingToken {
                    tokenEditor
                } else {
                    credentialOverview
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
        .confirmationDialog(
            "Remove the server API token?",
            isPresented: $showsRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Token", role: .destructive) {
                onSetToken(nil)
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "API requests will no longer require this token. "
                    + "The running server restarts automatically."
            )
        }
    }

    private var authenticationHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                authenticationHeaderTitle
                    .frame(width: 240, alignment: .leading)

                Spacer(minLength: 8)

                authenticationStatusBadge
            }

            VStack(alignment: .leading, spacing: 8) {
                authenticationHeaderTitle
                authenticationStatusBadge
            }
        }
    }

    private var authenticationHeaderTitle: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 1) {
                Text("Server API Authentication")
                    .font(.callout.weight(.semibold))
                Text("Protect API requests with a custom Bearer token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var authenticationStatusBadge: some View {
        Label(authenticationStatus, systemImage: authenticationStatusImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(authenticationStatusColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                authenticationStatusColor.opacity(0.12),
                in: Capsule()
            )
            .fixedSize()
    }

    private var authenticationStatus: String {
        activeToken == nil ? "Not Configured" : "Configured"
    }

    private var authenticationStatusImage: String {
        activeToken == nil ? "circle.dashed" : "checkmark.circle.fill"
    }

    private var authenticationStatusColor: Color {
        activeToken == nil ? .secondary : .green
    }

    private var credentialOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    credentialStatus
                    Spacer(minLength: 8)
                    credentialActions
                }

                VStack(alignment: .leading, spacing: 8) {
                    credentialStatus
                    credentialActions
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 105),
                        spacing: 12,
                        alignment: .leading
                    )
                ],
                alignment: .leading,
                spacing: 10
            ) {
                credentialAttribute(
                    title: "Token",
                    value: tokenInfo?.maskedValue ?? "Not available",
                    systemImage: "ellipsis.rectangle",
                    monospaced: true
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .privacySensitive()

                credentialAttribute(
                    title: "Header",
                    value: "Authorization",
                    systemImage: "textformat"
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                credentialAttribute(
                    title: "Scheme",
                    value: "Bearer",
                    systemImage: "lock"
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                credentialAttribute(
                    title: "Length",
                    value: activeTokenLength,
                    systemImage: "number"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var credentialStatus: some View {
        Label(
            activeToken == nil ? "No Active Credential" : "Active Credential",
            systemImage: activeToken == nil ? "key" : "key.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(activeToken == nil ? .secondary : .primary)
        .fixedSize()
    }

    @ViewBuilder
    private var credentialActions: some View {
        if activeToken != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    copyTokenButton
                    changeTokenButton
                    removeTokenButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    copyTokenButton
                    changeTokenButton
                    removeTokenButton
                }
            }
        } else {
            addTokenButton
        }
    }

    private var copyTokenButton: some View {
        Button {
            copyToken()
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .help("Copy the active server API token")
    }

    private var changeTokenButton: some View {
        Button {
            beginEditingToken()
        } label: {
            Label("Change", systemImage: "pencil")
        }
        .buttonStyle(.bordered)
    }

    private var removeTokenButton: some View {
        Button(role: .destructive) {
            showsRemovalConfirmation = true
        } label: {
            Label("Remove", systemImage: "trash")
        }
        .buttonStyle(.bordered)
    }

    private var addTokenButton: some View {
        Button {
            beginEditingToken()
        } label: {
            Label("Add Token", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
    }

    private var tokenEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    tokenEditorTitle
                    Spacer(minLength: 8)
                    generateTokenButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    tokenEditorTitle
                    generateTokenButton
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    tokenField
                        .frame(minWidth: 180)
                    tokenEditorActions
                }

                VStack(alignment: .leading, spacing: 8) {
                    tokenField
                    tokenEditorActions
                }
            }

            Text("Clients send this value as an Authorization Bearer token.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .task {
            tokenFieldIsFocused = true
        }
    }

    private var tokenEditorTitle: some View {
        Label(
            activeToken == nil ? "Add Server API Token" : "Replace Server API Token",
            systemImage: "key.fill"
        )
        .font(.caption.weight(.semibold))
        .fixedSize()
    }

    private var generateTokenButton: some View {
        Button {
            tokenEntry = ServerAPIAuthentication.generateToken()
            tokenFieldIsFocused = true
        } label: {
            Label("Generate Secure Token", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }

    private var tokenField: some View {
        SecureField("Paste or generate a server API token", text: $tokenEntry)
            .textFieldStyle(.plain)
            .font(.callout.monospaced())
            .focused($tokenFieldIsFocused)
            .editableFieldChrome(isFocused: tokenFieldIsFocused)
            .privacySensitive()
            .accessibilityLabel("Server API token")
            .onSubmit(saveToken)
    }

    private var tokenEditorActions: some View {
        HStack(spacing: 8) {
            Button("Cancel") {
                cancelEditingToken()
            }
            .buttonStyle(.bordered)

            Button("Save Token") {
                saveToken()
            }
            .buttonStyle(.borderedProminent)
            .disabled(ServerAPIAuthentication.normalizedToken(tokenEntry) == nil)
        }
    }

    private var activeTokenLength: String {
        guard let characterCount = tokenInfo?.characterCount else {
            return "—"
        }
        let unit = characterCount == 1 ? "character" : "characters"
        return "\(characterCount) \(unit)"
    }

    private func credentialAttribute(
        title: String,
        value: String,
        systemImage: String,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(
                    monospaced
                        ? .caption.monospaced().weight(.medium)
                        : .callout.weight(.medium)
                )
                .lineLimit(1)
        }
    }

    private func beginEditingToken() {
        tokenEntry = ""
        isEditingToken = true
    }

    private func cancelEditingToken() {
        isEditingToken = false
        tokenFieldIsFocused = false
        tokenEntry = ""
    }

    private func saveToken() {
        guard let token = ServerAPIAuthentication.normalizedToken(tokenEntry) else {
            return
        }
        onSetToken(token)
        isEditingToken = false
        tokenFieldIsFocused = false
        tokenEntry = ""
    }

    private func copyToken() {
        guard let activeToken else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(activeToken, forType: .string)
    }
}

private enum HuggingFaceTokenMetadataState {
    case idle
    case loading
    case loaded(HuggingFaceTokenMetadata)
    case unavailable
}

private struct HuggingFaceAuthenticationPanel: View {
    let customToken: String?
    let systemCredential: HuggingFaceCredential?
    let onLogIn: (String) async throws -> Void
    let onSetCustomToken: (String?) -> Void
    let onLogOutSystemCredential: () throws -> Void
    @State private var tokenEntry = ""
    @State private var isAddingToken = false
    @State private var isLoggingIn = false
    @State private var showsLogoutConfirmation = false
    @State private var managementError: String?
    @State private var tokenMetadataState = HuggingFaceTokenMetadataState.idle
    @FocusState private var tokenFieldIsFocused: Bool

    private var hasCustomToken: Bool {
        HuggingFaceAuthentication.normalizedToken(customToken) != nil
    }

    private var systemTokenSource: HuggingFaceTokenSource? {
        systemCredential?.source
    }

    private var activeToken: String? {
        HuggingFaceAuthentication.effectiveToken(
            customToken: customToken,
            environmentToken: systemCredential?.token
        )
    }

    private var activeTokenInfo: HuggingFaceTokenInfo? {
        HuggingFaceAuthentication.tokenInfo(activeToken)
    }

    private var hasActiveCredential: Bool {
        activeToken != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            authenticationHeader
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(PanelHeaderAccent(tint: .blue))

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                credentialOverview

                if isAddingToken {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add Hugging Face token")
                            .font(.caption.weight(.semibold))

                        tokenEditor

                        Text("Nativ validates and saves this as your active Hugging Face login.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
        .confirmationDialog(
            logoutConfirmationTitle,
            isPresented: $showsLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button(logoutConfirmationAction, role: .destructive) {
                performLogout()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(logoutConfirmationMessage)
        }
        .alert(
            "Hugging Face Authentication Error",
            isPresented: Binding(
                get: { managementError != nil },
                set: { if !$0 { managementError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                managementError = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(managementError ?? "An unknown error occurred.")
        }
        .task(id: activeToken) {
            await loadTokenMetadata(for: activeToken)
        }
    }

    private var authenticationHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                authenticationHeaderTitle
                    .frame(width: 240, alignment: .leading)

                Spacer(minLength: 8)

                authenticationStatusBadge
            }

            VStack(alignment: .leading, spacing: 8) {
                authenticationHeaderTitle
                authenticationStatusBadge
            }
        }
    }

    private var authenticationHeaderTitle: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.horizontal")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 1) {
                Text("Hugging Face Authentication")
                    .font(.callout.weight(.semibold))
                Text("Authenticate Hub requests and downloads for gated models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var authenticationStatusBadge: some View {
        Label(authenticationStatus, systemImage: authenticationStatusImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(authenticationStatusColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                authenticationStatusColor.opacity(0.12),
                in: Capsule()
            )
            .fixedSize()
    }

    private var authenticationStatus: String {
        hasActiveCredential ? "Configured" : "Not Configured"
    }

    private var authenticationStatusImage: String {
        hasActiveCredential ? "checkmark.circle.fill" : "circle.dashed"
    }

    private var authenticationStatusColor: Color {
        hasActiveCredential ? .green : .secondary
    }

    private var credentialOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    credentialStatus
                    Spacer(minLength: 8)
                    credentialActions
                }

                VStack(alignment: .leading, spacing: 8) {
                    credentialStatus
                    credentialActions
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 105),
                        spacing: 12,
                        alignment: .leading
                    )
                ],
                alignment: .leading,
                spacing: 10
            ) {
                credentialAttribute(
                    title: "Token",
                    value: activeTokenInfo?.maskedValue ?? "Not available",
                    systemImage: "ellipsis.rectangle",
                    monospaced: true
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .privacySensitive()

                credentialAttribute(
                    title: "Token Name",
                    value: activeTokenName,
                    systemImage: "tag"
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                credentialAttribute(
                    title: "Permission",
                    value: activeTokenPermission,
                    systemImage: "lock.shield"
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                credentialAttribute(
                    title: "Length",
                    value: activeTokenLength,
                    systemImage: "number"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var credentialStatus: some View {
        Label(
            hasActiveCredential ? "Active Credential" : "No Active Credential",
            systemImage: hasActiveCredential ? "key.fill" : "key"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(hasActiveCredential ? .primary : .secondary)
        .fixedSize()
    }

    private var credentialActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                primaryCredentialAction
                manageTokensLink
            }

            VStack(alignment: .leading, spacing: 8) {
                primaryCredentialAction
                manageTokensLink
            }
        }
    }

    @ViewBuilder
    private var primaryCredentialAction: some View {
        if hasCustomToken || systemCredential != nil {
            Button(role: .destructive) {
                requestLogout()
            } label: {
                Label(
                    "Log Out",
                    systemImage: "rectangle.portrait.and.arrow.right"
                )
            }
            .buttonStyle(.bordered)
        } else {
            Button {
                beginAddingToken()
            } label: {
                Label("Add Token", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var manageTokensLink: some View {
        Link(destination: URL(string: "https://huggingface.co/settings/tokens")!) {
            Label("HF Hub", systemImage: "arrow.up.right")
        }
        .buttonStyle(.bordered)
    }

    private var tokenEditor: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                tokenField
                    .frame(minWidth: 180)
                tokenEditorActions
            }

            VStack(alignment: .leading, spacing: 8) {
                tokenField
                tokenEditorActions
            }
        }
    }

    private var tokenField: some View {
        SecureField("Paste Hugging Face token", text: $tokenEntry)
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())
            .focused($tokenFieldIsFocused)
            .privacySensitive()
            .accessibilityLabel("Hugging Face token")
            .disabled(isLoggingIn)
            .onSubmit {
                Task {
                    await saveToken()
                }
            }
    }

    private var tokenEditorActions: some View {
        HStack(spacing: 8) {
            Button("Cancel") {
                cancelAddingToken()
            }
            .buttonStyle(.bordered)
            .disabled(isLoggingIn)

            Button {
                Task {
                    await saveToken()
                }
            } label: {
                if isLoggingIn {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Log In")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                isLoggingIn
                    || HuggingFaceAuthentication.normalizedToken(tokenEntry) == nil
            )
        }
    }

    private var activeTokenLength: String {
        guard let characterCount = activeTokenInfo?.characterCount else {
            return "—"
        }
        let unit = characterCount == 1 ? "character" : "characters"
        return "\(characterCount) \(unit)"
    }

    private var activeTokenName: String {
        switch tokenMetadataState {
        case .idle:
            "—"
        case .loading:
            "Checking…"
        case .loaded(let metadata):
            metadata.name ?? "Not reported"
        case .unavailable:
            "Unavailable"
        }
    }

    private var activeTokenPermission: String {
        switch tokenMetadataState {
        case .idle:
            "—"
        case .loading:
            "Checking…"
        case .loaded(let metadata):
            metadata.permission ?? "Not reported"
        case .unavailable:
            "Unavailable"
        }
    }

    private func credentialAttribute(
        title: String,
        value: String,
        systemImage: String,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(
                    monospaced
                        ? .caption.monospaced().weight(.medium)
                        : .callout.weight(.medium)
                )
                .lineLimit(1)
        }
    }

    private var systemTokenDescription: String? {
        switch systemTokenSource {
        case .environment:
            "HF_TOKEN from your environment"
        case .credentialFile:
            "your Hugging Face login"
        case nil:
            nil
        }
    }

    private var logoutConfirmationTitle: String {
        "Log out of Hugging Face?"
    }

    private var logoutConfirmationAction: String {
        "Log Out"
    }

    private var logoutConfirmationMessage: String {
        if hasCustomToken, let systemTokenDescription {
            return "Nativ will remove its custom token, fall back to \(systemTokenDescription), and restart the running server."
        }
        if hasCustomToken {
            return "Nativ will remove its custom token and restart the running server without Hugging Face authentication."
        }
        return "This removes the active Hugging Face CLI login file from this Mac and restarts the running server without it."
    }

    private func beginAddingToken() {
        tokenEntry = ""
        withAnimation(.easeInOut(duration: 0.15)) {
            isAddingToken = true
        }
        tokenFieldIsFocused = true
    }

    private func cancelAddingToken() {
        tokenFieldIsFocused = false
        tokenEntry = ""
        withAnimation(.easeInOut(duration: 0.15)) {
            isAddingToken = false
        }
    }

    @MainActor
    private func saveToken() async {
        guard let token = HuggingFaceAuthentication.normalizedToken(tokenEntry) else {
            return
        }
        isLoggingIn = true
        tokenFieldIsFocused = false
        defer {
            isLoggingIn = false
        }

        do {
            try await onLogIn(token)
            cancelAddingToken()
        } catch {
            managementError = error.localizedDescription
        }
    }

    @MainActor
    private func loadTokenMetadata(for token: String?) async {
        tokenMetadataState = .idle
        guard let token else {
            return
        }
        if let cachedMetadata = HuggingFaceTokenMetadataCache.load(for: token) {
            tokenMetadataState = .loaded(cachedMetadata)
            return
        }

        tokenMetadataState = .loading
        do {
            let metadata = try await HuggingFaceAuthentication.tokenMetadata(for: token)
            guard !Task.isCancelled else {
                return
            }
            try? HuggingFaceTokenMetadataCache.save(metadata, for: token)
            tokenMetadataState = .loaded(metadata)
        } catch {
            guard !Task.isCancelled else {
                return
            }
            tokenMetadataState = .unavailable
        }
    }

    private func requestLogout() {
        if !hasCustomToken, systemTokenSource == .environment {
            managementError =
                HuggingFaceAuthenticationError.environmentTokenCannotBeRemoved
                .localizedDescription
            return
        }
        showsLogoutConfirmation = true
    }

    private func performLogout() {
        if hasCustomToken {
            onSetCustomToken(nil)
            return
        }
        do {
            try onLogOutSystemCredential()
        } catch {
            managementError = error.localizedDescription
        }
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

    var displayTitle: String {
        self == .delete ? "DEL" : rawValue
    }

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
                Text(endpoint.method.displayTitle)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(endpoint.method.tint)
                    .frame(width: 42, alignment: .leading)

                Text(endpoint.path)
                    .font(.system(size: 12, design: .monospaced))
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
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search logs", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .accessibilityLabel("Search server logs")

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
        .editableFieldChrome(isFocused: isFocused)
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
    let title: String
    let value: String
    let detail: String?
    let systemImage: String
    let tint: Color
    var progress: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let progress {
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(tint)

                        if let detail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .padding(.top, 2)
                } else if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 82, alignment: .leading)
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
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var gpuUsage: Double?

    let chipName = SystemRuntimeInfo.chipName
    let totalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    let macOSVersion = SystemRuntimeInfo.macOSVersion
    let macOSBuild = SystemRuntimeInfo.macOSBuild
    let mlxVLMVersion = SystemRuntimeInfo.mlxVLMVersion

    private var timer: Timer?
    private var previousCPUTicks: SystemRuntimeInfo.CPUTicks?
    private(set) var cpuHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    var onUpdate: (() -> Void)?

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
        let currentCPUTicks = SystemRuntimeInfo.cpuTicks
        cpuUsage = SystemRuntimeInfo.cpuUsage(
            current: currentCPUTicks,
            previous: previousCPUTicks
        )
        previousCPUTicks = currentCPUTicks
        gpuUsage = SystemRuntimeInfo.gpuUsage
        usedMemoryBytes = SystemRuntimeInfo.usedMemoryBytes

        append(cpuUsage, to: &cpuHistory)
        append(gpuUsage ?? 0, to: &gpuHistory)
        append(memoryUsageFraction, to: &memoryHistory)
        onUpdate?()
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > 30 {
            history.removeFirst(history.count - 30)
        }
    }
}

private enum SystemRuntimeInfo {
    struct CPUTicks {
        let user: UInt64
        let system: UInt64
        let idle: UInt64

        var total: UInt64 {
            user + system + idle
        }
    }

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

    static var cpuTicks: CPUTicks {
        var statistics = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride
                / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return CPUTicks(user: 0, system: 0, idle: 1)
        }

        return CPUTicks(
            user: UInt64(
                statistics.cpu_ticks.0 + statistics.cpu_ticks.3
            ),
            system: UInt64(statistics.cpu_ticks.1),
            idle: UInt64(statistics.cpu_ticks.2)
        )
    }

    static func cpuUsage(current: CPUTicks, previous: CPUTicks?) -> Double {
        let delta: CPUTicks
        if let previous {
            delta = CPUTicks(
                user: current.user >= previous.user ? current.user - previous.user : 0,
                system: current.system >= previous.system
                    ? current.system - previous.system
                    : 0,
                idle: current.idle >= previous.idle ? current.idle - previous.idle : 0
            )
        } else {
            delta = current
        }
        guard delta.total > 0 else { return 0 }
        return min(max(1 - (Double(delta.idle) / Double(delta.total)), 0), 1)
    }

    static var gpuUsage: Double? {
        guard let matching = IOServiceMatching("AGXAccelerator") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let statistics = IORegistryEntryCreateCFProperty(
            service,
            "PerformanceStatistics" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSDictionary,
              let percentage = statistics["Device Utilization %"] as? NSNumber
        else {
            return nil
        }
        return min(max(percentage.doubleValue / 100, 0), 1)
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
