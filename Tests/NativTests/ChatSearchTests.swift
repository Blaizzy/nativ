import AppKit
import SwiftUI
import XCTest

@MainActor
final class ChatSearchTests: XCTestCase {
    func testSearchProjectionMatchesRenderedMarkdownFragments() throws {
        let source = """
        # A heading

        A **bold** paragraph with [a link](https://example.com/hidden), `code` and a soft
        break. 🌙

        - First item
        - Second *item*

        > Quoted text

        | Name | Value |
        | --- | --- |
        | Alpha | Beta |

        ```swift
        let answer = 42
        ```

        Inline $x+y$ math and ![image label](https://example.com/image.png).
        """
        let input = input(source, markdown: true)
        let fragments = ChatSearchDocument.fragments(for: input)
        let layout = MarkdownLayouter.layout(MathPreprocessor.preprocess(source), width: 500, style: MarkdownStyle())
        let rendered = Dictionary(uniqueKeysWithValues: layout.blocks.flatMap { block in
            block.text.map { (block.id + "/" + $0.id, $0.text.string) }
        })
        for fragment in fragments { XCTAssertEqual(fragment.text, rendered[fragment.id], fragment.id) }
        XCTAssertFalse(fragments.map(\.text).joined().contains("example.com/hidden"))
    }

    func testSearchIncludesRenderedMessagesAndMapsGroupedResponsesToTheirRow() {
        let user = ChatTranscriptMessage(role: .user, content: "Question")
        let tool = ChatTranscriptMessage(role: .tool, content: "Hidden tool output")
        let assistant = ChatTranscriptMessage(role: .assistant, content: "Final answer")
        let items = ChatTranscriptPresentation.items(from: [user, tool, assistant])
        let snapshots = ChatSearchInput.snapshots(from: items)
        XCTAssertEqual(snapshots.map(\.messageID), [user.id, assistant.id])
        XCTAssertEqual(snapshots.last?.rowID, tool.id)
    }

    func testWorkerSearchesVisibleMarkdownAndPreservesPlainUserText() async throws {
        let worker = ChatSearchWorker()
        let messages = [input("notification **permissions**", markdown: true), input("literal **permissions**")]
        let result = try await worker.search("notification permission", inputs: messages)
        XCTAssertEqual(result.occurrences.count, 1)
        XCTAssertEqual(result.occurrences.first?.text, "notification permissions")
        let literal = try await worker.search("\"**permissions**\"", inputs: messages)
        XCTAssertEqual(literal.occurrences.map(\.messageID), [messages[1].messageID])
    }

    func testWorkerRefreshesEditedMessagesAndRemovesDeletedMessages() async throws {
        let worker = ChatSearchWorker()
        let original = input("notification")
        let initial = try await worker.search("notification", inputs: [original])
        XCTAssertEqual(initial.occurrences.count, 1)
        let edited = ChatSearchInput(messageID: original.messageID, rowID: original.rowID, text: "different text", markdown: false)
        let afterEdit = try await worker.search("notification", inputs: [edited])
        XCTAssertTrue(afterEdit.occurrences.isEmpty)
        let afterDelete = try await worker.search("notification", inputs: [])
        XCTAssertTrue(afterDelete.occurrences.isEmpty)
    }

    func testWorkerPreservesWordFormsAndTyposWithoutExplicitLanguageDetection() async throws {
        for (query, text) in [("running", "We ran yesterday."), ("mouse", "mice"),
                              ("mouse", "The mice ate cheese."),
                              ("child", "children"), ("conect", "We connected yesterday."),
                              ("notificaiton", "notification")] {
            for markdown in [false, true] {
                let message = input(markdown ? "**\(text)**" : text, markdown: markdown)
                let result = try await ChatSearchWorker().search(query, inputs: [message])
                XCTAssertEqual(result.occurrences.map(\.messageID), [message.messageID], query)
            }
        }
    }

    func testIndexedQueriesReuseSnapshotsUntilContentChanges() async throws {
        let state = ChatSearchState()
        var reads = 0
        var messages = [ChatTranscriptMessage(role: .user, content: "notification permissions")]
        func items() -> [ChatTranscriptItem] {
            reads += 1
            return ChatTranscriptPresentation.items(from: messages)
        }
        state.query = "notification"
        state.update(items: items(), contentRevision: 1, queryChanged: true)
        try await waitForSearch(state)
        state.query = "permission"
        state.update(items: items(), contentRevision: 1, queryChanged: true)
        try await waitForSearch(state)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(state.occurrences.count, 1)
        messages[0].content = "changed content"
        state.update(items: items(), contentRevision: 2)
        try await waitForSearch(state)
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(state.occurrences.isEmpty)
    }

