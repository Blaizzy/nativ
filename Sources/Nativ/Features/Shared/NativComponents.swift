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

/// The application-wide typography roles used by Nativ interface chrome.
enum NativTypography {
    enum Style {
        case displayTitle
        case pageTitle
        case brandTitle
        case sheetTitle
        case detailTitle
        case cardTitle
        case compactCardTitle
        case emptyStateTitle
        case sidebarSectionTitle
        case sidebarItem
        case subsectionTitle
        case sectionTitle
        case rowTitleEmphasized
        case rowTitle
        case body
        case supporting
        case supportingEmphasized
        case metadata
        case metadataNumeric
        case badge
        case badgeMuted
        case badgeStrong
        case actionLabel
        case statusBadge
        case chartLabel
        case technicalDisplayTitle
        case technicalTitle
        case technicalLabel
        case code
        case codeEmphasized

        fileprivate var font: Font {
            switch self {
            case .displayTitle:
                .system(size: 32, weight: .semibold)
            case .pageTitle:
                .system(size: 20, weight: .semibold)
            case .brandTitle:
                .system(size: 18, weight: .semibold)
            case .sheetTitle:
                .system(size: 18, weight: .semibold)
            case .detailTitle:
                .system(size: 17, weight: .semibold)
            case .cardTitle:
                .system(size: 15, weight: .semibold)
            case .compactCardTitle:
                .system(size: 14, weight: .semibold)
            case .emptyStateTitle:
                .system(size: 15, weight: .medium)
            case .sidebarSectionTitle:
                .system(size: 15, weight: .semibold)
            case .sidebarItem:
                .system(size: 15)
            case .subsectionTitle:
                .system(size: 14, weight: .semibold)
            case .sectionTitle:
                .system(size: 13, weight: .semibold)
            case .rowTitleEmphasized:
                .system(size: 13, weight: .semibold)
            case .rowTitle:
                .system(size: 13, weight: .medium)
            case .body:
                .system(size: 13)
            case .supporting:
                .system(size: 12)
            case .supportingEmphasized:
                .system(size: 12, weight: .medium)
            case .metadata:
                .system(size: 11)
            case .metadataNumeric:
                .system(size: 11).monospacedDigit()
            case .badge:
                .system(size: 10, weight: .semibold)
            case .badgeMuted:
                .system(size: 10, weight: .medium)
            case .badgeStrong:
                .system(size: 10, weight: .bold)
            case .actionLabel:
                .system(size: 11, weight: .medium)
            case .statusBadge:
                .system(size: 11, weight: .semibold)
            case .chartLabel:
                .system(size: 9)
            case .technicalDisplayTitle:
                .system(size: 16, weight: .semibold, design: .monospaced)
            case .technicalTitle:
                .system(size: 15, weight: .semibold, design: .monospaced)
            case .technicalLabel:
                .system(size: 12, weight: .medium, design: .monospaced)
            case .code:
                .system(size: 12, design: .monospaced)
            case .codeEmphasized:
                .system(size: 12, weight: .semibold, design: .monospaced)
            }
        }
    }
}

private struct NativTypographyModifier: ViewModifier {
    let style: NativTypography.Style

    func body(content: Content) -> some View {
        content.font(style.font)
    }
}

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
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        if isHighlighted {
                            Color.primary.opacity(0.045)
                        }
                    }
                    .clipShape(shape)
            }
            .overlay {
                shape.stroke(
                    isHighlighted
                        ? Color.primary.opacity(0.16)
                        : Color(nsColor: .separatorColor),
                    lineWidth: 0.5
                )
            }
    }
}

extension View {
    /// Applies one of Nativ's application-wide typography roles.
    func nativTextStyle(_ style: NativTypography.Style) -> some View {
        modifier(NativTypographyModifier(style: style))
    }

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

private struct NativTypographyPreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                previewSection("Titles") {
                    previewRow("Display title", sample: "Welcome to Nativ", style: .displayTitle)
                    previewRow("Page title", sample: "Extensions", style: .pageTitle)
                    previewRow("Brand title", sample: "Nativ", style: .brandTitle)
                    previewRow("Sheet title", sample: "Edit Tool", style: .sheetTitle)
                    previewRow("Detail title", sample: "Featured Kit", style: .detailTitle)
                    previewRow("Card title", sample: "Scheduled Task", style: .cardTitle)
                    previewRow("Compact card title", sample: "Artifact.jpg", style: .compactCardTitle)
                    previewRow("Empty-state title", sample: "Drop files here", style: .emptyStateTitle)
                }

