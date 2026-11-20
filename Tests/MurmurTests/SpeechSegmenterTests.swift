import XCTest
@testable import Murmur

/// Synthetic audio: "speech" is a loud tone, "silence" is low noise.
enum TestAudio {
    static let rate = 16_000

    static func speech(_ seconds: Double, amplitude: Float = 0.1) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(Float($0) * 0.2) }
    }

    static func silence(_ seconds: Double, amplitude: Float = 0.0006) -> [Float] {
        var state: UInt32 = 12345
        return (0..<Int(seconds * Double(rate))).map { _ in
            state = state &* 1664525 &+ 1013904223
            return (Float(state >> 8) / Float(1 << 24) - 0.5) * 2 * amplitude
        }
    }

    /// Feed in 20 ms buffers like the mic tap does.
    static func feed(_ samples: [Float], buffer: Int = 320, _ body: ([Float]) -> Void) {
        var offset = 0
        while offset < samples.count {
            let end = min(offset + buffer, samples.count)
            body(Array(samples[offset..<end]))
            offset = end
        }
    }
}

final class SpeechSegmenterTests: XCTestCase {
    private func events(for audio: [Float], config: SpeechSegmenter.Config = .init()) -> (events: [SpeechSegmenter.Event], segmenter: SpeechSegmenter) {
        var segmenter = SpeechSegmenter(config: config)
        var events: [SpeechSegmenter.Event] = []
        TestAudio.feed(audio) { events += segmenter.append($0) }
        return (events, segmenter)
    }

    private func seconds(_ sample: Int) -> Double { Double(sample) / 16_000 }

    func testPauseIsReportedShortlyAfterSpeechStops() {
        let audio = TestAudio.silence(0.3) + TestAudio.speech(2) + TestAudio.silence(0.6)
        let (events, segmenter) = events(for: audio)
        guard case let .pause(cut)? = events.first, events.count == 1 else {
            return XCTFail("expected a single pause, got \(events)")
        }
        // Cut sits just after the speech (2.3 s) with a little padding.
        XCTAssertEqual(seconds(cut), 2.5, accuracy: 0.06)
        XCTAssertTrue(segmenter.isPaused)
        XCTAssertEqual(segmenter.trailingSilence, 0.6, accuracy: 0.06)
    }

    func testLeadingSilenceIsNotAPause() {
        let (events, _) = events(for: TestAudio.silence(3))
        XCTAssertEqual(events, [])
    }

    func testSpeechResumingEndsThePause() {
        let audio = TestAudio.speech(1.5) + TestAudio.silence(0.5) + TestAudio.speech(1)
        let (events, segmenter) = events(for: audio)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last, .speechResumed)
        XCTAssertFalse(segmenter.isPaused)
    }

    func testAClickDoesNotEndThePause() {
        var audio = TestAudio.speech(1.5) + TestAudio.silence(1.2)
        // One 20 ms click in the middle of the pause.
        let click = Int(2.2 * 16_000)
        for index in click..<(click + 320) { audio[index] = 0.3 }
        let (events, segmenter) = events(for: audio)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(segmenter.isPaused)
    }

    func testShortDictationIsNeverSplit() {
        // 3 s of speech then a long pause: a pause, but no boundary.
        let (events, segmenter) = events(for: TestAudio.speech(3) + TestAudio.silence(3))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(segmenter.segmentStart, 0)
    }

    func testLongPauseAfterEnoughAudioIsABoundary() {
        let audio = TestAudio.speech(7) + TestAudio.silence(1) + TestAudio.speech(1)
        let (events, segmenter) = events(for: audio)
        guard events.count == 2, case let .pause(pauseCut) = events[0], case let .boundary(cut) = events[1] else {
            return XCTFail("expected pause then boundary, got \(events)")
        }
        XCTAssertEqual(cut, pauseCut)
        XCTAssertEqual(seconds(cut), 7.2, accuracy: 0.06)
        XCTAssertEqual(segmenter.segmentStart, cut)
        // Speech after a boundary is a fresh segment, not a "resume".
        XCTAssertFalse(segmenter.isPaused)
    }

    func testBoundaryNeedsLessSilenceWhenALotIsPending() {
        let config = SpeechSegmenter.Config()
        let quiet = (config.eagerBoundarySilence + config.boundarySilence) / 2
        let short = events(for: TestAudio.speech(8) + TestAudio.silence(quiet) + TestAudio.speech(0.5)).events
        XCTAssertFalse(short.contains { if case .boundary = $0 { true } else { false } })
        let long = events(for: TestAudio.speech(15) + TestAudio.silence(quiet) + TestAudio.speech(0.5)).events
        XCTAssertTrue(long.contains { if case .boundary = $0 { true } else { false } })
    }

    func testUnbrokenSpeechIsForceCutAtTheQuietestSpot() {
        // 26 s of speech with a brief dip (too short to be a pause) at 21 s.
        var audio = TestAudio.speech(26)
        let dip = Int(21.0 * 16_000)
        for index in dip..<(dip + 16_000 / 5) { audio[index] *= 0.02 }
        let (events, segmenter) = events(for: audio)
        guard case let .forcedCut(cut)? = events.last else {
            return XCTFail("expected a forced cut, got \(events)")
        }
        XCTAssertEqual(seconds(cut), 21.1, accuracy: 0.12)
        XCTAssertEqual(segmenter.segmentStart, cut)
    }

    func testSpeechDurationCountsLoudFramesOnly() {
        let (_, segmenter) = events(for: TestAudio.silence(1) + TestAudio.speech(2) + TestAudio.silence(1))
        XCTAssertEqual(segmenter.speechDuration(from: 0), 2, accuracy: 0.06)
        XCTAssertEqual(segmenter.speechDuration(from: 16_000 * 3), 0, accuracy: 0.03)
    }

    func testQuietSpeechIsStillSpeechOverAQuietRoom() {
        // Soft voice (-46 dBFS) over a very quiet room.
        let audio = TestAudio.silence(0.5, amplitude: 0.0002) + TestAudio.speech(2, amplitude: 0.007) + TestAudio.silence(0.6, amplitude: 0.0002)
        let (events, segmenter) = events(for: audio)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(segmenter.speechDuration(from: 0), 2, accuracy: 0.08)
    }

    func testPeakLevelSeparatesADeadMicFromARoom() {
        XCTAssertLessThan(events(for: [Float](repeating: 0, count: 32_000)).segmenter.peakLevel, DictationSession.silentPeakLevel)
        XCTAssertGreaterThan(events(for: TestAudio.silence(2, amplitude: 0.003)).segmenter.peakLevel, DictationSession.silentPeakLevel)
    }
}
