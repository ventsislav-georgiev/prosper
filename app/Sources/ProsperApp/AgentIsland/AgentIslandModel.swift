// Agent Island (#474): every dch session and its agent state, shown in a notch
// overlay (AgentIslandController). This file is the part with no window: the
// session model and its display mapping, the no-fork poll gate, and the
// "which terminal owns this session" walk behind a row click. All of it is
// pure or takes its process/file lookups as parameters, so the tests drive it
// without a live dch.

import AppKit
import Darwin
import SwiftUI

/// dch's agent state, declared in urgency order: the collapsed island shows the
/// first one present, the list sorts by it.
enum AgentState: Int, Comparable, CaseIterable {
    case blocked, working, done, idle

    /// `--ls-json` state. Empty (dch before 1.4, the `-lj` fallback) or anything
    /// unknown reads as idle: there is no signal that an agent is doing anything.
    init(dch: String) {
        switch dch {
        case "blocked": self = .blocked
        case "working": self = .working
        case "done": self = .done
        default: self = .idle
        }
    }

    static func < (a: AgentState, b: AgentState) -> Bool { a.rawValue < b.rawValue }

    /// Static glyphs: the standing rule is no animation, so working never cycles.
    var glyph: String {
        switch self {
        case .blocked: "!"
        case .working: "✳"
        case .done, .idle: "●"
        }
    }

    var label: String {
        switch self {
        case .blocked: "Needs input"
        case .working: "Working"
        case .done: "Done"
        case .idle: "Idle"
        }
    }

    /// vibe-notch's terminal palette: Claude orange, amber, green, dim white.
    var color: Color {
        switch self {
        case .blocked: Color(red: 1.0, green: 0.7, blue: 0.0)
        case .working: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .done: Color(red: 0.4, green: 0.75, blue: 0.45)
        case .idle: Color.white.opacity(0.4)
        }
    }
}

/// One session is (socket dir, on-disk name): under "All sessions" the same name
/// can live in the default and the isolated dir at once.
struct AgentSessionKey: Hashable {
    let dir: String
    let name: String
}

/// #896: a local session's pty size and attached client count, as dch's `--ls-json` gives them.
struct AgentSessionPty: Equatable {
    let cols: Int
    let rows: Int
    let clients: Int
}

struct AgentSession: Equatable, Identifiable {
    let key: AgentSessionKey
    var alias: String
    /// Last pty output, seconds since 1970. Refreshed every tick from the stat'd
    /// `.sock.act` mtime, so the age ticks without a dch fork.
    var activity: TimeInterval
    let state: AgentState
    let agents: Int
    /// #506: dch 1.22's `meta` (open PRs, task counts); nil from older dch or none set.
    var meta: DchSessionMeta? = nil
    /// #578: its master's dch version, "" when too old to say (the control gate).
    var version: String = ""
    /// #765: dch's `meta_epoch`, kept so the phone's list served from here matches a fork's.
    var metaEpoch: Int = 0
    /// #792: dch's `auto_allowed`, the prompt its master answered last; nil when none.
    var autoAllowed: DchAutoAllowed? = nil
    /// #797: dch 1.30's `claude_session_id` and `transcript_path`, the Agents window's only
    /// session ↔ transcript mapping (design rule 6); nil from older dch or no confident match.
    var claudeSessionID: String? = nil
    var transcriptPath: String? = nil
    /// #1135: dch 1.63's `claude_foreground` for that Claude: false while it is suspended or in the background
    /// (a shell reads what is typed); nil when dch does not say (no Claude, an older client).
    var claudeForeground: Bool? = nil
    /// #935/#1133/#1135: Always allow's test of a row: fresh, naming one Claude Code, and not out of front (nil: today's rule).
    var claudeReading: Bool { fresh && claudeSessionID?.isEmpty == false && claudeForeground != false }
    /// #877: dch 1.52's `cwd`, carried for Remote Terminal's list (DchWatchHub.cache); "" when unknown.
    var cwd: String = ""
    /// #1133 (QA #849 INFO-3): false on a row kept from an earlier list because both list forms failed
    /// (#486); Always allow answers fresh rows only. Never sent to the phone.
    var fresh = true
    /// #1198: model id and effort word of the session's last answer, read from its transcript
    /// (AgentModelEffort); nil for Codex, shell and History rows and when the transcript holds none.
    var model: String? = nil
    var effort: String? = nil
    /// The transcript size `model`/`effort` were read at (the cache key with the path); nil = never read.
    var modelReadSize: UInt64? = nil
    /// #1267: consecutive list answers with no transcript mapping that kept the last model, effort and slot (display
    /// only: transcriptPath and claudeSessionID stay nil); 0 = not carried. At most `AgentModelEffort.carryAnswers`.
    var modelCarried = 0
    /// #1210: dch's harness title (DchListRow.harness), "" when none. Only the Sidekicks split matches it;
    /// `title` never reads it (an empty alias already holds it, as dch's label does).
    var harness: String = ""
    /// QA #606 INFO-1b: the state word dch printed ("" when it gave none), for Remote Terminal's cached list so
    /// an unknown state is absent from the row as a fork's is. nil: built here, the cache words `state`.
    var wireState: String? = nil
    /// #896: dch's `cols`/`rows`/`clients` (AgentTranscriptMapping.ptySizes); nil when dch leaves them out.
    var pty: AgentSessionPty? = nil
    /// #1558: dch 1.101's `shells` (DchListRow.shells), newest first; [] when dch leaves the key out or runs none.
    var shells: [DchShell] = []
    /// #1996: dch 1.182's `agent` (DchListRow.agent): "claude", "codex", "" (dch says neither), nil (dch did not say).
    /// "" and nil differ for runsCodex: "" is an answer (no record read), nil falls back to the record's argv.
    var agent: String? = nil

    var id: AgentSessionKey { key }
    var name: String { key.name }
    var title: String { alias.isEmpty ? key.name : alias }
}

/// "Show sessions" while Remote Terminal isolates its sessions.
enum AgentIslandSource: String, CaseIterable {
    case all, mac, remote

    /// Unset or unknown = all.
    init(raw: String?) { self = raw.flatMap(Self.init(rawValue:)) ?? .all }

    var label: String {
        switch self {
        case .all: "All sessions"
        case .mac: "Mac terminal sessions"
        case .remote: "Remote Terminal sessions"
        }
    }
}

/// #534: which of a row's details the island draws (Settings › Agent Island ›
/// Row details). Per Mac, never synced. #762: Agents, Open PRs and Merged, all on
/// by default (#1913: Merged is off by default) (Tasks done, In progress, Queued and Session name were removed).
/// The pure functions below take it as a parameter and never read defaults.
/// #1455: plus model, effort, state word, age and the Command 1-9 chip, all on by default; model and effort, when on, show
/// only where they differ from `defaultModel` / `defaultEffort` (Preferences' Default model and effort; "" shows them all).
struct AgentIslandRowDetails: Equatable {
    var agents = true
    var openPRs = true
    var merged = false
    var model = true
    var effort = true
    var state = true
    var age = true
    var shortcut = true
    /// #1558/#1583: the running shells' count (its help the commands) in Agent Sessions and on the island card.
    var shells = true
    var defaultModel = ""
    var defaultEffort = ""

    static let all = AgentIslandRowDetails(agents: true, openPRs: true, merged: true)

    /// #1455: a row's model label ("Opus 4.7") is the Default's when the Default, through the badge's own label function
    /// (AgentModelEffort.shortName), reads the same; a bare family alias ("opus") matches that family at any version.
    func isDefaultModel(_ label: String?) -> Bool {
        guard let label, !defaultModel.isEmpty else { return false }
        // A trailing "[...]" (context suffix, "opus[1m]") is not part of the model: strip one from both sides.
        let d = AgentModelEffort.shortName(Self.unbracketed(defaultModel)).lowercased(), l = AgentModelEffort.shortName(Self.unbracketed(label)).lowercased()
        return l == d || (!d.contains(" ") && l.hasPrefix(d + " "))
    }

    static func unbracketed(_ s: String) -> String {
        guard s.hasSuffix("]"), let i = s.lastIndex(of: "["), i > s.startIndex else { return s }
        return String(s[..<i])
    }

    /// #1455: the model and effort a row draws (nil: hidden), and whether each keeps its slot: an unknown value keeps it
    /// while its toggle is on (no size change when it arrives, #1203); a hidden one hands its width back to the title.
    func modelEffort(model: String?, effort: String?) -> (model: String?, effort: String?, modelSlot: Bool, effortSlot: Bool) {
        let m = self.model && !isDefaultModel(model) ? model : nil
        let e = self.effort && !(effort != nil && !defaultEffort.isEmpty && effort == defaultEffort) ? effort : nil
        // R1455a-s1: with a Default set an unknown value takes no slot (it would collapse when it arrives equal to it, #1203).
        return (m, e, self.model && (model == nil ? defaultModel.isEmpty : m != nil), self.effort && (effort == nil ? defaultEffort.isEmpty : e != nil))
    }

    /// #1455: Row.modelWords for the parts shown ("model Opus 4.7, effort high"); nil for none.
    func modelWords(model: String?, effort: String?) -> String? {
        let me = modelEffort(model: model, effort: effort)
        let w = [me.model.map { "model \($0)" }, me.effort.map { "effort \($0)" }].compactMap { $0 }
        return w.isEmpty ? nil : w.joined(separator: ", ")
    }
}

/// #571: Settings › Agent Island › Sort sessions. Per Mac, never synced.
enum AgentIslandSort: String, CaseIterable {
    case activity, name

    /// Unset or unknown = name (#1913; last activity before).
    init(raw: String?) { self = raw.flatMap(Self.init(rawValue:)) ?? .name }

    var label: String {
        switch self {
        case .activity: "Last activity"
        case .name: "Name"
        }
    }
}

enum AgentIsland {
    // MARK: - Display