    func testSingleWordIndexRefreshesAfterEditsAndDeletions() async throws {
        let worker = ChatSearchWorker()
        let first = input("mice")
        try await worker.synchronize([first])
        for query in ["mouse", "mouse"] {
            let result = try await worker.search(query)
            XCTAssertEqual(result.occurrences.map(\.messageID), [first.messageID])
        }
        let edited = ChatSearchInput(messageID: first.messageID, rowID: first.rowID, text: "children", markdown: false)
        try await worker.synchronize([edited])
        let old = try await worker.search("mouse")
        XCTAssertTrue(old.occurrences.isEmpty)
        let new = try await worker.search("child")
        XCTAssertEqual(new.occurrences.map(\.messageID), [first.messageID])
        try await worker.synchronize([])
        let deleted = try await worker.search("child")
        XCTAssertTrue(deleted.occurrences.isEmpty)
    }

    func testPhraseCanSpanMarkdownParagraphs() async throws {
        let result = try await ChatSearchWorker().search("notification permission", inputs: [
            input("notification\n\n**permissions**", markdown: true),
        ])
        let occurrence = try XCTUnwrap(result.occurrences.first)
        XCTAssertEqual(result.occurrences.count, 1)
        XCTAssertEqual(occurrence.fragments.map(\.text), ["notification", "permissions"])
    }

    func testWorkerReportsTruncationAndSearchesOlderMessages() async throws {
        let worker = ChatSearchWorker()
        let messages = (0..<250).map { _ in input("notification") }
        let result = try await worker.search("notificaiton", inputs: messages, limit: 2)
        XCTAssertEqual(result.occurrences.map(\.messageID), Array(messages.prefix(2).map(\.messageID)))
        XCTAssertTrue(result.hasMore)
    }

    func testNavigationWrapsAndChatSwitchClearsState() async throws {
        let state = ChatSearchState()
        state.reset(sessionID: UUID())
        XCTAssertFalse(state.isPresented)
        state.present()
        XCTAssertTrue(state.isPresented)
        let focus = state.focusID
        state.present()
        XCTAssertNotEqual(state.focusID, focus)
        state.query = "notification"
        state.update(items: [.message(ChatTranscriptMessage(role: .user, content: "notification notification"))], queryChanged: true)
        try await waitForSearch(state)
        XCTAssertEqual(state.countLabel, "1/2")
        state.move(-1)
        XCTAssertEqual(state.countLabel, "2/2")
        state.move(1)
        XCTAssertEqual(state.countLabel, "1/2")
        let previousNavigation = state.navigationID
        state.move(1)
        state.finishNavigation(previousNavigation)
        XCTAssertNil(state.revealID)
        state.finishNavigation(state.navigationID)
        XCTAssertEqual(state.revealID, state.navigationID)
        state.dismiss()
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(state.query, "")
        XCTAssertNil(state.selected)
        XCTAssertTrue(state.occurrences.isEmpty)
    }

    func testSupersededQueriesAndSessionResetsCannotPublishOldResults() async throws {
        let state = ChatSearchState()
        let items = [ChatTranscriptItem.message(ChatTranscriptMessage(role: .user, content: "notification permission"))]
        state.query = "notification"
        state.update(items: items, queryChanged: true)
        state.query = "permission"
        state.update(items: items, queryChanged: true)
        try await waitForSearch(state)
        let match = try XCTUnwrap(state.selected)
        XCTAssertEqual((match.text as NSString).substring(with: match.range), "permission")
        state.query = "notification"
        state.update(items: items, queryChanged: true)
        state.reset(sessionID: UUID())
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(state.occurrences.isEmpty)
        XCTAssertFalse(state.isSearching)
    }

