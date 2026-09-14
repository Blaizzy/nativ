import AppKit
import SwiftUI
import NativServerKit
import XCTest

@MainActor
final class ChatMarkdownRendererTests: XCTestCase {
    func testParagraphDoesNotPaintASeparateDocumentCanvas() throws {
        let layout = MarkdownLayouter.layout("Plain **text**", width: 560, style: .init())
        XCTAssertTrue(layout.decorations.isEmpty)
        let block = try XCTUnwrap(layout.blocks.first)
        XCTAssertTrue(block.decorations.isEmpty)
        let fragment = try XCTUnwrap(block.text.first)
        XCTAssertNil(fragment.text.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertFalse(MarkdownSelectableTextView(fragment: fragment).drawsBackground)
    }

    func testLongMarkdownUsesItsCompleteIntrinsicHeight() {
        let section = """
            ## Efficient streaming

            This paragraph contains **bold text**, `inline code`, and a [link](https://example.com).

            - First item with enough text to wrap naturally across the available width.
            - Second item with more content and an inline expression $x^2 + y^2$.

            ```swift
            struct Message: Identifiable {
                let id: UUID
                let content: String
            }
            ```

            """
        let markdown = Array(repeating: section, count: 80).joined(separator: "\n")
        XCTAssertGreaterThan(renderedHeight(content: markdown, fontScale: 1, width: 560), 8_000)
        XCTAssertGreaterThan(markdown.count, 25_000)
    }

    func testStreamingAndCompletedChatMountNativeTextViewsByDefault() throws {
        let content = "# Streaming\n\nContent grows with $\\frac{a}{b}$."
        for isStreaming in [true, false] {
            let host = NSHostingView(
                rootView: ChatMarkdownRenderer(
                    messageID: UUID(), content: content, isStreaming: isStreaming, fontScale: 1
                ).frame(width: 560).fixedSize(horizontal: false, vertical: true))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 560, height: 400), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let surface = try XCTUnwrap(
                descendants(of: host).compactMap { $0 as? MarkdownSurface }.first)
            surface.layoutSubtreeIfNeeded()
            surface.refreshVisibleBlocks()
            let texts = descendants(of: surface).compactMap {
                $0 as? MarkdownSelectableTextView
            }
            XCTAssertFalse(texts.isEmpty)
            XCTAssertTrue(texts.allSatisfy { $0.textLayoutManager != nil })
            XCTAssertGreaterThan(try XCTUnwrap(surface.snapshot).size.height, 40)
        }
    }

    func testFontScaleChangesMarkdownHeight() {
        let content = Array(
            repeating: "Font scaling should resize rendered Markdown along with the rest of Chat.",
            count: 12
        ).joined(separator: " ")
        XCTAssertGreaterThan(
            renderedHeight(content: content, fontScale: 1.5),
            renderedHeight(content: content, fontScale: 0.85))
    }

    func testFontScaleChangesHighlightedCodeHeight() {
        let lines = Array(repeating: "let renderedMessage = ChatMarkdownRenderer()", count: 12)
            .joined(separator: "\n")
        let content = "```swift\n\(lines)\n```"
        XCTAssertGreaterThan(
            renderedHeight(content: content, fontScale: 1.5),
            renderedHeight(content: content, fontScale: 0.85))
    }

    func testDocumentRendererWrapsTableCellsToFitAvailableWidth() {
        let content = """
            | Model | Context | Quantization | Architecture | Notes |
            | --- | ---: | --- | --- | --- |
            | Example | 131072 | 4-bit | Mixture of experts | A deliberately long table value that should wrap when the table is narrow |
            """
        func height(_ width: CGFloat) -> CGFloat {
            NSHostingView(
                rootView:
                    VStack(alignment: .leading, spacing: 0) {
                        MarkdownRenderer(
                            content: content, fontSize: 15, imagePolicy: .document)
                    }.frame(width: width).fixedSize(horizontal: false, vertical: true)
            ).fittingSize.height
        }
        XCTAssertGreaterThan(height(260), height(900))
    }