    /// #768: the lists hold the same sessions and differ only in activity (and so
    /// maybe in the order it sorts by): nothing the collapsed island shows.
    static func onlyActivityMoved(_ a: [AgentSession], _ b: [AgentSession]) -> Bool {
        func flat(_ l: [AgentSession]) -> [AgentSessionKey: AgentSession] {
            Dictionary(l.map { var s = $0; s.activity = 0; return ($0.key, s) }, uniquingKeysWith: { x, _ in x })
        }
        return a.count == b.count && flat(a) == flat(b)
    }

    /// `.activity`: blocked, working, done, idle; newest activity first inside a
    /// group. `.name` (#571): flat by the row title (alias, else name),
    /// numeric-aware ("a2" before "a10"), ties on name then dir; no state groups,
    /// so rows keep their places. prosper-ios DchSession.ordered.
    static func sorted(_ sessions: [AgentSession], by order: AgentIslandSort = .activity) -> [AgentSession] {
        switch order {
        case .activity:
            sessions.sorted {
                if $0.state != $1.state { return $0.state < $1.state }
                if $0.activity != $1.activity { return $0.activity > $1.activity }
                return ($0.key.name, $0.key.dir) < ($1.key.name, $1.key.dir)
            }
        case .name:
            sessions.sorted {
                let c = $0.title.localizedStandardCompare($1.title)
                return c == .orderedSame ? ($0.key.name, $0.key.dir) < ($1.key.name, $1.key.dir) : c == .orderedAscending
            }
        }
    }

    // MARK: - Sidekicks (#571; prosper-ios DchSession.split is the substring-only original, #759 made this a regex)

    static let sidekickDefault = "-qa"

    /// #1757: the main list and each group's sessions, in the groups' order (an empty group kept).
    struct Split {
        var primary: [AgentSession]
        var groups: [(group: SessionGroup, sessions: [AgentSession])]
        /// The first group's sessions (rows and the single-pattern callers).
        var firstGroup: [AgentSession] { groups.first?.sessions ?? [] }
        /// #1759: the groups with sessions, in list order: one island tab and one sidebar section each.
        var shownGroups: [(group: SessionGroup, sessions: [AgentSession])] { groups.filter { !$0.sessions.isEmpty } }
    }

    /// #1757: a session goes into the first group whose pattern matches it (as `matching`), else the main list.
    /// Each group searches only what the groups before it left; a pattern is compiled once (sidekickCache).
    static func split(_ list: [AgentSession], groups: [SessionGroup]) -> Split {
        var rest = list, out: [(group: SessionGroup, sessions: [AgentSession])] = []
        for g in groups {
            let m = matching(rest, pattern: g.pattern)
            rest = m.rest
            out.append((g, m.hits))
        }
        return Split(primary: rest, groups: out)
    }

    /// The one Sidekicks group with `pattern` ("" = no group).
    static func split(_ list: [AgentSession], pattern: String) -> Split { split(list, groups: SessionGroup.sidekicks(pattern)) }

