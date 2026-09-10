import AppKit

/// Selection belongs to the document, not to the short-lived viewport text views.
/// The index references existing attributed strings; it creates no text systems.
@MainActor
final class MarkdownSelection {
    struct Fragment {
        let id: String
        let text: NSAttributedString
        let frame: CGRect
        let separator: String
        let range: NSRange
    }

    struct SelectedFragment {
        let text: String
        let range: NSRange?
    }

    private weak var surface: MarkdownSurface?
    private(set) var fragments: [Fragment] = []
    private var ranges: [String: NSRange] = [:]
    private var indexed = false
    private(set) var anchor = 0
    private(set) var head = 0
    var range: NSRange { NSRange(location: min(anchor, head), length: abs(head - anchor)) }
    var length: Int { fragments.last.map { NSMaxRange($0.range) } ?? 0 }

    init(surface: MarkdownSurface) { self.surface = surface }

    func invalidate(contentChanged: Bool) {
        indexed = false
        fragments.removeAll()
        ranges.removeAll()
        if contentChanged { anchor = 0; head = 0 }
    }

    private func indexIfNeeded() {
        guard !indexed, let layout = surface?.snapshot else { return }
        indexed = true
        var values: [(String, MarkdownTextFragment, CGRect)] = []
        for block in layout.blocks {
            for fragment in block.text {
                values.append((block.id, fragment,
                               fragment.frame.offsetBy(dx: block.frame.minX, dy: block.frame.minY)))
            }
        }
        values.sort {
            $0.2.minY == $1.2.minY ? $0.2.minX < $1.2.minX : $0.2.minY < $1.2.minY
        }
        var offset = 0
        for (index, value) in values.enumerated() {
            let (blockID, text, frame) = value
            var separator = index == 0 ? "" : "\n\n"
            if index > 0 {
                let previous = values[index - 1]
                if previous.0 == blockID { separator = previous.2.minY == frame.minY ? "\t" : "\n" }
                else if previous.0.contains(".marker.") { separator = " " }
            }
            offset += separator.utf16.count
            let id = blockID + "/" + text.id
            let range = NSRange(location: offset, length: text.text.length)
            fragments.append(Fragment(id: id, text: text.text, frame: frame, separator: separator, range: range))
            ranges[id] = range
            offset = NSMaxRange(range)
        }
        anchor = min(anchor, length)
        head = min(head, length)
    }

    func localRange(for id: String) -> NSRange? {
        guard range.length > 0 else { return nil }
        indexIfNeeded()
        guard let fragment = ranges[id] else { return nil }
        let intersection = NSIntersectionRange(range, fragment)
        guard intersection.length > 0 else { return nil }
        return NSRange(location: intersection.location - fragment.location, length: intersection.length)
    }

    func select(anchor: Int, head: Int) {
        indexIfNeeded()
        self.anchor = max(0, min(anchor, length))
        self.head = max(0, min(head, length))
        surface?.updateSelectionHighlights()
    }

    func clear() { select(anchor: 0, head: 0) }

    func select(in id: String, range: NSRange) {
        indexIfNeeded()
        guard let fragment = ranges[id], range.location != NSNotFound,
              range.location >= 0, range.length >= 0,
              range.location <= fragment.length,
              range.length <= fragment.length - range.location else { return }
        if let surface { surface.window?.makeFirstResponder(surface) }
        select(anchor: fragment.location + range.location, head: fragment.location + NSMaxRange(range))
    }

    var text: String {
        indexIfNeeded()
        var result = ""
        for fragment in fragments {
            let separatorRange = NSRange(
                location: fragment.range.location - fragment.separator.utf16.count,
                length: fragment.separator.utf16.count)
            let separatorSelection = NSIntersectionRange(range, separatorRange)
            if separatorSelection.length > 0 {
                result += (fragment.separator as NSString).substring(with: NSRange(
                    location: separatorSelection.location - separatorRange.location,
                    length: separatorSelection.length))
            }
            if let local = localRange(for: fragment.id) {
                result += MarkdownSelectableTextView.plainText(fragment.text.attributedSubstring(from: local))
            }
        }
        return result
    }

