import NativServerKit
import SwiftUI

struct ToolsSectionView: View {
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    @State private var inspecting: ToolItem?
    @State private var showsAddTool = false
    @State private var editingTool: CustomHTTPTool?
    @State private var toolPendingRemoval: CustomHTTPTool?
    @State private var toolManagementError: String?

    var body: some View {
        HubSectionScaffold(
            title: "Tools",
            subtitle: "Built-in capabilities, custom tools, and tools from connected servers."
        ) {
            Button {
                showsAddTool = true
            } label: {
                Label("Add tool", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        } content: {
            VStack(alignment: .leading, spacing: 22) {
                toolGroup(title: "Built-in", tools: nativeTools)

                if !customTools.isEmpty {
                    toolGroup(title: "Custom", tools: customTools)
                }

                ForEach(enabledServers) { server in
                    let tools = mcpTools(for: server)
                    if !tools.isEmpty {
                        toolGroup(title: server.name, tools: tools)
                    }
                }
            }
        }
        .sheet(item: $inspecting) { tool in
            ToolInspectorView(tool: tool, host: host)
        }
        .sheet(isPresented: $showsAddTool) {
            CustomToolEditorSheet(model: model)
        }
        .sheet(item: $editingTool) { tool in
            CustomToolEditorSheet(model: model, tool: tool)
        }
        .alert(
            "Remove \(toolPendingRemoval?.name ?? "tool")?",
            isPresented: Binding(
                get: { toolPendingRemoval != nil },
                set: { if !$0 { toolPendingRemoval = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                removePendingTool()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                toolPendingRemoval = nil
            }
        } message: {
            Text("This removes the tool and its saved request credential.")
        }
        .alert("Couldn’t remove tool", isPresented: Binding(
            get: { toolManagementError != nil },
            set: { if !$0 { toolManagementError = nil } }
        )) {
            Button("OK", role: .cancel) {
                toolManagementError = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(toolManagementError ?? "An unexpected error occurred.")
        }
    }

    private var enabledServers: [MCPServerConfig] {
        model.settings.mcpServers.filter(\.isEnabled)
    }

    @ViewBuilder
    private func toolGroup(title: String, tools: [ToolItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                if index > 0 { Divider() }
                ToolRow(
                    tool: tool,
                    isOn: binding(for: tool.name),
                    onInspect: { inspecting = tool },
                    onEdit: editAction(for: tool),
                    onRemove: removeAction(for: tool)
                )
            }
        }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { !model.settings.disabledToolNames.contains(name) },
            set: { enabled in
                if enabled {
                    model.settings.disabledToolNames.removeAll { $0 == name }
                } else if !model.settings.disabledToolNames.contains(name) {
                    model.settings.disabledToolNames.append(name)
                }
            }
        )
    }

    private var nativeTools: [ToolItem] {
        var definitions: [MLXChatToolDefinition] = []
        definitions += ChatSystemMonitorToolRegistry.definitions()
        definitions += ChatModelLibraryToolRegistry.definitions()
        definitions += ChatServerStatsToolRegistry.definitions()
        definitions += ChatSwitchModelToolRegistry.definitions()
        definitions += ChatImageToolRegistry.definitions(canEdit: false)
        return definitions.map {
            ToolItem(
                name: $0.function.name,
                title: $0.function.name,
                detail: $0.function.description,
                parameters: $0.function.parameters,
                isRunnable: false,
                isBuiltIn: true
            )
        }
    }

    private var customTools: [ToolItem] {
        model.settings.customTools.map {
            ToolItem(
                name: $0.toolName,
                title: $0.name,
                detail: $0.displaySummary,
                parameters: try? $0.definition().function.parameters,
                customToolID: $0.id,
                executionHint: "This custom tool sends model-provided JSON to \($0.endpoint) when it is called in chat."
            )
        }
    }

    private func editAction(for tool: ToolItem) -> (() -> Void)? {
        guard let id = tool.customToolID else { return nil }
        return {
            editingTool = model.settings.customTools.first { $0.id == id }
        }
    }

    private func removeAction(for tool: ToolItem) -> (() -> Void)? {
        guard let id = tool.customToolID else { return nil }
        return {
            toolPendingRemoval = model.settings.customTools.first { $0.id == id }
        }
    }

    private func removePendingTool() {
        guard let tool = toolPendingRemoval else { return }
        do {
            try CustomHTTPToolKeychain().save(nil, for: tool.id)
            model.settings.customTools.removeAll { $0.id == tool.id }
            model.settings.disabledToolNames.removeAll { $0 == tool.toolName }
            toolPendingRemoval = nil
        } catch {
            toolPendingRemoval = nil
            toolManagementError = "The saved request credential could not be removed from Keychain."
        }
    }

    private func mcpTools(for server: MCPServerConfig) -> [ToolItem] {
        let defs = host.toolDefinitions()
        return host.tools(forServer: server.id).map { pair in
            let def = defs.first { $0.function.name == pair.name }
            return ToolItem(
                name: pair.name,
                title: pair.displayName,
                detail: def?.function.description ?? "",
                parameters: def?.function.parameters,
                isRunnable: true
            )
        }
    }
}

struct ToolItem: Identifiable {
    var id: String { name }
    let name: String
    let title: String
    let detail: String
    var parameters: MLXJSONValue?
    var isRunnable: Bool = false
    var isBuiltIn: Bool = false
    var customToolID: UUID?
    var executionHint: String?
}

private struct ToolRow: View {
    let tool: ToolItem
    @Binding var isOn: Bool
    let onInspect: () -> Void
    var onEdit: (() -> Void)?
    var onRemove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.title)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    if tool.isBuiltIn {
                        NativStatusBadge(text: "Built-in")
                            .help("Ships with Nativ")
                    }
                }
                if !tool.detail.isEmpty {
                    Text(tool.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            Button(action: onInspect) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Inspect / try")
            if let onEdit, let onRemove {
                Menu {
                    Button("Edit", action: onEdit)
                    Divider()
                    Button("Remove", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 18)
                .help("Manage tool")
            }
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 9)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onInspect)
    }
}

// MARK: - Inspector / playground

private struct ToolInspectorView: View {
    let tool: ToolItem
    @ObservedObject var host: MCPHostManager
    @Environment(\.dismiss) private var dismiss

