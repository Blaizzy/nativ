import AppKit
import SwiftUI
import XCTest

final class MarkdownParserTests: XCTestCase {
    func testGFMStructureReferencesAndLiteralCode() throws {
        let nodes = MarkdownParser.parse(
            """
            7. Seven
            8. Eight

            - [x] Done
            - [ ] Next

            | Left | Right |
            | :--- | ---: |
            | a | b |

            [Reference][ref]

            ```swift
            let price = "$100"
            ```

            [ref]: https://example.com
            """)
        XCTAssertEqual(nodes[0].kind, "list")
        XCTAssertEqual(nodes[0].start, 7)
        XCTAssertTrue(nodes[0].ordered)
        XCTAssertEqual(nodes[1].children.map(\.checked), [true, false])
        XCTAssertEqual(nodes[2].alignments, [108, 114])
        XCTAssertEqual(nodes[3].children.first?.destination, "https://example.com")
        XCTAssertEqual(nodes[4].literal, "let price = \"$100\"\n")
    }

    func testLaterReferenceDefinitionReinterpretsEarlierParagraph() {
        let unfinished = MarkdownParser.parse("See [the source][ref].")
        let complete = MarkdownParser.parse(
            "See [the source][ref].\n\n[ref]: https://example.com")
        XCTAssertFalse(unfinished[0].children.contains { $0.kind == "link" })
        XCTAssertTrue(
            complete[0].children.contains {
                $0.kind == "link" && $0.destination == "https://example.com"
            })
    }
}

@MainActor
final class MarkdownGeometryTests: XCTestCase {
    func testMovingAncestorIntoViewportMountsTextWithoutScrolling() async throws {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        let document = MarkdownTestFlippedView(frame: CGRect(x: 0, y: 0, width: 700, height: 20_000))
        let row = MarkdownTestFlippedView(frame: CGRect(x: 0, y: 18_000, width: 700, height: 500))
        let surface = MarkdownSurface()
        surface.configure(content: MarkdownFixtures.sample, style: .init())
        surface.frame = CGRect(origin: .zero, size: surface.preflight(width: 700).size)
        row.frame.size = surface.frame.size
        row.addSubview(surface)
        document.addSubview(row)
        scroll.documentView = document
        window.contentView = scroll
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(100))
        scroll.layoutSubtreeIfNeeded()
        surface.refreshVisibleBlocks()
        XCTAssertFalse(surface.visibleRect.intersects(surface.bounds))
        XCTAssertTrue(surface.subviews.isEmpty)
        let originalOffset = scroll.contentView.bounds.origin

