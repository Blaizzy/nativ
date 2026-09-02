import MarkdownUI
import SwiftUI
import XCTest

final class ChatMarkdownRendererTests: XCTestCase {
  func testChatThemeDoesNotPaintASeparateDocumentCanvas() {
    XCTAssertNil(Theme.nativChat.textBackgroundColor)
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
}

final class ChatStreamingRenderPolicyTests: XCTestCase {
  func testStreamingUsesSmoothTwentyHertzCadence() {
    XCTAssertEqual(ChatStreamingRenderPolicy.updatesPerSecond, 20)
    XCTAssertEqual(
      ChatStreamingRenderPolicy.flushInterval,
      .seconds(1.0 / 20.0)
    )
  }
}