    @State private var argumentsJSON = "{}"
    @State private var result: String?
    @State private var errorText: String?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.title)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    if !tool.detail.isEmpty {
                        Text(tool.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            section("Input schema") {
                ScrollView {
                    Text(schemaText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 150)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
            }

            if tool.isRunnable {
                section("Try it — arguments (JSON)") {
                    TextEditor(text: $argumentsJSON)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 70)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                }
                HStack {
                    Button {
                        run()
                    } label: {
                        Label(running ? "Running\u{2026}" : "Run", systemImage: "play.fill")
                    }
                    .disabled(running)
                    Spacer()
                }
                if let errorText {
                    Text(errorText).font(.system(size: 11)).foregroundStyle(.red)
                }
                if let result {
                    section("Result") {
                        ScrollView {
                            Text(result)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(height: 130)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            } else {
                Text(tool.executionHint ?? "Built-in tools run inside a chat when a tool-capable model calls them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func section<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }

    private var schemaText: String {
        guard let parameters = tool.parameters else { return "No schema provided." }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(parameters),
              let text = String(data: data, encoding: .utf8) else {
            return "No schema provided."
        }
        return text
    }

    private func run() {
        errorText = nil
        result = nil
        running = true
        let name = tool.name
        let args = argumentsJSON
        Task {
            do {
                let output = try await host.callTool(named: name, argumentsJSON: args)
                await MainActor.run {
                    result = output
                    running = false
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    running = false
                }
            }
        }
    }
}

private struct CustomToolEditorSheet: View {
    @ObservedObject var model: NativModel
    let tool: CustomHTTPTool?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var summary: String
    @State private var endpoint: String
    @State private var headerName: String
    @State private var headerValue = ""
    @State private var parametersJSON: String
    @State private var testArgumentsJSON = #"{"query":"test"}"#
    @State private var showsAdvanced = false
    @State private var revealsHeaderValue = false
    @State private var validationError: String?
    @State private var testResult: String?
    @State private var testing = false

    init(model: NativModel, tool: CustomHTTPTool? = nil) {
        self.model = model
        self.tool = tool
        _name = State(initialValue: tool?.name ?? "")
        _summary = State(initialValue: tool?.summary ?? "")
        _endpoint = State(initialValue: tool?.endpoint ?? "")
        _headerName = State(initialValue: tool?.headerName ?? "")
        _parametersJSON = State(initialValue: tool?.parametersJSON ?? CustomHTTPTool.defaultParametersJSON)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tool == nil ? "Add tool" : "Edit tool")
                    .font(.system(size: 17, weight: .semibold))
                Text("Nativ sends the model’s JSON arguments to your HTTP endpoint.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            form

            if let validationError {
                Text(validationError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            if let testResult {
                Text(testResult)
                    .font(.system(size: 11))
                    .foregroundStyle(validationError == nil ? .green : .red)
                    .lineLimit(2)
            }

            HStack {
                Button("Cancel", action: dismiss.callAsFunction)
                Spacer()
                Button(testing ? "Testing…" : "Test request", action: test)
                    .disabled(testing
                        || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(tool == nil ? "Add tool" : "Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear(perform: loadCredential)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Name") {
                TextField("Weather lookup", text: $name)
            }
            field("Description") {
                TextField("Looks up a forecast for a place.", text: $summary)
            }
            field("Endpoint") {
                TextField("https://example.com/tools/weather", text: $endpoint)
                    .textContentType(.URL)
            }
            Text("Uses POST with a JSON request body.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    field("Header name") {
                        TextField("Authorization", text: $headerName)
                    }
                    if !headerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        field("Header value") {
                            HStack(spacing: 6) {
                                Group {
                                    if revealsHeaderValue {
                                        TextField("Bearer …", text: $headerValue)
                                    } else {
                                        SecureField("Bearer …", text: $headerValue)
                                    }
                                }
                                Button {
                                    revealsHeaderValue.toggle()
                                } label: {
                                    Image(systemName: revealsHeaderValue ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help(revealsHeaderValue ? "Hide value" : "Show value")
                            }
                        }
                    }
                    Text("The header value is saved only in your Mac’s Keychain.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    field("Parameters") {
                        TextEditor(text: $parametersJSON)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 120)
                            .padding(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                    }
                    field("Test arguments") {
                        TextField(#"{"query":"test"}"#, text: $testArgumentsJSON)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                .padding(.top, 6)
            }
            .font(.system(size: 12, weight: .medium))
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            content()
        }
    }

    private func save() {
        do {
            let savedTool = try makeTool()
            guard !model.settings.customTools.contains(where: {
                $0.id != savedTool.id && $0.toolName == savedTool.toolName
            }) else {
                validationError = "A tool with that name already exists."
                return
            }
            try CustomHTTPToolKeychain().save(headerValue, for: savedTool.id)
            if let index = model.settings.customTools.firstIndex(where: { $0.id == savedTool.id }) {
                model.settings.customTools[index] = savedTool
            } else {
                model.settings.customTools.append(savedTool)
            }
            dismiss()
        } catch {
            validationError = credentialErrorMessage(for: error)
        }
    }

    private func test() {
        do {
            let draft = try makeTool()
            validationError = nil
            testResult = nil
            testing = true
            let arguments = testArgumentsJSON
            let credential = headerValue
            Task {
                do {
                    _ = try await CustomHTTPToolExecutor.execute(
                        draft,
                        argumentsJSON: arguments,
                        headerValue: credential
                    )
                    await MainActor.run {
                        testResult = "Request succeeded."
                        testing = false
                    }
                } catch {
                    await MainActor.run {
                        validationError = credentialErrorMessage(for: error)
                        testing = false
                    }
                }
            }
        } catch {
            validationError = credentialErrorMessage(for: error)
        }
    }

    private func makeTool() throws -> CustomHTTPTool {
        try CustomHTTPTool.make(
                name: name,
                summary: summary,
                endpoint: endpoint,
                parametersJSON: parametersJSON,
                headerName: headerName,
                id: tool?.id ?? UUID()
        )
    }

    private func loadCredential() {
        guard let tool else { return }
        do {
            headerValue = try CustomHTTPToolKeychain().load(for: tool.id) ?? ""
        } catch {
            validationError = "Couldn’t load the saved header value."
        }
    }

    private func credentialErrorMessage(for error: Error) -> String {
        if error is CustomHTTPToolCredentialPersistenceError {
            return "Couldn’t save the header value in Keychain."
        }
        return error.localizedDescription
    }
}
