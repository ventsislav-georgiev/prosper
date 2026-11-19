import Foundation

/// #1416 (#1356 step 2, dch README "--ref"): `dch --xray <n> --ref <text> --scope project --full --json`'s NDJSON, one
/// object per line with schema 1: first, definition, mention, tally, progress, resolved, done. Every string is outside
/// data, cleaned here (OutsideText.shown). An unknown key, kind or word is kept as a word or skipped; parse never throws.
struct XrayRefStream: Equatable {
    struct First: Equatable {
        var session: String
        var key: String
        var shape: String
        var text: String
        /// #1565 (6.3): dch's own ms from its start to this line (`elapsed_ms`, xray.c:4983 at v1.99.0); nil: not sent.
        var elapsed: Int? = nil
    }

    struct Definition: Equatable {
        var session: String
        var at: Date?
        var title: String
        /// Cleaned, newlines kept, at most passageCap scalars.
        var passage: String
        var rule: String
        var chapter: String?          // an anchor: checked by DchCtl.anchorOK before any use, never shown
        /// source "command": dch's define_command gave it (README "define_command").
        var command: Bool
        var url: String?              // display form (cleaned, capped): shown, never opened
        var rawURL: String?           // as dch sent it (capped), for a later http/https-checked Open
        var status: String?
        var index: Int
        /// dch's card: "\u{00B7} your define_command" on a command definition.
        var mark: String? { command ? XrayRefContext.commandMark : nil }
    }

    struct Mention: Equatable {
        var session: String
        var chapter: String?          // null for another session's line (README "Scope")
        var at: Date?
        var line: String
        var offset: Int?
        var index: Int
        /// #1528 (dch 1.100.0, README "--ref"): the turn's pN (nil when dch does not know it), who said it ("user",
        /// "assistant", "tool"; nil before dch 1.97) and its tool, and the sentence split at the ref; all nil from an older dch.
        var turn: Int? = nil
        var who: String? = nil
        var tool: String? = nil
        var sentence: Sentence? = nil
        /// #1589 (dch 1.104.0, README v1.104.0:1694): the session's own id (stable across renames; nil: none or an older
        /// dch), and on a line of another session of this project its turn's title and that session's last activity.
        /// `recall`: such a line (dch sent turn_title or last_active, even null); never from an older dch or another project.
        var sessionID: String? = nil
        var turnTitle: String? = nil
        var lastActive: Date? = nil
        var recall = false
    }

    /// #1528: the sentence around the ref, each part cleaned on its own; `hit` "" when dch's span did not hold (the plain
    /// sentence is all in `before`).
    struct Sentence: Equatable {
        var before: String
        var hit: String
        var after: String
    }

    /// dch's sentence is at most 400 bytes (README "--ref"); a longer one is not dch's and is shown plain, cut.
    static let sentenceCap = 400

    /// #1528 (review-clean-then-parse): the RAW sentence sliced at the span's UTF-8 byte offsets first, then each part
    /// cleaned. A span that is not two ints with 0 <= start <= end <= the byte count, both on scalar boundaries, or a
    /// sentence over the cap, keeps the plain sentence with no highlight.
    static func sentence(_ outside: String, span: Any?) -> Sentence {
        var raw = outside
        raw.makeContiguousUTF8()   // a bridged string's indices: native UTF-8 ones, so samePosition is exact
        let u = raw.utf8
        let v = raw.unicodeScalars   // sliced as scalars: String's own subscript would round to a Character
        func show(_ s: String.UnicodeScalarView.SubSequence) -> String { OutsideText.shown(String(s), max: sentenceCap) }
        if u.count <= sentenceCap, let p = span as? [Any], p.count == 2, let a = p.first as? Int, let b = p.last as? Int,
           0 <= a, a <= b, b <= u.count,   // checked before offsetBy: a bad span never moves an index past the end
           let i = u.index(u.startIndex, offsetBy: a).samePosition(in: v),
           let j = u.index(u.startIndex, offsetBy: b).samePosition(in: v) {
            return Sentence(before: show(v[..<i]), hit: show(v[i..<j]), after: show(v[j...]))
        }
        return Sentence(before: show(v.prefix(sentenceCap * 4)), hit: "", after: "")
    }

