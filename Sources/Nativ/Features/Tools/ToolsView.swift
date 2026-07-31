import NativServerKit
import SwiftUI

private enum ToolsSection: String, CaseIterable, Identifiable {
    case explore = "Explore"
    case mcp = "MCP"
    case active = "Active"

    var id: String { rawValue }
}

struct MCPCatalogEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let category: String
    let icon: String
    let command: String
    let args: [String]
    var requiredEnv: [String] = []
    var needsSetup: Bool = false

    static let seed: [MCPCatalogEntry] = [
        MCPCatalogEntry(
            id: "fetch",
            name: "Fetch",
            description: "Fetch a URL and hand the model the page contents.",
            category: "Web",
            icon: "globe",
            command: "uvx",
            args: ["mcp-server-fetch"]
        ),
        MCPCatalogEntry(
            id: "sequential-thinking",
            name: "Sequential Thinking",
            description: "A structured scratchpad for step-by-step reasoning.",
            category: "Reasoning",
            icon: "brain",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-sequential-thinking"]
        ),
        MCPCatalogEntry(
            id: "memory",
            name: "Memory",
            description: "A persistent knowledge-graph memory across chats.",
            category: "Utilities",
            icon: "externaldrive",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-memory"]
        ),
        MCPCatalogEntry(
            id: "time",
            name: "Time",
            description: "Current time and timezone conversions.",
            category: "Utilities",
            icon: "clock",
            command: "uvx",
            args: ["mcp-server-time"]
        ),
        MCPCatalogEntry(
            id: "filesystem",
            name: "Filesystem",
            description: "Read and write files in a folder you choose.",
            category: "Files",
            icon: "folder",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem"],
            needsSetup: true
        ),
        MCPCatalogEntry(
            id: "github",
            name: "GitHub",
            description: "Search repositories, issues, and pull requests.",
            category: "Development",
            icon: "chevron.left.forwardslash.chevron.right",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-github"],
            requiredEnv: ["GITHUB_PERSONAL_ACCESS_TOKEN"],
            needsSetup: true
        ),
    ]
}

extension MCPCatalogEntry: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, name, description, category, icon, command, args, requiredEnv, needsSetup
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "Other"
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "wrench.and.screwdriver"
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        requiredEnv = try container.decodeIfPresent([String].self, forKey: .requiredEnv) ?? []
        needsSetup =
            try container.decodeIfPresent(Bool.self, forKey: .needsSetup) ?? !requiredEnv.isEmpty
    }
}

enum MCPCatalog {
    static func load() -> [MCPCatalogEntry] {
        guard let url = Bundle.main.url(forResource: "ToolCatalog", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let entries = try? JSONDecoder().decode([MCPCatalogEntry].self, from: data),
            !entries.isEmpty
        else {
            return MCPCatalogEntry.seed
        }
        return entries
    }
}

struct ToolsView: View {
    @ObservedObject var model: NativModel
    var titleLeadingInset: CGFloat = 0
    @State private var section: ToolsSection = .explore
    @State private var pendingEntry: MCPCatalogEntry?
    @State private var pendingEnv: [String: String] = [:]