    func testChatImagesRemainTextLinksWithoutDocumentResources() throws {
        let source = "![**A model** diagram](https://example.com/image.png)"
        let layout = MarkdownLayouter.layout(source, width: 400, style: .init())
        let text = try XCTUnwrap(layout.blocks.first?.text.first?.text)
        XCTAssertEqual(text.string, "A model diagram")
        XCTAssertNil(text.attribute(.attachment, at: 0, effectiveRange: nil))
        XCTAssertEqual(
            text.attribute(.link, at: 0, effectiveRange: nil) as? URL,
            URL(string: "https://example.com/image.png"))
    }

    func testChatTablesFitViewportByDefaultAcrossWidthsAndFontSizes() throws {
        let source = """
            ## Summary Timeline

            | Period | Ruler | Title | Notes |
            | --- | --- | --- | --- |
            | 1792–1793 | **Louis XVI** | Last King | Executed by guillotine |
            | 1795–1799 | **The Directory** | Executive body | Five-member government |
            | 1799–1804 | **Napoleon Bonaparte** | First Consul | Became Emperor in 1804 |
            | 1804–1814 | **Napoleon I** | Emperor | Defeated at Waterloo (1815) |
            | 1814–1824 | **Louis XVIII** | King | Bourbon Restoration |
            | 1824–1830 | **Charles X** | King | Deposed in July Revolution |
            | 1830–1848 | **Louis-Philippe I** | King | "King of the French" |
            | 1848–1852 | **Louis-Napoleon Bonaparte** | President → Emperor | Napoleon III |
            | 1852–1870 | **Napoleon III** | Emperor | Defeated in 1870 |
            | 1870–1940 | **Third Republic** | Various Presidents | Thiers, MacMahon, Loubet, Doumer, etc. |
            | 1958–Present | **Fifth Republic** | Various Presidents | De Gaulle, Mitterrand, Chirac, Sarkozy, Hollande, Macron |
            """
        var heights: [CGFloat: CGFloat] = [:]
        for width: CGFloat in [260, 616, 900] {
            for scale in [1.0, 1.5] {
                let host = NSHostingView(
                    rootView:
                        ChatMarkdownRenderer(
                            messageID: UUID(), content: source, isStreaming: false, fontScale: scale
                        )
                        .environment(\.colorScheme, .light)
                        .frame(width: width).fixedSize(horizontal: false, vertical: true)
                        .background(Color.white)
                )
                let window = NSWindow(
                    contentRect: CGRect(x: 0, y: 0, width: width, height: host.fittingSize.height),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let surface = try XCTUnwrap(
                    descendants(of: host).compactMap { $0 as? MarkdownSurface }.first)
                surface.layoutSubtreeIfNeeded()
                surface.refreshVisibleBlocks()
                let layout = try XCTUnwrap(surface.snapshot)
                let table = try XCTUnwrap(layout.blocks.first { $0.text.count == 48 })
                XCTAssertFalse(table.scrollsHorizontally)
                XCTAssertLessThanOrEqual(table.contentSize.width, width + 0.5)
                XCTAssertLessThanOrEqual(table.frame.maxX, width + 0.5)
                for fragment in table.text {
                    XCTAssertGreaterThanOrEqual(fragment.frame.minX, 0)
                    XCTAssertLessThanOrEqual(fragment.frame.maxX, table.contentSize.width + 0.5)
                }
                if scale == 1 { heights[width] = table.frame.height }

            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(heights[260]), try XCTUnwrap(heights[900]))
    }

    private func renderedHeight(content: String, fontScale: Double, width: CGFloat = 260) -> CGFloat
    {
        NSHostingView(
            rootView:
                ChatMarkdownRenderer(
                    messageID: UUID(), content: content, isStreaming: false, fontScale: fontScale
                )
                .frame(width: width).fixedSize(horizontal: false, vertical: true)
        ).fittingSize.height
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

final class ChatStreamingRenderPolicyTests: XCTestCase {
    func testStreamingUsesSmoothTwentyHertzCadence() {
        XCTAssertEqual(ChatStreamingRenderPolicy.updatesPerSecond, 20)
        XCTAssertEqual(ChatStreamingRenderPolicy.flushInterval, .seconds(1.0 / 20.0))
    }
}

@MainActor
final class ChatPastedTextTests: XCTestCase {
    private let markdown = "  # Raw **Markdown**\r\n\t`code` 🌙 e\u{301}\n\n"

    func testOnlyLargePastesQualify() {
        XCTAssertFalse(ChatPastedText.shouldCollapse(String(repeating: "a", count: 1_999)))
        XCTAssertTrue(ChatPastedText.shouldCollapse(String(repeating: "a", count: 2_000)))
    }

    func testMultiplePastesRemainInOriginalMessageOrderWithoutEditorTokens() {
        var draft = ChatPastedTextDraft(text: "Before 🌙betweenafter", pastedTexts: [])
        draft = draft.replacingText(in: NSRange(location: "Before 🌙".utf16.count, length: 0), with: markdown, asAttachment: true)
        draft = draft.replacingText(in: NSRange(location: "Before 🌙between".utf16.count, length: 0), with: markdown, asAttachment: true)
        XCTAssertEqual(draft.editableText, "Before 🌙betweenafter")
        XCTAssertEqual(Array(draft.text.utf8), Array(("Before 🌙" + markdown + "between" + markdown + "after").utf8))
        XCTAssertEqual(draft.pastedTexts.count, 2)
        XCTAssertFalse(draft.editableText.contains("\u{fffc}"))
    }

    func testEditingAcrossAttachmentsKeepsTheirContentAndExplicitRemovalDeletesOnlyOne() {
        var draft = ChatPastedTextDraft(text: "before middle after", pastedTexts: [])
        draft = draft.replacingText(in: NSRange(location: 7, length: 0), with: markdown, asAttachment: true)
        draft = draft.replacingText(in: NSRange(location: 14, length: 0), with: markdown, asAttachment: true)
        let removedID = draft.pastedTexts[0].id
        draft = draft.replacingText(in: NSRange(location: 0, length: draft.editableText.utf16.count), with: "")
        XCTAssertEqual(draft.editableText, "")
        XCTAssertEqual(draft.text, markdown + markdown)
        draft = draft.removingAttachment(removedID)
        XCTAssertEqual(draft.text, markdown)
        XCTAssertEqual(draft.pastedTexts.count, 1)
        XCTAssertEqual(draft.pastedTexts[0].location, 0)
    }

    func testExistingSendTrimmingPreservesOriginalForPreviewAndEditedRequest() throws {
        let item = ChatPastedText(location: 0, length: markdown.utf16.count, text: markdown)
        let prompt = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = ChatPastedText.afterTrimming([item], draft: markdown)
        let saved = try XCTUnwrap(items.first)
        XCTAssertEqual(saved.range, NSRange(location: 0, length: prompt.utf16.count))
        XCTAssertEqual(Array(saved.text.utf8), Array(markdown.utf8))
        let edited = ChatPastedTextDraft(text: prompt, pastedTexts: items)
        XCTAssertEqual(edited.editableText, "")
        XCTAssertEqual(Array(edited.text.utf8), Array(prompt.utf8))
        XCTAssertEqual(edited.pastedTexts, items)
    }

    func testPresentationMetadataDoesNotChangeAPIBytesIncludingExistingContext() throws {
        let prompt = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        var original = ChatTranscriptMessage(role: .user, content: prompt)
        let source = ChatTranscriptMessage(role: .assistant, content: "Reference")
        original.annotations = [try XCTUnwrap(ChatAnnotation.capture(
            message: source, range: NSRange(location: 0, length: 9)))]
        original.imageAttachments = [ChatImageAttachment(filename: "existing.png", mimeType: "image/png",
                                                         base64Data: Data([0, 1, 2]).base64EncodedString())]
        var collapsed = original
        collapsed.pastedTexts = ChatPastedText.afterTrimming(
            [ChatPastedText(location: 0, length: markdown.utf16.count, text: markdown)], draft: markdown)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for context in [nil, "Existing document context"] as [String?] {
            for includesImages in [true, false] {
                let originalMessage = try XCTUnwrap(original.apiMessage(documentContext: context, includesImages: includesImages))
                let collapsedMessage = try XCTUnwrap(collapsed.apiMessage(documentContext: context, includesImages: includesImages))
                func request(_ message: MLXChatMessage) -> MLXChatCompletionRequest {
                    MLXChatCompletionRequest(model: "test/model", messages: [
                        MLXChatMessage(role: "system", content: "Existing system prefix"), message
                    ], maxTokens: 512, temperature: 0.7, topK: 0, topP: 0.95, minP: 0)
                }
                XCTAssertEqual(
                    try encoder.encode(request(originalMessage)),
                    try encoder.encode(request(collapsedMessage))
                )
            }
        }
        let restored = try JSONDecoder().decode(ChatTranscriptMessage.self, from: encoder.encode(collapsed))
        XCTAssertEqual(restored.pastedTexts, collapsed.pastedTexts)
        XCTAssertEqual(try encoder.encode(restored.apiMessage), try encoder.encode(original.apiMessage))
    }

    func testOldSessionsAndInvalidRangesRemainVisibleAsOrdinaryText() throws {
        let old = try JSONDecoder().decode(ChatTranscriptMessage.self, from: Data(#"{"role":"user","content":"hello"}"#.utf8))
        XCTAssertTrue(old.pastedTexts.isEmpty)
        let items = [
            ChatPastedText(location: -1, length: 3, text: "bad"),
            ChatPastedText(location: Int.max, length: Int.max, text: "bad"),
            ChatPastedText(location: 0, length: 5, text: "other")
        ]
        let draft = ChatPastedTextDraft(text: "hello", pastedTexts: items)
        XCTAssertEqual(draft.editableText, "hello")
    }

    func testRemoveButtonPreservesTypedTextAndSupportsUndo() {
        let model = ChatViewModel()
        let undo = UndoManager()
        model.draft = "before after"
        model.attachPastedText(markdown, replacing: NSRange(location: 7, length: 0), undoManager: nil)
        let original = model.draft
        undo.beginUndoGrouping()
        model.removePendingPastedText(model.pendingPastedTexts[0].id, undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(model.composerText, "before after")
        XCTAssertEqual(model.draft, "before after")
        undo.undo()
        XCTAssertEqual(model.draft, original)
        XCTAssertEqual(model.composerText, "before after")
    }

    func testReplacingDraftClearsPresentationMetadata() {
        let model = ChatViewModel()
        model.attachPastedText(markdown, replacing: NSRange(location: 0, length: 0), undoManager: nil)
        XCTAssertEqual(model.pendingPastedTexts.count, 1)
        model.draft = "Another draft"
        XCTAssertTrue(model.pendingPastedTexts.isEmpty)
        XCTAssertEqual(model.draft, "Another draft")
    }

    func testUndoRestoresAttachmentPositionAfterDeletingSurroundingText() {
        let model = ChatViewModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.draft = "before after"
        model.attachPastedText(markdown, replacing: NSRange(location: 7, length: 0), undoManager: nil)
        let original = model.draft
        undo.beginUndoGrouping()
        model.editComposerText(in: NSRange(location: 0, length: model.composerText.utf16.count),
                               replacement: "", undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(model.draft, markdown)
        XCTAssertEqual(model.composerText, "")
        undo.undo()
        XCTAssertEqual(model.draft, original)
        XCTAssertEqual(model.composerText, "before after")
        undo.redo()
        XCTAssertEqual(model.draft, markdown)
    }

    func testLargeAttachmentSurvivesOneHundredEditsUndoAndRedo() {
        let model = ChatViewModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let content = String(repeating: "x", count: 1_048_576)
        model.attachPastedText(content, replacing: NSRange(location: 0, length: 0), undoManager: nil)
        let attachmentID = model.pendingPastedTexts[0].id
        for index in 0..<100 {
            undo.beginUndoGrouping()
            model.editComposerText(in: NSRange(location: index, length: 0), replacement: "a", undoManager: undo)
            undo.endUndoGrouping()
        }
        let typed = String(repeating: "a", count: 100)
        XCTAssertEqual(model.composerText, typed)
        XCTAssertEqual(model.draft, content + typed)
        for _ in 0..<100 { undo.undo() }
        XCTAssertTrue(model.composerText.isEmpty)
        XCTAssertEqual(model.draft, content)
        for _ in 0..<100 { undo.redo() }
        XCTAssertEqual(model.composerText, typed)
        XCTAssertEqual(model.draft, content + typed)
        XCTAssertEqual(model.pendingPastedTexts[0].id, attachmentID)
        XCTAssertEqual(model.pendingPastedTexts[0].text, content)
    }

    func testRestoredTrimmedAttachmentKeepsItsRequestBytesAfterEditing() {
        let prompt = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = ChatPastedText.afterTrimming(
            [ChatPastedText(location: 0, length: markdown.utf16.count, text: markdown)], draft: markdown)
        let original = ChatPastedTextDraft(text: prompt, pastedTexts: items)
        let edited = original.replacingText(in: NSRange(location: 0, length: 0), with: "你好")
        XCTAssertEqual(edited.editableText, "你好")
        XCTAssertEqual(Array(edited.text.utf8), Array((prompt + "你好").utf8))
        XCTAssertEqual(edited.pastedTexts, items)
        XCTAssertEqual(Array(edited.pastedTexts[0].text.utf8), Array(markdown.utf8))
        XCTAssertEqual(original.text, prompt)
        let restored = ChatPastedTextDraft(text: edited.text, pastedTexts: edited.pastedTexts)
        XCTAssertEqual(restored, edited)
        XCTAssertEqual(restored.removingAttachment(items[0].id).text, "你好")
    }

    func testMultipleAttachmentsAtSamePositionKeepTheirOrderAfterEditing() {
        var draft = ChatPastedTextDraft(text: "before after", pastedTexts: [])
        draft = draft.replacingText(in: NSRange(location: 7, length: 0), with: "first", asAttachment: true)
        draft = draft.replacingText(in: NSRange(location: 7, length: 0), with: "second", asAttachment: true)
        let original = draft
        draft = draft.replacingText(in: NSRange(location: 0, length: 7), with: "🌙")
        XCTAssertEqual(draft.text, "🌙firstsecondafter")
        XCTAssertEqual(draft.editableText, "🌙after")
        XCTAssertEqual(draft.pastedTexts.map(\.location), [2, 7])
        XCTAssertEqual(original.text, "before firstsecondafter")
        draft = draft.removingAttachment(draft.pastedTexts[0].id)
        XCTAssertEqual(draft.text, "🌙secondafter")
        XCTAssertEqual(draft.pastedTexts[0].location, 2)
    }

    func testPastedTextContentControlsSendAvailability() {
        let model = ChatViewModel()
        model.attachPastedText(" \n\t", replacing: NSRange(location: 0, length: 0), undoManager: nil)
        XCTAssertFalse(model.canSend(isRunning: true, selectedModelID: "model"))
        model.attachPastedText("content", replacing: NSRange(location: 0, length: 0), undoManager: nil)
        XCTAssertTrue(model.canSend(isRunning: true, selectedModelID: "model"))
        model.removePendingPastedText(model.pendingPastedTexts[1].id, undoManager: nil)
        XCTAssertFalse(model.canSend(isRunning: true, selectedModelID: "model"))
        XCTAssertFalse(model.canRecallPreviousPrompt)
    }

    func testInputMethodCommitPreservesPastedTextAndUnicode() {
        let model = ChatViewModel()
        model.draft = "🌙 before after"
        let prefix = "🌙 before "
        model.attachPastedText(markdown, replacing: NSRange(location: prefix.utf16.count, length: 0),
                               undoManager: nil)
        model.commitComposerText("🌙 before 日本語 after", undoManager: nil)
        XCTAssertEqual(model.composerText, "🌙 before 日本語 after")
        XCTAssertEqual(Array(model.draft.utf8), Array((prefix + markdown + "日本語 after").utf8))
        XCTAssertEqual(model.pendingPastedTexts.first?.text, markdown)
    }
}
