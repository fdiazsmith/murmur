import Foundation
import WhisperKit

final class LocalTranscriber: TranscriptionProvider {
    private var whisperKit: WhisperKit?

    /// Whisper model variant to use (e.g. "tiny.en", "base", "small.en").
    var modelVariant: String?

    /// Called on main thread with (fractionCompleted 0-1, status string).
    var onProgress: ((Double, String) -> Void)?

    var isReady: Bool { whisperKit != nil }

    /// Force re-initialization on next transcription (e.g. after model change).
    func invalidate() {
        whisperKit = nil
    }

    func transcribe(fileURL: URL, prompt: String) async throws -> String {
        let kit = try await resolveWhisperKit()

        do {
            var options = DecodingOptions(
                temperatureFallbackCount: 2,
                chunkingStrategy: .vad
            )
            if !prompt.isEmpty, let tokenizer = kit.tokenizer {
                options.promptTokens = tokenizer.encode(text: prompt)
            }
            let results = try await kit.transcribe(audioPath: fileURL.path, decodeOptions: options)
            return results.compactMap(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        } catch {
            print("[Murmur] WhisperKit error, will reinit next call: \(error)")
            whisperKit = nil
            throw error
        }
    }

    /// Pre-warms the model (downloads if needed). Safe to call multiple times.
    func warmup() async {
        guard whisperKit == nil else { return }
        do {
            _ = try await resolveWhisperKit()
        } catch {
            print("[Murmur] Model warmup failed: \(error)")
        }
    }

    private func resolveWhisperKit() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }

        let progressCb = self.onProgress
        let config = WhisperKitConfig(
            model: modelVariant,
            verbose: false,
            prewarm: false,
            load: true,
            download: true
        )
        let kit = try await WhisperKit(config)

        kit.modelStateCallback = { [weak self] _, newState in
            guard let self else { return }
            let status: String
            switch newState {
            case .downloading: status = "Downloading model…"
            case .downloaded:  status = "Download complete"
            case .loading:     status = "Loading model…"
            case .loaded:      status = "Ready"
            case .prewarming:  status = "Preparing model…"
            default:           status = ""
            }
            if !status.isEmpty {
                Task { @MainActor in progressCb?(1.0, status) }
            }
        }

        print("[Murmur] WhisperKit: \(kit.modelVariant), \(kit.modelState)")
        Task { @MainActor in progressCb?(1.0, "Ready") }
        whisperKit = kit
        return kit
    }
}
