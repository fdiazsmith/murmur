import XCTest
@testable import Murmur

final class TranscriptMergerTests: XCTestCase {
    // MARK: - Empty / single chunk

    func testEmptyInput() {
        XCTAssertEqual(TranscriptMerger.merge([]), "")
    }

    func testWhitespaceOnlyChunksAreDropped() {
        XCTAssertEqual(TranscriptMerger.merge(["   ", "\n\t"]), "")
    }

    func testSingleChunkPassesThrough() {
        XCTAssertEqual(TranscriptMerger.merge(["Hello world."]), "Hello world.")
    }

    // MARK: - Boundary overlap dedup

    func testBoundaryOverlapOfFourOrMoreWordsIsDropped() {
        let result = TranscriptMerger.merge([
            "The quick brown fox jumps over the lazy dog",
            "over the lazy dog and runs away quickly",
        ])
        XCTAssertEqual(result, "The quick brown fox jumps over the lazy dog and runs away quickly")
    }

    func testBoundaryOverlapComparesNormalizedButKeepsOriginal() {
        // "At the coffee shop" (capitalized, comma) overlaps "at the coffee shop".
        let result = TranscriptMerger.merge([
            "see you at the coffee shop",
            "At the coffee shop, we can talk",
        ])
        XCTAssertEqual(result, "see you at the coffee shop we can talk")
    }

    func testShortBoundaryOverlapIsPreserved() {
        // Only "the store" (2 words) overlaps — below the 4-word threshold.
        let result = TranscriptMerger.merge([
            "I went to the store",
            "the store was closed",
        ])
        XCTAssertEqual(result, "I went to the store the store was closed")
    }

    // MARK: - Sentence-loop collapse

    func testConsecutiveDuplicateSentencesCollapse() {
        let result = TranscriptMerger.merge([
            "The meeting is at noon. The meeting is at noon. See you there.",
        ])
        XCTAssertEqual(result, "The meeting is at noon. See you there.")
    }

    func testDuplicateSentencesAcrossChunkBoundaryCollapse() {
        let result = TranscriptMerger.merge([
            "Welcome back.",
            "Welcome back.",
        ])
        XCTAssertEqual(result, "Welcome back.")
    }

    // MARK: - Phrase-loop collapse

    func testPhraseRepeatedThreeTimesCollapses() {
        let result = TranscriptMerger.merge([
            "Please call me back please call me back please call me back",
        ])
        XCTAssertEqual(result, "Please call me back")
    }

    func testPhraseRepeatedOnlyTwiceIsPreserved() {
        // Two repeats is below the >=3 threshold; leave it alone.
        let result = TranscriptMerger.merge([
            "Please call me back please call me back",
        ])
        XCTAssertEqual(result, "Please call me back please call me back")
    }

    // MARK: - Legit short repeats preserved

    func testShortWordRepeatIsPreserved() {
        let result = TranscriptMerger.merge(["No, no, no, that's not right"])
        XCTAssertEqual(result, "No, no, no, that's not right")
    }

    func testShortPhraseRepeatBelowFourWordsIsPreserved() {
        // "I know" is a 2-word phrase — under the phrase-loop minimum.
        let result = TranscriptMerger.merge(["I know I know I know I know"])
        XCTAssertEqual(result, "I know I know I know I know")
    }
}