    struct Tally: Equatable {
        var session: String
        var count: Int
        var mentionsDropped: Int
    }

    struct Resolved: Equatable {
        var kind: String
        var state: String
        var title: String
        var subtitle: String
        var lines: [String]
    }

    struct Counts: Equatable {
        var session: Int
        var project: Int
        var projectSessions: Int
        var all: Int?
        var allSessions: Int?
    }

    var first: First?
    var definitions: [Definition] = []
    var mentions: [Mention] = []
    var tallies: [Tally] = []
    var resolved: Resolved?
    /// done's counts, else the last progress line's (counts so far).
    var counts: Counts?
    /// A done line came (within the byte cap). None: cancelled (SIGTERM, a closed pipe, the cap), never complete.
    var done = false
    var donePartial = false
    var why: String?
    var defineWarn: String?

    /// No done line, or done said partial: every count is a lower bound and the definitions are "found so far".
    var partial: Bool { !done || donePartial }

    /// Caps: dch's 4 MiB output cap plus room; a passage 600 scalars, a mention line 200, resolved 14 lines x 200.
    static let maxBytes = 4 * 1024 * 1024 + 64 * 1024
    static let passageCap = 600
    static let lineCap = 200
    static let resolvedLines = 14
    static let wordCap = 32
    static let urlCap = 2048

    /// Bytes in; a line that is not a schema-1 object or names no known kind is skipped. Past maxBytes nothing more is
    /// read and the stream counts as cancelled (dch keeps room for done under its own 4 MiB, so more is not dch's).
    static func parse(_ data: Data) -> XrayRefStream {
        var s = XrayRefStream()
        func text(_ v: Any?, _ max: Int) -> String? {
            // raw prefix first so a huge string is not walked whole
            (v as? String).map { OutsideText.shown(String($0.unicodeScalars.prefix(max * 4)), max: max) }
        }
        func int(_ v: Any?) -> Int? { (v as? Int).map { min(max(0, $0), Int(Int32.max)) } }   // bounded: no overflow later
        func date(_ v: Any?) -> Date? { (v as? Double).flatMap { (0...1e10).contains($0) ? Date(timeIntervalSince1970: $0) : nil } }
        func counts(_ v: Any?) -> Counts? {
            guard let c = v as? [String: Any] else { return nil }
            return Counts(session: int(c["session"]) ?? 0, project: int(c["project"]) ?? 0,
                          projectSessions: int(c["project_sessions"]) ?? 0, all: int(c["all"]), allSessions: int(c["all_sessions"]))
        }
        for line in data.prefix(maxBytes).split(separator: 0x0a) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], o["schema"] as? Int == 1 else { continue }
            if let f = o["first"] as? [String: Any] {
                s.first = First(session: text(f["session"], 64) ?? "", key: text(f["key"], XrayRefs.maxRefBytes) ?? "",
                                shape: text(f["shape"], wordCap) ?? "", text: text(f["text"], XrayRefs.maxRefBytes) ?? "",
                                elapsed: int(f["elapsed_ms"]))
            } else if let d = o["definition"] as? [String: Any] {
                let passage = (d["passage"] as? String).map {
                    String(XrayMemory.cleanBody(String($0.unicodeScalars.prefix(passageCap * 4))).text.unicodeScalars.prefix(passageCap))
                } ?? ""
                s.definitions.append(Definition(session: text(d["session"], 64) ?? "", at: date(d["at"]),
                                                title: text(d["title"], XrayRefs.titleCap) ?? "", passage: passage,
                                                rule: text(d["rule"], wordCap) ?? "", chapter: (d["chapter"] as? String).map { String($0.prefix(128)) },
                                                command: d["source"] as? String == "command", url: text(d["url"], lineCap),
                                                rawURL: (d["url"] as? String).map { String($0.prefix(urlCap)) },
                                                status: text(d["status"], wordCap), index: s.definitions.count))
            } else if let m = o["mention"] as? [String: Any] {
                s.mentions.append(Mention(session: text(m["session"], 64) ?? "", chapter: (m["chapter"] as? String).map { String($0.prefix(128)) },
                                          at: date(m["at"]), line: text(m["line"], lineCap) ?? "", offset: int(m["offset"]),
                                          index: s.mentions.count,
                                          turn: (m["turn"] as? Int).flatMap { (1...Int(Int32.max)).contains($0) ? $0 : nil },
                                          who: text(m["who"], wordCap), tool: text(m["tool"], wordCap),
                                          sentence: (m["sentence"] as? String).map { sentence($0, span: m["span"]) },
                                          sessionID: text(m["session_id"], 64), turnTitle: text(m["turn_title"], XrayRefs.titleCap),
                                          lastActive: date(m["last_active"]), recall: m["turn_title"] != nil || m["last_active"] != nil))
            } else if let t = o["tally"] as? [String: Any] {
                s.tallies.append(Tally(session: text(t["session"], 64) ?? "", count: int(t["count"]) ?? 0,
                                       mentionsDropped: int(t["mentions_dropped"]) ?? 0))
            } else if let p = o["progress"] as? [String: Any] {
                if !s.done, let c = counts(p["counts"]) { s.counts = c }
            } else if let r = o["resolved"] as? [String: Any] {
                s.resolved = Resolved(kind: text(r["kind"], wordCap) ?? "", state: text(r["state"], wordCap) ?? "",
                                      title: text(r["title"], lineCap) ?? "", subtitle: text(r["subtitle"], lineCap) ?? "",
                                      lines: ((r["lines"] as? [Any]) ?? []).prefix(resolvedLines).compactMap { text($0, lineCap) })
            } else if o["done"] as? Bool == true {
                s.done = true
                s.donePartial = o["partial"] as? Bool == true
                s.why = text(o["why"], wordCap)
                s.defineWarn = text(o["define_warn"], lineCap)
                if let c = counts(o["counts"]) { s.counts = c }
            }
        }
        if data.count > maxBytes { s.done = false }   // a done past the cap was never read; one before it is not dch's last
        return s
    }
}

