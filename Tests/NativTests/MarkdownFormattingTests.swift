import Foundation
import XCTest

final class MarkdownStreamingTests: XCTestCase {
    private func streaming(_ markdown: String) -> String {
        NativMarkdownFormatting.streamingMarkdown(of: markdown)
    }

    private func openFenceCount(in markdown: String) -> Int {
        var open = 0
        var marker: Character?
        var length = 0
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            guard let first = trimmed.first, first == "`" || first == "~" else { continue }
            let run = trimmed.prefix(while: { $0 == first }).count
            guard run >= 3 else { continue }
            if let active = marker {
                guard first == active, run >= length else { continue }
                guard trimmed.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) else {
                    continue
                }
                marker = nil
                open -= 1
            } else {
                marker = first
                length = run
                open += 1
            }
        }
        return open
    }

    func testEmptyInputIsUnchanged() {
        XCTAssertEqual(streaming(""), "")
    }

    func testTextWithoutFencesIsUnchanged() {
        let source = "# Title\n\nA partially written paragr"
        XCTAssertEqual(streaming(source), source)
    }

    func testBalancedFencesAreUnchanged() {
        let source = "Intro\n\n```swift\nlet a = 1\n```\n\nOutro"
        XCTAssertEqual(streaming(source), source)
    }

    func testOpenFenceIsClosedSoCodeRendersWhileStreaming() {
        XCTAssertEqual(
            streaming("Here:\n\n```swift\nlet a = 1\nlet b = 2"),
            "Here:\n\n```swift\nlet a = 1\nlet b = 2\n```"
        )
    }

    func testFenceOpenerWithoutBodyIsWithheld() {
        XCTAssertEqual(streaming("Intro\n\n```swift"), "Intro\n")
        XCTAssertEqual(streaming("Intro\n\n```swift\n"), "Intro\n")
        XCTAssertEqual(streaming("```"), "")
    }

    func testClosingFenceMatchesTheOpeningMarkerAndLength() {
        XCTAssertEqual(streaming("~~~\nx = 1"), "~~~\nx = 1\n~~~")
        XCTAssertEqual(streaming("````\nnested ``` here"), "````\nnested ``` here\n````")
    }

    func testOnlyTheLastUnclosedFenceIsClosed() {
        XCTAssertEqual(
            streaming("```\nfirst\n```\n\n```py\nsecond"),
            "```\nfirst\n```\n\n```py\nsecond\n```"
        )
    }

    func testBlankLinesInsideAFenceStayInsideIt() {
        XCTAssertEqual(streaming("```\nfirst\n\nsecond"), "```\nfirst\n\nsecond\n```")
    }

    func testEveryStreamPrefixRendersWithBalancedFences() {
        let corpus = [
            "# Report\n\nIntro line.\n\n```swift\nlet x = 1\n```\n\n- one\n- two\n\nDone.",
            "no fences at all, just prose",
            "~~~\nraw\n~~~\n\nmore text\n\n> a quote",
            "````\nouter\n```\ninner\n```\n````\ntail",
            "text\n\n   ```js\n   indented()\n   ```\n\nend"
        ]
        for text in corpus {
            for length in 1...text.count {
                let source = String(text.prefix(length))
                XCTAssertEqual(
                    openFenceCount(in: streaming(source)),
                    0,
                    "unbalanced fence at length \(length) of \(text.debugDescription)"
                )
            }
        }
    }

    func testEveryStreamPrefixOnlyAddsAClosingFenceOrTrimsAnEmptyOpener() {
        let text = "Intro\n\n```swift\nlet x = 1\n```\n\nOutro\n\n~~~\ntail"
        for length in 1...text.count {
            let source = String(text.prefix(length))
            let result = streaming(source)
            let addedClosing = result.hasPrefix(source)
            let trimmedOpener = source.hasPrefix(result)
            XCTAssertTrue(
                addedClosing || trimmedOpener,
                "result diverged from the source at length \(length)"
            )
        }
    }

    func testCompletedMarkdownIsNeverAltered() {
        let text = "# Report\n\nIntro line.\n\n```swift\nlet x = 1\n```\n\n- one\n- two\n"
        XCTAssertEqual(streaming(text), text)
    }
}