    /// Include preceding fragments so repeated passages can be mapped in document order.
    var selectedFragments: [SelectedFragment] {
        indexIfNeeded()
        return fragments.prefix { $0.range.location < NSMaxRange(range) }.compactMap { fragment in
            guard !fragment.id.contains(".marker.") else { return nil }
            let local = localRange(for: fragment.id)
            let plainRange = local.map { local in
                NSRange(
                    location: MarkdownSelectableTextView.plainText(fragment.text.attributedSubstring(
                        from: NSRange(location: 0, length: local.location))).utf16.count,
                    length: MarkdownSelectableTextView.plainText(fragment.text.attributedSubstring(from: local)).utf16.count)
            }
            return SelectedFragment(text: MarkdownSelectableTextView.plainText(fragment.text), range: plainRange)
        }
    }

    var selectionFrame: CGRect? {
        guard let surface, let window = surface.window else { return nil }
        var result: CGRect?
        for view in surface.visibleTextViews {
            guard let local = localRange(for: view.fragmentID) else { continue }
            for rect in view.selectionRects(for: local) {
                let visible = view.convert(rect, to: surface).intersection(surface.visibleRect)
                if !visible.isEmpty && !visible.isNull { result = result.map { $0.union(visible) } ?? visible }
            }
        }
        return result.map { window.convertToScreen(surface.convert($0, to: nil)) }
    }