/// #1416: the ref card's data, computed purely from the stream, the asked text and the panel's cached Tasks and Memory.
struct XrayRefContext: Equatable {
    struct Group: Equatable {
        var session: String
        var mentions: [XrayRefStream.Mention]
    }

    /// #1528: one block of the Mentions tab: a turn of this session (pN), or nil: the "Earlier" block.
    /// #1589: or a turn of another session of this project (`session` its name, `title` dch's turn_title); `opens`: the
    /// first turn of that session's block, which carries its "also discussed in" header (`lastActive` its age).
    struct Turn: Equatable {
        var turn: Int?
        var mentions: [XrayRefStream.Mention]
        var session: String? = nil
        var title: String? = nil
        var lastActive: Date? = nil
        var opens = false
    }

    /// The text that was asked for (it passed DchCtl.refOK); Copy gives it.
    let ref: String
    /// The session asked about (first.session); its mentions alone may jump.
    let session: String?
    let shape: XrayRefs.Shape?
    let resolved: XrayRefStream.Resolved?
    /// Newest first (a define_command line has no time: after the dated ones, in dch's order).
    var definitions: [XrayRefStream.Definition]   // var: guarded(pinned:shell:) trims a copy
    let heading: String
    /// When there is no definition and no define_warn: the first mention ("First mention").
    var firstMention: XrayRefStream.Mention?
    /// This session in file order, then the other sessions, each newest first, the newest group first.
    var groups: [Group]
    /// #1528: dch 1.100.0's shape (a mention carries a sentence): this session's turns newest first, each in `groups`'
    /// order, then one Earlier block (no turn, or another session's). nil from an older dch: the flat `groups` stay.
    var turns: [Turn]?
    let counts: [String]
    /// #1560: "Other projects": the groups a `--scope all` read added (sessions this context has no group of) and its
    /// "All projects" count line; nil until that read lands.
    var others: [Group]?
    var othersCount: String?
    let tasks: [XrayTasks.Task]
    let memory: [XrayMemory.Item]
    /// #1567: the footer's facts: dch's counts as sent, a done line came, every count a lower bound (XrayRefStream), and
    /// the answer came from a light read (takeRef sets it; a full result serving a hover is not light).
    let rawCounts: XrayRefStream.Counts?
    let done: Bool
    let partial: Bool
    var light = false