    func testStreamingUpdatesAreNotStarvedByDebouncing() async throws {
        let state = ChatSearchState()
        state.query = "notification"
        let id = UUID()
        for index in 0..<12 {
            state.update(items: [.message(ChatTranscriptMessage(id: id, role: .user,
                                                               content: "notification \(index)"))])
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertFalse(state.occurrences.isEmpty)
        try await waitForSearch(state)
        XCTAssertEqual(state.selected?.text, "notification 11")
        state.stop()
    }

    func testStreamingDoesNotRepeatedlyNavigateToAnUnchangedMatch() async throws {
        let state = ChatSearchState()
        state.query = "notification"
        let id = UUID()
        state.update(items: [.message(ChatTranscriptMessage(id: id, role: .user, content: "notification"))])
        try await waitForSearch(state)
        let navigation = state.navigationID
        state.update(items: [.message(ChatTranscriptMessage(id: id, role: .user, content: "notification continued"))])
        try await waitForSearch(state)
        XCTAssertEqual(state.navigationID, navigation)
    }

    func testHighlightsPreserveLayoutAndRevealAnOffscreenOccurrence() async throws {
        let source = (0..<120).map { "Paragraph \($0) with notification text." }.joined(separator: "\n\n")
        let worker = ChatSearchWorker()
        let result = try await worker.search("notification", inputs: [input(source, markdown: true)])
        let selected = try XCTUnwrap(result.occurrences.last)
        let (window, scroll, surface) = fixture(source)
        defer { window.close() }
        let size = surface.snapshot?.size
        surface.setSearchHighlight(ChatSearchHighlight(matches: result.occurrences, selected: selected, revealID: UUID()))
        surface.layoutSubtreeIfNeeded()
        surface.revealSearchMatchIfNeeded()
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1000)
        surface.refreshVisibleBlocks()
        let view = try XCTUnwrap(surface.visibleTextViews.first { $0.fragmentID == selected.fragmentID })
        XCTAssertEqual(view.activeSearchRange, selected.range)
        let original = try XCTUnwrap(surface.snapshot?.blocks.flatMap(\.text).first { $0.text.string == selected.text }?.text)
        XCTAssertTrue(view.textStorage?.isEqual(to: original) == true, "Focus styling must not change the stored text or its attributes")
        XCTAssertEqual(surface.snapshot?.size, size)
        surface.setSearchHighlight(nil)
        XCTAssertTrue(surface.visibleTextViews.allSatisfy { $0.searchRanges.isEmpty && $0.activeSearchRange == nil && $0.searchPulseLayer == nil })
        XCTAssertTrue(view.textStorage?.isEqual(to: original) == true)
    }

    func testPlainTextSearchPreservesMarkdownCharactersAndUnicodeRanges() async throws {
        let text = "🌙 **literal** " + String(repeating: "content ", count: 100) + "notification"
        let worker = ChatSearchWorker()
        let result = try await worker.search("notification", inputs: [input(text)])
        let (window, _, surface) = fixture(text, plainText: true)
        defer { window.close() }
        surface.setSearchHighlight(ChatSearchHighlight(matches: result.occurrences, selected: result.occurrences.first, revealID: UUID()))
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(surface.snapshot?.blocks.first?.text.first?.text.string, text)
        XCTAssertEqual(surface.visibleTextViews.first?.activeSearchRange, result.occurrences.first?.range)
    }

    func testCompactUserSearchKeepsItsIntrinsicWidth() {
        let layout = MarkdownSurface.searchPlainTextLayout("notification", width: 500, style: MarkdownStyle())
        XCTAssertGreaterThan(layout.size.width, 0)
        XCTAssertLessThan(layout.size.width, 150)
    }

    func testArrowNavigationRevealsEachOccurrenceInsidePagedSwiftUITranscript() async throws {
        let longText = (0..<100).map { "Finding \($0): notification settings.\n" + String(repeating: "Background text. ", count: 20) }
            .joined(separator: "\n\n")
        let messages = (0..<40).map { index in
            ChatTranscriptMessage(role: .assistant, content: index == 5 ? longText : "Message \(index) without a match.")
        }
        try await withSearchTranscript(messages) { search, host in
            for offset in [0, 1, 75, -60, 83, 1, -1] {
                if offset != 0 { search.move(offset) }
                try await settle(host)
                try assertSelectedOccurrencePositioned(search, in: host)
            }
            for _ in 0..<55 { search.move(1) }
            try await settle(host)
            try assertSelectedOccurrencePositioned(search, in: host)
        }
    }

