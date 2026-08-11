import XCTest
@testable import NativServerKit

final class MLXChatRepetitionDetectorTests: XCTestCase {
    private let detector = MLXChatRepetitionDetector.default

    func testDetectsFourConsecutiveIdenticalNonTrivialWindows() {
        let repeatingPhrase = String(repeating: "the quick brown fox jumped ", count: 4)
        XCTAssertTrue(detector.isDegenerateRepetition(inTailOf: repeatingPhrase))
    }

    func testDoesNotFlagTextShorterThanEvenTheShortestRequiredLength() {
        XCTAssertFalse(detector.isDegenerateRepetition(inTailOf: "short"))
    }

    func testDoesNotFlagOrdinaryVariedProse() {
        let prose = """
        Here is a summary of the three sub-agent results. The first agent \
        found that the API returns paginated results. The second agent \
        confirmed the rate limit is 100 requests per minute. The third \
        agent noted the docs recommend exponential backoff on 429s. \
        Combining all three, the plan is to page through results while \
        respecting the rate limit and backing off on errors.
        """
        XCTAssertFalse(detector.isDegenerateRepetition(inTailOf: prose))
    }

    func testDoesNotFlagRepeatedWhitespaceOrSingleCharacterDividers() {
        let dividers = String(repeating: "-", count: 200)
        XCTAssertFalse(
            detector.isDegenerateRepetition(inTailOf: dividers),
            "a run of a single repeated character (e.g. a markdown divider) is common, legitimate content"
        )

        let blankPadding = String(repeating: "    \n", count: 40)
        XCTAssertFalse(detector.isDegenerateRepetition(inTailOf: blankPadding))
    }

    func testOnlyTheTailMatters() {
        let prefix = "A normal, varied opening sentence that sets up the answer. "
        let repeatingTail = String(repeating: "stuck in a loop again and again ", count: 5)
        XCTAssertTrue(
            detector.isDegenerateRepetition(inTailOf: prefix + repeatingTail),
            "a degenerate loop at the tail must still be caught even with varied content earlier in the same generation"
        )
    }

    func testThreeRepeatsIsNotEnoughForTheDefaultConfiguration() {
        let threeRepeats = String(repeating: "the quick brown fox jumped ", count: 3)
        XCTAssertFalse(
            detector.isDegenerateRepetition(inTailOf: threeRepeats),
            "the default requires 4 consecutive repeats — 3 must not trip it, or short coincidental echoes become false positives"
        )
    }

    func testCustomConfigurationIsRespected() {
        let custom = MLXChatRepetitionDetector(minimumPeriod: 4, maximumPeriod: 4, requiredRepeats: 2)
        XCTAssertTrue(custom.isDegenerateRepetition(inTailOf: "abcdabcd"))
        XCTAssertFalse(custom.isDegenerateRepetition(inTailOf: "abcdabce"))
    }

    func testCatchesAnAwkwardlySizedRepeatingUnit() {
        // A fixed-size-window comparison would miss an odd-length unit.
        let oddLengthUnit = "an oddly-sized fragment; "
        let repeated = String(repeating: oddLengthUnit, count: 4)
        XCTAssertTrue(detector.isDegenerateRepetition(inTailOf: repeated))
    }

    func testCatchesALiveCaughtSentenceLengthRepeatingUnit() {
        let sentence = "The Sicilian Defense is a popular opening that involves a series of sharp, aggressive moves designed to create a strong center for the black pieces."
        XCTAssertEqual(sentence.count, 148, "pin the real-world repeating unit's length so this test stays honest about what it's regression-testing")

        let repeated = String(repeating: sentence, count: 4)
        XCTAssertTrue(
            detector.isDegenerateRepetition(inTailOf: repeated),
            "a sentence-length repeating unit longer than the old 128-character cap must still be caught"
        )

        let oldBoundDetector = MLXChatRepetitionDetector(minimumPeriod: 6, maximumPeriod: 128, requiredRepeats: 4)
        XCTAssertFalse(
            oldBoundDetector.isDegenerateRepetition(inTailOf: repeated),
            "confirms the old maximumPeriod: 128 genuinely could not see this 148-character repeat"
        )
    }
}

final class NativChatErrorRepetitionLoopTests: XCTestCase {
    func testRepetitionLoopDetectedHasAUserFacingDescription() {
        let error = NativChatError.repetitionLoopDetected
        XCTAssertEqual(error.description, "The model got stuck repeating itself and generation was stopped early.")
        XCTAssertEqual(error.errorDescription, error.description)
    }
}

final class ChatRepetitionCheckThrottleTests: XCTestCase {
    func testDoesNotCheckBeforeTheStrideIsReached() {
        XCTAssertFalse(ChatRepetitionCheckThrottle.shouldCheck(charactersSinceLastCheck: 0))
        XCTAssertFalse(ChatRepetitionCheckThrottle.shouldCheck(charactersSinceLastCheck: ChatRepetitionCheckThrottle.checkStride - 1))
    }

    func testChecksExactlyAtTheStride() {
        XCTAssertTrue(ChatRepetitionCheckThrottle.shouldCheck(charactersSinceLastCheck: ChatRepetitionCheckThrottle.checkStride))
    }

    func testChecksWellPastTheStride() {
        XCTAssertTrue(ChatRepetitionCheckThrottle.shouldCheck(charactersSinceLastCheck: ChatRepetitionCheckThrottle.checkStride * 10))
    }
}
