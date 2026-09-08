import XCTest
import NativServerKit

final class ChatAnnotationTests: XCTestCase {
    func testRenderedSelectionSpansBoldAndLinkWithoutQuotingMarkup() throws {
        let source = ChatTranscriptMessage(role: .assistant,
            content: "Before. Read **this bold** and [linked text](https://example.com). After.")
        let displayed = "Before. Read this bold and linked text. After."
        let text = "this bold and linked text"
        let range = try XCTUnwrap(ChatAnnotation.selectionRange(text: text, in: source.content,
            elementText: displayed, elementRange: (displayed as NSString).range(of: text),
            renderedMarkdown: true))
        let annotation = try XCTUnwrap(ChatAnnotation.capture(message: source, range: range, displayedText: text))
        XCTAssertEqual(annotation.quote, text)
        XCTAssertTrue(annotation.before.hasPrefix("Before. Read"))
        XCTAssertTrue(annotation.after.hasSuffix("After."))
        XCTAssertEqual(annotation.historyPrefix(in: [source])?.last?.content, annotation.before)
    }

    func testRenderedRangeDisambiguatesRepeatedBoldText() throws {
        let source = "First **yes**, then **yes**."
        let displayed = "First yes, then yes."
        let range = try XCTUnwrap(ChatAnnotation.selectionRange(text: "yes", in: source,
            elementText: displayed, elementRange: (displayed as NSString).range(of: "yes", options: .backwards),
            renderedMarkdown: true))
        XCTAssertEqual(range, (source as NSString).range(of: "yes", options: .backwards))
    }

    func testNativeRangeDisambiguatesRepeatedText() {
        let source = "yes then yes"
        XCTAssertEqual(ChatAnnotation.selectionRange(text: "yes", in: source, elementText: source,
            elementRange: NSRange(location: 9, length: 3)), NSRange(location: 9, length: 3))
        XCTAssertNil(ChatAnnotation.selectionRange(text: "yes", in: source, elementText: nil,
            elementRange: NSRange(location: NSNotFound, length: 0)))
    }

    func testWholeMessageQuoteCapturesAdjacentConversation() throws {
        let previous = ChatTranscriptMessage(role: .assistant, content: "Which option?")
        let source = ChatTranscriptMessage(role: .user, content: "The second one.")
        let next = ChatTranscriptMessage(role: .assistant, content: "That means local storage.")
        let annotation = try XCTUnwrap(ChatAnnotation.capture(message: source,
            range: NSRange(location: 0, length: (source.content as NSString).length)))
            .addingAdjacentContext(from: [previous, source, next])
        XCTAssertTrue(annotation.before.contains("Which option?"))
        XCTAssertTrue(annotation.after.contains("local storage"))
    }

    func testTwentyPercentBoundaryScalesWithWindow() {
        XCTAssertFalse(ChatAnnotation.needsContext(distance: 9_600, contextLimit: 48_000))
        XCTAssertTrue(ChatAnnotation.needsContext(distance: 9_601, contextLimit: 48_000))
        XCTAssertTrue(ChatAnnotation.needsContext(distance: 20_000, contextLimit: 48_000))
        XCTAssertFalse(ChatAnnotation.needsContext(distance: 20_000, contextLimit: 256_000))
        XCTAssertTrue(ChatAnnotation.needsContext(distance: nil, contextLimit: 48_000))
        XCTAssertTrue(ChatAnnotation.needsContext(distance: 10, contextLimit: nil))
        XCTAssertTrue(ChatAnnotation.needsContext(distance: 10, contextLimit: 0))
    }

    func testRepeatedUnicodePassageUsesExactRange() throws {
        let message = ChatTranscriptMessage(role: .user, content: "🌙 first yes. Second yes. End.")
        let range = (message.content as NSString).range(of: "yes", options: .backwards)
        let annotation = try XCTUnwrap(ChatAnnotation.capture(message: message, range: range))
        XCTAssertEqual(annotation.quote, "yes")
        XCTAssertEqual(annotation.before, "🌙 first yes. Second ")
        XCTAssertEqual(annotation.after, ". End.")
        XCTAssertEqual(annotation.historyPrefix(in: [message])?.last?.content, annotation.before)
    }

