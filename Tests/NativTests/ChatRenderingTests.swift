import AppKit
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
  func testDocumentRendererRendersWideTable() throws {
    let content = """
      | Model | Context | Quantization | Architecture | Notes |
      | --- | ---: | --- | --- | --- |
      | Example | 131072 | 4-bit | Mixture of experts | A deliberately wide table value |
      """
    let renderer = ImageRenderer(
      content: NativMarkdownRenderer(
        content: content,
        font: .system(size: 15),
        fontSize: 15,
        imagePolicy: .document,
        scrollsWideTables: true
      )
      .frame(width: 260)
      .fixedSize(horizontal: false, vertical: true)
    )
    renderer.proposedSize = ProposedViewSize(width: 260, height: nil)

    let image = try XCTUnwrap(renderer.nsImage)
    XCTAssertGreaterThan(image.size.height, 20)
  }

  func testDocumentImageProviderLoadsLocalInlineImage() async throws {
    let pngData = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )
    )
    let imageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("png")
    try pngData.write(to: imageURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: imageURL) }

    let provider = NativMarkdownInlineImageProvider(
      fontSize: 15,
      color: .labelColor,
      policy: .document
    )

    _ = try await provider.image(with: imageURL, label: "Local image")
  }

  func testMathOnlyImageProviderRejectsDocumentImages() async {
    let provider = NativMarkdownInlineImageProvider(
      fontSize: 15,
      color: .labelColor,
      policy: .mathOnly
    )

    do {
      _ = try await provider.image(
        with: URL(string: "https://example.com/image.png")!,
        label: "Remote image"
      )
      XCTFail("The math-only provider should not fetch document images")
    } catch is NativMarkdownInlineImageProvider.UnsupportedURL {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
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

final class ChatStreamingRenderPolicyTests: XCTestCase {
  func testStreamingUsesSmoothTwentyHertzCadence() {
    XCTAssertEqual(ChatStreamingRenderPolicy.updatesPerSecond, 20)
    XCTAssertEqual(
      ChatStreamingRenderPolicy.flushInterval,
      .seconds(1.0 / 20.0)
    )
  }
}