    /// A sidekick's name, alias or harness title matches `pattern` (trimmed), each one on its own as dch's
    /// picker does (pk_load, #1210), an ICU regex searched
    /// case-insensitively (#759). A pattern that is not a usable regex (see
    /// `SidekickMatch`) is matched as literal text, still ignoring case. An empty
    /// pattern matches nothing. Order is kept in both halves.
    private static func matching(_ list: [AgentSession], pattern: String) -> (rest: [AgentSession], hits: [AgentSession]) {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return (list, []) }
        let texts = list.map(sidekickTexts)
        var hits = sidekickFind(p, in: texts.flatMap { $0 }).hits[...]
        // #1109 R9: an editor session is never a sidekick, whatever its file's name.
        let tagged = zip(list, texts.map { t in defer { hits = hits.dropFirst(t.count) }; return hits.prefix(t.count).contains(true) })
            .map { ($0.0, $0.1 && !TerminalEditor.isEditSession($0.0.key.name)) }
        return (tagged.filter { !$0.1 }.map(\.0), tagged.filter(\.1).map(\.0))
    }

    /// What split searches for one session, in dch's order. R1210-a: `title` marks the harness title, whose
    /// search may run out of the call's deadline without flipping the pattern (sidekickFind).
    private static func sidekickTexts(_ s: AgentSession) -> [(text: String, title: Bool)] {
        [(s.name, false), (s.alias, false), (s.harness, true)]
    }

    /// How a non-empty pattern is matched. Every case but `.regex` matches it as text.
    enum SidekickMatch: Equatable {
        case regex, invalid, matchesEmpty, slow
        /// QA #594 INFO-5: the "" probe ran out of its deadline; no session name was searched.
        case slowProbe

        var caption: String? {
            switch self {
            case .regex: nil
            case .invalid: "Not a valid regex: matched as text"
            case .matchesEmpty: "Matches every session: matched as text"
            case .slow: "Too slow on a session name: matched as text"
            case .slowProbe: "Too slow as a regex: matched as text"
            }
        }
    }

    /// #1172: the caption's line when dch's config gets no pattern (DchConfigWriter.sidekickValue is "").
    static let sidekickDchNote = "dch's picker cannot use it: no Sidekicks tab there"

    /// Settings' caption under the pattern field: none while the tabs are off (the
    /// field is disabled) or the pattern is empty. Settings passes the live `sessions`, so a pattern too slow
    /// on their names or aliases says so before the island does.
    /// #1172: and a line under it when the pattern does not reach dch's own picker.
    /// #1220: `sessions` are searched as split searches them (sidekickTexts: a title is a title), `names` as names.
    static func sidekickCaption(_ pattern: String, tabs: Bool, names: [String] = [], sessions: [AgentSession] = []) -> String? {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tabs, !p.isEmpty else { return nil }
        let lines = [sidekickFind(p, in: names.map { (text: $0, title: false) } + sessions.flatMap(sidekickTexts)).how.caption, DchConfigWriter.sidekickValue(p).isEmpty ? sidekickDchNote : nil]
            .compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// How the trimmed, non-empty `p` is matched now (cached per pattern, as the split uses it).
    static func sidekickMatch(_ p: String) -> SidekickMatch { sidekickFind(p, in: []).how }

    /// QA #592 F1: split runs on main several times a second, and an ICU regex can
    /// backtrack for seconds. Bounds, in this thread's CPU time (a busy machine
    /// preempting main is not the pattern's fault): a split call stops its search
    /// at `sidekickDeadline`, as does the "" probe; a call slower than
    /// `sidekickSlowCall` per 16 texts searched, or on any one text, adds to the
    /// pattern's tally, which may reach `sidekickSlowTotal`. Either flips the
    /// pattern to text for the life of the process. #1090: a burst of CPU the kernel charges to the thread (page
    /// faults, decompression) is not the pattern's cost, so before a call counts or flips on its names, the search runs once
    /// more (the "" probe too; the titles' own tally only forgets) and a search that is not slow stands, else the names' smaller time
    /// (titles never decide it): a pathological text is slow again, a hiccup is not. And a tally forgets: `sidekickForget` calls in a
    /// row that do not count reset it while it is at or under `sidekickSlowTotal`; once over, it stays over until relaunch.
    /// Worst case: a call that never counts costs min(10 ms, 1 ms per 16 texts) forever (10 ms from 160 texts);
    /// a call that would count or flip costs up to twice that (one more deadline, 10 ms); a flip costs about
    /// 2 x 10 ms once per pattern (two deadlines), a pattern that is slow every call reaches the 50 ms tally in
    /// as many counted calls, and one that counts less often than once per `sidekickForget` calls never flips. Titles cost at
    /// most their tally (50 ms) plus a deadline once per pattern before they are text for the life of the process.
    /// Vars only so a test can make the tally deterministic; nothing else writes them.
    nonisolated(unsafe) static var sidekickDeadline: UInt64 = 10_000_000
    nonisolated(unsafe) static var sidekickSlowCall: UInt64 = 1_000_000
    nonisolated(unsafe) static var sidekickSlowTotal: UInt64 = 50_000_000
    /// #1090: this many consecutive calls that do not count reset a pattern's tally (a call count, not a wall clock,
    /// so a test can drive it with the counted seam).
    static let sidekickForget = 32
    /// This thread's CPU time in ns. A var only so a test can count clock reads instead of
    /// timing a runner (#1063); nothing else writes it.
    nonisolated(unsafe) static var sidekickCPU: @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    /// Compiled once per trimmed pattern. Guarded by `sidekickLock`; the unsafe
    /// marker only silences Swift 6's global-state check.
    /// ponytail: grows by one entry per distinct pattern, typed in Settings or adopted from
    /// the paired phone (#760, one sync in flight per connection); a few hundred tiny entries at most per run.
    private static let sidekickLock = NSLock()
    /// #1220: `titleSpent` is the titles' own tally (R1210-a); past sidekickSlowTotal the titles are matched as text.
    nonisolated(unsafe) private static var sidekickCache: [String: (re: NSRegularExpression?, how: SidekickMatch, spent: UInt64, titleSpent: UInt64, quiet: Int, titleQuiet: Int)] = [:]

    /// Which of `texts` the trimmed, non-empty `p` finds, and how it was matched.
    /// R1210-a: names and aliases first, accounted as before titles were searched; then the titles, shortest
    /// first, in what is left of the same deadline. A title past it is no hit, as is every title after it in
    /// that call; it never flips the pattern, and no title's time counts toward the pattern's tally. Titles keep their
    /// own tally under the same bars; once it passes sidekickSlowTotal the pattern's titles are matched as text
    /// (names and aliases stay a regex), so a slow title costs the deadline per call only until then.
    private static func sidekickFind(_ p: String, in texts: [(text: String, title: Bool)]) -> (how: SidekickMatch, hits: [Bool]) {
        let cpu = sidekickCPU
        var entry = sidekickLock.withLock { sidekickCache[p] }
        var (re, how) = (entry?.re, entry?.how ?? .invalid)
        if entry == nil {
            // Off the lock: two first callers may both probe, and the first to store wins.
            re = sidekickRegex(p)
            if let re {
                // An empty match makes every session a sidekick (QA #592 INFO-2). The probe
                // gets the same CPU deadline as a search: `(x?|y?){32}\b` backtracks for
                // 0.35-1.3 s on "" alone before ICU's own limit stops it (QA #592 INFO-7, #594).
                // #1090: a probe that runs out of its deadline is repeated once, a hiccup is not slow twice.
                var tries = 0
                repeat {
                    tries += 1
                    how = .regex
                    let start = cpu()
                    re.enumerateMatches(in: "", options: .reportProgress, range: NSRange()) { r, _, stop in
                        if r != nil { how = .matchesEmpty; stop.pointee = true }
                        else if cpu() - start > sidekickDeadline { how = .slowProbe; stop.pointee = true }
                    }
                } while how == .slowProbe && tries < 2
            }
            (re, how) = sidekickLock.withLock {
                if sidekickCache[p] == nil { sidekickCache[p] = (re, how, 0, 0, 0, 0) }
                entry = sidekickCache[p]
                return (sidekickCache[p]!.re, sidekickCache[p]!.how)
            }
        }
        let titlesAsText = (entry?.titleSpent ?? 0) > sidekickSlowTotal
        var hits = [Bool](repeating: false, count: texts.count)
        if let re, how == .regex {
            let names = texts.indices.filter { !texts[$0].title }
            let titles = texts.indices.filter { texts[$0].title && !texts[$0].text.isEmpty }.sorted { texts[$0].text.utf8.count < texts[$1].text.utf8.count }
            typealias Pass = (hits: [Bool], slow: Bool, worst: UInt64, spent: UInt64, titleWorst: UInt64, titleSpent: UInt64, late: Bool)
            // One whole search of this call's texts, on this thread; `slow` when a name ran past the call's deadline.
            func pass() -> Pass {
                var hits = [Bool](repeating: false, count: texts.count)
                let start = cpu()
                var worst: UInt64 = 0
                // One search, inside the pass; nil when it ran past the call's deadline.
                func find(_ t: String) -> Bool? {
                    var hit: Bool? = false
                    // .reportProgress: ICU calls back inside a backtracking search, so the
                    // deadline ends one catastrophic search, not only the gaps between hits.
                    // A zero-width match (\b, ^, a lookahead) is no hit, or it would take every name.
                    re.enumerateMatches(in: t, options: .reportProgress, range: NSRange(t.startIndex..., in: t)) { r, _, stop in
                        if let r, r.range.length > 0 { hit = true; stop.pointee = true }
                        else if cpu() - start > sidekickDeadline { hit = nil; stop.pointee = true }
                    }
                    return hit
                }
                var slow = false
                for i in names where !slow {
                    let t0 = cpu()
                    if let hit = find(texts[i].text) { hits[i] = hit } else { slow = true }
                    worst = max(worst, cpu() - t0)
                }
                let spent = cpu() - start   // names and aliases only
                var (titleWorst, titleSpent, late): (UInt64, UInt64, Bool) = (0, 0, false)
                if titlesAsText {
                    for i in titles { hits[i] = texts[i].text.range(of: p, options: .caseInsensitive) != nil }
                } else if !slow, !titles.isEmpty {
                    let t1 = cpu()
                    for i in titles {
                        let t0 = cpu()
                        guard let hit = find(texts[i].text) else { late = true; break }   // the deadline is spent: no hit, no flip
                        hits[i] = hit
                        titleWorst = max(titleWorst, cpu() - t0)
                    }
                    titleSpent = cpu() - t1
                }
                return (hits, slow, worst, spent, titleWorst, titleSpent, late)
            }
            // Per 16 texts, so a cheap pattern over 100 sessions never counts (QA #592 INFO-8);
            // one name over the whole budget still counts, however many cheap names dilute it.
            func namesCount(_ r: Pass) -> Bool { r.worst > sidekickSlowCall || r.spent / UInt64(max(1, names.count / 16)) > sidekickSlowCall }
            // The titles' tally, same bars; it only ever ends their regex search, never the pattern's.
            func titlesCount(_ r: Pass) -> Bool { r.late || r.titleWorst > sidekickSlowCall || r.titleSpent / UInt64(max(1, titles.count / 16)) > sidekickSlowCall }
            var r = pass()
            // #1090: before a call counts or flips, search the names once more and keep the smaller time (cost: one more call's worth, at most a deadline).
            // shortcut: titles are not searched twice (their tally only turns titles to text, and DchConfigWriterTests' #1220 rows pin their reads per call); they only forget.
            if r.slow || namesCount(r) {
                let r2 = pass()
                // R1090-2: a pass that is not slow wins, then the names' smaller time; titles (own tally) never decide it.
                if (r.slow && !r2.slow) || (r.slow == r2.slow && r2.spent < r.spent) { r = r2 }
            }
            hits = r.hits
            if r.slow { how = .slow }
            how = sidekickLock.withLock {
                guard var e = sidekickCache[p], e.how == .regex else { return sidekickCache[p]?.how ?? how }
                if namesCount(r) { e.spent += r.spent; e.quiet = 0 } else { e.quiet += 1 }
                if titlesCount(r) { e.titleSpent += r.titleSpent; e.titleQuiet = 0 } else { e.titleQuiet += 1 }
                // R1090-1: a tally forgets only while at or under the bar; once over, it stays over until relaunch.
                if e.quiet >= sidekickForget, e.spent <= sidekickSlowTotal { (e.spent, e.quiet) = (0, 0) }
                if e.titleQuiet >= sidekickForget, e.titleSpent <= sidekickSlowTotal { (e.titleSpent, e.titleQuiet) = (0, 0) }
                if how == .slow || e.spent > sidekickSlowTotal { e.how = .slow }
                sidekickCache[p] = e
                return e.how
            }
        }
        if how != .regex { hits = texts.map { $0.text.range(of: p, options: .caseInsensitive) != nil } }
        return (how, hits)
    }

    /// The trimmed pattern as a case-insensitive regex; nil when empty or not a
    /// valid regex (Settings then says it is matched as text).
    static func sidekickRegex(_ pattern: String) -> NSRegularExpression? {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        // #1210: dch never calls setlocale (C locale): parity with dch's regcomp holds for ASCII; ICU folds and "." go by Unicode.
        // #1184: LF only ends a line, as POSIX: an alias or harness title can end in U+2028 etc. (dch cuts only LF/CR/blanks), and ICU's "$" would match before it.
        return p.isEmpty ? nil : try? NSRegularExpression(pattern: p, options: [.caseInsensitive, .useUnixLineSeparators])
    }

    // MARK: - What the pattern means as a regex (#938, QA INFO-3 on #759)

    /// What Settings tells about the saved pattern. `regex` carries the first syntax character, found left to right.
    enum SidekickHint: Equatable {
        case plain, invalid, exact, tooLong
        case regex(first: Unicode.Scalar)

        /// The plain words for the row's hint slot; nil where the row says nothing (plain and exact are calm; `invalid` is
        /// already told by `SidekickMatch.invalid.caption` under the field; `tooLong` is told by sidekickDchNote).
        var text: String? {
            guard case .regex(let c) = self, let says = AgentIsland.sidekickSyntax.first(where: { $0.char == c })?.says else { return nil }
            return "Read as a regex: \(c) \(says)"
        }
    }

    /// The characters ICU (NSRegularExpression, no x flag) reads as syntax outside a bracket set, and what each does. A "-"
    /// is none of them. The escape below prefixes exactly these, so one table pins both.
    static let sidekickSyntax: [(char: Unicode.Scalar, says: String)] = [
        ("\\", "starts a special code"), ("^", "means start of the text"), ("$", "means end of the text"),
        (".", "matches any character"), ("|", "means either side"), ("?", "may skip the one before"),
        ("*", "repeats the one before"), ("+", "repeats the one before"), ("(", "groups part of it"), (")", "groups part of it"),
        ("[", "picks one of a set"), ("]", "picks one of a set"), ("{", "sets a repeat count"), ("}", "sets a repeat count"),
    ]

    /// Same bound as the dch config line (DchConfigWriter.maxPatternBytes): longer is outside data, never scanned or escaped.
    static func sidekickHint(_ pattern: String) -> SidekickHint {
        guard pattern.utf8.count <= DchConfigWriter.maxPatternBytes else { return .tooLong }
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = p.unicodeScalars.first(where: { c in sidekickSyntax.contains { $0.char == c } }) else { return .plain }
        guard sidekickRegex(p) != nil else { return .invalid }
        // Already the escaped form of some text: dropping each backslash that guards a syntax character and escaping again gives it back.
        var plain = String.UnicodeScalarView(), chars = p.unicodeScalars.makeIterator(), next = chars.next()
        while let c = next {
            next = chars.next()
            if c == "\\", let n = next, sidekickSyntax.contains(where: { $0.char == n }) { plain.append(n); next = chars.next() } else { plain.append(c) }
        }
        return String(plain) != p && sidekickEscaped(String(plain)) == p ? .exact : .regex(first: first)
    }

    /// `text` as a pattern that matches that text and nothing else: a backslash before each syntax character.
    static func sidekickEscaped(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for c in text.unicodeScalars {
            if sidekickSyntax.contains(where: { $0.char == c }) { out.append("\\") }
            out.append(c)
        }
        return String(out)
    }

    /// #938 F938-1: the button works only on a pattern read as a regex whose ESCAPED form (what dch would get) still fits the
    /// config line's bound in UTF-8 bytes; past it dch writes the line empty. Pure: counts bytes, no index into the pattern.
    static func sidekickCanMatchExactly(_ pattern: String) -> Bool {
        guard case .regex = sidekickHint(pattern) else { return false }
        return sidekickEscaped(pattern.trimmingCharacters(in: .whitespacesAndNewlines)).utf8.count <= DchConfigWriter.maxPatternBytes
    }

    /// The "Match this text exactly" button: the escaped pattern when it is read as a regex and the escape fits, else unchanged.
    static func sidekickMatchExactly(_ pattern: String) -> String {
        guard sidekickCanMatchExactly(pattern) else { return pattern }
        return sidekickEscaped(pattern.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// #1759: the group tab shown: never without a group with sessions; the chosen one (by id) while it has sessions;
    /// else, when the groups are all there is, the first with sessions; else none (Sessions).
    static func shownGroup(_ split: Split, tab: String?) -> (group: SessionGroup, sessions: [AgentSession])? {
        let live = split.shownGroups
        if let tab, let g = live.first(where: { $0.group.id == tab }) { return g }
        return split.primary.isEmpty ? live.first : nil
    }

    /// now, 4m, 2h, 3d, 1y — whole units, rounded down; #1114: no seconds, "now" under a minute.
    /// #829 (QA #660 note 4): years past 364 days, capped at 99, so no age is wider than
    /// `ageWidest` and the window's fixed age slot always fits it.
    static func age(_ seconds: TimeInterval) -> String {
        // Also NaN and a clock that moved back (a far-future stamp): Int( below only sees 60...1e15.
        guard seconds >= 60 else { return "now" }
        let s = Int(min(seconds, 1e15))
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        if s < 365 * 86400 { return "\(s / 86400)d" }
        return "\(min(s / (365 * 86400), 99))y"
    }

    /// The widest age `age` can return ("364d"), as a template of the same characters.
    static let ageWidest = "000d"

    /// #1114: nothing on a working row (its state already says so, and its age is always "now").
    static func age(of s: AgentSession, now: TimeInterval) -> String {
        s.activity > 0 && s.state != .working ? age(now - s.activity) : ""
    }

    /// What VoiceOver and the "· 4m ago" texts read for an `age`: "just now" for "now"; nil for none.
    static func ago(_ age: String) -> String? {
        age.isEmpty ? nil : age == "now" ? "just now" : "\(age) ago"
    }

    struct Summary: Equatable {
        var counts: [AgentState: Int] = [:]
        var total = 0
        var mostUrgent: AgentState? { AgentState.allCases.first { (counts[$0] ?? 0) > 0 } }
        var working: Int { counts[.working] ?? 0 }
        var blocked: Int { counts[.blocked] ?? 0 }
        /// The right ear: blocked count in amber when anything is blocked, else
        /// the working count.
        var earCount: (value: Int, state: AgentState) {
            blocked > 0 ? (blocked, .blocked) : (working, .working)
        }
    }

    static func summary(_ sessions: [AgentSession]) -> Summary {
        var s = Summary()
        for x in sessions { s.counts[x.state, default: 0] += 1 }
        s.total = sessions.count
        return s
    }

    /// "Agent Island, 3 working, 1 needs input" — non-zero states only.
    /// QA #447 I3: with no session, the History count the island shows for
    /// ("Agent Island, no sessions, 3 in History").
    static func islandAccessibilityLabel(_ s: Summary, history: Int = 0) -> String {
        let order: [AgentState] = [.working, .blocked, .done, .idle]
        let parts = order.compactMap { st -> String? in
            guard let n = s.counts[st], n > 0 else { return nil }
            return "\(n) \(st.label.lowercased())"
        }
        let none = ["no sessions"] + (history > 0 ? ["\(history) in History"] : [])
        return (["Agent Island"] + (parts.isEmpty ? none : parts)).joined(separator: ", ")
    }

    /// #592: a History row's VoiceOver text. #605: "pinned" after the title on a pinned record.
    static func historyAccessibilityLabel(_ r: DchHistoryRecord, line2: String, age: String, cwd: String) -> String {
        ([r.title, r.pinned ? "pinned" : nil, line2, ago(age), cwd] as [String?])
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// #594 (QA #464 T6): the History row's label; a Resume status replaces line 2.
    static func historyRowAccessibilityLabel(_ r: DchHistoryRecord, status: String?, end: String, age: String, cwd: String) -> String {
        historyAccessibilityLabel(r, line2: status ?? end, age: age, cwd: cwd)
    }

    /// #596 (QA #465 INFO-1): what the row draws, in drawn order.
    static func rowAccessibilityLabel(_ s: AgentSession, now: TimeInterval, show d: AgentIslandRowDetails = .all) -> String {
        let age = age(of: s, now: now)
        let (chips, more) = prChips(s.meta, show: d, budget: .infinity)
        let prs = chips.map(\.fullName).joined(separator: ", ") + (more > 0 ? " and \(more) more pending PR\(more == 1 ? "" : "s")" : "")
        // #1137: the counts in the Agent Sessions window's words ("3 agents", "192 merged pull requests").
        let agents: String? = agentsCount(s, show: d).map { AgentSidebar.Count.agents.words($0) }
        let merged: String? = mergedCount(s.meta, show: d).map { AgentSidebar.Count.merged.words($0) }
        let shells: String? = d.shells && !s.shells.isEmpty ? AgentSidebar.Count.shells.words(s.shells.count) : nil   // #1583
        return [s.title, s.state.label, d.age ? ago(age) : nil, agents, shells, merged,
                chips.isEmpty ? nil : "open pull requests " + prs]
            .compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: - Session meta (#506)

    /// Every count the row draws: "99999+" above 99999, so a runaway number
    /// cannot squeeze the title.
    static func count(_ n: Int) -> String { n > 99_999 ? "99999+" : "\(n)" }

    /// #1137: the live subagents the title line draws (symbol plus number, AgentIslandCount); nil for none, a negative
    /// from dch's unclamped `agents`, or Agents off.
    static func agentsCount(_ s: AgentSession, show d: AgentIslandRowDetails = .all) -> Int? {
        d.agents && s.agents > 0 ? s.agents : nil
    }

    /// #1137: the merged PRs drawn right-aligned on the PR line (symbol plus number); nil for none or Merged off.
    static func mergedCount(_ m: DchSessionMeta?, show d: AgentIslandRowDetails = .all) -> Int? {
        guard d.merged, let n = m?.merged, n > 0 else { return nil }
        return n
    }

    /// #1137: the gap between a count's symbol and its number (AgentIslandCount).
    static let countGap: CGFloat = 2

    /// #1137: a count's symbol slot: the symbol's width at the chip font's size and weight, rounded up. AgentIslandCount
    /// lays the symbol out in exactly this width, so the budget and the drawn line agree. Main only (view bodies, the
    /// window's rows).
    static func symbolWidth(_ c: AgentSidebar.Count) -> CGFloat {
        let size = CTFontGetSize(AgentIslandGeometry.chipFont)
        // chipFont is monospacedSystemFont(ofSize: 10, weight: .medium); a missing symbol draws nothing, the size covers it.
        return (NSImage(systemSymbolName: c.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium))?.size.width ?? size).rounded(.up)
    }

    /// #1137: a count as AgentIslandCount draws it: the symbol slot, the gap and the capped number (rounded up, as
    /// SwiftUI rounds a text's width).
    static func countWidth(_ c: AgentSidebar.Count, _ n: Int) -> CGFloat {
        symbolWidth(c) + countGap + AgentIslandGeometry.width(count(n), AgentIslandGeometry.chipFont).rounded(.up)
    }

    /// #525: a row draws a third line, the PR line, only for open PRs with a
    /// label or a merged count; `prChips` and the row height agree through this.
    /// #534: only the ones toggled on count, so a row with neither is 48 pt again.
    static func hasPRLine(_ m: DchSessionMeta?, show d: AgentIslandRowDetails) -> Bool {
        (d.openPRs && (m?.openPRs.contains { $0.label != nil } ?? false)) || mergedCount(m, show: d) != nil
    }

    /// One open PR as the row draws it. `url` is set only when it passed the
    /// allowlist (`DchSessionMeta.PR.pullURL`); without one the chip is a label.
    /// `label` is "repo#num" (no owner), `fullName` "owner/repo#num" for the
    /// tooltip and the accessibility label.
    struct PRChip: Equatable {
        let label: String
        let title: String
        let url: URL?
        var fullName: String = ""

        /// "owner/repo#num — title", or the parts that are there.
        var help: String { [fullName.isEmpty ? label : fullName, title].filter { !$0.isEmpty }.joined(separator: " — ") }
    }

    static let maxPRChips = 3
    /// The repo is cut to this many characters (with "…") only when the chips do
    /// not fit uncut. Set so one cut chip with a 10-digit number fits the PR line
    /// next to the worst "+NN pending PRs" and a 99999+ merged count (tested).
    static let maxRepoChars = 18
    static let maxTitleChars = 200
    /// The PR line's width: the row's text column.
    static let prChipBudget: CGFloat = AgentIslandGeometry.rowTextWidth
    /// The least gap between the chips and the right-aligned merged count.
    static let mergedGap: CGFloat = 8
    static let chipInset: CGFloat = 5
    static let chipSpacing: CGFloat = 4

    /// Rounded up to whole points: SwiftUI rounds each text's width up, and the
    /// line holds up to five of them.
    static func chipWidth(_ s: String) -> CGFloat {
        AgentIslandGeometry.width(s, AgentIslandGeometry.chipFont).rounded(.up) + 2 * chipInset
    }

    /// The overflow chip: "+2 pending PRs", "+1 pending PR"; never read as "+N agents".
    static func moreLabel(_ n: Int) -> String { "+\(n) pending PR\(n == 1 ? "" : "s")" }

    /// The first PRs whose chips, plus a "+M pending PRs" chip for the rest,
    /// measure within `budget` less the merged count and its gap (at most
    /// `maxPRChips`); `more` is M. More chips win over uncut repos: each count
    /// is tried with full labels, then with repos cut to `maxRepoChars`. PRs with
    /// no label are skipped. #534: none with Open PRs off; Merged off leaves the
    /// chips the whole budget.
    static func prChips(_ m: DchSessionMeta?, show d: AgentIslandRowDetails = .all,
                        budget: CGFloat = prChipBudget) -> (chips: [PRChip], more: Int) {
        guard d.openPRs else { return ([], 0) }
        let budget = budget - (mergedCount(m, show: d).map { countWidth(.merged, $0) + mergedGap } ?? 0)
        let all = (m?.openPRs ?? []).compactMap { pr -> (full: PRChip, cut: PRChip)? in
            guard let label = pr.label, let hash = label.lastIndex(of: "#") else { return nil }
            let repo = label[..<hash], num = label[hash...]
            let owner = pr.pullURL.map { String($0.path.split(separator: "/")[0]) }
                ?? pr.repo.split(separator: "/").dropLast().joined(separator: "/")
            let fullName = owner.isEmpty ? label : "\(owner)/\(label)"
            let title = String(pr.title.prefix(maxTitleChars))
            let short = repo.count > maxRepoChars ? String(repo.prefix(maxRepoChars - 1)) + "…" : String(repo)
            return (PRChip(label: label, title: title, url: pr.pullURL, fullName: fullName),
                    PRChip(label: short + num, title: title, url: pr.pullURL, fullName: fullName))
        }
        var k = min(all.count, maxPRChips)
        while k > 0 {
            let more = all.count - k
            for chips in [all.prefix(k).map(\.full), all.prefix(k).map(\.cut)] {
                let w = chips.reduce(0) { $0 + chipWidth($1.label) } + CGFloat(k - 1) * chipSpacing
                    + (more > 0 ? chipSpacing + chipWidth(moreLabel(more)) : 0)
                if w <= budget { return (chips, more) }
            }
            k -= 1
        }
        return ([], all.count)
    }

    /// A PR click's only way out of the app; tests replace it and never open a real URL.
    /// Under XCTest the default opens nothing even unstubbed (as GhosttyEventSender).
    @MainActor static var openURL: @MainActor (URL) -> Void = { url in
        guard NSClassFromString("XCTestCase") == nil else { return }
        _ = workspaceOpen(url)
    }
    /// What the default reaches; replaced only by the guard's test.
    @MainActor static var workspaceOpen: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }

    /// Opens an allowlisted chip; a label chip opens nothing.
    @MainActor static func open(_ chip: PRChip) {
        guard let url = chip.url else { return }
        openURL(url)
    }

    // MARK: - Socket dirs and listing

    /// The dirs to list. One dir while Remote Terminal shares its sessions; with
    /// isolation on, the user's "Show sessions" pick.
    static func socketDirs(source: AgentIslandSource, isolate: Bool,
                           defaultDir: String, isolatedDir: String) -> [String] {
        guard isolate, defaultDir != isolatedDir else { return [defaultDir] }
        switch source {
        case .all: return [defaultDir, isolatedDir]
        case .mac: return [defaultDir]
        case .remote: return [isolatedDir]
        }
    }

    static func liveSocketDirs() -> [String] {
        socketDirs(source: AgentIslandSource(raw: Preferences.agentIslandSessions),
                   isolate: Preferences.isolateRemoteSessions,
                   defaultDir: DchCommand.defaultSocketDir, isolatedDir: DchCommand.isolatedSocketDir)
    }

    /// dch's env for one dir: DCH_SOCKET_DIR always set explicitly, because the
    /// Remote Terminal env pins the isolated dir whenever isolation is on.
    static func listEnv(dir: String, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env.removeValue(forKey: "DCH_SESSION")   // inside a dch session dch refuses to nest
        env["DCH_SOCKET_DIR"] = dir
        return env
    }

    /// stdout of one dch call; nil when it timed out.
    typealias Runner = (_ args: [String], _ env: [String: String]) -> Data?

    /// Every session of `dirs`, one dch fork per dir; `--ls-json`, else `-lj` (old dch).
    /// #486: a dir whose `-lj` timed out keeps its rows from `previous`, so a wedged
    /// dch does not read as "no sessions" and collapse the island.
    static func list(dirs: [String], keeping previous: [AgentSession] = [],
                     run: Runner = { DchCommand.runIsland(args: $0, env: $1) },
                     modelIO: AgentModelEffort.IO = .live) -> [AgentSession] {
        // #1198: runs on the caller's queue (the poller's), like the dch fork; `previous` is the cache.
        let before = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        return dirs.flatMap { dir -> [AgentSession] in
            let env = listEnv(dir: dir)
            let json = run(["--ls-json"], env) ?? Data()
            var rows = DchCommand.parseListJSON(json)
            let mapping = AgentTranscriptMapping.parse(json)   // #797: the same bytes, no second fork
            let foreground = AgentTranscriptMapping.foregrounds(json)   // #1291: also for a row with no transcript
            let ptys = AgentTranscriptMapping.ptySizes(json)   // #896: the Fit here chip
            if rows.isEmpty {
                guard let tsv = run(["-lj"], env) else {
                    return previous.filter { $0.key.dir == dir }.map { var s = $0; s.fresh = false; return s }
                }
                rows = DchCommand.parseListTSV(String(decoding: tsv, as: UTF8.self))
            }
            return rows.map { row -> AgentSession in
                // #1109 R9: a Text Viewer editor session shows an untrusted file's bytes: never Needs input (idle on the
                // island and to the phone) and never a Claude Code (#935's auto-allow test reads claudeSessionID).
                let edit = TerminalEditor.isEditSession(row.name)
                let s = AgentSession(key: AgentSessionKey(dir: dir, name: row.name), alias: row.alias,
                             activity: TimeInterval(row.activityEpoch), state: edit ? .idle : AgentState(dch: row.state),
                             agents: row.agents, meta: row.meta, version: row.version, metaEpoch: row.metaEpoch,
                             autoAllowed: row.autoAllowed,
                             claudeSessionID: edit ? nil : mapping[row.name]?.sessionID,
                             transcriptPath: edit ? nil : mapping[row.name]?.path,
                             claudeForeground: foreground[row.name], cwd: row.cwd, harness: row.harness,
                             wireState: edit ? "idle" : row.state, pty: ptys[row.name],
                             shells: edit ? [] : row.shells ?? [], agent: row.agent)
                return AgentModelEffort.carry(AgentModelEffort.resolve(s, previous: before[s.key], io: modelIO),
                                              previous: before[s.key])
            }
        }
    }

    // MARK: - Copy fallback

    static func shellQuoted(_ word: String) -> String { CodexHarness.shellQuoted(word) }

    /// What a terminal pastes to attach. `dch -n` attaches a live session even
    /// while another client holds it (checked against dch 1.20, #474 J9), so no
    /// `-f`. A session outside the default dir needs its dir, or the paste would
    /// spawn a new session of that name in the default one.
    static func attachCommand(_ key: AgentSessionKey, defaultDir: String) -> String {
        let cmd = "dch -n \(shellQuoted(key.name))"
        return key.dir == defaultDir ? cmd : "DCH_SOCKET_DIR=\(shellQuoted(key.dir)) \(cmd)"
    }

    /// #500: what a launched terminal runs — attachCommand as argv, with two
    /// differences. dch is the path Prosper resolves (a fresh terminal's PATH may
    /// not have it), and the dir is always explicit: the terminal's env (launchd's,
    /// or a login shell's rc) is not Prosper's, so an implicit default dir could
    /// make `dch -n` create a new session instead of attaching.
    /// #529 (QA #333 L-2): env reads any word with "=" as an assignment and
    /// documents no "--" (env(1) suggests interposing a utility), so a dch path
    /// with "=" goes through `sh -c 'exec "$0" "$@"'`, which keeps dch's argv[0]
    /// its path. No "--" after exec: /bin/dash (a valid /bin/sh) rejects it.
    static func attachArgv(_ key: AgentSessionKey, dch: String) -> [String] {
        ["/usr/bin/env", "DCH_SOCKET_DIR=\(key.dir)"] + (dch.contains("=") ? ["/bin/sh", "-c", #"exec "$0" "$@""#] : [])
            + [dch, "-n", key.name]
    }

    /// #505: Ghostty's `new window with configuration {command}` (Ghostty.sdef),
    /// built from four-char codes so no AppleScript source is compiled or escaped.
    /// Ghostty hands the command to one shell (`bash -c "exec -l <command>"`), so
    /// it is attachArgv shell-quoted, no `direct:`/`shell:` prefix. The env lead
    /// takes exec -l's "-" on its argv[0]; dch keeps a clean one (it re-execs
    /// itself from argv[0]).
    static func ghosttyNewWindow(_ key: AgentSessionKey, dch: String) -> NSAppleEventDescriptor {
        ghosttyEvent("NWin", configKeyword: "GNwS", key, dch: dch)
    }

    /// #527: Ghostty's `new tab with configuration {command}`, no `in`. Ghostty
    /// (handleNewTabScriptCommand) then tabs onto its main, else last-main window,
    /// and with no window at all makes a new window instead, so one event covers
    /// both. `in front window` would name scriptWindows.first and fail with none.
    static func ghosttyNewTab(_ key: AgentSessionKey, dch: String) -> NSAppleEventDescriptor {
        ghosttyEvent("NTab", configKeyword: "GNtS", key, dch: dch)
    }

    private static func ghosttyEvent(_ id: String, configKeyword: String, _ key: AgentSessionKey,
                                     dch: String) -> NSAppleEventDescriptor {
        func code(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }
        let cfg = NSAppleEventDescriptor.record()
        cfg.setDescriptor(NSAppleEventDescriptor(string: attachArgv(key, dch: dch).map(shellQuoted).joined(separator: " ")),
                          forKeyword: code("GScC"))
        let event = NSAppleEventDescriptor(
            eventClass: code("Ghst"), eventID: code(id),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: AgentTerminal.ghostty.bundleID),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(cfg, forKeyword: code(configKeyword))
        return event
    }
}

// MARK: - Click setting (#500)

/// What a row click does. #1736: `sessions` (the default) opens the Agent Sessions window on the session; `open` and
/// `copy` apply to a session with no local terminal window (one with a window is focused, as before).
enum AgentIslandClick: String, CaseIterable {
    case sessions, open, copy

    /// Unset or unknown = sessions.
    init(raw: String?) { self = raw.flatMap(Self.init(rawValue:)) ?? .sessions }

    var label: String {
        switch self {
        case .sessions: "Open in Agent Sessions"
        case .open: "Open in terminal"
        case .copy: "Copy attach command"
        }
    }
}

/// A terminal Prosper can start with a command. Every path is a Launch Services
/// open (no AppleScript, so no Automation prompt); the research is in #500's notes.
/// Ghostty tries its Apple Event first (#505, AgentIslandController.open) and
/// keeps the script as the fallback.
enum AgentTerminal: String, CaseIterable {
    case ghostty, terminal, iterm, wezterm, kitty, alacritty

    var bundleID: String {
        switch self {
        case .ghostty: "com.mitchellh.ghostty"
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .wezterm: "com.github.wez.wezterm"
        case .kitty: "net.kovidgoyal.kitty"
        case .alacritty: "org.alacritty"
        }
    }

    var label: String {
        switch self {
        case .ghostty: "Ghostty"
        case .terminal: "Terminal"
        case .iterm: "iTerm2"
        case .wezterm: "WezTerm"
        case .kitty: "kitty"
        case .alacritty: "Alacritty"
        }
    }

    enum Launch: Equatable {
        /// A new instance of the app with these arguments (`open -na <app> --args …`).
        case arguments([String])
        /// A `.command` script the running app opens as a document (`open -a <app> x.command`).
        case script(String)
    }

    /// Terminal, iTerm2 and Ghostty open a self-deleting script of shell-quoted
    /// words in a new window of the running app. Ghostty's documented `-e` needs a
    /// new instance per click (its own Dock icon); it stays the fallback if the
    /// script path ever breaks. The rest get the argv unsplit and unquoted.
    func launch(_ argv: [String]) -> Launch {
        switch self {
        case .alacritty: .arguments(["-e"] + argv)
        case .wezterm: .arguments(["start", "--"] + argv)
        case .kitty: .arguments(argv)
        case .terminal, .iterm, .ghostty:
            .script("#!/bin/sh\n/bin/rm -f \"$0\"\nexec \(argv.map(AgentIsland.shellQuoted).joined(separator: " "))\n")
        }
    }

    /// Read only: Launch Services knows the bundle id.
    static func isInstalled(_ t: AgentTerminal) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: t.bundleID) != nil
    }

    /// The picker: Terminal always, the others when installed.
    static func available(installed: (AgentTerminal) -> Bool) -> [AgentTerminal] {
        allCases.filter { $0 == .terminal || installed($0) }
    }

    /// The stored pick while it is still installed, else Ghostty when installed, else Terminal.
    static func resolve(raw: String?, installed: (AgentTerminal) -> Bool) -> AgentTerminal {
        if let t = raw.flatMap(Self.init(rawValue:)), available(installed: installed).contains(t) { return t }
        return installed(.ghostty) ? .ghostty : .terminal
    }
}

// MARK: - Poll gate

/// Mtimes of one session's sidecars: output (.act), a hook's reported state
/// (.state, where "done" always wins), the alias (.alias, the title) and
/// `dch --meta`'s PRs (.meta, #506).
struct AgentSidecarStamp: Equatable {
    var act: TimeInterval?
    var state: TimeInterval?
    var alias: TimeInterval?
    var meta: TimeInterval?
    /// #768 (QA #607 INFO-2): the master's version stamp; `dch --restart` rewrites only this.
    var ver: TimeInterval?
}

typealias AgentDirSnapshot = [AgentSessionKey: AgentSidecarStamp]

/// stat-only view of the socket dirs. readdir runs only when a dir's own mtime
/// moved (create/unlink: a session, a client, a new sidecar); a sidecar's
/// futimens leaves the dir alone, so the sidecars of known sessions are stat'd
/// every tick — about 4 stats per session per second, no fork.
final class AgentDirScanner {
    private var cache: [String: (mtime: TimeInterval, names: [String])] = [:]
    /// The readdir; tests count it.
    private let readDir: (String) -> [String]

    init(readDir: @escaping (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }) {
        self.readDir = readDir
    }

    func scan(_ dirs: [String]) -> AgentDirSnapshot {
        var snap: AgentDirSnapshot = [:]
        for dir in dirs {
            for name in names(dir) ?? [] {
                let base = "\(dir)/\(name).sock"
                snap[AgentSessionKey(dir: dir, name: name)] = AgentSidecarStamp(
                    act: Self.mtime(base + ".act"), state: Self.mtime(base + ".state"),
                    alias: Self.mtime(base + ".alias"), meta: Self.mtime(base + ".meta"),
                    ver: Self.mtime(base + ".ver"))
            }
        }
        cache = cache.filter { dirs.contains($0.key) }
        return snap
    }

    /// #1185: each dir's session names (its .sock files) and nothing else: one stat of the dir, a readdir only
    /// when its mtime moved; no sidecar is stat'd. A dir that does not exist is absent.
    func socks(_ dirs: [String]) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for dir in dirs { out[dir] = names(dir).map(Set.init) }
        cache = cache.filter { dirs.contains($0.key) }
        return out
    }

    /// The dir's .sock names through the cache: one stat, a readdir only when the dir's mtime moved; nil: no dir.
    private func names(_ dir: String) -> [String]? {
        // A dir that does not exist yet (isolation never used) is no sessions.
        guard let m = Self.mtime(dir) else { cache[dir] = nil; return nil }
        if cache[dir]?.mtime != m {
            let names = readDir(dir)
            cache[dir] = (m, names.filter { $0.hasSuffix(".sock") }.map { String($0.dropLast(5)) })
        }
        return cache[dir]?.names ?? []
    }

    static func mtime(_ path: String) -> TimeInterval? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9
    }
}

/// When to fork `dch --ls-json`. Clock is wall time, the same clock as the mtimes.
/// #768: output alone (.act) is not a change: ages come from the stat. A session
/// that was not working at the last fetch and prints again forks (it turns
/// working); a working one is re-read once its output has been quiet `trailing` s
/// (a prompt that just rendered) and at dch's idle flip. Everything else (.state,
/// .alias, .meta, a session coming or going) forks as before.
struct AgentPollGate {
    static let floor: TimeInterval = 2       // never more often
    static let backstop: TimeInterval = 30   // never less often while sessions exist
    static let hiddenBackstop: TimeInterval = 60   // display asleep or screen locked
    static let trailing: TimeInterval = 2    // re-read after a change: a blocker can be mid-render
    /// QA #607 F1: a working session that keeps printing (a spinner, subagents under a
    /// prompt) is never quiet, and dch finds a prompt on the screen with no sidecar
    /// change, so it is re-listed at least this often while it prints, hidden or not.
    /// 6 s = dch's 5 s working window + 1: a needs-you under a busy pane shows within
    /// about 6 s, at 10 forks/min per dir instead of 30 before #768.
    static let printingCap: TimeInterval = 6
    /// dch says "working" while now - act <= 5 s (whole seconds), so a session
    /// that stops printing turns idle at floor(act) + 6 without touching a file.
    static let idleAfter: TimeInterval = 6

    private(set) var lastFetch: TimeInterval?
    private var seen: AgentDirSnapshot?
    private var states: [AgentSessionKey: AgentState] = [:]
    private var trailingAt: TimeInterval?

    /// The snapshot with each .act reduced to whether it exists.
    private static func shape(_ snap: AgentDirSnapshot) -> AgentDirSnapshot {
        snap.mapValues { var s = $0; s.act = s.act.map { _ in 0 }; return s }
    }

    func shouldFetch(_ snap: AgentDirSnapshot, now: TimeInterval, hidden: Bool = false) -> Bool {
        guard let last = lastFetch, let seen else { return true }
        guard now - last >= Self.floor else { return false }
        if now - last >= (hidden ? Self.hiddenBackstop : Self.backstop) { return true }
        if trailingAt.map({ now >= $0 }) == true || Self.shape(snap) != Self.shape(seen) { return true }
        for (key, stamp) in snap {
            guard let act = stamp.act else { continue }
            if act != seen[key]?.act {
                switch states[key] {
                case .done: continue                              // done always wins: output changes nothing
                case .working:   // quiet again, or printing on past the cap
                    if now >= act + Self.trailing || now - last >= Self.printingCap { return true }
                default: return true                              // idle or blocked printing: it turns working
                }
            }
            // The idle flip; one already past at the last fetch is working for another reason.
            if states[key] == .working {
                let flip = act.rounded(.down) + Self.idleAfter
                if flip > last, now >= flip { return true }
            }
        }
        return false
    }

    mutating func didFetch(_ snap: AgentDirSnapshot, sessions: [AgentSession], now: TimeInterval) {
        let changed = seen.map { Self.shape(snap) != Self.shape($0) } ?? true
        trailingAt = changed ? now + Self.trailing : nil
        states = Dictionary(sessions.map { ($0.key, $0.state) }, uniquingKeysWith: { a, _ in a })
        seen = snap
        lastFetch = now
    }
}

/// One tick = one stat scan and, when the gate says so, one listing. Runs on
/// the controller's poll queue only (hence unchecked Sendable).
final class AgentIslandPoller: @unchecked Sendable {
    private let now: () -> TimeInterval
    private let dirs: () -> [String]
    /// The dirs to list and the last fetched sessions (kept for a dir whose list timed out).
    private let list: ([String], [AgentSession]) -> [AgentSession]
    private let scanner = AgentDirScanner()
    private var gate = AgentPollGate()
    private var fetched: [AgentSession] = []
    private var published: [AgentSession]?
    /// #768: display asleep or screen locked (the controller's ScreenGate): the longer backstop.
    var hidden = false
    /// QA #606 INFO-6: the dirs the last tick read; poll queue only.
    private(set) var listedDirs: [String] = []

    init(now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         dirs: @escaping () -> [String] = AgentIsland.liveSocketDirs,
         list: @escaping ([String], [AgentSession]) -> [AgentSession] = { AgentIsland.list(dirs: $0, keeping: $1) }) {
        self.now = now
        self.dirs = dirs
        self.list = list
    }

    /// The sorted sessions when they differ from the last tick's, else nil.
    func tick() -> [AgentSession]? {
        let dirs = dirs()
        listedDirs = dirs
        let snap = scanner.scan(dirs)
        let t = now()
        if snap.isEmpty {
            // Nothing to list: no fork, and the next session to appear fetches at once.
            fetched = []
            gate = AgentPollGate()
        } else if gate.shouldFetch(snap, now: t, hidden: hidden) {
            let live = Set(snap.keys.map(\.dir))
            fetched = list(dirs.filter(live.contains), fetched)
            gate.didFetch(snap, sessions: fetched, now: t)
        }
        // A session whose socket is gone drops at once; ages come from the stat.
        let current = AgentIsland.sorted(fetched.compactMap { s in
            guard let stamp = snap[s.key] else { return nil }
            var s = s
            if let act = stamp.act { s.activity = act.rounded(.down) }
            return s
        })
        guard current != published else { return nil }
        published = current
        return current
    }
}

// MARK: - Jump

/// What the process table says about one pid (sysctl + libproc, never ps).
struct AgentProcInfo: Equatable {
    let ppid: pid_t
    let hasTTY: Bool
    let path: String
    let argv: [String]
}

enum AgentJumpTarget: Equatable {
    /// The regular app whose process tree holds the newest local client.
    case app(pid_t)
    /// A live client whose chain ends at launchd with no app (tmux, ssh).
    case attachedElsewhere
    /// No local client: nothing to jump to.
    case notAttached
}

extension AgentIsland {
    /// `<on-disk name>.sock.client.<digits>`: exact prefix plus an all-digit pid,
    /// so a session "a" never claims "a.b"'s files and dotted names parse whole.
    static func clientPID(fileName: String, name: String) -> pid_t? {
        let prefix = "\(name).sock.client."
        guard fileName.hasPrefix(prefix) else { return nil }
        let digits = fileName.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let pid = pid_t(digits), pid > 0 else { return nil }
        return pid
    }

    /// The session's client pids, newest client file first (its mtime is the attach).
    static func clientPIDs(_ key: AgentSessionKey) -> [pid_t] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: key.dir)) ?? []
        return names.compactMap { f -> (pid_t, TimeInterval)? in
            guard let pid = clientPID(fileName: f, name: key.name) else { return nil }
            return (pid, AgentDirScanner.mtime("\(key.dir)/\(f)") ?? 0)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// dch's own liveness rule plus two of ours. Dead (no info) and orphaned
    /// (ppid 1, no tty) are dch's. A pid that is not dch any more is a reused pid
    /// from a stale file. Prosper's own Remote Terminal clients (our children, or
    /// `-E` in argv once orphaned) are the phone's, not a terminal's.
    static func isLocalClient(_ p: AgentProcInfo?, ourPID: pid_t) -> Bool {
        guard let p, (p.path as NSString).lastPathComponent == "dch" else { return false }
        if p.ppid == 1 && !p.hasTTY { return false }
        return p.ppid != ourPID && !p.argv.dropFirst().contains("-E")
    }

    static func jumpTarget(clients: [pid_t], info: (pid_t) -> AgentProcInfo?,
                           isRegularApp: (pid_t) -> Bool, ourPID: pid_t) -> AgentJumpTarget {
        let local = clients.filter { isLocalClient(info($0), ourPID: ourPID) }
        guard !local.isEmpty else { return .notAttached }
        for pid in local {
            if let app = MixerRoutingSupport.owningRegularAppPid(
                responsiblePid: pid,
                isRegularApp: { $0 != ourPID && isRegularApp($0) },
                parentPid: { info($0)?.ppid ?? 0 }) {
                return .app(app)
            }
        }
        return .attachedElsewhere
    }

    /// nil for a dead or zombie pid.
    static func procInfo(_ pid: pid_t) -> AgentProcInfo? {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return nil }
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0,
              Int32(kp.kp_proc.p_stat) != SZOMB else { return nil }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        let path = n > 0 ? String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        return AgentProcInfo(ppid: kp.kp_eproc.e_ppid, hasTTY: kp.kp_eproc.e_tdev != -1,
                             path: path, argv: argv(pid))
    }

    /// KERN_PROCARGS2: argc, the exec path, NUL padding, then argv.
    static func argv(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        return parseProcArgs(Array(buf.prefix(size)))
    }

    static func parseProcArgs(_ buf: [UInt8]) -> [String] {
        guard buf.count > 4 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        while i < buf.count, buf[i] != 0 { i += 1 }   // exec path
        while i < buf.count, buf[i] == 0 { i += 1 }   // padding
        var out: [String] = []
        while out.count < argc, i < buf.count {
            let start = i
            while i < buf.count, buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }
}

