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
        /// and "large-v3-v20240930_turbo_632MB" matches the compressed folder
        /// `openai_whisper-large-v3-v20240930_turbo_632MB`. A variant must be
        /// specific enough that the glob hits a single folder.
        let variant: String
        let label: String
    }

    /// OpenAI's large-v3 turbo (Sept 2024 release: large-v3 encoder, 4-layer
    /// decoder) in WhisperKit's compressed 632 MB build: same accuracy class
    /// as the full-size turbo, 10-30% faster to decode on Apple Silicon.
    static let defaultVariant = "large-v3-v20240930_turbo_632MB"

    /// Full-size (uncompressed) large-v3 turbo.
    static let fullTurboVariant = "large-v3-v20240930"

    /// Earlier defaults (base, then full-size turbo); a stored pick of one is
    /// upgraded once by `resolveStoredVariant`.
    static let legacyDefaultVariants: Set<String> = ["base", fullTurboVariant]

    static let options: [Option] = [
        Option(variant: "tiny.en", label: "tiny.en (fastest)"),
        Option(variant: "base.en", label: "base.en"),
        Option(variant: "small.en", label: "small.en"),
        Option(variant: defaultVariant, label: "large-v3 turbo (best)"),
        Option(variant: fullTurboVariant, label: "large-v3 turbo full-size (slower)"),
    ]

    static var variants: [String] { options.map(\.variant) }

    static func label(for variant: String) -> String {
        options.first(where: { $0.variant == variant })?.label ?? variant
    }

    /// Map a stored `whisperModelVariant` onto an offered model.
    /// - Parameter migrationDone: whether the one-time upgrade of an earlier
    ///   default to the current one already ran, so a later deliberate pick of
    ///   an old default is respected.
    static func resolveStoredVariant(_ stored: String?, migrationDone: Bool) -> String {
        guard let stored else { return defaultVariant }
        if !migrationDone && legacyDefaultVariants.contains(stored) { return defaultVariant }
        if variants.contains(stored) { return stored }
        // A dropped multilingual small model keeps its size as the .en sibling.
        if variants.contains(stored + ".en") { return stored + ".en" }
        return defaultVariant
    }
}
