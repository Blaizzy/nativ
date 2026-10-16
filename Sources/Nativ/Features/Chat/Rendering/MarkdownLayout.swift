import AppKit

struct MarkdownStyle: Hashable {
    var fontSize: CGFloat = 15
    var dark = false
    var baseURL: URL?
    var images: MarkdownImages = .empty

    var foreground: NSColor {
        dark ? NSColor(white: 0.94, alpha: 1) : NSColor(white: 0.06, alpha: 1)
    }
    var background: NSColor {
        dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.97, alpha: 1)
    }
    var border: NSColor { dark ? NSColor(white: 0.29, alpha: 1) : NSColor(white: 0.86, alpha: 1) }
}

struct MarkdownTextFragment {
    let id: String
    let text: NSAttributedString
    var frame: CGRect
}

struct MarkdownDecoration {
    var frame: CGRect
    let color: NSColor
    var radius: CGFloat = 0
}

struct MarkdownBlock {
    let id: String
    var frame: CGRect
    var contentSize: CGSize
    var text: [MarkdownTextFragment]
    var decorations: [MarkdownDecoration] = []
    var scrollsHorizontally = false
}

struct MarkdownLayout {
    var blocks: [MarkdownBlock]
    var decorations: [MarkdownDecoration]
    let size: CGSize
}

@MainActor
final class MarkdownLayoutCache {
    static let shared = MarkdownLayoutCache()
    private struct Key: Hashable {
        let markdown: String
        let width: CGFloat
        let style: MarkdownStyle
    }
    private var layouts: [Key: MarkdownLayout] = [:]
    private var order: [Key] = []
    private var cost = 0

    func layout(_ markdown: String, width: CGFloat, style: MarkdownStyle)
        -> MarkdownLayout
    {
        // The owning surface retains the current image layout. Do not let the shared
        // document cache keep decoded model-card images alive after that surface closes.
        if !style.images.values.isEmpty {
            return MarkdownLayouter.layout(markdown, width: max(1, width), style: style)
        }
        let key = Key(markdown: markdown, width: max(1, width), style: style)
        if let value = layouts[key] { return value }
        let value = MarkdownLayouter.layout(markdown, width: key.width, style: style)
        layouts[key] = value
        order.append(key)
        cost += markdown.utf8.count
        while order.count > 48 || (cost > 2_000_000 && order.count > 1) {
            let removed = order.removeFirst()
            layouts.removeValue(forKey: removed)
            cost -= removed.markdown.utf8.count
        }
        return value
    }

}

@MainActor
enum MarkdownLayouter {
    static func layout(_ markdown: String, width: CGFloat, style: MarkdownStyle)
        -> MarkdownLayout
    {
        var builder = Builder(style: style)
        builder.append(
            MarkdownParser.parse(markdown), x: 0, width: max(1, width), path: "root")
        return MarkdownLayout(
            blocks: builder.blocks.sorted { $0.frame.minY < $1.frame.minY },
            decorations: builder.decorations,
            size: CGSize(width: width, height: ceil(builder.y * 2) / 2)
        )
    }

    @MainActor
    private struct Builder {
        let style: MarkdownStyle
        var blocks: [MarkdownBlock] = []
        var decorations: [MarkdownDecoration] = []
        var y: CGFloat = 0

        mutating func append(
            _ nodes: [MarkdownNode], x: CGFloat, width: CGFloat, path: String,
            tight: Bool = false
        ) {
            var previousBottom: CGFloat = 0
            for (index, node) in nodes.enumerated() {
                let top: CGFloat = node.kind == "heading" || node.kind == "thematic_break" ? 24 : 0
                if index > 0 { y += max(previousBottom, top) }
                append(node, x: x, width: width, id: "\(path).\(index)")
                previousBottom = tight ? 4 : (node.kind == "thematic_break" ? 24 : 16)
            }
        }

