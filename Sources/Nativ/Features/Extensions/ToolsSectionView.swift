import NativServerKit
import SwiftUI

struct ToolsSectionView: View {
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    @State private var inspecting: ToolItem?

    var body: some View {
        HubSectionScaffold(
            title: "Tools",
            subtitle: "Capabilities tool-capable models can call. Select a tool to inspect or try it."
        ) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 22) {
                toolGroup(title: "Built-in", tools: nativeTools)

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
                    onInspect: { inspecting = tool }
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
                isRunnable: false
            )
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
}

private struct ToolRow: View {
    let tool: ToolItem
    @Binding var isOn: Bool
    let onInspect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
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
                Text("Built-in tools run inside a chat when a tool-capable model calls them.")
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
