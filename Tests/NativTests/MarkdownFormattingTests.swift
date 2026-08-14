import XCTest

final class MarkdownFormattingTests: XCTestCase {
    func testStreamingDocumentWaitsForFollowingBlockBeforeFreezingBoundary() {
        let awaitingNextBlock = NativMarkdownFormatting.streamingDocument(
            in: "First paragraph.\n\n",
            minimumChunkLength: 1
        )

        XCTAssertTrue(awaitingNextBlock.completedChunks.isEmpty)
        XCTAssertEqual(awaitingNextBlock.tail, "First paragraph.\n\n")

        let nextBlockStarted = NativMarkdownFormatting.streamingDocument(
            in: "First paragraph.\n\nSecond",
            minimumChunkLength: 1
        )

        XCTAssertEqual(
            nextBlockStarted.completedChunks.map(\.markdown),
            ["First paragraph.\n\n"]
        )
        XCTAssertEqual(nextBlockStarted.tail, "Second")
    }

    func testStreamingDocumentKeepsCompletedChunkIdentityStableAsContentAppends() throws {
        let prefix = "First paragraph is long enough.\n\nSecond"
        let initial = NativMarkdownFormatting.streamingDocument(
            in: prefix,
            minimumChunkLength: 12
        )
        let initialChunk = try XCTUnwrap(initial.completedChunks.first)

        let appended = NativMarkdownFormatting.streamingDocument(
            in: prefix + " paragraph.\n\nThird",
            minimumChunkLength: 12
        )

        XCTAssertEqual(appended.completedChunks.first, initialChunk)
        XCTAssertEqual(reconstructedMarkdown(from: appended), prefix + " paragraph.\n\nThird")
    }

    func testStreamingDocumentGroupsSmallBlocksUntilTargetLength() {
        let document = NativMarkdownFormatting.streamingDocument(
            in: "One.\n\nTwo.\n\nThree.",
            minimumChunkLength: 10
        )

        XCTAssertEqual(document.completedChunks.map(\.markdown), ["One.\n\nTwo.\n\n"])
        XCTAssertEqual(document.tail, "Three.")
    }

    func testStreamingDocumentDoesNotSplitInsideFencedCodeBlock() {
        let markdown = """
        ```swift
        let first = 1

        let second = 2
        ```

        Following paragraph
        """
        let document = NativMarkdownFormatting.streamingDocument(
            in: markdown,
            minimumChunkLength: 1
        )

        XCTAssertEqual(document.completedChunks.count, 1)
        XCTAssertTrue(document.completedChunks[0].markdown.hasSuffix("```\n\n"))
        XCTAssertEqual(document.tail, "Following paragraph")
        XCTAssertEqual(reconstructedMarkdown(from: document), markdown)
    }

    func testStreamingDocumentKeepsUnclosedFenceInMutableTail() {
        let markdown = """
        ```swift
        let first = 1

        let second = 2
        """
        let document = NativMarkdownFormatting.streamingDocument(
            in: markdown,
            minimumChunkLength: 1
        )

        XCTAssertTrue(document.completedChunks.isEmpty)
        XCTAssertEqual(document.tail, markdown)
    }

    func testStreamingDocumentDoesNotSplitLooseListItems() {
        let markdown = """
        - First item

        - Second item

        Following paragraph
        """
        let document = NativMarkdownFormatting.streamingDocument(
            in: markdown,
            minimumChunkLength: 1
        )

        XCTAssertEqual(document.completedChunks.count, 1)
        XCTAssertEqual(
            document.completedChunks[0].markdown,
            "- First item\n\n- Second item\n\n"
        )
        XCTAssertEqual(document.tail, "Following paragraph")
    }

    func testStreamingDocumentFreezesWholeTable() {
        let markdown = """
        | Name | Value |
        | --- | ---: |
        | Alpha | 1 |
        | Beta | 2 |

        Following paragraph
        """
        let document = NativMarkdownFormatting.streamingDocument(
            in: markdown,
            minimumChunkLength: 1
        )

        XCTAssertEqual(document.completedChunks.count, 1)
        XCTAssertTrue(document.completedChunks[0].markdown.contains("| Beta | 2 |"))
        XCTAssertEqual(document.tail, "Following paragraph")
        XCTAssertEqual(reconstructedMarkdown(from: document), markdown)
    }

    func testStreamingDocumentDoesNotSplitInsideDollarMathBlock() {
        let markdown = """
        $$
        a + b

        = c
        $$

        Following paragraph
        """
        let document = NativMarkdownFormatting.streamingDocument(
            in: markdown,
            minimumChunkLength: 1
        )

        XCTAssertEqual(document.completedChunks.count, 1)
        XCTAssertTrue(document.completedChunks[0].markdown.hasSuffix("$$\n\n"))
        XCTAssertEqual(document.tail, "Following paragraph")
    }

    func testStreamingDocumentDoesNotSplitInsideMultilineDollarMathBlock() {
        let markdown = """
        $$a + b

        = c$$

        Following paragraph
        """
        let document = NativMarkdownFormatting.streamingDocument(
            in: markdown,
            minimumChunkLength: 1
        )

        XCTAssertEqual(document.completedChunks.count, 1)
        XCTAssertTrue(document.completedChunks[0].markdown.hasSuffix("= c$$\n\n"))
        XCTAssertEqual(document.tail, "Following paragraph")
    }

    func testStreamingDocumentDoesNotSplitInsideBracketMathBlock() {
        let markdown = #"""
        \[
        a + b

        = c
        \]

        Following paragraph
        """#
        let document = NativMarkdownFormatting.streamingDocument(
            in: markdown,
            minimumChunkLength: 1
        )

        XCTAssertEqual(document.completedChunks.count, 1)
        XCTAssertTrue(document.completedChunks[0].markdown.hasSuffix("\\]\n\n"))
        XCTAssertEqual(document.tail, "Following paragraph")
    }

    private func reconstructedMarkdown(
        from document: NativStreamingMarkdownDocument
    ) -> String {
        document.completedChunks.map(\.markdown).joined() + document.tail
    }
}