    static let commandMark = "your define_command"
    static let othersCountPrefix = "All projects"
    static let noDefinition = "No definition found"

    init(_ s: XrayRefStream, ref: String, tasks: XrayTasks?, memory: XrayMemory?) {
        self.ref = ref
        session = s.first?.session
        shape = s.first.flatMap { XrayRefs.Shape(rawValue: $0.shape) }
        resolved = s.resolved
        let defs = s.definitions.sorted { a, b in
            switch (a.at, b.at) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.index < b.index
            }
        }
        definitions = defs
        let soFar = s.partial ? " found so far" : ""
        let titles = Set(defs.map(\.title)).count
        if !defs.isEmpty {
            heading = (titles >= 2 ? "\(titles) definitions" : "Definition") + soFar
            firstMention = nil
        } else if let w = s.defineWarn {
            heading = Self.noDefinition + ": " + w
            firstMention = nil
        } else if let m = s.mentions.min(by: { ($0.at ?? .distantFuture, $0.index) < ($1.at ?? .distantFuture, $1.index) }) {
            heading = "First mention" + soFar
            firstMention = m
        } else {
            heading = Self.noDefinition + (s.partial ? " so far" : "")   // R1416-s1: never "found found so far"
            firstMention = nil
        }
        let own = s.first?.session
        let mine = s.mentions.filter { $0.session == own }
            .sorted { ($0.offset ?? Int.max, $0.index) < ($1.offset ?? Int.max, $1.index) }
        func newest(_ a: XrayRefStream.Mention, _ b: XrayRefStream.Mention) -> Bool {
            (a.at ?? .distantPast, b.index) > (b.at ?? .distantPast, a.index)
        }
        let others = Dictionary(grouping: s.mentions.filter { $0.session != own }, by: \.session)
            .map { Group(session: $0.key, mentions: $0.value.sorted(by: newest)) }
            .sorted { a, b in newest(a.mentions[0], b.mentions[0]) }   // a grouping never makes an empty group
        groups = (mine.isEmpty ? [] : [Group(session: own ?? "", mentions: mine)]) + others
        if s.mentions.contains(where: { $0.sentence != nil }) {
            let flat = groups.flatMap(\.mentions)
            // a turn is this session's only (README: another session's line has none); grouping keeps `flat`'s order
            let keyed = Dictionary(grouping: flat.compactMap { m in m.session == own ? m.turn.map { ($0, m) } : nil }, by: \.0)
            // #1589: another session of this project (dch 1.104.0) gets its own block; an older dch's lines stay in Earlier
            func recall(_ m: XrayRefStream.Mention) -> Bool { m.session != own && m.recall }
            let earlier = flat.filter { ($0.turn == nil || $0.session != own) && !recall($0) }
            turns = keyed.keys.sorted(by: >).map { Turn(turn: $0, mentions: keyed[$0, default: []].map(\.1)) }
                + (earlier.isEmpty ? [] : [Turn(turn: nil, mentions: earlier)])
                + Self.recallBlocks(flat.filter(recall))
        } else {
            turns = nil
        }
        let ge = s.partial ? "\u{2265}" : ""
        counts = s.counts.map { c in
            ["This session \(ge)\(c.session)", "This project \(ge)\(c.project) in \(c.projectSessions) other sessions"]
                + (c.all.map { ["\(Self.othersCountPrefix) \(ge)\($0) in \(c.allSessions ?? 0) other sessions"] } ?? [])
        } ?? []
        (rawCounts, done, partial) = (s.counts, s.done, s.partial)
        let q = ref
        self.tasks = (tasks?.tasks ?? []).filter { t in
            [t.title, t.note ?? "", t.label].contains { $0.localizedCaseInsensitiveContains(q) }
        }
        self.memory = (memory?.items ?? []).filter { m in
            [m.title, m.note ?? "", m.body ?? ""].contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    /// #1589: the other same-project sessions' blocks, keyed by session_id (the name when dch sent none), newest
    /// last_active first (else the newest mention; ties in dch's order); in each, its turns newest first, then its
    /// mentions with no turn, each in `ms`' order.
    static func recallBlocks(_ ms: [XrayRefStream.Mention]) -> [Turn] {
        let bySession = Dictionary(grouping: ms) { $0.sessionID ?? $0.session }.values
        func last(_ b: [XrayRefStream.Mention]) -> (Date, Int) {
            (b.compactMap(\.lastActive).max() ?? b.compactMap(\.at).max() ?? .distantPast, -(b.map(\.index).min() ?? 0))
        }
        return bySession.sorted { last($0) > last($1) }.flatMap { b -> [Turn] in
            let name = b.first?.session ?? "", active = b.compactMap(\.lastActive).max()
            let keyed = Dictionary(grouping: b.filter { $0.turn != nil }) { $0.turn ?? 0 }
            let none = b.filter { $0.turn == nil }
            let ts = keyed.keys.sorted(by: >).map { n in
                Turn(turn: n, mentions: keyed[n, default: []], session: name,
                     title: keyed[n]?.lazy.compactMap(\.turnTitle).first, lastActive: active)
            } + (none.isEmpty ? [] : [Turn(turn: nil, mentions: none, session: name, lastActive: active)])
            return ts.enumerated().map { i, t in var t = t; t.opens = i == 0; return t }
        }
    }

    /// #1560: this context with `all`'s extra groups (a session it has no group of) and its All projects line.
    func with(others all: XrayRefContext) -> XrayRefContext {
        let seen = Set(groups.map(\.session) + [session].compactMap { $0 })
        var c = self
        c.others = all.groups.filter { !seen.contains($0.session) }
        c.othersCount = all.counts.last { $0.hasPrefix(Self.othersCountPrefix) }
        return c
    }

    /// #1565 (6.2 unpinned guard, S18, K4.2): what an unpinned hover card may show. Pinned: all of it. Unpinned: no
    /// other session's line or passage (pinned || sameSession) and no Other projects; a shell session's card titles and
    /// counts alone (the guard is `pinned` alone there): no mention line, no passage, no first mention.
    func guarded(pinned: Bool, shell: Bool) -> XrayRefContext {
        guard !pinned else { return self }
        var c = self
        (c.others, c.othersCount) = (nil, nil)
        let own = session
        c.definitions = definitions.map { d in
            var d = d
            if shell || d.session != own { d.passage = "" }
            return d
        }
        func mine(_ m: XrayRefStream.Mention) -> Bool { !shell && m.session == own }
        c.groups = groups.compactMap { g in
            let ms = g.mentions.filter(mine)
            return ms.isEmpty ? nil : Group(session: g.session, mentions: ms)
        }
        c.turns = turns.map { $0.compactMap { t in
            let ms = t.mentions.filter(mine)
            return ms.isEmpty ? nil : Turn(turn: t.turn, mentions: ms)
        } }
        c.firstMention = firstMention.flatMap { mine($0) ? $0 : nil }
        return c
    }

    /// #1565: a live shell session's id (dch README v1.99.0 "session_id": the ring's id, `m` + 16 hex).
    static func shell(_ sessionID: String?) -> Bool {
        guard let id = sessionID, id.count == 17, id.first == "m" else { return false }
        return id.dropFirst().allSatisfy { $0.isHexDigit }
    }

    /// #1560 (dch README v1.99.0 "--ref" :1775-1893, resolved states): one plain line for a state that is not `ok` (nil:
    /// draw the resolver's title and lines as before). A word Prosper does not know is shown as itself (cleaned by the parse).
    static func stateLine(_ r: XrayRefStream.Resolved) -> String? {
        switch r.state {
        case "ok": nil
        case "missing": "Missing"   // #1612: dch 1.110 file ref, no such file: its one plain line, as dch titles it
        case "ended": "Session ended: git not run"
        case "no_git": "No git found: not looked up"
        case "not_repo": "Not in a git repository"
        case "ambiguous": "Short SHA matches more than one object"
        case "not_commit": "Not a commit in this repository"
        case "timeout": "git took too long"
        case "outside_project": "Outside the project: not read"
        case "secret_name": "Looks like a secret: not read"
        case "too_large": "Over 2 MB: not read"
        default: r.state.isEmpty ? nil : r.state   // no state word (or one all unseen scalars): drawn as before
        }
    }

    /// Open: only a url ref, re-checked as http/https with a host.
    /// OQ-164 Q3 is not ruled: a file ref gets Copy only for now (no Open).
    var openURL: URL? { Self.openable(ref, shape: shape) }

    static func openable(_ text: String, shape: XrayRefs.Shape?) -> URL? {
        guard shape == .url, let u = URL(string: text), let s = u.scheme?.lowercased(), s == "http" || s == "https",
              u.host?.isEmpty == false else { return nil }
        return u
    }
}

extension XrayTarget {
    /// #1416: dch README "dch --xray <n> --ref <ref> --scope project --full --json"; the text is checked first (runRef).
    /// #1560: `scope` "all" for the card's Other projects row.
    func refArgs(_ text: String, scope: String = "project") -> [String] { ["--xray", name, "--ref", text, "--scope", scope, "--full", "--json"] }