/// #1537 (OQ-95 part 3): the Claude plan's session (5 h) and weekly limits for the open island, from the account
/// pool's in-memory usage sample of its current account (the pool runtime's planUsage) and that account's reset stamps.
/// Pure. Stale is dropped, per limit: a value whose window rolled over (its reset passed) or, with no reset known,
/// one older than its window belongs to a finished window and is wrong, not just old. nil: nothing to draw.
struct AgentPlanUsage: Equatable, Sendable {
    /// Anthropic's utilization, a fraction (0.42 = 42%); nil: not known or stale.
    var session: Double?
    var week: Double?
    /// Epochs the windows roll over; nil: not reported.
    var sessionReset: Int?
    var weekReset: Int?

    static let sessionWindow: Double = 5 * 3600
    static let weekWindow: Double = 7 * 86400

    /// `util` and `at` are the sample (claim -> fraction, its epoch); `reset` claim -> epoch.
    init?(util: [String: Double], at: Double, reset: [String: Int], now: Double) {
        let s = Self.fresh("five_hour", util: util, at: at, reset: reset, now: now)
        let w = Self.fresh("seven_day", util: util, at: at, reset: reset, now: now)
        guard s != nil || w != nil else { return nil }
        session = s?.value; sessionReset = s?.reset
        week = w?.value; weekReset = w?.reset
    }

