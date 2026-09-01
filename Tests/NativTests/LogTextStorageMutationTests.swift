import Testing

@Suite("Log text storage updates")
struct LogTextStorageMutationTests {
    @Test("Appending complete lines only replaces the appended suffix")
    func appendingCompleteLinesReplacesAppendedSuffix() {
        let previousText = "first\nsecond\n"

        let mutation = LogTextStorageMutation.plan(
            previousText: previousText,
            previousQuery: "",
            newText: previousText + "third\n",
            newQuery: ""
        )

        #expect(
            mutation == .replaceSuffix(
                fromUTF16Offset: previousText.utf16.count
            )
        )
    }

    @Test("Appending to a partial line restyles that entire line")
    func appendingToPartialLineRestylesTheLine() {
        let previousText = "first\n2026-09-01 - INF"

        let mutation = LogTextStorageMutation.plan(
            previousText: previousText,
            previousQuery: "",
            newText: previousText + "O - Decode progress\n",
            newQuery: ""
        )

        #expect(
            mutation == .replaceSuffix(
                fromUTF16Offset: "first\n".utf16.count
            )
        )
    }

    @Test("UTF-16 offsets match attributed string ranges")
    func mutationUsesUTF16Offsets() {
        let previousText = "status 🚀\nnext"

        let mutation = LogTextStorageMutation.plan(
            previousText: previousText,
            previousQuery: "",
            newText: previousText + " line",
            newQuery: ""
        )

        #expect(
            mutation == .replaceSuffix(
                fromUTF16Offset: "status 🚀\n".utf16.count
            )
        )
    }

    @Test("Trimming the log replaces the full document")
    func trimmingLogReplacesAllText() {
        let mutation = LogTextStorageMutation.plan(
            previousText: "first\nsecond\nthird\n",
            previousQuery: "",
            newText: "second\nthird\nfourth\n",
            newQuery: ""
        )

        #expect(mutation == .replaceAll)
    }

    @Test("Changing the search query replaces all attributes")
    func changingSearchQueryReplacesAllText() {
        let text = "first\nsecond\n"
        let mutation = LogTextStorageMutation.plan(
            previousText: text,
            previousQuery: "first",
            newText: text,
            newQuery: "second"
        )

        #expect(mutation == .replaceAll)
    }

    @Test("Canonically equivalent text with different storage replaces the document")
    func canonicallyEquivalentTextReplacesAllText() {
        let mutation = LogTextStorageMutation.plan(
            previousText: "é",
            previousQuery: "",
            newText: "e\u{301} continued",
            newQuery: ""
        )

        #expect(mutation == .replaceAll)
    }
}
