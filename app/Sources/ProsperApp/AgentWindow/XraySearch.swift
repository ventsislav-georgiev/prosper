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
        /// #1611 (dch 1.111.0): dch's `"answer": true` on one hit per group; false from an older dch.
        var answer = false
    }

    /// #1611 (dch #498, 1.110.0 `--scope project`): another session's group, as dch sent it (only one with a hit).
    /// `sessionID` keys "open that session"; the name is the fallback (an ended session's name can be reused, dch #493).
    struct Group: Equatable {
        var session: String
        var sessionID: String?
        var lastActive: Date?
        var hits: [Hit]
        var more: Bool
    }

    /// #1611 (dch 1.111.0): the top-level `first` and `latest` mentions; nil from an older dch or when dch sent null.
    struct Moment: Equatable {
        var session: String
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
    /// #1611: the other sessions' groups in dch's order (its project newest first, then other projects); [] unscoped.
    var others: [Group] = []
    var first: Moment? = nil
    var latest: Moment? = nil

    /// #1611: `--search --scope` (#498) and --search inside --requests (#501) need dch 1.110.0 (XrayTabs.minimumDch's pattern).
    static let scopeMinimum = [1, 110, 0]
    static func scoped(_ version: [Int]?) -> Bool { version.map { DchCommand.isAtLeast($0, scopeMinimum) } ?? false }
    /// #1611: dch's file cap (64 sessions) bounds the groups kept.
    static let maxGroups = 64

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
    /// #1611: a scoped answer (a `sessions` array, dch #498) takes its first group as this session's hits and the rest
    /// as `others`, in dch's order (Round 4: never re-sorted by time); a group that is not an object is skipped.
    static func parse(_ data: Data) -> XraySearch? {
        guard data.count <= XrayChapters.maxBytes, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["schema"] as? Int == 1 else { return nil }
        func text(_ v: Any?, _ max: Int) -> String? { (v as? String).map { String($0.unicodeScalars.prefix(max)) } }
        // bounded before Date: a far time from outside stays in range
        func date(_ v: Any?) -> Date? { (v as? Double).flatMap { (0...1e10).contains($0) ? Date(timeIntervalSince1970: $0) : nil } }
        func hits(_ list: [Any]) -> (hits: [Hit], over: Bool) {
            let rows = list.compactMap { $0 as? [String: Any] }
            return (rows.prefix(maxHits).compactMap { h -> Hit? in
                guard let snippet = text(h["snippet"], snippetCap) else { return nil }
                return Hit(who: text(h["who"], wordCap) ?? "", tool: text(h["tool"], toolCap), at: date(h["at"]), snippet: snippet,
                           answer: h["answer"] as? Bool == true)
            }, rows.count > maxHits)
        }
        func moment(_ v: Any?) -> Moment? {
            guard let m = v as? [String: Any], let snippet = text(m["snippet"], snippetCap) else { return nil }
            return Moment(session: text(m["session"], 64) ?? "", at: date(m["at"]), snippet: snippet)
        }
        let groups = (o["sessions"] as? [Any])?.compactMap { $0 as? [String: Any] }
        // a scoped answer's own group is its first (dch sends it also with no hit); unscoped: today's top-level hits
        guard let list = groups.map({ $0.first?["hits"] as? [Any] ?? [] }) ?? o["hits"] as? [Any] else { return nil }
        let own = hits(list), why = text(o["why"], wordCap)
        var s = XraySearch(hits: own.hits, more: (groups?.first ?? o)["more"] as? Bool == true || own.over,
                           partial: o["partial"] as? Bool == true, why: why)
        s.others = (groups ?? []).dropFirst().prefix(maxGroups).map { g in
            let h = hits(g["hits"] as? [Any] ?? [])
            return Group(session: text(g["session"], 64) ?? "", sessionID: text(g["session_id"], 64), lastActive: date(g["last_active"]),
                         hits: h.hits, more: g["more"] as? Bool == true || h.over)
        }.filter { !$0.hits.isEmpty }
        (s.first, s.latest) = (moment(o["first"]), moment(o["latest"]))
        return s
    }

    /// #1611: the "first mentioned" and "latest" lines (dch 1.111.0), each "<label> in <session>, <age>: <snippet>".
    func moments(now: Date) -> [String] {
        [("first mentioned", first), ("latest", latest)].compactMap { label, m in
            guard let m else { return nil }
            let age = XrayTaskRow.age(m.at, now: now)?.short
            let session = m.session.isEmpty ? "" : " in " + OutsideText.shown(m.session, max: 64)
            return label + session + (age.map { ", " + $0 } ?? "") + ": "
                + OutsideText.shown(Self.withoutLeadingEllipsis(m.snippet), max: 240)
        }
    }

    /// #1611: a group's header, the #1589 card's words ("also discussed in api-qa, 2h"; its last_active, else its newest hit).
    static func header(_ g: Group, now: Date) -> String {
        alsoDiscussed(g.session, at: g.lastActive ?? g.hits.compactMap(\.at).max(), now: now)
    }

    /// #1589's header words (XrayRefPopover.sessionHeader), shared with the Search groups: "also discussed in api-qa, 2h"
    /// (no age: the name alone). Here, not on the View, so it is not main-actor isolated.
    static func alsoDiscussed(_ name: String, at: Date?, now: Date) -> String {
        let age = XrayTaskRow.age(at, now: now)?.short
        return "also discussed in " + OutsideText.shown(name, max: 64) + (age.map { ", " + $0 } ?? "")
    }

    /// #1611: "open that session": a local sidebar row whose Claude session id (live) or agent id (History) is the
    /// group's session_id; with no id, the live row of that name (dch #493: an id never falls back to a name).
    static func row(_ g: Group, in rows: [AgentSidebar.Row]) -> AgentSidebar.RowID? {
        if let id = g.sessionID, !id.isEmpty {
            return rows.first { $0.session?.claudeSessionID == id || $0.record?.agent?.sessionID == id }?.id
        }
        return rows.first { $0.session?.key.name == g.session }?.id
    }

    /// The faint lines under the hits (dch README: "the 50 newest are shown"; the early stop and why).
    var footer: [String] {
        var out: [String] = []
        if more { out.append("the \(Self.maxHits) newest are shown") }
        if partial {
            let reason = ["bytes": ": too much to read", "time": ": too long", "range": ": the history changed",
                          "files": ": too many sessions"][why ?? ""] ?? ""   // #1611: dch #498's 64-file cap
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
    /// #1611: dch 1.111.0 marked this hit the answer (drawn as answerMark).
    let answer: Bool
    static let answerMark = "answer"

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
        answer = h.answer
        spoken = [who, a?.spoken, h.answer ? "the answer" : nil, said].compactMap { $0 }.joined(separator: ", ")
    }
}

extension XrayPanelModel {
    /// #1355: Return in the Search field. A query DchCtl.searchOK refuses runs nothing and says why; a good one cancels
    /// the read in flight (its dch is SIGTERMed, as on a session switch) and runs one search read through XrayPanels.run,
    /// the Tasks target (a local name or remote "host:name"). The poller never runs it (XrayPoller.tick).
    /// #1611: on dch 1.110.0+ (XraySearch.scoped) the read asks `--scope project`, so other sessions' hits come grouped.
    /// A remote host answers by its own release (dch README "host answers by its own release"): an older host's dch
    /// refuses `--scope` with exit 1, so a remote scoped read that exits 1 runs once more unscoped, and this panel stays
    /// unscoped after (`unscopedHost`). Exit 1 for another cause (no corpus, no --search) answers 1 again: as before.
    /// #1621: the one scope decision: the read and the field's accessibility label both use it.
    var searchScoped: Bool { XraySearch.scoped(XrayPanels.probed?.version) && !unscopedHost }
    var searchFieldLabel: String { searchScoped ? "Search this project" : "Search this session" }

    func runSearch() {
        guard DchCtl.searchOK(query) else { searchNote = XraySearch.badQuery; return }
        guard let dch, let run else { return }
        cancel()
        searchNote = nil
        let env = target.env, (text, input) = target.viaStdin(query, version: XrayPanels.probed?.version)
        let scoped = searchScoped
        let a = target.searchArgs(text, scope: scoped ? "project" : nil), plain = target.searchArgs(text), remote = target.dir == nil
        reading = Task { [weak self] in
            var r = await XrayPanels.stdin.withValue(input) { await run(dch, a, env) }
            if scoped, remote, r.status == 1, !Task.isCancelled {
                self?.unscopedHost = true
                r = await run(dch, plain, env)   // remote: the text is in argv, no stdin
            }
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
