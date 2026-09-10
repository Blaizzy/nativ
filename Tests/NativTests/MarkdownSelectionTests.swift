import AppKit
import XCTest

@MainActor
final class MarkdownSelectionTests: XCTestCase {
    func testDragAcrossHeadingParagraphAndCodeCopiesOnePassage() throws {
        let (window, _, surface) = fixture("# A heading\n\nA **bold** paragraph.\n\n```swift\nlet answer = 42\n```", height: 500)
        defer { window.close() }
        let views = surface.visibleTextViews.sorted { $0.convert($0.bounds, to: surface).minY < $1.convert($1.bounds, to: surface).minY }
        let first = try XCTUnwrap(views.first)
        let last = try XCTUnwrap(views.last)
        try drag(from: first, offset: 0, to: last, offset: last.string.utf16.count, window: window)
        XCTAssertTrue(window.firstResponder === surface)
        XCTAssertEqual(surface.selection.text, "A heading\n\nA bold paragraph.\n\nlet answer = 42")
        XCTAssertEqual(views.filter { $0.documentSelection != nil }.count, 3)
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        surface.selection.copy(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), surface.selection.text)
        pasteboard.releaseGlobally()

        let selection = try XCTUnwrap(ChatTextSelectionReader.selection(in: window))
        XCTAssertEqual(selection.text, surface.selection.text)
        let source = "# A heading\n\nA **bold** paragraph.\n\n```swift\nlet answer = 42\n```"
        let sourceRange = try XCTUnwrap(ChatAnnotation.selectionRange(
            text: selection.text, in: source, elementText: nil, elementRange: selection.range,
            renderedMarkdown: true, markdownFragments: selection.markdownFragments))
        let annotation = try XCTUnwrap(ChatAnnotation.capture(
            message: ChatTranscriptMessage(role: .assistant, content: source),
            range: sourceRange, displayedText: selection.text))
        XCTAssertEqual(annotation.quote, selection.text)
    }

    func testReverseDragAndShiftClickExtendExistingSelection() throws {
        let (window, _, surface) = fixture("First paragraph\n\nSecond paragraph\n\nThird paragraph", height: 400)
        defer { window.close() }
        let views = surface.visibleTextViews.sorted { $0.convert($0.bounds, to: surface).minY < $1.convert($1.bounds, to: surface).minY }
        try drag(from: views[1], offset: 6, to: views[0], offset: 6, window: window)
        XCTAssertEqual(surface.selection.text, "paragraph\n\nSecond")
        try drag(from: views[2], offset: 5, to: views[2], offset: 5, window: window, flags: .shift)
        XCTAssertEqual(surface.selection.text, " paragraph\n\nThird")
    }

    func testKeyboardSelectionUsesComposedCharactersAndCrossesBlocks() throws {
        let (window, _, surface) = fixture("🌙 hello\n\nSecond", height: 300)
        defer { window.close() }
        surface.selection.select(anchor: 0, head: 0)
        XCTAssertTrue(surface.selection.command(NSSelectorFromString("moveRightAndModifySelection:")))
        XCTAssertEqual(surface.selection.text, "🌙")
        XCTAssertTrue(surface.selection.command(NSSelectorFromString("moveToEndOfDocumentAndModifySelection:")))
        XCTAssertEqual(surface.selection.text, "🌙 hello\n\nSecond")
        XCTAssertTrue(surface.selection.command(NSSelectorFromString("moveLeft:")))
        XCTAssertEqual(surface.selection.range.length, 0)
        XCTAssertTrue(surface.selection.command(NSSelectorFromString("selectAll:")))
        XCTAssertEqual(surface.selection.text, "🌙 hello\n\nSecond")
    }

    func testSelectionSurvivesScrollingWithoutRetainingOffscreenTextViews() throws {
        let source = (0..<500).map { "Paragraph \($0) with selectable text." }.joined(separator: "\n\n")
        let (window, scroll, surface) = fixture(source, height: 300)
        defer { window.close() }
        let initialViews = surface.visibleTextViews
        let originalSize = surface.snapshot?.size
        let originalStrings = surface.snapshot?.blocks.map { $0.text.first!.text }
        _ = surface.selection.command(NSSelectorFromString("selectAll:"))
        XCTAssertEqual(surface.selection.text, source)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: surface.bounds.height / 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        surface.refreshVisibleBlocks()
        XCTAssertTrue(initialViews.allSatisfy { $0.window == nil })
        XCTAssertLessThan(surface.visibleTextViews.count, 40)
        XCTAssertTrue(surface.visibleTextViews.allSatisfy { $0.documentSelection != nil })
        XCTAssertEqual(surface.selection.text, source)
        XCTAssertEqual(surface.snapshot?.size, originalSize)
        for (before, after) in zip(originalStrings ?? [], surface.snapshot?.blocks.map { $0.text.first!.text } ?? []) {
            XCTAssertTrue(before === after, "Selection must not rebuild layout or attributed strings")
        }
    }

    func testListsAndTablesCopyInReadingOrder() throws {
        let source = "- First\n- Second\n\n| Name | Value |\n| --- | --- |\n| Alpha | Beta |"
        let (window, _, surface) = fixture(source, height: 500)
        defer { window.close() }
        _ = surface.selection.command(NSSelectorFromString("selectAll:"))
        XCTAssertEqual(surface.selection.text, "• First\n\n• Second\n\nName\tValue\nAlpha\tBeta")
        XCTAssertNotNil(ChatAnnotation.selectionRange(
            text: surface.selection.text, in: source, elementText: nil,
            elementRange: NSRange(location: NSNotFound, length: 0), renderedMarkdown: true,
            markdownFragments: surface.selection.selectedFragments))
    }

    func testDraggingPastViewportAutoscrollsWithoutMountingTheDocument() throws {
        let source = (0..<500).map { "Paragraph \($0) with selectable text." }.joined(separator: "\n\n")
        let (window, scroll, surface) = fixture(source, height: 150)
        defer { window.close() }
        let first = try XCTUnwrap(surface.visibleTextViews.first(where: { $0.string.hasPrefix("Paragraph 0 ") }))
        let start = first.convert(CGPoint(x: 0, y: 8), to: nil)
        let end = surface.convert(CGPoint(x: 80, y: surface.visibleRect.maxY + 40), to: nil)
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseDragged, at: end), atStart: false)
        NSApp.postEvent(try event(.leftMouseUp, at: end), atStart: false)
        first.mouseDown(with: try event(.leftMouseDown, at: start))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        XCTAssertGreaterThan(surface.selection.range.length, 50)
        XCTAssertLessThan(surface.visibleTextViews.count, 40)
    }

    func testAccessibilitySelectionReadsAndUpdatesTheDocumentRange() throws {
        let (window, _, surface) = fixture("First\n\nSecond", height: 300)
        defer { window.close() }
        _ = surface.selection.command(NSSelectorFromString("selectAll:"))
        let view = try XCTUnwrap(surface.visibleTextViews.first(where: { $0.string == "Second" }))
        XCTAssertEqual(view.accessibilitySelectedText(), "Second")
        view.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 3))
        XCTAssertEqual(surface.selection.text, "Sec")
        XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: 0, length: 3))
    }

    func testRepeatedEscapedPassagesMapToTheSelectedOccurrence() throws {
        let source = "First **same &amp; text**.\n\nSecond **same &amp; text**.\n\nLast paragraph."
        let (window, _, surface) = fixture(source, height: 400)
        defer { window.close() }
        _ = surface.selection.command(NSSelectorFromString("selectAll:"))
        let second = surface.selection.fragments[1]
        surface.selection.select(anchor: second.range.location + 7, head: surface.selection.length)
        let range = try XCTUnwrap(ChatAnnotation.selectionRange(
            text: surface.selection.text, in: source, elementText: nil,
            elementRange: NSRange(location: NSNotFound, length: 0), renderedMarkdown: true,
            markdownFragments: surface.selection.selectedFragments))
        XCTAssertEqual((source as NSString).substring(with: range), "same &amp; text**.\n\nLast paragraph.")
    }

    func testContentChangeClearsSelectionAndResizePreservesIt() {
        let (window, _, surface) = fixture("First\n\nSecond", height: 300)
        defer { window.close() }
        _ = surface.selection.command(NSSelectorFromString("selectAll:"))
        _ = surface.preflight(width: 450)
        surface.refreshVisibleBlocks()
        XCTAssertEqual(surface.selection.text, "First\n\nSecond")
        surface.configure(content: "Replacement", style: .init())
        _ = surface.preflight(width: 450)
        surface.refreshVisibleBlocks()
        XCTAssertEqual(surface.selection.range.length, 0)
        XCTAssertTrue(surface.visibleTextViews.allSatisfy { $0.documentSelection == nil })
    }

    func testUnselectedMathDoesNotBlockQuotingLaterSections() throws {
        let source = "Before $x$.\n\n**Second** paragraph.\n\n**Third** paragraph."
        let (window, _, surface) = fixture(source, height: 400)
        defer { window.close() }
        _ = surface.selection.command(NSSelectorFromString("selectAll:"))
        let second = try XCTUnwrap(surface.selection.fragments.first(where: { $0.text.string == "Second paragraph." }))
        surface.selection.select(anchor: second.range.location, head: surface.selection.length)
        let range = try XCTUnwrap(ChatAnnotation.selectionRange(
            text: surface.selection.text, in: source, elementText: nil,
            elementRange: NSRange(location: NSNotFound, length: 0), renderedMarkdown: true,
            markdownFragments: surface.selection.selectedFragments))
        XCTAssertEqual((source as NSString).substring(with: range), "Second** paragraph.\n\n**Third** paragraph.")
    }

    func testSelectedRendererProducesPreview() throws {
        let source = """
        # Selection across sections

        Drag from this paragraph into the sections below. **Formatting stays intact.**

        ## One continuous selection

        - Paragraphs, headings, and list items
        - Code and table cells

        ```swift
        let selection = response.selectedText
        copy(selection)
        ```

        The renderer still creates text views only near the viewport.
        """
        let (window, scroll, surface) = fixture(source, width: 680, height: 700)
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        _ = surface.selection.command(NSSelectorFromString("selectAll:"))
        let paragraph = try XCTUnwrap(surface.selection.fragments.first(where: { $0.text.string.hasPrefix("Drag from") }))
        let code = try XCTUnwrap(surface.selection.fragments.first(where: { $0.text.string.hasPrefix("let selection") }))
        surface.selection.select(anchor: paragraph.range.location + 5, head: NSMaxRange(code.range))
        let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        XCTAssertGreaterThan(surface.visibleTextViews.filter { $0.documentSelection != nil }.count, 4)
        if let path = ProcessInfo.processInfo.environment["NATIV_SELECTION_PREVIEW"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    func testKeyboardEndRevealsCaretInLongCodeBlock() throws {
        let source = "```text\n" + (0..<200).map { "Line \($0)" }.joined(separator: "\n") + "\n```"
        let (window, scroll, surface) = fixture(source, height: 150)
        defer { window.close() }
        surface.selection.select(anchor: 0, head: 0)
        XCTAssertTrue(surface.selection.command(NSSelectorFromString("moveToEndOfDocumentAndModifySelection:")))
        XCTAssertEqual(surface.selection.head, surface.selection.length)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "Keyboard selection should reveal the caret at the bottom")
        let view = try XCTUnwrap(surface.visibleTextViews.first)
        let caret = try XCTUnwrap(view.selectionRects(for: NSRange(location: view.string.utf16.count, length: 0)).first)
        XCTAssertTrue(view.convert(caret, to: surface).intersects(surface.visibleRect))
    }

    func testRepeatedTextAfterRenderedMathMapsToLaterOccurrence() throws {
        let source = "Repeat $x$.\n\nRepeat"
        let (window, _, surface) = fixture(MathPreprocessor.preprocess(source), height: 300)
        defer { window.close() }
        _ = surface.selection.command(NSSelectorFromString("selectAll:"))
        let last = try XCTUnwrap(surface.selection.fragments.last)
        surface.selection.select(anchor: last.range.location, head: NSMaxRange(last.range))
        let mapped = try XCTUnwrap(ChatAnnotation.selectionRange(
            text: surface.selection.text, in: source, elementText: nil,
            elementRange: NSRange(location: NSNotFound, length: 0), renderedMarkdown: true,
            markdownFragments: surface.selection.selectedFragments))
        XCTAssertEqual(mapped, (source as NSString).range(of: "Repeat", options: .backwards))
    }

    func testVisibleSelectionGeometryMatchesFullGeometryInLongBlocks() throws {
        let code = "```text\n" + (0..<5000).map { "Line \($0)" }.joined(separator: "\n") + "\n```"
        let wrapped = String(repeating: "🌙 hello مرحبا wrapped text. ", count: 500)
        for source in [code, wrapped] {
            let (window, _, surface) = fixture(source, height: 150)
            defer { window.close() }
            let view = try XCTUnwrap(surface.visibleTextViews.first)
            let selection = NSRange(location: 2, length: view.string.utf16.count - 4)
            // The reference must use actual layout rather than TextKit's estimated
            // offscreen line heights, which change when those lines become visible.
            view.system.manager.ensureLayout(for: view.system.storage.documentRange)
            let all = view.selectionRects(for: selection)
            XCTAssertGreaterThan(all.count, 100)
            for y in [CGFloat.zero, view.bounds.height / 2, view.bounds.height - 150] {
                let clip = CGRect(x: 0, y: y, width: view.bounds.width, height: 150)
                let clipped = view.selectionRects(for: selection, clippedTo: clip)
                XCTAssertEqual(clipped, all.filter { $0.intersects(clip) })
                XCTAssertFalse(clipped.isEmpty)
                XCTAssertLessThan(clipped.count, 40)
            }
            let clip = CGRect(x: 0, y: view.bounds.height / 2, width: view.bounds.width, height: 150)
            let start = Date.timeIntervalSinceReferenceDate
            for _ in 0..<5 { _ = view.selectionRects(for: selection, clippedTo: clip) }
            print("Visible selection geometry: \((Date.timeIntervalSinceReferenceDate - start) * 1000 / 5) ms")
        }
    }

    func testRepeatedTextBeforeRenderedMathUsesForwardAlignment() throws {
        let source = "Repeat\n\nRepeat $x$."
        let (window, _, surface) = fixture(MathPreprocessor.preprocess(source), height: 300)
        defer { window.close() }
        _ = surface.selection.command(NSSelectorFromString("selectAll:"))
        let first = try XCTUnwrap(surface.selection.fragments.first)
        surface.selection.select(anchor: first.range.location, head: NSMaxRange(first.range))
        XCTAssertEqual(ChatAnnotation.selectionRange(
            text: surface.selection.text, in: source, elementText: nil,
            elementRange: NSRange(location: NSNotFound, length: 0), renderedMarkdown: true,
            markdownFragments: surface.selection.selectedFragments), NSRange(location: 0, length: 6))
    }

    func testEquationsOnBothSidesPreserveRepeatedSourceRange() throws {
        let source = "Repeat $x$.\n\nRepeat\n\nRepeat $y$."
        let (window, _, surface) = fixture(MathPreprocessor.preprocess(source), height: 400)
        defer { window.close() }
        _ = surface.selection.command(NSSelectorFromString("selectAll:"))
        let middle = surface.selection.fragments[1]
        surface.selection.select(anchor: middle.range.location, head: NSMaxRange(middle.range))
        XCTAssertEqual(ChatAnnotation.selectionRange(
            text: surface.selection.text, in: source, elementText: nil,
            elementRange: NSRange(location: NSNotFound, length: 0), renderedMarkdown: true,
            markdownFragments: surface.selection.selectedFragments),
            NSRange(location: (source as NSString).range(of: "Repeat\n").location, length: 6))
    }

    func testDraggingThroughEquationListCreatesQuote() throws {
        let source = #"""
        Where:

        - $I(\lambda)$ is the scattered intensity at wavelength $\lambda$
        - $\lambda$ is the wavelength of the incident light
        - $\theta$ is the scattering angle
        - The factor $(1 + \cos^2\theta)$ accounts for angular dependence
        """#
        let (window, _, surface) = fixture(MathPreprocessor.preprocess(source), height: 500)
        defer { window.close() }
        let first = try XCTUnwrap(surface.visibleTextViews.first { $0.string == "Where:" })
        let last = try XCTUnwrap(surface.visibleTextViews.first { $0.string.contains("incident light") })
        let end = (last.string as NSString).range(of: "incident").location + "incident".utf16.count
        try drag(from: first, offset: 0, to: last, offset: end, window: window)
        let selection = try XCTUnwrap(ChatTextSelectionReader.selection(in: window))
        XCTAssertTrue(selection.text.contains(#"I(\lambda)"#))
        XCTAssertTrue(selection.text.hasSuffix("incident"))
        let range = try XCTUnwrap(ChatAnnotation.selectionRange(
            text: selection.text, in: source, elementText: selection.fullText, elementRange: selection.range,
            renderedMarkdown: true, markdownFragments: selection.markdownFragments))
        XCTAssertEqual(range, NSRange(location: 0, length: (source as NSString).range(of: "incident").location + 8))
        let annotation = try XCTUnwrap(ChatAnnotation.capture(
            message: ChatTranscriptMessage(role: .assistant, content: source), range: range, displayedText: selection.text))
        XCTAssertEqual(annotation.quote, selection.text)
    }

    func testMathNotationAndLiteralCodePreserveQuoteSourceRanges() throws {
        let expressions = [#"$\lambda$"#, #"\(I(\lambda)\)"#, #"\[1 + \cos^2\theta\]"#,
                           #"$$\frac{a}{b}$$"#, #"$x+y$"#, #"`$\lambda$`"#,
                           "$$a +\nb$$", #"\boxed{\frac{a}{b}}"#]
        for expression in expressions {
            let source = "🌙 Before.\n\n- \(expression) is the value.\n- Last item."
            let (window, _, surface) = fixture(MathPreprocessor.preprocess(source), height: 500)
            defer { window.close() }
            _ = surface.selection.command(NSSelectorFromString("selectAll:"))
            let selection = try XCTUnwrap(ChatTextSelectionReader.selection(in: window), expression)
            let range = try XCTUnwrap(ChatAnnotation.selectionRange(
                text: selection.text, in: source, elementText: nil, elementRange: selection.range,
                renderedMarkdown: true, markdownFragments: selection.markdownFragments), expression)
            XCTAssertEqual(range, NSRange(location: 0, length: source.utf16.count), expression)
        }
    }

    func testPartialItalicMathSelectionKeepsDistinctSourceOffsets() throws {
        let source = "Value $xyz$ ends."
        let (window, _, surface) = fixture(MathPreprocessor.preprocess(source), height: 200)
        defer { window.close() }
        let view = try XCTUnwrap(surface.visibleTextViews.first)
        surface.selection.select(in: view.fragmentID, range: (view.string as NSString).range(of: "𝑦"))
        let selection = try XCTUnwrap(ChatTextSelectionReader.selection(in: window))
        XCTAssertEqual(selection.text, "𝑦")
        XCTAssertEqual(ChatAnnotation.selectionRange(
            text: selection.text, in: source, elementText: nil, elementRange: selection.range,
            renderedMarkdown: true, markdownFragments: selection.markdownFragments),
            (source as NSString).range(of: "y"))
    }

    func testMathFencesAndOrdinaryCodeKeepTheirDifferentSemantics() throws {
        for block in ["```math\n\\frac{a}{b}\n```", "```swift\nlet value = \"$\\lambda$\"\n```"] {
            let source = "Before.\n\n\(block)\n\nAfter."
            let (window, _, surface) = fixture(MathPreprocessor.preprocess(source), height: 400)
            defer { window.close() }
            _ = surface.selection.command(NSSelectorFromString("selectAll:"))
            XCTAssertEqual(ChatAnnotation.selectionRange(
                text: surface.selection.text, in: source, elementText: nil,
                elementRange: NSRange(location: NSNotFound, length: 0), renderedMarkdown: true,
                markdownFragments: surface.selection.selectedFragments),
                NSRange(location: 0, length: source.utf16.count))
        }
    }

    private func fixture(_ source: String, width: CGFloat = 600, height: CGFloat) -> (NSWindow, NSScrollView, MarkdownSurface) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        let surface = MarkdownSurface()
        scroll.documentView = surface
        window.contentView = scroll
        surface.configure(content: source, style: .init())
        surface.frame = CGRect(origin: .zero, size: surface.preflight(width: width).size)
        scroll.layoutSubtreeIfNeeded()
        surface.layoutSubtreeIfNeeded()
        surface.refreshVisibleBlocks()
        window.makeFirstResponder(surface)
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return (window, scroll, surface)
    }

    private func drag(from first: MarkdownSelectableTextView, offset: Int, to last: MarkdownSelectableTextView,
                      offset end: Int, window: NSWindow, flags: NSEvent.ModifierFlags = []) throws {
        let startRect = try XCTUnwrap(first.selectionRects(for: NSRange(location: offset, length: 0)).first)
        let endRect = try XCTUnwrap(last.selectionRects(for: NSRange(location: end, length: 0)).first)
        // Posted mouse events round coordinates; stay just inside the insertion boundary.
        let startPoint = CGPoint(x: ceil(startRect.minX) + 1, y: startRect.midY)
        let endPoint = CGPoint(x: ceil(endRect.minX) + 1, y: endRect.midY)
        XCTAssertEqual(first.characterIndexForInsertion(at: startPoint), offset)
        XCTAssertEqual(last.characterIndexForInsertion(at: endPoint), end)
        let start = first.convert(startPoint, to: nil)
        let finish = last.convert(endPoint, to: nil)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseDragged, finish), atStart: false)
        NSApp.postEvent(try event(.leftMouseUp, finish), atStart: false)
        first.mouseDown(with: try event(.leftMouseDown, start))
    }
}
