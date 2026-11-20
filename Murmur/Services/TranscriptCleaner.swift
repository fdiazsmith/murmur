import Foundation

/// Tidies one piece of raw recognizer output before it is merged and pasted.
enum TranscriptCleaner {
    /// Non-speech annotations Whisper emits for noise or silence.
    private static let annotation = try! NSRegularExpression(
        pattern: #"[\[(]\s*(blank[_ ]audio|music|silence|noise|inaudible|applause|laughter|laughs|no audio|no speech|sighs?|coughs?|typing|keyboard clicking)[^\])]{0,20}[\])]|♪+"#,
        options: [.caseInsensitive]
    )

    /// What Whisper says when handed (near) silence — artefacts of its
    /// training on subtitled video.
    private static let silenceHallucinations: Set<String> = [
        "thank you", "thanks", "thank you very much", "thanks for watching", "thank you for watching",
        "you", "bye", "bye bye", "okay", "so", "the", "i", "oh", "uh", "um", "hmm",
        "please subscribe", "subtitles by the amara org community", "see you next time",
    ]

    /// Below this much detected speech a known silence phrase is treated as a
    /// hallucination; with real speech behind it, it is kept.
    static let hallucinationSpeechLimit: Double = 0.25

    /// - Parameter speechDuration: seconds of speech the pause detector heard
    ///   in the audio this text came from, or nil when unknown.
    static func clean(_ raw: String, speechDuration: Double? = nil) -> String {
        let range = NSRange(raw.startIndex..., in: raw)
        var text = annotation.stringByReplacingMatches(in: raw, range: range, withTemplate: " ")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if let speechDuration, speechDuration < hallucinationSpeechLimit,
           silenceHallucinations.contains(normalized(text)) {
            return ""
        }
        // Punctuation only ("." / "...") is an empty decode.
        if normalized(text).isEmpty { return "" }
        return text
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }
}
