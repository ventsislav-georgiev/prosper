import Foundation

/// #1415 (#1356 step 1, dch README "Refs"): the `refs` of `dch --xray <n> --json`, the same object XrayChapters reads.
/// Every string is outside data (OutsideText.shown). Gated off (XrayPanels.refsTab) until the ref card ships.
struct XrayRefs: Equatable {
    /// dch's shapes; a word Prosper does not know stays a row with a generic kind (shape nil).
    enum Shape: String, Equatable { case issue, pull, ticket, commit, file, url
        /// dch 1.93.0 (#458): a backticked span or a CONST_CASE/snake_case identifier; always defined:false, its one definition is the first mention.
        case term
    }

    struct Entry: Equatable {
        var key: String
        var shape: Shape?
        var text: String
        /// A commit's hex as written.
        var full: String?
        var count: Int
        /// The byte offset (or ring seq) of the latest mention; nil from a dch before 1.62.0.
        var lastOffset: Int?
        var defined: Bool
        var definitions: Int
        var title: String
        var underline: Bool
        /// The place in dch's list (its own order: count, then first seen).
        var index: Int
    }

    var entries: [Entry]
    var droppedKeys: Int
    var complete: Bool
    var why: String?
    var sessionID: String?

    /// Caps: dch holds at most 2000 keys (README "refs"); a ref's text is 1-256 bytes (README "--ref"); a title 120
    /// scalars. A row past them is dropped (rows past maxRows count in droppedKeys).
    static let maxRows = 2000
    static let maxRefBytes = 256
    static let titleCap = 120

    /// The parse: bytes in, never throws; nil (no refs) unless one object with schema 1 and a refs array. A row that is
    /// not an object, has no text, or whose key or text is over 256 bytes is skipped and counted in droppedKeys (R1415-i1 a).
    static func parse(_ data: Data) -> XrayRefs? {
        guard data.count <= XrayChapters.maxBytes, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(o)
    }

    /// #1475: the same parse of an object in hand (a follow's snapshot with its deltas applied, XrayFollow.swift).
    static func parse(_ o: [String: Any]) -> XrayRefs? {
        guard o["schema"] as? Int == 1, let list = o["refs"] as? [Any] else { return nil }
        func int(_ v: Any?) -> Int? { (v as? Int).map { min(max(0, $0), Int(Int32.max)) } }   // bounded: no overflow below
        let entries = list.prefix(maxRows).enumerated().compactMap { (k, v) -> Entry? in
            guard let c = v as? [String: Any], let rawText = c["text"] as? String, !rawText.isEmpty,
                  rawText.utf8.count <= maxRefBytes, ((c["key"] as? String) ?? "").utf8.count <= maxRefBytes else { return nil }
            let shapeWord = (c["shape"] as? String) ?? ""
            let title = (c["title"] as? String).map { String($0.unicodeScalars.prefix(titleCap)) } ?? ""
            return Entry(key: OutsideText.shown(c["key"] as? String ?? "", max: maxRefBytes), shape: Shape(rawValue: shapeWord),
                         text: OutsideText.shown(rawText, max: maxRefBytes),
                         full: (c["full"] as? String).map { OutsideText.shown($0, max: 40) }, count: int(c["count"]) ?? 0,
                         lastOffset: int(c["last_offset"]), defined: c["defined"] as? Bool == true,
                         definitions: int(c["definitions"]) ?? 0, title: OutsideText.shown(title, max: titleCap),
                         underline: c["underline"] as? Bool == true, index: k)
        }
        // both counts are of arrays in hand (at most the 16 MiB read): no overflow; dch's count is bounded by int
        let over = list.count - entries.count
        return XrayRefs(entries: entries, droppedKeys: (int(o["dropped_keys"]) ?? 0) + over,
                        complete: o["complete"] as? Bool != false, why: (o["why"] as? String).map { OutsideText.shown($0, max: 40) },
                        sessionID: (o["session_id"] as? String).map { OutsideText.shown($0, max: 64) })
    }

    /// dch's Refs order: latest mention first (last_offset), then count, then later in dch's list first; terms after the
    /// rest (#1489, dch #459: a term never crowds out an issue, a pull or a ticket).
    var ordered: [Entry] {
        entries.sorted { a, b in
            if (a.shape == .term) != (b.shape == .term) { return b.shape == .term }
            if (a.lastOffset ?? -1) != (b.lastOffset ?? -1) { return (a.lastOffset ?? -1) > (b.lastOffset ?? -1) }
            if a.count != b.count { return a.count > b.count }
            return a.index > b.index
        }
    }

    /// dch's default view: issues, pulls and tickets (and a shape it does not know, so no row is lost); `a` shows the rest.
    static func byDefault(_ e: Entry) -> Bool { ![XrayRefs.Shape.commit, .file, .url].contains { $0 == e.shape } }
}

/// One Refs row as drawn and spoken: the ref (a file relative to the cwd, else with ~), its title faint, its count.
struct XrayRefRow: Equatable {
    let text: String
    let title: String
    let count: String
    let bold: Bool
    let spoken: String

    static func kind(_ s: XrayRefs.Shape?) -> String {
        switch s {
        case .issue: "Issue"
        case .pull: "Pull request"
        case .ticket: "Ticket"
        case .commit: "Commit"
        case .file: "File"
        case .url: "Link"
        case .term: "Term"
        case nil: "Ref"
        }
    }

    /// `complete` false: dch's counts are lower bounds, so "\u{2265}" goes before them.
    init(_ e: XrayRefs.Entry, complete: Bool, home: String, cwd: String?) {
        // dch keys a file absolute against the cwd (`file:/...`); the text is as written
        let path = e.key.hasPrefix("file:/") ? String(e.key.dropFirst(5)) : e.text
        text = e.shape == .file ? XrayMemoryRow.shortPath(path, home: home, cwd: cwd) : e.text
        title = e.title
        count = (complete ? "" : "\u{2265}") + "\(e.count)"
        bold = e.defined || e.count >= 2
        let mentions = (complete ? "" : "at least ") + "\(e.count) mention\(e.count == 1 ? "" : "s")"
        spoken = [Self.kind(e.shape) + " " + text, title, mentions].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
