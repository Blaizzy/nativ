import NativServerKit
import SwiftUI

struct KitsSectionView: View {
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    @ObservedObject var store: NativKitStore
    let onOpenCapability: (NativKitCapabilityReference) -> Void

    @State private var editingKit: NativKit?
    @State private var deletingKit: NativKit?
    @State private var capabilityPendingNavigation: NativKitCapabilityReference?

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 14)]

    var body: some View {
        HubSectionScaffold(
            title: "Kits",
            subtitle: "Bundle MCPs, tools, and skills for chat or routines."
        ) {
            Button(action: createKit) {
                Label("Create Kit", systemImage: "plus")
            }
        } content: {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(store.allKits) { kit in
                    KitCard(
                        kit: kit,
                        evaluation: inventory.evaluation(of: kit),
                        onSetEnabled: { store.setEnabled($0, id: kit.id) },
                        onManage: { editingKit = kit },
                        onOpenCapability: onOpenCapability,
                        onDelete: kit.isBuiltIn ? nil : { deletingKit = kit }
                    )
                }
            }
        }
        .sheet(item: $editingKit, onDismiss: openPendingCapability) { kit in
            NativKitEditor(
                kit: kit,
                host: host,
                model: model,
                onSave: {
                    store.save($0)
                    editingKit = nil
                },
                onCancel: { editingKit = nil },
                onOpenCapability: { capability in
                    capabilityPendingNavigation = capability
                    editingKit = nil
                },
                onReset: kit.isBuiltIn ? {
                    store.resetBuiltIn(id: kit.id)
                    editingKit = nil
                } : nil
            )
        }
        .alert(
            "Delete Kit?",
            isPresented: Binding(
                get: { deletingKit != nil },
                set: { if !$0 { deletingKit = nil } }
            ),
            presenting: deletingKit
        ) { kit in
            Button("Delete", role: .destructive) {
                if let id = UUID(uuidString: kit.id) {
                    store.deleteUserKit(id: id)
                }
                deletingKit = nil
            }
            Button("Cancel", role: .cancel) { deletingKit = nil }
        } message: { _ in
            Text("The Kit will be removed. Its MCPs, tools, and skills will not be changed.")
        }
    }

    private var inventory: NativKitCapabilityInventory {
        NativKitCapabilityInventory(settings: model.settings, host: host)
    }

    private func createKit() {
        editingKit = UserNativKit(
            name: "New Kit",
            summary: "",
            contents: NativKitContents()
        ).resolved()
    }

    private func openPendingCapability() {
        guard let capability = capabilityPendingNavigation else { return }
        capabilityPendingNavigation = nil
        onOpenCapability(capability)
    }
}

private struct KitCard: View {
    let kit: NativKit
    let evaluation: NativKitEvaluation
    let onSetEnabled: (Bool) -> Void
    let onManage: () -> Void
    let onOpenCapability: (NativKitCapabilityReference) -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                NativTintedIconTile(symbol: kit.symbol, tint: kit.tint, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(kit.name)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        if kit.isBuiltIn {
                            Text("Built-in")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(kit.summary.isEmpty ? "A custom capability bundle." : kit.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                Toggle("", isOn: Binding(
                    get: { kit.isEnabled },
                    set: onSetEnabled
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(kit.isEnabled ? "Turn off this Kit" : "Turn on this Kit")
            }

            HStack(spacing: 7) {
                readinessControl
                if !kit.inventory.isEmpty {
                    Text(kit.inventory)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            if kit.isEnabled, let summary = evaluation.summary {
                Text(summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Button("Manage", action: onManage)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Delete Kit")
                }
            }
            .font(.system(size: 11, weight: .medium))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var readinessControl: some View {
        if !kit.isEnabled {
            NativStatusBadge(text: "Off")
        } else {
            switch evaluation.availability {
            case .ready:
                EmptyView()
            case .needsSetup:
                if let issue = evaluation.issues.first,
                   let capability = issue.capability,
                   let title = setupTitle(for: issue) {
                    Button {
                        onOpenCapability(capability)
                    } label: {
                        Label(title, systemImage: "arrow.up.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(issue.message)
                } else if let issue = evaluation.issues.first,
                          case .connecting = issue.reason {
                    NativStatusBadge(text: "Connecting", tone: .warning)
                } else {
                    NativStatusBadge(text: "Needs setup", tone: .warning)
                }
            case .unavailable:
                NativStatusBadge(text: "Unavailable", tone: .warning)
            }
        }
    }

    private func setupTitle(for issue: NativKitIssue) -> String? {
        switch issue.reason {
        case .globallyOff:
            "Turn on \(issue.componentName)"
        case .needsConfiguration, .connectionFailed:
            "Set up \(issue.componentName)"
        default:
            nil
        }
    }
}