                previewSection("Navigation and content") {
                    previewRow("Sidebar section", sample: "Chats", style: .sidebarSectionTitle)
                    previewRow("Sidebar item", sample: "Recent conversation", style: .sidebarItem)
                    previewRow("Subsection title", sample: "Custom Servers", style: .subsectionTitle)
                    previewRow("Section title", sample: "Capabilities", style: .sectionTitle)
                    previewRow("Emphasized row", sample: "Image Generation", style: .rowTitleEmphasized)
                    previewRow("Row title", sample: "Web Search", style: .rowTitle)
                    previewRow("Body", sample: "Primary interface content", style: .body)
                    previewRow("Supporting", sample: "Additional context and guidance", style: .supporting)
                    previewRow("Supporting emphasized", sample: "Field or control label", style: .supportingEmphasized)
                }

                previewSection("Metadata and labels") {
                    previewRow("Metadata", sample: "Updated today", style: .metadata)
                    previewRow("Numeric metadata", sample: "12 of 48", style: .metadataNumeric)
                    previewRow("Badge", sample: "BUILT-IN", style: .badge)
                    previewRow("Muted badge", sample: "Optional", style: .badgeMuted)
                    previewRow("Strong badge", sample: "PDF", style: .badgeStrong)
                    previewRow("Action label", sample: "Enable", style: .actionLabel)
                    previewRow("Status badge", sample: "Connected", style: .statusBadge)
                    previewRow("Chart label", sample: "12 AM", style: .chartLabel)
                }

                previewSection("Technical") {
                    previewRow("Technical display", sample: "web_search", style: .technicalDisplayTitle)
                    previewRow("Technical title", sample: "read_file", style: .technicalTitle)
                    previewRow("Technical label", sample: "POST", style: .technicalLabel)
                    previewRow("Code", sample: #"{"query":"Nativ"}"#, style: .code)
                    previewRow("Code emphasized", sample: "GET /v1/models", style: .codeEmphasized)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func previewSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .nativTextStyle(.sectionTitle)
            content()
        }
    }

    private func previewRow(
        _ name: String,
        sample: String,
        style: NativTypography.Style
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(name)
                .nativTextStyle(.metadata)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(sample)
                .nativTextStyle(style)
            Spacer(minLength: 0)
        }
    }
}

#Preview("Typography") {
    NativTypographyPreview()
        .frame(width: 520, height: 760)
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

/// Feature-local bulk selection state with shared mode and set operations.
struct NativBulkSelection<ID: Hashable> {
    private(set) var isActive = false
    private(set) var ids = Set<ID>()

    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: ID) -> Bool {
        ids.contains(id)
    }

    func includesAll(_ candidateIDs: Set<ID>) -> Bool {
        !candidateIDs.isEmpty && ids.isSuperset(of: candidateIDs)
    }

    mutating func toggleMode() {
        isActive.toggle()
        if !isActive {
            ids.removeAll()
        }
    }

    mutating func toggle(_ id: ID) {
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
    }

    mutating func toggleAll(_ candidateIDs: Set<ID>) {
        guard !candidateIDs.isEmpty else { return }
        if includesAll(candidateIDs) {
            ids.subtract(candidateIDs)
        } else {
            ids.formUnion(candidateIDs)
        }
    }

    mutating func remove(_ removedIDs: Set<ID>) {
        ids.subtract(removedIDs)
    }

    mutating func finish() {
        isActive = false
        ids.removeAll()
    }
}

/// Shared controls for selecting every visible item and performing bulk removal.
struct NativBulkSelectionToolbar: View {
    let selectedCount: Int
    let allSelected: Bool
    var deleteTitle = "Delete"
    var isSelectAllEnabled = true
    let onToggleAll: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(selectedCount) selected")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Button(allSelected ? "Deselect All" : "Select All", action: onToggleAll)
                .disabled(!isSelectAllEnabled)

            Spacer(minLength: 0)

            Button(role: .destructive, action: onDelete) {
                Label(deleteTitle, systemImage: "trash")
            }
            .disabled(selectedCount == 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
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
