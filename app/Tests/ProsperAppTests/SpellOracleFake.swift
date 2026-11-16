import Foundation
@testable import ProsperApp

/// Deterministic stand-in for the Mac's spell checker (#1310): the autocomplete
/// guards ask `SpellOracle.current`, and a test class that reaches them installs
/// this fake in setUp so its verdicts never depend on which spelling
/// dictionaries the Mac has installed or selected.
@MainActor
extension SpellOracle {
    /// The words the fake knows. Anything else is "misspelled".
    static let fakeEnglishWords: Set<String> = [
        "the", "quick", "quickly", "brown", "browns", "brownie", "fox", "foxes",
        "jumps", "over", "lazy", "dog", "is", "always", "visit", "my", "website",
        "websites", "here", "going", "go", "to", "store", "am", "be", "recording",
        "soon", "dear", "team", "thank", "thanks", "you", "your", "for", "form",
        "forward", "patience", "hello", "hellos", "world", "download", "downloads",
        "please", "receive", "received", "and", "then", "we", "should", "done",
    ]

    /// A fake answering from `words`: misspelled = not in the list, guesses =
    /// list words within two edits (3+ letter input), completions = longer list
    /// words with the fragment as prefix. No installed language, no checker state.
    static func fake(words: Set<String> = fakeEnglishWords) -> SpellOracle {
        SpellOracle(
            languages: { [] },
            isMisspelled: { !words.contains($0.lowercased()) },
            setAutoIdentify: { _ in },
            isMisspelledIn: { word, _ in !words.contains(word.lowercased()) },
            guesses: { word in
                let w = word.lowercased()
                guard w.count >= 3 else { return [] }
                return words
                    .map { ($0, AutocompleteEngine.editDistance(w, $0)) }
                    .filter { $0.0 != w && $0.1 <= 2 }
                    .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
                    .map(\.0)
            },
            completions: { fragment, _ in
                let f = fragment.lowercased()
                return words.filter { $0.count > f.count && $0.hasPrefix(f) }.sorted()
            }
        )
    }
}
