import AppKit
import SwiftUI

struct NativArrowlessPopoverPresenter<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    var gap: CGFloat = 8
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ anchorView: NSView, context: Context) {
        context.coordinator.update(
            anchorView: anchorView,
            isPresented: $isPresented,
            gap: gap,
            content: AnyView(content())
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss(updateBinding: false)
    }

    @MainActor
    final class Coordinator: NSObject {
        private let panel: ArrowlessPopoverPanel
        private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        private weak var anchorView: NSView?
        private var isPresented: Binding<Bool>?
        private var gap: CGFloat = 8

        override init() {
            panel = ArrowlessPopoverPanel(
                contentRect: .zero,
                styleMask: [.borderless],
                backing: .buffered,
                defer: true
            )
            super.init()

            panel.isFloatingPanel = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = true
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.contentView = hostingView
            panel.onDismiss = { [weak self] in
                guard self?.isPresented?.wrappedValue == true else { return }
                self?.isPresented?.wrappedValue = false
            }
        }

        func update(
            anchorView: NSView,
            isPresented: Binding<Bool>,
            gap: CGFloat,
            content: AnyView
        ) {
            self.anchorView = anchorView
            self.isPresented = isPresented
            self.gap = gap

            guard isPresented.wrappedValue else {
                dismiss(updateBinding: false)
                return
            }

            hostingView.rootView = AnyView(ArrowlessPopoverSurface(content: content))
            showPanel()
        }

        func dismiss(updateBinding: Bool = true) {
            if updateBinding, isPresented?.wrappedValue == true {
                isPresented?.wrappedValue = false
            }
            if let parent = panel.parent {
                parent.removeChildWindow(panel)
            }
            panel.orderOut(nil)
        }

        private func showPanel() {
            guard let anchorView, let parentWindow = anchorView.window else {
                DispatchQueue.main.async { [weak self] in
                    self?.showPanel()
                }
                return
            }

            hostingView.layoutSubtreeIfNeeded()
            let fittingSize = hostingView.fittingSize
            guard fittingSize.width > 0, fittingSize.height > 0 else { return }

            let wasVisible = panel.isVisible
            panel.setContentSize(fittingSize)
            positionPanel(relativeTo: anchorView, in: parentWindow, size: fittingSize)

            if panel.parent !== parentWindow {
                if let parent = panel.parent {
                    parent.removeChildWindow(panel)
                }
                parentWindow.addChildWindow(panel, ordered: .above)
            }
            guard !wasVisible else { return }
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }

        private func positionPanel(
            relativeTo anchorView: NSView,
            in parentWindow: NSWindow,
            size: NSSize
        ) {
            let windowRect = anchorView.convert(anchorView.bounds, to: nil)
            let screenRect = parentWindow.convertToScreen(windowRect)
            var origin = NSPoint(
                x: screenRect.midX - (size.width / 2),
                y: screenRect.maxY + gap
            )

            if let visibleFrame = parentWindow.screen?.visibleFrame {
                origin.x = min(
                    max(origin.x, visibleFrame.minX + 8),
                    visibleFrame.maxX - size.width - 8
                )
            }
            panel.setFrameOrigin(origin)
        }
    }
}

private final class ArrowlessPopoverPanel: NSPanel {
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        if isVisible {
            onDismiss?()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}

private struct ArrowlessPopoverSurface: View {
    let content: AnyView

    var body: some View {
        content
            .background(NativColor.Surface.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(NativColor.Border.primary, lineWidth: 0.75)
            }
    }
}

extension Color {
    /// Resolves a catalog/kit tint name to a color, defaulting to the accent.
    static func nativTint(_ name: String) -> Color {
        switch name.lowercased() {
        case "blue": return .blue
        case "orange": return .orange
        case "teal": return .teal
        case "purple": return .purple
        case "green": return .green
        case "red": return .red
        case "pink": return .pink
        case "yellow": return .yellow
        case "indigo": return .indigo
        case "mint": return .mint
        case "primary": return .primary
        default: return .accentColor
        }
    }
}

// Shared, flat UI primitives used across Nativ. These favor whitespace and a
// single tint over nested filled tiles, so a surface reads as one calm plane
// rather than a stack of boxes. Prefer these over re-rolling a pill/badge/dot.

/// The supported corner-radius roles for shared panel surfaces.
enum NativPanelCornerRadius {
    case compact
    case standard
    case large

    fileprivate var value: CGFloat {
        switch self {
        case .compact: 10
        case .standard: 12
        case .large: 14
        }
    }
}

private struct NativPanelSurfaceModifier: ViewModifier {
    let cornerRadius: NativPanelCornerRadius
    let isHighlighted: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius.value,
            style: .continuous
        )

