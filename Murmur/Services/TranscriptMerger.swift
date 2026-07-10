import Foundation

/// Merges the per-chunk transcription results WhisperKit returns for a single
/// recording into one string, defending against the two ways chunked decoding
/// produces repeated text:
///
/// 1. Boundary duplication — adjacent VAD chunks re-transcribe the same words
///    around the split, so the tail of one chunk repeats the head of the next.
/// 2. Hallucination loops — a single chunk gets stuck repeating a sentence or
///    phrase over and over.
///
/// Comparison is done on a normalized form (lowercased, punctuation stripped)
/// so that casing and punctuation differences don't hide a repeat, but the
/// surviving text keeps its original casing and punctuation. The collapse rules
/// are deliberately conservative: short intentional repeats like "no, no, no"
/// are left untouched.
enum TranscriptMerger {
    /// Minimum word-level overlap at a chunk boundary before we treat it as a
    /// duplicate and drop it. Below this we assume the repeat is coincidental.
    private static let minBoundaryOverlap = 4

    /// Minimum length (in words) of a phrase for the loop-collapse rule to fire.
    private static let minLoopPhraseWords = 4

    /// Minimum number of consecutive repeats of a phrase before we collapse it.
    private static let minLoopRepeats = 3

    /// Merge WhisperKit chunk texts into a single, de-duplicated transcript.
    static func merge(_ chunks: [String]) -> String {
        let cleaned = chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "" }

        // Phase 1: join chunks, dropping any verbatim overlap at each boundary.
        var words: [String] = []
        var norms: [String] = []
        for chunk in cleaned {
            let chunkWords = tokenize(chunk)
            let chunkNorms = chunkWords.map(normalizeWord)
            if words.isEmpty {
                words = chunkWords
                norms = chunkNorms
                continue
            }
            let drop = boundaryOverlap(tail: norms, head: chunkNorms)
            words.append(contentsOf: chunkWords[drop...])
            norms.append(contentsOf: chunkNorms[drop...])
        }

        // Phase 2: collapse a phrase repeated many times in a row (loops).
        words = collapsePhraseLoops(words, normalized: norms)

        // Phase 3: collapse consecutive identical sentences down to one.
        return collapseSentenceLoops(words.joined(separator: " "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Normalization

    /// Whitespace-separated tokens, preserving original casing/punctuation.
    static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Lowercased, alphanumerics only — used for repeat comparison, never output.
    static func normalizeWord(_ word: String) -> String {
        let scalars = word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Normalized sentence key: lowercased, punctuation replaced by spaces,
    /// runs of whitespace collapsed.
    static func normalizeSentence(_ sentence: String) -> String {
        let mapped = sentence.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(mapped).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Phase 1: boundary overlap

    /// Longest word count `k >= minBoundaryOverlap` such that the last `k`
    /// normalized words of `tail` equal the first `k` of `head`. Returns 0 when
    /// no overlap of at least the minimum length exists.
    static func boundaryOverlap(tail: [String], head: [String]) -> Int {
        var k = min(tail.count, head.count)
        while k >= minBoundaryOverlap {
            if Array(tail.suffix(k)) == Array(head.prefix(k)) {
                return k
            }
            k -= 1
        }
        return 0
    }

    // MARK: - Phase 2: phrase-loop collapse

    /// Collapse any phrase of `>= minLoopPhraseWords` words repeated
    /// `>= minLoopRepeats` times back-to-back down to a single occurrence.
    static func collapsePhraseLoops(_ words: [String], normalized: [String]) -> [String] {
        precondition(words.count == normalized.count)
        var out: [String] = []
        var i = 0
        let n = words.count
        while i < n {
            var collapsed = false
            let maxLen = (n - i) / minLoopRepeats
            if maxLen >= minLoopPhraseWords {
                var length = minLoopPhraseWords
                while length <= maxLen {
                    let base = Array(normalized[i ..< i + length])
                    var repeats = 1
                    while i + (repeats + 1) * length <= n {
                        let next = Array(normalized[(i + repeats * length) ..< (i + (repeats + 1) * length)])
                        if next == base { repeats += 1 } else { break }
                    }
                    if repeats >= minLoopRepeats {
                        out.append(contentsOf: words[i ..< i + length])
                        i += repeats * length
                        collapsed = true
                        break
                    }
                    length += 1
                }
            }
            if !collapsed {
                out.append(words[i])
                i += 1
            }
        }
        return out
    }

    // MARK: - Phase 3: sentence-loop collapse

    /// Split into sentences on `. ! ?` and drop consecutive duplicates.
    static func collapseSentenceLoops(_ text: String) -> String {
        let sentences = splitSentences(text)
        guard !sentences.isEmpty else { return "" }
        var out: [String] = []
        var previousKey: String?
        for sentence in sentences {
            let key = normalizeSentence(sentence)
            if !key.isEmpty && key == previousKey {
                continue
            }
            out.append(sentence)
            previousKey = key.isEmpty ? nil : key
        }
        return out.joined(separator: " ")
    }

    /// Break text into trimmed, non-empty sentences, keeping terminal punctuation.
    static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty { sentences.append(trailing) }
        return sentences
    }
}
