import XCTest
@testable import Murmur

final class ChunkRecoveryTests: XCTestCase {
    private struct ChunkError: Error, Equatable { let index: Int }

    private func values(_ outcome: ChunkRecovery.Outcome<String>) -> [String?] {
        outcome.results.map { try? $0.get() }
    }

    // MARK: - Nothing to recover

    func testAllSuccessesPassThroughWithoutRetrying() async {
        let firstPass: [Result<String, Error>] = [.success("a"), .success("b")]
        var retried: [Int] = []
        let outcome = await ChunkRecovery.recover(firstPass) { index in
            retried.append(index)
            return "retry \(index)"
        }
        XCTAssertEqual(values(outcome), ["a", "b"])
        XCTAssertTrue(retried.isEmpty)
        XCTAssertTrue(outcome.recoveredIndices.isEmpty)
        XCTAssertTrue(outcome.failedIndices.isEmpty)
        XCTAssertFalse(outcome.allFailed)
    }

    // MARK: - Mechanism A recovery

    func testFailedMiddleChunkIsRetriedAndSplicedInPlace() async {
        // Chunk 1 of 3 failed in the concurrent pass: its retry result must
        // land between chunks 0 and 2, not be appended at the end.
        let firstPass: [Result<String, Error>] = [.success("a"), .failure(ChunkError(index: 1)), .success("c")]
        var retried: [Int] = []
        let outcome = await ChunkRecovery.recover(firstPass) { index in
            retried.append(index)
            return "b"
        }
        XCTAssertEqual(values(outcome), ["a", "b", "c"])
        XCTAssertEqual(retried, [1])
        XCTAssertEqual(outcome.recoveredIndices, [1])
        XCTAssertTrue(outcome.failedIndices.isEmpty)
    }

    func testMultipleFailuresAreRetriedSequentiallyInOrder() async {
        let firstPass: [Result<String, Error>] = [
            .failure(ChunkError(index: 0)), .success("b"), .failure(ChunkError(index: 2)), .failure(ChunkError(index: 3)),
        ]
        var retried: [Int] = []
        let outcome = await ChunkRecovery.recover(firstPass) { index in
            retried.append(index)
            return "r\(index)"
        }
        XCTAssertEqual(retried, [0, 2, 3])
        XCTAssertEqual(values(outcome), ["r0", "b", "r2", "r3"])
        XCTAssertEqual(outcome.recoveredIndices, [0, 2, 3])
    }

    func testChunkThatFailsAgainStaysFailedWithItsRetryError() async {
        let firstPass: [Result<String, Error>] = [.success("a"), .failure(ChunkError(index: 1)), .failure(ChunkError(index: 2))]
        let outcome = await ChunkRecovery.recover(firstPass) { index in
            if index == 1 { throw ChunkError(index: 99) }
            return "c"
        }
        XCTAssertEqual(values(outcome), ["a", nil, "c"])
        XCTAssertEqual(outcome.recoveredIndices, [2])
        XCTAssertEqual(outcome.failedIndices, [1])
        XCTAssertFalse(outcome.allFailed)
        guard case let .failure(error) = outcome.results[1] else { return XCTFail("chunk 1 should still be failed") }
        XCTAssertEqual(error as? ChunkError, ChunkError(index: 99))
    }

    // MARK: - Systemic failure

    func testAllChunksFailedIsNotRetried() async {
        // Every chunk failing means the pipeline itself is broken, not one
        // chunk — leave the decision (reload / retry ladder) to the caller.
        let firstPass: [Result<String, Error>] = [.failure(ChunkError(index: 0)), .failure(ChunkError(index: 1))]
        var retried: [Int] = []
        let outcome = await ChunkRecovery.recover(firstPass) { index in
            retried.append(index)
            return "x"
        }
        XCTAssertTrue(retried.isEmpty)
        XCTAssertTrue(outcome.allFailed)
        XCTAssertEqual(outcome.failedIndices, [0, 1])
        XCTAssertEqual(outcome.firstError as? ChunkError, ChunkError(index: 0))
    }

    func testEmptyInputIsAllFailedWithNoError() async {
        let outcome = await ChunkRecovery.recover([Result<String, Error>]()) { _ in "x" }
        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertTrue(outcome.allFailed)
        XCTAssertNil(outcome.firstError)
    }
}