        // Evicting earlier rows can move an unchanged Markdown surface through its
        // SwiftUI wrapper while the clip view and the surface's own frame stay put.
        row.setFrameOrigin(.zero)
        try await Task.sleep(for: .milliseconds(100))
        let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        XCTAssertEqual(scroll.contentView.bounds.origin, originalOffset)
        XCTAssertTrue(surface.visibleRect.intersects(surface.bounds))
        XCTAssertFalse(surface.subviews.isEmpty, "Newly visible blocks must mount without a manual scroll")
    }

    func testSwiftUIBridgeUsesPreflightHeight() throws {
        let source = MathPreprocessor.preprocess(MarkdownFixtures.sample)
        let expected = MarkdownLayouter.layout(source, width: 560, style: .init())
        let host = NSHostingView(
            rootView: MarkdownView(content: source, style: .init())
                .frame(width: 560).fixedSize(horizontal: false, vertical: true))
        XCTAssertEqual(host.fittingSize.height, expected.size.height, accuracy: 1)
    }

    func testPreflightMatchesMountedTextKitAcrossWidthsAndFonts() {
        let source = MathPreprocessor.preprocess(MarkdownFixtures.sample)
        for width: CGFloat in [260, 616, 900] {
            for size: CGFloat in [13, 21] {
                let layout = MarkdownLayouter.layout(
                    source, width: width, style: .init(fontSize: size))
                XCTAssertGreaterThan(layout.size.height, 100)
                for block in layout.blocks {
                    XCTAssertLessThanOrEqual(block.frame.maxY, layout.size.height + 0.5)
                    for fragment in block.text where fragment.text.length > 0 {
                        let view = MarkdownSelectableTextView(fragment: fragment)
                        XCTAssertNotNil(view.textLayoutManager, "Must remain on TextKit 2")
                        let measured = view.system.measure()
                        XCTAssertEqual(
                            measured.height, fragment.frame.height, accuracy: 0.5,
                            "\(block.id)/\(fragment.id) at width \(width), font \(size)")
                        XCTAssertEqual(view.textContainerOrigin, .zero)
                    }
                }
            }
        }
    }

    func testWidthAndFontInvalidateGeometry() {
        let source = String(repeating: "Words that wrap at different widths. ", count: 30)
        let cache = MarkdownLayoutCache()
        let wide = cache.layout(source, width: 600, style: .init(fontSize: 15))
        let narrow = cache.layout(source, width: 260, style: .init(fontSize: 15))
        let larger = cache.layout(source, width: 260, style: .init(fontSize: 23))
        XCTAssertGreaterThan(narrow.size.height, wide.size.height)
        XCTAssertGreaterThan(larger.size.height, narrow.size.height)
        XCTAssertEqual(cache.layout(source, width: 600, style: .init(fontSize: 15)).size, wide.size)
    }

    func testTablesFitWrapAndKeepColumnAlignment() throws {
        let source = """
            | Name | Notes | Context |
            | --- | :---: | ---: |
            | Example model | This deliberately long value wraps in a narrow table | 131072 |
            """
        let fitted = MarkdownLayouter.layout(
            source, width: 260, style: .init())
        let wide = MarkdownLayouter.layout(
            source, width: 900, style: .init())
        let table = try XCTUnwrap(fitted.blocks.first)
        XCTAssertLessThanOrEqual(table.contentSize.width, 260.5)
        XCTAssertGreaterThan(fitted.size.height, wide.size.height)
        XCTAssertFalse(table.scrollsHorizontally)
        XCTAssertEqual(table.text.count, 6)
        XCTAssertEqual(
            (table.text[1].text.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle)?.alignment, .center)
        XCTAssertEqual(
            (table.text[2].text.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle)?.alignment, .right)
    }

    func testMathHasMetricsAndCopyAlternativeBeforeMounting() throws {
        let source = MathPreprocessor.preprocess(#"Inline $\frac{a+b}{c}$ and text."#)
        let layout = MarkdownLayouter.layout(source, width: 400, style: .init())
        let text = try XCTUnwrap(layout.blocks.first?.text.first?.text)
        var attachments = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) {
            value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            attachments += 1
            XCTAssertGreaterThan(attachment.bounds.width, 0)
            XCTAssertGreaterThan(attachment.bounds.height, 15)
        }
        XCTAssertEqual(attachments, 1)
        XCTAssertTrue(MarkdownSelectableTextView.plainText(text).contains(#"\frac{a+b}{c}"#))
        XCTAssertFalse(MarkdownSelectableTextView.plainText(text).contains("\u{FFFC}"))
    }

    func testLongMessageIsNotHeightCapped() {
        let source = MathPreprocessor.preprocess(
            Array(repeating: MarkdownFixtures.sample, count: 30).joined(separator: "\n\n"))
        XCTAssertGreaterThan(source.count, 25_000)
        let result = MarkdownLayouter.layout(source, width: 560, style: .init())
        XCTAssertGreaterThan(result.size.height, 8_000)
        XCTAssertLessThanOrEqual(result.blocks.map(\.frame.maxY).max() ?? 0, result.size.height)
    }

    func testLongDocumentMountsTextViewsNearViewportAndReleasesOffscreenViews() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        let surface = MarkdownSurface()
        scroll.documentView = surface
        window.contentView = scroll
        surface.configure(
            content: MathPreprocessor.preprocess(
                String(repeating: MarkdownFixtures.sample + "\n\n", count: 60)),
            style: .init())
        let layout = surface.preflight(width: scroll.contentSize.width)
        surface.frame = CGRect(origin: .zero, size: layout.size)
        scroll.layoutSubtreeIfNeeded()
        surface.layoutSubtreeIfNeeded()
        surface.refreshVisibleBlocks()

        func mountedTextViews(in view: NSView) -> [MarkdownSelectableTextView] {
            (view as? MarkdownSelectableTextView).map { [$0] }
                ?? view.subviews.flatMap { mountedTextViews(in: $0) }
        }
        let totalTextFragments = layout.blocks.reduce(0) { $0 + $1.text.count }
        XCTAssertGreaterThan(totalTextFragments, 500)
        let initialViews = mountedTextViews(in: surface)
        XCTAssertFalse(initialViews.isEmpty)
        XCTAssertLessThan(initialViews.count, totalTextFragments / 4)

        scroll.contentView.scroll(to: CGPoint(x: 0, y: layout.size.height / 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        surface.refreshVisibleBlocks()
        let laterViews = mountedTextViews(in: surface)
        XCTAssertFalse(laterViews.isEmpty)
        XCTAssertLessThan(laterViews.count, totalTextFragments / 4)
        XCTAssertTrue(
            initialViews.allSatisfy { $0.window == nil }, "Offscreen text views must be detached")
    }
}

@MainActor
private final class MarkdownTestFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class MarkdownDocumentImageTests: XCTestCase {
    func testRelativeReferencesExcludeCodeAndMath() throws {
        let request = MarkdownImageRequest(
            markdown:
                "![first](assets/diagram.png) [![badge](badge.svg)](details.md) `![literal](code.png)`\n\n![math](swiftmath://i/YQ)",
            baseURL: URL(string: "https://example.com/models/example/")
        )
        XCTAssertEqual(
            Set(request.urls.map(\.absoluteString)),
            [
                "https://example.com/models/example/assets/diagram.png",
                "https://example.com/models/example/badge.svg",
            ])
    }

    func testRemoteImagesLoadAndFailedImagesKeepTheirLinks() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MarkdownImageTestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = MarkdownImageRequest(
            markdown: "[![Badge](badge.svg)](details.md) ![Missing](missing.png)",
            baseURL: URL(string: "https://markdown.test/model/")
        )
        let images = await MarkdownImages.load(
            request, loader: MarkdownImageLoader(session: session))
        XCTAssertEqual(images.values.count, 1)
        let layout = MarkdownLayouter.layout(
            request.markdown, width: 360, style: .init(baseURL: request.baseURL, images: images))
        let text = try XCTUnwrap(layout.blocks.first?.text.first?.text)
        XCTAssertNotNil(text.attribute(.attachment, at: 0, effectiveRange: nil))
        XCTAssertEqual(
            text.attribute(.link, at: 0, effectiveRange: nil) as? URL,
            URL(string: "https://markdown.test/model/details.md"))
        XCTAssertEqual(MarkdownSelectableTextView.plainText(text), "Badge Missing")
        XCTAssertEqual(
            text.attribute(.link, at: text.length - 1, effectiveRange: nil) as? URL,
            URL(string: "https://markdown.test/model/missing.png"))
    }

    func testLocalImageGeometryInvalidatesCachedLayoutAndFitsTables() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try diagramPNG().write(to: directory.appendingPathComponent("diagram.png"))
        let source =
            "![A diagram](diagram.png)\n\n| Figure | Notes |\n| --- | --- |\n| ![Table diagram](diagram.png) | The image must fit this cell |"
        let request = MarkdownImageRequest(markdown: source, baseURL: directory)
        let images = await MarkdownImages.load(request)
        XCTAssertEqual(images.values.count, 1)
        let cache = MarkdownLayoutCache()
        let pending = cache.layout(
            source, width: 260, style: .init(baseURL: directory))
        let loaded = cache.layout(
            source, width: 260,
            style: .init(baseURL: directory, images: images))
        XCTAssertGreaterThan(loaded.size.height, pending.size.height)
        var imageCount = 0
        for block in loaded.blocks {
            for fragment in block.text {
                fragment.text.enumerateAttribute(
                    .attachment, in: NSRange(location: 0, length: fragment.text.length)
                ) { value, _, _ in
                    guard let attachment = value as? NSTextAttachment else { return }
                    imageCount += 1
                    XCTAssertLessThanOrEqual(attachment.bounds.width, fragment.frame.width + 0.5)
                    XCTAssertEqual(
                        attachment.bounds.height, attachment.bounds.width / 2, accuracy: 0.5)
                }
                let view = MarkdownSelectableTextView(fragment: fragment)
                XCTAssertEqual(view.system.measure().height, fragment.frame.height, accuracy: 0.5)
            }
        }
        XCTAssertEqual(imageCount, 2)
    }

    func testDocumentImageCompletionUpdatesNativeSwiftUIHeight() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try diagramPNG().write(to: directory.appendingPathComponent("diagram.png"))
        let source = "# Model card\n\n![A diagram](diagram.png)\n\nA description after the image."
        let root = MarkdownRenderer(
            content: source, baseURL: directory, fontSize: 15, imagePolicy: .document
        )
        .frame(width: 360).fixedSize(horizontal: false, vertical: true)
        let host = NSHostingView(rootView: root)
        let initialHeight = host.fittingSize.height
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 500), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        for _ in 0 ..< 100 {
            host.layoutSubtreeIfNeeded()
            if host.fittingSize.height > initialHeight + 50 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(host.fittingSize.height, initialHeight + 50)
    }

    private func diagramPNG() throws -> Data {
        let image = NSImage(size: CGSize(width: 640, height: 320), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            NSColor.white.setFill()
            CGRect(x: 40, y: 80, width: 160, height: 160).fill()
            CGRect(x: 440, y: 80, width: 160, height: 160).fill()
            CGRect(x: 200, y: 150, width: 240, height: 20).fill()
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(
            NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    }
}

private final class MarkdownImageTestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let svg =
            #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="20"><rect width="100" height="20" fill="blue"/></svg>"#
        let found = url.lastPathComponent == "badge.svg"
        let response = HTTPURLResponse(
            url: url, statusCode: found ? 200 : 404, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/svg+xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(svg.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
