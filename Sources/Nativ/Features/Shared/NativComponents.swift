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
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.75)
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

/// A semantic status color, shared by dots, badges, and tool states.
enum NativStatusTone {
    case neutral
    case active
    case success
    case warning
    case danger

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .active: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .danger: return .red
        }
    }
}

/// A small filled dot for connection/health status, optionally pulsing while live.
struct NativStatusDot: View {
    let tone: NativStatusTone
    var pulsing: Bool = false
    var diameter: CGFloat = 7

    @State private var animating = false

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: diameter, height: diameter)
            .opacity(pulsing && animating ? 0.35 : 1)
            .animation(
                pulsing ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                value: animating
            )
            .onAppear { animating = pulsing }
    }
}

/// A compact capsule badge: a short label tinted by tone, with an optional leading symbol.
struct NativStatusBadge: View {
    let text: String
    var tone: NativStatusTone = .neutral
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(tone.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tone.color.opacity(0.12), in: Capsule())
    }
}

/// The shared selection affordance for bulk-management lists.
struct NativBulkSelectionCheckbox: View {
    let isSelected: Bool
    var isEnabled = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.55),
                            lineWidth: 1.25
                        )
                }

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 18, height: 18)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }
}

private struct NativBulkSelectionSurface: ViewModifier {
    let isSelecting: Bool
    let isSelected: Bool
    let isEnabled: Bool
    let cornerRadius: CGFloat
    let accessibilityLabel: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            if isSelecting {
                Button(action: action) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                    .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
            }
        }
    }
}

extension View {
    /// Makes an entire row or card act as the bulk-selection control while selection mode is active.
    func nativBulkSelectable(
        isSelecting: Bool,
        isSelected: Bool,
        isEnabled: Bool = true,
        cornerRadius: CGFloat = 12,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        modifier(
            NativBulkSelectionSurface(
                isSelecting: isSelecting,
                isSelected: isSelected,
                isEnabled: isEnabled,
                cornerRadius: cornerRadius,
                accessibilityLabel: accessibilityLabel,
                action: action
            )
        )
    }
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
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                Color.primary.opacity(0.04),
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
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