        mutating func append(_ node: MarkdownNode, x: CGFloat, width: CGFloat, id: String) {
            switch node.kind {
            case "list":
                let indent = min(width / 2, style.fontSize * 2)
                for (index, item) in node.children.enumerated() {
                    if index > 0 { y += node.tight ? 4 : 16 }
                    let itemY = y
                    let marker =
                        item.checked.map { $0 ? "☑" : "☐" }
                        ?? (node.ordered ? "\(node.start + index)." : "•")
                    append(
                        item.children, x: x + indent, width: max(1, width - indent),
                        path: "\(id).\(index)", tight: node.tight)
                    let attributed = text(marker, size: style.fontSize, alignment: .right)
                    let size = measure(attributed, width: max(1, indent - 8))
                    blocks.append(
                        MarkdownBlock(
                            id: "\(id).marker.\(index)",
                            frame: CGRect(x: x, y: itemY, width: indent - 8, height: size.height),
                            contentSize: size,
                            text: [
                                .init(
                                    id: "marker", text: attributed,
                                    frame: CGRect(
                                        origin: .zero,
                                        size: CGSize(width: indent - 8, height: size.height)))
                            ]))
                    y = max(y, itemY + size.height)
                }
            case "block_quote":
                let initialY = y
                let inset = min(width / 3, style.fontSize)
                append(node.children, x: x + inset, width: max(1, width - inset * 2), path: id)
                decorations.append(
                    .init(
                        frame: CGRect(x: x, y: initialY, width: 3, height: y - initialY),
                        color: style.border, radius: 1.5))
            case "table":
                appendTable(node, x: x, width: width, id: id)
            case "thematic_break":
                let height = max(2, style.fontSize * 0.25)
                decorations.append(
                    .init(
                        frame: CGRect(x: x, y: y, width: width, height: height), color: style.border
                    ))
                y += height
            case "code_block":
                let font = NSFont.monospacedSystemFont(
                    ofSize: style.fontSize * 0.85, weight: .regular)
                var code = node.literal
                if code.hasSuffix("\n") { code.removeLast() }
                let output = NSMutableAttributedString(
                    string: code.isEmpty ? "\u{200B}" : code,
                    attributes: attributes(font: font, spacing: style.fontSize * 0.225))
                let highlighted = MarkdownHighlighter.highlight(
                    code, language: node.destination, dark: style.dark)
                highlighted.enumerateAttribute(
                    .foregroundColor, in: NSRange(location: 0, length: highlighted.length)
                ) { color, range, _ in
                    if let color {
                        output.addAttribute(.foregroundColor, value: color, range: range)
                    }
                }
                addText(
                    output, x: x, width: width, id: id, horizontal: true, padding: 16,
                    background: style.background)
            case "heading":
                let scales: [CGFloat] = [2, 1.5, 1.25, 1, 0.875, 0.85]
                let size = style.fontSize * scales[min(5, max(0, node.level - 1))]
                let output = inline(
                    node.children, font: .systemFont(ofSize: size, weight: .semibold),
                    spacing: size * 0.125, imageWidth: width)
                addText(output, x: x, width: width, id: id)
                if node.level <= 2 {
                    y += size * 0.3
                    decorations.append(
                        .init(
                            frame: CGRect(x: x, y: y, width: width, height: 0.5),
                            color: style.border))
                    y += 0.5
                }
            case "paragraph", "html_block":
                if node.children.count == 1, let child = node.children.first, child.kind == "image",
                    let url = URL(string: child.destination), url.scheme == "swiftmath",
                    url.host == "d"
                {
                    let output = inline(
                        node.children, font: .systemFont(ofSize: style.fontSize + 2))
                    addText(
                        output, x: x, width: width, id: id, horizontal: true, padding: 4,
                        centered: true)
                } else {
                    let output =
                        node.children.isEmpty
                        ? text(node.literal, size: style.fontSize)
                        : inline(
                            node.children, font: .systemFont(ofSize: style.fontSize),
                            imageWidth: width)
                    addText(output, x: x, width: width, id: id)
                }
            default:
                if !node.children.isEmpty {
                    append(node.children, x: x, width: width, path: id)
                } else if !node.literal.isEmpty {
                    addText(text(node.literal, size: style.fontSize), x: x, width: width, id: id)
                }
            }
        }

        mutating func addText(
            _ text: NSAttributedString, x: CGFloat, width: CGFloat, id: String,
            horizontal: Bool = false, padding: CGFloat = 0, centered: Bool = false,
            background: NSColor? = nil
        ) {
            guard text.length > 0 else { return }
            let available = max(1, width - padding * 2)
            let preferred = horizontal ? measure(text, width: 100_000).width : available
            let textWidth = horizontal ? max(available, preferred + 1) : available
            let metrics = measure(text, width: textWidth)
            let scrolls = horizontal && textWidth > available + 1
            let height = metrics.height + padding * 2 + (scrolls ? 12 : 0)
            let contentSize = CGSize(
                width: textWidth + padding * 2, height: metrics.height + padding * 2)
            let textX = centered && !scrolls ? max(padding, (width - preferred) / 2) : padding
            let fragmentWidth = centered && !scrolls ? min(textWidth, preferred + 1) : textWidth
            let fragment = MarkdownTextFragment(
                id: "text", text: text,
                frame: CGRect(x: textX, y: padding, width: fragmentWidth, height: metrics.height))
            var block = MarkdownBlock(
                id: id, frame: CGRect(x: x, y: y, width: width, height: height),
                contentSize: contentSize, text: [fragment], scrollsHorizontally: scrolls)
            if let background {
                block.decorations = [
                    .init(
                        frame: CGRect(origin: .zero, size: contentSize), color: background,
                        radius: 6)
                ]
            }
            blocks.append(block)
            y += height
        }