    /// #1565 (6.2, dch README v1.99.0 :394, :1704-1742): the hover card's light read: no --full, a budget in 50...300.
    func lightArgs(_ text: String, budget: Int) -> [String] {
        ["--xray", name, "--ref", text, "--scope", "project", "--budget-ms", "\(min(max(budget, 50), 300))", "--json"]
    }
}

extension XrayTarget {
    /// #1623: dch 1.113.0 (#518) takes `--no-github` with --ref; DCH_NO_GITHUB=1 turns the lookup off for one local call (1.111.0+).
    static let noGithubMinimum = [1, 113, 0]

    /// #1623: a ref read's argv and env with the GitHub lookup setting applied; `lookups` on changes nothing. Off: a local
    /// read (dir set) gets the env var; a remote or --requests read gets `--no-github` before the closing --json, only when
    /// the local dch (it forwards the flag) is 1.113.0+, and `flagged` says a refusing host may need the plain argv again.
    func refCall(_ args: [String], version: [Int]?, lookups: Bool) -> (args: [String], env: [String: String], flagged: Bool) {
        var env = self.env
        guard !lookups else { return (args, env, false) }
        guard dir == nil else { env["DCH_NO_GITHUB"] = "1"; return (args, env, false) }
        guard let version, DchCommand.isAtLeast(version, Self.noGithubMinimum), args.last == "--json" else { return (args, env, false) }
        return (args.dropLast() + ["--no-github", "--json"], env, true)
    }
}

extension XrayPanels {
    /// #1416: one --ref read (`shown`: the text the card names, when it differs from what is sent). A text DchCtl.refOK refuses, or one starting with "-" (dch would read it as a flag), runs
    /// nothing and returns false. A new read cancels the one in flight (the product runner SIGTERMs its dch). #1410: a
    /// local text goes on stdin, where dch counts its newline in the 256 bytes: over 255 runs nothing (a remote keeps 256).
    /// shortcut: one --ref for the app, not per window; the card is a transient popover (a click or key in another
    /// window closes it first), so two never show at once. Key it by window if a later step keeps two cards open.
    /// #1567: the window's result cache (m.refResults, XrayRefResults) does not need it: a hit within 30 s lands at once
    /// with no spawn and no read in flight; an exit-0 answer goes into the cache of the window that asked.
    @discardableResult
    /// #1565: `budget` set: the hover card's light read (lightArgs), whose `first.elapsed_ms` goes to spawnCosts.
    func runRef(_ text: String, shown: String? = nil, scope: String = "project", budget: Int? = nil, for m: XrayPanelModel) -> Bool {
        let (arg, input) = m.target.viaStdin(text, version: XrayPanels.probed?.version)   // #1410: on stdin dch's 256 bytes count the newline
        guard DchCtl.refOK(text), !text.hasPrefix("-"), !Self.overStdin(input), let dch = m.dch,
              let run = m.run else { return false }
        // #1560: the card's own read, which its close names (an Other projects read stands in for it)
        let card = Self.othersRead.flatMap { $0.read == refReading ? $0.card : nil } ?? refReading
        closeRef()
        if scope == "project" { m.refContext = nil }   // Other projects adds to the card's context, never clears it
        m.refNote = nil
        let cache = m.refResults(), key = XrayRefResults.Key(target: m.target, ref: shown ?? text, light: budget != nil, scope: scope)
        if let hit = cache?.get(key) {   // #1567: no spawn; a light answer never reaches a full ask (get)
            Self.othersRead = nil
            m.takeRef((0, hit.out), text: shown ?? text, scope: scope, light: hit.light, cached: true)
            return true
        }
        let plain = budget.map { m.target.lightArgs(arg, budget: $0) } ?? m.target.refArgs(arg, scope: scope)
        let (a, env, flagged) = m.target.refCall(plain, version: XrayPanels.probed?.version, lookups: Preferences.xrayGithubLookups)   // #1623
        refReading = Task { [weak m, weak cache] in
            var r = await XrayPanels.stdin.withValue(input) { await run(dch, a, env) }
            // #1623: a host older than 1.113.0 refuses --no-github (exit 1; so does no corpus, so the retry is the evidence): once more without it
            if flagged, r.status == 1, !Task.isCancelled { r = await run(dch, plain, env) }
            guard !Task.isCancelled, let m else { return }   // cancelled: the SIGTERMed answer is not news
            if r.status == 0 { cache?.put(key, r.out) }   // #1567: only an answer the card shows as a context
            m.takeRef(r, text: shown ?? text, scope: scope, light: budget != nil)
        }
        Self.othersRead = scope == "project" ? nil : card.map { (card: $0, read: refReading) }
        return true
    }

