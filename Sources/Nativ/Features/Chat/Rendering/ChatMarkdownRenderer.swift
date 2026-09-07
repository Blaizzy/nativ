import AppKit
import Highlightr
import MarkdownUI
import SwiftUI

struct ChatMarkdownRenderer: View {
  let messageID: UUID?
  let content: String
  let isStreaming: Bool
  let fontScale: Double

  var body: some View {
    let renderedContent = ChatMarkdownCache.shared.renderedContent(
      for: messageID,
      content: content,
      isStreaming: isStreaming
    )
    let markdown = NativMarkdownRenderer(
      content: renderedContent,
      font: ChatFontMetrics.bodyFont(scale: fontScale),
      fontSize: ChatFontMetrics.baseBodyPointSize * fontScale
    )

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
