import XCTest
@testable import Murmur

/// Records what it was asked to transcribe; answers with a script.
private final class FakeProvider: TranscriptionProvider, @unchecked Sendable {
    struct Call {
        let seconds: Double
        let context: TranscriptionContext
    }

    let supportsStreaming: Bool
    var delay: Duration = .milliseconds(5)
    /// Answer for the nth completed call; default echoes the audio length.
    var respond: (Int, Call) throws -> String = { index, call in String(format: "piece%d %.1fs.", index, call.seconds) }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _cancelled = 0

    init(streaming: Bool = true) { supportsStreaming = streaming }

    var calls: [Call] { lock.withLock { _calls } }
    var cancelled: Int { lock.withLock { _cancelled } }

    func transcribe(samples: [Float], context: TranscriptionContext) async throws -> String {
        do {
            try await Task.sleep(for: delay)
        } catch {
            lock.withLock { _cancelled += 1 }
            throw CancellationError()
        }
        let call = Call(seconds: Double(samples.count) / 16_000, context: context)
        let index = lock.withLock {
            _calls.append(call)
            return _calls.count - 1
        }
        return try respond(index, call)
    }
}

private struct FakeError: Error {}

final class DictationSessionTests: XCTestCase {
    private func run(
        _ audio: [Float],
        provider: FakeProvider,
        prompt: String = "",
        settle: Duration = .milliseconds(60)
    ) async -> DictationSession.Outcome {
        let session = DictationSession(provider: provider, profilePrompt: prompt)
        TestAudio.feed(audio) { session.append($0) }
        // Let work started during "recording" get going, as it would live.
        try? await Task.sleep(for: settle)
        return await session.finish()
    }

    func testReleaseRightAfterSpeakingTranscribesEverythingOnce() async {
        let provider = FakeProvider()
        let outcome = await run(TestAudio.speech(3), provider: provider)
        XCTAssertEqual(provider.calls.count, 1)
        XCTAssertEqual(provider.calls[0].seconds, 3, accuracy: 0.01)
        XCTAssertEqual(outcome.text, "piece0 3.0s.")
        XCTAssertEqual(outcome.pieceCount, 1)
        XCTAssertFalse(outcome.finishedAhead)
        XCTAssertFalse(outcome.silent)
    }

    func testPauseBeforeReleaseIsAlreadyTranscribed() async {
        let provider = FakeProvider()
        let outcome = await run(TestAudio.speech(3) + TestAudio.silence(0.8), provider: provider)
        // The speculative piece (speech + padding) is the answer; the
        // trailing silence is never sent.
        XCTAssertTrue(outcome.finishedAhead)
        XCTAssertEqual(provider.calls.count, 1)
        XCTAssertEqual(provider.calls[0].seconds, 3.2, accuracy: 0.06)
        XCTAssertEqual(outcome.pieceCount, 1)
    }

    func testSpeakingAgainAfterAPauseDiscardsTheSpeculation() async {
        let provider = FakeProvider()
        provider.delay = .milliseconds(200)
        let audio = TestAudio.speech(2) + TestAudio.silence(0.5) + TestAudio.speech(1)
        let outcome = await run(audio, provider: provider, settle: .zero)
        XCTAssertFalse(outcome.finishedAhead)
        XCTAssertEqual(outcome.pieceCount, 1)
        // Only the full-length pass completed.
        XCTAssertEqual(provider.calls.count, 1)
        XCTAssertEqual(provider.calls[0].seconds, 3.5, accuracy: 0.01)
        XCTAssertEqual(provider.cancelled, 1)
    }

    func testLongDictationIsSplitAtPausesAndStitchedInOrder() async {
        let provider = FakeProvider()
        provider.respond = { index, _ in ["First part.", "Second part.", "Third."][index] }
        let audio = TestAudio.speech(7) + TestAudio.silence(1) + TestAudio.speech(8) + TestAudio.silence(1) + TestAudio.speech(2)
        let outcome = await run(audio, provider: provider, prompt: "Vocabulary")
        XCTAssertEqual(outcome.text, "First part. Second part. Third.")
        XCTAssertEqual(outcome.pieceCount, 3)
        XCTAssertEqual(outcome.failedPieces, 0)
        let calls = provider.calls
        XCTAssertEqual(calls.map(\.context.previousText), ["", "First part.", "Second part."])
        XCTAssertEqual(calls.map(\.context.prompt), ["Vocabulary", "Vocabulary", "Vocabulary"])
        // Pieces tile the recording: nothing dropped, nothing doubled.
        XCTAssertEqual(calls.map(\.seconds).reduce(0, +), outcome.audioDuration, accuracy: 0.01)
    }

    func testTrailingSilenceAfterASplitIsNotTranscribed() async {
        let provider = FakeProvider()
        let outcome = await run(TestAudio.speech(7) + TestAudio.silence(2.5), provider: provider)
        XCTAssertEqual(provider.calls.count, 1)
        XCTAssertEqual(outcome.pieceCount, 1)
        XCTAssertEqual(provider.calls[0].seconds, 7.2, accuracy: 0.06)
    }

