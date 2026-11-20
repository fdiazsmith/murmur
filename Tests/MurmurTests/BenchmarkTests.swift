import XCTest
import WhisperKit
@testable import Murmur

/// End-to-end timing against the real model: wav files are fed through a
/// `DictationSession` in real time, as the mic would, and the wait between
/// "release" and text is measured. Skipped unless MURMUR_BENCH_AUDIO points
/// at a folder of 16 kHz wav files:
///
///   MURMUR_BENCH_AUDIO=/path swift test -c release -Xswiftc -enable-testing --filter Benchmark
///
/// MURMUR_BENCH_PROMPT sets a profile prompt; MURMUR_BENCH_MODEL the variant.
final class BenchmarkTests: XCTestCase {
    func testReleaseToTextLatency() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["MURMUR_BENCH_AUDIO"] else {
            throw XCTSkip("MURMUR_BENCH_AUDIO not set")
        }
        let transcriber = LocalTranscriber()
        transcriber.modelVariant = environment["MURMUR_BENCH_MODEL"] ?? WhisperModelCatalog.defaultVariant
        await transcriber.warmup()
        let profilePrompt = environment["MURMUR_BENCH_PROMPT"] ?? ""

        let files = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".wav") }.sorted()
        for file in files {
            let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: folder + "/" + file)
            let seconds = Double(audio.count) / 16_000

            // Before: everything transcribed after release.
            let batchStart = Date()
            let batch = try await transcriber.transcribe(samples: audio, context: TranscriptionContext(prompt: profilePrompt))
            let batchTime = Date().timeIntervalSince(batchStart)
            print(String(format: "[Bench] %@ (%.1fs) batch: %.2fs", file, seconds, batchTime))
            print("[Bench]   text: \(batch)")

            // After: live session; release right at the last word, or after
            // a natural half-second beat.
            for (label, trailing) in [("release at last word", 0.0), ("release after 0.5s beat", 0.5)] {
                let partials = PartialLog()
                let session = DictationSession(
                    provider: transcriber, profilePrompt: profilePrompt,
                    livePreview: environment["MURMUR_BENCH_NO_PREVIEW"] == nil
                ) { partials.add($0) }
                let live = audio + [Float](repeating: 0, count: Int(trailing * 16_000))
                let clock = ContinuousClock()
                let start = clock.now
                var offset = 0
                while offset < live.count {
                    let end = min(offset + 320, live.count)
                    session.append(Array(live[offset..<end]))
                    offset = end
                    // Stay on the wall clock rather than accumulating sleep drift.
                    try await clock.sleep(until: start + .milliseconds(offset / 16))
                }
                let released = Date()
                let outcome = await session.finish()
                print(String(format: "[Bench] %@ live, %@: %.2fs  (%d piece(s), ahead=%@)", file, label,
                             Date().timeIntervalSince(released), outcome.pieceCount, outcome.finishedAhead ? "yes" : "no"))
                print("[Bench]   text: \(outcome.text)")
                print("[Bench]   partials: \(partials.summary)")
            }
        }
    }
}

private final class PartialLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Date, String)] = []
    private let start = Date()

    func add(_ text: String) { lock.withLock { entries.append((Date(), text)) } }

    var summary: String {
        lock.withLock {
            entries.map { String(format: "%.1fs:%dch", $0.0.timeIntervalSince(start), $0.1.count) }.joined(separator: " ")
        }
    }
}
