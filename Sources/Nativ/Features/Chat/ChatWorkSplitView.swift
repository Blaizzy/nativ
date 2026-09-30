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
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if showsChat {
                        chat()
                            .frame(width: isWorkVisible ? width : available)
                            .frame(maxHeight: .infinity)
                    }
                    if isWorkVisible {
                        if showsChat {
                            Rectangle().fill(Color(nsColor: .separatorColor))
                                .frame(width: sizing.dividerWidth)
                        }
                        work()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if isWorkVisible {
                    resizeHandle(available: available, height: geometry.size.height,
                                 chatWidth: width, showsChat: showsChat)
                        .offset(x: showsChat ? width - 16 : 0)
                }
            }
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

    private func resizeHandle(available: CGFloat, height: CGFloat, chatWidth: CGFloat,
                              showsChat: Bool) -> some View {
        let isActive = isHoveringLine || isHoveringHandle || dragStartWidth != nil
        return ZStack {
            Color.clear
                .frame(width: 12)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHoveringLine = hovering
                    (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                }
                .accessibilityLabel("Chat pane width")
                .accessibilityAdjustableAction { direction in
                    guard showsChat else { return }
                    resize(to: chatWidth + (direction == .increment ? 40 : -40),
                           available: available)
                }
            Button {
                restoreOrCollapse(available: available, showsChat: showsChat)
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
            }
            .buttonStyle(.plain)
            .help(showsChat ? "Collapse chat · Drag to resize" : "Show chat")
            .accessibilityLabel(showsChat ? "Collapse chat" : "Show chat")
            .opacity(isActive || !showsChat ? 1 : 0)
            .onHover { isHoveringHandle = $0 }
        }
        .frame(width: 32, height: height)
        .simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in
                    guard showsChat else { return }
                    if dragStartWidth == nil { dragStartWidth = chatWidth }
                    resize(to: (dragStartWidth ?? chatWidth) + value.translation.width,
                           available: available)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                    NSCursor.arrow.set()
                }
        )
    }

    private func resize(to proposed: CGFloat, available: CGFloat) {
        if sizing.shouldCollapse(proposed: proposed, available: available) {
            if let dragStartWidth { preferredChatWidth = dragStartWidth }
            isExpanded = true
        } else {
            preferredChatWidth = sizing.chatWidth(preferred: proposed, available: available)
        }
    }

    private func restoreOrCollapse(available: CGFloat, showsChat: Bool) {
        if showsChat {
            isExpanded = true
        } else if sizing.canSplit(available) {
            isExpanded = false
        } else {
            onShowChatOnly()
        }
    }
}
