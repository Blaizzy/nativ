import Foundation
import NaturalLanguage
import XCTest

final class ChatTextSearchTests: XCTestCase {
    func testLiteralMatchesPreserveCaseInsensitiveSubstringBehavior() throws {
        let results = try search("NOTIFICATION notifications notification", for: "notification")
        XCTAssertEqual(results.texts, ["NOTIFICATION", "notification", "notification"])
        XCTAssertEqual(results.matches.map(\.kind), [.exact, .exact, .exact])
    }

    func testFindsInsertionDeletionReplacementAndTransposition() throws {
        for query in ["notifcation", "notiffication", "notificxtion", "notificaiton"] {
            let results = try search("notification", for: query)
            XCTAssertEqual(results.texts, ["notification"], query)
            XCTAssertEqual(results.matches.first?.kind, .typo, query)
        }
    }

    func testWordFormsIncludeInflectionsAndIrregularForms() throws {
        for (query, text) in [("connect", "connected"), ("run", "running"), ("child", "children"), ("mouse", "mice")] {
            let results = try search(text, for: query)
            XCTAssertFalse(results.matches.isEmpty, "\(query) → \(text)")
            // Literal substrings still win over grammatical alternatives.
            XCTAssertEqual(results.matches.first?.kind, text.contains(query) ? .exact : .wordForm)
        }
        XCTAssertEqual(try search("We ran yesterday.", for: "running").matches.first?.kind, .wordForm)
    }

    func testTypoCanMatchAnInflectedWordThroughItsLemma() throws {
        XCTAssertEqual(try search("We connected yesterday.", for: "conect").texts, ["connected"])
    }

    func testPhrasesRequireAdjacentWordsInTheSameOrder() throws {
        let text = "notificaiton permission; notification other permissions; permissions notification"
        XCTAssertEqual(try search(text, for: "notification permissions").texts, ["notificaiton permission"])
        XCTAssertTrue(try search("notification. Permissions", for: "notification permissions").matches.isEmpty)
    }

    func testPhraseAllowsWhitespaceChanges() throws {
        let results = try search("Notification\n\tpermissions", for: "notification permissions")
        XCTAssertEqual(results.texts, ["Notification\n\tpermissions"])
    }

    func testQuotedQueriesAreLiteral() throws {
        let text = "notification permissions; notificaiton permissions; notification\npermissions"
        XCTAssertEqual(try search(text, for: "\"notification permissions\"").texts, ["notification permissions"])
        XCTAssertTrue(try search("We ran.", for: "\"running\"").matches.isEmpty)
    }

    func testPunctuationAndCodeQueriesStayLiteral() throws {
        XCTAssertEqual(try search("Use foo_bar() and foo_baz().", for: "foo_bar()").texts, ["foo_bar()"])
        XCTAssertTrue(try search("chat_session", for: "chat_sesion").matches.isEmpty)
        XCTAssertTrue(try search("notificationManager", for: "notificaitonManager").matches.isEmpty)
        XCTAssertTrue(try search("notification-manager", for: "notificaiton-manager").matches.isEmpty)
        XCTAssertEqual(try search("Use **bold** here.", for: "**bold**").texts, ["**bold**"])
    }

    func testShortWordsNumbersAndAcronymsDoNotReceiveTypoExpansion() throws {
        for (query, text) in [("car", "cat"), ("port", "part"), ("12345", "12346"), ("HTTPS", "HTTPX")] {
            XCTAssertTrue(try search(text, for: query).matches.isEmpty, query)
        }
    }

    func testTypoDistanceIsBoundedByWordLength() throws {
        XCTAssertTrue(try search("planet", for: "plxxet").matches.isEmpty)
        XCTAssertEqual(try search("notification", for: "notificxtixn").texts, ["notification"])
        XCTAssertTrue(try search("notification", for: "notixixxtion").matches.isEmpty)
        XCTAssertTrue(try search(String(repeating: "a", count: 80), for: String(repeating: "a", count: 79) + "b").matches.isEmpty)
    }

    func testDoesNotExpandSynonyms() throws {
        XCTAssertTrue(try search("automobile bicycle vehicle", for: "car").matches.isEmpty)
    }

