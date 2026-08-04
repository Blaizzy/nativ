import NativExtensionSDK
import NativServerKit
import SwiftUI

/// The badge shown on a kit card/header for its derived activation state.
@ViewBuilder
private func kitStateBadge(_ state: NativKitState) -> some View {
    switch state {
    case .enabled:
        NativStatusBadge(text: "Enabled", tone: .success, symbol: "checkmark")
    case .partial:
        NativStatusBadge(text: "Partial", tone: .warning)
    case .off:
        EmptyView()
    }
}

struct KitsSectionView: View {
    @ObservedObject var manager: NativExtensionManager
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    @State private var openKit: NativKit?

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 14)]

    var body: some View {
        HubSectionScaffold(
            title: "Kits",
            subtitle: "Ready-made setups. Enable one to turn on the MCP servers, skills, and extensions for a way of working — then manage any piece on its own."
        ) {
            EmptyView()
        } content: {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(NativKit.all) { kit in
                    KitCard(
                        kit: kit,
                        state: NativKitActivation.state(of: kit, model: model, manager: manager),
                        onOpen: { openKit = kit },
                        onEnable: { NativKitActivation.setEnabled(true, kit: kit, model: model, manager: manager) }
                    )
                }
            }
        }
        .sheet(item: $openKit) { kit in
            KitDetailView(kit: kit, manager: manager, host: host, model: model)
        }
    }
}

private struct KitCard: View {
    let kit: NativKit
    let state: NativKitState
    let onOpen: () -> Void
    let onEnable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                NativTintedIconTile(symbol: kit.symbol, tint: kit.tint)
                Spacer(minLength: 0)
                kitStateBadge(state)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(kit.name)
                    .font(.system(size: 15, weight: .semibold))
                Text(kit.summary)
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
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    @Environment(\.dismiss) private var dismiss

    private var state: NativKitState { NativKitActivation.state(of: kit, model: model, manager: manager) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    mcpGroup
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
                Text(kit.summary)
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
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 12)
            NativHoverCloseButton { dismiss() }
        }
        .padding(20)
    }

    // MARK: Groups

    private var mcpGroup: some View {
        KitGroup(title: "MCP servers & tools", caption: "Their tools become available in chat and appear under Tools.") {
            ForEach(kit.mcpEntries) { entry in
                KitPartRow(
                    symbol: entry.symbol,
                    tint: entry.tint,
                    logoAssetName: entry.logoAssetName,
                    title: entry.name,
                    subtitle: entry.summary,
                    isOn: mcpBinding(entry)
                )
            }
        }
    }

    private var skillsGroup: some View {
        KitGroup(title: "Skills", caption: "Guidance added to the model when tools are available.") {
            ForEach(kit.skills) { skill in
                KitPartRow(
                    symbol: "sparkles",
                    tint: kit.tint,
                    logoAssetName: nil,
                    title: skill.name,
                    subtitle: nil,
                    isOn: skillBinding(skill)
                )
            }
        }
    }

    private var extensionsGroup: some View {
        KitGroup(title: "Extensions", caption: nil) {
            ForEach(kit.extensionIDs, id: \.self) { extensionID in
                KitPartRow(
                    symbol: "puzzlepiece.extension",
                    tint: kit.tint,
                    logoAssetName: nil,
                    title: extensionName(extensionID),
                    subtitle: nil,
                    isOn: extensionBinding(extensionID)
                )
            }
        }
    }

    // MARK: Bindings

    private func mcpBinding(_ entry: MCPCatalogEntry) -> Binding<Bool> {
        // Match by launch identity (command + arguments), not name, so the
        // toggle never targets an unrelated server that shares a name.
        func matches(_ server: MCPServerConfig) -> Bool {
            server.command == entry.command && server.arguments == entry.arguments
        }
        return Binding(
            get: { model.settings.mcpServers.first(where: matches)?.isEnabled ?? false },
            set: { newValue in
                if let index = model.settings.mcpServers.firstIndex(where: matches) {
                    model.settings.mcpServers[index].isEnabled = newValue
                } else if newValue {
                    model.settings.mcpServers.append(entry.makeConfig())
                }
            }
        )
    }

    private func skillBinding(_ skill: NativSkill) -> Binding<Bool> {
        Binding(
            get: { model.settings.skills.first { $0.id == skill.id }?.isEnabled ?? false },
            set: { newValue in
                if let index = model.settings.skills.firstIndex(where: { $0.id == skill.id }) {
                    model.settings.skills[index].isEnabled = newValue
                } else if newValue {
                    var enabled = skill
                    enabled.isEnabled = true
                    model.settings.skills.append(enabled)
                }
            }
        )
    }

    private func extensionBinding(_ extensionID: String) -> Binding<Bool> {
        Binding(
            get: { manager.isEnabled(extensionID: extensionID) },
            set: { manager.setEnabled($0, extensionID: extensionID) }
        )
    }

    private func extensionName(_ extensionID: String) -> String {
        manager.records.first { $0.id == extensionID }?.manifest.displayName ?? extensionID
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
