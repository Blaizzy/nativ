import AppKit
import NativServerKit
import SwiftUI

struct MCPCatalogEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let category: String
    let icon: String
    let command: String
    let args: [String]
    var requiredEnv: [String] = []
    var requiresFolder: Bool = false
    var sourceURL: String?
    var official: Bool = false
    var logo: String?

    var needsSetup: Bool { !requiredEnv.isEmpty || requiresFolder }

    var logoImage: NSImage? {
        guard let logo, !logo.isEmpty, let base = Bundle.main.resourceURL else {
            return nil
        }
        return NSImage(contentsOf: base.appendingPathComponent("ToolCatalogIcons/\(logo)"))
    }

    static let seed: [MCPCatalogEntry] = [
        MCPCatalogEntry(
            id: "fetch",
            name: "Fetch",
            description: "Fetch a URL and hand the model the page contents.",
            category: "Web",
            icon: "globe",
            command: "uvx",
            args: ["--with", "mcp==1.12.0", "mcp-server-fetch"],
            sourceURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/fetch"
        ),
        MCPCatalogEntry(
            id: "sequential-thinking",
            name: "Sequential Thinking",
            description: "A structured scratchpad for step-by-step reasoning.",
            category: "Reasoning",
            icon: "brain",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-sequential-thinking"],
            sourceURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking"
        ),
        MCPCatalogEntry(
            id: "memory",
            name: "Memory",
            description: "A persistent knowledge-graph memory across chats.",
            category: "Utilities",
            icon: "externaldrive",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-memory"],
            sourceURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/memory"
        ),
        MCPCatalogEntry(
            id: "time",
            name: "Time",
            description: "Current time and timezone conversions.",
            category: "Utilities",
            icon: "clock",
            command: "uvx",
            args: ["--with", "mcp==1.12.0", "mcp-server-time"],
            sourceURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/time"
        ),
        MCPCatalogEntry(
            id: "filesystem",
            name: "Filesystem",
            description: "Read and write files in a folder you choose.",
            category: "Files",
            icon: "folder",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem"],
            requiresFolder: true,
            sourceURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem"
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
            sourceURL: "https://github.com/github/github-mcp-server"
        ),
    ]
}

