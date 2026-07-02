import Foundation

/// Session-local recall of sentences the user has recently written (any app).
/// People retype the same sentence often — telling a second person the same
/// thing, or rewriting a line they just deleted. When the current unfinished
/// sentence is a prefix of a recently written one, its remainder is the
/// highest-confidence completion available: it is the user's OWN phrasing,
/// deterministic, and instant (no model round-trip).
///
/// In-memory only (never persisted), capped, session-scoped. Fed from the text
/// the engine already reads for completion requests; secure-input contexts
/// never reach this point (the engine bails before requesting).
@MainActor
final class RecentSentences {
    static let shared = RecentSentences()

    /// Newest-last. `key` is the dedupe identity (lowercased trimmed text).
    private var entries: [(key: String, text: String)] = []
    private let cap = 200

    /// Characters that end a sentence. Newlines count: a line the user finished
    /// is as re-typeable as a sentence.
    nonisolated private static let terminators = CharacterSet(charactersIn: ".!?\n")

    /// Harvest completed sentences from the text before the caret. Only the last
    /// ~600 chars are scanned (older text was ingested by earlier requests).
    /// The trailing unterminated fragment is NOT stored — it is still being typed.
    func ingest(before: String) {
        let window = String(before.suffix(600))
        var sentence = ""
        for ch in window {
            sentence.append(ch)
            if ch.unicodeScalars.allSatisfy({ Self.terminators.contains($0) }) {
                add(sentence)
                sentence = ""
            }
        }
        // `sentence` now holds the unfinished tail — deliberately dropped.
    }

    private func add(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Too short to be a re-typeable thought (also skips "..." runs and
        // stray terminators). Word requirement keeps single-word lines out.
        guard text.count >= 12, text.contains(" ") else { return }
        let key = text.lowercased()
        if let i = entries.firstIndex(where: { $0.key == key }) {
            entries.remove(at: i) // re-written → bump to newest
        }
        entries.append((key, text))
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
    }

    /// If the current unfinished sentence (the text after the last terminator)
    /// is a prefix of a recently written sentence, return that sentence's
    /// remainder — newest match wins. Case-insensitive on the prefix; the
    /// remainder keeps the stored casing.
    func continuation(for before: String) -> String? {
        let fragment = Self.currentFragment(of: before)
        guard fragment.count >= 4 else { return nil }
        let lower = fragment.lowercased()
        for entry in entries.reversed() {
            guard entry.key.hasPrefix(lower), entry.key != lower else { continue }
            let remainder = String(entry.text.dropFirst(fragment.count))
            guard remainder.count >= 2 else { continue }
            return remainder
        }
        return nil
    }

    /// The unfinished sentence being typed: text after the last terminator,
    /// leading whitespace trimmed.
    nonisolated static func currentFragment(of before: String) -> String {
        var fragment = ""
        for ch in before.reversed() {
            if ch.unicodeScalars.allSatisfy({ terminators.contains($0) }) { break }
            fragment.append(ch)
        }
        return String(fragment.reversed()).trimmingCharacters(in: .whitespaces)
    }

    /// Test seam.
    func reset() { entries.removeAll() }
}