        mutating func appendTable(
            _ node: MarkdownNode, x: CGFloat, width: CGFloat, id: String
        ) {
            let columns = max(
                node.alignments.count, node.children.map { $0.children.count }.max() ?? 0)
            guard columns > 0 else { return }
            let cells: [[NSAttributedString]] = node.children.enumerated().map { row, rowNode in
                (0 ..< columns).map { column in
                    let value =
                        column < rowNode.children.count ? rowNode.children[column].children : []
                    let alignment: NSTextAlignment =
                        column < node.alignments.count && node.alignments[column] == 114
                        ? .right
                        : (column < node.alignments.count && node.alignments[column] == 99
                            ? .center : .left)
                    return inline(
                        value,
                        font: .systemFont(
                            ofSize: style.fontSize, weight: row == 0 ? .semibold : .regular),
                        alignment: alignment)
                }
            }
            var widths = (0 ..< columns).map { column in
                min(
                    360,
                    max(
                        64,
                        (cells.map { measure($0[column], width: 100_000).width }.max() ?? 0) + 26))
            }
            let preferred = widths.reduce(0, +) + 1
            if preferred > width {
                let factor = max(1, width - 1) / widths.reduce(0, +)
                widths = widths.map { max(1, $0 * factor) }
            }
            var fragments: [MarkdownTextFragment] = []
            var fills: [MarkdownDecoration] = []
            var rowY: CGFloat = 1
            for (row, rowValues) in cells.enumerated() {
                let values = rowValues.enumerated().map {
                    MarkdownImages.fittingAttachments(
                        in: $0.element, width: max(1, widths[$0.offset] - 26))
                }
                let sizes = values.enumerated().map {
                    measure($0.element, width: max(1, widths[$0.offset] - 26))
                }
                let height = max(style.fontSize * 1.3, sizes.map(\.height).max() ?? 0) + 12
                var columnX: CGFloat = 1
                for column in 0 ..< columns {
                    fragments.append(
                        .init(
                            id: "\(row).\(column)", text: values[column],
                            frame: CGRect(
                                x: columnX + 13, y: rowY + 6, width: max(1, widths[column] - 26),
                                height: sizes[column].height)))
                    fills.append(
                        .init(
                            frame: CGRect(x: columnX - 1, y: rowY, width: 1, height: height),
                            color: style.border))
                    columnX += widths[column]
                }
                if row % 2 == 1 {
                    fills.insert(
                        .init(
                            frame: CGRect(x: 0, y: rowY, width: columnX, height: height),
                            color: style.background), at: 0)
                }
                fills.append(
                    .init(
                        frame: CGRect(x: 0, y: rowY - 1, width: columnX, height: 1),
                        color: style.border))
                fills.append(
                    .init(
                        frame: CGRect(x: columnX - 1, y: rowY, width: 1, height: height),
                        color: style.border))
                rowY += height
            }
            let totalWidth = widths.reduce(0, +) + 1
            fills.append(
                .init(
                    frame: CGRect(x: 0, y: rowY - 1, width: totalWidth, height: 1),
                    color: style.border))
            let scrolls = totalWidth > width + 1
            let height = rowY + (scrolls ? 12 : 0)
            blocks.append(
                .init(
                    id: id, frame: CGRect(x: x, y: y, width: width, height: height),
                    contentSize: CGSize(width: totalWidth, height: rowY), text: fragments,
                    decorations: fills, scrollsHorizontally: scrolls))
            y += height
        }

