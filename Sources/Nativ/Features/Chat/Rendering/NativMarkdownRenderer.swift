import AppKit
@preconcurrency import MarkdownUI
import SwaTex
import SwaTexRender
import SwiftUI

struct NativMarkdownRenderer: View {
  enum ImagePolicy: Equatable {
    case mathOnly
    case document
  }

  @Environment(\.colorScheme) private var colorScheme

  let content: String
  let baseURL: URL?
  let font: Font
  let fontSize: CGFloat
  let imagePolicy: ImagePolicy
  let fitsTablesToWidth: Bool

  init(
    content: String,
    baseURL: URL? = nil,
    font: Font,
    fontSize: CGFloat,
    imagePolicy: ImagePolicy = .mathOnly,
    fitsTablesToWidth: Bool = false
  ) {
    self.content = content
    self.baseURL = baseURL
    self.font = font
    self.fontSize = fontSize
    self.imagePolicy = imagePolicy
    self.fitsTablesToWidth = fitsTablesToWidth
  }

  var body: some View {
    Markdown(
      MarkdownContent(content),
      baseURL: baseURL,
      imageBaseURL: baseURL
    )
    .markdownTheme(
      .nativMarkdown(
        fontSize: fontSize,
        fitsTablesToWidth: fitsTablesToWidth
      )
    )
    .markdownCodeSyntaxHighlighter(ChatCodeHighlighter.forScheme(colorScheme))
    .markdownInlineImageProvider(
      NativMarkdownInlineImageProvider(
        fontSize: fontSize,
        color: mathColor,
        policy: imagePolicy
      )
    )
    .markdownImageProvider(
      NativMarkdownImageProvider(
        fontSize: fontSize + 2,
        color: mathColor,
        policy: imagePolicy
      )
    )
    .textSelection(.enabled)
    .font(font)
  }

  private var mathColor: NSColor {
    colorScheme == .dark
      ? NSColor(white: 0.92, alpha: 1)
      : NSColor(white: 0.12, alpha: 1)
  }
}

extension MarkdownUI.Theme {
  static func nativMarkdown(
    fontSize: CGFloat,
    fitsTablesToWidth: Bool = false
  ) -> MarkdownUI.Theme {
    let theme = MarkdownUI.Theme.gitHub
      .text {
        BackgroundColor(nil)
        FontSize(fontSize)
      }

    guard fitsTablesToWidth else { return theme }
    return theme.table { configuration in
      NativMarkdownFittedTable(content: configuration.label)
    }
  }

  static func nativChat(fontScale: Double) -> MarkdownUI.Theme {
    nativMarkdown(fontSize: ChatFontMetrics.baseBodyPointSize * fontScale)
  }
}

private struct NativMarkdownFittedTable<Content: View>: View {
  // MarkdownUI stores theme builders outside the main actor. SwiftUI still reads
  // this immutable label only from `body` on the main actor.
  nonisolated(unsafe) private let content: Content

  nonisolated init(content: Content) {
    self.content = content
  }

  var body: some View {
    content
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .markdownTableBorderStyle(
        .init(color: Color.secondary.opacity(0.25))
      )
      .markdownTableBackgroundStyle(
        .alternatingRows(
          Color.clear,
          Color.secondary.opacity(0.06)
        )
      )
      .markdownMargin(top: 0, bottom: 16)
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

struct NativMarkdownInlineImageProvider: InlineImageProvider {
  struct UnsupportedURL: Error {}

  let fontSize: CGFloat
  let color: NSColor
  let policy: NativMarkdownRenderer.ImagePolicy

  func image(with url: URL, label: String) async throws -> Image {
    if url.scheme == "swiftmath" {
      let nsImage = MathRenderer.render(
        base64URL: String(url.path.dropFirst()),
        display: (url.host ?? "") == "d",
        fontSize: fontSize,
        color: color
      )
      return Image(nsImage: nsImage)
    }

    guard policy == .document else {
      throw UnsupportedURL()
    }
    if url.isFileURL {
      let data = try await Task.detached(priority: .utility) {
        try Data(contentsOf: url)
      }.value
      guard let image = NSImage(data: data) else {
        throw URLError(.cannotDecodeContentData)
      }
      return Image(nsImage: image)
    }
    return try await DefaultInlineImageProvider.default.image(with: url, label: label)
  }
}

struct NativMarkdownImageProvider: ImageProvider {
  let fontSize: CGFloat
  let color: NSColor
  let policy: NativMarkdownRenderer.ImagePolicy

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
    } else if policy == .document {
      if let url, url.isFileURL {
        NativLocalMarkdownImage(url: url)
      } else {
        DefaultImageProvider.default.makeImage(url: url)
      }
    } else if let url {
      Link(url.absoluteString, destination: url)
    } else {
      EmptyView()
    }
  }
}

private struct NativLocalMarkdownImage: View {
  let url: URL

  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
      } else {
        Color.clear
          .frame(width: 0, height: 0)
      }
    }
    .task(id: url) {
      let data = try? await Task.detached(priority: .utility) {
        try Data(contentsOf: url)
      }.value
      guard !Task.isCancelled else { return }
      image = data.flatMap(NSImage.init(data:))
    }
  }
}
