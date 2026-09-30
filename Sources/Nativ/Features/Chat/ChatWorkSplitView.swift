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
    @State private var isHoveringLine = false
    @State private var isHoveringHandle = false

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
                isHoveringLine = false
                isHoveringHandle = false
                // On a small window, restoring chat shows it at full width.
                if !expanded && !fits && isWorkVisible { onShowChatOnly() }
            }
            .onChange(of: isWorkVisible) { _, visible in
                isHoveringLine = false
                isHoveringHandle = false
                if visible && !fits { isExpanded = true }
            }
        }
        .onPreferenceChange(ChatComposerMinimumWidthKey.self) { width in
            // Keep the last measurement while the chat is collapsed.
            if width > 0 { minimumChatWidth = max(480, ceil(width)) }
        }
    }

    private func resizeHandle(available: CGFloat, height: CGFloat, chatWidth: CGFloat) -> some View {
        let isActive = isHoveringLine || isHoveringHandle || dragStartWidth != nil
        return ZStack {
            Color.clear
                .frame(width: 12)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHoveringLine = hovering
                }
                .background(ChatWorkCursorRegion(cursor: .resizeLeftRight).accessibilityHidden(true))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Chat pane width")
                .accessibilityAdjustableAction { direction in
                    resize(to: chatWidth + (direction == .increment ? 40 : -40),
                           available: available)
                }
                .accessibilityAction(named: "Swap chat and work pane") { isWorkOnLeft.toggle() }
            Button {
                isWorkOnLeft.toggle()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75)
                    }
                    .background(ChatWorkCursorRegion(cursor: .pointingHand).accessibilityHidden(true))
            }
            .buttonStyle(.plain)
            .help("Swap sides · Drag the divider to resize")
            .accessibilityLabel("Swap chat and work pane")
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .onHover { isHoveringHandle = $0 }
        }
        .frame(width: 32, height: height)
        .highPriorityGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartWidth == nil { dragStartWidth = chatWidth }
                    let translation = isWorkOnLeft ? -value.translation.width : value.translation.width
                    resize(to: (dragStartWidth ?? chatWidth) + translation,
                           available: available)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
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

/// Cursor rectangles participate in AppKit's cursor updates, unlike a one-off
/// NSCursor.set() from SwiftUI's hover callback, which a child view can override.
private struct ChatWorkCursorRegion: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorView { CursorView(cursor: cursor) }

    func updateNSView(_ view: CursorView, context: Context) {
        view.cursor = cursor
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var cursor: NSCursor

        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(visibleRect, cursor: cursor)
        }
    }
}
