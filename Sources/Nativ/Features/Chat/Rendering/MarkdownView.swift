import AppKit
import SwiftUI

/// A cheap document shell. Its height comes from preflight; only nearby blocks create text views.
struct MarkdownView: NSViewRepresentable {
    let content: String
    let style: MarkdownStyle

    func makeNSView(context: Context) -> MarkdownSurface {
        let view = MarkdownSurface()
        view.configure(content: content, style: style)
        return view
    }

    func updateNSView(_ nsView: MarkdownSurface, context: Context) {
        nsView.configure(content: content, style: style)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownSurface, context: Context)
        -> CGSize?
    {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return nsView.preflight(width: width).size
    }
}

@MainActor
final class MarkdownSurface: NSView {
    private(set) lazy var selection = MarkdownSelection(surface: self)
    var visibleTextViews: [MarkdownSelectableTextView] { mounted.values.flatMap { $0.content.textViews } }
    private var content: String?
    private var style = MarkdownStyle()
    private var mounted: [String: MarkdownBlockView] = [:]
    private var measuredWidth: CGFloat = -1
    private(set) var snapshot: MarkdownLayout?
    private var maximumBlockEnds: [CGFloat] = []
    private var blockIDs: Set<String> = []
    private var isRefreshing = false
    private var refreshedVisibleRect: CGRect?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) { selection.track(event) }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    override func doCommand(by selector: Selector) {
        if !selection.command(selector) { super.doCommand(by: selector) }
    }
    override func resignFirstResponder() -> Bool {
        selection.clear()
        return super.resignFirstResponder()
    }
    @objc func copy(_ sender: Any?) { selection.copy(to: .general) }
    override func selectAll(_ sender: Any?) { _ = selection.command(#selector(selectAll(_:))) }

    func updateSelectionHighlights() {
        for view in visibleTextViews { view.documentSelection = selection.localRange(for: view.fragmentID) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = selection.range.length > 0
        menu.autoenablesItems = false
        return menu
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Not a serialized view") }

    func configure(content: String, style: MarkdownStyle) {
        guard self.content != content || self.style != style else { return }
        selection.invalidate(contentChanged: self.content != content)
        self.content = content
        self.style = style
        measuredWidth = -1
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func preflight(width: CGFloat) -> MarkdownLayout {
        if let snapshot, measuredWidth == width { return snapshot }
        let result = MarkdownLayoutCache.shared.layout(
            content ?? "", width: width, style: style)
        setSnapshot(result)
        measuredWidth = width
        return result
    }

    private func setSnapshot(_ snapshot: MarkdownLayout) {
        self.snapshot = snapshot
        selection.invalidate(contentChanged: false)
        refreshedVisibleRect = nil
        var end: CGFloat = 0
        maximumBlockEnds = snapshot.blocks.map {
            end = max(end, $0.frame.maxY)
            return end
        }
        blockIDs = Set(snapshot.blocks.map(\.id))
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if content != nil && bounds.width > 0 { _ = preflight(width: bounds.width) }
        refreshVisibleBlocks()
    }

    override func viewWillDraw() {
        // Evicting older rows can move an unchanged surface through its ancestors
        // after the clip-view notification. Mount against the final visible rect
        // before AppKit visits the text subviews for this display pass.
        if refreshedVisibleRect != visibleRect { refreshVisibleBlocks() }
        super.viewWillDraw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self, name: NSView.boundsDidChangeNotification, object: nil)
        if window != nil {
            enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(viewportChanged),
                name: NSView.boundsDidChangeNotification, object: nil)
            needsLayout = true
        }
    }

    @objc private func viewportChanged(_ notification: Notification) {
        guard notification.object is NSClipView else { return }
        refreshVisibleBlocks()
    }

    func refreshVisibleBlocks() {
        guard !isRefreshing, let snapshot, window != nil else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let visible = visibleRect
        refreshedVisibleRect = visible
        let region = visible.isEmpty ? CGRect.zero : visible.insetBy(dx: 0, dy: -350)
        var needed = Set<String>()
        var lower = 0
        var upper = maximumBlockEnds.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if maximumBlockEnds[middle] < region.minY { lower = middle + 1 } else { upper = middle }
        }
        for block in snapshot.blocks.dropFirst(lower) {
            if region.isEmpty || block.frame.minY > region.maxY { break }
            guard block.frame.intersects(region) else { continue }
            needed.insert(block.id)
            let view = mounted[block.id] ?? MarkdownBlockView()
            if mounted[block.id] == nil {
                mounted[block.id] = view
                addSubview(view)
            }
            view.frame = block.frame
            view.update(block, selection: selection)
        }
        for id in Array(mounted.keys) where !needed.contains(id) {
            guard let view = mounted[id] else { continue }
            if view.containsSelection && blockIDs.contains(id) { continue }
            view.removeFromSuperview()
            mounted.removeValue(forKey: id)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for decoration in snapshot?.decorations ?? [] where decoration.frame.intersects(dirtyRect) {
            decoration.color.setFill()
            NSBezierPath(
                roundedRect: decoration.frame, xRadius: decoration.radius,
                yRadius: decoration.radius
            ).fill()
        }
    }
}

@MainActor
private final class MarkdownHorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

@MainActor
private final class MarkdownBlockView: NSView {
    let content = MarkdownBlockContentView()
    private var scroller: NSScrollView?
    override var isFlipped: Bool { true }
    var containsSelection: Bool { content.containsSelection }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(content)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Not a serialized view") }

    func update(_ block: MarkdownBlock, selection: MarkdownSelection) {
        if block.scrollsHorizontally {
            if scroller == nil {
                content.removeFromSuperview()
                let scroll = MarkdownHorizontalScrollView()
                scroll.drawsBackground = false
                scroll.hasHorizontalScroller = true
                scroll.hasVerticalScroller = false
                scroll.scrollerStyle = .overlay
                scroll.autohidesScrollers = true
                scroll.documentView = content
                addSubview(scroll)
                scroller = scroll
            }
            scroller?.frame = bounds
            content.frame = CGRect(origin: .zero, size: block.contentSize)
        } else {
            if let scroller {
                scroller.documentView = nil
                scroller.removeFromSuperview()
                self.scroller = nil
                addSubview(content)
            }
            content.frame = bounds
        }
        content.update(block, selection: selection)
    }
}

@MainActor
private final class MarkdownBlockContentView: NSView {
    private var block: MarkdownBlock?
    private var texts: [String: MarkdownSelectableTextView] = [:]
    var textViews: [MarkdownSelectableTextView] { Array(texts.values) }
    override var isFlipped: Bool { true }
    var containsSelection: Bool { texts.values.contains(where: \.hasActiveSelection) }

    func update(_ block: MarkdownBlock, selection: MarkdownSelection) {
        self.block = block
        // The parent already restricts mounting to the viewport. Cells in large tables are restricted too.
        let region = visibleRect.insetBy(dx: -100, dy: -350)
        var needed = Set<String>()
        for fragment in block.text where fragment.frame.intersects(region) {
            needed.insert(fragment.id)
            let view: MarkdownSelectableTextView
            if let existing = texts[fragment.id], existing.matches(fragment) {
                view = existing
            } else {
                let previous = texts[fragment.id]
                let selection = previous?.selectedRange() ?? NSRange(location: 0, length: 0)
                previous?.removeFromSuperview()
                view = MarkdownSelectableTextView(fragment: fragment)
                if selection.length > 0 {
                    let start = min(selection.location, fragment.text.length)
                    view.setSelectedRange(
                        NSRange(
                            location: start,
                            length: min(selection.length, fragment.text.length - start)))
                }
                texts[fragment.id] = view
                addSubview(view)
            }
            view.frame = fragment.frame
            view.fragmentID = block.id + "/" + fragment.id
            view.document = selection
            view.documentSelection = selection.localRange(for: view.fragmentID)
        }
        for id in Array(texts.keys) where !needed.contains(id) {
            guard let view = texts[id], !view.hasActiveSelection else { continue }
            view.removeFromSuperview()
            texts.removeValue(forKey: id)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for decoration in block?.decorations ?? [] where decoration.frame.intersects(dirtyRect) {
            decoration.color.setFill()
            NSBezierPath(
                roundedRect: decoration.frame, xRadius: decoration.radius,
                yRadius: decoration.radius
            ).fill()
        }
    }
}

@MainActor
final class MarkdownSelectableTextView: NSTextView {
    weak var document: MarkdownSelection?
    var fragmentID = ""
    var documentSelection: NSRange? {
        didSet { if oldValue != documentSelection { needsDisplay = true } }
    }
    let system: MarkdownTextSystem
    private let original: NSAttributedString
    private let measuredWidth: CGFloat
    var hasActiveSelection: Bool { window?.firstResponder === self && selectedRange().length > 0 }

    init(fragment: MarkdownTextFragment) {
        system = MarkdownTextSystem(fragment.text, width: fragment.frame.width)
        original = fragment.text
        measuredWidth = fragment.frame.width
        super.init(frame: fragment.frame, textContainer: system.container)
        textContainerInset = .zero
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        isAutomaticLinkDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        allowsUndo = false
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        setAccessibilityLabel(Self.plainText(fragment.text))
    }

    required init?(coder: NSCoder) { fatalError("Not a serialized view") }

    func matches(_ fragment: MarkdownTextFragment) -> Bool {
        measuredWidth == fragment.frame.width && original.isEqual(to: fragment.text)
    }

    override func mouseDown(with event: NSEvent) {
        guard let document else { super.mouseDown(with: event); return }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let link = index < original.length ? original.attribute(.link, at: index, effectiveRange: nil) : nil
        document.track(event)
        if document.range.length == 0, event.clickCount == 1, !event.modifierFlags.contains(.shift), let link {
            clicked(onLink: link, at: index)
        }
    }

    override func accessibilitySelectedText() -> String? {
        documentSelection.map { Self.plainText(original.attributedSubstring(from: $0)) }
            ?? super.accessibilitySelectedText()
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        documentSelection ?? super.accessibilitySelectedTextRange()
    }

    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        if let document { document.select(in: fragmentID, range: range) }
        else { super.setAccessibilitySelectedTextRange(range) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if document?.range.length ?? 0 > 0 {
            let menu = NSMenu()
            let item = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            item.target = self
            menu.autoenablesItems = false
            return menu
        }
        return super.menu(for: event)
    }

    func selectionRects(for range: NSRange, clippedTo clip: CGRect? = nil) -> [CGRect] {
        var range = range
        if let clip {
            let visible = clip.intersection(bounds)
            guard !visible.isNull, !visible.isEmpty else { return [] }
            system.manager.ensureLayout(for: visible)
            guard
                  let lower = lineBoundary(at: visible.minY, upper: false),
                  let upper = lineBoundary(at: visible.maxY.nextDown, upper: true), upper > lower else { return [] }
            // Keep a character of context on either side so TextKit preserves
            // full-line selection extents and leading at the viewport boundaries.
            let string = original.string as NSString
            let start = lower > 0 ? string.rangeOfComposedCharacterSequence(at: lower - 1).location : 0
            let end = upper < string.length ? NSMaxRange(string.rangeOfComposedCharacterSequence(at: upper)) : string.length
            range = NSIntersectionRange(range, NSRange(location: start, length: end - start))
            guard range.length > 0 else { return [] }
        }
        guard let start = system.storage.location(system.storage.documentRange.location, offsetBy: range.location),
              let end = system.storage.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        var rects: [CGRect] = []
        system.manager.enumerateTextSegments(in: textRange, type: .selection, options: []) { _, rect, _, _ in
            if let clip, !rect.intersects(clip) { return true }
            rects.append(rect)
            return true
        }
        return rects
    }

    /// Find whole visible lines before enumerating selection geometry. Using line
    /// boundaries also preserves RTL text and wrapped paragraphs when clipping.
    private func lineBoundary(at y: CGFloat, upper: Bool) -> Int? {
        guard original.length > 0 else { return nil }
        let last = system.storage.location(system.storage.documentRange.location, offsetBy: original.length - 1)
        guard let fragment = system.manager.textLayoutFragment(for: CGPoint(x: bounds.minX, y: y))
                ?? (upper ? last.flatMap { system.manager.textLayoutFragment(for: $0) } : nil) else { return nil }
        guard let line = fragment.textLineFragment(forVerticalOffset: y - fragment.layoutFragmentFrame.minY,
                                                   requiresExactMatch: false)
                ?? (upper ? fragment.textLineFragments.last : nil) else { return nil }
        let start = system.storage.offset(from: system.storage.documentRange.location,
                                          to: fragment.rangeInElement.location)
        return min(original.length, start + (upper ? NSMaxRange(line.characterRange) : line.characterRange.location))
    }

    override func draw(_ dirtyRect: NSRect) {
        if let documentSelection {
            (window?.isKeyWindow == true ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
            for rect in selectionRects(for: documentSelection, clippedTo: dirtyRect.intersection(visibleRect)) {
                NSBezierPath(rect: rect).fill()
            }
        }
        super.draw(dirtyRect)
    }

    override func copy(_ sender: Any?) {
        if let document, document.range.length > 0 { document.copy(to: .general); return }
        let range = selectedRange()
        guard range.length > 0 else { return }
        let value = Self.plainText(original.attributedSubstring(from: range))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    static func plainText(_ text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttribute(
            .markdownAlternative, in: NSRange(location: 0, length: text.length)
        ) { alternative, range, _ in
            result += (alternative as? String) ?? (text.string as NSString).substring(with: range)
        }
        return result
    }
}