    /// #1898: the 5 h claim's window; every other claim (the week and the model weeklies) is a 7-day one.
    static func window(_ claim: String) -> Double { claim == "five_hour" ? sessionWindow : weekWindow }

    /// One limit under the stale rule: its value and reset, or nil (unknown, out of range, or its window is over).
    /// #1898: the island's popover runs every account's every claim through this same rule.
    static func fresh(_ claim: String, util: [String: Double], at: Double, reset: [String: Int], now: Double) -> (value: Double, reset: Int?)? {
        // Outside data: the pool keeps 0...100 (its core's utils); checked again before the percent's Int().
        guard let u = util[claim], (0...100).contains(u), at.isFinite, now.isFinite else { return nil }
        if let r = reset[claim] { return Double(r) > now ? (u, r) : nil }
        return now - at < window(claim) ? (u, nil) : nil
    }

    static func percent(_ u: Double) -> String { "\(Int((u * 100).rounded()))%" }

    /// The island's line, the pool pane's words: "5h 42% · week 10%".
    var text: String {
        [session.map { "5h \(Self.percent($0))" }, week.map { "week \(Self.percent($0))" }]
            .compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// The help (and spoken) text: what each figure is and when it resets.
    func help(timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE HH:mm"
        func line(_ name: String, _ u: Double?, _ r: Int?) -> String? {
            guard let u else { return nil }
            return "\(name): \(Self.percent(u)) used" + (r.map { ", resets \(f.string(from: Date(timeIntervalSince1970: Double($0))))" } ?? "")
        }
        return (["Claude plan usage (account pool, current account)"]
                + [line("Session limit", session, sessionReset), line("Weekly limit", week, weekReset)].compactMap { $0 })
            .joined(separator: "\n")
    }
}

/// #1898: every pool account's limits for the island's popover, read only. Pure: the pool runtime hands plain values
/// (labels, claim names in its display order, its pool words); each claim goes through AgentPlanUsage.fresh, the line's
/// own stale rule. Accounts most urgent first: the highest use of any of its limits, ties by the earliest reset.
struct AgentPlanLimits: Equatable, Sendable {
    struct Limit: Equatable, Sendable {
        var claim: String
        /// The pool's display name ("5h", "week", "opus", "sonnet", "fable").
        var name: String
        var util: Double
        var reset: Int?
        /// #1899: when this limit reaches 100% at the last hour's pace, before its reset; nil: not before the reset or unknown.
        var runsOut: Int? = nil
    }

