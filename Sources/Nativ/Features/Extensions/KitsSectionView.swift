import NativExtensionSDK
import NativServerKit
import SwiftUI

@ViewBuilder
private func kitStateBadge(_ state: NativKitState) -> some View {
    switch state {
    case .enabled:
        NativStatusBadge(text: "Enabled", tone: .success, symbol: "checkmark")
    case let .partial(active, total):
        NativStatusBadge(text: "\(active) of \(total) on", tone: .warning)
    case .off:
        EmptyView()
    }
}

struct KitsSectionView: View {
    @ObservedObject var manager: NativExtensionManager
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    @State private var openKit: NativKit?
    @State private var editingKit: UserNativKit?
    @State private var deletingKit: UserNativKit?

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 14)]

    var body: some View {
        HubSectionScaffold(
            title: "Kits",
            subtitle: "Set up a way of working once, then turn its pieces on together."
        ) {
            Button {
                editingKit = UserNativKit()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Create kit")
        } content: {
            VStack(alignment: .leading, spacing: 22) {
                if !model.settings.userKits.isEmpty {
                    kitGroup(title: "Your kits", kits: model.settings.userKits.map { $0.resolved() })
                }
                kitGroup(title: "Built-in kits", kits: NativKit.all)
            }
        }
        .sheet(item: $openKit) { kit in
            KitDetailView(
                kit: kit,
                manager: manager,
                model: model,
                onEdit: kit.isBuiltIn ? nil : { edit(kit) },
                onDelete: kit.isBuiltIn ? nil : { confirmDelete(kit) }
            )
        }
        .sheet(item: $editingKit) { kit in
            KitEditor(
                kit: kit,
                manager: manager,
                host: host,
                model: model,
                onSave: save,
                onCancel: { editingKit = nil }
            )
        }
        .alert("Delete kit?", isPresented: Binding(
            get: { deletingKit != nil },
            set: { if !$0 { deletingKit = nil } }
        ), presenting: deletingKit) { kit in
            Button("Delete", role: .destructive) {
                model.settings.userKits.removeAll { $0.id == kit.id }
                deletingKit = nil
            }
            Button("Cancel", role: .cancel) {
                deletingKit = nil
            }
        } message: { kit in
            Text("This removes only the kit. Its MCP servers, skills, and extensions stay unchanged.")
        }
    }

    @ViewBuilder
    private func kitGroup(title: String, kits: [NativKit]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(kits) { kit in
                    KitCard(
                        kit: kit,
                        state: NativKitActivation.state(of: kit, model: model, manager: manager),
                        onOpen: { openKit = kit },
                        onEnable: {
                            NativKitActivation.setEnabled(true, kit: kit, model: model, manager: manager)
                        },
                        onEdit: kit.isBuiltIn ? nil : { edit(kit) },
                        onDelete: kit.isBuiltIn ? nil : { confirmDelete(kit) }
                    )
                }
            }
        }
    }

    private func edit(_ kit: NativKit) {
        guard let userKit = model.settings.userKits.first(where: { $0.id.uuidString == kit.id }) else { return }
        openKit = nil
        DispatchQueue.main.async {
            editingKit = userKit
        }
    }

    private func confirmDelete(_ kit: NativKit) {
        guard let userKit = model.settings.userKits.first(where: { $0.id.uuidString == kit.id }) else { return }
        openKit = nil
        deletingKit = userKit
    }

    private func save(_ kit: UserNativKit) {
        if let index = model.settings.userKits.firstIndex(where: { $0.id == kit.id }) {
            model.settings.userKits[index] = kit
        } else {
            model.settings.userKits.append(kit)
        }
        editingKit = nil
    }
}

