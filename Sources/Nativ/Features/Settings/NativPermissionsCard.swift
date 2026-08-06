import SwiftUI

struct NativPermissionsCard: View {
    @ObservedObject var store: NativPermissionStore

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(NativPermission.allCases.enumerated()), id: \.element.id) { index, permission in
                if index > 0 {
                    Divider()
                        .padding(.leading, 52)
                }

                NativPermissionRow(
                    permission: permission,
                    status: store.status(for: permission),
                    actionTitle: store.actionTitle(for: permission),
                    isPending: store.pendingPermission == permission
                ) {
                    store.resolve(permission)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

struct NativPermissionRow: View {
    let permission: NativPermission
    let status: NativPermissionStatus
    let actionTitle: String
    let isPending: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(iconTint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 20)

            if status == .granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                    .fixedSize()
                    .accessibilityLabel("\(permission.title) granted")
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .disabled(isPending)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    private var detail: String {
        switch status {
        case .granted, .notRequested:
            permission.summary
        case .needsAttention:
            "\(permission.summary) Turn it on for Nativ in System Settings."
        }
    }

    private var iconTint: Color {
        switch status {
        case .granted:
            .green
        case .notRequested:
            .secondary
        case .needsAttention:
            .orange
        }
    }
}

struct NativPermissionsSummary: View {
    @ObservedObject var store: NativPermissionStore

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(store.allGranted ? Color.green : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var title: String {
        let outstanding = store.outstandingPermissions.count
        switch outstanding {
        case 0:
            return "All set. Nativ has everything it needs."
        case 1:
            return "1 permission still needed."
        default:
            return "\(outstanding) permissions still needed."
        }
    }

    private var systemImage: String {
        store.allGranted ? "checkmark.seal.fill" : "info.circle"
    }
}