    /// #1899: one usage record sample of one claim: its time, use (1 = 100%) and the reset it was under.
    struct PaceSample: Equatable, Sendable {
        var t: Double
        var u: Double
        var r: Double
    }

    struct Account: Equatable, Sendable {
        var label: String
        var isCurrent: Bool
        /// Fresh limits only, in the given claim order; empty: no recent data.
        var limits: [Limit]
        /// The earliest cooldown still in force (the pane's "limited until"); nil: not benched.
        var benchedUntil: Int?
        /// The usage sample's epoch; nil: none.
        var sampleAt: Double?

        /// `claims`: (claim, display name) in display order; a claim not listed is not drawn.
        init(label: String, isCurrent: Bool, util: [String: Double], at: Double?, reset: [String: Int],
             cooldown: [String: Int], claims: [(claim: String, name: String)], now: Double) {
            self.label = label
            self.isCurrent = isCurrent
            sampleAt = at
            limits = at.map { at in
                claims.compactMap { c in
                    AgentPlanUsage.fresh(c.claim, util: util, at: at, reset: reset, now: now).map { Limit(claim: c.claim, name: c.name, util: $0.value, reset: $0.reset) }
                }
            } ?? []
            benchedUntil = cooldown.values.filter { Double($0) > now }.min()
        }

