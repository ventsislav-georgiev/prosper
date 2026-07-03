import Foundation

/// Writing-system classification for guided inline decoding (B1).
///
/// Prosper's wrong-language / foreign-script garbage (Devanagari or Greek bursts in
/// Cyrillic text, Cyrillic in English) is caught today *post-hoc* by sanitizer
/// guards (`mismatchedScript`, `containsForeignScript`) that reject a finished
/// completion and burn a retry rung. The decode-time analogue is to never let the
/// model emit an out-of-script token in the first place — the "guided decoding"
/// mechanism the recovered Cotypist source uses.
///
/// This is the pure, testable core: given a target script and a token's text piece,
/// decide whether that piece may be generated. `RequiredScriptLogitProcessor` turns
/// a whole vocabulary's verdicts into a logit mask.
///
/// It is deliberately COARSE — it constrains by *script*, not language. Bulgarian
/// vs. Russian (same Cyrillic script) is NOT separable here; that sister-language
/// leak stays the job of the dictionary gate (`containsRussianOnlyCyrillicWord`).
/// Latin letters are always allowed even under a Cyrillic target, so loanwords,
/// URLs, code identifiers, and emoji shortcodes are never blocked.
enum ScriptClassifier {

    /// The script the completion should stay within, derived from the user's text.
    enum Target: Equatable {
        /// Cyrillic context: allow Cyrillic + Latin + neutral; block other letters.
        case cyrillic
        /// Latin context: allow Latin + neutral; block non-Latin letters.
        case latin
        /// Unknown/mixed: no constraint (every piece allowed).
        case unconstrained
    }

    /// Whether a scalar is a Latin letter (basic + Latin-1/Extended-A/B ranges).
    static func isLatinLetter(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) // A–Z a–z
            || (v >= 0xC0 && v <= 0x24F && s.properties.isAlphabetic) // Latin-1/Ext-A/B
    }

    /// Whether a scalar is a Cyrillic letter (Cyrillic + Cyrillic Supplement blocks).
    static func isCyrillicLetter(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (v >= 0x0400 && v <= 0x04FF) || (v >= 0x0500 && v <= 0x052F)
    }

    /// True when `piece` may be generated under `target`. A piece is allowed unless
    /// it contains a letter from a blocked script. Non-letters (whitespace,
    /// punctuation, digits, symbols, the SentencePiece `▁` space marker) never block.
    static func isAllowed(_ piece: String, target: Target) -> Bool {
        guard target != .unconstrained else { return true }
        for scalar in piece.unicodeScalars {
            // Only letters can disqualify a piece; everything else is script-neutral.
            guard scalar.properties.isAlphabetic else { continue }
            if isLatinLetter(scalar) { continue } // Latin always allowed (loanwords).
            switch target {
            case .cyrillic:
                if !isCyrillicLetter(scalar) { return false } // block non-Cyr non-Lat.
            case .latin:
                return false // any non-Latin letter blocks under a Latin target.
            case .unconstrained:
                break
            }
        }
        return true
    }

    /// The target script for a run of the user's text: Cyrillic if it contains any
    /// Cyrillic letter, else Latin if it contains any Latin letter, else no
    /// constraint (digits/punctuation/emoji only — nothing to anchor on).
    static func target(for text: String) -> Target {
        var sawLatin = false
        for scalar in text.unicodeScalars {
            if isCyrillicLetter(scalar) { return .cyrillic }
            if isLatinLetter(scalar) { sawLatin = true }
        }
        return sawLatin ? .latin : .unconstrained
    }
}
