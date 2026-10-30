import XCTest
import WhisperKit
@testable import Murmur

final class LocalTranscriberTests: XCTestCase {
    // MARK: - Prompt tokens

    /// Whisper's special tokens start at 50257 for the English-only tokenizer.
    private let specialBegin = 50257

    func testSpecialTokensAreStripped() {
        // tokenizer.encode(text:) wraps text in <|startoftranscript|>… <|endoftext|>.
        let encoded = [50258, 50359, 50363, 11, 22, 33, 50257]
        let tokens = LocalTranscriber.promptTokens(fromEncoded: encoded, specialTokenBegin: specialBegin, limit: 10)
        XCTAssertEqual(tokens, [11, 22, 33])
    }

    func testLongPromptKeepsTheTail() {
        // The end of the prompt sits closest to the audio, so it is what
        // Whisper conditions on most — keep it, drop the head.
        let encoded = [50258] + Array(1...10) + [50257]
        let tokens = LocalTranscriber.promptTokens(fromEncoded: encoded, specialTokenBegin: specialBegin, limit: 4)
        XCTAssertEqual(tokens, [7, 8, 9, 10])
    }

    func testLimitAppliesAfterFiltering() {
        // Trailing special tokens must not eat into the budget.
        let encoded = [1, 2, 3, 50257, 50257]
        let tokens = LocalTranscriber.promptTokens(fromEncoded: encoded, specialTokenBegin: specialBegin, limit: 3)
        XCTAssertEqual(tokens, [1, 2, 3])
    }

    func testDefaultLimitMatchesWhisperKitPromptBudget() {
        XCTAssertEqual(LocalTranscriber.maxPromptTokens, Constants.maxTokenContext / 2 - 1)
    }

    // MARK: - Error classification

    func testPipelineErrorsInvalidateModel() {
        XCTAssertTrue(LocalTranscriber.invalidatesModel(WhisperError.modelsUnavailable()))
        XCTAssertTrue(LocalTranscriber.invalidatesModel(WhisperError.tokenizerUnavailable()))
        XCTAssertTrue(LocalTranscriber.invalidatesModel(WhisperError.prepareDecoderInputsFailed()))
        XCTAssertTrue(LocalTranscriber.invalidatesModel(WhisperError.decodingLogitsFailed()))
        XCTAssertTrue(LocalTranscriber.invalidatesModel(NSError(domain: "com.apple.CoreML", code: 0)))
    }

    func testPerRecordingErrorsKeepModel() {
        XCTAssertFalse(LocalTranscriber.invalidatesModel(WhisperError.loadAudioFailed()))
        XCTAssertFalse(LocalTranscriber.invalidatesModel(WhisperError.audioProcessingFailed()))
        XCTAssertFalse(LocalTranscriber.invalidatesModel(WhisperError.decodingFailed()))
        XCTAssertFalse(LocalTranscriber.invalidatesModel(WhisperError.transcriptionFailed()))
        XCTAssertFalse(LocalTranscriber.invalidatesModel(CancellationError()))
        XCTAssertFalse(LocalTranscriber.invalidatesModel(NSError(domain: NSCocoaErrorDomain, code: 260)))
    }

    // MARK: - Decoding options

    func testDictationOptionsNeverSkipWindowsOrEndThemEarly() {
        let options = LocalTranscriber.dictationDecodingOptions()
        XCTAssertNil(options.noSpeechThreshold)
        XCTAssertNil(options.firstTokenLogProbThreshold)
        // Repetition / low-confidence checks only trigger the temperature
        // fallback ladder (never drop text), so they stay on.
        XCTAssertEqual(options.compressionRatioThreshold, 2.4)
        XCTAssertEqual(options.logProbThreshold, -1.0)
        XCTAssertEqual(options.temperatureFallbackCount, 5)
        // Timestamps let a truncated window re-seek instead of skipping 30s.
        XCTAssertFalse(options.withoutTimestamps)
        XCTAssertTrue(options.skipSpecialTokens)
    }
}
