import Foundation

/// The local Whisper models offered in the menu, and how a stored preference
/// maps onto them.
///
/// Murmur never sets a decoding language, so WhisperKit forces `<|en|>` on
/// multilingual models: the multilingual tiny/base/small are strictly worse
/// than their `.en` siblings here and are not offered. large-v3 turbo has no
/// `.en` variant and is the accuracy pick.
enum WhisperModelCatalog {
    struct Option {
        /// WhisperKit `model:` string. WhisperKit resolves it against the
        /// argmaxinc/whisperkit-coreml repo with the glob `*<variant>/*`, so
        /// "large-v3-v20240930" matches exactly `openai_whisper-large-v3-v20240930`
        /// (not the `_626MB` / `_turbo_632MB` compressed folders).
        let variant: String
        let label: String
    }

    /// OpenAI's large-v3 turbo (Sept 2024 release: large-v3 encoder, 4-layer decoder).
    static let defaultVariant = "large-v3-v20240930"

    /// The default before large-v3 turbo; upgraded once by `resolveStoredVariant`.
    static let legacyDefaultVariant = "base"

    static let options: [Option] = [
        Option(variant: "tiny.en", label: "tiny.en (fastest)"),
        Option(variant: "base.en", label: "base.en"),
        Option(variant: "small.en", label: "small.en"),
        Option(variant: defaultVariant, label: "large-v3 turbo (best)"),
    ]

    static var variants: [String] { options.map(\.variant) }

    static func label(for variant: String) -> String {
        options.first(where: { $0.variant == variant })?.label ?? variant
    }

    /// Map a stored `whisperModelVariant` onto an offered model.
    /// - Parameter migrationDone: whether the one-time base -> large-v3 turbo
    ///   upgrade already ran, so a later deliberate pick of base is respected.
    static func resolveStoredVariant(_ stored: String?, migrationDone: Bool) -> String {
        guard let stored else { return defaultVariant }
        if !migrationDone && stored == legacyDefaultVariant { return defaultVariant }
        if variants.contains(stored) { return stored }
        // A dropped multilingual small model keeps its size as the .en sibling.
        if variants.contains(stored + ".en") { return stored + ".en" }
        return defaultVariant
    }
}
