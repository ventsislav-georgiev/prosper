import Foundation

/// One saved snippet surfaced to the runner UI and the inline expander.
///
/// `keyword` is the bare trigger as the user typed it in the editor (no spaces /
/// quotes — see `SnippetStore.sanitizeKeyword`). The *effective* trigger that
/// fires an expansion is `collection.prefix + keyword + collection.suffix`
/// (Alfred-style collection affixes); see `SnippetStore.effectiveKeywords()`.
///
/// `text` holds the snippet body. For a plain snippet it is the literal template
/// (with `{placeholder}` tokens resolved at insert time by `PlaceholderEngine`).
/// For a rich snippet (`richText == true`) it holds an RTF document string; the
/// placeholder tokens still apply to its plain-text runs.
struct SnippetHit: Sendable, Equatable, Identifiable {
    let name: String
    let keyword: String
    let text: String
    let collection: String
    let description: String
    let autoExpand: Bool
    let richText: Bool

    /// Identity is the (unique) name — the same convention `QuicklinkHit` uses.
    var id: String { name }

    init(name: String, keyword: String = "", text: String, collection: String = "",
         description: String = "", autoExpand: Bool = true, richText: Bool = false) {
        self.name = name
        self.keyword = keyword
        self.text = text
        self.collection = collection
        self.description = description
        self.autoExpand = autoExpand
        self.richText = richText
    }
}

/// A snippet collection (folder). Beyond grouping, a collection can carry an
/// `affix`: a `prefix` prepended and/or `suffix` appended to *every* member
/// keyword to form its effective trigger (Alfred parity — e.g. a `;;` prefix
/// turns keyword `addr` into the trigger `;;addr`).
struct SnippetCollection: Sendable, Equatable, Identifiable {
    let name: String
    let prefix: String
    let suffix: String

    var id: String { name }

    init(name: String, prefix: String = "", suffix: String = "") {
        self.name = name
        self.prefix = prefix
        self.suffix = suffix
    }
}