        var urgency: Double { limits.map(\.util).max() ?? -1 }
        var nextReset: Int { limits.compactMap(\.reset).min() ?? Int.max }
    }

    /// The pool's free share, the Account pool pane's words ("5h 162% · week 40% (more at Tue 18:00)"); nil: none known.
    var pool: String?
    var accounts: [Account]

    init(pool: String?, accounts: [Account]) {
        self.pool = pool
        self.accounts = Self.sorted(accounts)
    }

    /// #1899: each limit's runsOut from the last hour's samples, `samples[label][claim]` (any order).
    func withPace(_ samples: [String: [String: [PaceSample]]], now: Double) -> AgentPlanLimits {
        var out = self
        for i in out.accounts.indices {
            let label = out.accounts[i].label
            for j in out.accounts[i].limits.indices {
                let l = out.accounts[i].limits[j]
                out.accounts[i].limits[j].runsOut = l.reset.flatMap { Self.runsOut(samples[label]?[l.claim] ?? [], reset: $0, now: now) }
            }
        }
        return out
    }

    static let paceWindow = 3600.0
    static let paceMinSpan = 600.0

    /// #1899: when the use reaches 100% on a straight line (least squares) through the last hour's samples of the current reset
    /// window (after the last sample under another reset), if that falls after `now` and before `reset`. nil: under 2 samples,
    /// under 10 min between the first and last, a flat or falling pace, a crossing at or before now, or at or past the reset.
    static func runsOut(_ samples: [PaceSample], reset: Int, now: Double) -> Int? {
        guard now.isFinite else { return nil }
        let inHour = samples.filter { $0.t.isFinite && $0.u.isFinite && $0.t > now - paceWindow && $0.t <= now }.sorted { $0.t < $1.t }
        let cut = inHour.lastIndex { $0.r != Double(reset) }.map { $0 + 1 } ?? 0
        let s = inHour[cut...]
        guard s.count >= 2, let first = s.first, let last = s.last, last.t - first.t >= paceMinSpan else { return nil }
        let n = Double(s.count)
        let mt = s.reduce(0) { $0 + $1.t - first.t } / n, mu = s.reduce(0) { $0 + $1.u } / n
        let num = s.reduce(0) { $0 + ($1.t - first.t - mt) * ($1.u - mu) }
        let den = s.reduce(0) { $0 + ($1.t - first.t - mt) * ($1.t - first.t - mt) }
        guard den > 0 else { return nil }
        let slope = num / den
        guard slope > 0 else { return nil }
        // From the line's mean point forward to 1.
        let cross = first.t + mt + (1 - mu) / slope
        guard cross.isFinite, cross > now, cross < Double(reset) else { return nil }
        return Int(cross.rounded())
    }

