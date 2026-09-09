import AppKit
import Observation
import SwiftUI
import XCTest

@MainActor
final class ChatTranscriptScrollingTests: XCTestCase {
    func testSendingFirstMessageKeepsContentInViewport() async throws {
        try await exerciseInsertion(historyCount: 0)
    }

    func testSendingIntoLongTranscriptKeepsContentInViewport() async throws {
        try await exerciseInsertion(historyCount: 1_000)
    }

    func testSendingFromTopOfLongTranscriptRendersRetainedMarkdownWithoutManualScroll() async throws {
        try await withTranscript(historyCount: 1_000) { model, probe, host in
            model.target = model.rows[0].id
            try await self.settleRendering(host, probe: probe)
            XCTAssertEqual(self.nativeSurfaceCount(in: host), 1_000)

            model.rows.append(.init(id: UUID(), content: "A new question", isUser: true))
            model.submissionID = UUID()
            model.isStreaming = true
            model.revision.bump()
            try await self.settleRendering(host, probe: probe)
            XCTAssertEqual(self.nativeSurfaceCount(in: host), 8)
            try self.assertPinned(probe, height: model.viewportHeight)

            let surfaces = self.descendants(of: host).compactMap { $0 as? MarkdownSurface }
            var visibleFragments = 0
            for surface in surfaces where !surface.visibleRect.isEmpty {
                let texts = self.descendants(of: surface).compactMap {
                    $0 as? MarkdownSelectableTextView
                }
                for block in try XCTUnwrap(surface.snapshot).blocks {
                    for fragment in block.text {
                        let frame = fragment.frame.offsetBy(dx: block.frame.minX, dy: block.frame.minY)
                        guard frame.intersects(surface.visibleRect), fragment.text.length > 0 else { continue }
                        visibleFragments += 1
                        XCTAssertTrue(
                            texts.contains { $0.matches(fragment) },
                            "Visible Markdown must mount after history eviction without a scroll event")
                    }
                }
            }
            XCTAssertGreaterThan(visibleFragments, 1, "Check retained response text as well as the new prompt")
        }
    }

    func testPagingOlderRowsPreservesPartiallyVisibleRow() async throws {
        try await withTranscript(historyCount: 40) { model, probe, host in
            XCTAssertEqual(self.nativeSurfaceCount(in: host), 8)
            for firstIndex in stride(from: 32, through: 8, by: -8) {
                let id = model.rows[firstIndex].id
                let view = try XCTUnwrap(probe.rows[id]?.view)
                let scroll = try XCTUnwrap(view.enclosingScrollView)
                let clip = scroll.contentView
                clip.postsBoundsChangedNotifications = true
                clip.scroll(to: CGPoint(x: 0, y: 28))
                scroll.reflectScrolledClipView(clip)
                let originalY = view.convert(view.bounds, to: clip).minY - clip.bounds.minY
                probe.renderedRowPositions.removeAll()
                try await self.settleRendering(host, probe: probe, rowID: id)
                XCTAssertEqual(self.nativeSurfaceCount(in: host), 40 - firstIndex + 8)
                let finalY = view.convert(view.bounds, to: clip).minY - clip.bounds.minY
                XCTAssertEqual(
                    finalY, originalY, accuracy: 1, "Prepending must preserve the reading offset")
                XCTAssertTrue(
                    probe.renderedRowPositions.allSatisfy { abs($0 - originalY) <= 1 },
                    "No displayed frame should jump while attaching older rows")
            }
        }
    }

