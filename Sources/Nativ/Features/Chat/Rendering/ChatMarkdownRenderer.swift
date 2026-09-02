import AppKit
import Highlightr
import MarkdownUI
import SwaTex
import SwaTexRender
import SwiftUI

struct ChatMarkdownRenderer: View {
  let messageID: UUID?
  let content: String
  let isStreaming: Bool
  let fontScale: Double

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let renderedContent = ChatMarkdownCache.shared.renderedContent(
      for: messageID,
      content: content,
      isStreaming: isStreaming
    )
    let markdown = Markdown(MarkdownContent(renderedContent))
      .markdownTheme(.nativChat)
      .markdownCodeSyntaxHighlighter(ChatCodeHighlighter.forScheme(colorScheme))
      .markdownInlineImageProvider(
        MathInlineProvider(
          fontSize: ChatFontMetrics.baseBodyPointSize * fontScale,
          color: mathColor
        )
      )
      .markdownImageProvider(
        MathBlockProvider(
          fontSize: (ChatFontMetrics.baseBodyPointSize + 2) * fontScale,
          color: mathColor
        )
      )
      .textSelection(.enabled)
      .font(ChatFontMetrics.bodyFont(scale: fontScale))

    if isStreaming {
      markdown
        .geometryGroup()
        .transaction { transaction in
          transaction.animation = nil
        }
    } else {
      markdown
    }
  }

  private var mathColor: NSColor {
    colorScheme == .dark
      ? NSColor(white: 0.92, alpha: 1)
      : NSColor(white: 0.12, alpha: 1)
  }
}

extension MarkdownUI.Theme {
  static var nativChat: MarkdownUI.Theme {
    MarkdownUI.Theme.gitHub
      .text {
        BackgroundColor(nil)
        FontSize(16)
      }
  }
}

@MainActor
final class ChatMarkdownCache {
  static let shared = ChatMarkdownCache()

  private struct Entry {
    let content: String
    let renderedContent: String
  }

  private var entries: [UUID: Entry] = [:]
  private var order: [UUID] = []
  private let capacity: Int

  init(capacity: Int = 256) {
    self.capacity = capacity
  }

  func renderedContent(
    for id: UUID?,
    content: String,
    isStreaming: Bool
  ) -> String {
    if isStreaming {
      return Self.preprocessStreamingFlush(content)
    }

    guard let id else {
      return MathPreprocessor.preprocess(content)
    }
    if let entry = entries[id], entry.content == content {
      touch(id)
      return entry.renderedContent
    }

    let renderedContent = MathPreprocessor.preprocess(content)
    entries[id] = Entry(content: content, renderedContent: renderedContent)
    touch(id)
    evictIfNeeded()
    return renderedContent
  }

  private static func preprocessStreamingFlush(_ text: String) -> String {
    let dollarCount = text.reduce(into: 0) { count, character in
      if character == "$" {
        count += 1
      }
    }
    guard !dollarCount.isMultiple(of: 2),
      let lastDollar = text.lastIndex(of: "$")
    else {
      return MathPreprocessor.preprocess(text)
    }

    let stable = String(text[..<lastDollar])
    let held = String(text[lastDollar...])
    return MathPreprocessor.preprocess(stable) + held
  }

  private func touch(_ id: UUID) {
    if let index = order.firstIndex(of: id) {
      order.remove(at: index)
    }
    order.append(id)
  }

  private func evictIfNeeded() {
    while order.count > capacity {
      entries.removeValue(forKey: order.removeFirst())
    }
  }
}

final class ChatCodeHighlighter: CodeSyntaxHighlighter, @unchecked Sendable {
  static let light = ChatCodeHighlighter(theme: "xcode")
  static let dark = ChatCodeHighlighter(theme: "atom-one-dark")

  static func forScheme(_ scheme: ColorScheme) -> ChatCodeHighlighter {
    scheme == .dark ? .dark : .light
  }

  private let highlightr: Highlightr?
  private var cache: [String: Text] = [:]

  private init(theme: String) {
    let highlightr = Highlightr()
    highlightr?.setTheme(to: theme)
    self.highlightr = highlightr
  }

