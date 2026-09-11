import AppKit
import SwiftUI
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