    func testInvalidSelectionsAndStreamingAreRejected() {
        var message = ChatTranscriptMessage(role: .assistant, content: "🌙 Hello")
        XCTAssertNil(ChatAnnotation.capture(message: message, range: NSRange(location: 99, length: 1)))
        XCTAssertNil(ChatAnnotation.capture(message: message, range: NSRange(location: 0, length: 0)))
        XCTAssertNil(ChatAnnotation.capture(message: message, range: NSRange(location: 0, length: 1)))
        message.isStreaming = true
        XCTAssertNil(ChatAnnotation.capture(message: message, range: NSRange(location: 3, length: 5)))
    }

    func testContextIsBoundedWithoutTruncatingQuote() throws {
        let text = String(repeating: "a", count: 1_000) + "SELECTED" + String(repeating: "b", count: 1_000)
        let message = ChatTranscriptMessage(role: .assistant, content: text)
        let annotation = try XCTUnwrap(ChatAnnotation.capture(
            message: message, range: (text as NSString).range(of: "SELECTED")
        ))
        XCTAssertEqual(annotation.quote, "SELECTED")
        XCTAssertEqual(annotation.before.count, 600)
        XCTAssertEqual(annotation.after.count, 600)
    }

    func testPromptIncludesContextOnlyWhenRequiredAndPreservesRequest() throws {
        let source = ChatTranscriptMessage(role: .assistant, content: "Before. Selected. After.")
        var annotation = try XCTUnwrap(ChatAnnotation.capture(
            message: source, range: (source.content as NSString).range(of: "Selected.")
        ))
        var message = ChatTranscriptMessage(role: .user, content: "Explain this.")
        annotation.includesContext = false
        message.annotations = [annotation]
        let recent = try XCTUnwrap(message.apiMessage?.content?.textValue)
        XCTAssertTrue(recent.contains("> Selected."))
        XCTAssertFalse(recent.contains("Before."))
        XCTAssertFalse(recent.contains("After."))
        XCTAssertTrue(recent.hasSuffix("Current user request:\nExplain this."))
        annotation.includesContext = true
        message.annotations = [annotation]
        let old = try XCTUnwrap(message.apiMessage?.content?.textValue)
        XCTAssertTrue(old.contains("Before."))
        XCTAssertTrue(old.contains("After."))
        XCTAssertEqual(message.content, "Explain this.")
    }

    func testSnapshotSurvivesSourceEditsAndPersistence() throws {
        var source = ChatTranscriptMessage(role: .user, content: "Original passage")
        let annotation = try XCTUnwrap(ChatAnnotation.capture(message: source, range: NSRange(location: 0, length: 8)))
        var message = ChatTranscriptMessage(role: .user, content: "Question")
        message.annotations = [annotation]
        source.content = "Edited passage"
        XCTAssertNil(annotation.historyPrefix(in: [source]))
        let decoded = try JSONDecoder().decode(ChatTranscriptMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.annotations, [annotation])
        XCTAssertEqual(decoded.annotations.first?.quote, "Original")
    }

    func testLegacyMessageDecodesWithoutAnnotations() throws {
        let data = Data(#"{"role":"user","content":"Old chat"}"#.utf8)
        let decoded = try JSONDecoder().decode(ChatTranscriptMessage.self, from: data)
        XCTAssertTrue(decoded.annotations.isEmpty)
        XCTAssertEqual(decoded.apiMessage?.content?.textValue, "Old chat")
    }

    func testArchiveImportRemapsAnnotationSource() throws {
        let source = ChatTranscriptMessage(role: .assistant, content: "Original")
        var question = ChatTranscriptMessage(role: .user, content: "Explain")
        question.annotations = [try XCTUnwrap(ChatAnnotation.capture(message: source, range: NSRange(location: 0, length: 8)))]
        let session = ChatSession(id: UUID(), title: "Test", createdAt: .now, updatedAt: .now, messages: [source, question])
        let archive = ChatArchive(chat: session, modelRepositoryID: "test/model", systemPrompt: "")
        let imported = try ChatArchiveCodec.importedSession(from: archive)
        XCTAssertEqual(imported.messages[1].annotations.first?.sourceMessageID, imported.messages[0].id)
        XCTAssertNotEqual(imported.messages[0].id, source.id)
    }
}
