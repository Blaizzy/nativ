import XCTest

final class HuggingFaceModelReadmeTests: XCTestCase {
    func testDisplayMarkdownRemovesModelCardFrontMatter() {
        let markdown = """
        ---
        license: apache-2.0
        tags:
          - mlx
        ---
        # Model title

        Model details.
        """

        XCTAssertEqual(
            HuggingFaceModelReadmeFormatting.displayMarkdown(markdown),
            "# Model title\n\nModel details."
        )
    }

    func testDisplayMarkdownPreservesMarkdownWithoutFrontMatter() {
        let markdown = "\n# Model title\r\n\r\nModel details.\n"

        XCTAssertEqual(
            HuggingFaceModelReadmeFormatting.displayMarkdown(markdown),
            "# Model title\n\nModel details."
        )
    }

    func testDisplayMarkdownConvertsCommonModelCardHTML() {
        let markdown = """
        <div align="center">
          <img src=https://ai.google.dev/gemma/images/gemma4_banner.png>
        </div>
        <p align="center">
          <a href="https://huggingface.co/google/gemma-4">Hugging Face</a> |
          <a href="https://github.com/google-deepmind/gemma">GitHub</a><br>
          <b>License:</b> Apache 2.0
        </p>
        """

        let output = HuggingFaceModelReadmeFormatting.displayMarkdown(markdown)
        XCTAssertTrue(output.contains("![](https://ai.google.dev/gemma/images/gemma4_banner.png)"))
        XCTAssertTrue(output.contains("[Hugging Face](https://huggingface.co/google/gemma-4)"))
        XCTAssertTrue(output.contains("[GitHub](https://github.com/google-deepmind/gemma)"))
        XCTAssertTrue(output.contains("**License:** Apache 2.0"))
        XCTAssertFalse(output.contains("<div"))
        XCTAssertFalse(output.contains("<a "))
    }

    func testDisplayMarkdownDoesNotRewriteHTMLInsideCodeFence() {
        let markdown = """
        ```html
        <div>Example</div>
        ```
        """

        XCTAssertEqual(
            HuggingFaceModelReadmeFormatting.displayMarkdown(markdown),
            markdown
        )
    }

    func testRemovingDuplicateLeadingTitleMatchesRepositoryName() {
        let markdown = """
        # North Micro Vision Instruct

        ![](banner.png)

        Model details.
        """

        XCTAssertEqual(
            HuggingFaceModelReadmeFormatting.removingDuplicateLeadingTitle(
                markdown,
                modelTitle: "North-Micro-Vision-Instruct"
            ),
            "![](banner.png)\n\nModel details."
        )
    }

    func testRemovingDuplicateLeadingTitlePreservesDifferentHeading() {
        let markdown = "# Usage\n\nRun the model."

        XCTAssertEqual(
            HuggingFaceModelReadmeFormatting.removingDuplicateLeadingTitle(
                markdown,
                modelTitle: "North-Micro-Vision-Instruct"
            ),
            markdown
        )
    }
}