private struct KitCard: View {
    let kit: NativKit
    let state: NativKitState
    let onOpen: () -> Void
    let onEnable: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                NativTintedIconTile(symbol: kit.symbol, tint: kit.tint)
                Spacer(minLength: 0)
                if kit.isBuiltIn {
                    NativStatusBadge(text: "Built-in")
                        .help("Ships with Nativ")
                }
                kitStateBadge(state)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(kit.name)
                    .font(.system(size: 15, weight: .semibold))
                Text(kit.summary.isEmpty ? "A personal setup." : kit.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
            Text(kit.inventory)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                if state == .off {
                    Button("Enable", action: onEnable)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Details", action: onOpen)
                        .buttonStyle(.plain)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Manage", action: onOpen)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                if let onEdit, let onDelete {
                    Menu {
                        Button("Edit", action: onEdit)
                        Button("Delete", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 22)
                }
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
    }
}

private struct KitDetailView: View {
    let kit: NativKit
    @ObservedObject var manager: NativExtensionManager
    @ObservedObject var model: NativModel
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    private var state: NativKitState { NativKitActivation.state(of: kit, model: model, manager: manager) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !kit.extensionIDs.isEmpty { extensionsGroup }
                    if !kit.mcpServers.isEmpty { mcpGroup }
                    if !kit.toolNames.isEmpty { toolsGroup }
                    if !kit.skills.isEmpty { skillsGroup }
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 560)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            NativTintedIconTile(symbol: kit.symbol, tint: kit.tint, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(kit.name)
                        .font(.system(size: 17, weight: .semibold))
                    kitStateBadge(state)
                }
                Text(kit.summary.isEmpty ? "A personal setup." : kit.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Enable all") {
                        NativKitActivation.setEnabled(true, kit: kit, model: model, manager: manager)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("Disable all") {
                        NativKitActivation.setEnabled(false, kit: kit, model: model, manager: manager)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if let onEdit {
                        Button("Edit", action: onEdit)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 12)
            if let onDelete {
                Menu {
                    Button("Delete kit", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
            NativHoverCloseButton { dismiss() }
        }
        .padding(20)
    }

    private var mcpGroup: some View {
        KitGroup(title: "MCP servers", caption: nil) {
            ForEach(Array(kit.mcpServers.enumerated()), id: \.offset) { _, target in
                mcpPart(target)
            }
        }
    }

    private var toolsGroup: some View {
        KitGroup(title: "Tools", caption: nil) {
            ForEach(kit.toolNames, id: \.self) { name in
                KitPartRow(
                    symbol: "hammer",
                    tint: kit.tint,
                    logoAssetName: nil,
                    title: name,
                    subtitle: nil,
                    isOn: toolBinding(name)
                )
            }
        }
    }

    @ViewBuilder
    private func mcpPart(_ target: NativKitMCP) -> some View {
        switch target {
        case .catalog(let id):
            if let entry = MCPCatalogEntry.catalog.first(where: { $0.id == id }) {
                KitPartRow(
                    symbol: entry.symbol,
                    tint: entry.tint,
                    logoAssetName: entry.logoAssetName,
                    title: entry.name,
                    subtitle: entry.summary,
                    isOn: mcpBinding(target)
                )
            } else {
                KitUnavailablePartRow(title: "Unavailable MCP server", subtitle: "This catalog entry is no longer available.")
            }
        case .configured(let id):
            if let server = model.settings.mcpServers.first(where: { $0.id == id }) {
                KitPartRow(
                    symbol: "server.rack",
                    tint: kit.tint,
                    logoAssetName: nil,
                    title: server.name.isEmpty ? "Untitled server" : server.name,
                    subtitle: nil,
                    isOn: mcpBinding(target)
                )
            } else {
                KitUnavailablePartRow(title: "Unavailable MCP server", subtitle: "This server was removed from Nativ.")
            }
        }
    }

    private var skillsGroup: some View {
        KitGroup(title: "Skills", caption: "Guidance added to the model when tools are available.") {
            ForEach(Array(kit.skills.enumerated()), id: \.offset) { _, target in
                skillPart(target)
            }
        }
    }

    @ViewBuilder
    private func skillPart(_ target: NativKitSkill) -> some View {
        switch target {
        case .builtIn(let skill):
            KitPartRow(
                symbol: "sparkles",
                tint: kit.tint,
                logoAssetName: nil,
                title: skill.name,
                subtitle: nil,
                isOn: skillBinding(target)
            )
        case .configured(let id):
            if let skill = model.settings.skills.first(where: { $0.id == id }) {
                KitPartRow(
                    symbol: "sparkles",
                    tint: kit.tint,
                    logoAssetName: nil,
                    title: skill.name.isEmpty ? "Untitled skill" : skill.name,
                    subtitle: nil,
                    isOn: skillBinding(target)
                )
            } else {
                KitUnavailablePartRow(title: "Unavailable skill", subtitle: "This skill was removed from Nativ.")
            }
        }
    }

    private var extensionsGroup: some View {
        KitGroup(title: "Extensions", caption: nil) {
            ForEach(kit.extensionIDs, id: \.self) { extensionID in
                if let record = manager.records.first(where: { $0.id == extensionID && !$0.isRemoved }) {
                    KitPartRow(
                        symbol: record.manifest.systemImage,
                        tint: kit.tint,
                        logoAssetName: nil,
                        title: record.manifest.displayName,
                        subtitle: record.manifest.summary,
                        isOn: extensionBinding(extensionID)
                    )
                } else {
                    KitUnavailablePartRow(title: "Unavailable extension", subtitle: "This extension is no longer installed.")
                }
            }
        }
    }

    private func mcpBinding(_ target: NativKitMCP) -> Binding<Bool> {
        Binding(
            get: { NativKitActivation.isServerEnabled(target, model: model) },
            set: { NativKitActivation.setServerEnabled($0, target: target, model: model) }
        )
    }

    private func skillBinding(_ target: NativKitSkill) -> Binding<Bool> {
        Binding(
            get: { NativKitActivation.isSkillEnabled(target, model: model) },
            set: { NativKitActivation.setSkillEnabled($0, target: target, model: model) }
        )
    }

    private func toolBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { NativKitActivation.isToolEnabled(name, model: model) },
            set: { NativKitActivation.setToolEnabled($0, name: name, model: model) }
        )
    }

    private func extensionBinding(_ extensionID: String) -> Binding<Bool> {
        Binding(
            get: { manager.isEnabled(extensionID: extensionID) },
            set: { manager.setEnabled($0, extensionID: extensionID) }
        )
    }
}

private struct KitGroup<Content: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                content()
            }
        }
    }
}