    func testNavigationAcrossRowsAndWithinLongCodeAndUserText() async throws {
        let lines = (0..<90).map { "Line \($0): notification settings." }.joined(separator: "\n")
        var messages = (0..<40).map { ChatTranscriptMessage(role: .assistant, content: "Message \($0).") }
        messages[2] = ChatTranscriptMessage(role: .user, content: "notification")
        messages[8] = ChatTranscriptMessage(role: .assistant, content: "```\n" + lines + "\n```")
        messages[30] = ChatTranscriptMessage(role: .user, content: lines)
        try await withSearchTranscript(messages) { search, host in
            for offset in [0, 1, 89, 1, 89, 1, -1, -90, -90] {
                if offset != 0 { search.move(offset) }
                try await settle(host)
                try assertSelectedOccurrencePositioned(search, in: host)
            }
        }
    }

    func testLibraryResultCentersItsMessageInTheRealTranscript() async throws {
        let messages = (0..<40).map { index in
            ChatTranscriptMessage(role: .assistant,
                                  content: index == 5 || index == 35 ? "notification \(index)" : "Background message \(index)")
        }
        let session = ChatSession(id: UUID(), title: "Target", createdAt: Date(), updatedAt: Date(), messages: messages)
        let items = ChatTranscriptPresentation.items(from: messages)
        let results = try await ChatLibrarySearchWorker().search("notification", sessions: [
            ChatLibrarySearchSession(summary: session.summary, items: items)
        ])
        let target = try XCTUnwrap(results.messages.first)
        try await withSearchTranscript(messages) { search, host in
            search.reveal(target.occurrence, query: "notification", sessionID: session.id, items: items)
            search.update(items: items, queryChanged: true)
            try await waitForSearch(search)
            try await settle(host)
            XCTAssertEqual(search.selected?.messageID, messages[35].id)
            try assertSelectedOccurrencePositioned(search, in: host)
        }
    }

    func testSearchingShortChatsDoesNotExpandScrollBounds() async throws {
        for messages in [
            [ChatTranscriptMessage(role: .user, content: "notification")],
            [ChatTranscriptMessage(role: .assistant, content: "notification")],
            [ChatTranscriptMessage(role: .user, content: "notification"),
             ChatTranscriptMessage(role: .assistant, content: "Last notification.")],
        ] {
            var originalHeight: CGFloat = 0
            var originalLimits: ClosedRange<CGFloat> = 0...0
            try await withSearchTranscript(messages, beforeSearch: { host in
                let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
                originalHeight = try XCTUnwrap(scroll.documentView).frame.height
                originalLimits = scrollLimits(scroll.contentView)
            }) { search, host in
                for offset in [0, 1, -1] {
                    if offset != 0 { search.move(offset) }
                    try await settle(host)
                    let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
                    XCTAssertEqual(try XCTUnwrap(scroll.documentView).frame.height, originalHeight, accuracy: 1,
                                   "Searching must not add blank space to a short transcript")
                    let limits = scrollLimits(scroll.contentView)
                    XCTAssertEqual(limits.lowerBound, originalLimits.lowerBound, accuracy: 1)
                    XCTAssertEqual(limits.upperBound, originalLimits.upperBound, accuracy: 1)
                    try assertSelectedOccurrencePositioned(search, in: host)
                }
            }
        }
    }

    private func scrollLimits(_ clip: NSClipView) -> ClosedRange<CGFloat> {
        var bounds = clip.bounds
        bounds.origin.y = -1_000_000
        let top = clip.constrainBoundsRect(bounds).minY
        bounds.origin.y = 1_000_000
        return top...clip.constrainBoundsRect(bounds).minY
    }

    func testFirstAndLastFindingsStayVisibleInAShortChat() async throws {
        let messages = [ChatTranscriptMessage(role: .user, content: "notification"),
                        ChatTranscriptMessage(role: .assistant, content: "Last notification.")]
        try await withSearchTranscript(messages) { search, host in
            for offset in [0, 1, -1] {
                if offset != 0 { search.move(offset) }
                try await settle(host)
                try assertSelectedOccurrencePositioned(search, in: host)
            }
        }
    }

    func testPhraseSpanningParagraphsPositionsTheWholeFinding() async throws {
        let messages = [ChatTranscriptMessage(role: .assistant, content: "notification\n\npermissions")]
        try await withSearchTranscript(messages, query: "notification permissions") { search, host in
            try await settle(host)
            XCTAssertEqual(search.selected?.fragments.count, 2)
            try assertSelectedOccurrencePositioned(search, in: host)
        }
    }

