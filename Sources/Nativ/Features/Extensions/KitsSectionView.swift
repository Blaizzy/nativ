import NativExtensionSDK
import NativServerKit
import SwiftUI

private struct KitStateIcon: View {
    let state: NativKitState

    var body: some View {
        Image(systemName: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .accessibilityLabel("Kit status: \(title)")
            .help(title)
    }

    private var title: String {
        switch state {
        case .off: "Not enabled"
        case .partial: "Partially enabled"
        case .enabled: "Enabled"
        }
    }

    private var symbol: String {
        switch state {
        case .off: "circle"
        case .partial: "circle.lefthalf.filled"
        case .enabled: "circle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .off: .secondary
        case .partial: .orange
        case .enabled: .green
        }
    }
}

struct KitsSectionView: View {
    @ObservedObject var manager: NativExtensionManager
    var model: NativModel
    @State private var openKit: NativKit?

    private static let columns = [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 14)]

    var body: some View {
        HubSectionScaffold(
            title: "Kits",
            subtitle: "Ready-made setups. Enable one to turn on the MCP servers, skills, and extensions for a way of working — then manage any piece on its own."
        ) {
            EmptyView()
        } content: {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 14) {
                ForEach(NativKitCatalog.bundled.kits) { kit in
                    kitCard(for: kit)
                }
            }
        }
        .sheet(item: $openKit) { kit in
            KitDetailView(kit: kit, manager: manager, model: model)
        }
    }

    private func kitCard(for kit: NativKit) -> some View {
        let snapshot = NativKitActivation.snapshot(
            of: kit,
            model: model,
            extensionName: extensionName,
            isExtensionEnabled: manager.isEnabled(extensionID:)
        )
        return KitCard(
            kit: kit,
            snapshot: snapshot,
            onOpen: { openKit = kit },
            onEnable: { enableMissing(in: kit) }
        )
    }

    private func extensionName(_ id: String) -> String {
        manager.records.first { $0.id == id }?.manifest.displayName ?? id
    }

    private func enableMissing(in kit: NativKit) {
        NativKitActivation.enableMissing(
            in: kit,
            model: model,
            isExtensionEnabled: manager.isEnabled(extensionID:),
            enableExtension: { manager.setEnabled(true, extensionID: $0) }
        )
    }
}

private struct KitCard: View {
    let kit: NativKit
    let snapshot: NativKitActivationSnapshot
    let onOpen: () -> Void
    let onEnable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                NativTintedIconTile(symbol: kit.symbol, tint: .nativTint(kit.tintName))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                NativStatusBadge(text: "Built-in")
                    .help("Ships with Nativ")
                KitStateIcon(state: snapshot.state)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(kit.name)
                    .nativTextStyle(.cardTitle)
                Text(kit.summary)
                    .nativTextStyle(.supporting)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(capabilitiesText)
                .nativTextStyle(.metadata)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    actions
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) {
                    actions
                }
            }
            .nativTextStyle(.supporting)
            .controlSize(.regular)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }

    private var capabilitiesText: String {
        if snapshot.state == .partial {
            "Needs: \(snapshot.inactivePartNames.joined(separator: " · "))"
        } else {
            "Includes: \(kit.capabilityNames(in: .bundled).joined(separator: " · "))"
        }
    }

    @ViewBuilder
    private var actions: some View {
        if snapshot.state != .enabled {
            Button(snapshot.state == .partial ? "Enable Missing" : "Enable", action: onEnable)
                .buttonStyle(.borderedProminent)
        }
        Button(snapshot.state == .off ? "Details" : "Manage", action: onOpen)
            .buttonStyle(.bordered)
    }
}

private struct KitDetailView: View {
    let kit: NativKit
    @ObservedObject var manager: NativExtensionManager
    var model: NativModel
    @Environment(\.dismiss) private var dismiss

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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .presentationSizing(.fitted)
        .frame(
            minWidth: 600,
            idealWidth: 680,
            maxWidth: 920,
            minHeight: 480,
            idealHeight: 620,
            maxHeight: 800
        )
    }

    private var header: some View {
        let snapshot = NativKitActivation.snapshot(
            of: kit,
            model: model,
            extensionName: extensionName,
            isExtensionEnabled: manager.isEnabled(extensionID:)
        )
        return HStack(alignment: .top, spacing: 12) {
            NativTintedIconTile(symbol: kit.symbol, tint: .nativTint(kit.tintName), size: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(kit.name)
                        .nativTextStyle(.detailTitle)
                    KitStateIcon(state: snapshot.state)
                }
                Text(kit.summary)
                    .nativTextStyle(.supporting)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if snapshot.state != .enabled {
                    Button(snapshot.state == .partial ? "Enable Missing" : "Enable All") {
                        NativKitActivation.enableMissing(
                            in: kit,
                            model: model,
                            isExtensionEnabled: manager.isEnabled(extensionID:),
                            enableExtension: { manager.setEnabled(true, extensionID: $0) }
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 12)
            NativHoverCloseButton { dismiss() }
        }
        .padding(20)
    }

    // MARK: Groups

    private var mcpGroup: some View {
        KitGroup(title: "MCP Servers & Tools", caption: "Their tools become available in chat and appear under Tools.") {
            ForEach(kit.mcpEntries(in: .bundled)) { entry in
                KitPartRow(
                    symbol: entry.symbol,
                    tint: .nativTint(entry.tintName),
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
                    tint: .nativTint(kit.tintName),
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
                    tint: .nativTint(kit.tintName),
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
        let catalog = MCPServerCatalog.bundled
        return Binding(
            get: { catalog.isEnabled(entry, in: model.settings.mcpServers) },
            set: { newValue in
                var servers = model.settings.mcpServers
                catalog.setEnabled(newValue, for: entry, in: &servers)
                model.settings.mcpServers = servers
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
                    .nativTextStyle(.sectionTitle)
                if let caption {
                    Text(caption)
                        .nativTextStyle(.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                NativTintedIconTile(
                    symbol: symbol,
                    tint: tint,
                    logoAssetName: logoAssetName,
                    size: 30
                )
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .nativTextStyle(.rowTitle)
                    if let subtitle {
                        Text(subtitle)
                            .nativTextStyle(.metadata)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.regular)
        .padding(.vertical, 8)
    }
}
