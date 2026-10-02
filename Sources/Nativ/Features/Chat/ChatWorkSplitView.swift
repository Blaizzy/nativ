import AppKit
import SwiftUI

/// The composer reports its controls' ideal width, including the transcript inset.
struct ChatComposerMinimumWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ChatWorkSplitSizing {
    var minimumChatWidth: CGFloat = 480
    let minimumWorkWidth: CGFloat = 320
    let dividerWidth: CGFloat = 1
    let collapseDistance: CGFloat = 24

    func canSplit(_ width: CGFloat) -> Bool {
        width >= minimumChatWidth + minimumWorkWidth + dividerWidth
    }

    func chatWidth(preferred: CGFloat?, available: CGFloat) -> CGFloat {
        min(max(preferred ?? available / 2, minimumChatWidth),
            max(0, available - minimumWorkWidth - dividerWidth))
    }

    func shouldCollapse(proposed: CGFloat, available: CGFloat) -> Bool {
        !canSplit(available) || proposed < minimumChatWidth - collapseDistance
    }
}

struct ChatWorkSplitView<Chat: View, Work: View>: View {
    let isWorkVisible: Bool
    @Binding var isExpanded: Bool
    @Binding var isWorkOnLeft: Bool
    let onShowChatOnly: () -> Void
    @ViewBuilder let chat: () -> Chat
    @ViewBuilder let work: () -> Work

    @State private var minimumChatWidth: CGFloat = 480
    @State private var preferredChatWidth: CGFloat?
    @State private var dragStartWidth: CGFloat?

    private var sizing: ChatWorkSplitSizing {
        ChatWorkSplitSizing(minimumChatWidth: minimumChatWidth)
    }

    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.width
            let fits = sizing.canSplit(available)
            let showsChat = !isWorkVisible || (!isExpanded && fits)
            let width = sizing.chatWidth(preferred: preferredChatWidth, available: available)
            let workWidth = showsChat ? max(0, available - width - sizing.dividerWidth) : available
            let dividerX = isWorkOnLeft ? workWidth : width
            ZStack(alignment: .leading) {
                // Move the existing views so swapping preserves drafts, scroll
                // positions, and the document/browser view's local state.
                if showsChat {
                    chat()
                        .frame(width: isWorkVisible ? width : available)
                        .frame(maxHeight: .infinity)
                        .offset(x: isWorkVisible && isWorkOnLeft ? workWidth + sizing.dividerWidth : 0)
                }
                if isWorkVisible {
                    if showsChat {
                        Rectangle().fill(Color(nsColor: .separatorColor))
                            .frame(width: sizing.dividerWidth)
                            .offset(x: dividerX)
                    }
                    work()
                        .frame(width: workWidth)
                        .frame(maxHeight: .infinity)
                        .offset(x: showsChat && !isWorkOnLeft ? width + sizing.dividerWidth : 0)
                }
                if isWorkVisible && showsChat {
                    resizeHandle(available: available, height: geometry.size.height,
                                 chatWidth: width)
                        .offset(x: dividerX - 16)
                }
            }
            .frame(width: available, height: geometry.size.height, alignment: .leading)
            .onChange(of: fits, initial: true) { _, fits in
                if isWorkVisible && !fits { isExpanded = true }
            }
            .onChange(of: isExpanded) { _, expanded in
                // On a small window, restoring chat shows it at full width.
                if !expanded && !fits && isWorkVisible { onShowChatOnly() }
            }
            .onChange(of: isWorkVisible) { _, visible in
                if visible && !fits { isExpanded = true }
            }
        }
        .onPreferenceChange(ChatComposerMinimumWidthKey.self) { width in
            // Keep the last measurement while the chat is collapsed.
            if width > 0 { minimumChatWidth = max(480, ceil(width)) }
        }
    }

    private func resizeHandle(available: CGFloat, height: CGFloat, chatWidth: CGFloat) -> some View {
        ChatWorkDivider(
            onSwap: { isWorkOnLeft.toggle() },
            onDrag: { translation in
                if dragStartWidth == nil { dragStartWidth = chatWidth }
                let delta = isWorkOnLeft ? -translation : translation
                resize(to: (dragStartWidth ?? chatWidth) + delta, available: available)
            },
            onDragEnded: { dragStartWidth = nil },
            onAdjust: { delta in resize(to: chatWidth + delta, available: available) }
        )
        .frame(width: 32, height: height)
    }

    private func resize(to proposed: CGFloat, available: CGFloat) {
        if sizing.shouldCollapse(proposed: proposed, available: available) {
            if let dragStartWidth { preferredChatWidth = dragStartWidth }
            dragStartWidth = nil
            isExpanded = true
        } else {
            preferredChatWidth = sizing.chatWidth(preferred: proposed, available: available)
        }
    }
}

