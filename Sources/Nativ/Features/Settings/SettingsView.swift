import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    static let storageKey = "appAppearance"

    case system
    case light
    case dark

    var id: Self { self }

    var displayName: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system:
            "circle.lefthalf.filled"
        case .light:
            "sun.max.fill"
        case .dark:
            "moon.fill"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

struct SettingsView: View {
    let softwareUpdater: SoftwareUpdater
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader
                generalSettings
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pageHeader: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                .accessibilityLabel("Nativ app icon")

            VStack(spacing: 5) {
                Text("Nativ")
                    .font(.largeTitle.weight(.semibold))
                Text(appVersionLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Local AI, native to your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("General")
                .font(.headline)

            VStack(spacing: 0) {
                settingsRow(
                    title: "Software Updates",
                    description: "Check for a newer version of Nativ.",
                    systemImage: "arrow.triangle.2.circlepath"
                ) {
                    CheckForUpdatesCommand(updater: softwareUpdater.updater)
                        .buttonStyle(.bordered)
                }

                Divider()
                    .padding(.leading, 52)

                settingsRow(
                    title: "Appearance",
                    description: appearanceDescription,
                    systemImage: appearance.systemImage
                ) {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.displayName)
                                .tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                Divider()
                    .padding(.leading, 52)

                settingsRow(
                    title: "Start at Login",
                    description: launchAtLogin.requiresApproval
                        ? "Approval is required in System Settings."
                        : "Open Nativ automatically when you log in.",
                    systemImage: "person.crop.circle.badge.checkmark"
                ) {
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    ))
                    .labelsHidden()
                }

                if launchAtLogin.requiresApproval {
                    Divider()
                        .padding(.leading, 52)

                    HStack {
                        Spacer()
                        Button("Open Login Items Settings…") {
                            launchAtLogin.openSystemSettings()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
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

    private func settingsRow<Accessory: View>(
        title: String,
        description: String,
        systemImage: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 20)
            accessory()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    private var appearanceDescription: String {
        switch appearance {
        case .system:
            "Match your Mac’s appearance."
        case .light:
            "Use Nativ’s light appearance."
        case .dark:
            "Use Nativ’s dark appearance."
        }
    }

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String
        if let build, !build.isEmpty {
            return "Version \(version) (\(build))"
        }
        return "Version \(version)"
    }
}