  func highlightCode(_ code: String, language: String?) -> Text {
    let key = (language ?? "") + "\u{0}" + code
    if let cached = cache[key] {
      return cached
    }

    guard let highlightr,
      let highlighted = highlightr.highlight(
        code,
        as: normalized(language),
        fastRender: true
      ),
      let attributed = try? AttributedString(highlighted, including: \.appKit)
    else {
      return Text(code)
    }

    let text = Text(attributed)
    if cache.count > 300 {
      cache.removeAll(keepingCapacity: true)
    }
    cache[key] = text
    return text
  }

  private func normalized(_ language: String?) -> String? {
    guard let language = language?.lowercased(), !language.isEmpty else {
      return nil
    }
    switch language {
    case "js":
      return "javascript"
    case "ts":
      return "typescript"
    case "py":
      return "python"
    case "sh", "zsh", "shell":
      return "bash"
    case "yml":
      return "yaml"
    default:
      return language
    }
  }
}

enum MathRenderer {
  nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()
  private static let retinaScale: CGFloat = 2

  static func render(
    base64URL encoded: String,
    display: Bool,
    fontSize: CGFloat,
    color: NSColor
  ) -> NSImage {
    let key = "\(display ? "d" : "i")|\(fontSize)|\(color.description)|\(encoded)" as NSString
    if let cached = cache.object(forKey: key) {
      return cached
    }

    let latex = MathPreprocessor.decodeBase64URL(encoded) ?? ""
    let options = RenderOptions(fontSize: fontSize, padding: display ? 6 : 1)
    let style: MathStyle = display ? .display : .text
    let ink = swatexColor(from: color)

    let final: NSImage
    if let cgImage = try? ImageRenderer.image(
      latex: latex,
      style: style,
      color: ink,
      options: options,
      displayScale: retinaScale
    ) {
      let pointSize = NSSize(
        width: CGFloat(cgImage.width) / retinaScale,
        height: CGFloat(cgImage.height) / retinaScale
      )
      final = NSImage(cgImage: cgImage, size: pointSize)
    } else {
      final = literalImage(text: latex.isEmpty ? "math" : latex, color: color)
    }
    cache.setObject(final, forKey: key)
    return final
  }

  private static func swatexColor(from color: NSColor) -> SwaTex.Color {
    let rgb = color.usingColorSpace(.sRGB) ?? color
    return SwaTex.Color(
      r: Float(rgb.redComponent),
      g: Float(rgb.greenComponent),
      b: Float(rgb.blueComponent),
      a: Float(rgb.alphaComponent)
    )
  }

  private static func literalImage(text: String, color: NSColor) -> NSImage {
    let attributed = NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        .foregroundColor: color,
      ]
    )
    var size = attributed.size()
    size.width = max(size.width, 4)
    size.height = max(size.height, 4)
    return NSImage(size: size, flipped: false) { rect in
      attributed.draw(in: rect)
      return true
    }
  }
}

struct MathInlineProvider: InlineImageProvider {
  let fontSize: CGFloat
  let color: NSColor

  struct UnsupportedURL: Error {}

  func image(with url: URL, label: String) async throws -> Image {
    guard url.scheme == "swiftmath" else {
      throw UnsupportedURL()
    }
    let encoded = String(url.path.dropFirst())
    let nsImage = MathRenderer.render(
      base64URL: encoded,
      display: (url.host ?? "") == "d",
      fontSize: fontSize,
      color: color
    )
    return Image(nsImage: nsImage)
  }
}

struct MathBlockProvider: ImageProvider {
  let fontSize: CGFloat
  let color: NSColor

  @ViewBuilder
  func makeImage(url: URL?) -> some View {
    if let url, url.scheme == "swiftmath" {
      let nsImage = MathRenderer.render(
        base64URL: String(url.path.dropFirst()),
        display: (url.host ?? "") == "d",
        fontSize: fontSize,
        color: color
      )
      if nsImage.size.width > 720 {
        ScrollView(.horizontal, showsIndicators: true) {
          Image(nsImage: nsImage)
            .padding(.vertical, 4)
        }
      } else {
        Image(nsImage: nsImage)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 4)
      }
    } else if let url {
      Link(url.absoluteString, destination: url)
    } else {
      EmptyView()
    }
  }
}
