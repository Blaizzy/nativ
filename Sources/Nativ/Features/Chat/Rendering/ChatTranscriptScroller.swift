import SwiftUI

struct ChatTranscriptScroller<Content: View, TopInset: View>: View {
    let currentSessionID: UUID?
    let revision: ChatTranscriptRevision
    let submissionID: UUID?
    @Binding var scrollTargetMessageID: UUID?
    let itemIDs: [UUID]
    let searchNavigation: ChatSearchNavigationRequest?
    let onSearchNavigation: (UUID) -> Void
    let topInset: TopInset
    let content: (Range<Int>) -> Content
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var followState = ChatTranscriptFollowState()
    @State private var paging = ChatTranscriptPagingState()
    @State private var readingPosition = ScrollPosition(edge: .bottom)
    @State private var pendingPrepend: ChatTranscriptGeometry?
    @State private var initialPositionEstablished = false
    @State private var topTriggerArmed = true

    init(
        currentSessionID: UUID?,
        revision: ChatTranscriptRevision,
        submissionID: UUID?,
        scrollTargetMessageID: Binding<UUID?>,
        itemIDs: [UUID],
        searchNavigation: ChatSearchNavigationRequest? = nil,
        onSearchNavigation: @escaping (UUID) -> Void = { _ in },
        @ViewBuilder topInset: () -> TopInset,
        @ViewBuilder content: @escaping (Range<Int>) -> Content
    ) {
        self.currentSessionID = currentSessionID
        self.revision = revision
        self.submissionID = submissionID
        _scrollTargetMessageID = scrollTargetMessageID
        self.itemIDs = itemIDs
        self.searchNavigation = searchNavigation
        self.onSearchNavigation = onSearchNavigation
        self.topInset = topInset()
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content(paging.attachedRange(in: itemIDs))
                    // Leave room to center findings at either end of the conversation.
                    .padding(.vertical, searchNavigation == nil ? 0 : viewportHeight / 2)
            }
                .scrollPosition($readingPosition)
                // Content-size changes are handled by the single pinner below.
                // Applying the default anchor to them as well competes with that scroll.
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .alignment)
                .safeAreaInset(edge: .top, spacing: 0) { topInset }
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    viewportHeight = $0
                }
                .onScrollGeometryChange(for: ChatTranscriptGeometry.self) { geometry in
                    ChatTranscriptGeometry(
                        contentHeight: geometry.contentSize.height,
                        // Only retain exact offsets at the paging boundary; ordinary
                        // scrolling should not invalidate the transcript every pixel.
                        offset: geometry.contentOffset.y <= 32 ? geometry.contentOffset.y : 0,
                        topInset: geometry.contentInsets.top,
                        nearBottom: isNearTranscriptBottom(geometry),
                        nearTop: geometry.contentOffset.y <= 32,
                        underfilled: viewportHeight > 0
                            && geometry.contentSize.height < viewportHeight
                    )
                } action: { _, geometry in
                    contentHeight = geometry.contentHeight
                    if let previous = pendingPrepend,
                        geometry.contentHeight != previous.contentHeight
                    {
                        pendingPrepend = nil
                        // Eager layout gives the actual added height. Compensate for
                        // it before display, preserving even a partly visible row.
                        // ScrollPosition's coordinate includes the reported top inset.
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            readingPosition.scrollTo(
                                y: previous.offset + geometry.contentHeight - previous.contentHeight
                                    + geometry.topInset)
                        }
                        return
                    }
                    // Content-size changes are not user navigation. Only an actual
                    // user scroll may change the decision to follow the conversation.
                    followState.geometryChanged(nearBottom: geometry.nearBottom)
                    if geometry.nearBottom { initialPositionEstablished = true }
                    if !geometry.nearTop { topTriggerArmed = true }
                    if initialPositionEstablished && geometry.nearTop
                        && (topTriggerArmed || geometry.underfilled)
                        && (!geometry.nearBottom || !followState.shouldPin || geometry.underfilled)
                        && paging.hasOlderItems(in: itemIDs)
                    {
                        if !geometry.underfilled {
                            followState.pause()
                            pendingPrepend = geometry
                        }
                        topTriggerArmed = false
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { paging.revealOlder(in: itemIDs) }
                    }
                }
                .onScrollPhaseChange { _, newPhase, context in
                    followState.phaseChanged(
                        newPhase, nearBottom: isNearTranscriptBottom(context.geometry))
                }
                .onChange(of: submissionID) { _, submission in
                    guard submission != nil else { return }
                    resetAttachedHistory()
                }
                .onChange(of: scrollTargetMessageID) { _, target in
                    guard let target else { return }
                    followState.pause()
                    pendingPrepend = nil
                    paging.reveal(target, in: itemIDs)
                    initialPositionEstablished = true
                    Task { @MainActor in
                        await Task.yield()
                        guard scrollTargetMessageID == target else { return }
                        proxy.scrollTo(target, anchor: .center)
                        scrollTargetMessageID = nil
                    }
                }
                .task(id: searchNavigation) {
                    guard let request = searchNavigation else { return }
                    followState.pause()
                    pendingPrepend = nil
                    paging.reveal(request.rowID, in: itemIDs)
                    initialPositionEstablished = true
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    onSearchNavigation(request.id)
                }
                .background {
                    ChatTranscriptScrollPinner(
                        revision: revision,
                        request: ChatTranscriptPinRequest(
                            sessionID: currentSessionID,
                            fingerprint: ChatTranscriptFingerprint(
                                messageCount: itemIDs.count, lastMessageID: itemIDs.last),
                            contentHeight: contentHeight,
                            viewportHeight: viewportHeight,
                            paused: !followState.shouldPin || scrollTargetMessageID != nil
                        ),
                        proxy: proxy
                    )
                }
        }
        .id(currentSessionID)
        .onChange(of: itemIDs, initial: true) { _, ids in
            paging.updateItems(ids)
        }
        .onChange(of: currentSessionID) { _, _ in
            resetAttachedHistory()
        }
    }

    private func resetAttachedHistory() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // A send explicitly returns to the newest page even when the reader
            // was paused in older history. Cancel any pending prepend correction.
            paging = ChatTranscriptPagingState()
            paging.updateItems(itemIDs)
            // Issue a new command rather than assigning another .bottom value:
            // the stored position may still say .bottom after a proxy message jump.
            readingPosition.scrollTo(edge: .bottom)
            scrollTargetMessageID = nil
            pendingPrepend = nil
            initialPositionEstablished = false
            topTriggerArmed = true
            followState = ChatTranscriptFollowState()
        }
    }

    private func isNearTranscriptBottom(_ geometry: ScrollGeometry) -> Bool {
        // ScrollGeometry can report a zero container size during an initial layout.
        let height =
            geometry.containerSize.height > 0
            ? geometry.containerSize.height : viewportHeight
        return height > 0 && geometry.contentOffset.y + height >= geometry.contentSize.height - 60
    }
}

