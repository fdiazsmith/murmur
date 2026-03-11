import Foundation

protocol TranscriptionProvider {
    func transcribe(fileURL: URL) async throws -> String
}