    func testJumpToUnattachedMessageAndSessionReset() async throws {
        try await withTranscript(historyCount: 40) { model, probe, host in
            model.target = model.rows[5].id
            try await self.settle()
            XCTAssertEqual(self.nativeSurfaceCount(in: host), 40)
            let view = try XCTUnwrap(probe.rows[model.rows[5].id]?.view)
            let clip = try XCTUnwrap(view.enclosingScrollView?.contentView)
            let rect = view.convert(view.bounds, to: clip)
            XCTAssertTrue(rect.intersects(clip.bounds), "Reveal the target before jumping to it")
            model.sessionID = UUID()
            try await self.settle()
            XCTAssertEqual(self.nativeSurfaceCount(in: host), 8)
            try self.assertPinned(probe, height: model.viewportHeight)
        }
    }

    func testPagingWhileStreamingPreservesReadingPosition() async throws {
        try await withTranscript(historyCount: 40) { model, probe, host in
            let id = model.rows[32].id
            let view = try XCTUnwrap(probe.rows[id]?.view)
            let scroll = try XCTUnwrap(view.enclosingScrollView)
            let clip = scroll.contentView
            clip.scroll(to: CGPoint(x: 0, y: 28))
            scroll.reflectScrolledClipView(clip)
            let originalY = view.convert(view.bounds, to: clip).minY - clip.bounds.minY
            let stream = Task { @MainActor in
                model.isStreaming = true
                for _ in 0 ..< 20 {
                    try await Task.sleep(for: .milliseconds(8))
                    model.rows[39].content += "\n\nMore streamed content."
                    model.revision.bump()
                }
            }
            defer { stream.cancel() }
            try await self.settleRendering(host, probe: probe, rowID: id)
            try await stream.value
            XCTAssertEqual(self.nativeSurfaceCount(in: host), 16)
            XCTAssertTrue(
                probe.renderedRowPositions.allSatisfy { abs($0 - originalY) <= 1 },
                "Content growing below the reader must not affect the prepend anchor")
        }
    }

    func testShortPagesFillViewportWithoutAttachingAllHistory() async throws {
        let rows = (0 ..< 100).map { _ in
            ScrollTestModel.Row(id: UUID(), content: "Short", isUser: true)
        }
        try await withTranscript(historyCount: 0, rows: rows) { model, probe, host in
            XCTAssertGreaterThan(self.nativeSurfaceCount(in: host), 8)
            XCTAssertLessThan(self.nativeSurfaceCount(in: host), rows.count)
            try self.assertPinned(probe, height: model.viewportHeight)
        }
    }

    func testSendingReleasesPagedHistoryAndAllowsPagingAgainDuringStreaming() async throws {
        try await withTranscript(historyCount: 40) { model, probe, host in
            // Jump into old history to attach every row and pause bottom following.
            model.target = model.rows[5].id
            try await self.settle()
            XCTAssertEqual(self.nativeSurfaceCount(in: host), 40)

            for _ in 0 ..< 2 {
                probe.renderedFooterFrames.removeAll()
                model.rows.append(.init(id: UUID(), content: "A new question", isUser: true))
                model.submissionID = UUID()
                model.isStreaming = true
                model.revision.bump()
                try await self.settleRendering(host, probe: probe)
                XCTAssertEqual(
                    self.nativeSurfaceCount(in: host), 8, "Release the older attached rows on send")
                try self.assertPinned(probe, height: model.viewportHeight)
                XCTAssertTrue(
                    probe.renderedFooterFrames.allSatisfy {
                        abs($0.maxY - model.viewportHeight) <= 2
                    },
                    "Removing history must not display a blank or displaced transcript")

                // The assistant shell and streamed text must keep the small working set.
                let firstAttachedID = model.rows[model.rows.count - 8].id
                model.rows.append(.init(id: UUID(), content: ""))
                model.revision.bump()
                try await self.settle()
                model.rows[model.rows.count - 1].content = MarkdownFixtures.sample
                model.revision.bump()
                try await self.settleRendering(host, probe: probe)
                XCTAssertEqual(self.nativeSurfaceCount(in: host), 9)
                try self.assertPinned(probe, height: model.viewportHeight)

                let first = try XCTUnwrap(probe.rows[firstAttachedID]?.view)
                let scroll = try XCTUnwrap(first.enclosingScrollView)
                scroll.contentView.scroll(to: CGPoint(x: 0, y: 28))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await self.settleRendering(host, probe: probe)
                XCTAssertEqual(
                    self.nativeSurfaceCount(in: host), 17,
                    "Older history remains available after sending")

                // Receiving output is not a send and must not collapse reopened history.
                model.rows.append(.init(id: UUID(), content: "Additional assistant output"))
                model.revision.bump()
                try await self.settle()
                XCTAssertEqual(self.nativeSurfaceCount(in: host), 18)
            }
            XCTAssertEqual(
                model.rows.count, 46, "Unpaging must only remove views, never conversation data")
            // Regenerating an existing prompt can submit without changing row IDs.
            model.submissionID = UUID()
            model.revision.bump()
            try await self.settleRendering(host, probe: probe)
            XCTAssertEqual(self.nativeSurfaceCount(in: host), 8)
            try self.assertPinned(probe, height: model.viewportHeight)
        }
    }