enum ChatTranscriptScrollTarget {
    static let bottom = "chat-transcript-bottom"
}

struct ChatTranscriptFingerprint: Equatable {
    let messageCount: Int
    let lastMessageID: UUID?
}

/// Following is user intent, not a conclusion drawn from changing content geometry.
struct ChatTranscriptFollowState {
    private var isFollowing = true
    private var isUserScrolling = false
    var shouldPin: Bool { isFollowing && !isUserScrolling }

    mutating func pause() { isFollowing = false }

    mutating func geometryChanged(nearBottom: Bool) {
        if isUserScrolling { isFollowing = nearBottom }
    }

    mutating func phaseChanged(_ phase: ScrollPhase, nearBottom: Bool) {
        switch phase {
        case .tracking, .interacting, .decelerating:
            isUserScrolling = true
            isFollowing = false
        case .idle:
            if isUserScrolling { isFollowing = nearBottom }
            isUserScrolling = false
        default:
            break
        }
    }
}

private struct ChatTranscriptGeometry: Equatable {
    let contentHeight: CGFloat
    let offset: CGFloat
    let topInset: CGFloat
    let nearBottom: Bool
    let nearTop: Bool
    let underfilled: Bool
}

private struct ChatTranscriptPinRequest: Equatable {
    let sessionID: UUID?
    let fingerprint: ChatTranscriptFingerprint
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    let paused: Bool
}

private struct ChatTranscriptScrollPinner: View {
    let revision: ChatTranscriptRevision
    let request: ChatTranscriptPinRequest
    let proxy: ScrollViewProxy

    private struct Update: Equatable {
        let request: ChatTranscriptPinRequest
        let revision: Int
    }

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            // Keep the streaming revision observation out of the transcript's body.
            .task(id: Update(request: request, revision: revision.value)) {
                guard !request.paused, request.viewportHeight > 0 else { return }
                // Coalesce insertion, revision, and geometry notifications. Scrolling
                // inside those callbacks can target the transcript's previous layout.
                await Task.yield()
                guard !Task.isCancelled else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(ChatTranscriptScrollTarget.bottom, anchor: .bottom)
                }
            }
    }
}

/// Eagerly measure the attached rows and composer clearance for stable scrolling.
struct ChatTranscriptStack<Item: Identifiable, Row: View, Empty: View, Footer: View>: View {
    let items: [Item]
    let row: (Item) -> Row
    let empty: Empty
    let footer: Footer

    init(
        items: [Item],
        @ViewBuilder empty: () -> Empty,
        @ViewBuilder row: @escaping (Item) -> Row,
        @ViewBuilder footer: () -> Footer
    ) {
        self.items = items
        self.row = row
        self.empty = empty()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if items.isEmpty { empty }
            ForEach(items, content: row)
            footer
        }
    }
}

/// The attached range expands until a send or session switch resets it.
/// Other appends (assistant/tool output) keep its oldest row.
struct ChatTranscriptPagingState {
    let pageSize = 8
    private(set) var firstAttachedID: UUID?
    private var previousIDs: [UUID] = []

    func attachedRange(in ids: [UUID]) -> Range<Int> {
        let start =
            firstAttachedID.flatMap { ids.firstIndex(of: $0) }
            ?? max(0, ids.count - pageSize)
        return start ..< ids.count
    }

    func hasOlderItems(in ids: [UUID]) -> Bool { attachedRange(in: ids).lowerBound > 0 }

    mutating func updateItems(_ ids: [UUID]) {
        if let firstAttachedID, !ids.contains(firstAttachedID) {
            let survivingIDs = Set(ids)
            self.firstAttachedID = previousIDs.firstIndex(of: firstAttachedID).flatMap { oldStart in
                previousIDs[oldStart...].first { survivingIDs.contains($0) }
            }
        }
        if firstAttachedID == nil { firstAttachedID = ids.suffix(pageSize).first }
        previousIDs = ids
    }

    mutating func revealOlder(in ids: [UUID]) {
        let start = max(0, attachedRange(in: ids).lowerBound - pageSize)
        if !ids.isEmpty { firstAttachedID = ids[start] }
    }

    mutating func reveal(_ id: UUID, in ids: [UUID]) {
        guard let index = ids.firstIndex(of: id), index < attachedRange(in: ids).lowerBound else {
            return
        }
        // Include context above the target so centering it does not immediately
        // run into the paging boundary.
        firstAttachedID = ids[max(0, index - pageSize)]
    }
}