    func testVeryLongUnbrokenSpeechIsForceSplit() async {
        let provider = FakeProvider()
        let outcome = await run(TestAudio.speech(50), provider: provider)
        XCTAssertEqual(outcome.pieceCount, 3)
        XCTAssertTrue(provider.calls.allSatisfy { $0.seconds <= 24.5 })
        XCTAssertEqual(provider.calls.map(\.seconds).reduce(0, +), 50, accuracy: 0.01)
    }

    func testDeadMicIsReportedWithoutCallingTheProvider() async {
        let provider = FakeProvider()
        let outcome = await run([Float](repeating: 0, count: 32_000), provider: provider)
        XCTAssertTrue(outcome.silent)
        XCTAssertEqual(provider.calls.count, 0)
        XCTAssertEqual(outcome.text, "")
    }

    func testAudioTheDetectorCallsSilenceIsStillTranscribed() async {
        // Never drop a whole dictation on the detector's word: room-level
        // audio with no detected speech still goes to the provider.
        let provider = FakeProvider()
        let outcome = await run(TestAudio.silence(2, amplitude: 0.004), provider: provider)
        XCTAssertFalse(outcome.silent)
        XCTAssertEqual(provider.calls.count, 1)
    }

    func testNonStreamingProviderGetsOneCallWithEverything() async {
        let provider = FakeProvider(streaming: false)
        let audio = TestAudio.speech(7) + TestAudio.silence(1) + TestAudio.speech(8) + TestAudio.silence(1)
        let outcome = await run(audio, provider: provider)
        XCTAssertEqual(provider.calls.count, 1)
        XCTAssertEqual(provider.calls[0].seconds, 17, accuracy: 0.01)
        XCTAssertEqual(outcome.pieceCount, 1)
    }

    func testATransientErrorIsRetried() async {
        let provider = FakeProvider()
        provider.respond = { index, _ in
            if index == 0 { throw FakeError() }
            return "Recovered."
        }
        let outcome = await run(TestAudio.speech(2), provider: provider)
        XCTAssertEqual(outcome.text, "Recovered.")
        XCTAssertEqual(outcome.failedPieces, 0)
        XCTAssertNil(outcome.error)
    }

    func testAnEmptyPromptedResultIsRetriedWithoutThePrompt() async {
        let provider = FakeProvider()
        provider.respond = { _, call in call.context.prompt.isEmpty ? "Plain result." : "" }
        let outcome = await run(TestAudio.speech(2), provider: provider, prompt: "Vocabulary")
        XCTAssertEqual(outcome.text, "Plain result.")
        XCTAssertEqual(provider.calls.map(\.context.prompt), ["Vocabulary", ""])
    }

    func testAFailedPieceIsReportedButTheRestSurvives() async {
        let provider = FakeProvider()
        provider.respond = { _, call in
            if call.context.previousText.isEmpty { return "First part." }
            throw FakeError()
        }
        let audio = TestAudio.speech(7) + TestAudio.silence(1) + TestAudio.speech(3)
        let outcome = await run(audio, provider: provider)
        XCTAssertEqual(outcome.text, "First part.")
        XCTAssertEqual(outcome.failedPieces, 1)
        XCTAssertNotNil(outcome.error)
    }

    func testTotalFailureYieldsAnErrorAndNoText() async {
        let provider = FakeProvider()
        provider.respond = { _, _ in throw FakeError() }
        let outcome = await run(TestAudio.speech(2), provider: provider)
        XCTAssertEqual(outcome.text, "")
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(outcome.failedPieces, 1)
    }

    func testAudioAfterFinishIsIgnored() async {
        let provider = FakeProvider()
        let session = DictationSession(provider: provider, profilePrompt: "")
        TestAudio.feed(TestAudio.speech(1)) { session.append($0) }
        let outcome = await session.finish()
        session.append(TestAudio.speech(1))
        XCTAssertEqual(outcome.audioDuration, 1, accuracy: 0.01)
    }

    // MARK: - Never drop speech on the detector's say

    /// Syllables over a loud room: ~10 dB between speech and background.
    private func noisySpeech(_ seconds: Double) -> [Float] {
        let noise = TestAudio.silence(seconds, amplitude: 0.02)
        return noise.enumerated().map { index, sample in
            let t = Double(index) / 16_000
            let envelope = Float(0.5 + 0.5 * sin(t * 2 * .pi * 3))
            return sample + 0.07 * envelope * sin(Float(index) * 0.2)
        }
    }

    private func assertFullyCovered(_ audio: [Float], file: StaticString = #filePath, line: UInt = #line) async {
        let provider = FakeProvider()
        let outcome = await run(audio, provider: provider)
        let sent = provider.calls.suffix(outcome.pieceCount).map(\.seconds).reduce(0, +)
        XCTAssertEqual(sent, outcome.audioDuration, accuracy: 0.05, file: file, line: line)
    }

