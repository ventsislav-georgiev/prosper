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
                                shape: text(f["shape"], wordCap) ?? "", text: text(f["text"], XrayRefs.maxRefBytes) ?? "")
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
                                          index: s.mentions.count))
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

    /// The text that was asked for (it passed DchCtl.refOK); Copy gives it.
    let ref: String
    /// The session asked about (first.session); its mentions alone may jump.
    let session: String?
    let shape: XrayRefs.Shape?
    let resolved: XrayRefStream.Resolved?
    /// Newest first (a define_command line has no time: after the dated ones, in dch's order).
    let definitions: [XrayRefStream.Definition]
    let heading: String
    /// When there is no definition and no define_warn: the first mention ("First mention").
    let firstMention: XrayRefStream.Mention?
    /// This session in file order, then the other sessions, each newest first, the newest group first.
    let groups: [Group]
    let counts: [String]
    let tasks: [XrayTasks.Task]
    let memory: [XrayMemory.Item]

    static let commandMark = "your define_command"
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
        let ge = s.partial ? "\u{2265}" : ""
        counts = s.counts.map { c in
            ["This session \(ge)\(c.session)", "This project \(ge)\(c.project) in \(c.projectSessions) other sessions"]
                + (c.all.map { ["All projects \(ge)\($0) in \(c.allSessions ?? 0) other sessions"] } ?? [])
        } ?? []
        let q = ref
        self.tasks = (tasks?.tasks ?? []).filter { t in
            [t.title, t.note ?? "", t.label].contains { $0.localizedCaseInsensitiveContains(q) }
        }
        self.memory = (memory?.items ?? []).filter { m in
            [m.title, m.note ?? "", m.body ?? ""].contains { $0.localizedCaseInsensitiveContains(q) }
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
    func refArgs(_ text: String) -> [String] { ["--xray", name, "--ref", text, "--scope", "project", "--full", "--json"] }
}

extension XrayPanels {
    /// #1416: one --ref read (`shown`: the text the card names, when it differs from what is sent). A text DchCtl.refOK refuses, or one starting with "-" (dch would read it as a flag), runs
    /// nothing and returns false. A new read cancels the one in flight (the product runner SIGTERMs its dch). #1410: a
    /// local text goes on stdin, where dch counts its newline in the 256 bytes: over 255 runs nothing (a remote keeps 256).
    /// shortcut: one --ref for the app, not per window; the card is a transient popover (a click or key in another
    /// window closes it first), so two never show at once. Key it by window if a later step keeps two cards open.
    @discardableResult
    func runRef(_ text: String, shown: String? = nil, for m: XrayPanelModel) -> Bool {
        let (arg, input) = m.target.viaStdin(text, version: XrayPanels.probed?.version)   // #1410: on stdin dch's 256 bytes count the newline
        guard DchCtl.refOK(text), !text.hasPrefix("-"), !Self.overStdin(input), let dch = m.dch,
              let run = m.run else { return false }
        closeRef()
        m.refContext = nil
        m.refNote = nil
        let a = m.target.refArgs(arg), env = m.target.env
        refReading = Task { [weak m] in
            let r = await XrayPanels.stdin.withValue(input) { await run(dch, a, env) }
            guard !Task.isCancelled, let m else { return }   // cancelled: the SIGTERMed answer is not news
            m.takeRef(r, text: shown ?? text)
        }
        return true
    }

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
        if let read, read == refReading { closeRef() }
    }
}

extension XrayPanelModel {
    static let refNoCorpus = "No X-ray history for this session"
    static let refNotARef = "dch did not read this as a ref"
    static let refTooLong = "Too long to look up here"
    static let refFailed = "The ref read failed"

    /// Exit 0: the context; 1: no corpus; 2: not a ref; 4/7 (or a remote -1): host unreachable; else failed.
    func takeRef(_ r: (status: Int32, out: Data), text: String) {
        switch r.status {
        case 0: refContext = XrayRefContext(XrayRefStream.parse(r.out), ref: text, tasks: tasks, memory: memory)
        case 1: refNote = Self.refNoCorpus
        case 2: refNote = Self.refNotARef
        case _ where unreached(r.status): refNote = "host unreachable"
        default: refNote = Self.refFailed
        }
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
}
