import XCTest
import WhisperKit
@testable import Murmur

final class PromptDecodingFiltersTests: XCTestCase {
    // large-v3 ids: <|endoftext|> 50257, <|startoftranscript|> 50258, <|en|> 50259,
    // <|translate|> 50359, <|transcribe|> 50360, <|startofprev|> 50362,
    // <|notimestamps|> 50364, <|0.00|> 50365 (<|0.40|> = 50385).
    private let special = SpecialTokens(
        endToken: 50257, englishToken: 50259, noSpeechToken: 50363, noTimestampsToken: 50364,
        specialTokenBegin: 50257, startOfPreviousToken: 50362, startOfTranscriptToken: 50258,
        timeTokenBegin: 50365, transcribeToken: 50360, translateToken: 50359, whitespaceToken: 220
    )
    /// <|startofprev|> " Murmur" <|startoftranscript|> <|en|> <|transcribe|> <|0.00|>
    private let initialPrompt = [50362, 9373, 76, 374, 50258, 50259, 50360, 50365]
    private let unprompted = [50258, 50259, 50360, 50365]

    // MARK: - PromptPrefillEndFilter

    func testSuppressesEndWhileOnlyThePromptIsInContext() {
        // WhisperKit filters with the full initial prompt for every forced
        // prompt step and for the first real sample.
        XCTAssertTrue(PromptPrefillEndFilter.shouldSuppressEnd(tokens: initialPrompt, specialTokens: special))
        XCTAssertTrue(PromptPrefillEndFilter.shouldSuppressEnd(
            tokens: Array(initialPrompt.dropLast()) + [50364], specialTokens: special
        ))
    }

    func testSuppressesEndWhenLastForcedStepKeptAPredictedTimestamp() {
        // On the last forced step WhisperKit keeps the model's own timestamp
        // prediction (e.g. <|0.40|>) in place of <|0.00|> — still prefill.
        let tokens = Array(initialPrompt.dropLast()) + [50385]
        XCTAssertTrue(PromptPrefillEndFilter.shouldSuppressEnd(tokens: tokens, specialTokens: special))
    }

    func testSuppressesEndAfterTranslateTaskToken() {
        let tokens = [50362, 9373, 50258, 50259, 50359, 50365]
        XCTAssertTrue(PromptPrefillEndFilter.shouldSuppressEnd(tokens: tokens, specialTokens: special))
    }

    func testAllowsEndOnceASampledTimestampFollows() {
        // First sampled token is <|0.00|> again: something was sampled, so EOT
        // must be allowed (otherwise it stays suppressed while <|0.00|> repeats).
        XCTAssertFalse(PromptPrefillEndFilter.shouldSuppressEnd(tokens: initialPrompt + [50365], specialTokens: special))
        XCTAssertFalse(PromptPrefillEndFilter.shouldSuppressEnd(tokens: initialPrompt + [50365, 50365], specialTokens: special))
    }

    func testAllowsEndOnceTextHasBeenSampled() {
        XCTAssertFalse(PromptPrefillEndFilter.shouldSuppressEnd(tokens: initialPrompt + [770, 318], specialTokens: special))
        XCTAssertFalse(PromptPrefillEndFilter.shouldSuppressEnd(tokens: initialPrompt + [770, 50400], specialTokens: special))
    }

    func testLeavesUnpromptedDecodingAlone() {
        XCTAssertFalse(PromptPrefillEndFilter.shouldSuppressEnd(tokens: unprompted, specialTokens: special))
    }

    // MARK: - PromptTimestampRulesFilter

    func testSampleBeginIsAfterTaskAndClosingTimestamp() {
        XCTAssertEqual(PromptTimestampRulesFilter.sampleBegin(tokens: initialPrompt, specialTokens: special), initialPrompt.count)
        // Stays anchored as tokens are sampled.
        XCTAssertEqual(
            PromptTimestampRulesFilter.sampleBegin(tokens: initialPrompt + [770, 50400], specialTokens: special),
            initialPrompt.count
        )
    }

    func testSampleBeginToleratesPredictedClosingTimestamp() {
        let tokens = Array(initialPrompt.dropLast()) + [50385]
        XCTAssertEqual(PromptTimestampRulesFilter.sampleBegin(tokens: tokens, specialTokens: special), tokens.count)
    }

    func testNoSampleBeginForUnpromptedOrUntimestampedDecodes() {
        // Unprompted: WhisperKit's own TimestampRulesFilter already applies.
        XCTAssertNil(PromptTimestampRulesFilter.sampleBegin(tokens: unprompted, specialTokens: special))
        // withoutTimestamps: no timestamp rules at all.
        let noTimestamps = Array(initialPrompt.dropLast()) + [50364]
        XCTAssertNil(PromptTimestampRulesFilter.sampleBegin(tokens: noTimestamps, specialTokens: special))
    }
}
