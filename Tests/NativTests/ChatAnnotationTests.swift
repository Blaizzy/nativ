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

    func testRepeatedUnicodePassageUsesExactRange() throws {
        let message = ChatTranscriptMessage(role: .user, content: "🌙 first yes. Second yes. End.")
        let range = (message.content as NSString).range(of: "yes", options: .backwards)
        let annotation = try XCTUnwrap(ChatAnnotation.capture(message: message, range: range))
        XCTAssertEqual(annotation.quote, "yes")
        XCTAssertEqual(annotation.selectionLocation, range.location)
        XCTAssertEqual(annotation.selectionLength, range.length)
    }

    func testInvalidSelectionsAndStreamingAreRejected() {
        var message = ChatTranscriptMessage(role: .assistant, content: "🌙 Hello")
        XCTAssertNil(ChatAnnotation.capture(message: message, range: NSRange(location: 99, length: 1)))
        XCTAssertNil(ChatAnnotation.capture(message: message, range: NSRange(location: 0, length: 0)))
        XCTAssertNil(ChatAnnotation.capture(message: message, range: NSRange(location: 0, length: 1)))
        message.isStreaming = true
        XCTAssertNil(ChatAnnotation.capture(message: message, range: NSRange(location: 3, length: 5)))
    }

    func testPromptIncludesOnlySelectedPassagesAndPreservesRequest() throws {
        let sources = [
            ChatTranscriptMessage(role: .user, content: "Before user. Selected user. After user."),
            ChatTranscriptMessage(role: .assistant, content: "Before assistant. Selected\nassistant. After assistant.")
        ]
        let selections = ["Selected user.", "Selected\nassistant."]
        var message = ChatTranscriptMessage(role: .user, content: "Explain this.")
        message.annotations = try zip(sources, selections).map { source, selection in
            try XCTUnwrap(ChatAnnotation.capture(
                message: source, range: (source.content as NSString).range(of: selection)
            ))
        }
        let prompt = try XCTUnwrap(message.apiMessage?.content?.textValue)
        XCTAssertTrue(prompt.contains("Reference 1 from an earlier user message:\nSelected passage:\n> Selected user."))
        XCTAssertTrue(prompt.contains("Reference 2 from an earlier assistant message:\nSelected passage:\n> Selected\n> assistant."))
        XCTAssertFalse(prompt.contains("Before"))
        XCTAssertFalse(prompt.contains("After"))
        XCTAssertTrue(prompt.hasSuffix("Current user request:\nExplain this."))
        XCTAssertEqual(message.content, "Explain this.")
    }

    func testPreviouslySavedContextIsIgnoredAndRemovedOnSave() throws {
        let data = Data("""
        {
            "role": "user", "content": "Explain this.",
            "annotations": [{
                "id": "11111111-1111-1111-1111-111111111111",
                "sourceMessageID": "22222222-2222-2222-2222-222222222222",
                "sourceRole": "assistant", "sourceDigest": "old-digest",
                "selectionLocation": 8, "selectionLength": 9,
                "quote": "Selected.", "before": "Before. ", "after": " After.",
                "includesContext": true
            }]
        }
        """.utf8)
        let message = try JSONDecoder().decode(ChatTranscriptMessage.self, from: data)
        let prompt = try XCTUnwrap(message.apiMessage?.content?.textValue)
        XCTAssertTrue(prompt.contains("> Selected."))
        XCTAssertFalse(prompt.contains("Before."))
        XCTAssertFalse(prompt.contains("After."))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        let annotations = try XCTUnwrap(saved["annotations"] as? [[String: Any]])
        let annotation = try XCTUnwrap(annotations.first)
        XCTAssertNil(annotation["before"])
        XCTAssertNil(annotation["after"])
        XCTAssertNil(annotation["includesContext"])
        XCTAssertNil(annotation["sourceDigest"])
        XCTAssertEqual(annotation["quote"] as? String, "Selected.")
    }

    func testSnapshotSurvivesSourceEditsAndPersistence() throws {
        var source = ChatTranscriptMessage(role: .user, content: "Original passage")
        let annotation = try XCTUnwrap(ChatAnnotation.capture(message: source, range: NSRange(location: 0, length: 8)))
        var message = ChatTranscriptMessage(role: .user, content: "Question")
        message.annotations = [annotation]
        source.content = "Edited passage"
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

    func testArchiveRejectsDuplicateMessageIDs() throws {
        let source = ChatTranscriptMessage(role: .assistant, content: "Original")
        let session = ChatSession(id: UUID(), title: "Test", createdAt: .now, updatedAt: .now, messages: [source, source])
        let archive = ChatArchive(chat: session, modelRepositoryID: "test/model", systemPrompt: "")
        let data = try ChatArchiveCodec.encode(archive)
        XCTAssertThrowsError(try ChatArchiveCodec.decode(data)) { error in
            XCTAssertEqual(error as? ChatArchiveError, .duplicateMessageIDs)
        }
        XCTAssertThrowsError(try ChatArchiveCodec.importedSession(from: archive)) { error in
            XCTAssertEqual(error as? ChatArchiveError, .duplicateMessageIDs)
        }
    }
}