    /// #1565 (6.3): dch's own start-up ms (`first.elapsed_ms`) of the last 8 light reads, oldest first.
    static var spawnCosts: [Int] = []
    static let costsKept = 8

    /// #1565: one light read's cost (nil: dch sent none, nothing kept). The parse bounded it to 0...Int32.max.
    static func spent(_ ms: Int?) {
        guard let ms else { return }
        spawnCosts = Array((spawnCosts + [ms]).suffix(costsKept))
    }

    /// #1565 (6.3): the light read's budget, B = max(50, 300 - p75 of spawnCosts) (nearest rank); 250 with none yet.
    static func budget() -> Int {
        let s = spawnCosts.sorted()
        guard !s.isEmpty else { return 250 }
        return max(50, 300 - s[(s.count * 3 + 3) / 4 - 1])
    }

    /// #1560: the Other projects read in flight and the card read it stands in for (one --ref read for the app).
    private static var othersRead: (card: Task<Void, Never>, read: Task<Void, Never>?)?

    /// #1419 (R1410-i1): dch's stdin cap, newline included.
    private static func overStdin(_ input: Data?) -> Bool { input.map { $0.count > 256 } ?? false }

    /// #1419 (R1410-i1): runRef refuses `text` for its length alone (a local ref over 255 bytes), so the card can say so.
    func refTooLong(_ text: String, for m: XrayPanelModel) -> Bool {
        DchCtl.refOK(text) && !text.hasPrefix("-") && Self.overStdin(m.target.viaStdin(text, version: XrayPanels.probed?.version).stdin)
    }

