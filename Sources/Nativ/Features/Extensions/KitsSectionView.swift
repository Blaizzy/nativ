import NativServerKit
import SwiftUI

@ViewBuilder
private func kitStateBadge(_ state: NativKitState) -> some View {
    switch state {
    case .enabled:
        NativStatusBadge(text: "Enabled", tone: .success, symbol: "checkmark")
    case .partial:
        NativStatusBadge(text: "Needs setup", tone: .warning)
    case .off:
        EmptyView()
    }
}

struct KitsSectionView: View {
    @ObservedObject var manager: NativExtensionManager
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    @ObservedObject var store: NativKitStore
    @State private var openKit: NativKit?
    @State private var editingKit: UserNativKit?
    @State private var deletingKit: UserNativKit?

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 14)]

    var body: some View {
        HubSectionScaffold(
            title: "Kits",
            subtitle: "Set up a way of working once, then make its capabilities available together."
        ) {
            Button {
                editingKit = UserNativKit()
            } label: {
                Label("Create kit", systemImage: "plus")
            }
        } content: {
            VStack(alignment: .leading, spacing: 22) {
                if !store.userKits.isEmpty {
                    kitGroup(title: "Your kits", kits: store.userKits.map { $0.resolved() })
                }
                kitGroup(title: "Built-in kits", kits: NativKit.builtIns)
            }
        }
        .sheet(item: $openKit) { kit in
            KitDetailView(
                kit: kit,
                manager: manager,
                host: host,
                model: model,
                onEdit: kit.isBuiltIn ? nil : { edit(kit) },
                onDelete: kit.isBuiltIn ? nil : { confirmDelete(kit) }
            )
        }
        .sheet(item: $editingKit) { kit in
            NativKitEditor(
                kit: kit,
                manager: manager,
                host: host,
                model: model,
                onSave: { saved in
                    store.upsert(saved)
                    editingKit = nil
                },
                onCancel: { editingKit = nil }
            )
        }
        .alert(
            "Delete kit?",
            isPresented: Binding(
                get: { deletingKit != nil },
                set: { if !$0 { deletingKit = nil } }
            ),
            presenting: deletingKit
        ) { kit in
            Button("Delete", role: .destructive) {
                store.delete(id: kit.id)
                deletingKit = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                deletingKit = nil
            }
        } message: { _ in
            Text("The kit is removed, but its components stay configured. Routines that selected it will fail until you choose another kit.")
        }
    }

    private var activation: NativKitActivationCoordinator {
        NativKitActivationCoordinator(model: model, manager: manager, host: host)
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
                        state: activation.state(of: kit),
                        capabilityNames: activation.componentNames(of: kit),
                        inactiveParts: activation.inactiveComponentNames(of: kit),
                        onOpen: { openKit = kit },
                        onEnable: { Task { await activation.activate(kit) } },
                        onEdit: kit.isBuiltIn ? nil : { edit(kit) },
                        onDelete: kit.isBuiltIn ? nil : { confirmDelete(kit) }
                    )
                }
            }
        }
    }

    private func edit(_ kit: NativKit) {
        guard let id = UUID(uuidString: kit.id), let userKit = store.userKit(id: id) else { return }
        openKit = nil
        Task { @MainActor in editingKit = userKit }
    }

    private func confirmDelete(_ kit: NativKit) {
        guard let id = UUID(uuidString: kit.id), let userKit = store.userKit(id: id) else { return }
        openKit = nil
        deletingKit = userKit
    }
}

private struct KitCard: View {
    let kit: NativKit
    let state: NativKitState
    let capabilityNames: [String]
    let inactiveParts: [String]
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
            Text(capabilitiesText)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
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
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
    }

    private var capabilitiesText: String {
        if case .partial = state {
            return "Off: \(inactiveParts.joined(separator: " · "))"
        }
        return "Includes: \(capabilityNames.joined(separator: " · "))"
    }
}

private struct KitDetailView: View {
    let kit: NativKit
    @ObservedObject var manager: NativExtensionManager
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    private var activation: NativKitActivationCoordinator {
        NativKitActivationCoordinator(model: model, manager: manager, host: host)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                NativTintedIconTile(symbol: kit.symbol, tint: kit.tint, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(kit.name).font(.system(size: 17, weight: .semibold))
                        kitStateBadge(activation.state(of: kit))
                    }
                    Text(kit.summary.isEmpty ? "A personal setup." : kit.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Make available") {
                            Task { await activation.activate(kit) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        if let onEdit { Button("Edit", action: onEdit).controlSize(.small) }
                        if let onDelete {
                            Button("Delete", role: .destructive, action: onDelete)
                                .controlSize(.small)
                        }
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 12)
                NativHoverCloseButton { dismiss() }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !kit.extensionIDs.isEmpty {
                        componentGroup("Extensions", values: kit.extensionIDs.map(extensionName))
                    }
                    if !kit.mcpServers.isEmpty {
                        componentGroup("MCP servers", values: kit.mcpServers.map(serverName))
                    }
                    if !kit.mcpTools.isEmpty {
                        componentGroup("MCP tools", values: kit.mcpTools.map { $0.name })
                    }
                    if !kit.builtInToolNames.isEmpty {
                        componentGroup("Built-in tools", values: kit.builtInToolNames)
                    }
                    if !kit.customToolIDs.isEmpty {
                        componentGroup("Custom tools", values: kit.customToolIDs.map(customToolName))
                    }
                    if !kit.skills.isEmpty {
                        componentGroup("Skills", values: kit.skills.map(skillName))
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 520)
    }

    private func componentGroup(_ title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
            }
        }
    }

    private func serverName(_ reference: NativKitMCPServer) -> String {
        switch reference {
        case .catalog(let id):
            return MCPCatalogEntry.catalog.first(where: { $0.id == id })?.name ?? "Unavailable server"
        case .configured(let id):
            return model.settings.mcpServers.first(where: { $0.id == id })?.name ?? "Unavailable server"
        }
    }

    private func skillName(_ reference: NativKitSkillReference) -> String {
        switch reference {
        case .builtIn(let skill): skill.name
        case .configured(let id):
            model.settings.skills.first(where: { $0.id == id })?.name ?? "Unavailable skill"
        }
    }

    private func extensionName(_ id: String) -> String {
        manager.records.first(where: { $0.id == id })?.manifest.displayName ?? "Unavailable extension"
    }

    private func customToolName(_ id: UUID) -> String {
        model.settings.customTools.first(where: { $0.id == id })?.name ?? "Unavailable custom tool"
    }
}
