import XCTest
@testable import Murmur

final class TranscriptionDiagnosticsTests: XCTestCase {
    // MARK: - Interval merging

    func testMergeIntervalsCombinesOverlaps() {
        let merged = TranscriptionDiagnostics.mergeIntervals([(0, 10), (8, 20), (25, 30)])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 20)
        XCTAssertEqual(merged[1].start, 25)
        XCTAssertEqual(merged[1].end, 30)
    }

    func testMergeIntervalsDropsEmptyAndSortsUnordered() {
        let merged = TranscriptionDiagnostics.mergeIntervals([(15, 20), (5, 5), (0, 10)])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[1].start, 15)
    }

    // MARK: - Coverage analysis

    func testFullCoverageNoLoss() {
        let report = TranscriptionDiagnostics.analyze(
            segmentSpans: [(0, 28), (27, 60)],
            audioDuration: 61,
            resultCount: 2,
            expectedChunkCount: 2,
            failedChunkIndices: []
        )
        XCTAssertFalse(report.suspectedLoss)
        XCTAssertEqual(report.verdict, "no loss detected")
        XCTAssertEqual(report.coveredDuration, 60, accuracy: 0.001)
        XCTAssertTrue(report.gaps.isEmpty)
    }

    func testSmallSilencesBelowThresholdAreNotGaps() {
        // 4s pauses between segments — normal speech, not a dropped window.
        let report = TranscriptionDiagnostics.analyze(
            segmentSpans: [(0, 10), (14, 24), (28, 38)],
            audioDuration: 40,
            resultCount: 2,
            expectedChunkCount: 2,
            failedChunkIndices: []
        )
        XCTAssertTrue(report.gaps.isEmpty)
        XCTAssertFalse(report.suspectedLoss)
    }

    func testDroppedChunkIsMechanismA() {
        // Chunk 1 of 3 failed: its ~30s never comes back.
        let report = TranscriptionDiagnostics.analyze(
            segmentSpans: [(0, 30), (60, 90)],
            audioDuration: 90,
            resultCount: 2,
            expectedChunkCount: 3,
            failedChunkIndices: [1]
        )
        XCTAssertTrue(report.suspectedLoss)
        XCTAssertEqual(report.chunkShortfall, 1)
        XCTAssertTrue(report.verdict.contains("mechanism A"))
        XCTAssertEqual(report.gaps, [TranscriptionDiagnostics.Gap(start: 30, end: 60)])
    }

    func testCoverageGapWithAllChunksIsMechanismB() {
        // All chunks returned, but a ~30s window inside one is uncovered.
        let report = TranscriptionDiagnostics.analyze(
            segmentSpans: [(0, 30), (30, 45), (75, 90)],
            audioDuration: 90,
            resultCount: 3,
            expectedChunkCount: 3,
            failedChunkIndices: []
        )
        XCTAssertTrue(report.suspectedLoss)
        XCTAssertEqual(report.chunkShortfall, 0)
        XCTAssertTrue(report.verdict.contains("mechanism B"))
        XCTAssertEqual(report.gaps, [TranscriptionDiagnostics.Gap(start: 45, end: 75)])
    }

    func testTrailingGapIsDetected() {
        let report = TranscriptionDiagnostics.analyze(
            segmentSpans: [(0, 30)],
            audioDuration: 55,
            resultCount: 1,
            expectedChunkCount: 2,
            failedChunkIndices: []
        )
        XCTAssertEqual(report.gaps, [TranscriptionDiagnostics.Gap(start: 30, end: 55)])
        XCTAssertEqual(report.chunkShortfall, 1)
    }

    func testShortUnchunkedRecordingHasNoExpectedCount() {
        let report = TranscriptionDiagnostics.analyze(
            segmentSpans: [(0, 12)],
            audioDuration: 12,
            resultCount: 1,
            expectedChunkCount: nil,
            failedChunkIndices: []
        )
        XCTAssertEqual(report.chunkShortfall, 0)
        XCTAssertFalse(report.suspectedLoss)
    }

    func testCoverageClampsSegmentsBeyondFileDuration() {
        // Whisper pads the last window to 30s; segment ends can overrun the
        // real duration. Coverage must not exceed 100%.
        let report = TranscriptionDiagnostics.analyze(
            segmentSpans: [(0, 28), (26, 39)],
            audioDuration: 32.2,
            resultCount: 2,
            expectedChunkCount: 2,
            failedChunkIndices: []
        )
        XCTAssertEqual(report.coveredDuration, 32.2, accuracy: 0.001)
        XCTAssertFalse(report.suspectedLoss)
    }

    // MARK: - Merge accounting

    func testMergeAccountingCountsDrops() {
        let accounting = TranscriptionDiagnostics.mergeAccounting(
            chunkTexts: ["one two three four five", "four five six seven"],
            mergedText: "one two three four five six seven"
        )
        XCTAssertEqual(accounting.chunkWordCounts, [5, 4])
        XCTAssertEqual(accounting.rawWordCount, 9)
        XCTAssertEqual(accounting.mergedWordCount, 7)
        XCTAssertEqual(accounting.droppedWords, 2)
    }

    // MARK: - Log collector parsing

    func testCollectorParsesChunkCountAndFailures() {
        let collector = WhisperKitLogCollector()
        collector.beginRun()
        collector.ingest("Found 7 VAD chunks")
        collector.ingest("Error transcribing chunk 3: WhisperError.transcriptionFailed")
        collector.ingest("Error transcribing chunk 5: cancelled")
        collector.ingest("Audio loading and convert time: 0.2")
        XCTAssertEqual(collector.vadChunkCount, 7)
        XCTAssertEqual(collector.failedChunkIndices, [3, 5])
    }

    func testCollectorBeginRunResetsState() {
        let collector = WhisperKitLogCollector()
        collector.ingest("Found 4 VAD chunks")
        collector.ingest("Error transcribing chunk 0: boom")
        collector.beginRun()
        XCTAssertNil(collector.vadChunkCount)
        XCTAssertEqual(collector.failedChunkIndices, [])
    }
}
