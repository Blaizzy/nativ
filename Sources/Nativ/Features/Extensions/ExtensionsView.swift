import NativExtensionSDK
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let nativExtensionPackage = UTType(
        exportedAs: "com.nativ.extension-package",
        conformingTo: .package
    )
}

@MainActor
struct ExtensionsView: View {
    @ObservedObject var manager: NativExtensionManager
    let titleLeadingInset: CGFloat

    @State private var isImporterPresented = false
    @State private var extensionPendingRemoval: NativExtensionRecord?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    includedSection
                    if !installedExtensions.isEmpty {
                        installedSection
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 1_100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Color.nativMainContentBackground)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.nativExtensionPackage],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let URLs):
                if let packageURL = URLs.first {
                    manager.installPackage(at: packageURL)
                }
            case .failure(let error):
                manager.lastErrorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(
                get: { extensionPendingRemoval != nil },
                set: { isPresented in
                    if !isPresented {
                        extensionPendingRemoval = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(
                extensionPendingRemoval?.isIncluded == true ? "Remove" : "Uninstall",
                role: .destructive
            ) {
                if let extensionPendingRemoval {
                    manager.remove(extensionID: extensionPendingRemoval.id)
                }
                extensionPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                extensionPendingRemoval = nil
            }
        } message: {
            if extensionPendingRemoval?.isIncluded == true {
                Text("Its shortcuts, background activity, and pages will be disabled. You can restore it later.")
            } else {
                Text("The extension package and its runtime will be removed from this Mac.")
            }
        }
        .alert(
            "Extension Error",
            isPresented: Binding(
                get: { manager.lastErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        manager.lastErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                manager.lastErrorMessage = nil
            }
        } message: {
            Text(manager.lastErrorMessage ?? "An unknown extension error occurred.")
        }
        .onAppear {
            manager.refresh()
            manager.refreshPermissionStatuses()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Extensions")
                    .font(.title2.weight(.semibold))
                Text("Add capabilities to Nativ without coupling them to the core app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 28)
        .padding(.leading, titleLeadingInset)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    private var includedSection: some View {
        extensionSection(
            title: "Included with Nativ",
            subtitle: "First-party extensions are available by default and can be removed or restored.",
            records: includedExtensions
        )
    }

    private var installedSection: some View {
        extensionSection(
            title: "Installed",
            subtitle: "Extensions installed from local .nativextension packages.",
            records: installedExtensions
        )
    }

    private func extensionSection(
        title: String,
        subtitle: String,
        records: [NativExtensionRecord]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(records) { record in
                extensionCard(record)
            }
        }
    }

    private func extensionCard(_ record: NativExtensionRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: record.manifest.systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(record.manifest.displayName)
                            .font(.headline)
                        if record.isIncluded {
                            Text("INCLUDED")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Color.blue.opacity(0.12),
                                    in: Capsule()
                                )
                        }
                        if record.isRemoved {
                            Text("REMOVED")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Color.secondary.opacity(0.12),
                                    in: Capsule()
                                )
                        }
                    }
                    Text(record.manifest.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Version \(record.manifest.version) · \(record.manifest.developer)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 12)

                extensionActions(record)
            }

            if !record.isRemoved {
                Divider()
                permissions(for: record)

                if let errorMessage = record.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(record.isRemoved ? 0.018 : 0.035),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .opacity(record.isRemoved ? 0.75 : 1)
    }

    @ViewBuilder
    private func extensionActions(_ record: NativExtensionRecord) -> some View {
        if record.isRemoved {
            Button("Restore") {
                manager.restore(extensionID: record.id)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { record.isEnabled },
                    set: { manager.setEnabled($0, extensionID: record.id) }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(!record.hasRuntime)
            .help(record.isEnabled ? "Disable extension" : "Enable extension")

            Button(record.isIncluded ? "Remove" : "Uninstall", role: .destructive) {
                extensionPendingRemoval = record
            }
            .buttonStyle(.bordered)
        }
    }

    private func permissions(for record: NativExtensionRecord) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Permissions")
                .font(.subheadline.weight(.semibold))

            FlowLayout(spacing: 8) {
                ForEach(record.manifest.permissions, id: \.self) { permission in
                    permissionBadge(permission)
                }
            }
        }
    }

    @ViewBuilder
    private func permissionBadge(
        _ permission: NativExtensionPermission
    ) -> some View {
        let status = manager.permissionStatus(permission)
        let actionTitle = manager.permissionActionTitle(permission)
        if let actionTitle {
            Button {
                manager.requestPermission(permission)
            } label: {
                permissionBadgeLabel(
                    permission: permission,
                    status: status,
                    actionTitle: actionTitle
                )
            }
            .buttonStyle(.plain)
            .help("\(actionTitle) \(permission.displayName) permission")
        } else {
            permissionBadgeLabel(
                permission: permission,
                status: status,
                actionTitle: nil
            )
        }
    }

    private func permissionBadgeLabel(
        permission: NativExtensionPermission,
        status: NativExtensionPermissionStatus,
        actionTitle: String?
    ) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Text(permission.displayName)
            Text("· \(status.title)")
                .foregroundStyle(.secondary)
            if let actionTitle {
                Text(actionTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Color.primary.opacity(0.045),
            in: Capsule()
        )
        .contentShape(Capsule())
    }

    private var includedExtensions: [NativExtensionRecord] {
        manager.records.filter(\.isIncluded)
    }

    private var installedExtensions: [NativExtensionRecord] {
        manager.records.filter { !$0.isIncluded }
    }

    private var removalTitle: String {
        guard let extensionPendingRemoval else {
            return "Remove Extension?"
        }
        return extensionPendingRemoval.isIncluded
            ? "Remove \(extensionPendingRemoval.manifest.displayName)?"
            : "Uninstall \(extensionPendingRemoval.manifest.displayName)?"
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(
            proposal: proposal,
            subviews: subviews
        ).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )
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
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return (
            CGSize(
                width: proposal.width ?? max(0, x - spacing),
                height: y + lineHeight
            ),
            points
        )
    }
}