    func testSpeechInANoisyRoomIsFullyTranscribed() async {
        await assertFullyCovered(noisySpeech(20))
        await assertFullyCovered(noisySpeech(30))
    }

    func testASteadyQuietVoiceIsFullyTranscribed() async {
        await assertFullyCovered(TestAudio.speech(30, amplitude: 0.0015))
        await assertFullyCovered(TestAudio.speech(20, amplitude: 0.03))
        await assertFullyCovered(TestAudio.silence(1, amplitude: 0.0002) + TestAudio.speech(30, amplitude: 0.002))
    }

    func testAWordStartedJustBeforeReleaseIsKept() async {
        await assertFullyCovered(TestAudio.speech(2) + TestAudio.silence(0.4) + TestAudio.speech(0.04))
        await assertFullyCovered(TestAudio.speech(7) + TestAudio.silence(1) + TestAudio.speech(0.08))
    }

    func testSparseSoundAfterAPauseIsKept() async {
        var tail = TestAudio.silence(3)
        for frame in stride(from: 0, to: tail.count / 320, by: 3) {
            for index in (frame * 320)..<(frame * 320 + 320) { tail[index] = 0.1 * sin(Float(index) * 0.2) }
        }
        await assertFullyCovered(TestAudio.speech(2) + TestAudio.silence(0.4) + tail)
    }

    func testAnUnrequestedCancellationCountsAsAFailure() async {
        let provider = FakeProvider()
        provider.respond = { _, _ in throw CancellationError() }
        let outcome = await run(TestAudio.speech(2), provider: provider)
        XCTAssertEqual(outcome.text, "")
        XCTAssertEqual(outcome.failedPieces, 1)
        XCTAssertNotNil(outcome.error)
    }

    func testAKnownHallucinationFromFaintAudioIsDropped() async {
        // Room tone only, which the adaptive detector partly flags as speech.
        var audio = TestAudio.silence(8, amplitude: 0.0006)
        for index in stride(from: 16_000, to: audio.count, by: 16_000) {
            for offset in 0..<3200 { audio[index + offset] *= 5 }
        }
        let provider = FakeProvider()
        provider.respond = { _, _ in " you" }
        let outcome = await run(audio, provider: provider)
        XCTAssertEqual(outcome.text, "")
        XCTAssertNil(outcome.error)
    }

    // MARK: - Live preview

    private final class Partials: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ text: String) { lock.withLock { values.append(text) } }
        var all: [String] { lock.withLock { values } }
    }

    func testPreviewsShowTextWhileSpeakingAndNeverReachTheResult() async throws {
        let provider = FakeProvider()
        provider.respond = { _, call in call.context.prompt.isEmpty ? "preview text" : "Final text." }
        let partials = Partials()
        let session = DictationSession(provider: provider, profilePrompt: "Vocabulary", livePreview: true) { partials.add($0) }
        // Speak for 3 s in real-ish time so previews get a chance to run.
        for _ in 0..<6 {
            TestAudio.feed(TestAudio.speech(0.5)) { session.append($0) }
            try await Task.sleep(for: .milliseconds(40))
        }
        let outcome = await session.finish()
        XCTAssertEqual(outcome.text, "Final text.")
        XCTAssertEqual(outcome.pieceCount, 1)
        XCTAssertFalse(partials.all.isEmpty)
        XCTAssertTrue(partials.all.allSatisfy { $0 == "preview text" })
        // Previews run without the profile prompt; the real pass uses it.
        XCTAssertEqual(provider.calls.last?.context.prompt, "Vocabulary")
        XCTAssertEqual(provider.calls.last?.seconds ?? 0, 3, accuracy: 0.01)
    }

    func testPartialsIncludeEarlierPieces() async throws {
        let provider = FakeProvider()
        provider.respond = { _, call in call.context.previousText.isEmpty ? "First part." : "Second part." }
        let partials = Partials()
        let session = DictationSession(provider: provider, profilePrompt: "", livePreview: false) { partials.add($0) }
        TestAudio.feed(TestAudio.speech(7) + TestAudio.silence(1) + TestAudio.speech(2) + TestAudio.silence(0.5)) { session.append($0) }
        try await Task.sleep(for: .milliseconds(120))
        _ = await session.finish()
        XCTAssertEqual(partials.all.first, "First part.")
        XCTAssertEqual(partials.all.last, "First part. Second part.")
    }

    func testNoPreviewsWithoutTheSetting() async throws {
        let provider = FakeProvider()
        let session = DictationSession(provider: provider, profilePrompt: "", livePreview: false) { _ in }
        for _ in 0..<6 {
            TestAudio.feed(TestAudio.speech(0.5)) { session.append($0) }
            try await Task.sleep(for: .milliseconds(40))
        }
        _ = await session.finish()
        XCTAssertEqual(provider.calls.count, 1)
    }
}