    func copy(to pasteboard: NSPasteboard) {
        guard range.length > 0 else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func hit(at point: CGPoint) -> (MarkdownSelectableTextView, Int)? {
        guard let surface else { return nil }
        // Only hit-test already mounted text. Autoscrolling mounts the next viewport normally.
        let candidates = surface.visibleTextViews.filter { !$0.visibleRect.isEmpty }
        guard let view = candidates.min(by: {
            distance(point, to: $0.convert($0.bounds, to: surface))
                < distance(point, to: $1.convert($1.bounds, to: surface))
        }) else { return nil }
        indexIfNeeded()
        guard let fragment = ranges[view.fragmentID] else { return nil }
        let local = view.convert(point, from: surface)
        let index = min(view.characterIndexForInsertion(at: local), fragment.length)
        return (view, fragment.location + index)
    }

    private func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    func track(_ event: NSEvent) {
        guard let surface, let window = surface.window,
              let (view, position) = hit(at: surface.convert(event.locationInWindow, from: nil)),
              let fragment = ranges[view.fragmentID] else { return }
        let granularity: NSSelectionGranularity = event.clickCount >= 3 ? .selectByParagraph
            : event.clickCount == 2 ? .selectByWord : .selectByCharacter
        let local = view.selectionRange(forProposedRange: NSRange(
            location: position - fragment.location, length: 0), granularity: granularity)
        let initial = NSRange(location: fragment.location + local.location, length: local.length)
        let start = event.modifierFlags.contains(.shift) ? NSRange(location: anchor, length: 0) : initial
        window.makeFirstResponder(surface)
        select(anchor: start.location, head: event.modifierFlags.contains(.shift) ? position : NSMaxRange(initial))
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.03)
        defer { NSEvent.stopPeriodicEvents() }
        var drag = event
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic],
                                           until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            guard surface.window === window else { break }
            if next.type != .periodic { drag = next }
            let finished = next.type == .leftMouseUp
            if !finished { _ = surface.autoscroll(with: drag) }
            surface.refreshVisibleBlocks()
            guard let (target, end) = hit(at: surface.convert(drag.locationInWindow, from: nil)),
                  let targetRange = ranges[target.fragmentID] else {
                if finished { break }
                continue
            }
            let expanded = target.selectionRange(forProposedRange: NSRange(
                location: end - targetRange.location, length: 0), granularity: granularity)
            let lower = targetRange.location + expanded.location
            let upper = lower + expanded.length
            select(anchor: lower < start.location ? NSMaxRange(start) : start.location,
                   head: lower < start.location ? lower : upper)
            if finished { break }
        }
    }

    /// Native key bindings call these selectors through interpretKeyEvents.
    func command(_ selector: Selector) -> Bool {
        indexIfNeeded()
        let name = NSStringFromSelector(selector)
        let extending = name.contains("AndModifySelection")
        let forward = !name.contains("Left") && !name.contains("Backward")
            && !name.contains("Beginning") && !name.contains("Up")
        var destination: Int
        if name == "selectAll:" { select(anchor: 0, head: length); return true }
        if name == "cancelOperation:" { clear(); return true }
        if name.contains("BeginningOfDocument") { destination = 0 }
        else if name.contains("EndOfDocument") { destination = length }
        else if name.hasPrefix("move") && !name.contains("Line") && (name.contains("Left") || name.contains("Right")
                    || name.contains("Forward") || name.contains("Backward")) {
            if !extending && range.length > 0 && !name.contains("Word") {
                destination = forward ? NSMaxRange(range) : range.location
            } else {
                destination = step(from: head, forward: forward, word: name.contains("Word"))
            }
        } else if name.hasPrefix("move") && (name.contains("Up") || name.contains("Down")
                    || name.contains("Line")
                    || name.contains("BeginningOfParagraph") || name.contains("EndOfParagraph")) {
            guard let surface else { return true }
            revealHead()
            guard let view = surface.visibleTextViews.first(where: {
                ranges[$0.fragmentID].map { head >= $0.location && head <= NSMaxRange($0) } == true
            }), let fragment = ranges[view.fragmentID] else { return true }
            if name.contains("Paragraph") {
                destination = forward ? NSMaxRange(fragment) : fragment.location
            } else {
                let local = NSRange(location: head - fragment.location, length: 0)
                guard let caret = view.selectionRects(for: local).first else { return true }
                let rect = view.convert(caret, to: surface)
                let point: CGPoint
                if name.contains("Line") {
                    point = CGPoint(x: forward ? surface.bounds.maxX : 0, y: rect.midY)
                } else {
                    point = CGPoint(x: rect.minX, y: rect.midY + (forward ? 1 : -1) * (rect.height + 4))
                }
                destination = hit(at: point)?.1 ?? head
                if destination == head { destination = step(from: head, forward: forward, word: false) }
            }
        } else { return false }
        select(anchor: extending ? anchor : destination, head: destination)
        revealHead()
        return true
    }

    private func step(from position: Int, forward: Bool, word: Bool) -> Int {
        guard let fragment = fragments.first(where: {
            forward ? NSMaxRange($0.range) > position : $0.range.location < position && NSMaxRange($0.range) >= position
        }) ?? (forward ? nil : fragments.last(where: { $0.range.location < position })) else {
            return forward ? length : 0
        }
        let local = max(0, min(position - fragment.range.location, fragment.range.length))
        if forward && position < fragment.range.location { return fragment.range.location }
        if !forward && position > NSMaxRange(fragment.range) { return NSMaxRange(fragment.range) }
        if word { return fragment.range.location + fragment.text.nextWord(from: local, forward: forward) }
        let index = forward ? local : max(0, local - 1)
        guard index < fragment.text.length else { return NSMaxRange(fragment.range) }
        let composed = (fragment.text.string as NSString).rangeOfComposedCharacterSequence(at: index)
        return fragment.range.location + (forward ? NSMaxRange(composed) : composed.location)
    }

    private func revealHead() {
        guard let surface, let fragment = fragments.first(where: {
            head >= $0.range.location && head <= NSMaxRange($0.range)
        }) else { return }
        if !fragment.frame.intersects(surface.visibleRect) {
            surface.scrollToVisible(fragment.frame)
            surface.refreshVisibleBlocks()
        }
    }
}