    func testRangesReferToOriginalUnicodeText() throws {
        let text = "👩🏽‍💻 cafe\u{301} — NOTIFICATION; notificaiton ✅"
        let results = try search(text, for: "notification")
        XCTAssertEqual(results.texts, ["NOTIFICATION", "notificaiton"])
        for match in results.matches {
            XCTAssertNotNil(Range(match.range, in: text))
        }
        XCTAssertEqual(try search("👋 cafe\u{301}", for: "café").texts, ["cafe\u{301}"])
    }

    func testExactMatchesAreNotDuplicatedByWordMatching() throws {
        let results = try search("connected connected", for: "connect")
        XCTAssertEqual(results.texts, ["connect", "connect"])
    }

    func testLimitsPreserveTextOrderAcrossMatchKinds() throws {
        let results = try search("notificaiton notification notificxtion notification", for: "notification", limit: 2)
        XCTAssertEqual(results.texts, ["notificaiton", "notification"])
        XCTAssertEqual(results.matches.map(\.kind), [.typo, .exact])
    }

    func testEmptyQueriesAndNonpositiveLimitsHaveNoMatches() throws {
        for query in ["", " \n\t", "\"\""] {
            XCTAssertTrue(try search("notification", for: query).matches.isEmpty)
        }
        XCTAssertTrue(try search("notification", for: "notification", limit: 0).matches.isEmpty)
        XCTAssertTrue(try search("notification", for: "notification", limit: -1).matches.isEmpty)
    }

    func testPreparedMessageCanBeReusedAndRetainsItsID() throws {
        let id = UUID()
        let message = try ChatTextSearch.Message(id: id, text: "notification permissions", language: .english)
        for query in ["notification", "permission", "notificaiton"] {
            let results = try ChatTextSearch.matches(in: message, query: ChatTextSearch.Query(query, language: .english))
            XCTAssertEqual(results.map(\.messageID), [id])
        }
    }

    func testMessagesDoNotSharePhraseMatches() throws {
        let query = try ChatTextSearch.Query("notification permissions", language: .english)
        for text in ["notification", "permissions"] {
            let message = try ChatTextSearch.Message(id: UUID(), text: text, language: .english)
            XCTAssertTrue(try ChatTextSearch.matches(in: message, query: query).isEmpty)
        }
    }

    func testUnknownLanguageRetainsLiteralAndTypoMatching() throws {
        let message = try ChatTextSearch.Message(id: UUID(), text: "notification", language: .undetermined)
        for text in ["notification", "notificaiton"] {
            let query = try ChatTextSearch.Query(text, language: .undetermined)
            XCTAssertEqual(try ChatTextSearch.matches(in: message, query: query).count, 1)
        }
    }

    func testAutomaticLanguageDetectionSupportsWordForms() throws {
        let message = try ChatTextSearch.Message(id: UUID(), text: "We ran yesterday.")
        let query = try ChatTextSearch.Query("running")
        let matches = try ChatTextSearch.matches(in: message, query: query)
        XCTAssertEqual(matches.map(\.kind), [.wordForm])
    }

    func testNonLatinLiteralRangesAndCaseFolding() throws {
        XCTAssertEqual(try search("👋 连接数据库", for: "数据库").texts, ["数据库"])
        XCTAssertEqual(try search("👋 Straße", for: "STRASSE").texts, ["Straße"])
    }

    func testCancellationIsPropagated() async throws {
        let message = try ChatTextSearch.Message(id: UUID(), text: "notification", language: .english)
        let query = try ChatTextSearch.Query("notification", language: .english)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ChatTextSearch.matches(in: message, query: query)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }

    private func search(_ text: String, for query: String, limit: Int = 200) throws -> (texts: [String], matches: [ChatTextSearch.Match]) {
        let message = try ChatTextSearch.Message(id: UUID(), text: text, language: .english)
        let query = try ChatTextSearch.Query(query, language: .english)
        let matches = try ChatTextSearch.matches(in: message, query: query, limit: limit)
        let texts = try matches.map { match in
            String(text[try XCTUnwrap(Range(match.range, in: text))])
        }
        return (texts, matches)
    }
}
