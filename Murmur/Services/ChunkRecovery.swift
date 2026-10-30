import Foundation

/// Mechanism-A recovery (see `TranscriptionDiagnostics`): WhisperKit
/// transcribes VAD chunks concurrently and its own chunked path drops a failed
/// chunk with only a debug log. `LocalTranscriber` runs the chunk loop itself
/// so it sees each chunk's `Result`, then hands the first pass here.
///
/// Failed chunks are retried once, sequentially (no concurrent ANE contention),
/// and each retry result is spliced back into the failed chunk's own slot —
/// chunk index is time order, so the transcript stays in order for the merger.
enum ChunkRecovery {
    struct Outcome<Value> {
        /// One entry per chunk, in chunk (time) order.
        let results: [Result<Value, Error>]
        /// Chunks that failed the first pass and succeeded on retry.
        let recoveredIndices: [Int]
        /// Chunks still failed after recovery.
        let failedIndices: [Int]

        var allFailed: Bool { failedIndices.count == results.count }

        var firstError: Error? {
            for result in results {
                if case let .failure(error) = result { return error }
            }
            return nil
        }
    }

    /// Retry each failed chunk once, in order. When *every* chunk failed the
    /// pipeline itself is broken rather than one chunk, so nothing is retried
    /// and the caller decides (reload the model / run the retry ladder).
    static func recover<Value>(
        _ firstPass: [Result<Value, Error>],
        retry: (Int) async throws -> Value
    ) async -> Outcome<Value> {
        let failed = firstPass.indices.filter { index in
            if case .failure = firstPass[index] { return true }
            return false
        }
        guard !failed.isEmpty, failed.count < firstPass.count else {
            return Outcome(results: firstPass, recoveredIndices: [], failedIndices: failed)
        }

        var results = firstPass
        var recovered: [Int] = []
        var stillFailed: [Int] = []
        for index in failed {
            do {
                results[index] = .success(try await retry(index))
                recovered.append(index)
            } catch {
                results[index] = .failure(error)
                stillFailed.append(index)
            }
        }
        return Outcome(results: results, recoveredIndices: recovered, failedIndices: stillFailed)
    }
}
