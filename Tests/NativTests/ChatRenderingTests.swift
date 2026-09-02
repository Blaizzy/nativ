import MarkdownUI
import SwiftUI
import XCTest

final class ChatMarkdownRendererTests: XCTestCase {
  func testChatThemeDoesNotPaintASeparateDocumentCanvas() {
    XCTAssertNil(Theme.nativChat(fontScale: 1).textBackgroundColor)
  }

  @MainActor
  func testLongMarkdownUsesItsCompleteIntrinsicHeight() throws {
    let section = """
      ## Efficient streaming

      This paragraph contains **bold text**, `inline code`, and a [link](https://example.com).

      - First item with enough text to wrap naturally across the available width.
      - Second item with more content and an inline expression $x^2 + y^2$.

      ```swift
      struct Message: Identifiable {
          let id: UUID
          let content: String
      }
      ```

      """
    let markdown = Array(repeating: section, count: 80).joined(separator: "\n")
    let renderer = ImageRenderer(
      content: ChatMarkdownRenderer(
        messageID: UUID(),
        content: markdown,
        isStreaming: false,
        fontScale: 1
      )
      .frame(width: 560)
      .fixedSize(horizontal: false, vertical: true)
    )
    renderer.proposedSize = ProposedViewSize(width: 560, height: nil)

    let image = try XCTUnwrap(renderer.nsImage)
    XCTAssertGreaterThan(image.size.height, 8_000)
    XCTAssertGreaterThan(markdown.count, 25_000)
  }

  @MainActor
  func testStreamingAndCompletedMarkdownBothRender() throws {
    let content = """
      # Streaming

      Content grows without assigning a fixed row height.

      $$E = mc^2$$
      """

    for isStreaming in [true, false] {
      let renderer = ImageRenderer(
        content: ChatMarkdownRenderer(
          messageID: UUID(),
          content: content,
          isStreaming: isStreaming,
          fontScale: 1
        )
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
      )
      renderer.proposedSize = ProposedViewSize(width: 560, height: nil)

      let image = try XCTUnwrap(renderer.nsImage)
      XCTAssertGreaterThan(image.size.height, 40)
    }
  }

  @MainActor
  func testFontScaleChangesMarkdownHeight() throws {
    let content = Array(
      repeating: "Font scaling should resize rendered Markdown along with the rest of Chat.",
      count: 12
    ).joined(separator: " ")

    let compactHeight = try renderedHeight(content: content, fontScale: 0.85)
    let largeHeight = try renderedHeight(content: content, fontScale: 1.5)

    XCTAssertGreaterThan(largeHeight, compactHeight)
  }

  @MainActor
  func testFontScaleChangesHighlightedCodeHeight() throws {
    let lines = Array(
      repeating: "let renderedMessage = ChatMarkdownRenderer()",
      count: 12
    ).joined(separator: "\n")
    let content = "```swift\n\(lines)\n```"

    let compactHeight = try renderedHeight(content: content, fontScale: 0.85)
    let largeHeight = try renderedHeight(content: content, fontScale: 1.5)

    XCTAssertGreaterThan(largeHeight, compactHeight)
  }

  @MainActor
  private func renderedHeight(content: String, fontScale: Double) throws -> CGFloat {
    let renderer = ImageRenderer(
      content: ChatMarkdownRenderer(
        messageID: UUID(),
        content: content,
        isStreaming: false,
        fontScale: fontScale
      )
      .frame(width: 260)
      .fixedSize(horizontal: false, vertical: true)
    )
    renderer.proposedSize = ProposedViewSize(width: 260, height: nil)

    return try XCTUnwrap(renderer.nsImage).size.height
  }
}