/// The frontmost native view owns both hit testing and cursor updates. A cursor
/// view behind a SwiftUI gesture surface does not receive the cursor event.
private struct ChatWorkDivider: NSViewRepresentable {
    let onSwap: () -> Void
    let onDrag: (CGFloat) -> Void
    let onDragEnded: () -> Void
    let onAdjust: (CGFloat) -> Void

    func makeNSView(context: Context) -> ChatWorkDividerNSView { ChatWorkDividerNSView() }

    func updateNSView(_ view: ChatWorkDividerNSView, context: Context) {
        view.onSwap = onSwap
        view.onDrag = onDrag
        view.onDragEnded = onDragEnded
        view.onAdjust = onAdjust
    }
}

final class ChatWorkDividerNSView: NSView {
    var onSwap: () -> Void = {}
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    var onAdjust: (CGFloat) -> Void = { _ in }

    private let icon = NSImageView()
    private var hoverArea: NSTrackingArea?
    private var isHovered = false
    private var mouseDownPoint: NSPoint?
    private var pressedHandle = false
    private var isDragging = false

    private var handleRect: NSRect {
        NSRect(x: bounds.midX - 16, y: bounds.midY - 16, width: 32, height: 32)
    }

    private var lineRect: NSRect {
        NSRect(x: bounds.midX - 6, y: bounds.minY, width: 12, height: bounds.height)
    }

    init() {
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleNone
        icon.isHidden = true
        icon.setAccessibilityElement(false)
        addSubview(icon)
        toolTip = "Swap sides · Drag the divider to resize"
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Chat pane width")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Swap chat and work pane", target: self,
                                        selector: #selector(swapPanes))
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        icon.frame = handleRect
        if let window {
            updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor else { return nil }
        let local = convert(point, from: superview)
        return cursor(at: local) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate,
                                           .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
        if let cursor = isDragging ? NSCursor.resizeLeftRight : cursor(at: point) {
            cursor.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseEntered(with event: NSEvent) { cursorUpdate(with: event) }
    override func mouseMoved(with event: NSEvent) { cursorUpdate(with: event) }
    override func mouseExited(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
        // AppKit gives the next view its cursor-update event. Do not reset its cursor.
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        pressedHandle = handleRect.contains(convert(event.locationInWindow, from: nil))
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let translation = event.locationInWindow.x - start.x
        guard isDragging || abs(translation) >= 4 else { return }
        isDragging = true
        updateHover(at: convert(event.locationInWindow, from: nil))
        NSCursor.resizeLeftRight.set()
        onDrag(translation)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }
        let wasDragging = isDragging
        let shouldSwap = !wasDragging && pressedHandle
            && handleRect.contains(convert(event.locationInWindow, from: nil))
        mouseDownPoint = nil
        pressedHandle = false
        isDragging = false
        updateHover(at: convert(event.locationInWindow, from: nil))
        if wasDragging { onDragEnded() }
        if shouldSwap { onSwap() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHovered || isDragging else { return }
        let outline = NSBezierPath(roundedRect: handleRect.insetBy(dx: 0.375, dy: 0.375),
                                   xRadius: 12, yRadius: 12)
        NSColor.textBackgroundColor.setFill()
        outline.fill()
        NSColor.separatorColor.setStroke()
        outline.lineWidth = 0.75
        outline.stroke()
    }

    override func accessibilityPerformIncrement() -> Bool { onAdjust(40); return true }
    override func accessibilityPerformDecrement() -> Bool { onAdjust(-40); return true }
    @objc private func swapPanes() -> Bool { onSwap(); return true }

    private func cursor(at point: NSPoint) -> NSCursor? {
        guard bounds.contains(point) else { return nil }
        if handleRect.contains(point) { return .pointingHand }
        return lineRect.contains(point) ? .resizeLeftRight : nil
    }

    private func updateHover(at point: NSPoint) {
        isHovered = window?.isKeyWindow == true && cursor(at: point) != nil
        icon.isHidden = !(isHovered || isDragging)
        needsDisplay = true
    }
}
