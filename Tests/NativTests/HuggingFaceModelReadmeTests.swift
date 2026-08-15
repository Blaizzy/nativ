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
        XCTAssertFalse(output.contains("    [Hugging Face]"))
        XCTAssertFalse(output.contains("    [GitHub]"))
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

    func testDisplayMarkdownConvertsHTMLTableIntoCompleteMarkdownRows() {
        let markdown = """
        <table>
          <thead><tr><th>Benchmark</th><th>Model A</th><th>Model B</th></tr></thead>
          <tbody>
            <tr><th>Coding Agent</th><td>88.8</td><td>84.6</td></tr>
            <tr><th colspan="3">Repository tasks</th></tr>
            <tr><td>NL2Repo</td><td>69.4</td><td>47.2</td></tr>
          </tbody>
        </table>
        """

        XCTAssertEqual(
            HuggingFaceModelReadmeFormatting.displayMarkdown(markdown),
            """
            | Benchmark | Model A | Model B |
            | --- | --- | --- |
            | **Coding Agent** | 88.8 | 84.6 |
            | **Repository tasks** |  |  |
            | NL2Repo | 69.4 | 47.2 |
            """
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