    private func assertSelectedOccurrencePositioned(_ search: ChatSearchState, in host: NSView) throws {
        let selected = try XCTUnwrap(search.selected)
        let surface = try XCTUnwrap(descendants(host).compactMap { $0 as? MarkdownSurface }.first {
            $0.searchHighlight?.selected?.location == selected.location
        })
        let clip = try XCTUnwrap(surface.enclosingScrollView?.contentView)
        var bounds: CGRect?
        for fragment in selected.fragments {
            let text = try XCTUnwrap(surface.visibleTextViews.first { $0.fragmentID == fragment.id },
                                    "Selected occurrence \(search.selectedIndex) must be mounted")
            XCTAssertEqual(text.activeSearchRange, fragment.range)
            // Measure the reference without TextKit's estimates for offscreen lines.
            text.system.manager.ensureLayout(for: text.system.storage.documentRange)
            for rect in text.selectionRects(for: fragment.range) {
                let converted = text.convert(rect, to: clip)
                bounds = bounds.map { $0.union(converted) } ?? converted
            }
        }
        let finding = try XCTUnwrap(bounds)
        XCTAssertTrue(clip.bounds.intersects(finding), "The selected finding must be visible")
        let delta = finding.midY - clip.bounds.midY
        if abs(delta) > 1 {
            var boundary = clip.bounds
            boundary.origin.y = delta < 0 ? -1_000_000 : 1_000_000
            XCTAssertEqual(clip.bounds.minY, clip.constrainBoundsRect(boundary).minY, accuracy: 1,
                           "A finding must be centered unless the transcript's scroll limit prevents it")
        }
    }

    private func withSearchTranscript(_ messages: [ChatTranscriptMessage], query: String = "notification",
                                      beforeSearch: (NSView) async throws -> Void = { _ in },
                                      body: (ChatSearchState, NSView) async throws -> Void) async throws {
        let search = ChatSearchState()
        let items = ChatTranscriptPresentation.items(from: messages)
        let host = NSHostingView(rootView: SearchNavigationFixture(search: search, items: items))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { search.stop(); window.close() }
        try await settle(host)
        search.present()
        try await settle(host)
        try await beforeSearch(host)
        search.query = query
        search.update(items: items, queryChanged: true)
        try await waitForSearch(search)
        try await body(search, host)
    }

    private func settle(_ host: NSView) async throws {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func input(_ text: String, markdown: Bool = false) -> ChatSearchInput {
        let id = UUID()
        return ChatSearchInput(messageID: id, rowID: id, text: text, markdown: markdown)
    }

    private func waitForSearch(_ state: ChatSearchState) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while state.isSearching && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(state.isSearching, "Search did not finish")
        XCTAssertNil(state.error)
    }

    private func fixture(_ source: String, plainText: Bool = false) -> (NSWindow, NSScrollView, MarkdownSurface) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 250),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 250))
        scroll.hasVerticalScroller = true
        let surface = MarkdownSurface()
        surface.configure(content: source, style: MarkdownStyle(), plainText: plainText)
        surface.frame = CGRect(origin: .zero, size: surface.preflight(width: 480).size)
        scroll.documentView = surface
        window.contentView = scroll
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        surface.refreshVisibleBlocks()
        return (window, scroll, surface)
    }
}

private struct SearchNavigationFixture: View {
    let search: ChatSearchState
    let items: [ChatTranscriptItem]
    @State private var target: UUID?
    @State private var revision = ChatTranscriptRevision()

    var body: some View {
        ChatTranscriptScroller(currentSessionID: nil, revision: revision, submissionID: nil,
                               scrollTargetMessageID: $target, itemIDs: items.map(\.id),
                               searchNavigation: search.navigationRequest, onSearchNavigation: search.finishNavigation,
                               topInset: {
                                   if search.isPresented { ChatSearchBar(search: search).padding(8) }
                               }) { attached in
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Array(items[attached])) { item in
                    if case .message(let message) = item {
                        Group {
                            if message.role == .user {
                                MarkdownView(content: message.content, style: MarkdownStyle(fontSize: 14), plainText: true)
                                    .fixedSize(horizontal: message.content.count <= 72 && !message.content.contains(where: \.isNewline), vertical: false)
                            } else {
                                MarkdownRenderer(content: message.content, fontSize: 14)
                            }
                        }
                        .environment(\.chatSearchHighlight, search.highlight(for: message.id))
                        .id(item.id)
                    }
                }
                Color.clear.frame(height: 100).id(ChatTranscriptScrollTarget.bottom)
            }
            .padding(20)
        }
    }
}