    private let catalog = MCPCatalog.load()

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.leading, titleLeadingInset)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.nativMainContentBackground)
        .sheet(item: $pendingEntry) { entry in
            ToolSetupSheet(
                entry: entry,
                values: $pendingEnv,
                onCancel: { pendingEntry = nil },
                onAdd: {
                    appendServer(entry, environment: pendingEnv, enabled: true)
                    pendingEntry = nil
                    section = .mcp
                }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tools")
                    .font(.title2.weight(.semibold))
                Text("Give your models tools — browse the catalog, connect MCP servers, and manage what they can call.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            sectionPicker
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sectionPicker: some View {
        Picker("Section", selection: $section) {
            ForEach(ToolsSection.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 260, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .explore:
            ToolsExploreView(
                entries: catalog,
                addedNames: Set(model.settings.mcpServers.map(\.name)),
                onAdd: add
            )
        case .mcp:
            ScrollView {
                MCPServersPanel(host: model.mcpHost, servers: $model.settings.mcpServers)
                    .padding(22)
            }
        case .active:
            ToolsActiveView(model: model, host: model.mcpHost)
        }
    }

    private func add(_ entry: MCPCatalogEntry) {
        guard !model.settings.mcpServers.contains(where: { $0.name == entry.name }) else { return }
        if entry.requiredEnv.isEmpty {
            appendServer(entry, environment: [:], enabled: !entry.needsSetup)
            section = .mcp
        } else {
            pendingEnv = [:]
            pendingEntry = entry
        }
    }

    private func appendServer(
        _ entry: MCPCatalogEntry,
        environment: [String: String],
        enabled: Bool
    ) {
        guard !model.settings.mcpServers.contains(where: { $0.name == entry.name }) else { return }
        model.settings.mcpServers.append(
            MCPServerConfig(
                name: entry.name,
                command: entry.command,
                arguments: entry.args,
                environment: environment,
                isEnabled: enabled
            )
        )
    }
}

private struct ToolSetupSheet: View {
    let entry: MCPCatalogEntry
    @Binding var values: [String: String]
    let onCancel: () -> Void
    let onAdd: () -> Void

    private var isIncomplete: Bool {
        entry.requiredEnv.contains { (values[$0] ?? "").isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up \(entry.name)")
                    .font(.headline)
                Text("This server needs the values below to run. They're saved to your settings on this Mac only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(entry.requiredEnv, id: \.self) { key in
                VStack(alignment: .leading, spacing: 4) {
                    Text(key)
                        .font(.caption.weight(.medium))
                    SecureField(
                        key,
                        text: Binding(
                            get: { values[key] ?? "" },
                            set: { values[key] = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Add", action: onAdd)
                    .buttonStyle(.borderedProminent)
                    .disabled(isIncomplete)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct ToolsExploreView: View {
    let entries: [MCPCatalogEntry]
    let addedNames: Set<String>
    let onAdd: (MCPCatalogEntry) -> Void

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(entries) { entry in
                    ToolCatalogCard(
                        entry: entry,
                        isAdded: addedNames.contains(entry.name),
                        onAdd: { onAdd(entry) }
                    )
                }
            }
            .padding(24)
        }
    }
}

private struct ToolCatalogCard: View {
    let entry: MCPCatalogEntry
    let isAdded: Bool
    let onAdd: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Image(systemName: entry.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 52, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )
                Spacer()
                Text(entry.category)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.name)
                    .font(.title3.bold())
                Text(entry.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if isAdded {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    Button(action: onAdd) {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
                if entry.needsSetup {
                    Label("Needs setup", systemImage: "gearshape")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 185, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isHovering ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isHovering ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
        .onHover { isHovering = $0 }
    }
}

private struct ToolsActiveView: View {
    @ObservedObject var model: NativModel
    @ObservedObject var host: MCPHostManager

    private var context: ChatToolExecutionContext {
        ChatToolExecutionContext(
            imageGenerationModelID: model.settings.imageGenerationModelID,
            baseURL: model.settings.serverBaseURL,
            apiKey: model.settings.serverAPIKey,
            imageReferences: [],
            modelSearchPath: model.settings.expandedModelSearchPath,
            additionalModelSearchPaths: model.settings.additionalModelSearchPaths
        )
    }

    private var builtIn: [MLXChatToolDefinition] {
        ChatToolRegistry.definitions(context: context, canEditImage: false)
    }

    private var mcp: [MLXChatToolDefinition] {
        host.toolDefinitions()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                group(
                    title: "Built-in",
                    subtitle: "Bundled tools, available to any tool-capable model.",
                    tools: builtIn
                )
                if !mcp.isEmpty {
                    group(
                        title: "From MCP servers",
                        subtitle: "Provided by your connected servers.",
                        tools: mcp
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private func isEnabled(_ name: String) -> Bool {
        !model.settings.disabledToolNames.contains(name)
    }

    private func setEnabled(_ name: String, _ enabled: Bool) {
        if enabled {
            model.settings.disabledToolNames.removeAll { $0 == name }
        } else if !model.settings.disabledToolNames.contains(name) {
            model.settings.disabledToolNames.append(name)
        }
    }

    private func group(title: String, subtitle: String, tools: [MLXChatToolDefinition]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(tools.enumerated()), id: \.element.function.name) { index, tool in
                    ToolRow(
                        name: tool.function.name,
                        description: tool.function.description,
                        isOn: isEnabled(tool.function.name),
                        onToggle: { setEnabled(tool.function.name, $0) }
                    )
                    if index < tools.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

private struct ToolRow: View {
    let name: String
    let description: String
    let isOn: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ChatToolPresentation.symbolName(toolName: name, status: nil))
                .font(.system(size: 15))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(ChatToolPresentation.title(toolName: name, status: nil))
                    .font(.callout.weight(.medium))
                if !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(get: { isOn }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .opacity(isOn ? 1 : 0.55)
    }
}
