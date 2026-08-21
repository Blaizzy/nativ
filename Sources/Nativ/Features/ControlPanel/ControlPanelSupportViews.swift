import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

enum FooterControl {
    case settings
    case support
    case server
    case reportIssue
}

enum ControlPanelLayout {
    static let sidebarMinimumWidth: CGFloat = 220
    static let sidebarIdealWidth: CGFloat = 260
    static let sidebarMaximumWidth: CGFloat = 480
    static let detailMinimumWidth: CGFloat = 720
    static let titlebarHeight: CGFloat = 52
    static let sidebarBrandTopClearance: CGFloat = 46
    static let sidebarBrandBottomClearance: CGFloat = 8
    static let collapsedSidebarTitleClearance: CGFloat = 108
    static let sidebarButtonLeadingPadding: CGFloat = 88
    static let modelConfigurationButtonTrailingPadding: CGFloat = 12
    static let collapseButtonSize: CGFloat = 30
    static let windowControlsLeadingPadding: CGFloat = 19
    static let windowControlsTopPadding: CGFloat = 9
    static let windowControlsWidth: CGFloat = 64
    static let windowControlsHeight: CGFloat = 28
    static let windowControlsCenterY =
        windowControlsTopPadding + (windowControlsHeight / 2)
    static let sidebarTransitionDuration: TimeInterval = 0.2
    static let sidebarTransitionSettleDuration: Duration = .milliseconds(225)
}

enum ControlPanelOnboarding {
    static let extensionsBadgeDismissedKey =
        "nativ.control-panel.extensions-new-badge-dismissed.v1"
}

extension Color {
    static let nativMainContentBackground = Color(
        nsColor: NSColor(name: NSColor.Name("NativMainContentBackground")) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(
                    srgbRed: 24 / 255,
                    green: 24 / 255,
                    blue: 24 / 255,
                    alpha: 1
                )
            }

            return .windowBackgroundColor
        }
    )
}

/// A small pulsing download arrow shown at the trailing edge of the Models sidebar row
/// while a model is downloading.
struct ModelsDownloadArrow: View {
    let count: Int
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.tint)
                .opacity(pulse ? 0.4 : 1.0)
                .animation(
                    .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse
                )
                .onAppear { pulse = true }
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.tint)
            }
        }
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        count == 1 ? "A model is downloading" : "\(count) models are downloading"
    }
}

/// Owns the control-panel's download-count projection and listens only for the
/// manager's structural add/remove signal, not its progress publications.
struct ModelsDownloadBadge: View {
    let downloads: HuggingFaceDownloadManager
    @State private var activeCount: Int

    init(downloads: HuggingFaceDownloadManager) {
        self.downloads = downloads
        _activeCount = State(initialValue: downloads.activeCount)
    }

    var body: some View {
        Group {
            if activeCount > 0 {
                ModelsDownloadArrow(count: activeCount)
            }
        }
        .onReceive(
            downloads.rowUpdates
                .compactMap { updatedModelID in
                    updatedModelID == nil ? downloads.activeCount : nil
                }
                .removeDuplicates()
        ) { activeCount = $0 }
    }
}

struct SidebarNavigationLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .frame(width: 24, alignment: .center)
            configuration.title
        }
    }
}

struct GlobalModelLoadFailureBanner: View {
    let failure: ModelLoadFailure
    let onOpenModels: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(failure.title)
                    .font(.callout.weight(.semibold))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button("Open Models", action: onOpenModels)
                .buttonStyle(.bordered)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Dismiss model loading error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }
}