private struct KitPartRow: View {
    let symbol: String
    let tint: Color
    let logoAssetName: String?
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            NativTintedIconTile(symbol: symbol, tint: tint, logoAssetName: logoAssetName, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 8)
    }
}

private struct KitUnavailablePartRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            NativTintedIconTile(symbol: "exclamationmark.triangle", tint: .secondary, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text("Unavailable")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

private enum KitComponentPicker: String, Identifiable {
    case extensions
    case mcpServers
    case tools
    case skills

    var id: Self { self }

    var title: String {
        switch self {
        case .extensions: "Extensions"
        case .mcpServers: "MCP servers"
        case .tools: "Tools"
        case .skills: "Skills"
        }
    }

    var symbol: String {
        switch self {
        case .extensions: "puzzlepiece.extension"
        case .mcpServers: "server.rack"
        case .tools: "hammer"
        case .skills: "sparkles"
        }
    }
}

private struct KitEditor: View {
    @State private var kit: UserNativKit
    @State private var picker: KitComponentPicker?
    @ObservedObject var manager: NativExtensionManager
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    let onSave: (UserNativKit) -> Void
    let onCancel: () -> Void

    init(
        kit: UserNativKit,
        manager: NativExtensionManager,
        host: MCPHostManager,
        model: NativModel,
        onSave: @escaping (UserNativKit) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _kit = State(initialValue: kit)
        self.manager = manager
        self.host = host
        self.model = model
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                editor
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 680)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(kit.name.isEmpty ? "Create kit" : "Edit kit")
                .font(.system(size: 21, weight: .semibold))
            Text("Build a reusable setup from the parts you use together.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("e.g. Project research", text: $kit.name)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("What is this setup for?", text: $kit.summary)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Includes")
                    .font(.system(size: 14, weight: .semibold))
                Text("Add components below. A component can belong to more than one kit.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                componentSection(.extensions) {
                    ForEach(kit.extensionIDs, id: \.self) { id in
                        componentTag(
                            title: extensions.first(where: { $0.id == id })?.manifest.displayName ?? id,
                            kind: .extensions
                        ) {
                            remove(id, from: \.extensionIDs)
                        }
                    }
                }
                componentSection(.mcpServers) {
                    ForEach(kit.mcpServerIDs, id: \.self) { id in
                        componentTag(
                            title: servers.first(where: { $0.id == id })?.name ?? "Unavailable server",
                            kind: .mcpServers
                        ) {
                            remove(id, from: \.mcpServerIDs)
                        }
                    }
                }
                componentSection(.tools) {
                    ForEach(kit.toolNames, id: \.self) { name in
                        componentTag(title: name, kind: .tools) {
                            remove(name, from: \.toolNames)
                        }
                    }
                }
                componentSection(.skills) {
                    ForEach(kit.skillIDs, id: \.self) { id in
                        componentTag(
                            title: skills.first(where: { $0.id == id })?.name ?? "Unavailable skill",
                            kind: .skills
                        ) {
                            remove(id, from: \.skillIDs)
                        }
                    }
                }
            }
        }
        .padding(28)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
            Button("Save kit") {
                kit.name = kit.name.trimmingCharacters(in: .whitespacesAndNewlines)
                kit.summary = kit.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                onSave(kit)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!kit.isComplete)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private func count(for kind: KitComponentPicker) -> Int {
        switch kind {
        case .extensions: kit.extensionIDs.count
        case .mcpServers: kit.mcpServerIDs.count
        case .tools: kit.toolNames.count
        case .skills: kit.skillIDs.count
        }
    }

    @ViewBuilder
    private func componentSection<Content: View>(
        _ kind: KitComponentPicker,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                Text(kind.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    picker = kind
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add \(kind.title.lowercased())")
            }
            if count(for: kind) == 0 {
                Text("Nothing added yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                KitTagFlowLayout(spacing: 7) {
                    content()
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .popover(
            isPresented: Binding(
                get: { picker == kind },
                set: { if !$0 { picker = nil } }
            ),
            arrowEdge: .trailing
        ) {
            KitComponentPickerPopover(
                kind: kind,
                kit: $kit,
                manager: manager,
                host: host,
                model: model,
                onDismiss: { picker = nil }
            )
        }
    }

    private func componentTag(
        title: String,
        kind: KitComponentPicker,
        onRemove: @escaping () -> Void
    ) -> some View {
        KitComponentTag(title: title, symbol: kind.symbol, onRemove: onRemove)
    }

    private func remove<Value: Equatable>(
        _ value: Value,
        from keyPath: WritableKeyPath<UserNativKit, [Value]>
    ) {
        kit[keyPath: keyPath].removeAll { $0 == value }
    }

    private var servers: [MCPServerConfig] {
        model.settings.mcpServers
    }

    private var extensions: [NativExtensionRecord] {
        manager.records.filter { !$0.isRemoved }
    }

    private var skills: [NativSkill] {
        model.settings.skills
    }
}

private struct KitComponentPickerPopover: View {
    let kind: KitComponentPicker
    @Binding var kit: UserNativKit
    @ObservedObject var manager: NativExtensionManager
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add \(kind.title.lowercased())")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done", action: onDismiss)
                    .controlSize(.small)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                switch kind {
                case .extensions:
                    if extensions.isEmpty {
                        emptyRow("Install an extension first, then include it here.")
                    } else {
                        ForEach(extensions) { record in
                            selectionRow(
                                title: record.manifest.displayName,
                                subtitle: record.manifest.summary,
                                isSelected: kit.extensionIDs.contains(record.id)
                            ) {
                                toggle(record.id, in: \.extensionIDs)
                            }
                        }
                    }
                case .mcpServers:
                    if servers.isEmpty {
                        emptyRow("Add an MCP server first, then include it here.")
                    } else {
                        ForEach(servers) { server in
                            selectionRow(
                                title: server.name.isEmpty ? "Untitled server" : server.name,
                                subtitle: "",
                                isSelected: kit.mcpServerIDs.contains(server.id)
                            ) {
                                toggle(server.id, in: \.mcpServerIDs)
                            }
                        }
                    }
                case .tools:
                    if tools.isEmpty {
                        emptyRow("Connect an MCP server first, then include its tools here.")
                    } else {
                        ForEach(tools) { tool in
                            selectionRow(
                                title: tool.title,
                                subtitle: "",
                                isSelected: kit.toolNames.contains(tool.name)
                            ) {
                                toggle(tool.name, in: \.toolNames)
                            }
                        }
                    }
                case .skills:
                    if model.settings.skills.isEmpty {
                        emptyRow("Add a skill first, then include it here.")
                    } else {
                        ForEach(model.settings.skills) { skill in
                            selectionRow(
                                title: skill.name.isEmpty ? "Untitled skill" : skill.name,
                                subtitle: skill.instructions,
                                isSelected: kit.skillIDs.contains(skill.id)
                            ) {
                                toggle(skill.id, in: \.skillIDs)
                            }
                        }
                    }
                }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 330, height: 320)
    }

    private var servers: [MCPServerConfig] {
        model.settings.mcpServers
            .filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var extensions: [NativExtensionRecord] {
        manager.records.filter { !$0.isRemoved }
    }

    private var tools: [ToolItem] {
        let tools = NativToolCatalog.builtIns()
            + model.settings.mcpServers.flatMap { NativToolCatalog.mcpTools(for: $0, host: host) }
        var names = Set<String>()
        return tools
            .filter { names.insert($0.name).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    @ViewBuilder
    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.vertical, 12)
    }

    private func selectionRow(
        title: String,
        subtitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func toggle<Value: Equatable>(_ value: Value, in keyPath: WritableKeyPath<UserNativKit, [Value]>) {
        if let index = kit[keyPath: keyPath].firstIndex(of: value) {
            kit[keyPath: keyPath].remove(at: index)
        } else {
            kit[keyPath: keyPath].append(value)
        }
    }
}

private struct KitComponentTag: View {
    let title: String
    let symbol: String
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(isHovering ? 0.85 : 0)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(isHovering ? 0.09 : 0.055), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Remove \(title)")
        .onHover { isHovering = $0 }
    }
}

private struct KitTagFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, points: [CGPoint]) {
        let availableWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0
        var points: [CGPoint] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > availableWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            width = max(width, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }

        return (CGSize(width: width, height: y + rowHeight), points)
    }
}