    func testPagingBoundarySurvivesAppendsAndDeletion() {
        var ids = (0 ..< 40).map { _ in UUID() }
        var paging = ChatTranscriptPagingState()
        paging.updateItems(ids)
        XCTAssertEqual(paging.attachedRange(in: ids), 32 ..< 40)
        paging.revealOlder(in: ids)
        ids.append(UUID())
        paging.updateItems(ids)
        XCTAssertEqual(paging.attachedRange(in: ids), 24 ..< 41)
        let nextID = ids[25]
        ids.remove(at: 24)
        paging.updateItems(ids)
        XCTAssertEqual(paging.firstAttachedID, nextID)
        XCTAssertEqual(paging.attachedRange(in: ids), 24 ..< 40)
        paging.updateItems([])
        XCTAssertTrue(paging.attachedRange(in: []).isEmpty)
        paging.updateItems(ids)
        XCTAssertEqual(paging.attachedRange(in: ids), 32 ..< 40)
    }

    func testTypingUpdatesComposerWithoutRebuildingLongTranscript() async throws {
        let chat = ChatViewModel()
        for _ in 0 ..< 100 {
            if !chat.isLoadingSessions { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(chat.isLoadingSessions)
        try await withTranscript(historyCount: 1_000, draftModel: chat) { model, probe, host in
            let initialUpdates = probe.transcriptBodyUpdates
            probe.renderedFooterFrames.removeAll()
            for character in "Testing 123" {
                chat.draft.append(character)
                try await self.settleRendering(host, probe: probe)
            }
            XCTAssertEqual(probe.displayedDraft, "Testing 123")
            XCTAssertTrue(probe.canSend)
            XCTAssertEqual(probe.transcriptBodyUpdates, initialUpdates)
            try self.assertPinned(probe, height: model.viewportHeight)
            let bottoms = probe.renderedFooterFrames.map(\.maxY)
            XCTAssertLessThanOrEqual(
                try XCTUnwrap(bottoms.max()) - XCTUnwrap(bottoms.min()), 2,
                "Typing must not move unchanged transcript content")

            chat.draft = ""
            try await self.settle()
            XCTAssertEqual(probe.displayedDraft, "")
            XCTAssertFalse(probe.canSend)
            XCTAssertEqual(probe.transcriptBodyUpdates, initialUpdates)
        }
    }

    func testSendingAndBulkStreamingAfterVeryTallReplies() async throws {
        // Short prompts interleaved with replies several viewports tall. A large
        // count of similarly sized rows does not exercise the same scroll transitions.
        let sizes = [4, 3, 5, 1, 4, 5, 5, 5, 9, 9, 9, 11, 11, 11, 0, 0, 4, 3, 3, 3]
        let rows = sizes.flatMap { size in
            [
                ScrollTestModel.Row(id: UUID(), content: "A short question?", isUser: true),
                ScrollTestModel.Row(
                    id: UUID(),
                    content: size == 0
                        ? "A short answer."
                        : String(repeating: MarkdownFixtures.sample, count: size),
                    hasReasoning: true
                ),
            ]
        }
        try await withTranscript(historyCount: 0, rows: rows) { model, probe, _ in
            // Repeat the same insertion sequence as the conversation grows.
            for turn in 0 ..< 4 {
                model.rows.append(
                    .init(id: UUID(), content: "Another short question?", isUser: true))
                model.submissionID = UUID()
                model.composerHeight = 145
                model.isStreaming = true
                model.revision.bump()
                try await self.settle()
                try self.assertPinned(probe, height: model.viewportHeight)

                model.rows.append(.init(id: UUID(), content: "", hasReasoning: true))
                model.revision.bump()
                try await self.settle()
                try self.assertPinned(probe, height: model.viewportHeight)

                // The footer must stay addressable even when one flush adds more
                // content than fits in the viewport.
                model.rows[model.rows.count - 1].content =
                    String(repeating: MarkdownFixtures.sample, count: 12) + "\n\nReply \(turn)"
                model.revision.bump()
                try await self.settle()
                try self.assertPinned(probe, height: model.viewportHeight)
                model.isStreaming = false
            }
        }
    }

    func testResizingWhileFollowingKeepsComposerClearanceVisible() async throws {
        try await withTranscript(historyCount: 100) { model, probe, _ in
            model.viewportHeight = 480
            try await self.settle()
            try self.assertPinned(probe, height: model.viewportHeight)
            model.composerHeight = 280
            try await self.settle()
            try self.assertPinned(probe, height: model.viewportHeight)
        }
    }

    func testContentGeometryChangesDoNotChangeFollowingIntent() {
        var state = ChatTranscriptFollowState()
        state.geometryChanged(nearBottom: false)
        XCTAssertTrue(state.shouldPin, "A content-size change must not lose the bottom pin")
        state.pause()
        state.geometryChanged(nearBottom: true)
        XCTAssertFalse(
            state.shouldPin, "A layout correction must not undo a deliberate message jump")
    }

    func testFollowingResumesOnlyAfterUserReturnsToBottom() {
        var state = ChatTranscriptFollowState()
        state.phaseChanged(.interacting, nearBottom: true)
        state.geometryChanged(nearBottom: true)
        XCTAssertFalse(state.shouldPin, "Never issue an automatic scroll during a user gesture")
        state.geometryChanged(nearBottom: false)
        state.phaseChanged(.idle, nearBottom: false)
        XCTAssertFalse(state.shouldPin)
        state.geometryChanged(nearBottom: true)
        XCTAssertFalse(state.shouldPin, "Streaming layout changes must preserve the reading pause")
        state.phaseChanged(.decelerating, nearBottom: true)
        XCTAssertFalse(state.shouldPin)
        state.phaseChanged(.idle, nearBottom: true)
        XCTAssertTrue(state.shouldPin)
    }

    private func exerciseInsertion(historyCount: Int) async throws {
        try await withTranscript(historyCount: historyCount) { model, probe, host in
            if historyCount >= 1_000 {
                XCTAssertEqual(
                    self.nativeSurfaceCount(in: host), 8,
                    "Only the newest page should be attached initially")
            }
            probe.renderedFooterFrames.removeAll()
            model.rows.append(
                .init(
                    id: UUID(), content: "A newly sent message in this conversation.", isUser: true)
            )
            model.composerHeight = 130
            model.submissionID = UUID()
            model.isStreaming = true
            model.revision.bump()
            try await self.settleRendering(host, probe: probe)
            try self.assertPinned(probe, height: model.viewportHeight)

            // Sending inserts an assistant shell before the first content flush.
            model.rows.append(.init(id: UUID(), content: ""))
            model.revision.bump()
            try await self.settleRendering(host, probe: probe)
            try self.assertPinned(probe, height: model.viewportHeight)
            XCTAssertFalse(
                probe.renderedFooterFrames.contains { $0.maxY < 0 },
                "Insertion displayed the transcript above the viewport")
            XCTAssertFalse(
                probe.renderedFooterFrames.isEmpty,
                "Observe display passes, not just layout estimates")

            let response = MarkdownFixtures.sample
            for length in stride(from: 96, to: response.count + 96, by: 96) {
                model.rows[model.rows.count - 1].content = String(response.prefix(length))
                model.revision.bump()
                try await self.settle()
                try self.assertPinned(probe, height: model.viewportHeight)
            }
        }
    }

    private func withTranscript(
        historyCount: Int,
        rows: [ScrollTestModel.Row]? = nil,
        draftModel: ChatViewModel? = nil,
        body: (ScrollTestModel, ScrollTestProbe, NSView) async throws -> Void
    ) async throws {
        let model = ScrollTestModel(historyCount: historyCount)
        if let rows { model.rows = rows }
        let probe = ScrollTestProbe()
        let host = NSHostingView(
            rootView: Group {
                if let draftModel {
                    ScrollTestDraftHost(chat: draftModel, model: model, probe: probe)
                } else {
                    ScrollTestTranscript(model: model, probe: probe)
                }
            })
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 700, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        // Exercise SwiftUI's real layout passes without taking keyboard focus.
        window.orderBack(nil)
        try await settle()
        try assertPinned(probe, height: model.viewportHeight)
        try await body(model, probe, host)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(350))
    }

    private func settleRendering(_ host: NSView, probe: ScrollTestProbe, rowID: UUID? = nil)
        async throws
    {
        // The background test window may be occluded. Force display passes so we
        // inspect rendered native positions, not transient pre-layout preferences.
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0 ..< 22 {
            try await Task.sleep(for: .milliseconds(16))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let marker = try XCTUnwrap(probe.footerView)
            let clip = try XCTUnwrap(marker.enclosingScrollView?.contentView)
            probe.renderedFooterFrames.append(
                marker.convert(marker.bounds, to: clip).offsetBy(
                    dx: -clip.bounds.minX, dy: -clip.bounds.minY)
            )
            if let rowID {
                let row = try XCTUnwrap(probe.rows[rowID]?.view)
                probe.renderedRowPositions.append(
                    row.convert(row.bounds, to: clip).minY - clip.bounds.minY)
            }
        }
    }

    private func assertPinned(_ probe: ScrollTestProbe, height: CGFloat) throws {
        let marker = try XCTUnwrap(probe.footerView)
        let clip = try XCTUnwrap(
            marker.enclosingScrollView?.contentView, "Footer must stay mounted")
        let nativeBottom = marker.convert(marker.bounds, to: clip).maxY - clip.bounds.minY
        XCTAssertEqual(
            nativeBottom, height, accuracy: 2,
            "Check actual AppKit geometry as well as SwiftUI's reported frame")
        let frame = try XCTUnwrap(probe.footer)
        XCTAssertEqual(
            frame.maxY, height, accuracy: 2, "Composer clearance must remain at the viewport bottom"
        )
    }

    private func nativeSurfaceCount(in view: NSView) -> Int {
        (view is MarkdownSurface ? 1 : 0)
            + view.subviews.reduce(0) { $0 + nativeSurfaceCount(in: $1) }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

}

@MainActor @Observable
private final class ScrollTestModel {
    struct Row: Identifiable {
        let id: UUID
        var content: String
        var isUser = false
        var hasReasoning = false
    }
    var rows: [Row]
    var composerHeight: CGFloat = 210
    var viewportHeight: CGFloat = 640
    var isStreaming = false
    var sessionID = UUID()
    var submissionID: UUID?
    var target: UUID?
    let revision = ChatTranscriptRevision()

    init(historyCount: Int) {
        rows = (0 ..< historyCount).map { index in
            Row(
                id: UUID(),
                content: index % 3 == 0 ? MarkdownFixtures.sample : MarkdownFixtures.short)
        }
    }
}

@MainActor
private final class ScrollTestProbe {
    struct RowView { weak var view: NSView? }
    var rows: [UUID: RowView] = [:]
    var renderedRowPositions: [CGFloat] = []
    weak var footerView: NSView?
    var footer: CGRect?
    var renderedFooterFrames: [CGRect] = []
    var transcriptBodyUpdates = 0
    var displayedDraft = ""
    var canSend = false
}

private struct ScrollTestDraftHost: View {
    @ObservedObject var chat: ChatViewModel
    let model: ScrollTestModel
    let probe: ScrollTestProbe

    var body: some View {
        let _ = probe.transcriptBodyUpdates += 1
        ScrollTestTranscript(model: model, probe: probe)
            .overlay(alignment: .bottom) {
                ScrollTestComposer(chat: chat, probe: probe)
            }
    }
}

private struct ScrollTestComposer: View {
    @ObservedObject var chat: ChatViewModel
    let probe: ScrollTestProbe

    var body: some View {
        let _ = probe.displayedDraft = chat.draft
        let canSend = chat.canSend(isRunning: true, selectedModelID: "test-model")
        let _ = probe.canSend = canSend
        HStack {
            TextField("Message", text: $chat.draft)
            Button("Send") {}.disabled(!canSend)
        }
        .frame(height: 90)
        .background(Color.white)
    }
}

private struct ScrollTestTranscript: View {
    @Bindable var model: ScrollTestModel
    let probe: ScrollTestProbe

    var body: some View {
        ChatTranscriptScroller(
            currentSessionID: model.sessionID,
            revision: model.revision,
            submissionID: model.submissionID,
            scrollTargetMessageID: $model.target,
            itemIDs: model.rows.map(\.id),
            topInset: { EmptyView() }
        ) { attachedRange in
            ChatTranscriptStack(items: Array(model.rows[attachedRange])) {
                Text("Start a conversation").frame(maxWidth: .infinity).padding(.top, 120)
            } row: { row in
                testRow(row)
            } footer: {
                Color.clear.frame(height: model.composerHeight)
                    .background(ScrollTestFooterMarker(probe: probe))
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named("testViewport"))
                    } action: { frame in
                        probe.footer = frame
                    }
                    .id(ChatTranscriptScrollTarget.bottom)
            }
            .frame(maxWidth: 616)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 42)
            .padding(.top, 18)
        }
        .frame(width: 700, height: model.viewportHeight)
        .coordinateSpace(name: "testViewport")
        .background(Color.white)
    }
    private func testRow(_ row: ScrollTestModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !row.isUser {
                Text("Assistant").font(.caption)
                if row.hasReasoning {
                    Text("Worked").frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }
            ChatMarkdownRenderer(
                messageID: row.id, content: row.content,
                isStreaming: model.isStreaming && row.id == model.rows.last?.id,
                fontScale: 1
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ScrollTestRowMarker(id: row.id, probe: probe))
        .id(row.id)
    }

}

private struct ScrollTestRowMarker: NSViewRepresentable {
    let id: UUID
    let probe: ScrollTestProbe
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        probe.rows[id] = .init(view: view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { probe.rows[id] = .init(view: view) }
}

private struct ScrollTestFooterMarker: NSViewRepresentable {
    let probe: ScrollTestProbe
    func makeNSView(context: Context) -> Marker {
        Marker(probe: probe)
    }
    func updateNSView(_ view: Marker, context: Context) {
        if view.window != nil { probe.footerView = view }
    }
    final class Marker: NSView {
        let probe: ScrollTestProbe
        init(probe: ScrollTestProbe) {
            self.probe = probe
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { probe.footerView = self }
        }
    }
}
