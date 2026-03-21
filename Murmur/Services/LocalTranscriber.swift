import Foundation
import WhisperKit

final class LocalTranscriber: TranscriptionProvider {
    private var whisperKit: WhisperKit?

    func transcribe(fileURL: URL) async throws -> String {
        let kit = try await resolveWhisperKit()
        let results = try await kit.transcribe(audioPath: fileURL.path)
        return results.compactMap(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private func resolveWhisperKit() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        let kit = try await WhisperKit(WhisperKitConfig(downloadBase: Self.modelCacheURL()))
        whisperKit = kit
        return kit
    }

    /// Stable model cache in Application Support — survives relaunches and rebuilds.
    static func modelCacheURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Murmur/HuggingFace")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
