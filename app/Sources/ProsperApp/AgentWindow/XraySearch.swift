import Foundation

/// #1355 (X-ray P7, dch README "Search"): `dch --xray <n> --search <text> --json`'s one object as the Search tab's
/// rows. Every string is outside data: OutsideText.shown cleans it where it is drawn (XraySearchRow).
struct XraySearch: Equatable {
    struct Hit: Equatable {
        /// dch's `who`: "user", "assistant" or "tool" (any other word kept, capped).
        var who: String
        var tool: String?
        var at: Date?
        var snippet: String
    }

    var hits: [Hit]
    /// dch 1.94 (#457) keeps the hits of the newest 50 turns, up to 500, newest first; it says `more` past a 51st turn or a
    /// 501st hit. Prosper draws the first 50 hits (maxHits), so a host that sends more than 50 counts as `more` too.
    var more: Bool
    /// dch stopped early (`why`: "bytes", "time" or "range"); the hits shown stand.
    var partial: Bool
    var why: String?

    /// Caps: 50 drawn hits (the newest of dch's up to 500); a snippet 400 scalars (dch: about
    /// 160 bytes), a tool name 120, `who` and `why` 16; the whole answer 16 MiB (XrayPanels.maxReadBytes).
    static let maxHits = 50
    static let snippetCap = 400
    static let toolCap = 120
    static let wordCap = 16

    /// dch 1.94 (#456): a snippet that starts past the text's start begins with "\u{2026} ". Drawn as the cue that the text
    /// was cut; spoken without it. Only that leading pair goes, never one inside the text. (Search has no highlight.)
    static func withoutLeadingEllipsis(_ s: String) -> String {
        s.unicodeScalars.starts(with: "\u{2026} ".unicodeScalars) ? String(s.unicodeScalars.dropFirst(2)) : s
    }

    static let tooLarge = "The search answer was too large"
    static let cannotSearch = "This host\u{2019}s dch cannot search"
    static let refused = "Search was refused"
    /// The query rule, said where a query fails DchCtl.searchOK (nothing runs then).
    static let badQuery = "Search needs 2 to 200 bytes and no control character"

    /// The parse: bytes in, never throws; nil unless one object with schema 1 and a hits array. A hit that is not an
    /// object or has no snippet is skipped.
    static func parse(_ data: Data) -> XraySearch? {
        guard data.count <= XrayChapters.maxBytes, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["schema"] as? Int == 1, let list = o["hits"] as? [Any] else { return nil }
        func text(_ v: Any?, _ max: Int) -> String? { (v as? String).map { String($0.unicodeScalars.prefix(max)) } }
        let rows = list.compactMap { $0 as? [String: Any] }
        let hits = rows.prefix(maxHits).compactMap { h -> Hit? in
            guard let snippet = text(h["snippet"], snippetCap) else { return nil }
            // bounded before Date: a far time from outside stays in range
            let at = (h["at"] as? Double).flatMap { (0...1e10).contains($0) ? Date(timeIntervalSince1970: $0) : nil }
            return Hit(who: text(h["who"], wordCap) ?? "", tool: text(h["tool"], toolCap), at: at, snippet: snippet)
        }
        let why = text(o["why"], wordCap)
        return XraySearch(hits: hits, more: o["more"] as? Bool == true || rows.count > maxHits,
                          partial: o["partial"] as? Bool == true, why: why)
    }

    /// The faint lines under the hits (dch README: "the 50 newest are shown"; the early stop and why).
    var footer: [String] {
        var out: [String] = []
        if more { out.append("the \(Self.maxHits) newest are shown") }
        if partial {
            let reason = ["bytes": ": too much to read", "time": ": too long", "range": ": the history changed"][why ?? ""] ?? ""
            out.append("the search stopped early" + reason)
        }
        return out
    }
}

/// One hit as drawn and spoken: who said it (You, Reply, the tool's name), its age, the text around the match.
struct XraySearchRow: Equatable {
    let who: String
    let age: String?
    let snippet: String
    let spoken: String

    init(_ h: XraySearch.Hit, now: Date) {
        switch h.who {
        case "user": who = "You"
        case "assistant": who = "Reply"
        default: who = OutsideText.shown(h.tool ?? (h.who.isEmpty ? "Output" : h.who), max: 40)
        }
        let a = XrayTaskRow.age(h.at, now: now)
        age = a?.short
        snippet = OutsideText.shown(h.snippet, max: 240)
        let said = OutsideText.shown(XraySearch.withoutLeadingEllipsis(h.snippet), max: 240)
        spoken = [who, a?.spoken, said].compactMap { $0 }.joined(separator: ", ")
    }
}

extension XrayPanelModel {
    /// #1355: Return in the Search field. A query DchCtl.searchOK refuses runs nothing and says why; a good one cancels
    /// the read in flight (its dch is SIGTERMed, as on a session switch) and runs one search read through XrayPanels.run,
    /// the Tasks target (a local name or remote "host:name"). The poller never runs it (XrayPoller.tick).
    func runSearch() {
        guard DchCtl.searchOK(query) else { searchNote = XraySearch.badQuery; return }
        guard let dch, let run else { return }
        cancel()
        searchNote = nil
        let env = target.env, (text, input) = target.viaStdin(query, version: XrayPanels.probed?.version), a = target.searchArgs(text)
        reading = Task { [weak self] in
            let r = await XrayPanels.stdin.withValue(input) { await run(dch, a, env) }
            guard !Task.isCancelled, let self else { return }
            self.reading = nil
            self.takeSearch(r)
            self.landed()
        }
    }

    /// As take: exit 4 or 7 (or a remote -1) keeps the last hits and says "host unreachable"; exit 1 (the host's dch does
    /// not know --search, or no corpus) or 6 (refused) leaves no Search tab; any other answer replaces the hits, and a
    /// failed one (exit 2, 3, a local -1, bad JSON) says so. #1407: an over-cap answer (overCap) says it was too large.
    func takeSearch(_ r: (status: Int32, out: Data)) {
        if unreached(r.status) { unreachable = true; return }
        unreachable = false
        if r.status == 1 || r.status == 6 {
            (searchable, search) = (false, nil)
            searchGone = r.status == 1 ? XraySearch.cannotSearch : XraySearch.refused   // R1355-i1: said where the strip lands
            return
        }
        // #1407: this answer was too large; unlike exit 6 (the host never answers this form) another text may fit, so the tab stays
        if r.status == XrayPanels.overCap { (search, searchNote) = (nil, XraySearch.tooLarge); return }
        search = r.status == 0 ? XraySearch.parse(r.out) : nil
        if search == nil { searchNote = "The search failed" }
    }

    /// The Search tab's faint lines: dch's "more" and "partial", then "host unreachable".
    var searchFooter: [String] { (search?.footer ?? []) + memoryFooter }
}
