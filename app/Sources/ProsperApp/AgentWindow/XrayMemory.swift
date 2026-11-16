import Foundation

/// One session's memories and instruction files as `dch --xray <n> --memory --json` prints them (NDJSON: a header
/// without session keys, memory rows, a done line). Every string is outside data. Dates and line limits are XrayTasks'.
struct XrayMemory: Equatable {
    enum Kind: String, Equatable { case user, feedback, project, reference, instructions }
    enum Scope: String, Equatable { case managed, user, project }
    enum Session: String, Equatable { case wrote, loaded }

    struct Item: Equatable {
        var id: String
        var title: String
        var note: String?
        /// nil for null and for a word Prosper does not know; kindWord then holds the cleaned word (nil only for null).
        var kind: Kind?
        var kindWord: String?
        var scope: Scope?
        var scopeWord: String?
        var updated: Date?
        /// Kept raw for a later open; never opened here and never shown.
        var path: String
        var session: Session?
        var sessionWord: String?
        var chapter: String?          // an anchor: checked by DchCtl.anchorOK before any use, never shown
        /// Cleaned, newlines kept (see cleanBody). nil when dch sent null (over 1 MB, symlink, not a regular file).
        var body: String?
        /// dch cut the body, or the 16 KB cap here did.
        var cut: Bool
    }

    struct Group: Equatable {
        var title: String
        var items: [Item]
    }

    var source: String?
    var title: String?
    /// The header's partial flag, or no done line (the output was cut).
    var partial: Bool
    var headerWarn: String?
    var doneWarn: String?
    var droppedCount: Int
    /// Lines left out here: over 64 KB, past the row limit, or not valid JSON for any line kind.
    var skippedLines: Int
    var items: [Item]

    static let maxBody = 16 * 1024

    /// Count = every row (dch's own rule).
    var count: Int { items.count }

    /// This session (any session word, newest first), Memories, Instructions (load order = dch's order); empty groups left out.
    var groups: [Group] {
        let mine = items.enumerated().filter { $0.element.sessionWord != nil }.sorted { a, b in
            switch (a.element.updated, b.element.updated) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
        let rest = items.filter { $0.sessionWord == nil }
        return [Group(title: "This session", items: mine),
                Group(title: "Memories", items: rest.filter { $0.kind != .instructions }),
                Group(title: "Instructions", items: rest.filter { $0.kind == .instructions })].filter { !$0.items.isEmpty }
    }

    // MARK: wire

    private struct Header: Decodable {
        let schema: Int
        let source: String?
        let title: String?
        let partial: Bool?
        let warn: String?
    }

    private struct Row: Decodable {
        struct M: Decodable {
            let id: String?
            let title: String?
            let note: String?
            let kind: String?
            let scope: String?
            let updated: String?
            let path: String?
            let session: String?
            let chapter: String?
            let body: String?
            let cut: Bool?
        }
        let memory: M
    }

    private struct DoneLine: Decodable {
        let done: Bool
        let count: Int?
        let dropped: Int?
        let warn: String?
    }

    /// OutsideText.shown drops every control scalar, newline included, so it is applied per line (split on U+000A) and the
    /// lines are joined again: a CR, tab or bidi scalar goes, the line breaks stay. Then at most 16 KB of UTF-8, cut on a scalar.
    static func cleanBody(_ raw: String) -> (text: String, cut: Bool) {
        let text = raw.components(separatedBy: "\n")   // not split(separator:): a CR LF is one Character
            .map { OutsideText.shown($0, max: Int.max) }.joined(separator: "\n")
        guard text.utf8.count > maxBody else { return (text, false) }
        var out = String.UnicodeScalarView(), bytes = 0
        for u in text.unicodeScalars {
            bytes += String(u).utf8.count
            if bytes > maxBody { break }
            out.append(u)
        }
        return (String(out), true)
    }

    private static func item(_ m: Row.M) -> Item {
        let body = m.body.map(cleanBody)
        return Item(id: OutsideText.shown(m.id ?? "", max: 64), title: OutsideText.shown(m.title ?? "", max: 120),
                    note: m.note.map { OutsideText.shown($0, max: 120) },
                    kind: m.kind.flatMap(Kind.init(rawValue:)), kindWord: m.kind.map { OutsideText.shown($0, max: 40) },
                    scope: m.scope.flatMap(Scope.init(rawValue:)), scopeWord: m.scope.map { OutsideText.shown($0, max: 40) },
                    updated: XrayTasks.date(m.updated), path: m.path ?? "",
                    session: m.session.flatMap(Session.init(rawValue:)), sessionWord: m.session.map { OutsideText.shown($0, max: 40) },
                    chapter: m.chapter, body: body?.text, cut: (m.cut ?? false) || (body?.cut ?? false))
    }

    /// The parse: bytes in, never throws; a bad line is counted and skipped.
    static func parse(_ data: Data) -> XrayMemory {
        var r = XrayMemory(source: nil, title: nil, partial: true, headerWarn: nil, doneWarn: nil, droppedCount: 0,
                           skippedLines: 0, items: [])
        var sawDone = false, headerPartial = false, rows = 0
        let dec = JSONDecoder()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if line.count > XrayTasks.maxLine { r.skippedLines += 1; continue }
            if let row = try? dec.decode(Row.self, from: line) {
                rows += 1
                if rows > XrayTasks.maxRows { r.skippedLines += 1 } else { r.items.append(item(row.memory)) }
            } else if let d = try? dec.decode(DoneLine.self, from: line), d.done {
                sawDone = true
                r.droppedCount = max(0, d.dropped ?? 0)
                r.doneWarn = d.warn.map { OutsideText.shown($0, max: 160) }
            } else if let h = try? dec.decode(Header.self, from: line) {
                r.source = h.source.map { OutsideText.shown($0, max: 40) }
                r.title = h.title.map { OutsideText.shown($0, max: 120) }
                headerPartial = h.partial ?? false
                r.headerWarn = h.warn.map { OutsideText.shown($0, max: 160) }
            } else { r.skippedLines += 1 }
        }
        r.partial = headerPartial || !sawDone
        return r
    }
}