        content
            .background {
                shape
                    .fill(NativColor.Surface.primary)
                    .overlay {
                        if isHighlighted {
                            NativColor.Accent.hover
                        }
                    }
                    .clipShape(shape)
            }
            .overlay {
                shape.stroke(
                    isHighlighted
                        ? NativColor.Accent.emphasis
                        : NativColor.Border.primary,
                    lineWidth: 0.5
                )
            }
    }
}

extension View {
    /// Applies Nativ's standard semantic panel surface.
    func nativPanelStyle(
        cornerRadius: NativPanelCornerRadius = .standard,
        isHighlighted: Bool = false
    ) -> some View {
        modifier(
            NativPanelSurfaceModifier(
                cornerRadius: cornerRadius,
                isHighlighted: isHighlighted
            )
        )
    }
}

/// A semantic status color, shared by dots, badges, and tool states.
enum NativStatusTone {
    case neutral
    case active
    case success
    case warning
    case danger

    var color: Color {
        switch self {
        case .neutral: return NativColor.Status.neutral
        case .active: return NativColor.Status.active
        case .success: return NativColor.Status.success
        case .warning: return NativColor.Status.warning
        case .danger: return NativColor.Status.danger
        }
    }
}

/// A small filled dot for connection/health status, optionally pulsing while live.
struct NativStatusDot: View {
    let tone: NativStatusTone
    var pulsing: Bool = false
    var diameter: CGFloat = 7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: diameter, height: diameter)
            .opacity(pulsing && animating && !reduceMotion ? 0.35 : 1)
            .animation(
                pulsing && !reduceMotion
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : nil,
                value: animating
            )
            .onAppear { animating = pulsing }
            .onChange(of: pulsing) { _, newValue in
                animating = newValue
            }
    }
}

/// A compact capsule badge with an optional leading status dot or symbol.
struct NativStatusBadge: View {
    let text: String
    var tone: NativStatusTone = .neutral
    var symbol: String? = nil
    var showsDot = false

    var body: some View {
        HStack(spacing: 4) {
            if showsDot {
                NativStatusDot(tone: tone, diameter: 6)
            }
            if let symbol {
                Image(systemName: symbol)
            }
            Text(text)
        }
        .nativTextStyle(.statusBadge)
        .foregroundStyle(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tone.color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

#Preview("Status Indicators") {
    VStack(alignment: .leading) {
        HStack {
            NativStatusDot(tone: .neutral)
            NativStatusDot(tone: .active)
            NativStatusDot(tone: .success)
            NativStatusDot(tone: .warning)
            NativStatusDot(tone: .danger)
        }

        NativStatusBadge(text: "Inactive")
        NativStatusBadge(text: "Active", tone: .active, showsDot: true)
        NativStatusBadge(text: "Connected", tone: .success, showsDot: true)
        NativStatusBadge(
            text: "Needs attention",
            tone: .warning,
            symbol: "exclamationmark.triangle.fill"
        )
        NativStatusBadge(text: "Failed", tone: .danger)
    }
    .padding()
}

/// A monospaced code/JSON block with a subtle background and selectable text.
/// JSON content is pretty-printed; anything else is shown verbatim.
struct NativCodeBlock: View {
    let raw: String
    var lineLimit: Int? = nil

    private var display: String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let string = String(data: formatted, encoding: .utf8)
        else { return raw }
        return string
    }

    var body: some View {
        Text(display)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(NativColor.Content.secondary)
            .textSelection(.enabled)
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                NativColor.Fill.quaternary,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }
}

/// A soft, tinted rounded tile holding an SF Symbol — or a bundled logo image
/// when `logoAssetName` resolves. Used for catalog logos and section glyphs.
struct NativTintedIconTile: View {
    let symbol: String
    var tint: Color = .accentColor
    var logoAssetName: String? = nil
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let logoAssetName, let nsImage = NSImage(named: logoAssetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.16)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .background(
            tint.opacity(0.12),
            in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        )
    }
}

#Preview("Panel Surfaces") {
    VStack {
        Text("Compact")
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .nativPanelStyle(cornerRadius: .compact)

        Text("Standard")
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .nativPanelStyle()

        Text("Highlighted")
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .nativPanelStyle(cornerRadius: .large, isHighlighted: true)
    }
    .padding()
    .frame(width: 320)
}

/// A borderless close (X) button that reveals a soft circular hover hue —
/// the standard dismiss affordance for Nativ's popovers and sheets.
struct NativHoverCloseButton: View {
    let action: () -> Void
    var help: String = "Close"

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NativColor.Content.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hovering ? NativColor.Fill.primary : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
