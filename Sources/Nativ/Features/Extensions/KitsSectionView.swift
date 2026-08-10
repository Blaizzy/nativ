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
                    if !kit.mcpServers.isEmpty { mcpGroup }
                    if !kit.skills.isEmpty { skillsGroup }
                    if !kit.extensionIDs.isEmpty { extensionsGroup }
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
        KitGroup(title: "MCP servers", caption: "Their tools follow the server configuration and remain manageable under Tools.") {
            ForEach(Array(kit.mcpServers.enumerated()), id: \.offset) { _, target in
                mcpPart(target)
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
    case mcpServers
    case skills
    case extensions

    var id: Self { self }

    var title: String {
        switch self {
        case .mcpServers: "MCP servers"
        case .skills: "Skills"
        case .extensions: "Extensions"
        }
    }

    var symbol: String {
        switch self {
        case .mcpServers: "server.rack"
        case .skills: "sparkles"
        case .extensions: "puzzlepiece.extension"
        }
    }
}

private struct KitEditor: View {
    @State private var kit: UserNativKit
    @State private var picker: KitComponentPicker?
    @ObservedObject var manager: NativExtensionManager
    @ObservedObject var model: NativModel
    let onSave: (UserNativKit) -> Void
    let onCancel: () -> Void

    init(
        kit: UserNativKit,
        manager: NativExtensionManager,
        model: NativModel,
        onSave: @escaping (UserNativKit) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _kit = State(initialValue: kit)
        self.manager = manager
        self.model = model
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        if let picker {
            KitComponentPickerView(
                kind: picker,
                kit: $kit,
                manager: manager,
                model: model,
                onDone: { self.picker = nil }
            )
        } else {
            editor
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(kit.name.isEmpty ? "Create kit" : "Edit kit")
                    .font(.system(size: 17, weight: .semibold))
                Text("Pick the pieces you already use together. You can change each one later in its own section.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Includes")
                    .font(.system(size: 13, weight: .semibold))
                Text("Choose only the components that belong in this setup.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ForEach([KitComponentPicker.mcpServers, .skills, .extensions]) { kind in
                    Button {
                        picker = kind
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: kind.symbol)
                                .frame(width: 18)
                                .foregroundStyle(Color.accentColor)
                            Text(kind.title)
                            Spacer()
                            Text("\(count(for: kind))")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if kind != .extensions { Divider() }
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
        }
        .padding(20)
        .frame(width: 480)
    }

    private func count(for kind: KitComponentPicker) -> Int {
        switch kind {
        case .mcpServers: kit.mcpServerIDs.count
        case .skills: kit.skillIDs.count
        case .extensions: kit.extensionIDs.count
        }
    }
}

private struct KitComponentPickerView: View {
    let kind: KitComponentPicker
    @Binding var kit: UserNativKit
    @ObservedObject var manager: NativExtensionManager
    @ObservedObject var model: NativModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onDone) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to kit")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose \(kind.title)")
                        .font(.system(size: 16, weight: .semibold))
                    Text("A component can belong to more than one kit.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            List {
                switch kind {
                case .mcpServers:
                    if servers.isEmpty {
                        emptyRow("Add an MCP server first, then include it here.")
                    } else {
                        ForEach(servers) { server in
                            selectionRow(
                                title: server.name.isEmpty ? "Untitled server" : server.name,
                                subtitle: server.command,
                                isSelected: kit.mcpServerIDs.contains(server.id)
                            ) {
                                toggle(server.id, in: \.mcpServerIDs)
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
                }
            }
            .listStyle(.inset)
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 500, height: 480)
    }

    private var servers: [MCPServerConfig] {
        model.settings.mcpServers
            .filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var extensions: [NativExtensionRecord] {
        manager.records.filter { !$0.isRemoved && $0.hasRuntime }
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
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
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
    }

    private func toggle<Value: Equatable>(_ value: Value, in keyPath: WritableKeyPath<UserNativKit, [Value]>) {
        if let index = kit[keyPath: keyPath].firstIndex(of: value) {
            kit[keyPath: keyPath].remove(at: index)
        } else {
            kit[keyPath: keyPath].append(value)
        }
    }
}