    /// The card closed (or a new ref asked): the read in flight is cancelled.
    func closeRef() {
        refReading?.cancel()
        refReading = nil
    }

    /// #1417: the card that started `read` went (presenter closed, Esc, Search): its read is cancelled, unless a newer
    /// card's read is the one in flight now (a replaced card's close may come after the new card's read started).
    func closeRef(started read: Task<Void, Never>?) {
        if let read, read == refReading || Self.othersRead.map({ $0.card == read && $0.read == refReading }) == true { closeRef() }
    }
}

extension XrayPanelModel {
    static let refNoCorpus = "No X-ray history for this session"
    static let refNotARef = "dch did not read this as a ref"
    static let refTooLong = "Too long to look up here"
    static let refFailed = "The ref read failed"
    /// #1568: a remote --xray's exit 6 (dch README v1.99.0:1267-1269: the host's hello lacks the `xray` token).
    static let refNoXray = "The host's dch has no X-ray: needs dch serve 1.55.0+"
    /// #1568 (K4.1): a remote hover card's note: it runs no read; Pin runs the full one.
    static let pinForPassages = "Pin for passages"

    /// Exit 0: the context; 1: no corpus; 2: not a ref; 4/7 (or a remote -1): host unreachable; #1568: a remote 6: the
    /// host's dch has no X-ray; else failed.
    /// #1560: a `scope` "all" read adds its extra groups to the card's context (XrayRefContext.with(others:)).
    /// #1565: a `light` read's `first.elapsed_ms` is kept (XrayPanels.spent). #1567: not a `cached` one (no spawn); the
    /// context says it is light (its footer's end slot).
    func takeRef(_ r: (status: Int32, out: Data), text: String, scope: String = "project", light: Bool = false, cached: Bool = false) {
        switch r.status {
        case 0:
            let s = XrayRefStream.parse(r.out)
            if light, !cached { XrayPanels.spent(s.first?.elapsed) }
            var c = XrayRefContext(s, ref: text, tasks: tasks, memory: memory)
            c.light = light
            refContext = scope == "project" ? c : refContext?.with(others: c)
        case 1: refNote = Self.refNoCorpus
        case 2: refNote = Self.refNotARef
        case 6 where target.dir == nil: refNote = Self.refNoXray
        case _ where unreached(r.status): refNote = "host unreachable"
        default: refNote = Self.refFailed
        }
    }

