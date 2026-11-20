import XCTest
@testable import Murmur

final class TranscriptCleanerTests: XCTestCase {
    func testTrimsAndCollapsesWhitespace() {
        XCTAssertEqual(TranscriptCleaner.clean("  Hello   there.\n"), "Hello there.")
    }

    func testNonSpeechAnnotationsAreRemoved() {
        XCTAssertEqual(TranscriptCleaner.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(TranscriptCleaner.clean("Okay (music) let's go ♪♪"), "Okay let's go")
        XCTAssertEqual(TranscriptCleaner.clean("[ Silence ]"), "")
    }

    func testBracketsThatAreNotAnnotationsSurvive() {
        XCTAssertEqual(TranscriptCleaner.clean("Use array[0] (the first one)."), "Use array[0] (the first one).")
    }

    func testSilenceHallucinationIsDroppedOnlyWithoutSpeech() {
        XCTAssertEqual(TranscriptCleaner.clean("Thank you.", speechDuration: 0.05), "")
        XCTAssertEqual(TranscriptCleaner.clean(" Thanks for watching!", speechDuration: 0), "")
        // Actually said: keep it.
        XCTAssertEqual(TranscriptCleaner.clean("Thank you.", speechDuration: 0.7), "Thank you.")
        // Unknown speech amount: keep it.
        XCTAssertEqual(TranscriptCleaner.clean("Thank you."), "Thank you.")
    }

    func testPunctuationOnlyIsEmpty() {
        XCTAssertEqual(TranscriptCleaner.clean(" ... "), "")
    }

    func testRealTextNeverMatchesTheHallucinationList() {
        XCTAssertEqual(TranscriptCleaner.clean("Thank you for the review.", speechDuration: 0), "Thank you for the review.")
    }
}

final class WavWriterTests: XCTestCase {
    func testHeaderAndSamples() {
        let data = WavWriter.data(samples: [0, 1, -1, 2], sampleRate: 16_000)
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        let samples = data[44...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        // Out-of-range input is clamped, not wrapped.
        XCTAssertEqual(samples, [0, Int16.max, -Int16.max, Int16.max])
    }
}

final class AudioLevelMeterTests: XCTestCase {
    func testSnapshotInterpolatesOnTheSampleClock() {
        let meter = AudioLevelMeter()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        meter.load(levels: [0, 1, 0.5], startTime: start)
        let snapshot = meter.snapshot()
        XCTAssertEqual(snapshot.level(at: start.addingTimeInterval(0.005)), 0.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.level(at: start.addingTimeInterval(0.015)), 0.75, accuracy: 0.001)
        // Past the newest level: hold it rather than drop to zero.
        XCTAssertEqual(snapshot.level(at: start.addingTimeInterval(5)), 0.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.level(at: start.addingTimeInterval(-5)), 0)
    }

    func testLevelsRiseInstantlyAndFallGradually() {
        let meter = AudioLevelMeter()
        meter.push([Float](repeating: 0.2, count: AudioLevelMeter.window))
        meter.push([Float](repeating: 0, count: AudioLevelMeter.window * 3))
        let levels = meter.snapshot().levels
        XCTAssertEqual(levels.count, 4)
        XCTAssertGreaterThan(levels[0], 0.8)
        XCTAssertEqual(levels[1], levels[0] * AudioLevelMeter.release, accuracy: 0.001)
        XCTAssertLessThan(levels[3], levels[1])
    }
}