        func inline(
            _ nodes: [MarkdownNode], font: NSFont, spacing: CGFloat? = nil,
            alignment: NSTextAlignment = .natural, imageWidth: CGFloat = 334
        ) -> NSAttributedString {
            let result = NSMutableAttributedString(string: "")
            let attrs = attributes(
                font: font, spacing: spacing ?? style.fontSize * 0.25, alignment: alignment)
            for node in nodes {
                switch node.kind {
                case "text":
                    result.append(NSAttributedString(string: node.literal, attributes: attrs))
                case "softbreak": result.append(NSAttributedString(string: " ", attributes: attrs))
                case "linebreak": result.append(NSAttributedString(string: "\n", attributes: attrs))
                case "code":
                    var codeAttrs = attrs
                    codeAttrs[.font] = NSFont.monospacedSystemFont(
                        ofSize: font.pointSize * 0.85, weight: .regular)
                    codeAttrs[.backgroundColor] = style.background
                    result.append(NSAttributedString(string: node.literal, attributes: codeAttrs))
                case "emph", "strong", "strikethrough", "link":
                    var childFont = font
                    if node.kind == "emph" {
                        childFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    }
                    if node.kind == "strong" {
                        childFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    }
                    let child = NSMutableAttributedString(
                        attributedString: inline(
                            node.children, font: childFont, spacing: spacing, alignment: alignment,
                            imageWidth: imageWidth))
                    let range = NSRange(location: 0, length: child.length)
                    if node.kind == "strikethrough" {
                        child.addAttribute(
                            .strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                            range: range)
                    }
                    if node.kind == "link",
                        let url = URL(string: node.destination, relativeTo: style.baseURL)?
                            .absoluteURL
                    {
                        child.addAttribute(.link, value: url, range: range)
                    }
                    result.append(child)
                case "image":
                    if let url = URL(string: node.destination), url.scheme == "swiftmath",
                        let math = MarkdownMath.attachment(
                            url: url, fontSize: font.pointSize, dark: style.dark)
                    {
                        let child = NSMutableAttributedString(attributedString: math)
                        child.addAttributes(
                            attrs, range: NSRange(location: 0, length: child.length))
                        result.append(child)
                    } else if let url = URL(string: node.destination), url.scheme == "swiftmath" {
                        let literal =
                            MathPreprocessor.decodeBase64URL(String(url.path.dropFirst())) ?? "math"
                        result.append(NSAttributedString(string: literal, attributes: attrs))
                    } else {
                        let alt = imageLabel(node.children)
                        let label = alt.isEmpty ? node.destination : alt
                        let url = URL(string: node.destination, relativeTo: style.baseURL)?
                            .absoluteURL
                        var imageAttrs = attrs
                        if let url { imageAttrs[.link] = url }
                        if let url,
                            let image = style.images.attachment(
                                url: url, label: label, width: imageWidth)
                        {
                            let child = NSMutableAttributedString(attributedString: image)
                            child.addAttributes(
                                imageAttrs, range: NSRange(location: 0, length: child.length))
                            result.append(child)
                        } else {
                            // Chat does not load document images; failed/pending document images have a link fallback.
                            result.append(NSAttributedString(string: label, attributes: imageAttrs))
                        }
                    }
                case "html_inline":
                    let isBreak =
                        node.literal.range(
                            of: #"^<br\s*/?>$"#, options: [.regularExpression, .caseInsensitive])
                        != nil
                    result.append(
                        NSAttributedString(string: isBreak ? "\n" : node.literal, attributes: attrs)
                    )
                default:
                    result.append(
                        node.children.isEmpty
                            ? NSAttributedString(string: node.literal, attributes: attrs)
                            : inline(
                                node.children, font: font, spacing: spacing, alignment: alignment,
                                imageWidth: imageWidth))
                }
            }
            return NSAttributedString(attributedString: result)
        }

        func imageLabel(_ nodes: [MarkdownNode]) -> String {
            nodes.map { $0.children.isEmpty ? $0.literal : imageLabel($0.children) }.joined()
        }

        func attributes(font: NSFont, spacing: CGFloat, alignment: NSTextAlignment = .natural)
            -> [NSAttributedString.Key: Any]
        {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = spacing
            paragraph.alignment = alignment
            paragraph.tabStops = []
            paragraph.defaultTabInterval = font.pointSize * 2.4
            return [.font: font, .foregroundColor: style.foreground, .paragraphStyle: paragraph]
        }

        func text(_ string: String, size: CGFloat, alignment: NSTextAlignment = .natural)
            -> NSAttributedString
        {
            NSAttributedString(
                string: string,
                attributes: attributes(
                    font: .systemFont(ofSize: size), spacing: size * 0.25, alignment: alignment))
        }

        func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
            MarkdownTextMetrics.shared.measure(text, width: max(1, width))
        }
    }
}