    /// #1957: "week runs out in ~1 d 3 h \u{00B7} Thu 18:28 at this pace" (the limit's name, the distance and the day, as resetText); nil: no crossing before the reset.
    static func runsOutText(_ l: Limit, now: Double, timeZone: TimeZone) -> String? {
        l.runsOut.map { "\(l.name) runs out in ~\(duration(Double($0) - now)) \u{00B7} \(clock($0, format: "EEE HH:mm", timeZone: timeZone)) at this pace" }
    }

    /// Most urgent first; ties by the earliest reset, then by label (a stable order).
    static func sorted(_ accounts: [Account]) -> [Account] {
        accounts.sorted { ($1.urgency, $0.nextReset, $0.label) < ($0.urgency, $1.nextReset, $1.label) }
    }

    // MARK: Words

    /// "0 min", "59 min", "2 h 14 min", "3 d"; spoken: "2 hours 14 minutes". Negative or not finite: 0.
    static func duration(_ seconds: Double, spoken: Bool = false) -> String {
        let s = seconds.isFinite ? Int(max(0, min(seconds, 1e9))) : 0
        let m = s / 60, h = m / 60, d = h / 24
        func unit(_ n: Int, _ short: String, _ long: String) -> String { spoken ? "\(n) \(long)\(n == 1 ? "" : "s")" : "\(n) \(short)" }
        if h == 0 { return unit(m, "min", "minute") }
        if d == 0 { return [unit(h, "h", "hour"), m % 60 > 0 ? unit(m % 60, "min", "minute") : nil].compactMap { $0 }.joined(separator: " ") }
        return [unit(d, "d", "day"), h % 24 > 0 ? unit(h % 24, "h", "hour") : nil].compactMap { $0 }.joined(separator: " ")
    }

    static func clock(_ epoch: Int, format: String, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f.string(from: Date(timeIntervalSince1970: Double(epoch)))
    }

    /// #1915: "2 h 14 min · Tue 18:00", on the limit's own row (the absolute in the line's help format); nil: no reset known.
    static func resetText(_ l: Limit, now: Double, timeZone: TimeZone) -> String? {
        l.reset.map { "\(duration(Double($0) - now)) \u{00B7} \(clock($0, format: "EEE HH:mm", timeZone: timeZone))" }
    }

    /// #1915: "just now", "3 min ago": the card header's trailing age; the spoken row keeps updatedText.
    static func ago(_ at: Double, now: Double) -> String {
        now - at < 60 ? "just now" : "\(duration(now - at)) ago"
    }

    static func updatedText(_ at: Double, now: Double) -> String { "updated \(ago(at, now: now))" }

    static func benchedText(_ until: Int, timeZone: TimeZone) -> String { "benched until \(clock(until, format: "HH:mm", timeZone: timeZone))" }

    static let noData = "no recent data"

    /// #1915: an account with no fresh limit draws one compact dimmed row (no card) with this trailing status: its bench, else
    /// no recent data; nil: it has limits, a card.
    static func compactStatus(_ a: Account, timeZone: TimeZone) -> String? {
        guard a.limits.isEmpty else { return nil }
        return a.benchedUntil.map { benchedText($0, timeZone: timeZone) } ?? noData
    }

    /// #1915: one window of the pool's free share, for an aligned row: "5h", "292%", "more at Tue 11:20" (nil: none).
    struct PoolPart: Equatable, Sendable {
        var name: String
        var free: String
        var more: String?
    }

    /// #1915: `pool` split into its windows: the pane's words are "<name> <n>%[ (more at <when>)]" joined by " · ". A part
    /// without a space is all name.
    static func poolParts(_ pool: String) -> [PoolPart] {
        pool.components(separatedBy: " \u{00B7} ").filter { !$0.isEmpty }.map { part in
            var head = part, more: String?
            if part.hasSuffix(")"), let r = part.range(of: " (more at ") {
                head = String(part[..<r.lowerBound])
                more = "more at " + part[r.upperBound...].dropLast()
            }
            guard let sp = head.lastIndex(of: " ") else { return PoolPart(name: head, free: "", more: more) }
            return PoolPart(name: String(head[..<sp]), free: String(head[head.index(after: sp)...]), more: more)
        }
    }
    static let settingsLink = "Account pool settings\u{2026}"
    /// The Account pool pane's Settings id ("ext:<extension id>|<section id>", the sidebar's rule).
    static let settingsPane = "ext:com.prosper.ccpool|ccpool"

    /// The row as one spoken element: "alpha, 5 hour 15 percent, resets in 2 hours 14 minutes, Tuesday 18:00; week ...".
    static func spoken(_ a: Account, now: Double, timeZone: TimeZone) -> String {
        let limits = a.limits.map { l in
            "\(l.name == "5h" ? "5 hour" : l.name) \(Int((l.util * 100).rounded())) percent"
                + (l.reset.map { ", resets in \(duration(Double($0) - now, spoken: true)), \(clock($0, format: "EEEE HH:mm", timeZone: timeZone))" } ?? "")
                + (l.runsOut.map { ", \(l.name == "5h" ? "5 hour" : l.name) runs out at this pace in about \(duration(Double($0) - now, spoken: true)), \(clock($0, format: "EEEE HH:mm", timeZone: timeZone))" } ?? "")
        }
        let head = [OutsideText.shown(a.label, max: 40)]
        let tail = (a.limits.isEmpty ? [noData] : [limits.joined(separator: "; ")])
            + (a.benchedUntil.map { [benchedText($0, timeZone: timeZone)] } ?? [])
            + (a.sampleAt.map { [updatedText($0, now: now)] } ?? [])
        return (head + tail).joined(separator: ", ")
    }
}

/// #1757 (#1755): one session group, a section of its own: a name (the title) and a pattern matched as the sidekick
/// pattern always was. The default list is one "Sidekicks" group; an empty list puts every session in the main list.
struct SessionGroup: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var pattern: String

    /// dch's caps (#1755 contract): lines after the 8th are ignored there, a name is 1-32 bytes.
    static let maxCount = 8
    static let maxNameBytes = 32
    /// The default group's id, so the migrated group and `sidekicks(_:)` are the same group.
    static let sidekicksID = "sidekicks"

    /// The one Sidekicks group with `pattern`; none for a blank pattern (no split, as an empty pattern always was).
    static func sidekicks(_ pattern: String) -> [SessionGroup] {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [SessionGroup(id: sidekicksID, name: "Sidekicks", pattern: pattern)]
    }

    /// #1801: dch 1.132.0 skips a group named like one of its own tabs (trimmed, any case).
    static let reservedKeys: Set<String> = ["sessions", "history"]
    static func isReserved(_ name: String) -> Bool { reservedKeys.contains(nameKey(name)) }

    /// A name dch keeps: 1-32 bytes once trimmed, no "=" (dch splits the line at the first one), no control character,
    /// not one of its own tab names.
    static func validName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return (1...maxNameBytes).contains(n.utf8.count) && !isReserved(n) && !n.unicodeScalars.contains { $0 == "=" || $0.value < 0x20 || $0.value == 0x7F }
    }

    /// A name as dch and the editor compare it: trimmed, ignoring case.
    static func nameKey(_ name: String) -> String { name.trimmingCharacters(in: .whitespaces).lowercased() }

    /// What is kept: the first `maxCount` groups whose name is valid, names trimmed; #1758 (QA R1757 n86): only the first
    /// of each id (SwiftUI rows) and of each name (nameKey: one dch section per name).
    static func normalized(_ list: [SessionGroup]) -> [SessionGroup] {
        var ids = Set<String>(), names = Set<String>()
        return Array(list.filter { validName($0.name) && ids.insert($0.id).inserted && names.insert(nameKey($0.name)).inserted }.prefix(maxCount)).map {
            SessionGroup(id: $0.id, name: $0.name.trimmingCharacters(in: .whitespaces), pattern: $0.pattern)
        }
    }
}
