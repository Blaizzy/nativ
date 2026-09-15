import SwiftUI

struct ChatMarkdownRenderer: View {
  let messageID: UUID?
  let content: String
  let isStreaming: Bool
  let fontScale: Double

  var body: some View {
    MarkdownRenderer(
      content: ChatMarkdownCache.shared.renderedContent(
        for: messageID,
        content: content,
        isStreaming: isStreaming
      ),
      fontSize: ChatFontMetrics.baseBodyPointSize * fontScale
    )
    .transaction { $0.animation = nil }
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
