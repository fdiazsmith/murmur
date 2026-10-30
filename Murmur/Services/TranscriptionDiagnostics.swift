import Foundation

/// Stage-1 instrumentation for the silent-transcript-gap bug on long local
/// recordings. WhisperKit can lose audio two ways without ever throwing:
///
/// - Mechanism A: a VAD chunk's transcription task fails and the failure is
///   dropped in `AudioChunker.updateSeekOffsetsForResults` with only a
///   `Logging.debug` call.
/// - Mechanism B: a ~30s decoding window is skipped entirely when its
///   `noSpeechProb` exceeds `noSpeechThreshold` (default 0.6) — no log at all.
///
/// This type answers, per run: how many chunks did WhisperKit find vs. return,
/// and how much of the recorded audio do the returned segments actually cover.
/// The two mechanisms leave different fingerprints:
///
/// - A: `resultCount < expectedChunkCount`, plus a parsed per-chunk error line.
/// - B: chunk counts match but a large uncovered gap remains.
enum TranscriptionDiagnostics {
    /// Uncovered spans up to this long are treated as normal silence between
    /// speech segments. A skipped no-speech window discards ~30s, and a failed
    /// VAD chunk up to ~30s, so real losses show up well above this.
    static let gapThreshold: Double = 5.0

    struct Gap: Equatable {
        let start: Double
        let end: Double
        var duration: Double { end - start }
    }

    struct Report {
        let audioDuration: Double
        let coveredDuration: Double
        /// One transcription result per successfully transcribed VAD chunk.
        let resultCount: Int
        /// Parsed from WhisperKit's "Found N VAD chunks" log; nil when the
        /// recording was short enough to skip chunking (or log capture failed).
        let expectedChunkCount: Int?
        /// Parsed from WhisperKit's "Error transcribing chunk N:" log lines.
        let failedChunkIndices: [Int]
        let gaps: [Gap]
        /// Highest noSpeechProb among segments that were *kept* — shows how
        /// close routine decoding runs to the 0.6 skip threshold.
        let maxKeptNoSpeechProb: Double?

        var suspectedLoss: Bool { !failedChunkIndices.isEmpty || chunkShortfall > 0 || !gaps.isEmpty }

        var chunkShortfall: Int {
            guard let expected = expectedChunkCount else { return 0 }
            return max(0, expected - resultCount)
        }

        var verdict: String {
            let chunkLoss = !failedChunkIndices.isEmpty || chunkShortfall > 0
            switch (chunkLoss, !gaps.isEmpty) {
            case (true, _):
                return "mechanism A: chunk task failure silently dropped"
            case (false, true):
                return "mechanism B suspected: coverage gap with all chunks returned (no-speech window skip, or genuine silence)"
            case (false, false):
                return "no loss detected"
            }
        }