extension MCPCatalogEntry: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, name, description, category, icon, command, args
        case requiredEnv, requiresFolder, sourceURL, official, logo
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
        requiresFolder = try container.decodeIfPresent(Bool.self, forKey: .requiresFolder) ?? false
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        official = try container.decodeIfPresent(Bool.self, forKey: .official) ?? false
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
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

    private let catalog = MCPCatalog.load()

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.leading, titleLeadingInset)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        BuiltInToolsPanel(disabledToolNames: $model.settings.disabledToolNames)

                        MCPServersPanel(
                            host: model.mcpHost,
                            servers: $model.settings.mcpServers,
                            disabledToolNames: $model.settings.disabledToolNames
                        )
                    }
                    .padding(20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                CatalogColumn(
                    entries: catalog,
                    addedNames: Set(model.settings.mcpServers.map(\.name)),
                    onAdd: add
                )
                .frame(width: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.nativMainContentBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tools")
                .font(.title2.weight(.semibold))
            Text("Connect Model Context Protocol servers to give your models tools. Add one from the catalog or configure your own.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func add(_ entry: MCPCatalogEntry, environment: [String: String], extraArgs: [String]) {
        guard !model.settings.mcpServers.contains(where: { $0.name == entry.name }) else { return }
        model.settings.mcpServers.append(
            MCPServerConfig(
                name: entry.name,
                command: entry.command,
                arguments: entry.args + extraArgs,
                environment: environment,
                isEnabled: true
            )
        )
    }
}

private struct BuiltInToolsPanel: View {
    @Binding var disabledToolNames: [String]

    private struct Item: Identifiable {
        let id: String
        let title: String
        let description: String
        let icon: String
    }

    private let items: [Item] = [
        Item(
            id: "get_system_stats",
            title: "System stats",
            description: "CPU, GPU, memory, and disk usage on this Mac.",
            icon: "cpu"
        ),
        Item(
            id: "get_server_stats",
            title: "Server stats",
            description: "Requests, tokens, speed, and time to first token.",
            icon: "chart.line.uptrend.xyaxis"
        ),
        Item(
            id: "list_models",
            title: "List models",
            description: "Downloaded MLX models with size and quantization.",
            icon: "shippingbox"
        ),
        Item(
            id: "generate_image",
            title: "Generate image",
            description: "Create images from a prompt (needs an image model).",
            icon: "photo"
        ),
        Item(
            id: "edit_image",
            title: "Edit image",
            description: "Edit an attached or generated image (needs an image model).",
            icon: "photo.badge.plus"
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Built-in")
                    .font(.headline)
                Text("Nativ's own tools — always available, no setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(items) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.callout.weight(.medium))
                        Text(item.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: binding(for: item.id))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !disabledToolNames.contains(id) },
            set: { enabled in
                if enabled {
                    disabledToolNames.removeAll { $0 == id }
                } else if !disabledToolNames.contains(id) {
                    disabledToolNames.append(id)
                }
            }
        )
    }
}

private struct CatalogColumn: View {
    let entries: [MCPCatalogEntry]
    let addedNames: Set<String>
    let onAdd: (MCPCatalogEntry, [String: String], [String]) -> Void
    @State private var query = ""

    private var filtered: [MCPCatalogEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return entries }
        return entries.filter {
            $0.name.lowercased().contains(trimmed)
                || $0.description.lowercased().contains(trimmed)
                || $0.category.lowercased().contains(trimmed)
        }
    }

    private var officialEntries: [MCPCatalogEntry] { filtered.filter(\.official) }
    private var communityEntries: [MCPCatalogEntry] { filtered.filter { !$0.official } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Catalog")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 4)
            Text("Browse servers and enable one to add its tools.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.1)))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group(title: "Official", entries: officialEntries, emptyMessage: nil)
                    group(
                        title: "Community",
                        entries: communityEntries,
                        emptyMessage: query.isEmpty ? "Community-contributed servers appear here." : nil
                    )
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04))
    }

    @ViewBuilder
    private func group(title: String, entries: [MCPCatalogEntry], emptyMessage: String?) -> some View {
        if !entries.isEmpty || emptyMessage != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if entries.isEmpty, let emptyMessage {
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(entries) { entry in
                        CatalogCard(
                            entry: entry,
                            isAdded: addedNames.contains(entry.name),
                            onAdd: { env, extraArgs in onAdd(entry, env, extraArgs) }
                        )
                    }
                }
            }
        }
    }
}

private struct CatalogCard: View {
    let entry: MCPCatalogEntry
    let isAdded: Bool
    let onAdd: ([String: String], [String]) -> Void

    @State private var envValues: [String: String] = [:]
    @State private var folderPath: String = ""
    @State private var isHovering = false

    private var isReady: Bool {
        let envFilled = entry.requiredEnv.allSatisfy { !(envValues[$0] ?? "").isEmpty }
        let folderFilled = !entry.requiresFolder || !folderPath.isEmpty
        return envFilled && folderFilled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if let image = entry.logoImage {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: entry.icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.callout.weight(.semibold))
                    Text(entry.category)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let sourceURL = entry.sourceURL, let url = URL(string: sourceURL) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .foregroundStyle(.secondary)
                    .help("Open source")
                }
            }

            Text(entry.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !isAdded {
                if !entry.requiredEnv.isEmpty {
                    ForEach(entry.requiredEnv, id: \.self) { key in
                        SecureField(
                            key,
                            text: Binding(
                                get: { envValues[key] ?? "" },
                                set: { envValues[key] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    }
                }
                if entry.requiresFolder {
                    HStack(spacing: 6) {
                        Button("Choose Folder…", action: chooseFolder)
                            .controlSize(.small)
                        Text(folderPath.isEmpty ? "No folder" : (folderPath as NSString).lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            HStack {
                Spacer()
                if isAdded {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    Button {
                        onAdd(envValues, entry.requiresFolder && !folderPath.isEmpty ? [folderPath] : [])
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!isReady)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovering ? Color.accentColor.opacity(0.05) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }
}
