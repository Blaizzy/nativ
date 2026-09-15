enum MarkdownFixtures {
    static let short =
        "A short reply with **bold**, *emphasis*, ~~strike~~, `inline code`, and a [link](https://example.com)."
    static let sample = #"""
        ## Predictable Markdown geometry

        This paragraph wraps with **bold**, *emphasis*, ***both***, ~~strikethrough~~, and `inline code`. Follow a [reference link][reference]. Text should stay selectable after resizing the window.

        日本語の文章と中文用于验证换行。 العربية تُقرأ من اليمين إلى اليسار. Emoji: 👩🏽‍💻 👨‍👩‍👧‍👦 and combining marks: café.

        - A list item that is deliberately long enough to wrap at narrow widths while preserving its hanging indentation.
          - A nested item with $x^2 + y^2 = z^2$.
          - Another nested item.
        - [x] Completed task
        - [ ] Pending task

        7. An ordered list starting at seven.
        8. The following item.

        > A quotation can wrap over several lines.
        >
        > It can contain **multiple paragraphs** and a nested list:
        > - One
        > - Two

        ```swift
        struct Message: Identifiable {
            let id: UUID
            let content: String
            let deliberatelyLongLine = "Horizontal scrolling should not resize the transcript or swallow vertical wheel events."
        }
        ```

        | Model | Context | Notes |
        | :--- | ---: | :---: |
        | **Small** | 8192 | A short description |
        | Large | 131072 | A longer value that wraps when the table is fitted to the available width |

        Inline math: $\frac{a+b}{c}$ next to ordinary text, and display math:

        $$\int_0^1 x^2\,dx = \frac{1}{3}$$

        A hard break follows here.  
        This is a new line. Another<br>HTML line break.

        ---

        [reference]: https://example.com
        """#
}
