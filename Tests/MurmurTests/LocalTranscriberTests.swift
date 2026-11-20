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

    // MARK: - Prompt + previous text

    /// Fake tokenizer: one token per word, wrapped in specials like the real one.
    private func encode(_ text: String) -> [Int] {
        [50258] + text.split(separator: " ").map { Int($0.dropFirst())! } + [50257]
    }

    func testPreviousTextSitsAfterTheProfilePrompt() {
        let tokens = LocalTranscriber.promptTokens(prompt: "w1 w2 w3", previousText: "w7 w8", specialTokenBegin: specialBegin, encode: encode)
        XCTAssertEqual(tokens, [1, 2, 3, 7, 8])
    }

    func testPreviousTextIsCappedSoTheProfileKeepsTheBudget() {
        let previous = (100..<200).map { "w\($0)" }.joined(separator: " ")
        let prompt = (1...50).map { "w\($0)" }.joined(separator: " ")
        let tokens = LocalTranscriber.promptTokens(prompt: prompt, previousText: previous, specialTokenBegin: specialBegin, limit: 30, previousLimit: 10, encode: encode)
        XCTAssertEqual(tokens.count, 30)
        XCTAssertEqual(Array(tokens.suffix(10)), Array(190..<200))
        XCTAssertEqual(Array(tokens.prefix(20)), Array(31...50))
    }

    func testNoPromptAndNoContextMeansNoTokens() {
        XCTAssertEqual(LocalTranscriber.promptTokens(prompt: " ", previousText: "", specialTokenBegin: specialBegin, encode: encode), [])
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
