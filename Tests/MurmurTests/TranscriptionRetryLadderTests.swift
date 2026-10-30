import XCTest
@testable import Murmur

final class TranscriptionRetryLadderTests: XCTestCase {
    func testWithPromptTriesPromptTwiceThenWithout() {
        XCTAssertEqual(TranscriptionRetryLadder.prompts(for: "Swift, Xcode"), ["Swift, Xcode", "Swift, Xcode", ""])
    }

    func testWithoutPromptRetriesOnce() {
        XCTAssertEqual(TranscriptionRetryLadder.prompts(for: ""), ["", ""])
    }

    func testErrorsWalkTheWholeLadder() {
        let prompts = TranscriptionRetryLadder.prompts(for: "p")
        XCTAssertEqual(TranscriptionRetryLadder.nextAttempt(after: 0, in: prompts, emptyResult: false), 1)
        XCTAssertEqual(TranscriptionRetryLadder.nextAttempt(after: 1, in: prompts, emptyResult: false), 2)
        XCTAssertNil(TranscriptionRetryLadder.nextAttempt(after: 2, in: prompts, emptyResult: false))
    }

    func testEmptyResultSkipsStraightToNoPrompt() {
        // Decoding is deterministic, so re-running the same prompt on the
        // same audio would just reproduce the empty result.
        let prompts = TranscriptionRetryLadder.prompts(for: "p")
        XCTAssertEqual(TranscriptionRetryLadder.nextAttempt(after: 0, in: prompts, emptyResult: true), 2)
        XCTAssertNil(TranscriptionRetryLadder.nextAttempt(after: 2, in: prompts, emptyResult: true))
    }

    func testEmptyResultWithoutPromptGivesUp() {
        let prompts = TranscriptionRetryLadder.prompts(for: "")
        XCTAssertNil(TranscriptionRetryLadder.nextAttempt(after: 0, in: prompts, emptyResult: true))
        XCTAssertEqual(TranscriptionRetryLadder.nextAttempt(after: 0, in: prompts, emptyResult: false), 1)
    }
}
