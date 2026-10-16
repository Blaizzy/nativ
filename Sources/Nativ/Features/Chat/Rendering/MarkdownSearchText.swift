import Foundation

/// Uses the same alternatives as copy and accessibility, whether math renders as an
/// attachment or falls back to literal LaTeX. Ranges remain in UTF-16 coordinates.
struct MarkdownSearchText {
    private struct Segment {
        let text: NSRange
        let rendered: NSRange
        let isAlternative: Bool
    }

    let text: String
    private let segments: [Segment]

    init(_ rendered: NSAttributedString) {
        var text = ""
        var segments: [Segment] = []
        var offset = 0
        rendered.enumerateAttribute(.markdownAlternative, in: NSRange(location: 0, length: rendered.length)) {
            alternative, range, _ in
            let value = (alternative as? String) ?? (rendered.string as NSString).substring(with: range)
            let length = value.utf16.count
            segments.append(Segment(text: NSRange(location: offset, length: length), rendered: range,
                                    isAlternative: alternative is String))
            text += value
            offset += length
        }
        self.text = text
        self.segments = segments
    }

    func renderedRange(for range: NSRange) -> NSRange? {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= text.utf16.count, range.length <= text.utf16.count - range.location else { return nil }
        var result: NSRange?
        for segment in segments {
            let intersection = NSIntersectionRange(range, segment.text)
            guard intersection.length > 0 else { continue }
            // A match inside LaTeX selects its entire attachment; surrounding text keeps exact offsets.
            let mapped = segment.isAlternative ? segment.rendered : NSRange(
                location: segment.rendered.location + intersection.location - segment.text.location,
                length: intersection.length)
            result = result.map { NSUnionRange($0, mapped) } ?? mapped
        }
        return result
    }
}
