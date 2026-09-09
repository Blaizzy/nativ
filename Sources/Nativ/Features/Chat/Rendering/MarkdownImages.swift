import AppKit
import ImageIO

struct MarkdownImageRequest: Hashable {
    let markdown: String
    let baseURL: URL?

    var urls: [URL] {
        var urls = Set<URL>()
        func collect(_ nodes: [MarkdownNode]) {
            for node in nodes {
                if node.kind == "image",
                    let url = URL(string: node.destination, relativeTo: baseURL)?.absoluteURL,
                    ["https", "http", "file"].contains(url.scheme?.lowercased() ?? "")
                {
                    urls.insert(url)
                }
                collect(node.children)
            }
        }
        collect(MarkdownParser.parse(markdown))
        return urls.sorted { $0.absoluteString < $1.absoluteString }
    }
}

/// Immutable resources participate in the layout key. Loading never mutates a measured attachment.
struct MarkdownImages: Hashable {
    static let empty = MarkdownImages(values: [:])
    private let identity = UUID()
    let values: [URL: NSImage]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    func hash(into hasher: inout Hasher) { hasher.combine(identity) }

    @MainActor
    static func load(
        _ request: MarkdownImageRequest,
        loader: MarkdownImageLoader = .shared
    ) async -> MarkdownImages {
        let urls = request.urls
        guard !urls.isEmpty else { return .empty }
        let data = await withTaskGroup(of: (URL, Data?).self) { group in
            var remaining = urls.makeIterator()
            func enqueue(_ url: URL) {
                group.addTask { (url, try? await loader.data(for: url)) }
            }
            for _ in 0 ..< min(4, urls.count) {
                if let url = remaining.next() { enqueue(url) }
            }
            var result: [URL: Data] = [:]
            while let (url, bytes) = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return result
                }
                result[url] = bytes
                if let next = remaining.next() { enqueue(next) }
            }
            return result
        }
        guard !Task.isCancelled else { return .empty }
        let values = data.compactMapValues(decode)
        return values.isEmpty ? .empty : MarkdownImages(values: values)
    }

    @MainActor
    static func decode(_ data: Data) -> NSImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                ] as CFDictionary)
        {
            // Thumbnail pixels are bounded; retain the original display size and orientation.
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            let size =
                orientation >= 5
                ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
            return NSImage(cgImage: thumbnail, size: size)
        }
        // AppKit also understands document image formats not decoded by ImageIO.
        guard let image = NSImage(data: data), image.size.width.isFinite,
            image.size.height.isFinite, image.size.width > 0, image.size.height > 0
        else { return nil }
        return image
    }

    @MainActor
    func attachment(url: URL, label: String, width: CGFloat) -> NSAttributedString? {
        guard let image = values[url] else { return nil }
        let text = NSMutableAttributedString(
            attachment: Self.attachment(image: image, width: width))
        text.addAttributes(
            [
                .markdownDocumentImage: image,
                .markdownAlternative: label,
            ], range: NSRange(location: 0, length: text.length))
        return text
    }

    @MainActor
    private static func attachment(image: NSImage, width: CGFloat) -> NSTextAttachment {
        let scale = min(1, max(1, width) / max(1, image.size.width))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let displayed = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        let attachment = NSTextAttachment()
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: displayed)
        attachment.bounds = CGRect(origin: .zero, size: size)
        return attachment
    }

    /// Fitted table columns can be narrower than their first intrinsic measurement.
    @MainActor
    static func fittingAttachments(in text: NSAttributedString, width: CGFloat)
        -> NSAttributedString
    {
        let result = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(
            .markdownDocumentImage, in: NSRange(location: 0, length: text.length)
        ) { image, range, _ in
            guard let image = image as? NSImage else { return }
            result.addAttribute(
                .attachment, value: attachment(image: image, width: width), range: range)
        }
        return result
    }
}

extension NSAttributedString.Key {
    static let markdownDocumentImage = NSAttributedString.Key(
        "dev.nativ.markdown.documentImage")
}

actor MarkdownImageLoader {
    static let shared = MarkdownImageLoader()
    private let session: URLSession
    private let cache = NSCache<NSURL, NSData>()

    init(session: URLSession = .shared) {
        self.session = session
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.countLimit = 128
    }

    func data(for url: URL) async throws -> Data {
        try Task.checkCancellation()
        if let data = cache.object(forKey: url as NSURL) { return data as Data }
        let data: Data
        if url.isFileURL {
            data = try await Task.detached(priority: .utility) {
                try Data(contentsOf: url, options: .mappedIfSafe)
            }.value
        } else {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw URLError(.unsupportedURL)
            }
            let response: URLResponse
            (data, response) = try await session.data(
                for: URLRequest(url: url, timeoutInterval: 20))
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode)
            else {
                throw URLError(.badServerResponse)
            }
        }
        try Task.checkCancellation()
        guard data.count <= 24 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        return data
    }
}
