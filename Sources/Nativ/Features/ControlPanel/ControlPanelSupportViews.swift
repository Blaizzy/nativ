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
    static let sidebarMaximumWidth: CGFloat = 440
    static let sidebarTransitionDuration: TimeInterval = 0.3
    static let detailMinimumWidth: CGFloat = 720
    static let sidebarBrandHeight: CGFloat = 40
    static let sidebarBrandIconSize: CGFloat = 24
    static let sidebarBrandBottomClearance: CGFloat = 8
    static let fullScreenSidebarTopClearance: CGFloat = 32
    static let detailHeaderTopInset = (sidebarBrandHeight - sidebarBrandIconSize) / 2
    static let topControlSize: CGFloat = 30
    static let topControlsLeadingPadding: CGFloat = 80
    static let topControlsLeadingPaddingFullScreen: CGFloat = 12
    static let topControlsTrailingPadding: CGFloat = 12
    static let topControlsTopPadding: CGFloat = 1
}

enum ControlPanelOnboarding {
    static let extensionsBadgeDismissedKey =
        "nativ.control-panel.extensions-new-badge-dismissed.v1"
}

private struct ControlPanelFullScreenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var controlPanelIsFullScreen: Bool {
        get { self[ControlPanelFullScreenKey.self] }
        set { self[ControlPanelFullScreenKey.self] = newValue }
    }
}

struct ControlPanelWindowStateReader: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isFullScreen: $isFullScreen)
    }

    func makeNSView(context: Context) -> ControlPanelWindowStateReaderView {
        let view = ControlPanelWindowStateReaderView()
        view.onFullScreenChange = context.coordinator.update(isFullScreen:)
        return view
    }

    func updateNSView(_ view: ControlPanelWindowStateReaderView, context: Context) {
        context.coordinator.isFullScreen = $isFullScreen
        view.onFullScreenChange = context.coordinator.update(isFullScreen:)
        view.reportWindowState()
    }

    @MainActor
    final class Coordinator {
        var isFullScreen: Binding<Bool>

        init(isFullScreen: Binding<Bool>) {
            self.isFullScreen = isFullScreen
        }

        func update(isFullScreen newValue: Bool) {
            guard isFullScreen.wrappedValue != newValue else { return }
            isFullScreen.wrappedValue = newValue
        }
    }
}

@MainActor
final class ControlPanelWindowStateReaderView: NSView {
    var onFullScreenChange: ((Bool) -> Void)?
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowObservation()
        reportWindowState()
    }

    func reportWindowState() {
        onFullScreenChange?(window?.styleMask.contains(.fullScreen) == true)
    }

    private func updateWindowObservation() {
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willEnterFullScreenNotification,
                object: observedWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didEnterFullScreenNotification,
                object: observedWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didExitFullScreenNotification,
                object: observedWindow
            )
        }

        observedWindow = window
        guard let window else { return }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillEnterFullScreen(_:)),
            name: NSWindow.willEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowStateDidChange(_:)),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowStateDidChange(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
    }

    @objc
    private func windowWillEnterFullScreen(_ notification: Notification) {
        onFullScreenChange?(true)
    }

    @objc
    private func windowStateDidChange(_ notification: Notification) {
        reportWindowState()
    }
}

struct ControlPanelSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
    }
}

extension Color {
    static func nativMaterialOverlay(for colorScheme: ColorScheme) -> Color {
        (colorScheme == .dark ? Color.black : Color.white).opacity(0.1)
    }

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
