import CoreML
import WhisperKit

// Workarounds for two WhisperKit 0.16 decoder bugs that only bite when a
// profile prompt is set. With `promptTokens`, WhisperKit skips the KV prefill
// cache and forces `<|startofprev|> prompt… <|startoftranscript|> [lang] task
// <|0.00|>` through the decoder one token per loop step. Logits filters see
// the same token list (that full initial prompt) during every forced step and
// the first real sample; after that, sampled tokens are appended.

/// Bug 1: WhisperKit still samples a "prediction" at each forced step and ends
/// the window as soon as it is `<|endoftext|>` (`isSegmentCompleted` doesn't
/// check `isPrefill`). The prediction after a forced prompt token is routinely
/// EOT, so on large-v3 turbo every chunk came back "" while coverage read 100%.
/// (Its `suppressBlank` filter, which would cover the first real step, never
/// fires with a prompt: it compares against the prefill-cache index, 0 then.)
///
/// Suppressing EOT while nothing has been sampled yet stops prefill from ending
/// the window; at the first real step it is whisper's standard suppress-blank.
struct PromptPrefillEndFilter: LogitsFiltering {
    let specialTokens: SpecialTokens

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        guard Self.shouldSuppressEnd(tokens: tokens, specialTokens: specialTokens) else { return logits }
        logits.fill(indexes: [[0, 0, specialTokens.endToken as NSNumber]], with: -FloatType.infinity)
        return logits
    }

    /// True while `tokens` is still just the initial prompt of a prompted
    /// decode: the task token followed by the prompt's closing timestamp (or
    /// `<|notimestamps|>`). The closing token may be any timestamp, not only
    /// `<|0.00|>`: on the last forced step WhisperKit keeps the model's own
    /// timestamp prediction in its place. Once anything is sampled, the token
    /// before the last is no longer the task token.
    static func shouldSuppressEnd(tokens: [Int], specialTokens: SpecialTokens) -> Bool {
        guard tokens.first == specialTokens.startOfPreviousToken, tokens.count >= 2 else { return false }
        let penultimate = tokens[tokens.count - 2]
        let last = tokens[tokens.count - 1]
        let afterTask = penultimate == specialTokens.transcribeToken || penultimate == specialTokens.translateToken
        let closesPrompt = last >= specialTokens.timeTokenBegin || last == specialTokens.noTimestampsToken
        return afterTask && closesPrompt
    }
}

/// Bug 2: on multilingual models (large-v3 turbo) `TimestampRulesFilter` finds
/// where sampling begins by looking for the task token in the first 3 tokens.
/// With a prompt the list starts with `<|startofprev|>`, so it finds nothing
/// and silently skips the timestamp rules for the whole decode — no pairing,
/// no monotonic timestamps — producing nonsense segments (e.g. 2.0–31.98s on
/// silence) that break both the coverage diagnostics and in-window re-seek.
///
/// This re-applies WhisperKit's own `TimestampRulesFilter` on prompted decodes
/// with sampling begin located after the task token and closing timestamp.
/// Install it only for multilingual models: for `.en` models WhisperKit's
/// built-in filter already uses the right index.
struct PromptTimestampRulesFilter: LogitsFiltering {
    let specialTokens: SpecialTokens

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        guard let sampleBegin = Self.sampleBegin(tokens: tokens, specialTokens: specialTokens) else { return logits }
        // Single-index rules (isModelMultilingual: false) with an explicit
        // begin — the same rules WhisperKit applies to unprompted decodes.
        let rules = TimestampRulesFilter(
            specialTokens: specialTokens,
            sampleBegin: sampleBegin,
            maxInitialTimestampIndex: nil,
            isModelMultilingual: false
        )
        return rules.filterLogits(logits, withTokens: tokens)
    }

    /// Index of the first sampled token in a prompted, timestamped decode, or
    /// nil when the decode is unprompted (WhisperKit's filter handles it) or
    /// runs without timestamps (no rules to apply). Prompt tokens are all text
    /// tokens, so the first task token is the real one.
    static func sampleBegin(tokens: [Int], specialTokens: SpecialTokens) -> Int? {
        guard tokens.first == specialTokens.startOfPreviousToken,
              let taskIndex = tokens.firstIndex(where: { $0 == specialTokens.transcribeToken || $0 == specialTokens.translateToken }),
              taskIndex + 1 < tokens.count,
              tokens[taskIndex + 1] >= specialTokens.timeTokenBegin
        else { return nil }
        return taskIndex + 2
    }
}
