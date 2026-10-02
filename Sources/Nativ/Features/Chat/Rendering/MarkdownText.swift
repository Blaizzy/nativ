import AppKit
import Highlightr
import SwaTex
import SwaTexRender

/// Both preflight and display use this exact TextKit 2 configuration.
@MainActor
final class MarkdownTextSystem {
    let storage = NSTextContentStorage()
    let manager = NSTextLayoutManager()
    let container: NSTextContainer

    init(_ text: NSAttributedString, width: CGFloat) {
        container = NSTextContainer(
            size: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        storage.addTextLayoutManager(manager)
        manager.textContainer = container
        storage.textStorage?.setAttributedString(text)
    }

    func measure() -> CGSize {
        guard (storage.textStorage?.length ?? 0) > 0 else { return .zero }
        manager.ensureLayout(for: storage.documentRange)
        var bounds = CGRect.zero
        var contentWidth: CGFloat = 0
        manager.enumerateTextLayoutFragments(
            from: storage.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            bounds = bounds.union(fragment.layoutFragmentFrame)
            contentWidth = max(contentWidth, fragment.layoutFragmentFrame.width)
            return true
        }
        // Keep half-point precision on Retina, including the final line's descent.
        // Alignment offsets are not intrinsic content width (especially in table cells).
        return CGSize(width: ceil(contentWidth * 2) / 2, height: ceil(bounds.maxY * 2) / 2)
    }
}

@MainActor
final class MarkdownTextMetrics {
    static let shared = MarkdownTextMetrics()
    private struct Key: Hashable {
        let text: NSAttributedString
        let width: CGFloat
    }
    private var values: [Key: CGSize] = [:]
    private var order: [Key] = []
    private var cost = 0

    func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        var containsDocumentImage = false
        text.enumerateAttribute(
            .markdownDocumentImage, in: NSRange(location: 0, length: text.length)
        ) { value, _, stop in
            if value != nil {
                containsDocumentImage = true
                stop.pointee = true
            }
        }
        // Image-bearing runs belong to the surface snapshot, not this process-wide metrics cache.
        if containsDocumentImage { return MarkdownTextSystem(text, width: width).measure() }
        let key = Key(text: text, width: width)
        if let size = values[key] { return size }
        let size = MarkdownTextSystem(text, width: width).measure()
        values[key] = size
        order.append(key)
        cost += text.length
        while order.count > 1024 || (cost > 2_000_000 && order.count > 1) {
            let removed = order.removeFirst()
            values.removeValue(forKey: removed)
            cost -= removed.text.length
        }
        return size
    }

}

/// A cached attachment carries its baseline and dimensions before any text view exists.
final class MarkdownMathCell: NSTextAttachmentCell {
    private let metricSize: CGSize
    private let baselineOffset: CGFloat

    init(image: NSImage, size: CGSize, baseline: CGFloat) {
        metricSize = size
        baselineOffset = baseline - size.height
        super.init(imageCell: image)
    }

    required init(coder: NSCoder) { fatalError("Not a serialized cell") }
    override func cellSize() -> NSSize { metricSize }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: baselineOffset) }
}

extension NSAttributedString.Key {
    static let markdownAlternative = NSAttributedString.Key("dev.nativ.markdown.alternative")
}

@MainActor
enum MarkdownMath {
    private static let cache = NSCache<NSString, NSAttributedString>()

    static func attachment(url: URL, fontSize: CGFloat, dark: Bool) -> NSAttributedString? {
        guard let latex = MathPreprocessor.decodeBase64URL(String(url.path.dropFirst())) else {
            return nil
        }
        let display = url.host == "d"
        let key = "\(fontSize)|\(dark)|\(display)|\(latex)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let color =
            dark
            ? SwaTex.Color(r: 0.92, g: 0.92, b: 0.92, a: 1)
            : SwaTex.Color(r: 0.12, g: 0.12, b: 0.12, a: 1)
        guard
            let list = try? SwaTexEngine.displayList(
                for: latex, style: display ? .display : .text, color: color)
        else { return nil }
        let options = RenderOptions(fontSize: fontSize, padding: display ? 6 : 1)
        let metrics = DisplayListRenderer.metrics(for: list, options: options)
        // Bound bitmap allocation for malformed/model-generated expressions.
        guard metrics.width.isFinite, metrics.height.isFinite,
            metrics.width * metrics.height < 4_000_000,
            let cgImage = SwaTexRender.ImageRenderer.image(
                for: list, options: options, displayScale: 2)
        else { return nil }
        let size = CGSize(width: metrics.width, height: metrics.height)
        let image = NSImage(cgImage: cgImage, size: size)
        let attachment = NSTextAttachment()
        attachment.attachmentCell = MarkdownMathCell(
            image: image, size: size, baseline: metrics.baseline)
        attachment.bounds = CGRect(
            x: 0, y: metrics.baseline - size.height, width: size.width, height: size.height)
        let text = NSMutableAttributedString(attachment: attachment)
        text.addAttribute(
            .markdownAlternative, value: latex,
            range: NSRange(location: 0, length: text.length))
        let immutable = NSAttributedString(attributedString: text)
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.setObject(immutable, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return immutable
    }
}

/// JS engines are confined to the main actor. Highlighting never determines fonts or spacing.
@MainActor
enum MarkdownHighlighter {
    private static let light: Highlightr? = make(theme: "xcode")
    private static let dark: Highlightr? = make(theme: "atom-one-dark")
    private static let cache = NSCache<NSString, NSAttributedString>()

    private static func make(theme: String) -> Highlightr? {
        let value = Highlightr()
        value?.setTheme(to: theme)
        return value
    }

    static func highlight(_ code: String, language: String, dark isDark: Bool) -> NSAttributedString
    {
        let key = "\(isDark)|\(language)|\(code)" as NSString
        if let value = cache.object(forKey: key) { return value }
        let aliases = [
            "js": "javascript", "ts": "typescript", "py": "python", "sh": "bash", "zsh": "bash",
            "shell": "bash", "yml": "yaml",
        ]
        let language = language.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        let highlighted =
            (isDark ? dark : light)?.highlight(
                code, as: language.isEmpty ? nil : (aliases[language] ?? language), fastRender: true
            )
        // Color ranges are usable only when highlighting preserved the literal source.
        let value = highlighted?.string == code ? highlighted! : NSAttributedString(string: code)
        cache.totalCostLimit = 4 * 1024 * 1024
        cache.setObject(value, forKey: key, cost: value.length * 4)
        return value
    }
}
