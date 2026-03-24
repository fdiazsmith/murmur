import Foundation
import WhisperKit

final class LocalTranscriber: TranscriptionProvider {
    private var whisperKit: WhisperKit?

    func transcribe(fileURL: URL, prompt: String) async throws -> String {
        let kit = try await resolveWhisperKit()
        if !prompt.isEmpty, let tokenizer = kit.tokenizer {
            let tokens = tokenizer.encode(text: prompt)
            let options = DecodingOptions(promptTokens: tokens)
            let results = try await kit.transcribe(audioPath: fileURL.path, decodeOptions: options)
            return results.compactMap(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
        let results = try await kit.transcribe(audioPath: fileURL.path)
        return results.compactMap(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private func resolveWhisperKit() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        let kit = try await WhisperKit()
        whisperKit = kit
        return kit
    }
}
