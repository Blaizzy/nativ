import Foundation
import XCTest

final class MarkdownStreamingSplitTests: XCTestCase {
    private func split(_ markdown: String) -> NativMarkdownFormatting.StreamingSplit {
        NativMarkdownFormatting.streamingSplit(of: markdown)
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
                guard first == active, run >= length,
                      trimmed.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" })
                else { continue }
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

    func testEmptyInputSplitsIntoNothing() {
        XCTAssertEqual(split(""), .init(settled: "", pending: ""))
    }

    func testAnIncompleteFirstBlockStaysPending() {
        XCTAssertEqual(
            split("Intro line one\nline two partia"),
            .init(settled: "", pending: "Intro line one\nline two partia")
        )
    }

    func testCompletedBlocksSettle() {
        XCTAssertEqual(
            split("## Title\n\n- one\n- tw"),
            .init(settled: "## Title\n", pending: "- one\n- tw")
        )
    }

    func testMidParagraphNeverSplits() {
        let result = split("First para.\n\nSecond para keeps\ngrowing here")
        XCTAssertEqual(result.settled, "First para.\n")
        XCTAssertEqual(result.pending, "Second para keeps\ngrowing here")
    }

    func testOpenFenceSettlesWithAVirtualClose() {
        let result = split("Here:\n\n```swift\nlet a = 1\nlet b = 2")
        XCTAssertEqual(result.pending, "")
        XCTAssertTrue(result.settled.hasSuffix("\n```"))
        XCTAssertTrue(result.settled.contains("let b = 2"))
    }

    func testFenceOpenerWithoutBodyDoesNotEmitAnEmptyCodeBlock() {
        let result = split("Intro\n\n```swift")
        XCTAssertEqual(result.settled, "Intro\n")
        XCTAssertEqual(result.pending, "```swift")
    }

    func testClosingFenceMatchesTheOpeningMarkerAndLength() {
        XCTAssertTrue(split("~~~\nx = 1").settled.hasSuffix("\n~~~"))
        XCTAssertTrue(split("````\nnested ``` here").settled.hasSuffix("\n````"))
    }

    func testAClosedFenceIsABlockBoundary() {
        XCTAssertEqual(
            split("```\ncode\n```\nAfter tex"),
            .init(settled: "```\ncode\n```", pending: "After tex")
        )
    }

    func testBlankLinesInsideAFenceStayInsideIt() {
        XCTAssertTrue(split("```\nfirst\n\nsecond").settled.contains("first\n\nsecond"))
    }

    func testSettledMarkdownAlwaysHasBalancedFences() {
        let corpus = [
            "# Report\n\nIntro line.\n\n```swift\nlet x = 1\n```\n\n- one\n- two\n\nDone.",
            "no fences at all, just prose",
            "~~~\nraw\n~~~\n\nmore text\n\n> a quote",
            "````\nouter\n```\ninner\n```\n````\ntail",
            "text\n\n   ```js\n   indented()\n   ```\n\nend"
        ]
        for text in corpus {
            for length in 1...text.count {
                let result = split(String(text.prefix(length)))
                XCTAssertEqual(
                    openFenceCount(in: result.settled),
                    0,
                    "unbalanced settled fence at length \(length) of \(text.debugDescription)"
                )
            }
        }
    }

    func testSettledGrowsMonotonicallyAndNeverLosesContent() {
        let text = "# Report\n\nIntro line.\n\n```swift\nlet x = 1\n```\n\n- one\n- two\n\nDone."
        var previousSettledLength = 0
        for length in 1...text.count {
            let source = String(text.prefix(length))
            let result = split(source)

            var sourceWithoutTrailingNewlines = source
            while sourceWithoutTrailingNewlines.hasSuffix("\n") {
                sourceWithoutTrailingNewlines.removeLast()
            }

            var stripped = result.settled
            if result.pending.isEmpty {
                for fence in ["\n```", "\n~~~"]
                where stripped.hasSuffix(fence)
                    && !sourceWithoutTrailingNewlines.hasSuffix(fence)
                {
                    stripped = String(stripped.dropLast(fence.count))
                    break
                }
            }
            XCTAssertTrue(
                source.hasPrefix(stripped),
                "settled was not a source prefix at length \(length)"
            )
            XCTAssertGreaterThanOrEqual(
                stripped.count,
                previousSettledLength,
                "settled shrank at length \(length)"
            )
            previousSettledLength = stripped.count

            let visible = stripped.count + result.pending.count
            XCTAssertGreaterThanOrEqual(
                visible + 1,
                source.count,
                "content dropped at length \(length)"
            )
        }
    }
}
