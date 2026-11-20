import Foundation

/// What a provider knows about a piece of audio besides the samples.
struct TranscriptionContext {
    /// The active profile's prompt (vocabulary / style hints). May be empty.
    var prompt: String = ""
    /// Text transcribed just before this audio in the same dictation.
    var previousText: String = ""
}

protocol TranscriptionProvider: AnyObject {
    /// Whether pieces of a dictation can be transcribed while it is still
    /// being recorded (cheap, local) or only the whole thing once (one upload).
    var supportsStreaming: Bool { get }

    /// Transcribe 16 kHz mono samples. Honors task cancellation.
    func transcribe(samples: [Float], context: TranscriptionContext) async throws -> String
}