    /// #1560: the card's Other projects row opened: one `--scope all` read of the card's ref, once (none while the
    /// card's own read has not landed, or once the groups are in).
    @discardableResult
    func openOthers() -> Bool {
        guard let e = refCard, let c = refContext, c.others == nil, c.ref == e.text else { return false }
        // as openRef sends it (XrayPanel.swift): a term in backticks
        let sent = e.shape == .term ? (e.text.contains("`") ? "" : "`" + e.text + "`") : e.text
        return panels?.runRef(sent, shown: e.text, scope: "all", for: self) == true
    }

    /// Search: the ref text becomes the query and runs, only when DchCtl.searchOK takes it (else nothing changes); #1417:
    /// the card closes and the panel lands on the Search tab.
    func searchRef(_ text: String) {
        guard DchCtl.searchOK(text) else { return }
        dismiss()
        tab = .search
        query = text
        runSearch()
    }

    /// A mention's Return: this session's mention opens its chapter's card (#1471: no transcript to jump in); another
    /// session's never does, whatever its chapter says. An anchor dch's chapters read does not hold opens nothing.
    @discardableResult
    func jumpRef(_ m: XrayRefStream.Mention, in c: XrayRefContext) -> Bool {
        guard let anchor = m.chapter, c.session != nil, m.session == c.session else { return false }
        if let i = chapterAnchors[anchor], let ch = chapters.first(where: { $0.ordinal == i }) { openChapterCard(ch) }
        return true
    }

    /// #1528: a turn header's Return or click: that turn's chapter card (the jumpRef and Read the prompt path). The
    /// Earlier block, or a turn the chapters read does not hold, opens nothing (a turn block is this session's only).
    @discardableResult
    func jumpTurn(_ t: XrayRefContext.Turn, in c: XrayRefContext) -> Bool {
        // #1589: another session's turn is not in this session's chapters: it opens nothing
        guard t.session == nil, let n = t.turn, let ch = chapters.last(where: { $0.ordinal == n }) else { return false }
        openChapterCard(ch)
        return true
    }
}