        var consoleSummary: String {
            let coveredPct = audioDuration > 0 ? Int((coveredDuration / audioDuration * 100).rounded()) : 0
            var lines: [String] = []
            let chunkInfo = expectedChunkCount.map { "\(resultCount)/\($0)" } ?? "\(resultCount) (expected count unknown)"
            lines.append(String(
                format: "[Murmur][Diag] audio %.1fs, covered %.1fs (%d%%), chunks %@, failed chunks %@",
                audioDuration, coveredDuration, coveredPct, chunkInfo,
                failedChunkIndices.isEmpty ? "none" : "\(failedChunkIndices)"
            ))
            for gap in gaps {
                lines.append(String(format: "[Murmur][Diag] gap %.1f–%.1fs (%.1fs uncovered)", gap.start, gap.end, gap.duration))
            }
            if let maxProb = maxKeptNoSpeechProb {
                lines.append(String(format: "[Murmur][Diag] max kept noSpeechProb %.2f (skip threshold 0.6)", maxProb))
            }
            lines.append("[Murmur][Diag] verdict: \(verdict)")
            if suspectedLoss {
                lines.append("[Murmur][WARNING] transcript may be incomplete")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Pure coverage analysis over absolute segment time spans.
    /// - Parameter segmentSpans: (start, end) in seconds, absolute within the
    ///   recording (WhisperKit adds each chunk's seekTime before returning).
    static func analyze(
        segmentSpans: [(start: Double, end: Double)],
        audioDuration: Double,
        resultCount: Int,
        expectedChunkCount: Int?,
        failedChunkIndices: [Int],
        maxKeptNoSpeechProb: Double? = nil
    ) -> Report {
        let merged = mergeIntervals(segmentSpans)
        // Whisper pads the last window to 30s, so segment ends can overrun the
        // real file duration — clamp so coverage never reads >100%.
        let covered = merged.reduce(0) { $0 + (min($1.end, audioDuration) - min($1.start, audioDuration)) }

        var gaps: [Gap] = []
        var cursor = 0.0
        for span in merged {
            if span.start - cursor > gapThreshold {
                gaps.append(Gap(start: cursor, end: span.start))
            }
            cursor = max(cursor, span.end)
        }
        if audioDuration - cursor > gapThreshold {
            gaps.append(Gap(start: cursor, end: audioDuration))
        }

        return Report(
            audioDuration: audioDuration,
            coveredDuration: covered,
            resultCount: resultCount,
            expectedChunkCount: expectedChunkCount,
            failedChunkIndices: failedChunkIndices,
            gaps: gaps,
            maxKeptNoSpeechProb: maxKeptNoSpeechProb
        )
    }

    /// Word-count accounting across the chunk-merge stage. Coverage analysis
    /// proves WhisperKit's segments span the audio; this proves the *text*
    /// survived `TranscriptMerger`. A small drop is expected boundary dedup;
    /// a large one means the merger is eating real content.
    struct MergeAccounting {
        let chunkWordCounts: [Int]
        let mergedWordCount: Int
        var rawWordCount: Int { chunkWordCounts.reduce(0, +) }
        var droppedWords: Int { rawWordCount - mergedWordCount }

        var consoleSummary: String {
            let perChunk = chunkWordCounts.map(String.init).joined(separator: "+")
            return "[Murmur][Diag] merge: chunks \(perChunk)=\(rawWordCount) words -> merged \(mergedWordCount) (dropped \(droppedWords))"
        }
    }

    static func mergeAccounting(chunkTexts: [String], mergedText: String) -> MergeAccounting {
        MergeAccounting(
            chunkWordCounts: chunkTexts.map { TranscriptMerger.tokenize($0).count },
            mergedWordCount: TranscriptMerger.tokenize(mergedText).count
        )
    }

    /// Sort spans and merge overlapping/adjacent ones into disjoint intervals.
    static func mergeIntervals(_ spans: [(start: Double, end: Double)]) -> [(start: Double, end: Double)] {
        let sorted = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [(start: Double, end: Double)] = []
        for span in sorted {
            if var last = merged.last, span.start <= last.end {
                last.end = max(last.end, span.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}

/// Captures WhisperKit's internal log lines for one transcription run.
/// WhisperKit logs both the VAD chunk count and per-chunk transcription
/// failures at `.debug` level only, so this is the sole way to observe a
/// dropped chunk from outside the library.
final class WhisperKitLogCollector {
    private let lock = NSLock()
    private var _vadChunkCount: Int?
    private var _failedChunkIndices: [Int] = []

    /// Lines containing any of these substrings are forwarded to the console
    /// even outside full-verbose mode — they're the diagnosis signal.
    private static let interestingFragments = ["VAD chunk", "Error", "error", "Fallback", "fallback"]

    /// Set to true to forward every WhisperKit log line to the console.
    var fullVerbose = false

    var vadChunkCount: Int? {
        lock.lock(); defer { lock.unlock() }
        return _vadChunkCount
    }

    var failedChunkIndices: [Int] {
        lock.lock(); defer { lock.unlock() }
        return _failedChunkIndices.sorted()
    }

    /// Reset per-run state. Call before each `transcribe`.
    func beginRun() {
        lock.lock(); defer { lock.unlock() }
        _vadChunkCount = nil
        _failedChunkIndices = []
    }

    /// Parse and optionally forward one WhisperKit log line. Thread-safe;
    /// WhisperKit logs from its concurrent chunk workers.
    func ingest(_ line: String) {
        if let count = Self.match(line, pattern: #"Found (\d+) VAD chunks"#) {
            lock.lock()
            _vadChunkCount = count
            lock.unlock()
        }
        if let index = Self.match(line, pattern: #"Error transcribing chunk (\d+):"#) {
            lock.lock()
            _failedChunkIndices.append(index)
            lock.unlock()
        }
        if fullVerbose || Self.interestingFragments.contains(where: { line.contains($0) }) {
            print("[WhisperKit] \(line)")
        }
    }

    private static func match(_ line: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(result.range(at: 1), in: line)
        else { return nil }
        return Int(line[range])
    }
}
