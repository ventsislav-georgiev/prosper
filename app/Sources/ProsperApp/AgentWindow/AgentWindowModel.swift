import AppKit
import Combine
import Foundation
import SwiftUI

// #797 Agent window D1: the sidebar of every dch session and the one conversation
// model behind the detail pane. Fed only by Agent Island's store (its poller is
// the only dch fork); the transcript mapping rides on that same --ls-json read.

/// dch 1.30's per-row `claude_session_id` and `transcript_path` (design rule 6),
/// parsed from the same `--ls-json` bytes Agent Island already read.
enum AgentTranscriptMapping {
    struct Entry: Equatable {
        let sessionID: String
        let path: String
    }

    /// #1135/#1291: dch 1.63's `claude_foreground` by row name, read outside `parse` because dch writes it for a
    /// row whose `transcript_path` is null. Only a real JSON boolean counts (a 1/0 number bridges to Bool through
    /// NSNumber); anything else, or the key left out, has no entry.
    static func foregrounds(_ data: Data) -> [String: Bool] {
        guard !data.isEmpty, let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [:] }
        var out: [String: Bool] = [:]
        for o in rows {
            guard let name = o["name"] as? String, !name.isEmpty, let n = o["claude_foreground"] as? NSNumber,
                  CFGetTypeID(n) == CFBooleanGetTypeID() else { continue }
            out[name] = n.boolValue
        }
        return out
    }

    /// #896 (dch ask 1): `cols`, `rows` and `clients` by row name (dch.c:17267-17270 at v1.99.0; left out for a master
    /// too old to say). Outside values: only plain JSON integers, a size that fits a winsize (1...65535) and a client
    /// count from 0; anything else has no entry.
    static func ptySizes(_ data: Data) -> [String: AgentSessionPty] {
        guard !data.isEmpty, let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [:] }
        func int(_ v: Any?) -> Int? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n as? Int   // nil for a fraction or a value outside Int
        }
        var out: [String: AgentSessionPty] = [:]
        for o in rows {
            guard let name = o["name"] as? String, !name.isEmpty, let cols = int(o["cols"]), let rows = int(o["rows"]),
                  let clients = int(o["clients"]), (1...65535).contains(cols), (1...65535).contains(rows), clients >= 0
            else { continue }
            out[name] = AgentSessionPty(cols: cols, rows: rows, clients: clients)
        }
        return out
    }

    /// name → mapping. Tolerant (rule 2): a row without both, a non-UUID-shaped id or
    /// a path that is not an absolute `.jsonl` maps to nothing, so the session opens
    /// terminal-first (fail closed, never a guessed file).
    static func parse(_ data: Data) -> [String: Entry] {
        guard !data.isEmpty, let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [:] }
        var out: [String: Entry] = [:]
        for o in rows {
            guard let name = o["name"] as? String, !name.isEmpty,
                  let sid = (o["claude_session_id"] ?? o["claudeSessionId"]) as? String,
                  let path = (o["transcript_path"] ?? o["transcriptPath"]) as? String,
                  !sid.isEmpty, sid.count <= 64, sid.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "-") }),
                  path.hasPrefix("/"), path.hasSuffix(".jsonl"), path.utf8.count <= 4096,
                  !path.contains("\0"), !path.split(separator: "/").contains(".."),
                  // QA #626 INFO-5: dch names `<config>/projects/<dir>/<sessionId>.jsonl`, so the file is that id's.
                  (path as NSString).lastPathComponent == "\(sid).jsonl"
            else { continue }
            out[name] = Entry(sessionID: sid, path: path)
        }
        return out
    }
}

/// The sidebar's rows, built from the island store's values. Pure.
enum AgentSidebar {
    enum RowID: Hashable {
        case live(AgentSessionKey)
        /// A History record (its `id`): it can share a key with a live session (#580).
        case history(AgentSessionKey)
        /// #836: a session on another machine, from `dch --ls-json --remote` (Terminal only).
        case remote(host: String, name: String)
    }

    /// #2002 (gap 3): the agent a live row runs, a small symbol on line two that VoiceOver reads by name; nil for a shell.
    enum AgentKind: String {
        case claude = "Claude Code", codex = "Codex"
        var symbol: String { self == .codex ? "chevron.left.forwardslash.chevron.right" : "sparkle" }
        /// dch's `agent` through AgentIsland.runsCodex with no record read (main thread); a row without it (an older
        /// dch) keeps today's rule: Claude by its session id, never Codex.
        static func of(_ s: AgentSession) -> AgentKind? {
            if AgentIsland.runsCodex(s, records: []) { return .codex }
            return s.agent == "claude" || (s.agent == nil && s.claudeSessionID?.isEmpty == false) ? .claude : nil
        }
    }

    /// #836: one `dch --ls-json --remote` row that carries a "host" key: dch writes the plain name and the host apart
    /// (dch.c:16380-16397 at v1.74.0); `stale` is dch's own two-minute cache of a host that missed its probe.
    struct Remote: Equatable {
        let host: String
        let name: String
        let alias: String
        let stale: Bool
        let cwd: String?
    }

    /// #1324 (a): one `dch --history --json --remote` record that carries a "host" key, keyed AgentSessionKey("@" + host,
    /// name) (step A's remote key), so it never meets a local record; `stale` is dch's two-minute cache of a quiet host.
    struct RemoteRecord: Equatable {
        let record: DchHistoryRecord
        let stale: Bool
        var host: String { String(record.key.dir.dropFirst()) }
    }

    struct Row: Identifiable, Equatable {
        let id: RowID
        let title: String
        /// nil for a History row.
        let state: AgentState?
        /// "Needs input", "Working", "Stopping…"; "Ended · exit 1" on a History row. #1115: the counts are fields.
        let detail: String
        /// "4m", "now" under a minute; "" for an unknown time and on a working row (#1114). #1634: `reaged` rewrites it.
        var age: String
        /// Open PR labels the island shows ("repo#12"), and "+N" past two.
        let prs: [String]
        /// Every open PR shown (the chips' fallback when they do not fit).
        var prCount = 0
        /// #1289 (G5): the shown chips' values (label, help, allowlisted url); "+N" has none.
        var prLinks: [AgentIsland.PRChip] = []
        /// #1115: live subagents and merged PRs, drawn as symbol plus number; 0 (none, or the detail is off) draws nothing.
        var agents = 0
        var merged = 0
        /// #1558: the session's Claude's running shells (dch's `shells`, newest first); [] draws nothing.
        var shells: [DchShell] = []
        var session: AgentSession?
        var record: DchHistoryRecord?
        /// #836: a row from another machine; nil for local and History rows.
        var remote: Remote?
        /// #1324: a remote History row's host (the host slot); its record is keyed "@" + host, as step A's remote key.
        var host: String?
        /// #1203: a live Claude session's row (it has a transcript) keeps the model slot, with or without a value;
        /// Codex, shell and History rows have none.
        var modelSlot = false
        /// #1203: the short name of the last answer's model ("Opus 4.7") and its effort word; effort only with a model.
        var model: String?
        var effort: String?
        /// #2002 (gap 3): the live row's agent marker; nil for a shell, History and remote rows.
        var agentKind: AgentKind?

        /// #1203: "Opus 4.7 · high", "Opus 4.7", or "" when the model is unknown.
        var modelText: String { model.map { m in effort.map { "\(m) · \($0)" } ?? m } ?? "" }
        /// #1203: "model Opus 4.7, effort high", "model Opus 4.7", or nil when unknown.
        var modelWords: String? { model.map { m in "model \(m)" + (effort.map { ", effort \($0)" } ?? "") } }

        /// #1115: the groups beside the state text, agents, shells (#1558) then merged; a count of 0 is left out.
        var counts: [(Count, Int)] { [(Count.agents, agents), (Count.shells, shells.count), (Count.merged, merged)].filter { $0.1 > 0 } }
        /// #1558: the shells group's help, the list itself (AgentSidebar.shellList); the others read their words.
        var countHelp: [Count: String] { shells.isEmpty ? [:] : [.shells: AgentSidebar.shellList(shells)] }
        /// The counts in words for VoiceOver, the open PRs too (whether their chips or their count shows).
        var countWords: [String] { (counts + (prCount > 0 ? [(Count.open, prCount)] : [])).map { $0.0.words($0.1) } }
    }

    /// #1115: a count drawn as an SF Symbol plus a number (they follow the theme colour and the UI scale; an
    /// emoji does not); VoiceOver and the help read the words.
    enum Count: CaseIterable {
        case agents, merged, open, shells

        var symbol: String {
            switch self {
            case .agents: "person.2"
            case .merged: "arrow.triangle.merge"
            case .open: "arrow.triangle.pull"
            case .shells: "terminal"
            }
        }

        /// "2 agents", "192 merged pull requests", "1 open pull request"; "99999+" above 99999, as drawn.
        func words(_ n: Int) -> String {
            let noun = switch self {
            case .agents: "agent"
            case .merged: "merged pull request"
            case .open: "open pull request"
            case .shells: "running shell"
            }
            return "\(AgentIsland.count(n)) \(noun)\(n == 1 ? "" : "s")"
        }
    }

    struct Section: Identifiable, Equatable {
        let title: String
        let rows: [Row]
        /// #1759: the fold and drawn-items key: the title, a group's `groupFold(id)` (a rename keeps it, two groups never share it).
        let id: String
        init(title: String, rows: [Row], id: String? = nil) { self.title = title; self.rows = rows; self.id = id ?? title }
    }

    /// #1342: one drawn sidebar row. #1820: pairs are gone, so an item is always one row; `rows` keeps the drawn list's
    /// shape (numbers, scroll targets).
    struct Item: Identifiable, Equatable {
        let id: RowID
        let rows: [Row]
    }

    /// #1342: the drawn rows of each section, by id (#1759: a group section's is its fold key): one item per row.
    static func items(_ sections: [Section]) -> [String: [Item]] {
        Dictionary(sections.map { s in (s.id, s.rows.map { Item(id: $0.id, rows: [$0]) }) }) { a, _ in a }
    }


    /// #1558: the shells chip's list, every text through OutsideText.shown: "2 running shells", then by owner (main first,
    /// then each subagent in dch's order under its description, else its id, then the shells dch could not place), each
    /// shell's command with its description as the line below, newest first as dch gives them. One group: no group headers.
    static func shellList(_ shells: [DchShell], max: Int = 20) -> String {
        var order: [String??] = [], groups: [String??: [DchShell]] = [:], names: [String: String] = [:]
        for sh in shells.prefix(max) {
            if groups[sh.agent] == nil { order.append(sh.agent) }
            groups[sh.agent, default: []].append(sh)
            if case let .some(.some(a)) = sh.agent, names[a] == nil, let d = sh.agentDescription { names[a] = d }
        }
        // main first, the unplaced last, the subagents between in their first-seen order
        func rank(_ a: String??) -> Int {
            switch a { case .some(.none): 0; case .some(.some): 1; case nil: 2 }
        }
        order = (0...2).flatMap { r in order.filter { rank($0) == r } }
        var lines = [Count.shells.words(shells.count)]
        for owner in order {
            if order.count > 1 {
                switch owner {
                case .some(.none): lines.append("Main conversation")
                case let .some(.some(a)): lines.append("Agent: " + OutsideText.shown(names[a] ?? a, max: 80))
                case nil: lines.append("Owner unknown")
                }
            }
            for sh in groups[owner] ?? [] {
                lines.append("  " + OutsideText.shown(sh.command))
                if let d = sh.description { lines.append("    " + OutsideText.shown(d, max: 80)) }
            }
        }
        if shells.count > max { lines.append("and \(shells.count - max) more") }
        return lines.joined(separator: "\n")
    }

    static let needsYouTitle = "Needs you"
    static let otherMachinesTitle = "Other machines"   // #836
    /// #828: the sections a header click folds away. Needs you never folds: it is the list of
    /// sessions waiting on the human.
    static let collapsible: Set<String> = ["Sessions", "Other machines", "History", "Layouts"]   // #901 B3 step 4b: Layouts
    /// #1759: a session group's section folds by its id, never its name; the stored fold set keeps this string form.
    static func groupFold(_ id: String) -> String { "group:" + id }
    /// #2060: a group section's live sessions, the rows its header's "\u{22EF}" acts on; nil for any other section.
    static func groupSessions(_ section: Section) -> [AgentSession]? {
        section.id.hasPrefix("group:") ? section.rows.compactMap(\.session) : nil
    }
    /// #1759: what a header click folds: a fixed title above or any group's section.
    static func folds(_ id: String) -> Bool { collapsible.contains(id) || id.hasPrefix("group:") }

    /// Waiting for the human: blocked on a prompt, or done (the turn is over and the
    /// next message is theirs). Working and idle sessions are not.
    static func needsYou(_ s: AgentSession) -> Bool { s.state == .blocked || s.state == .done }

    /// "Needs you" first (blocked before done, newest first), then the island's own
    /// Sessions / Sidekicks split in its sort order, then History. A session sits in
    /// one group only; empty groups are left out.
    /// #829 G0: `actions` are the island's row texts; a running one replaces the state word.
    static func sections(sessions: [AgentSession], history: [DchHistoryRecord], sort: AgentIslandSort,
                         groups: [SessionGroup], details: AgentIslandRowDetails, now: TimeInterval,
                         actions: [AgentSessionKey: String] = [:], remote: [Remote] = [],
                         remoteHistory: [RemoteRecord] = []) -> [Section] {
        let needs = sessions.filter(needsYou).sorted(by: before)
        let rest = AgentIsland.split(AgentIsland.sorted(sessions.filter { !needsYou($0) }, by: sort), groups: groups)
        var out: [Section] = []
        func add(_ title: String, _ rows: [Row], id: String? = nil) { if !rows.isEmpty { out.append(Section(title: title, rows: rows, id: id)) } }
        let live = { (s: AgentSession) in row(s, details: details, now: now, action: actions[s.key]) }
        add(needsYouTitle, needs.map(live))
        add("Sessions", rest.primary.map(live))
        for g in rest.groups { add(g.group.name, g.sessions.map(live), id: groupFold(g.group.id)) }   // #1757: one section per group, in order
        // #836: grouped under their host (host, then name), after the local live rows.
        add(otherMachinesTitle, remote.sorted { ($0.host, $0.name) < ($1.host, $1.name) }.map(row))
        // #1324 (a): after the local records (unchanged), each host's, capped per host as dch's picker does (50 names).
        let stale = Set(remoteHistory.filter(\.stale).map(\.record.id))
        // R1364-s1: a name live on a host hides that host's records only (the key carries "@" + host).
        let liveFar = Set(remote.map { AgentSessionKey(dir: "@" + $0.host, name: $0.name) })
        let far = Dictionary(grouping: remoteHistory, by: \.host).sorted { $0.key < $1.key }
            .flatMap { AgentIsland.cappedHistory($0.value.map(\.record), live: liveFar) }
            .map { row($0, now: now, stale: stale.contains($0.id), action: actions[$0.id]) }
        add("History", AgentIsland.cappedHistory(history, live: Set(sessions.map(\.key))).map { row($0, now: now) } + far)
        return out
    }

    /// Needs you's order, and AgentIsland.sorted's `.activity` one: state, newest activity, then name and dir.
    static func before(_ a: AgentSession, _ b: AgentSession) -> Bool {
        if a.state != b.state { return a.state < b.state }
        if a.activity != b.activity { return a.activity > b.activity }
        return (a.key.name, a.key.dir) < (b.key.name, b.key.dir)
    }

    /// #1634: `sections` again for a list where only activity (or the clock) moved: each live row takes its session and
    /// age from `sessions`, a History row its age at `now`; nothing else is rebuilt. nil (build afresh): a live row's
    /// session is not in `sessions`, or the new activity orders two neighbouring live rows the other way (Needs you, and
    /// Sessions / Sidekicks under `.activity`; `.name` never reads activity).
    static func reaged(_ sections: [Section], sessions: [AgentSession], sort: AgentIslandSort,
                       now: TimeInterval) -> [Section]? {
        let live = Dictionary(sessions.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Section] = []
        for section in sections {
            let ordered = section.id == needsYouTitle || sort == .activity
            var rows: [Row] = []
            for var r in section.rows {
                if let k = r.session?.key {
                    guard let s = live[k] else { return nil }
                    if ordered, let p = rows.last?.session, !before(p, s) { return nil }
                    r.session = s
                    r.age = AgentIsland.age(of: s, now: now)
                } else if let rec = r.record {
                    r.age = rec.lastSeen > 0 ? AgentIsland.age(now - rec.lastSeen) : ""
                }
                rows.append(r)
            }
            out.append(Section(title: section.title, rows: rows, id: section.id))
        }
        return out
    }

    /// #1519: the model label a live row draws (nil: no Claude transcript, or no model read yet); the phone list shares it.
    static func modelLabel(_ s: AgentSession) -> String? {
        s.transcriptPath != nil || s.modelCarried > 0 ? s.model.map(AgentModelEffort.shortName) : nil
    }

    static func row(_ s: AgentSession, details: AgentIslandRowDetails, now: TimeInterval, action: String? = nil) -> Row {
        // #829 G0: "Stopping…", "Pausing…" while a Restart or Stop runs (from the island or the window).
        let (chips, more) = AgentIsland.prChips(s.meta, show: details, budget: .infinity)
        let prs = chips.prefix(2).map(\.label) + (chips.count + more > 2 ? ["+\(chips.count + more - 2)"] : [])
        // dch's agents is an unclamped Int (DchCommand.parseListJSON); merged is clamped by DchSessionMeta.count.
        // #1203: only a Claude session has a transcript (dch sets the path with a Claude only); the effort only with a model.
        // #1267: or a label carried over an answer with no mapping (display only).
        let claude = s.transcriptPath != nil || s.modelCarried > 0, model = modelLabel(s)
        return Row(id: .live(s.key), title: s.title, state: s.state, detail: AgentWindowControls.lock(action) ?? s.state.label,
                   age: AgentIsland.age(of: s, now: now), prs: prs, prCount: chips.count + more, prLinks: Array(chips.prefix(2)),
                   agents: details.agents ? max(0, s.agents) : 0, merged: details.merged ? max(0, s.meta?.merged ?? 0) : 0,
                   shells: details.shells ? s.shells : [], session: s, modelSlot: claude, model: model, effort: model == nil ? nil : s.effort,
                   agentKind: AgentKind.of(s))
    }

    static func row(_ r: DchHistoryRecord, now: TimeInterval) -> Row {
        Row(id: .history(r.id), title: r.title, state: nil, detail: "Ended · " + AgentIsland.endLabel(r.end),
            age: r.lastSeen > 0 ? AgentIsland.age(now - r.lastSeen) : "", prs: [], record: r)
    }

    /// #1324 (a): a remote record's row: the local row's text (its Resume's text while one runs or after), the host slot.
    static func row(_ r: DchHistoryRecord, now: TimeInterval, stale: Bool, action: String?) -> Row {
        Row(id: .history(r.id), title: OutsideText.shown(r.title), state: nil,   // #1330 (R836-q2)
            detail: action.map { OutsideText.shown($0) } ?? (stale ? "Stale \u{00B7} " : "") + "Ended \u{00B7} " + AgentIsland.endLabel(r.end),
            age: r.lastSeen > 0 ? AgentIsland.age(now - r.lastSeen) : "", prs: [], record: r,
            host: String(r.key.dir.dropFirst()))
    }

    /// #836 (c): no island state (the island answers only for local sessions): no state glyph, no age, nothing to answer.
    static func row(_ r: Remote) -> Row {
        // #1330 (R836-q2): outside text, drawn as the layout names are; the id keeps the raw host and name (argv).
        Row(id: .remote(host: r.host, name: r.name), title: OutsideText.shown(r.alias.isEmpty ? r.name : r.alias), state: nil,
            detail: r.stale ? "Stale" : "Terminal only", age: "", prs: [], remote: r)
    }

    /// #836 (a): the rows of `dch --ls-json --remote` output that carry a "host"; local rows (no "host") are the island's.
    /// nil when the bytes are not a JSON array (a timed-out or failed call): the caller keeps what it had. A name or host
    /// that is empty, over 256 bytes, starts with "-" (dch would read it as a flag) or holds a control character is
    /// left out, as is a second row of the same host and name.
    static func parseRemote(_ data: Data) -> [Remote]? {
        guard !data.isEmpty, let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let ok = remoteOK
        var seen = Set<[String]>(), out: [Remote] = []
        for o in rows {
            guard let host = o["host"] as? String, let name = o["name"] as? String, ok(host), ok(name),
                  seen.insert([host, name]).inserted else { continue }
            let alias = (o["alias"] as? String).flatMap { ok($0) ? $0 : nil } ?? ""
            let stale = (o["stale"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
            out.append(Remote(host: host, name: name, alias: alias, stale: stale, cwd: o["cwd"] as? String))
        }
        return out
    }

    /// #836: a name or host Prosper passes on: not empty, at most 256 bytes, no leading "-" (dch would read a flag),
    /// no C0 control or DEL.
    static func remoteOK(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 256 && !s.hasPrefix("-") && !s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    /// #1324 (a): the records of `dch --history --json --remote` that carry a "host" (the local ones, without, are the
    /// island's), each read by the island's own parseHistory under the dir "@" + host. nil when the bytes are not a JSON
    /// array (a timed-out or failed call): the caller keeps what it had. A host, name or file that remoteOK refuses is
    /// left out, as is a second record of the same host and id. Per host as cappedHistory orders it (#1347: pinned, then A to Z).
    static func parseRemoteHistory(_ data: Data) -> [RemoteRecord]? {
        guard !data.isEmpty, let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var seen = Set<AgentSessionKey>()
        return rows.compactMap { o -> RemoteRecord? in
            guard let host = o["host"] as? String, let name = o["name"] as? String, remoteOK(host), remoteOK(name),
                  (o["file"] as? String).map({ $0.isEmpty || remoteOK($0) }) ?? true,
                  let one = try? JSONSerialization.data(withJSONObject: [o]),
                  let r = AgentIsland.parseHistory(one, dir: "@" + host).first, seen.insert(r.id).inserted else { return nil }
            let stale = (o["stale"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
            return RemoteRecord(record: r, stale: stale)
        }.sorted { $0.host != $1.host ? $0.host < $1.host : $0.record.lastSeen > $1.record.lastSeen }
    }

    /// The transcript model's input for a live session.
    static func source(_ s: AgentSession) -> AgentTranscriptSource {
        let state = switch s.state {
        case .blocked: "blocked"
        case .working: "working"
        case .done: "done"
        case .idle: "idle"
        }
        return AgentTranscriptSource(key: s.key, dchVersion: s.version, dchState: state,
                                     sessionId: s.claudeSessionID, transcriptPath: s.transcriptPath,
                                     codex: AgentIsland.runsCodex(s, records: []))   // #2002: dch's `agent`, no record read
    }
}

/// #831 B1 step 2 (4.1a, rider R899-3): the lastLive map's home. The window's owner (`AgentsWindow`) keeps one for the
/// process and hands it to every model it builds, so a pane's last live sight outlives a window close; a model built
/// without one (tests) gets its own. B1 step 3 (R1193-3): pruned to the store's panes on load and on a layout delete.
@MainActor
final class AgentLastLiveHome {
    var map: AgentPaneLayout.LastLiveMap = [:]
}

/// #831 B1 step 2 (4.4, 11.2): one pane's runtime in the active layout: its own transcript model and its kept display
/// row. `ended` and `content` publish themselves (written only on a change), so a view of an UNFOCUSED pane is told of
/// an entry into or an exit from Ended, which changes no `selection` (step 1 review (a)).
@MainActor
final class AgentPaneRuntime: ObservableObject {
    let pane: UUID
    let transcript = AgentTranscriptModel()
    /// 4.4 M1: the session ended while this pane's transcript ran: its last live row, the blocks kept (suspended).
    @Published fileprivate(set) var ended: (target: PaneTarget, row: AgentSidebar.Row)?
    /// The pane's content as of the last resolve.
    @Published fileprivate(set) var content: PaneContent?
    /// The pane's live row as of the last resolve: what `ended` keeps when the session goes.
    fileprivate var liveRow: AgentSidebar.Row?
    /// #1477 (spec 15 C): this pane's own terminal, split gate on only; made by the model on first need (`paneTerminal`).
    fileprivate(set) var terminal: AgentTerminalController?

    init(pane: UUID) { self.pane = pane }
}

/// The window's state: the sidebar, the selection and one transcript model per pane of the active layout.
/// Energy (design "Energy"): nothing runs unless the window is open and visible.
/// While hidden the transcript is stopped and the age clock is off; `close` drops
/// the store subscription too.
@MainActor
final class AgentWindowModel: ObservableObject {
    @Published private(set) var sections: [AgentSidebar.Section] = [] { didSet { drawnMemo = nil } }
    /// #831 B1 (spec 3.5): the focused pane's RESOLVED content as a row (`.live` -> .live(k), `.history` -> .history(id),
    /// anything else nil), written only by `settle()`. Stored so `$selection` publishes one change per change.
    @Published private(set) var selection: AgentSidebar.RowID?
    /// #831: the window's active layout. B1 step 3 (8.1): restored from the store on open (init, `layouts`), else a
    /// fresh one; every change is saved (`autosave`). Every selection change goes into its focused pane through the
    /// browse rule (`show`, 7.1). 15.0: a multi-pane layout keeps its whole tree here with the split gate off;
    /// `shownPanes` reduces it to the focused pane, and nothing saves that reduction.
    private(set) var layout = PaneLayout.single() {
        // #900 B2 step 5b (R900-5a-1): any writer but the drag's own move (perform, select, bind, the store refresh, a
        // pick, a nudge) ends a drag first: its live ratio is saved once, then this change by the didSet's rule.
        willSet { if dividerDrag != nil, !dragMoving { dragEnded() } }
        didSet {
            // #1645: the old focused pane's terminal view outlives a focus switch now (AgentPaneTerminalColumn), so it no
            // longer drops the keys by leaving the window: it gives them up here, before adopt's focusSelection asks the
            // new pane's (pending until that one is live). Read before syncRuntimes can drop a closed pane's runtime.
            if AgentPaneLayout.splitsEnabled, layout.focused != oldValue.focused,
               let v = runtimes[oldValue.focused]?.terminal?.view, let w = v.window, w.firstResponder === v {
                w.makeFirstResponder(nil)
            }
            // 4.1a: a retarget or a closed pane loses its sight; a layout switch (another id) keeps every layout's.
            if oldValue.id == layout.id { lastLive = AgentPaneLayout.retargeted(lastLive, from: oldValue, to: layout) }
            syncRuntimes(switched: oldValue.id != layout.id)
            // #900 B2 step 4b (7.2): a new value settle() did not already tell (a zoom, a split, a close or focus move that
            // keeps the row) is published once, so the sidebar's "in view" glyphs redraw. Gate on only: nothing changes off.
            if !settle(), layout != oldValue, AgentPaneLayout.splitsEnabled { objectWillChange.send() }
            syncTier()   // R900-4b-1: a split or close moves the line too, so the stored tier never goes stale
            // #900 B2 step 6b2b (7.2): the focused pane moved, so its input box is built anew in the new pane (AgentPaneArea
            // draws the old one's as inert): forget the old box, so a focus asked for waits for the new one (pending).
            if AgentPaneLayout.splitsEnabled, layout.focused != oldValue.focused { interaction.composer = nil }
            if dividerDrag == nil { autosave() }   // #900 B2 step 5a (8.1): a divider drag saves once, at its end
            // R1895 f1: a Swap Session… request no switcher took is dropped once the focus moves (a one-shot, never stale)
            if swapRequest != nil, layout.focused != oldValue.focused { swapRequest = nil }
            // R901-s4b-q2: another active layout ends an open inline rename (nothing written).
            if layoutRenaming != nil, layout.id != oldValue.id { layoutRenaming = nil }
        }
    }
    /// 8.1 / 8.2: where the layouts load from and save to: the owner passes the app's defaults, tests a private
    /// XCTestDefaults suite. nil: the model neither loads nor saves (every model built without one).
    private let layoutDefaults: UserDefaults?
    /// 8.1: the window's layouts as loaded and as last saved; nil without `layoutDefaults`.
    private(set) var layouts: PaneLayoutStore?
    /// Counts blob writes (tests: a change writes once, a publish that changes nothing writes nothing).
    private(set) var layoutWrites = 0
    /// #1538: the active layout set aside while the single-pane view shows a session outside a made layout; nil otherwise.
    /// The single-pane view is not a layout: never stored, never counted against the 9, no Layouts row is active.
    private(set) var parked: PaneLayout?
    /// #1538, #1895 (operator 2026-11-23: no edit mode): a layout the person made: the split gate on, a store loaded and the
    /// Layouts section's show rule (two panes or more, or two layouts or more; the lone one-pane layout follows the pick).
    /// Then a sidebar pick of a session outside it opens the single-pane view (lockedShowing) unless the focused pane is
    /// empty (it takes the pick); every change of it is saved at once (autosave); the single-pane view never is.
    var layoutMade: Bool {
        guard AgentPaneLayout.splitsEnabled, let s = layouts else { return false }
        return parked != nil || layout.panes.count >= 2 || s.layouts.count >= 2
    }

    /// #901 B3 step 2 (decision c): the pane bind(nil) emptied in memory and the target it had; nil while the island is on.
    private var offEmptied: (layout: UUID, pane: UUID, target: PaneTarget?)?
    /// R899-2: the browse rule's refusal of the last pick (select() kept the layout as it was); the next pick that
    /// lands drops it. The pane notice line (3.3) draws its `notice`.
    @Published private(set) var paneRefusal: PaneRefusal?
    /// #831 A2 (4.1a): the panes' last live sights, stamped by `stampLastLive` in the store's publish sink only.
    /// B1 step 2 (R899-3): kept by the window's owner (`lastLiveHome`), so it outlives this model.
    private(set) var lastLive: AgentPaneLayout.LastLiveMap {
        get { lastLiveHome.map }
        set { lastLiveHome.map = newValue }
    }
    let lastLiveHome: AgentLastLiveHome
    /// False while the island is off (no store): the window says so.
    @Published private(set) var hasStore = false { didSet { sidebarColumnMoved() } }
    /// #831 B1 step 2 (11.2): one runtime per pane of the active layout, keyed by pane id; freed by a close.
    private(set) var runtimes: [UUID: AgentPaneRuntime] = [:]
    var focusedRuntime: AgentPaneRuntime? { runtimes[layout.focused] }
    /// After `close()` (no runtime left): a model that never starts, for a late reader.
    private lazy var detachedTranscript = AgentTranscriptModel()
    /// The focused pane's conversation model (every existing reader, the view included, means that pane's). The same
    /// object across a row change in that pane (rewrite 11, restated per pane runtime); another pane's is another.
    var transcript: AgentTranscriptModel { focusedRuntime?.transcript ?? detachedTranscript }
    /// The shown panes (11.1) from frames in `paneArea`: with the split gate off, the focused pane alone (15.0).
    /// #900 B2 step 2 (7.4): zoomed, the zoomed pane (always the focused one) alone; the frames stay the tiling.
    var shownPanes: Set<UUID> {
        let tiled = Set(paneFrames(in: paneArea).keys)
        guard AgentPaneLayout.splitsEnabled, let z = layout.zoomed, tiled.contains(z) else { return tiled }
        return [z]
    }
    /// #900 B2 step 4b (7.2): the rows of the sessions shown in the active layout other than the focused pane's (the
    /// sidebar's "in view" glyph). From `shownPanes`, so a zoom or the too-small fallback (the focused pane alone) gives
    /// none. O(panes): one tiling walk and one resolved row per pane. Empty with the split gate off; the sidebar reads
    /// it once per section. shortcut: `paneArea` is not published, so a resize across the too-small line alone shows
    /// at the next model publish (as the band's chip, AgentWindowBand); publish it if that ever shows.
    var inViewRows: Set<AgentSidebar.RowID> {
        guard AgentPaneLayout.splitsEnabled else { return [] }
        let shown = shownPanes
        var rows = Set(layout.panes.compactMap { p in
            shown.contains(p.id) && p.id != layout.focused ? Self.resolvedRow(runtimes[p.id]?.content) : nil
        })
        if let selection { rows.remove(selection) }   // the focused pane's session keeps the selection bar alone
        return rows
    }
    /// 3.3 (#900 B2 step 2): the minimum pane, 300x200·s: the one value paneFrames tiles with and perform's split
    /// checks, so a split that passes its room check is always drawn tiled.
    var paneMinimum: CGSize { CGSize(width: sz(PaneLayout.minimumPane.width), height: sz(PaneLayout.minimumPane.height)) }
    /// #831 B1 step 4: the panes to draw in `area` and where (the view passes its own size, so a frame is never a
    /// layout pass behind): the layout's frames; too small (3.4): the focused pane alone at the whole area.
    func paneFrames(in area: CGRect) -> [UUID: CGRect] {
        switch layout.frames(in: area, minimum: paneMinimum, splitsEnabled: AgentPaneLayout.splitsEnabled) {
        case let .tiled(f): f
        case let .tooSmall(id): [id: area]
        }
    }
    /// The pane area's size: written by the view (AgentPaneArea, R1193-4) and by tests. `.zero`: the focused pane alone.
    /// Not @Published (the view draws from its own size); the same size again follows nothing.
    var paneArea: CGRect = .zero {
        didSet { if paneArea != oldValue { paneAreaChanges += 1; follow(); syncTier() } }
    }
    /// #900 B2 step 6b2e (R900-4b-1, 3.4): the too-small tier of `paneArea` for the active layout, published so a resize
    /// that only crosses the line redraws the sidebar's glyphs and the band's chip. Gate on only; written only on a
    /// change, from paneArea's didSet (the view's onAppear/onChange actions, after the body pass) and the layout's.
    @Published private(set) var paneTooSmall = false
    private func syncTier() {
        guard AgentPaneLayout.splitsEnabled else { return }   // gate off: nothing read, nothing written
        // #1697: an unmeasured area (.zero, before the view's first pass) is not too small: no band flash on open.
        // #1698 (QA R1697 n35): a band up for the tier alone is measured as the area it took, so the line is the same
        // both ways (else the band's 30 pt kept the tier on until the window grew 30 pt past the line).
        var area = paneArea
        if paneTooSmall && !AgentWindowBand.showsBesidesTier(self) { area.size.height += AgentWindowBand.height }
        let t = if paneArea.isEmpty { false } else if case .tooSmall = layout.frames(in: area, minimum: paneMinimum, splitsEnabled: true) { true } else { false }
        if t != paneTooSmall { paneTooSmall = t }
    }
    /// Counts `paneArea` changes (tests: the same size twice is one change).
    private(set) var paneAreaChanges = 0
    /// 4.2 "Pick Another": the window gives the sidebar the keys (AgentsWindow wires it; tests count it).
    var focusSidebar: () -> Void = {}
    /// #1925: the sidebar column came, went or changed mode: the window re-reads its minimum (AgentsWindow wires it).
    var sidebarColumnChanged: () -> Void = {}
    /// #1925: the column's mode, shown state or store changed. R1923 i1: the drag handle may have left the tree mid-drag
    /// (its gesture is cancelled, no mouse-up comes), so a live sidebar drag ends here, as dragBegan ends a divider's.
    private func sidebarColumnMoved() {
        sidebarDragEnded()
        sidebarColumnChanged()
    }

    /// #831 7.2 (R6.1): which side takes plain arrows and Return; replaces the window's own Bool (`sidebarFocused` now
    /// reads and writes this). Set by a click (`mouseDown`), Tab, Pick Another and the pane focus actions; a publish, an
    /// autosave or an attention change never sets it (R6.9). Not @Published: nothing draws it.
    var keyFocus: PaneKeys.KeyFocus = .sidebar

    /// #900 B2 step 4 (7.2, R900-2): the sidebar hidden by ⌃⌘S; read from `Preferences.agentWindowSidebarHidden` (a
    /// Bool, nothing else) when the model is made and written on every toggle. Drawn only through `sidebarShown`.
    @Published private(set) var sidebarHidden = Preferences.agentWindowSidebarHidden { didSet { sidebarColumnMoved() } }
    /// The sidebar is drawn: always with the split gate off (15.0: the parent's window), else unless hidden. The root
    /// view, `sidebarFrame` and `paneAreaFrame` all read this one value.
    /// #1379: Slide draws no column; its sidebar is shown only while it is slid in (an overlay over the panes).
    var sidebarShown: Bool {
        sidebarMode == .slide ? slideOpen : !(AgentPaneLayout.splitsEnabled && sidebarHidden)
    }

    /// #1379: Settings' and the Go menu's sidebar mode (Preferences.agentSidebarMode), read when the model is made.
    @Published private(set) var sidebarMode = Preferences.agentSidebarMode { didSet { sidebarColumnMoved() } }
    /// #1379 Slide: slid in by the pointer at the window's left edge (#1458: its hover area; out again a while after it
    /// leaves the area and the sidebar), or pinned by Control-Command-S.
    @Published private(set) var slideRevealed = false
    @Published private(set) var slidePinned = false
    var slideOpen: Bool { slideRevealed || slidePinned }
    /// #1379: Reduce Motion, read on every slide (tests set it); on, the sidebar shows and hides at once.
    static var reduceMotion: @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// #1379 tests: the last slide's animation was on (nil: no slide yet).
    private(set) var lastSlideAnimated: Bool?

    /// #1379: the full sidebar's width and Mini's rail. #1470 a2 (operator 2026-11-17, "Widen the sidebar"): TIP's sz(290)
    /// plus how much wider the full row's chip column (all 18 chips) is than the nine Command chips' (Mini's column), so a
    /// row's title and badges keep TIP's room; the panes are that much narrower.
    static var fullSidebarWidth: CGFloat { fullSidebarWidth(at: ThemeRuntime.scale) }
    static func fullSidebarWidth(at scale: CGFloat) -> CGFloat { 290 * scale + digitColumnExtra(at: scale) }
    /// #1470 a2: that difference at the current UI scale, from the chip views' exact ideal widths (once per scale).
    static var digitColumnExtra: CGFloat { digitColumnExtra(at: ThemeRuntime.scale) }
    static func digitColumnExtra(at scale: CGFloat) -> CGFloat {
        if let w = digitColumnExtraByScale[scale] { return w }
        let saved = ThemeRuntime.scale
        ThemeRuntime.scale = scale   // the chips' fonts and paddings read it while they are measured
        defer { ThemeRuntime.scale = saved }
        let w = AgentSidebarRowView.idealWidths(AgentSidebarRowView.digitColumn, AgentSidebarRowView.miniDigitColumn)
        guard w.count == 2 else { return 0 }   // not measured: TIP's width, and measured again on the next read
        digitColumnExtraByScale[scale] = max(0, w[0] - w[1])
        return max(0, w[0] - w[1])
    }
    private static var digitColumnExtraByScale: [CGFloat: CGFloat] = [:]
    /// #1457: Mini's rail fits a name of `miniNameLength` wide characters, its superscript, the mark and needs-you slots
    /// (AgentSidebarRowView.miniWidestLine, measured at the current UI scale, once per scale), and the list's padding.
    static var miniSidebarWidth: CGFloat { miniSidebarWidth(at: ThemeRuntime.scale) }
    static func miniSidebarWidth(at scale: CGFloat) -> CGFloat {
        if let w = miniSidebarWidthByScale[scale] { return w }
        let saved = ThemeRuntime.scale
        ThemeRuntime.scale = scale   // the line's fonts and paddings read it while it is measured
        defer { ThemeRuntime.scale = saved }
        // not measured: the full sidebar (nothing clips), measured again on the next read
        guard let line = AgentSidebarRowView.idealWidths(AgentSidebarRowView.miniWidestLine, EmptyView()).first, line > 0 else {
            return fullSidebarWidth
        }
        let w = (line + 2 * sz(8)).rounded(.up)   // AgentSidebarView's list pads each side by sz(8)
        miniSidebarWidthByScale[scale] = w
        return w
    }
    private static var miniSidebarWidthByScale: [CGFloat: CGFloat] = [:]
    /// #1457: Mini's quick full-name tooltip (its rows report their hover to it).
    let miniTip = AgentMiniTip()
    /// #1923: Full's (and Slide's overlay's) dragged width; fullSidebarWidth stays its minimum.
    let sidebarWidth = AgentSidebarWidth()
    /// R1923 i1: the live drag's gesture start (nil between drags and for the keyboard's steps).
    private var sidebarDragOrigin: CGFloat?
    /// #1923: a drag on the Full sidebar's line moved `dx` since it began: the terminals re-grid at its end only (as 7.5's
    /// divider drag), so a tick is the layout alone. R1923 i1: `from` is the gesture's start (nil: the keyboard's step);
    /// a new start while a drag is live is a new drag whose last one never ended: that one ends first, and this restarts
    /// from the drawn width.
    func sidebarDragged(by dx: CGFloat, from x: CGFloat? = nil) {
        if let x, x != sidebarDragOrigin { sidebarDragEnded(); sidebarDragOrigin = x }
        if !sidebarWidth.dragging { for t in allTerminals { t.liveResizeStarted() } }
        sidebarWidth.dragged(by: dx)
    }
    /// #1923: the drag's mouse-up: the width is written once and each terminal pushes its grid once.
    func sidebarDragEnded() {
        sidebarDragOrigin = nil
        guard sidebarWidth.dragging else { return }
        sidebarWidth.ended()
        for t in allTerminals { t.liveResizeEnded() }
    }
    /// #1379: the width the sidebar column takes from the panes: Full, Mini's rail, Slide none (its sidebar is an overlay).
    var sidebarColumnWidth: CGFloat {
        switch sidebarMode {
        case .full: return sidebarWidth.drawn
        case .mini: return Self.miniSidebarWidth
        case .slide: return 0
        }
    }

    /// #1379: a new mode from Settings or the Go menu, saved and drawn at once; Slide starts slid out.
    func setSidebarMode(_ m: AgentSidebarMode) {
        Preferences.agentSidebarMode = m
        guard m != sidebarMode else { return }
        sidebarMode = m
        (slideRevealed, slidePinned, slideInArea, slideInSidebar, slideAreaHeld) = (false, false, false, false, false)
        slideCancel()
        if !sidebarShown { keyFocus = .pane }
    }

    /// #1379 Slide: the sidebar's enter (true) reveals at once, its exit (false) hides `slideHideDelay` later unless the
    /// pointer is back over the sidebar or the hover area by then (#1458); a pinned sidebar stays. Other modes: nothing.
    /// #1461: while a menu or popover of the sidebar is open an exit is held (it stays revealed and keeps the keys); an
    /// enter drops the held exit.
    func slide(_ reveal: Bool) {
        guard sidebarMode == .slide else { return }
        slideInSidebar = reveal
        slideExitHeld = slideMenusOpen > 0 && !reveal
        if reveal {
            slideCancel()
            if !slideRevealed { animateSlide { slideRevealed = true } }
        } else {
            slideHideLater()
        }
    }

    /// #1458: the hover area's dwell before it opens the sidebar, and the wait after the pointer has left both the area
    /// and the sidebar before it hides. Static seams: tests shorten them.
    static var slideOpenDelay: Duration = .milliseconds(150)
    static var slideHideDelay: Duration = .milliseconds(1500)
    /// #1458: the pointer is over the hover area or the slid sidebar (their trackers' enter, move and exit).
    private(set) var slideInArea = false
    private(set) var slideInSidebar = false
    /// #1458: Control-Command-S closed the sidebar with the pointer in the area: no dwell starts from it until the area
    /// reports the pointer left (a move there would else reopen it 150 ms later).
    private(set) var slideAreaHeld = false
    /// #1458: the pending dwell (open) or hide.
    private var slideTimer: (open: Bool, task: Task<Void, Never>)?

    /// #1458: the hover area's enter or move (true) and exit (false). Slid out: inside starts the dwell (a move keeps a
    /// running one), outside drops it, so a pass that leaves sooner opens nothing. Slid in: inside drops a pending hide,
    /// outside starts it unless the pointer is over the sidebar. A move also reopens after a hide that landed (or an
    /// area made) with the pointer already inside, which sends no fresh enter.
    func slideArea(_ inside: Bool) {
        guard sidebarMode == .slide else { return }
        slideInArea = inside
        if !inside { slideAreaHeld = false }
        guard !slideAreaHeld else { return }
        switch (slideRevealed, inside) {
        case (false, true): slideLater(open: true)
        case (false, false), (true, true): slideCancel()
        case (true, false): slideHideLater()
        }
    }

    /// #1458: starts the hide unless the pointer is over the area or the sidebar, or a sidebar menu holds the exit.
    private func slideHideLater() {
        guard slideRevealed, !slideInArea, !slideInSidebar, !slideExitHeld else { return }
        slideLater(open: false)
    }

    private func slideLater(open: Bool) {
        guard slideTimer?.open != open else { return }   // a running dwell or hide keeps its start
        slideTimer?.task.cancel()
        let delay = open ? Self.slideOpenDelay : Self.slideHideDelay
        slideTimer = (open, Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.slideTimer = nil
            self.slideTimerFired(open)
        })
    }

    private func slideCancel() {
        slideTimer?.task.cancel()
        slideTimer = nil
    }

    /// The states are checked again when the wait lands: the pointer may have come back, or a menu opened meanwhile.
    private func slideTimerFired(_ open: Bool) {
        guard sidebarMode == .slide else { return }
        if open {
            guard slideInArea, !slideAreaHeld, !slideRevealed else { return }
            slideInSidebar = true   // the area lies inside the sidebar's width; its tracker assumes inside (no enter comes)
            animateSlide { slideRevealed = true }
        } else {
            guard slideRevealed, !slideInArea, !slideInSidebar else { return }
            if slideMenusOpen > 0 { slideExitHeld = true; return }   // #1461: the menu's last close runs it
            animateSlide { slideRevealed = false }
        }
    }

    /// #1461: menus, submenus and popovers the slid sidebar has open now, and an exit that came while one was.
    private(set) var slideMenusOpen = 0
    private(set) var slideExitHeld = false

    /// #1461: a sidebar menu or popover opened (true) or closed (false). The last close runs a held exit (the pointer
    /// left and did not come back), the normal exit path (#1458: the hide follows after its delay).
    func slideMenu(_ open: Bool) {
        slideMenusOpen = max(0, slideMenusOpen + (open ? 1 : -1))
        guard slideMenusOpen == 0, slideExitHeld else { return }
        slideExitHeld = false
        slide(false)
    }

    private func animateSlide(_ change: () -> Void) {
        let still = Self.reduceMotion()
        lastSlideAnimated = !still
        withAnimation(still ? nil : .easeOut(duration: 0.15), change)
        if !slideOpen { keyFocus = .pane }
    }

    /// ⌃⌘S (through `perform`) and the band's show-sidebar glyph: hides or shows the sidebar and saves the choice.
    /// Hidden, the panes take the keys (a hidden sidebar never holds them); shown again, the keys stay where they are.
    /// #1379 Slide: pins the slid-in sidebar open or closed instead (nothing saved; any split gate).
    func toggleSidebar() {
        if sidebarMode == .slide {
            slideAreaHeld = slideOpen && slideInArea   // a chord close holds the area; the opening chord drops it
            slideCancel()   // a dwell already running must not land after the chord
            animateSlide { slidePinned = !slideOpen; slideRevealed = false }
            return
        }
        sidebarHidden.toggle()
        Preferences.agentWindowSidebarHidden = sidebarHidden
        if sidebarHidden { keyFocus = .pane }
    }

    /// 4.2 "Pick Another": focuses the pane and gives the sidebar the keys; starts nothing.
    func pickAnother(_ pane: UUID) {
        keyFocus = .sidebar   // before adopt: the sidebar keeps the keys (adopt's rule asks the pane's input only for .pane)
        if pane != layout.focused, case let .success(l) = layout.focus(pane) { adopt(l) }
        if !sidebarShown { toggleSidebar() }   // #900 B2 step 4: the pick is made in the sidebar, so it shows again
        focusSidebar()
    }

    /// 4.2 "Close Pane": the last pane is refused (7.3), so a one-pane window draws no Close Pane. 7.2: a close moves the
    /// keys to the panes.
    /// #1817 (operator 2026-11-21): a close is saved; the single-pane view's one
    /// pane never closes (close refuses the last pane).
    func closePane(_ pane: UUID) {
        let shown = layout.focused
        if case let .success(l) = layout.close(pane) {
            keyFocus = .pane; adopt(l); autosave(); cancelFormOfClosed(pane, shown: shown); closedToOne()
        }
    }

    /// #1894 (operator 2026-11-23): a close that leaves one pane deletes the layout: the session left is shown on its own (the pick rule over the layout deleteLayout handed over to:
    /// a pane of it that shows the session is focused, else the single-pane view; unlocked, the one pane takes it). The
    /// lone layout is never deleted (.lastLayout): it stays as the one-pane layout, the Layouts section hidden as before.
    private func closedToOne() {
        guard AgentPaneLayout.splitsEnabled, parked == nil, layout.panes.count == 1 else { return }
        let left = layout.panes.first?.target
        guard deleteLayout(layout.id) == nil, let id = Self.rowID(left) else { return }
        if case let .success(l) = layoutMade ? lockedShowing(id) : showing(id), l != layout { adopt(l); autosave() }   // #1895 (R1894 i2): saved at once
    }

    /// #1659: the one rule for every close (⌘W, Close Pane, the pills, a VoiceOver press): the form is drawn in the focused
    /// pane (`shown`, read BEFORE the action), so when that pane closes the form goes with it (Cancel's path, nothing
    /// starts). Another pane's close leaves it.
    private func cancelFormOfClosed(_ pane: UUID, shown: UUID) {
        if newSession != nil, pane == shown { cancelNewSession() }
    }

    /// #900 B2 step 1 (12.1, 7.3, 7.4): a tree key's action on the active layout; the window calls it only for
    /// `PaneKeys.treeAction` (the split gate on). True: it acted, so the window swallows the chord: the layout changed,
    /// or a refused split put its refusal in the pane notice line (R899-2's `paneRefusal`). False (an edge with no
    /// neighbour, an action this step does not route, the window closed): the chord goes on as before #831.
    /// Zoom: frames ignore it (the view still draws the tiling until step 3); shownPanes and follow() honour it (step
    /// 2), so a focus key while zoomed moves the zoom: one pane suspends, one starts (7.4).
    @discardableResult
    func perform(_ a: PaneAction, pane: UUID? = nil) -> Bool {
        guard !closed else { return false }
        // #900 B2 step 6b1 (R900-6a-1): `pane` (a header "⋯" item's) is focused in the result, so a choice writes once.
        let shown = layout.focused
        let base = pane.flatMap { try? layout.focus($0).get() } ?? layout
        let next: Result<PaneLayout, PaneRefusal>
        var closing: UUID?
        switch a {
        case let .split(axis):
            next = splitting(axis, pane: pane)
            // #1700: the single-pane view's split makes a new layout of it (as "+" then a split)
            if parked != nil, case let .success(l) = next { keyFocus = .pane; unpark(l); return true }
        case .closePane:
            // #1817: saved below. #1700: the single-pane view swallows it with no notice (never the window close)
            if parked != nil { return true }
            closing = base.focused
            next = base.close(base.focused)
        case let .focus(d):
            // The tree's tiling in a fixed square: adjacency depends on the ratios only, never on the size or the minimum.
            let square = CGRect(x: 0, y: 0, width: 1000, height: 1000)
            guard case let .tiled(f) = base.frames(in: square, minimum: .zero, splitsEnabled: true),
                  let id = base.neighbour(of: base.focused, direction: d, frames: f) else { return false }
            next = base.focus(id)
        case let .cycle(step):
            next = base.focus(step < 0 ? base.previous : base.next)
        case .zoom:
            next = .success(base.toggleZoom())
        case .toggleSidebar:   // #900 B2 step 4: always acts, so ⌃⌘S is always swallowed (gate on)
            toggleSidebar()
            return true
        default:
            return false
        }
        switch next {
        case let .success(l):
            guard l != layout else { return false }
            if paneRefusal != nil { paneRefusal = nil }
            keyFocus = .pane   // 7.2: every pane focus action, split and close
            // #1895: a split focuses its new empty pane, which takes the next sidebar pick (select's empty-pane rule).
            adopt(l)
            if closing != nil { autosave() }   // #1817: a close is saved
            closing.map { cancelFormOfClosed($0, shown: shown) }
            if closing != nil { closedToOne() }   // #1894
            return true
        case let .failure(r):
            if base != layout { keyFocus = .pane; adopt(base) }   // the menu's pane is focused even when its action is refused
            guard case .split = a else { return false }
            paneRefusal = r
            return true
        }
    }

    /// #900 B2 step 6a: what Split answers for the focused pane, or for `pane` once focused (the header "⋯" of an
    /// unfocused pane focuses it first): perform's own call, so the menu and the key share one cap and one room rule.
    func splitting(_ axis: PaneNode.Axis, pane: UUID? = nil) -> Result<PaneLayout, PaneRefusal> {
        countDryRun()
        // #1826 (operator 2026-11-21): Split is saved (perform); #1700: the single-pane view splits (unpark).
        let l = pane.flatMap { try? layout.focus($0).get() } ?? layout
        // The same minimum paneFrames tiles with, so a split that passes here is drawn tiled.
        return l.split(axis: axis, minimum: paneMinimum, in: CGRect(origin: .zero, size: paneArea.size))
    }

    #if DEBUG
    /// Tests (R900-6b1-3): calls of `showing` and `splitting` (the menus' dry runs), read around one body pass.
    private(set) var dryRuns = 0
    #endif
    private func countDryRun() {
        #if DEBUG
        dryRuns += 1
        #endif
    }

    /// 7.6: the first click on an unfocused pane focuses it; the panes take the keys (7.2).
    /// #1895: Swap Session… chosen for this pane: its title switcher opens its list and clears it (AgentPaneSwitcherButton).
    /// R1895 f1: a focus move drops it (layout's didSet); swapMenu offers none for a pane that draws no switcher.
    @Published var swapRequest: UUID?

    func focusPane(_ pane: UUID) {
        keyFocus = .pane
        if pane != layout.focused, case let .success(l) = layout.focus(pane) { adopt(l) }
    }

    /// 7.2: the sidebar's frame in the root view's content of `size` (top-left origin; AgentWindowRootView.split: the
    /// sidebar sidebarWidth.drawn wide (#1923), a 1 pt line, the pane area). nil while no sidebar is drawn (the island off: one message;
    /// #900 B2 step 4: hidden by ⌃⌘S, so a click where it was is the pane area's).
    func sidebarFrame(in size: CGSize) -> CGRect? {
        hasStore && sidebarShown ? CGRect(x: 0, y: 0, width: sidebarMode == .mini ? Self.miniSidebarWidth : sidebarWidth.drawn,
                                           height: size.height) : nil   // #1379: Slide's overlay is the full width
    }

    /// The pane area's frame in the same content: right of the sidebar and its line, under the band while it is shown
    /// (AgentWindowBand.shown; 9.1: a click on the band is in no pane), else the whole height; nil with no store.
    func paneAreaFrame(in size: CGSize) -> CGRect? {
        let band = AgentWindowBand.shows(self) ? AgentWindowBand.height : 0   // #1538: the view's own rule
        // #900 B2 step 4: hidden, the pane area starts at x = 0; #1379: so does it under Slide's overlay (never shrunk)
        let lead = sidebarShown && sidebarMode != .slide ? sidebarColumnWidth + 1 : 0
        return hasStore ? CGRect(x: lead, y: band, width: max(0, size.width - lead),
                                 height: max(0, size.height - band)) : nil
    }

    /// 7.2 / 7.6: a left mouse-down at `p` in the content of `size` (top-left origin). Outside data: a point or size that
    /// is not finite changes nothing. In the sidebar: the sidebar takes the keys. In a pane frame: the panes do, and an
    /// unfocused pane is focused (`AgentsNSWindow.firstClick`). Elsewhere (the 1 pt line, the band): nothing changes.
    /// True: the click only focused a pane, so the window swallows it with its drags and its up. #1707: a down in the
    /// unfocused pane's header focuses it and passes (false), so the header control under it acts on that click.
    /// #900 B2 step 4b (7.4, N900-f): zoomed, the view draws the zoomed pane over the whole pane area and no other
    /// (AgentPaneArea.drawn), so a down anywhere in the area is that pane's: the panes take the keys and the click
    /// passes (never a hidden pane's tile). Checked after the finiteness guard, so it never reads a non-finite frame.
    func mouseDown(at p: CGPoint, in size: CGSize) -> Bool {
        guard p.x.isFinite, p.y.isFinite, size.width.isFinite, size.height.isFinite else { return false }
        if sidebarFrame(in: size)?.contains(p) == true { keyFocus = .sidebar; return false }
        guard let a = paneAreaFrame(in: size), a.contains(p) else { return false }
        let local = CGPoint(x: p.x - a.minX, y: p.y - a.minY), area = CGRect(origin: .zero, size: a.size)
        let frames = paneFrames(in: area), drawn = AgentPaneArea.drawn(self, in: area)
        if drawn.count < frames.count, let z = drawn.keys.first {
            focusPane(z)   // the focused pane: the layout stays as it is
            return false
        }
        guard frames.values.contains(where: { $0.contains(local) }) else { return false }
        keyFocus = .pane
        guard let id = AgentsNSWindow.firstClick(at: local, frames: frames, focused: layout.focused) else { return false }
        focusPane(id)
        // #1707 (OQ-170 b): in the pane's header (X-ray, "...", the title chip) the same click acts too; the body only focuses.
        return !AgentsNSWindow.inHeader(local, frames[id])
    }

    // MARK: 7.5 Dividers (#900 B2 step 5a; split gate on only)

    /// A divider in a pane area: the split at `path` (0 = first, 1 = second, from the root), its axis, its 1 pt line (the
    /// second side's leading edge, where AgentPaneArea.edge draws it) and the split's own rect.
    struct Divider: Equatable {
        let path: [Int]
        let axis: PaneNode.Axis
        let line: CGRect
        let split: CGRect
        /// R900-5b-q1: the split's identity: the pane ids of its first and of its second side, in tree order.
        let sides: [[UUID]]
        /// The line widened to 6·s across its axis, centred on it, clipped to the split's rect. Frames abut, so it overlaps
        /// both neighbours' edges: inside it the divider wins over the panes (checked before the first-click rule).
        @MainActor var hitArea: CGRect {
            let d = (1 - sz(6)) / 2
            return line.insetBy(dx: axis == .columns ? d : 0, dy: axis == .rows ? d : 0).intersection(split)
        }
    }

    /// 7.5: the dividers in a pane area of `size`, parents before children. None with the gate off, one pane, zoomed,
    /// too small (3.4: the focused pane alone) or a size that is not finite (refused before any use).
    func dividers(in size: CGSize) -> [Divider] {
        // #1826: a divider drag, equalize and nudge are saved, like #1817's close
        guard AgentPaneLayout.splitsEnabled, size.width.isFinite, size.height.isFinite, layout.zoomed == nil
        else { return [] }
        let area = CGRect(origin: .zero, size: size)
        guard case let .tiled(f) = layout.frames(in: area, minimum: paneMinimum, splitsEnabled: true), f.count > 1 else { return [] }
        var out: [Divider] = []
        func walk(_ n: PaneNode, _ r: CGRect, _ path: [Int]) {
            guard case let .split(axis, ratio, a, b) = n else { return }
            let (x, y) = PaneNode.divide(r, axis, ratio)
            out.append(Divider(path: path, axis: axis, line: axis == .columns
                ? CGRect(x: y.minX, y: r.minY, width: 1, height: r.height) : CGRect(x: r.minX, y: y.minY, width: r.width, height: 1),
                               split: r, sides: [a.panes.map(\.id), b.panes.map(\.id)]))
            walk(a, x, path + [0])
            walk(b, y, path + [1])
        }
        walk(layout.tree, area, [])
        return out
    }

    /// 7.5: the divider whose hit area holds `p` (pane-area coordinates, outside data: not finite is nil first); a parent
    /// before its children, so where a nested line meets its parent's the parent's is hit.
    func divider(at p: CGPoint, in size: CGSize) -> Divider? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        return dividers(in: size).first { $0.hitArea.contains(p) }
    }

    /// The divider drag under way: the divider, where it began along its axis, the split's ratio then, the area's size.
    private(set) var dividerDrag: (divider: Divider, start: CGFloat, ratio: Double, size: CGSize)?
    /// True only while dragMoved adopts its own move (the one writer of `layout` that keeps the drag).
    private var dragMoving = false
    /// R900-5a-1: the left button's down began a divider drag: the window's route swallows that button's drags and its
    /// up even after the drag was ended by something else (a key, a close, resign key). Reset by the up and the next down.
    var dividerHeld = false

    /// 7.5: a left mouse-down at `p` in a pane area of `size`: on a divider it begins that divider's drag (true). A
    /// double-click (`clicks` 2 or more) first equalizes that split alone (deep false), saved once by the didSet.
    /// Anywhere else false, nothing changes. A drag whose up never came is ended first.
    func dragBegan(at p: CGPoint, in size: CGSize, clicks: Int = 1) -> Bool {
        if dividerDrag != nil { dragEnded() }
        guard !closed, let d = divider(at: p, in: size) else { return false }
        if clicks >= 2, case let .success(l) = layout.equalize(path: d.path, deep: false), l != layout { adopt(l); autosave() }
        guard case let .split(_, ratio, _, _)? = layout.tree.locate(d.path[...], in: .zero)?.node else { return false }
        dividerDrag = (d, d.axis == .columns ? p.x : p.y, ratio, size)
        for t in allTerminals { t.liveResizeStarted() }   // 7.5: each terminal re-grids at the drag's end only (one setSize)
        return true
    }

    /// 7.5: the drag at `p`: ratio = the ratio at the start + the move along the axis / the split's length (compared
    /// first: at least 1 pt, so never a division by zero; p and the start are finite, so the ratio is), through setRatio
    /// (clamped at the minimum, 3.3), adopted live and NOT saved. An equal ratio (held at the clamp) adopts nothing.
    func dragMoved(to p: CGPoint) {
        guard let g = dividerDrag, p.x.isFinite, p.y.isFinite else { return }
        let length = g.divider.axis == .columns ? g.divider.split.width : g.divider.split.height
        guard length >= 1 else { return }
        let r = g.ratio + Double(((g.divider.axis == .columns ? p.x : p.y) - g.start) / length)
        guard case let .success(l) = layout.setRatio(path: g.divider.path, r, minimum: paneMinimum,
                                                     in: CGRect(origin: .zero, size: g.size)), l != layout else { return }
        dragMoving = true
        defer { dragMoving = false }
        adopt(l)
    }

    /// 7.5 / 8.1: the drag ends (its mouse-up): saved once, and only when the layout differs from the saved one (a drag
    /// back to its start writes nothing); the terminal pushes its grid once.
    func dragEnded() {
        guard dividerDrag != nil else { return }
        dividerDrag = nil
        for t in allTerminals { t.liveResizeEnded() }
        autosave()   // #1826: a drag saves once, at its end
    }

    /// 13: a divider's value: its split's ratio in whole percent, rounded. nil: no split at `path`, or a ratio (outside
    /// data: a saved blob) that is not finite or not in [0, 1], refused before the Int conversion.
    func dividerPercent(_ path: [Int]) -> Int? {
        guard case let .split(_, r, _, _)? = layout.tree.locate(path[...], in: .zero)?.node, r.isFinite, r >= 0, r <= 1
        else { return nil }
        return Int((r * 100).rounded())
    }

    /// 13: the divider's adjustable action: its first side grows (`up`) or shrinks by 5 percent through setRatio (clamped
    /// at the minimum and [0.1, 0.9] as a drag is), adopted only when the layout differs, so saved once by the didSet
    /// (a drag under way is ended first by the willSet). Nothing for a path with no divider: the gate off, zoomed, too
    /// small, one pane or a size that is not finite (dividers(in:) is empty); nothing at the clamp (no save, no publish).
    /// R900-5b-q1: `sides`, the drawn divider's identity (Divider.sides): nothing when the split now at `path` is another
    /// one (a tree change not yet drawn); nil compares none.
    func nudge(_ path: [Int], up: Bool, in size: CGSize, sides: [[UUID]]? = nil) {
        guard dividers(in: size).contains(where: { $0.path == path && (sides == nil || $0.sides == sides) }),
              case let .split(_, r, _, _)? = layout.tree.locate(path[...], in: .zero)?.node,
              case let .success(l) = layout.setRatio(path: path, r + (up ? 0.05 : -0.05), minimum: paneMinimum,
                                                     in: CGRect(origin: .zero, size: size)), l != layout else { return }
        adopt(l)
        autosave()   // #1826
    }

    private(set) var store: AgentIslandStore? { didSet { drawnMemo = nil } }
    private(set) var visible = false
    private(set) var closed = false
    private var subscription: AnyCancellable?
    private(set) var clock: Timer?
    /// QA #626 INFO-4: the first row is picked once, on the window's first fill; a selected
    /// session that ends leaves nothing selected (the hint), never another conversation.
    private var filled = false
    /// #798: the input box, interrupt and prompt answers for the selected live session.
    let interaction = AgentWindowInteraction()
    /// #847 D2.3, #1471 b: a first message the island could not send, shown over its pane's terminal until
    /// Send or Dismiss (both drop the island's record) or the session ends. Never typed into the terminal by itself.
    struct UnsentFirst: Equatable { let key: AgentSessionKey; let text: String }
    @Published private(set) var unsentFirst: UnsentFirst?
    /// #828: the folded sidebar sections (titles), per Mac across window close and relaunch.
    /// Folding hides rows only: the selection, its transcript and Return stay as they were.
    @Published private(set) var collapsed = Preferences.agentWindowCollapsedSections {
        didSet { if collapsed != oldValue { Preferences.agentWindowCollapsedSections = collapsed } }
    }
    /// #822: the window's terminal with the split gate off (one pane); attached only by `follow`.
    let windowTerminal = AgentTerminalController()
    /// #822: the focused pane's terminal. #1477 (spec 15 C, no singleton): with the split gate on every pane runtime has its
    /// own, and this is the focused pane's, so keys, find, font and focus act on that pane only. Gate off: the window's.
    var terminal: AgentTerminalController {
        guard AgentPaneLayout.splitsEnabled, let r = focusedRuntime else { return windowTerminal }
        return paneTerminal(r)
    }
    /// #1477: makes a pane's terminal (rows hand in a fake spawn and screen).
    var makeTerminal: () -> AgentTerminalController = { AgentTerminalController() }
    /// #1477 (11.2): the delay of an unfocused pane's attach rest (rows run it by hand).
    var paneAfter: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
    }
    /// 11.2: "visible, shown, unfocused: attached after the 250 ms rest".
    static let attachRest: TimeInterval = 0.25
    /// #1477: the session each unfocused pane waits out its rest for (a pending rest is never restarted).
    private var restPending: [UUID: AgentSessionKey] = [:]
    /// #1477 (11.3): the conservative branch of the budget gate (the 6-surface harness needs a real dch, not run): at most
    /// 4 ATTACHED local terminal clients per window, the focused pane's always one of them.
    static let attachCap = 4
    /// #1477 (11.3, QA r1449 i2): shown unfocused Terminal panes left detached (over the cap, or the same session as a
    /// pane before them): their last frame and Connect, which focuses the pane (and so attaches it).
    @Published private(set) var connectPanes: Set<UUID> = []
    /// #1477 (11.3): when each pane was last focused (a counter): the least recently focused go over the cap first.
    private var focusedAt: [UUID: Int] = [:]
    private var focusTick = 0

    /// #1477: pane `r`'s own terminal, wired like the window's on first need.
    func paneTerminal(_ r: AgentPaneRuntime) -> AgentTerminalController {
        if let t = r.terminal { return t }
        let t = makeTerminal()
        wire(t)
        t.paneFocused = { [weak self, weak r] in r.map { self?.layout.focused == $0.pane } ?? false }
        r.terminal = t
        return t
    }

    /// Every terminal of this window: the window's and each pane's made so far.
    private var allTerminals: [AgentTerminalController] { [windowTerminal] + runtimes.values.compactMap(\.terminal) }

    /// #1477 (spec 15 C, 4.4): an Ended pane's terminal that still holds its last frame (gate on), drawn under "Ended".
    func keptFrame(_ pane: UUID) -> AgentTerminalController? {
        guard AgentPaneLayout.splitsEnabled, let r = runtimes[pane], r.ended != nil, let t = r.terminal, t.screen != nil
        else { return nil }
        return t
    }

    // Seams.
    var now: () -> TimeInterval = { Date().timeIntervalSince1970 }
    /// A pane runtime made after init (a new pane, a layout switch); tests give its transcript their seams. Called on the
    /// main actor, from the layout's didSet.
    var onNewRuntime: (AgentPaneRuntime) -> Void = { _ in }
    /// Open in terminal: the island's row click (focus the attached terminal, else
    /// open one, else copy the attach command).
    var openSession: (AgentSession) -> Void = { AgentIslandController.shared.jump($0, fromWindow: true) }
    /// The island controller the History verbs go to (tests: one with a fake runner).
    var island: () -> AgentIslandController = { .shared }
    /// A History row's Resume: the island's.
    lazy var resume: (DchHistoryRecord) -> Void = { [weak self] r in
        guard let self else { return }
        resumeStarted = island().resume(r, failed: { [weak self] in self?.resumeFailed(r) })
    }
    /// #1935: whether the last Resume verb started a job (false: a busy row or a closed gate); act() sets it true first, the
    /// default seams below set it from the island. A test's seam that runs nothing sets it false.
    var resumeStarted = true
    /// #1935: the resume of record `r` ended in failure: its pending follow goes (only that record's; a later resume's stays).
    func resumeFailed(_ r: DchHistoryRecord) { if pendingResume?.record == r.id { pendingResume = nil } }
    /// #829 G6-G8: Resume (no message), Pin/Unpin and Remove from History: the island's.
    lazy var resumeNoMessage: (DchHistoryRecord) -> Void = { [weak self] r in
        guard let self else { return }
        resumeStarted = island().resume(r, noMessage: true, failed: { [weak self] in self?.resumeFailed(r) })
    }
    lazy var pinRecord: (DchHistoryRecord) -> Void = { [weak self] in self?.island().pin($0) }
    lazy var removeRecord: (DchHistoryRecord) -> Void = { [weak self] in self?.island().remove($0) }
    /// #897 (G9): "Agent Island Settings...": Settings on Agent Island's pane, through the extension host's one opener.
    var openIslandSettings: () -> Void = {
        LiveExtensionHostServices.shared.openSettings(extensionID: AgentWindowControls.islandExtensionID,
                                                      sectionID: AgentWindowControls.islandSectionID, anchor: nil)
    }

    /// #897 (G9): a sidebar "..." item: the island's own call on `island()`.
    func runSidebar(_ v: AgentSidebarVerb) {
        // R897-q1: Always allow ON asks first (the strip); nothing is written before its Turn on. OFF stays immediate.
        if v == .autoAllow, !Preferences.agentIslandAutoAllow { askingAlwaysAllow = true; return }
        if v == .newGroup { newGroup = NewGroupAsk(); return }   // #2062: the name field first
        AgentWindowControls.runSidebar(v, island: island(), openSettings: openIslandSettings)
    }

    /// #2060: a group header's "\u{22EF}" item: the island's ask scoped to the group's rows.
    func runGroup(_ v: AgentSidebarVerb, name: String, rows: [AgentSession]) {
        AgentWindowControls.runGroup(v, name: name, rows: rows, island: island())
    }

    /// #2062: a row's Move to group item: the island's --group-set (nil: --auto), or New group… for this session.
    func runMove(_ v: AgentSidebarVerb, _ s: AgentSession) {
        switch v {
        case .moveToGroup(let g): setGroup(s, g, false)
        case .newGroup: newGroup = NewGroupAsk(session: s)
        default: break
        }
    }

    /// #2062: New group…'s name field in the sidebar; `session`, the row whose menu asked (moved into the group once added).
    struct NewGroupAsk: Equatable {
        var session: AgentSession? = nil
        var name = ""
        var refused: String? = nil
    }
    @Published var newGroup: NewGroupAsk?
    /// #2062 r3: who had the keys when the name field took them (the terminal, usually); its close gives them back.
    private(set) weak var newGroupKeys: NSResponder?
    /// The field took the keys from `prior`. A field editor stands for its field, read now: the window's one editor is
    /// the name field's next.
    func newGroupTookKeys(_ prior: NSResponder?) {
        if let t = prior as? NSTextView, t.isFieldEditor { newGroupKeys = t.delegate as? NSView } else { newGroupKeys = prior }
    }
    /// #2062: a name field is up (a session's or a layout's rename, New group…): the window's key chords stand down for it.
    var typingName: Bool { renaming != nil || layoutRenaming != nil || newGroup != nil }
    /// #2062 seams: the island's --group-set (`configFirst`: dch's config is written before it runs, for a group just
    /// added); the stored list and its save as Settings saves it (the island regroups, then writes dch's group lines).
    lazy var setGroup: (AgentSession, String?, _ configFirst: Bool) -> Void = { [weak self] s, g, first in
        self?.island().setGroup(s, group: g, configFirst: first)
    }
    var storedGroups: () -> [SessionGroup] = { Preferences.agentIslandSessionGroups }
    lazy var saveGroups: ([SessionGroup]) -> Void = { [weak self] list in
        Preferences.editSessionGroups(list)
        self?.island().rowDetailsChanged()
    }

    /// #2062: the field's Create (or Return) and Cancel. A refused name stays in the field with its reason; an added
    /// group is stored with an empty pattern and, from a row's menu, that row is moved into it (one --group-set).
    func answerNewGroup(_ create: Bool) {
        guard let ask = newGroup else { return }
        guard create else { return endNewGroup() }
        switch AgentWindowControls.addingGroup(ask.name, to: storedGroups()) {
        case .failure(let f): newGroup?.refused = f.reason
        case .success(let list):
            endNewGroup()
            saveGroups(list)
            // #2062: the save's dch config write is debounced; this move writes it first, or dch has no such group yet.
            if let s = ask.session, let g = list.last { setGroup(s, g.name, true) }
        }
    }

    /// #2062 r3: the field goes; the keys go back where they were (the window itself: no view has them).
    private func endNewGroup() {
        newGroup = nil
        let back = newGroupKeys
        newGroupKeys = nil
        if let v = back as? NSView, let w = v.window { w.makeFirstResponder(v) } else if let w = back as? NSWindow { w.makeFirstResponder(nil) }
    }

    /// R897-q1: the Always allow question is up in the sidebar (the store's question type cannot carry it: window state).
    @Published private(set) var askingAlwaysAllow = false

    /// R897-q1: the strip's answer. Turn on writes the setting as Settings does; Cancel (and Esc) writes nothing.
    func answerAlwaysAllow(_ yes: Bool) {
        guard askingAlwaysAllow else { return }
        askingAlwaysAllow = false
        if yes { AgentIslandPane.autoAllowToggled(true, island()) }
    }

    /// #897 (G9): the sidebar strip's answer to the store's question up now, through the island's confirm call.
    func answerStoreQuestion(_ yes: Bool) {
        guard let store, let q = AgentWindowControls.storeQuestion(store) else { return }
        AgentWindowControls.answer(q.kind, yes, island: island())
    }
    /// Told when the window shows or hides, so the island keeps the store current
    /// (it holds activity-only lists back while nothing shows them).
    var onVisible: (Bool) -> Void = { AgentIslandController.shared.windowWatching = $0 }
    /// #2068: told once, when the focused pane's first session lands (settle); the window applies that session's X-ray
    /// drawer state then (the area's onChange sees only later changes).
    var firstShown: (() -> Void)?
    /// The age clock: while visible the rows are rebuilt at least this often, so a row's age is never more than
    /// this behind (#1114: whole minutes, so at most one minute low, for at most this long past the minute).
    var ageInterval: TimeInterval = 30
    /// #836 (a): the remote list's call, the island's own bounded runner (DchCommand.runIsland, its 4 s bound and kill);
    /// none under XCTest, so an unstubbed test never runs dch. Never the server's list (d).
    var remoteRun: @Sendable (_ args: [String], _ env: [String: String]) -> Data? = { args, env in
        NSClassFromString("XCTestCase") == nil ? DchCommand.runIsland(args: args, env: env) : nil
    }
    /// Where that call runs: off main in the app; under XCTest inline, so a fake's answer is in at once.
    var remoteOffMain = NSClassFromString("XCTestCase") == nil
    /// Monotonic seconds for the remote call's spacing (tests set it).
    var remoteClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// dch's own remote probe tick (README "Following the list": every 2 s): no more often than this.
    static let remoteEvery: TimeInterval = 2
    /// #1634: the spacing grows (doubling) while the remote answers change nothing, up to this; any change, a show or a
    /// remote action starts it over at `remoteEvery`. Never past remoteHistoryEvery, so History keeps its own spacing.
    static let remoteIdleMax: TimeInterval = 10
    /// #1634: the spacing now, `remoteEvery` up to `remoteIdleMax`.
    private(set) var remoteGap: TimeInterval = remoteEvery
    /// #836: the last good `--ls-json --remote` rows; a call that failed or timed out keeps them.
    private(set) var remoteSessions: [AgentSidebar.Remote] = []
    private var remoteInFlight = false
    private var remoteAt: TimeInterval?
    /// Counts remote list calls started (tests).
    private(set) var remoteCalls = 0
    /// #1324 (a): the remote History call (`dch --history --json --remote`), the same bounded runner, its own seam so a
    /// fake list answers only the list; none under XCTest. It rides in the list's job (one in flight with it).
    var remoteHistoryRun: @Sendable (_ args: [String], _ env: [String: String]) -> Data? = { args, env in
        NSClassFromString("XCTestCase") == nil ? DchCommand.runIsland(args: args, env: env) : nil
    }
    /// dch's own picker reads remote history every 10 s, not every 2 s: each fetch runs a dch on every host and logs
    /// there (README.md:3289-3291 at v1.74.0).
    static let remoteHistoryEvery: TimeInterval = 10
    static let remoteHistoryArgs = ["--history", "--json", "--remote"]
    /// #1324: the last good remote History records; a call that failed or timed out keeps them.
    private(set) var remoteHistory: [AgentSidebar.RemoteRecord] = []
    private var remoteHistoryAt: TimeInterval?
    /// #1555: the client dch whose follow stream replaces the per-refresh list (README "Following the list"; dch 1.62.0).
    static let remoteFollowDch = [1, 62, 0]
    static let remoteFollowArgs = ["--ls-json", "--remote", "--follow"]
    /// #1555: the client's version (AgentTerminal's probe, the binary runIsland runs); nil under XCTest: the per-refresh call.
    var remoteFollowVersion: @Sendable () -> [Int]? = {
        NSClassFromString("XCTestCase") == nil ? DchCommand.probedVersion(DchCommand.dchPath) : nil
    }
    /// #1555: starts the follow child (nil: it did not start, retried after the backoff); none under XCTest.
    var remoteFollowStart: (_ args: [String], _ env: [String: String],
                            _ onData: @escaping @MainActor @Sendable (Data) -> Void,
                            _ onExit: @escaping @MainActor @Sendable (Int32) -> Void) -> AgentRemoteFollowHandle? = {
        NSClassFromString("XCTestCase") == nil
            ? AgentRemoteFollowChild.start(path: DchCommand.dchPath, args: $0, env: $1, onData: $2, onExit: $3) : nil
    }
    /// #1555: the follow child's restart delay, AgentTerminal's own `after` form.
    var remoteAfter: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
    }
    /// #1555: nil until this showing's probe answered; true: the follow child lists, false: the per-refresh call.
    private(set) var remoteFollows: Bool?
    private var followProbing = false
    private var follower: AgentRemoteFollowHandle?
    private var followWaiting = false
    private var followLines = AgentRemoteFollowLines()
    /// Bumped by each start and by a stop, so a late line, exit, probe or restart of an earlier child is dropped.
    private var followGen = 0
    private var followRestarts = 0
    private var followStartedAt: TimeInterval = 0
    /// Counts follow children started (tests).
    private(set) var remoteFollowStarts = 0
    /// #1324 (b): dch's DCH_AGENT_TIMEOUT_MS (600 s) plus margin, the #836 Round 2 bound for --revive; an idle bound
    /// (DchActionRunner: each NDJSON line restarts it).
    nonisolated static let remoteReviveBound: TimeInterval = 660
    /// #1324 (b): a remote record's Resume, a dch call of its own on the island's shared action runner (never the
    /// list's call or stream), keyed by the record's id under "@" + host, so it never meets a local job; false: the key
    /// is busy and nothing ran. None under XCTest. `done` runs on the runner's thread.
    var remoteVerb: (_ key: AgentSessionKey, _ dch: String, _ args: [String],
                     _ done: @escaping @Sendable (DchActionResult) -> Void) -> Bool = { key, dch, args, done in
        NSClassFromString("XCTestCase") == nil
            && DchActionRunner.shared.start(key, path: dch, args: args, bound: AgentWindowModel.remoteReviveBound,
                                            env: { AgentIsland.listEnv(dir: DchCommand.defaultSocketDir) }, done: done)
    }
    /// #1324 (c): a remote Resume's row text (the island's words), by record id: the island keeps only its own records'.
    @Published private(set) var remoteResumeText: [AgentSessionKey: String] = [:]
    /// #829: Restart agent, Stop and Kill: the island's controller methods (its gates, runner
    /// keys, busy refusal and row texts). True: the job started.
    var restartSession: (AgentSession) -> Bool = { AgentIslandController.shared.restart($0, sayBusy: true) }
    var stopSession: (AgentSession) -> Bool = { AgentIslandController.shared.stop($0, sayBusy: true) }
    var killSession: (AgentSession) -> Bool = { AgentIslandController.shared.kill($0) }
    /// #829 G4: Rename's `dch -m`, on the island's controller (its runner key and the row's dir env).
    var renameSession: (AgentSession, String) -> Bool = { AgentIslandController.shared.rename($0, alias: $1) }
    /// G4: the live session whose header title is a text field now. Dropped by a selection change,
    /// an ask, Return, Esc and the field losing focus. While set, the window's shortcuts stand down.
    /// #853 (QA #693 INFO-1): the edit itself, its typed text included, so a field the header builds
    /// anew (a ViewThatFits variant swap) carries on with it.
    @Published private(set) var renameEdit: AgentRenameEdit?
    var renaming: AgentSessionKey? { renameEdit?.key }
    /// R901-s3-b (tests): the session rename field's state set without ask()'s select: no session verb, no attach.
    func openRenameField(_ edit: AgentRenameEdit) { renameEdit = edit }
    /// #901 B3 step 4b (8.1): the Layouts row whose name is an inline field now; nil: none. Set only with the gate on.
    @Published private(set) var layoutRenaming: UUID?
    /// #829 (R5): the question the confirm strip shows; dropped by a selection change.
    @Published private(set) var confirming: AgentWindowConfirm?
    /// QA #665 INFO-6: an answer a gate refused since the question; dropped by a selection change or the next ask.
    @Published var refusal: AgentWindowRefusal?   // #1935: internal set (a test seam leaves one)
    /// #831 B1 (4.4 M1, replaces #829 G2's hold): the focused pane's session ended while its transcript ran: the pane
    /// keeps that session's last live row and its blocks (the transcript suspended), display only, until resolve
    /// first gives its own record (one swap), a new session takes the name, or the pane is retargeted or closed.
    /// B1 step 2: the focused pane's runtime's (each pane keeps its own).
    var ended: (target: PaneTarget, row: AgentSidebar.Row)? { focusedRuntime?.ended }
    /// The focused pane's content as of the last resolve.
    var content: PaneContent? { focusedRuntime?.content }
    /// The values of the publish being handled: the store's @Published still hold the old ones inside the sink.
    private var publishing: (sessions: [AgentSession], history: [DchHistoryRecord])?
    /// dch writes a record each minute: a Stop or Kill's record has ended by then, with slack.
    static let recordSlack: TimeInterval = AgentPaneLayout.recordSlack
    /// #829 G8, #1929 (operator 2026-11-24): a record the window removed (its id): once its row is gone, every pane that
    /// showed it (`removingPanes`) closes, or goes empty when it is the only pane; never another record. A manual pick drops it.
    private(set) var removing: AgentSessionKey?
    /// #1929: the panes that showed `removing` when it was confirmed (a `.session` pane on its own record, 4.5, too);
    /// only a pane still holding the same target closes.
    private var removingPanes: [Pane] = []
    /// Counts sidebar rebuilds (tests: nothing rebuilds after close).
    private(set) var refreshes = 0
    /// #1634: counts full `AgentSidebar.sections` builds (an activity-only list re-ages the rows instead).
    private(set) var sectionBuilds = 0
    /// #1634: what the last refresh read, the sessions apart (only their activity may move without a build).
    private struct SidebarInputs: Equatable {
        let history: [DchHistoryRecord], sort: AgentIslandSort, groups: [SessionGroup], details: AgentIslandRowDetails
        let actions: [AgentSessionKey: String], remote: [AgentSidebar.Remote], remoteHistory: [AgentSidebar.RemoteRecord]
    }
    private var built: (sessions: [AgentSession], inputs: SidebarInputs)?

    private var askSubscription: AnyCancellable?
    private var planSubscription: AnyCancellable?
    /// 5.2: what the ask and plan sinks are bound to: the focused pane, its model, its resolved row.
    private struct Bound: Equatable {
        let pane: UUID
        let row: AgentSidebar.RowID?
        let ended: Bool
    }
    private var bound: Bound?
    /// R1193-6: the bound model itself, compared with ===: a switch frees the old models before it makes the new
    /// ones, so a new model can take a freed one's address (an ObjectIdentifier would compare equal).
    private weak var boundModel: AgentTranscriptModel?

    init(lastLive home: AgentLastLiveHome = AgentLastLiveHome(), layouts d: UserDefaults? = nil) {
        lastLiveHome = home
        layoutDefaults = d
        // 8.1: the window loads the store when it opens, never at app launch. Nothing is written here: a repaired or
        // multi-pane blob (15.0) stays as stored until a change. R1193-3: sights of panes in no stored layout go; an
        // inactive layout's panes keep theirs (only temporarily absent).
        if let d {
            let s = Preferences.agentWindowLayouts(in: d)
            layouts = s
            lastLiveHome.map = AgentPaneLayout.pruned(home.map, keeping: s)
            if let l = s.activeLayout { layout = l }
        }
        for p in layout.panes { runtimes[p.id] = AgentPaneRuntime(pane: p.id) }
        if !sidebarShown { keyFocus = .pane }   // #900 B2 step 4: made hidden (the saved choice), the panes take the keys
        wire(windowTerminal)
        // #831 B1 (4.3): every interaction action re-resolves the focused pane (main actor: called from its actions).
        interaction.resolveFocused = { [weak self] in self?.focusedLive }
        rebind()
    }

    /// 5.2 (R6.2): the ask and plan sinks follow the focused pane's transcript model: re-subscribed on a change of
    /// focus, of that pane's model, or of its resolved content, so another pane's question never reaches the input.
    /// Subscribing delivers the model's current values at once (step 2 of 5.2). Both sinks run on the main actor:
    /// `pendingAsk` / `pendingPlan` are set by the @MainActor transcript model, and Published sends on the setter's thread.
    private func rebind() {
        let f = closed ? nil : focusedRuntime
        let now = f.map { Bound(pane: $0.pane, row: Self.resolvedRow($0.content), ended: $0.ended != nil) }
        guard now != bound || f?.transcript !== boundModel else { return }
        bound = now
        boundModel = f?.transcript
        // #798: the transcript's pending AskUserQuestion is what a question form is checked against.
        askSubscription = f?.transcript.$pendingAsk.sink { [weak self] ask in
            MainActor.assumeIsolated { self?.interaction.ask = ask }
        }
        // #802: and the pending ExitPlanMode is what a plan approval is checked against.
        planSubscription = f?.transcript.$pendingPlan.sink { [weak self] plan in
            MainActor.assumeIsolated { self?.interaction.plan = self?.withConfigDir(plan) }
        }
    }

    /// #1092: a plan kept in a file gets the focused live session's "config_dir" from dch's own live record (the
    /// controller's readLiveRecords seam, none under XCTest), never from the transcript or the screen. No record, no
    /// controller or "": the default <home>/.claude/plans. Read only while a plan file is pending (a few lstats).
    private func withConfigDir(_ p: AgentPlanInput?) -> AgentPlanInput? {
        guard var p, p.plan == nil, let s = focusedLive, let c = interaction.controller else { return p }
        p.configDir = c.readLiveRecords([s]).first { $0.key == s.key }?.agent?.configDir ?? ""
        return p
    }

    /// 11.2: a runtime per pane of the active layout. A layout switch frees every runtime of the old layout (stopped
    /// before any new one starts; pane ids are unique per layout only, so none is reused across layouts); within a
    /// layout a closed pane's runtime is stopped and freed, a new pane gets a fresh one.
    private func syncRuntimes(switched: Bool) {
        guard !closed else { return }
        let ids = Set(layout.order)
        for (id, r) in runtimes where switched || !ids.contains(id) {
            r.transcript.stop()
            r.terminal?.attach(nil)   // 11.2: closing a pane terminates its client; the dch session is untouched
            restPending[id] = nil
            focusedAt[id] = nil
            runtimes[id] = nil
        }
        for id in layout.order where runtimes[id] == nil {
            let r = AgentPaneRuntime(pane: id)
            runtimes[id] = r
            onNewRuntime(r)
        }
    }

    /// The window model's answers a terminal asks for (the window's and, #1477, each pane's).
    private func wire(_ terminal: AgentTerminalController) {
        terminal.keptPeers = { [weak self] in self?.allTerminals ?? [] }   // #1790: one kept cap per window
        terminal.isLive = { [weak self] key in self?.store?.sessions.contains { $0.key == key } ?? false }
        // OQ-66: an OSC 52 write needs the session to be the focused pane's, live now (4.3: resolved at the write).
        terminal.isSelected = { [weak self] key in self?.focusedLive?.key == key }
        // #1480: a relative file link resolves against the live session's folder (a remote key is in no store row).
        terminal.cwd = { [weak self] key in self?.store?.sessions.first { $0.key == key }?.cwd }
        // #1953: the command pill's Run goes the composer's way, on the pane's own session (its live row, any pane)
        terminal.runOff = { [weak self] key in
            guard let self else { return AgentWindowText.notRunning }
            return interaction.runOff(liveSession(key))
        }
        terminal.run = { [weak self] key, command, tell in
            guard let self else { return }
            interaction.run(command, session: liveSession(key), tell: tell)
        }
    }

    /// #1953: a pane's session by key, live rows only (focusedLive's rule: listed in the store now, the window open).
    func liveSession(_ key: AgentSessionKey?) -> AgentSession? {
        guard !closed, let key else { return nil }
        return store?.sessions.first { $0.key == key }
    }

    /// #896: each terminal's session pty size and clients from this list (the Fit here chip); a remote key has no row.
    private func feedPty(_ sessions: [AgentSession]) {
        for t in allTerminals {
            let p = t.key.flatMap { k in sessions.first { $0.key == k }?.pty }
            if t.sessionPty != p { t.sessionPty = p }
        }
    }

    /// The window's active layout replaced: a layout switch, or a focus or tree change (saved, 8.1). Only tests call it
    /// before B2/B3 route verbs, with multi-pane layouts built under the split gate (15.0).
    func adopt(_ l: PaneLayout) {
        guard !closed else { return }
        let moved = l.focused != layout.focused
        // #900 B2 step 6b2d (3.1 :224): a focus change or another set of panes drops the pane refusal. Gate on only, and a
        // write only when one is set: a gate-off person never sees a publish from here.
        if AgentPaneLayout.splitsEnabled, paneRefusal != nil, moved || l.order != layout.order { paneRefusal = nil }
        layout = l
        follow()
        // #900 B2 step 6b2b (7.2, R1196-1): the keys follow the focused pane: every pane focus action (a click, the pane
        // keys and menu, close pane) sets keyFocus .pane first. After follow(): the terminal's attach drops older asks.
        if moved, AgentPaneLayout.splitsEnabled, keyFocus == .pane { focusSelection() }
    }

    /// 8.1 Delete (B3 routes it): refused on the last layout, or with no store. R899-3: the deleted layout's sights go
    /// (the other layouts keep theirs); a deleted active layout hands over to the MRU's next, which is adopted.
    @discardableResult
    func deleteLayout(_ id: UUID) -> PaneRefusal? {
        dragEnded()   // R900-5a-1: before the store is read and replaced, so the drag's save cannot bring a deleted layout back
        guard !closed, let s = layouts else { return .noSuchLayout }
        switch s.deleting(id) {
        case let .failure(r):
            return r
        case let .success(out):
            autosave(out)
            if let r = layoutRenaming, !out.layouts.contains(where: { $0.id == r }) { layoutRenaming = nil }   // R901-s4b-q2
            lastLive = AgentPaneLayout.pruned(lastLive, keeping: out)
            if let next = out.activeLayout, next.id != (parked ?? layout).id { parked = nil; adopt(next) }
            return nil
        }
    }

    /// #901 B3 step 1, 8.1 New (B3 step 4 draws it): one empty pane, name nil (automatic), appended and made active.
    /// Refused as a value, nothing made or written: with the split gate off (.layoutsOff), at 9 layouts (.layoutCap,
    /// N1217-b: never made and dropped later), with no store loaded or the window closed (.noSuchLayout).
    @discardableResult
    func newLayout() -> PaneRefusal? { addLayout { _ in .single() } }

    /// 8.1 Duplicate: a copy of `id` with fresh layout and pane ids (`duplicated`), named by `duplicateName`, appended and
    /// made active. Refused as `newLayout`, and .noSuchLayout for an id the store does not hold.
    @discardableResult
    func duplicateLayout(_ id: UUID) -> PaneRefusal? {
        addLayout { s in s.layouts.first { $0.id == id }.map { $0.duplicated(name: s.duplicateName(of: $0.name)) } }
    }

    /// #1700: the single-pane view is not a layout, so a change to its panes (`l`) is saved as a new
    /// layout (addLayout: the view's layout left, the parked one stays saved); at 9 layouts the notice says so.
    /// #1722: false when no layout was made (the cap, the notice set): the caller's after-success steps do not run.
    @discardableResult
    private func unpark(_ l: PaneLayout) -> Bool {
        guard let r = addLayout({ _ in l }) else { return true }
        paneRefusal = r
        return false
    }

    /// New and Duplicate: the whole store is written once (explicitly, so a layout made while the island is off is saved
    /// and the re-adopt in bind(store) keeps it), then the new layout is adopted (a switch: the old runtimes stop before
    /// the new pane's starts, 11.2); adopt's own autosave finds the store equal and writes nothing. Main actor; `make`
    /// runs synchronously here.
    private func addLayout(_ make: (PaneLayoutStore) -> PaneLayout?) -> PaneRefusal? {
        guard AgentPaneLayout.splitsEnabled else { return .layoutsOff }
        dragEnded()   // R900-5a-1: the drag's save lands before the store is read and replaced
        guard !closed, let s = layouts, let l = make(s) else { return .noSuchLayout }
        switch s.adding(l).flatMap({ $0.activate(l.id) }) {
        case let .failure(r):
            return r
        case let .success(out):
            autosave(out)
            parked = nil
            adopt(l)   // #1895: "+" makes one empty pane, focused: it takes the next pick

            return nil
        }
    }

    /// 8.1 Rename: the name cleaned and bounded (`PaneLayoutStore.cleanName`); empty returns to automatic. One write when
    /// the cleaned name differs, none when it does not. The active layout keeps its panes in memory (only the name
    /// changes there), so a rename while the island is off never brings back what bind(nil) emptied.
    @discardableResult
    func renameLayout(_ id: UUID, to raw: String?) -> PaneRefusal? {
        guard AgentPaneLayout.splitsEnabled else { return .layoutsOff }
        dragEnded()
        guard !closed, var s = layouts, let i = s.layouts.firstIndex(where: { $0.id == id }) else { return .noSuchLayout }
        let name = PaneLayoutStore.cleanName(raw)
        s.layouts[i].name = name
        autosave(s)
        if id == layout.id {
            var l = layout
            l.name = name
            adopt(l)
        } else if id == parked?.id {
            parked?.name = name   // #1538: the parked layout comes back under its new name
        }
        return nil
    }

    /// #901 B3 step 4b (8.1): a Layouts row's Rename opens its inline field. Gate off, or an id the store does not hold:
    /// nothing opens. Main actor (a menu entry's run).
    func beginLayoutRename(_ id: UUID) {
        guard AgentPaneLayout.splitsEnabled, layouts?.layouts.contains(where: { $0.id == id }) == true else { return }
        layoutRenaming = id
    }

    /// The inline field's end, once: `text` nil (Escape, the focus left) writes nothing; Return renames through
    /// renameLayout (the D1 cleaning there, one write, none when unchanged). Another row's late end changes nothing.
    func endLayoutRename(_ id: UUID, _ text: String?) {
        guard layoutRenaming == id else { return }
        layoutRenaming = nil
        if let text { renameLayout(id, to: text) }
    }

    /// #901 B3 step 2 (8.1, 11.2): a switch to layout `id` (step 3 routes the keys, step 4 the rows). Refused as a value
    /// before anything is read or written with the split gate off (.layoutsOff); .noSuchLayout with no store loaded, the
    /// window closed or an id the store does not hold. The active layout: nothing changes, nothing is written. Else the
    /// store from `activate` (the MRU updated) is written once, explicitly, so a switch while the island is off is saved
    /// and bind(store)'s re-adopt keeps it; then the saved layout is adopted with its focus and zoom: syncRuntimes stops
    /// every old runtime before a new one is made, follow() starts the focused pane first; adopt's autosave finds the
    /// store equal. Only the window's pane runtimes: no session is started, resumed, revived or attached (8.1 :619-621).
    /// #901 B3 step 6 (⌘J, 7.4): `pane` of that layout focused in the same write and adopt; zoomed, the zoom moves to it.
    @discardableResult
    func switchLayout(_ id: UUID, focus pane: UUID? = nil) -> PaneRefusal? {
        guard AgentPaneLayout.splitsEnabled else { return .layoutsOff }
        guard !closed, layouts != nil else { return .noSuchLayout }
        // #1538: back from the single-pane view: the layout as it was left (its focus kept), `pane` focused if given;
        // nothing is written (the store still holds it as active).
        if let p = parked, p.id == id {
            parked = nil
            adopt(pane.flatMap { try? p.focus($0).get() } ?? p)
            return nil
        }
        guard id != layout.id else { return nil }
        dragEnded()   // R900-5a-1: the drag's save lands before the store is read
        guard let s = layouts, case let .success(out) = s.activate(id), let saved = out.activeLayout else { return .noSuchLayout }
        let l = pane.flatMap { try? saved.focus($0).get() } ?? saved
        autosave(l == saved ? out : out.storing(l) ?? out)
        parked = nil
        adopt(l)
        return nil
    }

    /// #901 B3 step 6 (section 10 :754-757, 7.1, 7.4): ⌘J. The Needs you rows (the sidebar's order: blocked before done,
    /// newest first) after the focused pane's session, wrapping, the focused one left out; the first blocked one, else
    /// the first done one. Shown in a pane of the active layout: that pane is focused. Else shown in a stored layout (the
    /// first in the stored order, the ⌃N numbers): switchLayout's own path, that pane focused. Else into the focused pane
    /// (7.1 rule 2: a row's click). Zoomed, the zoom moves with the focus (PaneLayout.focus). False, nothing read: the
    /// gate off or the window closed; false, nothing changed: no other session needs you. Never a session verb: only the
    /// window's pane runtimes stop and start. Main actor (the window's key route).
    /// R901-s6-q1: a refused stored-layout switch moves no keys and falls through to the focused pane (rule 2).
    /// #1895 (supervisor ruling, round 3): rule 2 is a pick like a sidebar click, so on a made layout (layoutMade) it follows
    /// rule 1: a session in none of its panes opens the single-pane view (the layout parked, nothing saved); an empty
    /// focused pane takes it (select's empty-pane rule).
    /// `switching` (tests): the switch, nil = switchLayout(_:focus:); no refusal is reachable through the model's own store.
    /// #1862 n180: under keepingKeys (an agent's jump) the fall-through into the focused pane is refused (false, nothing
    /// changed): its retarget swaps the pane's terminal view and AgentTerminalHostSlot.hold hands the new one the keys.
    @discardableResult
    func nextNeedsYou(switching: ((UUID, UUID) -> PaneRefusal?)? = nil) -> Bool {
        guard AgentPaneLayout.splitsEnabled, !closed, let next = nextNeedingYou() else { return false }
        let t = target(next)
        func shown(_ l: PaneLayout) -> UUID? { l.panes.first { $0.target == t }?.id }   // a session, never a History pane
        if let p = shown(layout) {
            focusPane(p)
        } else if let other = layouts?.layouts.first(where: { $0.id != layout.id && shown($0) != nil }), let p = shown(other),
                  (switching ?? { self.switchLayout($0, focus: $1) })(other.id, p) == nil {
            // The keys move only once switched; adopt's own focusSelection ran only if they were the pane's already.
            if keyFocus != .pane { keyFocus = .pane; focusSelection() }
        } else {
            guard !(keysStay && wouldRetargetFocusedPane(next)) else { return false }
            keyFocus = .pane
            select(next)
            focusSelection()
        }
        return true
    }

    /// ⌘J's pick (nextNeedsYou's): the Needs you rows after the focused pane's session, wrapping, the first blocked one,
    /// else the first done one; nil: no other live session needs you. Reads only.
    func nextNeedingYou() -> AgentSidebar.RowID? {
        let rows = sections.first { $0.id == AgentSidebar.needsYouTitle }?.rows ?? []
        let mine = layout.panes.first { $0.id == layout.focused }?.target
        let after = rows.firstIndex { target($0.id) == mine }.map { Array(rows[($0 + 1)...] + rows[..<$0]) } ?? rows
        guard let next = after.first(where: { $0.state == .blocked }) ?? after.first, case .live = next.id else { return nil }
        return next.id
    }

    /// #1862 n180 (#1864 reuses it for sessions.focus): `select(id)` would put another target into the focused pane (the
    /// browse rule's answer, `showing`), so its terminal view is swapped and takes the keys the old one had. An agent path
    /// (keepingKeys) skips such a select. A refused show retargets nothing: false.
    /// shortcut: reads the browse rule; a made layout's pick (lockedShowing) parks it for a single-pane view
    /// instead, which this counts as a retarget too (the conservative answer), upgrade if an agent path must pick there.
    func wouldRetargetFocusedPane(_ id: AgentSidebar.RowID) -> Bool {
        guard case let .success(l) = showing(id) else { return false }
        func shownIn(_ p: PaneLayout) -> PaneTarget? { p.panes.first { $0.id == layout.focused }?.target }
        return shownIn(l) != shownIn(layout)
    }

    /// 8.1: the layout numbered `n`, 1 to 9 in the list's order. `n` is outside data (a key): compared, never trapped on;
    /// a number with no layout is a no-op (.noSuchLayout): nothing made, switched or written.
    @discardableResult
    func switchLayout(number n: Int) -> PaneRefusal? {
        guard AgentPaneLayout.splitsEnabled else { return .layoutsOff }
        guard !closed, let s = layouts, n >= 1, n <= s.layouts.count else { return .noSuchLayout }
        return switchLayout(s.layouts[n - 1].id)
    }

    /// #901 B3 step 4a (8.1): one row of the sidebar's Layouts section. `name` is as drawn: the set name, else the
    /// automatic name of its panes' titles, through OutsideText.shown (outside data: never an id or a format string).
    struct LayoutRow: Identifiable, Equatable {
        let id: UUID
        /// 1...9, the stored order (the ⌃N key).
        let number: Int
        let name: String
        let active: Bool
        /// #901 B3 step 5 (section 10): blocked sessions in this layout's panes, an inactive layout only; 0 draws nothing.
        var blocked = 0
        /// #1661: any session in this layout's panes is working (the row draws the working mark, else idle). In `==`, so a flip redraws.
        var working = false
    }

    /// #901 B3 step 5 (section 10): what a session in a pane asks of the person: blocked outranks done (the sidebar's order).
    enum PaneNeed: Equatable { case blocked, done }

    /// Section 10's map: the active layout's panes whose session needs you, and per INACTIVE layout the count of its
    /// distinct blocked sessions (no entry for 0). Pure value.
    struct Attention: Equatable {
        var panes: [UUID: PaneNeed] = [:]
        var layouts: [UUID: Int] = [:]
    }

    /// Needs-you sessions by key, as of the last visible refresh (refresh(sessions:)); nil with the gate off or before
    /// the first visible refresh. Written only when it changes, so an equal refresh publishes nothing.
    @Published private(set) var needs: [AgentSessionKey: PaneNeed]?

    /// #1661: the working sessions' keys, from the same visible refresh as `needs` and written only when they change; nil
    /// with the gate off or before the first visible refresh (every Layouts row idle).
    @Published private(set) var working: Set<AgentSessionKey>?

    static func needing(_ sessions: [AgentSession]) -> [AgentSessionKey: PaneNeed] {
        var out: [AgentSessionKey: PaneNeed] = [:]
        for s in sessions where AgentSidebar.needsYou(s) { out[s.key] = s.state == .blocked ? .blocked : .done }
        return out
    }

    /// The map from `needs`, the active layout as it is now and the stored layouts: a pure read; nil with the gate off.
    var attention: Attention? {
        guard AgentPaneLayout.splitsEnabled, let n = needs else { return nil }
        return Self.attention(n, active: layout, stored: layouts?.layouts ?? [])
    }

    static func attention(_ needs: [AgentSessionKey: PaneNeed], active: PaneLayout, stored: [PaneLayout]) -> Attention {
        func key(_ t: PaneTarget?) -> AgentSessionKey? {
            if case let .session(d, n)? = t { AgentSessionKey(dir: d, name: n) } else { nil }   // history, remote: none
        }
        var a = Attention()
        for p in active.panes { if let k = key(p.target), let v = needs[k] { a.panes[p.id] = v } }
        for l in stored where l.id != active.id {
            let blocked = Set(l.panes.compactMap { key($0.target) }.filter { needs[$0] == .blocked })
            if !blocked.isEmpty { a.layouts[l.id] = blocked.count }
        }
        return a
    }

    /// Section 10's marks of pane `id`: nil for the focused pane (it never shows them) and for one that needs nothing.
    func paneNeed(_ id: UUID) -> PaneNeed? {
        guard id != layout.focused else { return nil }
        return attention?.panes[id]
    }

    /// #901 B3 step 4a (8.1 :625-627): the Layouts section's rows in the stored order; nil: the section is not built.
    /// Gate off: nil before anything is read (nothing drawn, routed or read aloud). Shown when the active layout has two or
    /// more panes or there are two or more layouts. A pure read of the state a user action changes (`layout`, `layouts`,
    /// `sections` for the titles): a refresh that changes none of them gives the same rows.
    var layoutRows: [LayoutRow]? {
        guard AgentPaneLayout.splitsEnabled, let s = layouts, (parked ?? layout).panes.count >= 2 || s.layouts.count >= 2
        else { return nil }
        let counts = attention?.layouts ?? [:]   // step 5: inactive layouts only (the map skips the active one)
        let busy = working ?? []
        return s.layouts.prefix(PaneLayoutStore.maxLayouts).enumerated().map { i, stored in
            let l = stored.id == layout.id ? layout : stored   // the active one as it is now (island off too)
            let name = l.name ?? PaneLayoutStore.automaticName(l.panes.map { layoutTitle($0.target) })
            // #1661: any pane's session working; an empty pane, a gone session, history or remote: idle
            let working = l.panes.contains { p in
                if case let .session(d, n)? = p.target { busy.contains(AgentSessionKey(dir: d, name: n)) } else { false }
            }
            return LayoutRow(id: l.id, number: i + 1, name: OutsideText.shown(name), active: l.id == layout.id,
                             blocked: counts[l.id] ?? 0, working: working)
        }
    }

    /// A pane's title for an automatic layout name: the sidebar row's title; a gone target the pane's own word for it
    /// (AgentPaneArea.title: its name); no target "Empty".
    private func layoutTitle(_ t: PaneTarget?) -> String {
        switch t {
        case let .session(d, n)?: row(.live(AgentSessionKey(dir: d, name: n)))?.title ?? n
        case let .history(d, id, _)?: row(.history(AgentSessionKey(dir: d, name: id)))?.title ?? id
        case let .remote(_, n)?: n
        case nil: "Empty"
        }
    }

    /// 8.1 ⌃Tab: the MRU pair, the layout active before this one. One layout: a no-op (.noSuchLayout), nothing written.
    @discardableResult
    func previousLayout() -> PaneRefusal? {
        guard AgentPaneLayout.splitsEnabled else { return .layoutsOff }
        guard !closed, let p = layouts?.previous else { return .noSuchLayout }
        return switchLayout(p)
    }

    /// #901 B3 step 2 (decision c): with the island off, the active layout as the person left it: the pane bind(nil)
    /// emptied (memory only, not their change) is saved with its target. nil, so skipped as before: the gate off, or
    /// nothing recorded, or a target the tree refuses back.
    private func islandOffLayout() -> PaneLayout? {
        guard AgentPaneLayout.splitsEnabled, let e = offEmptied else { return nil }
        guard e.layout == layout.id, layout.panes.contains(where: { $0.id == e.pane && $0.target == nil }) else { return layout }
        return try? layout.replace(e.pane, target: e.target).get()
    }

    /// 8.1: a change of the active layout (or `next`, a whole store) is written once; a call that changes nothing
    /// writes nothing. Runs on the main actor (the layout's didSet, deleteLayout). Causes of the early returns: no
    /// store loaded (`layoutDefaults` nil), the window closed; for a layout change also the island off (`store` nil:
    /// bind(nil) empties the pane, which is not the user's change; the blob keeps their target), the 9-layout cap
    /// (`storing` nil); and no change.
    /// shortcut: one write per committed change, not coalesced per run-loop turn (8.1); B2's divider (save at drag end)
    /// and B3's chained verbs are where coalescing pays.
    /// #1895: every change of a layout is saved at once; the single-pane view (`parked`) is never a layout, never saved.
    private func autosave(_ next: PaneLayoutStore? = nil) {
        guard let d = layoutDefaults, !closed, let s = layouts else { return }
        if next == nil, parked != nil { return }   // #1538: the parked layout stays as saved under the single-pane view
        guard let n = next ?? (store == nil ? islandOffLayout().flatMap(s.storing) : s.storing(layout)), n != s else { return }
        layouts = n
        layoutWrites += 1
        Preferences.setAgentWindowLayouts(n, in: d)
    }

    /// Follows `store` (nil: the island is off). Called on open and whenever the
    /// island rebuilds its store. The sidebar fills once the window is visible.
    func bind(_ store: AgentIslandStore?) {
        guard !closed else { return }
        dragEnded()   // R900-5a-1: saved while the old store is still bound (bind(nil) makes autosave a no-op)
        self.store = store
        hasStore = store != nil
        subscription = nil
        guard let store else {
            stopFollow()   // #1555: the island off lists no remote rows either way
            // QA #713 INFO-4: the island's runner drops every answer once its store is gone.
            if let k = newSession?.starting {
                // R2 F5: answered and waiting for its row: it started, so the form goes; else no answer will come.
                if pendingSpawn?.key == k { newSession = nil } else {
                    newSession?.starting = nil
                    newSession?.status = "No answer for \(k.name): Agent Island is off"
                }
                follow()   // #2058: the started pane goes either way

            }
            pendingSpawn = nil   // #1096 1b: the island back later would expire it over a session that runs
            claimed = [:]
            sections = []
            // #901 B3 step 2 (decision c): the pane about to be emptied and its target, once per island-off spell.
            if offEmptied == nil, AgentPaneLayout.splitsEnabled {
                offEmptied = (layout.id, layout.focused, layout.panes.first { $0.id == layout.focused }?.target)
            }
            select(nil, manual: false)
            return
        }
        // R1194-2: the island back: the saved layout again (bind(nil) emptied its pane in memory only), before the first
        // refresh, so no first-row pick lands over the saved target and the autosave finds the store equal (no write).
        if let saved = layouts?.activeLayout, saved != layout { parked = nil; adopt(saved) }
        offEmptied = nil
        // @Published sends on willSet with the new value, so the values are used as given.
        subscription = store.$sessions.combineLatest(store.$history, store.$sort, store.$sessionGroups)
            .combineLatest(store.$details, store.$actions)
            .sink { [weak self] v, details, actions in
                MainActor.assumeIsolated {
                    self?.seeSpawn(v.0)
                    self?.refresh(sessions: v.0, history: v.1, sort: v.2, groups: v.3, details: details, actions: actions)
                    self?.pollRemote()
                    self?.feedPty(v.0)   // #896: after the refresh, so a terminal it just attached gets its row
                    self?.stampLastLive(v.0)   // after the refresh: a pane it just filled is stamped by this publish
                }
            }
    }

    /// #831 A2 (4.1a, entry 898 item a): a store publish stamps the shown panes whose session it lists live, at the
    /// publish's own time: the store has no poll time, and this sink runs as it publishes. The age tick never stamps
    /// (its values are the last publish's, so its clock would date a sight it never made); nor does a hidden window.
    private func stampLastLive(_ sessions: [AgentSession]) {
        guard visible, !closed else { return }
        // B1 step 2 (R899-3): every shown pane, from frames (the split gate off: the focused pane alone, 15.0).
        // #900 N900-d: with the gate on, every pane of the active layout (zoomed away and too-small hidden ones keep a
        // runtime, so a stale sight would bind them to an earlier instance's record).
        let stamped = AgentPaneLayout.splitsEnabled ? Set(layout.order) : shownPanes
        lastLive = AgentPaneLayout.stamp(lastLive, layout: layout.id, panes: layout.panes, visible: stamped,
                                         sessions: sessions, at: now())
    }

    /// 3.5, phase A: the RAW mapping of a pane target to its sidebar row, never through resolve. A remote pane has none.
    nonisolated static func rowID(_ t: PaneTarget?) -> AgentSidebar.RowID? {
        switch t {
        case let .session(dir, name)?: .live(AgentSessionKey(dir: dir, name: name))
        case let .history(dir, id, _)?: .history(AgentSessionKey(dir: dir, name: id))
        case let .remote(h, n)?: .remote(host: h, name: n)
        case nil: nil
        }
    }

    /// The pane target of a sidebar row; a History row's carries the record's lastSeen as `seen` (3.1).
    private func target(_ id: AgentSidebar.RowID) -> PaneTarget {
        switch id {
        case let .live(k): .session(dir: k.dir, name: k.name)
        case let .history(k): .history(dir: k.dir, id: k.name, seen: row(id)?.record?.lastSeen)
        case let .remote(h, n): .remote(host: h, name: n)
        }
    }

    /// Rebuilds the sidebar from the store's current values (the age clock's tick).
    func refresh() {
        guard let s = store else { return }
        refresh(sessions: s.sessions, history: s.history, sort: s.sort, groups: s.sessionGroups, details: s.details,
                actions: s.actions)
        pollRemote()
    }

    /// #836 (a): one `dch --ls-json --remote` per refresh (a store publish, the age tick, showing the window), at most one
    /// at a time and one per `remoteEvery`. Hidden, closed or the island off: none.
    /// #1555: a client dch >= 1.62.0 lists through one follow child instead (startFollow); then this runs only the
    /// remote History call, at its own spacing. Until the probe answers (and for an older client): the call as before.
    func pollRemote() {
        guard visible, !closed, store != nil else { return }
        probeFollow()
        let following = remoteFollows == true
        if following { startFollow() }
        guard !remoteInFlight else { return }
        let t = remoteClock()
        // #1634: the list at `remoteGap`; History, due on its own spacing, no longer waits for the list's turn.
        let list = !following && (remoteAt.map { t - $0 >= remoteGap } ?? true)
        // #1324 (a): History in the same job, at dch's own History spacing.
        let history = remoteHistoryAt.map { t - $0 >= Self.remoteHistoryEvery } ?? true
        guard list || history else { return }
        // #1634: a list run at once (remoteAt nil: a remote action's, the first) never doubles: what it waits for may come next.
        let counts = list && remoteAt != nil
        if list { remoteAt = t }
        if history { remoteHistoryAt = t }
        remoteInFlight = true
        if list { remoteCalls += 1 }
        let run = remoteRun, runHistory = remoteHistoryRun, env = AgentIsland.listEnv(dir: DchCommand.defaultSocketDir)
        let historyArgs = Self.remoteHistoryArgs
        let job: @Sendable () -> (Data?, Data?) = {
            (list ? run(["--ls-json", "--remote"], env) : nil, history ? runHistory(historyArgs, env) : nil)
        }
        guard remoteOffMain else { let r = job(); return remoteListed(r.0, history: r.1, listed: counts) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = job()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.remoteListed(r.0, history: r.1, listed: counts) } }
        }
    }

    /// #836 (e): the answer replaces the remote rows whole, so a host dch no longer lists drops its rows in one refresh.
    /// A host that missed one probe is still listed by dch, "stale":true, for two minutes (its cache), so one refresh
    /// is enough and a transient miss never empties the section. nil or not an array: the rows stay (a wedged dch is
    /// not "no hosts").
    /// #1324 (a): the History answer the same way: replaced whole when it is an array, kept otherwise; an offline
    /// host's records stay, "stale", for dch's two minutes, then go with the next good answer.
    /// #1634: `listed` (a list call ran on its spacing): a change starts the spacing over, none doubles it up to
    /// remoteIdleMax, except while a remote Start waits for its row (the person is waiting for it).
    func remoteListed(_ data: Data?, history: Data? = nil, listed: Bool = false) {
        remoteInFlight = false
        guard !closed else { return }
        var changed = false
        if let data, let rows = AgentSidebar.parseRemote(data), rows != remoteSessions { remoteSessions = rows; changed = true }
        if let history, let recs = AgentSidebar.parseRemoteHistory(history), recs != remoteHistory {
            remoteHistory = recs
            changed = true
        }
        let awaited = pendingSpawn.map { AgentTerminalSpawn.remoteHost($0.key) != nil } ?? false
        if changed || awaited { remoteGap = Self.remoteEvery } else if listed {
            remoteGap = min(remoteGap * 2, Self.remoteIdleMax)
        }
        guard changed, let s = store else { return }
        refresh(sessions: s.sessions, history: s.history, sort: s.sort, groups: s.sessionGroups, details: s.details,
                actions: s.actions)
    }

    /// #1555: once per showing, the client's version decides follow or call (off main in the app, inline under XCTest).
    private func probeFollow() {
        guard remoteFollows == nil, !followProbing else { return }
        let probe = remoteFollowVersion, gen = followGen
        guard remoteOffMain else { return followProbed(probe(), gen: gen) }
        followProbing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let v = probe()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.followProbed(v, gen: gen) } }
        }
    }

    /// An unknown version is not a new one: the call, as before. A hide since the probe began drops its answer.
    private func followProbed(_ v: [Int]?, gen: Int) {
        guard gen == followGen else { return }
        followProbing = false
        remoteFollows = v.map { DchCommand.isAtLeast($0, Self.remoteFollowDch) } ?? false
        if remoteFollows == true { startFollow() }
    }

    /// #1555: one follow child while shown: none while one runs or waits out its backoff, hidden, closed or island off.
    private func startFollow() {
        guard remoteFollows == true, follower == nil, !followWaiting, visible, !closed, store != nil else { return }
        followGen += 1
        let gen = followGen
        followLines = AgentRemoteFollowLines()
        followStartedAt = remoteClock()
        remoteFollowStarts += 1
        follower = remoteFollowStart(Self.remoteFollowArgs, AgentIsland.listEnv(dir: DchCommand.defaultSocketDir),
                                     { [weak self] in self?.followRead($0, gen: gen) },
                                     { [weak self] in self?.followExited($0, gen: gen) })
        if follower == nil { followExited(-1, gen: gen) }   // it did not start: retried like an exit
    }

    /// Each complete line is the whole remote list, replaced as one call's answer is; a bad line keeps the last good rows.
    private func followRead(_ chunk: Data, gen: Int) {
        guard gen == followGen, !closed else { return }
        var changed = false
        for line in followLines.append(chunk) {
            if let rows = AgentSidebar.parseRemote(line), rows != remoteSessions { remoteSessions = rows; changed = true }
        }
        guard changed, let s = store else { return }
        refresh(sessions: s.sessions, history: s.history, sort: s.sort, groups: s.sessionGroups, details: s.details,
                actions: s.actions)
    }

    /// The child ended on its own: restarted after AgentTerminal's backoff (a child that lived `reconnectSettled`
    /// starts it over; past its last step every restart waits that last step). Exit 2 is dch's bad usage: this
    /// client cannot follow, so the per-refresh call takes over for this showing.
    private func followExited(_ status: Int32, gen: Int) {
        guard gen == followGen else { return }
        follower = nil
        guard visible, !closed else { return }
        if status == 2 { remoteFollows = false; return pollRemote() }
        if remoteClock() - followStartedAt >= AgentTerminalController.reconnectSettled { followRestarts = 0 }
        let steps = AgentTerminalController.reconnectBackoff
        let delay = steps[min(followRestarts, steps.count - 1)]
        followRestarts += 1
        followWaiting = true
        remoteAfter(delay) { [weak self] in
            guard let self, gen == self.followGen else { return }
            self.followWaiting = false
            self.startFollow()
        }
    }

    /// #1555: hide, close or island off: the child is stopped by its recorded pid and every late answer dropped;
    /// the next showing probes again (a client updated meanwhile).
    private func stopFollow() {
        followGen += 1
        follower?.stop()
        follower = nil
        followWaiting = false
        followProbing = false
        followRestarts = 0
        remoteFollows = nil
    }

    /// #836: the focused pane's remote session while its row is listed; nil for anything else.
    var focusedRemote: AgentSidebar.Remote? {
        guard case let .remote(h, n)? = focusedTarget else { return nil }
        return row(.remote(host: h, name: n))?.remote
    }

    private func refresh(sessions: [AgentSession], history: [DchHistoryRecord], sort: AgentIslandSort,
                         groups: [SessionGroup], details: AgentIslandRowDetails, actions: [AgentSessionKey: String]) {
        // Hidden or closed: nothing is rebuilt; showing again reads the store afresh.
        guard visible, !closed else { return }
        refreshes += 1
        // #1469: an effort switch's next answer; one that kept another level says so on its row.
        for (key, text) in interaction.effortLanded(sessions) { refusal = AgentWindowRefusal(id: .live(key), text: text) }
        // #901 B3 step 5 (section 10): the attention source, on this visible refresh only; gate off: stays nil.
        let n = AgentPaneLayout.splitsEnabled ? Self.needing(sessions) : nil
        if n != needs { needs = n }
        let w = AgentPaneLayout.splitsEnabled ? Set(sessions.lazy.filter { $0.state == .working }.map(\.key)) : nil
        if w != working { working = w }
        // #1324: a remote Resume's text by its record id ("@" + host: never a local key).
        let inputs = SidebarInputs(history: history, sort: sort, groups: groups, details: details,
                                   actions: actions.merging(remoteResumeText) { a, _ in a }, remote: remoteSessions,
                                   remoteHistory: remoteHistory)
        let t = now()
        let new: [AgentSidebar.Section]
        // #1634: the same sessions, titles and order, only activity or the clock moved: the ages are read again, no build;
        // and when no age changed either, nothing publishes (the rows keep their sessions of the last publish: nothing
        // drawn reads a row's activity, only its age and its place). Empty sections: bind(nil) cleared them, so build.
        if let b = built, b.inputs == inputs, !sections.isEmpty, AgentIsland.onlyActivityMoved(sessions, b.sessions),
           let aged = AgentSidebar.reaged(sections, sessions: sessions, sort: sort, now: t) {
            new = aged.map(\.rows).map { $0.map(\.age) } == sections.map(\.rows).map { $0.map(\.age) } ? sections : aged
        } else {
            sectionBuilds += 1
            new = AgentSidebar.sections(sessions: sessions, history: history, sort: sort, groups: groups,
                                        details: details, now: t, actions: inputs.actions, remote: remoteSessions,
                                        remoteHistory: remoteHistory)
        }
        built = (sessions, inputs)
        publishing = (sessions, history)
        defer { publishing = nil }
        if new != sections { sections = new }
        // #831 B1 (4.3): the focused pane re-resolved on every publish. A session that ended stays Ended (4.4) and
        // swaps once to its own record (4.5: G2 subsumed). #1929: a removed record's panes close (the only pane goes
        // empty) before the resolve, so the selection is never another record.
        if let id = removing, row(.history(id)) == nil {
            removing = nil
            for p in removingPanes where layout.panes.contains(p) {
                if layout.panes.count > 1 { closePane(p.id) } else { select(nil, manual: false) }
            }
            removingPanes = []
        }
        settle()
        follow()
        if confirming != nil, confirmingSession == nil, confirmingRecord == nil { confirming = nil }
        if let k = renaming, !sessions.contains(where: { $0.key == k }) { renameEdit = nil }   // it ended: no field
        // #853 F1 (QA #699): a busy Return's refusal goes with the running text it was refused under,
        // so the row's outcome ("Restarted", a failure, the Stop's result) shows. Other refusals keep theirs.
        if let r = refusal, r.text == AgentIsland.renameBusyText, case .live(let k) = r.id,
           AgentWindowControls.lock(actions[k]) == nil { refusal = nil }
        // #948 F2, F3: before landSpawn, so no check here runs on this publish's values after a write it made.
        expireDirLine(sessions: sessions, actions: actions)
        endUnlisted(history)
        landSpawn()   // #847
        landResume()   // #1924
        // #828: the first shown row; every section folded leaves the hint, not a hidden pick.
        if !filled, !rows.isEmpty {
            filled = true
            // B1 step 2: only into an empty focused pane; a pane with a target (an adopted layout's, its session gone)
            // keeps it and shows its placeholder (R3.4), never another conversation.
            // #836: never a remote row: an attach there takes the session from the device that has it (dch exit 5).
            if focusedTarget == nil, let first = navigableIDs.first(where: { if case .remote = $0 { false } else { true } }) {
                select(first, manual: false)
            }
        }
    }

    var rows: [AgentSidebar.Row] { sections.flatMap(\.rows) }
    func row(_ id: AgentSidebar.RowID) -> AgentSidebar.Row? { rows.first { $0.id == id } }
    /// The focused pane's row: its Ended session's last live row (4.4), else the selection's row.
    var selectedRow: AgentSidebar.Row? { ended?.row ?? selection.flatMap { row($0) } }
    /// #831 B1 (4.4): the focused pane is Ended (kept blocks, display only: nothing opens, sends or asks on it).
    var focusedEnded: Bool { ended != nil }

    var focusedTarget: PaneTarget? { layout.panes.first { $0.id == layout.focused }?.target }

    /// 4.1 on the focused pane, against the publish being handled, else the store as it is now. No store: nil.
    private func focusedContent() -> PaneContent? { resolvedContent(of: layout.focused, focusedTarget) }

    /// 4.1 on one pane of the active layout (its own slot of the lastLive map). No store or no target: nil.
    private func resolvedContent(of pane: UUID, _ target: PaneTarget?) -> PaneContent? {
        guard let t = target,
              let v = publishing ?? store.map({ (sessions: $0.sessions, history: $0.history) }) else { return nil }
        // #1324: a remote History pane resolves to its record while dch lists it.
        return AgentPaneLayout.resolve(t, sessions: v.sessions, history: v.history + remoteHistory.map(\.record),
                                       lastLive: lastLive[AgentPaneLayout.PaneSlot(layout: layout.id, pane: pane)])
    }

    /// 4.3: the focused pane resolved now; its session only when `.live` (an ended, removed or empty pane: nil).
    var focusedLive: AgentSession? {
        guard !closed, case .live(let s)? = focusedContent() else { return nil }
        return s
    }

    /// 3.5 (B1): a content's sidebar row.
    nonisolated static func resolvedRow(_ c: PaneContent?) -> AgentSidebar.RowID? {
        switch c {
        case let .live(s)?: .live(s.key)
        case let .history(r)?: .history(r.id)
        case .notRunning?, .removed?, nil: nil
        }
    }

    /// #831 B1: re-resolves the focused pane and writes `content`, `ended` and `selection`. Ended (M1) is entered only
    /// on a `.live` -> `.notRunning` edge of the same target while the transcript runs (visible): a session that
    /// ended while hidden had its blocks freed, so it shows nothing kept. Any other content or target drops the kept
    /// blocks (`drop()`), so a name reuse never runs `start()` on them (4.4 (b)). No store: the raw mapping (3.5 A).
    /// B1 step 2: every pane of the active layout is settled (its own content and Ended state); `selection` stays the
    /// focused pane's.
    /// True when it published (a change of row, or of focusedEnded).
    @discardableResult
    private func settle() -> Bool {
        let wasEnded = focusedEnded
        for p in layout.panes { if let r = runtimes[p.id] { settle(r, target: p.target) } }
        // #836: a remote pane resolves to no content (AgentPaneLayout.resolve); its row is the selection while listed.
        let s = store == nil ? Self.rowID(focusedTarget) : focusedRemote.map { AgentSidebar.RowID.remote(host: $0.host, name: $0.name) }
            ?? Self.resolvedRow(content)
        // Any change of row drops the confirm strip's question, a refusal and the rename field (R5), as a
        // `select()` did before B1 for the publish-driven changes too (an end, the swap to History).
        if s != selection {
            selection = s
            confirming = nil
            refusal = nil
            renameEdit = nil
            if s != nil, let f = firstShown { firstShown = nil; f() }
        } else if focusedEnded != wasEnded {
            objectWillChange.send()   // the view reads focusedEnded: told even when the row stays (an emptied pane)
        } else {
            return false
        }
        return true
    }

    /// One pane's runtime. Ended entry: a `.live` -> `.notRunning` edge of the same target while this pane's
    /// transcript runs (shown, visible window); exit: any other content or target (`drop()`).
    private func settle(_ r: AgentPaneRuntime, target t: PaneTarget?) {
        let was = r.content
        let c = store == nil ? nil : resolvedContent(of: r.pane, t)
        if case .live(let s)? = c { r.liveRow = row(.live(s.key)) }
        // #900 N900-e (4.4): a suspended pane (zoomed away, too-small hidden: gate on only) keeps its blocks: Ended too.
        if case .notRunning? = c, case .live? = was, r.ended == nil, visible,
           r.transcript.running || r.transcript.suspended,
           let t, let kept = r.liveRow, kept.id == Self.rowID(t) {
            r.ended = (t, kept)
        } else if let e = r.ended {
            var stays = false
            if case .notRunning? = c { stays = e.target == t }
            if !stays {
                r.ended = nil
                r.transcript.drop()   // the one swap, a name reuse, a retarget: the kept model goes (4.4 (b), (e))
            }
        }
        if r.content != c { r.content = c }   // published only on a change (one view update per change)
    }

    func isCollapsed(_ title: String) -> Bool {
        sidebarMode != .mini && AgentSidebar.folds(title) && collapsed.contains(title)   // #1383: Mini's rail draws no headers, so no fold
    }

    /// Folds or unfolds `title` (a header click); a section that never folds is left alone.
    func setCollapsed(_ title: String, _ on: Bool) {
        guard sidebarMode != .mini, AgentSidebar.folds(title) else { return }   // #1383: Mini never writes Full's fold
        if on { collapsed.insert(title) } else { collapsed.remove(title) }
    }

    func toggleCollapsed(_ title: String) { setCollapsed(title, !isCollapsed(title)) }

    /// Left / right arrows: fold or unfold the selected row's section.
    func collapseSelected(_ on: Bool) {
        guard let sel = selection, let s = sections.first(where: { $0.rows.contains { $0.id == sel } }) else {
            // QA #660 note 1: Right with nothing selected and nothing shown unfolds the first
            // folded section; then (or when rows show) it selects the first shown row.
            if !on, selection == nil {
                if navigableIDs.isEmpty, let s = sections.first(where: { isCollapsed($0.id) }) { setCollapsed(s.id, false) }
                move(1)
            }
            return
        }
        setCollapsed(s.id, on)
    }

    /// The rows up/down walk: the shown ones, plus the selection where it sits when its
    /// section is folded (so a move goes to its neighbour, never into a folded section).
    var navigableIDs: [AgentSidebar.RowID] {
        sections.flatMap { s in isCollapsed(s.id) ? s.rows.filter { $0.id == selection } : s.rows }.map(\.id)
    }

    /// `manual`: the human's pick (a click, a key, a menu); it drops a pending follow-to-History.
    /// Any change of row drops the confirm strip's question (R5).
    /// #847: a manual pick also closes the New session form and drops a pending spawn's selection.
    func select(_ id: AgentSidebar.RowID?, manual: Bool = true, placement: PaneLayout.Placement = .focused) {
        if manual { removing = nil; pendingSpawn = nil; newSession = nil; pendingResume = nil }
        // #831 A2 (3.5): into the focused pane through the browse rule, never straight into the tree. One pane: the
        // pick replaces its target (or swaps it for the name's own record, #580); B1: `selection` is its resolve, and
        // `settle()` drops the strip's question on a change of row.
        // #1538: a made layout's own pick (the human's, into the focused pane) goes through lockedShowing; #1895: an empty
        // focused pane takes it instead (after Split or "+"); a session the layout shows still only focuses its pane.
        let next = if let id, manual, placement == .focused, layoutMade, focusedTarget != nil { lockedShowing(id) } else {
            id.map { showing($0, placement: placement) } ?? layout.replace(layout.focused, target: nil)
        }
        switch next {
        case let .success(l):
            if paneRefusal != nil { paneRefusal = nil }
            // #1700: Open to the Side from the single-pane view: a new layout of the view and the side pane
            if placement == .side, parked != nil, l.order != layout.order { unpark(l) } else {
                layout = l
                if placement == .side, parked == nil { autosave() }   // #1826; #1832: never the parked single-pane view
            }
        case let .failure(r):
            paneRefusal = r   // R899-2: kept for the pane notice line, never dropped silently
        }
        // #1330 (R836-q1): only the human's pick (a click, a key) arms a remote attach; follow() alone never starts one.
        // #1477 b3: armed after the move, on the pane the pick focused (rule 1 can move the focus to another pane's terminal).
        if manual, case let .remote(h, n)? = id { terminal.arm(AgentTerminalSpawn.remoteKey(host: h, name: n)) }
        follow()
    }

    /// #845: the selection sits in a folded section (Right unfolds it before it moves in).
    var selectionFolded: Bool {
        sections.first { $0.rows.contains { $0.id == selection } }.map { isCollapsed($0.id) } ?? false
    }

    /// #845: a row click, Return or Right: the keyboard into the selected live session's terminal (once its client
    /// is live; #1471: Terminal is the only mode). False, and the focus
    /// stays where it is: nothing there takes input (History, an ended session's held row, none), or the rename
    /// field is editing. Only the human's actions call it, never a selection the model makes itself.
    @discardableResult
    func focusSelection() -> Bool {
        // #887 (QA #747 INFO-4): the New session form covers the pane, so its session takes no input meanwhile.
        // #1862 n170: inside keepingKeys (an agent's pane change) no terminal takes the keys.
        guard !keysStay, renaming == nil, newSession == nil, !focusedEnded,
              selectedRow?.session != nil || selectedRow?.remote != nil else { return false }
        terminal.focus()   // #1471: Terminal is the only mode
        return true
    }

    /// #1862 n170: true only inside `keepingKeys`.
    private(set) var keysStay = false

    /// #1862 n170: `body` (the control channel's pane changes: window.nextNeedsYou and its undo) shows and focuses panes
    /// as the human's keys do, but the keys stay where they are, as sessions.focus leaves them: focusSelection refuses
    /// meanwhile (every pane focus path asks it) and keyFocus is put back after. The human's ⌘J never runs inside it.
    func keepingKeys<T>(_ body: () throws -> T) rethrows -> T {
        let held = (keyFocus, keysStay)
        keysStay = true
        defer { (keyFocus, keysStay) = held }
        return try body()
    }

    /// #1538: a pick on a made layout (select). A session the layout shows: the browse rule on the layout (its pane focused; from the
    /// single-pane view, back to the layout as it was left). Any other: the single-pane view shows it, the layout parked
    /// (set before select's write, so its autosave saves nothing); already there, the view's own pane takes it.
    private func lockedShowing(_ id: AgentSidebar.RowID) -> Result<PaneLayout, PaneRefusal> {
        let t = target(id), home = parked ?? layout
        let area = CGRect(origin: .zero, size: paneArea.size)
        if home.pane(showing: t) != nil {
            let out = home.show(t, placement: .focused, minimum: paneMinimum, in: area, splitsEnabled: true)
            if case .success = out { parked = nil }
            return out
        }
        if parked != nil { return layout.show(t, placement: .focused, minimum: paneMinimum, in: area, splitsEnabled: true) }
        dragEnded()   // #1895 (R900-5a-1): the drag's save lands before the park (autosave never saves a parked layout)
        parked = layout
        return .success(.single(t))
    }

    /// #900 B2 step 6b1: the browse rule's answer for row `id` (select's own call; the row menu reads it). `.side` splits
    /// in the pane area at the minimum paneFrames tiles with; `.focused` never reads the area.
    func showing(_ id: AgentSidebar.RowID, placement: PaneLayout.Placement = .focused) -> Result<PaneLayout, PaneRefusal> {
        countDryRun()
        return layout.show(target(id), placement: placement, minimum: paneMinimum, in: CGRect(origin: .zero, size: paneArea.size),
                    splitsEnabled: AgentPaneLayout.splitsEnabled)
    }

    /// #1491: the pane title switcher's list for `pane`: the sidebar's rows in its order, History left out, each with the
    /// number (1-based, layout order) of ANOTHER pane that shows its session, nil when none does.
    func switcherRows(for pane: UUID) -> [(row: AgentSidebar.Row, inPane: Int?)] {
        let order = layout.order
        return sections.filter { $0.id != "History" }.flatMap(\.rows).map { r in
            let shown = layout.pane(showing: target(r.id)).flatMap { $0 == pane ? nil : order.firstIndex(of: $0) }
            return (r, shown.map { $0 + 1 })
        }
    }

    /// #1491: a pick in pane `pane`'s title switcher: row `id` goes into THAT pane (focused or not), swapping with a pane
    /// that already shows it (PaneLayout.put), then the pane takes the focus and the keys as a sidebar click does (a remote
    /// row arms its attach). The pane's own session, or a pane no longer in the layout: nothing changes.
    /// #1895: the title switcher's pick, Swap Session… and a centre drop act alike and are saved (autosave).
    func choose(_ id: AgentSidebar.RowID, into pane: UUID) {
        if parked != nil { select(id); focusSelection(); return }   // #1700: the single-pane view's one pane takes the pick
        guard case let .success(put) = layout.put(target(id), in: pane), put != layout,
              case let .success(l) = put.focus(pane) else { return }
        removing = nil; pendingSpawn = nil; newSession = nil
        if paneRefusal != nil { paneRefusal = nil }
        layout = l
        if case let .remote(h, n) = id { terminal.arm(AgentTerminalSpawn.remoteKey(host: h, name: n)) }
        follow()
        focusSelection()
    }

    /// #1492: the drop indicator: the pane a sidebar row is dragged over and the zone it would take; nil, none.
    @Published private(set) var dropHover: (pane: UUID, zone: PaneDropZone)?

    /// #1492: a row's drag payload: a live or remote row's id as text; a History row has none (not draggable).
    static func dragToken(_ id: AgentSidebar.RowID) -> String? {
        if case .history = id { return nil }
        return String(describing: id)
    }

    /// #1895 (rule 4): a pane header's drag payload: its session's row token, so a drop on another pane's edge moves the
    /// pane there (PaneLayout.split closes the pane that showed it) and on its centre swaps the two (put); always on, no
    /// mode. A row with no token (History) or the split gate off: nil, no drag.
    /// #1927: an empty pane of several drags too: its own token (emptyPaneToken), never a row's.
    func paneDragToken(_ pane: UUID) -> String? {
        guard AgentPaneLayout.splitsEnabled, let p = layout.panes.first(where: { $0.id == pane }) else { return nil }
        guard let t = p.target else { return layout.panes.count > 1 ? Self.emptyPaneToken(pane) : nil }
        return Self.rowID(t).flatMap(Self.dragToken)
    }

    /// #1927: an empty pane's drag payload, matched only against this layout's empty panes (drop(_:into:at:in:)).
    static func emptyPaneToken(_ pane: UUID) -> String { "pane:" + pane.uuidString }

    /// #1492: the zone at `p` in pane of `size`; the split gate off, only the centre.
    func dropZone(at p: CGPoint, in size: CGSize) -> PaneDropZone {
        AgentPaneLayout.splitsEnabled ? PaneLayout.dropZone(at: p, in: size) : .centre
    }

    /// #1492: a drag over pane `pane` at `p` (its own coordinates): the indicator follows the zone.
    func dropOver(_ pane: UUID, at p: CGPoint, in size: CGSize) {
        let z = dropZone(at: p, in: size)
        if dropHover?.pane != pane || dropHover?.zone != z { dropHover = (pane, z) }
    }

    /// #1492: the drag left pane `pane` (or ended there): its indicator goes; another pane's stays.
    func dropExit(_ pane: UUID) {
        if dropHover?.pane == pane { dropHover = nil }
    }

    /// #1492: the dropped text `token` at `p` in pane `pane`: matched against this window's rows only (outside data is
    /// never parsed). False: no such draggable row, nothing changed but the indicator.
    @discardableResult
    func drop(_ token: String, into pane: UUID, at p: CGPoint, in size: CGSize) -> Bool {
        dropExit(pane)
        if let source = layout.panes.first(where: { $0.target == nil && Self.emptyPaneToken($0.id) == token })?.id {
            return move(source, into: pane, zone: dropZone(at: p, in: size))   // #1927
        }
        guard let id = rows.first(where: { Self.dragToken($0.id) == token })?.id else { return false }
        return drop(id, into: pane, zone: dropZone(at: p, in: size))
    }

    /// #1927: empty pane `source` dropped on pane `pane`, as a session pane's header drag: the centre swaps the two
    /// (`pane`'s session goes into `source`, `pane` is left empty), an edge closes `source` and splits `pane` on that side
    /// with a new empty pane. The pane the drop lands in takes the focus; a refusal is the split verbs' notice.
    @discardableResult
    func move(_ source: UUID, into pane: UUID, zone: PaneDropZone) -> Bool {
        dropHover = nil
        guard !closed, parked == nil, AgentPaneLayout.splitsEnabled, layout.order.contains(pane) else { return false }
        let moved: Result<PaneLayout, PaneRefusal>
        if case let .edge(side) = zone {
            moved = layout.split(pane, side: side, target: nil, moving: source, minimum: paneMinimum,
                                 in: CGRect(origin: .zero, size: paneArea.size))
        } else if let t = layout.panes.first(where: { $0.id == pane })?.target, case let .success(put) = layout.put(t, in: source) {
            moved = put.focus(pane)
        } else {
            moved = layout.focus(pane)   // two empty panes, or its own: nothing to swap
        }
        switch moved {
        case let .failure(r):
            paneRefusal = r
        case let .success(l):
            removing = nil; pendingSpawn = nil; newSession = nil
            if paneRefusal != nil { paneRefusal = nil }
            layout = l
            follow()
            focusSelection()
        }
        return true
    }

    /// #1492: row `id` dropped on pane `pane`. The centre (or any drop with the split gate off) is the title switcher's
    /// choose (put: a session shown in another pane swaps). An edge splits `pane` on that side with the row in the new
    /// pane (PaneLayout.split(_:side:); a session already shown elsewhere moves: its pane closes); a refusal
    /// is the split verbs' notice and nothing else changes. The pane the drop lands in takes the focus and the keys.
    @discardableResult
    func drop(_ id: AgentSidebar.RowID, into pane: UUID, zone: PaneDropZone) -> Bool {
        dropHover = nil
        guard !closed, Self.dragToken(id) != nil, row(id) != nil, layout.order.contains(pane) else { return false }
        // #1817, #1895: a drop (a sidebar row or a pane header) retargets, or splits with a move, and is saved
        guard AgentPaneLayout.splitsEnabled, case let .edge(side) = zone else { choose(id, into: pane); return true }
        switch layout.split(pane, side: side, target: target(id), minimum: paneMinimum,
                            in: CGRect(origin: .zero, size: paneArea.size)) {
        case let .failure(r):
            paneRefusal = r
        case let .success(l):
            // #1722: a refused unpark (9 layouts) keeps the pending state and arms, follows and focuses nothing
            if parked != nil { guard unpark(l) else { return true } } else { layout = l; autosave() }   // #1700: an edge drop on the single-pane view
            removing = nil; pendingSpawn = nil; newSession = nil
            if paneRefusal != nil { paneRefusal = nil }
            if case let .remote(h, n) = id { terminal.arm(AgentTerminalSpawn.remoteKey(host: h, name: n)) }
            follow()
            focusSelection()
        }
        return true
    }

    /// #845: a sidebar row's click: the human's pick, and the keyboard moves into it. #900 B2 step 6b1 (7.1, 15.0):
    /// `flags`, the click's event modifiers (outside data), are read only with the split gate on, and Option alone (no
    /// Command, Control or Shift) opens to the side; the gate off or any other set is today's click.
    func click(_ id: AgentSidebar.RowID, flags: @autoclosure () -> NSEvent.ModifierFlags = []) {
        if AgentPaneLayout.splitsEnabled, flags().intersection([.command, .option, .control, .shift]) == .option {
            return openToTheSide(id)
        }
        select(id)
        focusSelection()
    }

    /// R900-6b1-a: the flags a row Button's action may read: a plain SwiftUI Button runs its action on the left mouse up
    /// of the click it tracked (the down is the same click's), so only those two give their flags; a key (Full Keyboard
    /// Access), a flagsChanged, any other event or none (an accessibility press has no event of its own) gives [].
    static func clickFlags(_ e: NSEvent?) -> NSEvent.ModifierFlags {
        guard let e, e.type == .leftMouseUp || e.type == .leftMouseDown else { return [] }
        return e.modifierFlags
    }

    /// #900 B2 step 6b1 (7.1 rule 3, 3.3, 15.0): Option-click and the row menu's "Open to the Side". Gate off, a History
    /// row or an id no longer in the list: the plain click. Gate on: the layout's own show(.side) (rule 1 focuses a pane
    /// already showing it). A refusal (the cap, no room) is the key's refused split: the notice alone; layout,
    /// selection, the New session form and the keys stay.
    func openToTheSide(_ id: AgentSidebar.RowID) {
        guard AgentPaneLayout.splitsEnabled, case .live = id, row(id) != nil else { return click(id) }
        if case let .failure(r) = showing(id, placement: .side) { paneRefusal = r; return }
        select(id, placement: .side)
        focusSelection()
    }

    /// QA #694 INFO-2: the human took the keys elsewhere (a sidebar mouse-down, a rename) before a
    /// focus asked for landed (a terminal still attaching, an input box not built yet): it never lands.
    func dropPendingFocus() {
        terminal.dropPendingFocus()
        interaction.dropPendingFocus()
        pendingResume = nil   // #1924
    }

    /// Up/down: the next or previous shown row across groups, clamped; from none, the first.
    func move(_ delta: Int) {
        let ids = navigableIDs
        guard !ids.isEmpty else { return }
        // #900 B2 step 4 (7.1, OQ-1): with the gate on and several panes the step goes through PaneLayout.walk: a row
        // shown in another pane is skipped and the end is a no-op (no wrap). One pane or the gate off: today's walk.
        if AgentPaneLayout.splitsEnabled, layout.panes.count > 1 {
            if let t = layout.walk(ids.map { target($0) }, down: delta > 0), let id = Self.rowID(t) { select(id) }
            return
        }
        guard let sel = selection, let i = ids.firstIndex(of: sel) else { return select(ids[0]) }
        select(ids[min(max(i + delta, 0), ids.count - 1)])
    }

    /// #1342: the sidebar's drawn rows by section. #1785: built once per real change, never per selection or draw.
    /// Inputs: `sections` and `store` (their didSets clear it). `drawnBuilds` counts the builds.
    var drawnItems: [String: [AgentSidebar.Item]] {
        if let m = drawnMemo { return m }
        let drawn = AgentSidebar.items(sections)
        drawnMemo = drawn
        drawnBuilds += 1
        return drawn
    }
    private var drawnMemo: [String: [AgentSidebar.Item]]? { didSet { numberedMemo = nil } }
    private(set) var drawnBuilds = 0

    /// #1785: the numbered items and their chips, rebuilt only when `drawnItems` is (its memo's didSet clears this one),
    /// a fold (`collapsed`) or the mode (Mini folds nothing) changes. `numberedBuilds` counts the builds.
    private var numbered: (items: [AgentSidebar.Item], numbers: [AgentSidebar.RowID: Int]) {
        let drawn = drawnItems
        if let m = numberedMemo, m.collapsed == collapsed, m.mode == sidebarMode { return (m.items, m.numbers) }
        let items = Array(sections.filter { !isCollapsed($0.id) }.flatMap { drawn[$0.id] ?? [] }
            .filter { $0.rows.first?.session != nil }.prefix(18))
        let numbers = Dictionary(items.enumerated().map { ($1.id, $0 + 1) }) { a, _ in a }
        numberedMemo = (collapsed, sidebarMode, items, numbers)
        numberedBuilds += 1
        return (items, numbers)
    }
    private var numberedMemo: (collapsed: Set<String>, mode: AgentSidebarMode, items: [AgentSidebar.Item],
                               numbers: [AgentSidebar.RowID: Int])?
    private(set) var numberedBuilds = 0

    /// #1110: the rows Command-1...9 select (#1470: then Option-Command-1...9), from the list the sidebar draws: the live rows
    /// it shows, top to bottom across its sections, the first 18. A folded section's rows are not shown, so not numbered;
    /// History never is (#1785: cached).
    func numberedItems() -> [AgentSidebar.Item] { numbered.items }

    /// The numbered rows' ids.
    var numberedIDs: [AgentSidebar.RowID] { numberedItems().map(\.id) }

    /// The sidebar row's chip: its 1-based number, nil for an unnumbered row.
    func number(_ id: AgentSidebar.RowID) -> Int? { numbers[id] }

    /// #1111: every chip by row id (#1785: built with the numbered items, not per draw).
    var numbers: [AgentSidebar.RowID: Int] { numbered.numbers }

    /// ⌘<n>: the n-th numbered row, the human's pick, and the keyboard into its pane (as a click). False: no row there,
    /// nothing changes.
    @discardableResult
    func selectNumbered(_ n: Int) -> Bool {
        let items = numberedItems()
        guard n >= 1, n <= items.count, let id = items[n - 1].rows.first?.id else { return false }
        click(id)
        return true
    }


    /// The "Open in terminal" buttons: a live session only. False: nothing to open (a History
    /// row, none). QA #668 F1: nor an ended
    /// session's held row (`dch -n <name>` would start a new session of that name).
    @discardableResult
    func openSelected() -> Bool {
        guard let s = focusedLive else { return false }   // 4.3: resolved now; only `.live` opens (never `dch -n`)
        openSession(s)
        return true
    }

    // MARK: #822 Transcript | Terminal

    nonisolated static func terminalKey(_ k: AgentSessionKey) -> String { "\(k.dir)\t\(k.name)" }

    /// #1471: Terminal is the only mode. True: a live local or remote row; false: nothing can attach (History, an ended
    /// session's held row, none), so no terminal card shows where no terminal can be.
    var paneHasTerminal: Bool { !focusedEnded && (selectedRow?.session != nil || selectedRow?.remote != nil) }

    // MARK: #847 New session

    /// The form in the detail pane; nil: not shown.
    @Published private(set) var newSession: AgentNewSessionForm?
    /// Bumped by every open: the form's Name field takes the keys (⌘N on an open form too).
    @Published private(set) var newSessionFocus = 0
    /// #2058: the form's local Start, from the click until its row lands: the pane shows that session's terminal at once,
    /// typeable, while the form waits unseen (a failure brings it back with dch's line). A remote Start keeps the form.
    var launchKey: AgentSessionKey? {
        guard let k = newSession?.starting, AgentTerminalSpawn.remoteHost(k) == nil else { return nil }
        return k
    }
    /// #2058: dch answered the Start of this key: an attach for it may run its client now.
    private var launchAnswered: AgentSessionKey?
    /// A session the window started: on the refresh its row shows, it is selected in Terminal with the keys.
    /// Dropped by a manual pick, the form reopening and after `spawnSlack`.
    /// #948 F3: `asked`, the request's time (a record that landed since is this start's).
    private(set) var pendingSpawn: (key: AgentSessionKey, at: TimeInterval, asked: TimeInterval)? {
        didSet {
            spawnSeen = false
            // #887 (QA #747 INFO-1): the slack has its own deadline, not the next refresh (the 30 s age clock).
            spawnDeadline?.invalidate()
            spawnDeadline = pendingSpawn == nil || closed ? nil
                : scheduleDeadline(Self.spawnSlack + 0.5) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
        }
    }
    static let spawnSlack: TimeInterval = 15
    /// #1096 4: the deadline's timer; a test records the interval it asks for (no wall clock).
    var scheduleDeadline: (TimeInterval, @escaping @Sendable (Timer) -> Void) -> Timer = {
        let t = AgentWindowModel.makeSpawnDeadline($0, $1)
        RunLoop.main.add(t, forMode: .default)
        return t
    }
    /// #1637: the spawn deadline, built but not scheduled. The "ended at once" text lands a moment late at worst, so
    /// 10 % slack lets macOS coalesce the wakeup.
    static func makeSpawnDeadline(_ every: TimeInterval, _ fire: @escaping @Sendable (Timer) -> Void) -> Timer {
        let t = Timer(timeInterval: every, repeats: false, block: fire)
        t.tolerance = every / 10
        return t
    }
    /// #1096 1c: the store listed the pending start while the window was hidden (its sink runs, the rebuild does not).
    private(set) var spawnSeen = false
    private func seeSpawn(_ sessions: [AgentSession]) {
        guard !visible, let p = pendingSpawn, sessions.contains(where: { $0.key == p.key }) else { return }
        spawnSeen = true
    }
    /// #1096 1a: the form's start that expired unlisted; its row listing later lands it.
    private(set) var lateSpawn: AgentSessionKey?
    /// #1434 (R1096-s1): the form as it was when its start expired; an edit since keeps the late row from landing.
    private var lateForm: AgentNewSessionForm?
    /// Fires once just past `spawnSlack` after the answer; a hidden window lands or expires the spawn when shown again.
    private(set) var spawnDeadline: Timer?
    /// QA #747 INFO-1: dch --spawn answers 0 for a session whose program already exited, the same as for one that runs.
    /// #948 F3: with the end of a record of that name that landed after the start ("exit 127"), in brackets.
    /// #1096 4: `command` false (a quick shell: nothing typed): no "check the command".
    nonisolated static func notListedText(_ name: String, end: String = "", command: Bool = true) -> String {
        "\(name) ended at once or never started" + (command ? ": check the command" : "") + (end.isEmpty ? "" : " (\(end))")
    }
    /// #1434 (R1096-s1): the late row listed over a form the person edited since: it stays, and says so.
    nonisolated static func startedAfterAllText(_ name: String) -> String {
        "\(name) started after all: it is in the list"
    }
    /// #948 F3: a start that never listed, waiting for the one History read after its deadline.
    private(set) var unlisted: (key: AgentSessionKey, asked: TimeInterval)?
    /// QA #713 INFO-4: numbers every spawn; the form keeps its own (`request`), a quick shell has none.
    private var requests = 0
    /// QA #713 INFO-4 (d): the names this window spawned until the poll lists them: in flight (.infinity), then for
    /// `spawnSlack` after the answer. A second quick shell before the next poll takes the next free name.
    private var claimed: [String: TimeInterval] = [:]
    /// The island's one --spawn (its gate, runner key, env and failure line).
    lazy var spawnSession: (_ folder: String, _ command: [String], _ name: String?,
                            _ done: @escaping @MainActor @Sendable (AgentSessionKey?, String?) -> Void) -> AgentSessionKey? = {
        [weak self] in self?.island().spawn(in: $0, command: $1, name: $2, done: $3)
    }
    /// #847 D3.7: a first message into a started session, then `then`: the island controller's sayFirst (#1369).
    /// #1370 (R1369 rider): a failure seeds the draft at once when that session is the selected one (follow() seeds
    /// the others when they are selected later).
    /// #1877: `then` gets the controller's outcome (nil when sent, else why not). #1992: `codex`, a Codex session's.
    lazy var sayFirst: (_ key: AgentSessionKey, _ text: String, _ codex: Bool,
                        _ then: (@MainActor (_ notSent: String?) -> Void)?) -> Void = {
        [weak self] key, text, codex, then in
        self?.island().sayFirst(key, text, codex: codex) { @MainActor [weak self] why in
            self?.showUnsentFirst(key, selectedOnly: true)
            then?(why)
        }
    }
    /// #847 D2.4: the prompt as last typed, kept across Cancel while the window lives; a Start that takes it drops it.
    /// Never persisted: a prompt can hold anything.
    private(set) var lastPrompt = ""
    var folderExists: (String) -> Bool = { AgentIsland.isFolder($0) }
    var home = NSHomeDirectory()
    var shell = ProcessInfo.processInfo.environment["SHELL"]

    /// ⌘N, +, the empty state's pill: the form, prefilled (last folder > the selected session's cwd > ~,
    /// no name: #1731 it is typed, the island's command setting, else its inference). Open already: its Name field.
    func openNewSession(folder: String? = nil) {
        newSessionFocus += 1
        guard newSession == nil || launchKey != nil else { return }   // #2058: over a started pane, a new form
        guard store?.resumeGate.isOK == true else {   // R2 F2: the one gate check for ⌘N, + and the pill
            store?.resumeGate.refusal.map { sayOnDirLine("Controls \($0)", until: .gate) }   // #887: Command-N says why too
            return
        }
        pendingSpawn = nil
        lateSpawn = nil; lateForm = nil   // #1434 (R1096-i1): a reopened form is not the one that said it never started
        clearDirLine()   // #948 F2: the form says its own status
        let typed = Preferences.agentIslandNewSessionCommand
        newSessionTookKeys = sessionHasKeys
        newSession = AgentNewSessionForm(folder: AgentNewSession.abbreviate(folder ?? newSessionDefaultFolder, home: home),
                                         command: typed.isEmpty ? "claude" : typed,
                                         prompt: lastPrompt)   // #847 D2.4
        follow()   // P1b: the form covers the pane, so the terminal detaches (its view leaves the window)
        guard typed.isEmpty else { return }
        island().newSessionCommand { [weak self] argv in
            guard let self, var f = self.newSession, f.starting == nil, f.command == "claude" else { return }
            f.command = AgentIsland.shellLine(argv)
            self.newSession = f
        }
    }

    /// Cancel, Esc: the pane again, its terminal re-attached (a fresh client: dch redraws the screen), and the keys
    /// back in the session when the form took them from it.
    /// R2 F5: after a Start's answer (the form waits for the row), Cancel drops the pending selection too.
    func cancelNewSession() {
        if newSession?.starting != nil, pendingSpawn?.key == newSession?.starting { pendingSpawn = nil }
        newSession = nil
        follow()
        if newSessionTookKeys { focusSelection() }
    }

    /// P1b: the form opened while the keys were in the selected session (its terminal or input box) or asked for it.
    private var newSessionTookKeys = false
    private var sessionHasKeys: Bool {
        if terminal.focusPending || interaction.composerFocusPending { return true }
        let views: [NSView?] = [terminal.view, interaction.composer]
        return views.contains { v in v.map { $0.window?.firstResponder === $0 } ?? false }
    }

    var newSessionDefaultFolder: String {
        if let last = Preferences.agentWindowNewSessionFolder, folderExists(last) { return last }
        if !focusedEnded, selectedRow?.session != nil, let cwd = transcript.cwd, folderExists(cwd) { return cwd }
        return home
    }

    func setNewSessionFolder(_ s: String) { newSession?.folder = s }

    /// #1731: no generated name: an empty one (after trim) is refused at Start.
    func setNewSessionName(_ s: String) {
        newSession?.name = s
        newSession?.nameEdited = !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setNewSessionCommand(_ s: String) { newSession?.command = s }

    /// #1997: the Command menu's pick sets the whole field from that agent's setting (AgentNewSession.command).
    func pickNewSessionAgent(_ a: AgentNewSession.Agent) { setNewSessionCommand(AgentNewSession.command(for: a)) }

    /// #1809: `draft: false` (an agent's sessions.new) fills the form only: the person's kept draft stays.
    func setNewSessionPrompt(_ s: String, draft: Bool = true) {
        guard newSession != nil, newSession?.starting == nil else { return }
        newSession?.prompt = s
        newSession?.imageNote = nil   // #1836: cleared on the next edit
        if draft { lastPrompt = s }
    }

    /// #1822: where a pasted prompt image is written; nil (the XCTest default): an image paste is not taken.
    var promptImagesDir: URL? = AgentPromptImages.defaultDir

    /// #1836: an image paste's encode starts: Start waits until `addNewSessionPromptImages` ends it.
    func beginNewSessionPromptPaste() { newSession?.pasting += 1 }

    /// #1822: images written by a paste in the prompt (their paths already inserted there); thumbnails built here, on main.
    /// #1836: ends the paste's wait and sets the status line for what failed, was skipped or refused.
    /// shortcut: a form closed and reopened mid-paste takes the old paste's end as its own; upgrade if that shows.
    func addNewSessionPromptImages(_ out: AgentPromptImages.Outcome) {
        guard newSession != nil else { return }
        endNewSessionPromptPaste()
        newSession?.images += out.made.map { AgentPromptImages.Pasted(path: $0.path, thumb: $0.thumb.flatMap(NSImage.init(data:))) }
        newSession?.imageNote = out.note
    }

    /// #1863 n173 (c): a paste's end with nothing for the form (its images, its note): Start stops waiting for it.
    func endNewSessionPromptPaste() { newSession?.pasting = max(0, (newSession?.pasting ?? 0) - 1) }

    /// #1822: a chip's x: its path leaves the prompt and the chip goes (the file stays for the age prune).
    func removeNewSessionPromptImage(_ path: String) {
        guard let f = newSession, f.starting == nil else { return }
        newSession?.images.removeAll { $0.path == path }
        setNewSessionPrompt(AgentPromptImages.removing(path, from: f.prompt))
    }

    /// #1992: an interactive Codex (AgentIsland.isInteractiveCodex) on this Mac: a first prompt, no name, no images.
    var newSessionCodex: Bool {
        guard let f = newSession, f.host == nil else { return false }
        return AgentIsland.isInteractiveCodex(AgentNewSession.argv(f.command, shell: shell))
    }

    /// #1992: the form's prompt takes effect: a Claude or a Codex on this Mac.
    var newSessionTakesPrompt: Bool { newSessionClaude || newSessionCodex }

    /// #847 D6.1: an interactive Claude (AgentIsland.isInteractiveClaude, the rule naming() uses) on this Mac.
    /// shortcut: another Mac (#1323) gets no first prompt (the say seam is this Mac's); upgrade when the remote spawn
    /// learns it.
    var newSessionClaude: Bool {
        guard let f = newSession, f.host == nil else { return false }
        return AgentIsland.isInteractiveClaude(AgentNewSession.argv(f.command, shell: shell))
    }

    static let plainShellRefusal = "Clear the prompt to start a plain shell"

    /// #847 D6.2: the form's New shell would drop a typed prompt silently: refused while it holds and takes effect
    /// (#1392: the effective value, as the editor shows it; Start ignores it when not Claude).
    var newSessionShellRefusal: String? {
        guard let f = newSession,
              newSessionTakesPrompt && !f.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Self.plainShellRefusal
    }

    func chooseNewSessionFolder() {
        guard newSession?.host == nil else { return }   // #1323: this Mac's chooser; another Mac's folder is typed
        island().chooseFolder(.init(prompt: AgentIslandController.FolderAsk.choose) { [weak self] path in
            guard let self, let path, self.newSession?.starting == nil else { return }
            self.setNewSessionFolder(AgentNewSession.abbreviate(path, home: self.home))
        })
    }

    /// The live sessions' and records' names in the spawn dir, from this window's store.
    var spawnTaken: Set<String> {
        guard let store else { return [] }
        let t = now(), own = newSession?.starting?.name.lowercased()
        // R2-1: the name the open form is starting is not taken for that form (its claim, or a poll listing it early).
        return AgentIsland.spawnTaken(dir: island().spawnDir(), sessions: store.sessions, history: store.history)
            .union(claimed.filter { t - $0.value <= Self.spawnSlack }.keys).filter { $0.lowercased() != own }
    }

    // MARK: #1323 New session on another Mac

    /// The picker's hosts: every host the remote list or remote History names, sorted; none below dch 1.41.0 (no
    /// `--spawn host:name --cwd` there). Empty: no picker, this Mac only.
    var newSessionHosts: [String] {
        guard let v = store?.controlDch?.version, DchCommand.isAtLeast(v, AgentNewSession.remoteMinimum) else { return [] }
        return Set(remoteSessions.map(\.host) + remoteHistory.map(\.host)).sorted()
    }

    /// The picker's label: a host is outside text (OutsideText.shown); the form keeps it raw for argv.
    func newSessionHostLabel(_ host: String?) -> String {
        host.map(AgentSidebarRowView.hostLabel) ?? AgentNewSession.thisMac
    }

    /// The picker: the folder becomes that Mac's newest known folder (this Mac: the usual default).
    func setNewSessionHost(_ host: String?) {
        guard var f = newSession, f.starting == nil, f.host != host else { return }
        f.host = host
        f.folder = host.map { AgentNewSession.remoteRecents(host: $0, sessions: remoteSessions, history: remoteHistory).first ?? "" }
            ?? AgentNewSession.abbreviate(newSessionDefaultFolder, home: home)
        f.status = nil
        newSession = f
    }

    /// The names taken on `host`: its listed sessions' and its History records'.
    private func remoteTaken(_ host: String) -> Set<String> {
        Set(remoteSessions.filter { $0.host == host }.map(\.name) + remoteHistory.filter { $0.host == host }.map(\.record.name))
    }

    /// The remote folder as typed, trimmed (no "~": the home there is not known here).
    private var newSessionFolder: String { (newSession?.folder ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The login shell the form's empty command runs: $SHELL here; /bin/zsh on another Mac (this $SHELL may not exist there).
    private var newSessionShell: String? { newSession?.host == nil ? shell : nil }

    /// The remote start: `dch --spawn host:name --cwd <path> -- <command>` on the verb seam (the island's runner, a call of
    /// its own, never the list's). False: nothing ran.
    private func spawnRemote(_ host: String, _ argv: [String], name: String) -> Bool {
        guard let store, case .ok(let dch) = store.resumeGate else { return false }
        requests += 1
        let request = requests, key = AgentTerminalSpawn.remoteKey(host: host, name: name)
        let args = AgentNewSession.remoteArgs(host: host, name: name, cwd: newSessionFolder, command: argv)
        let started = remoteVerb(key, dch, args) { [weak self] res in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.remoteSpawned(key, request: request, res) } }
        }
        guard started else { newSession?.status = "\(name) is busy: try again"; return false }
        newSession?.starting = key
        newSession?.request = request
        newSession?.status = nil
        return true
    }

    /// dch's answer: a failure is the form's line, the form open again; success waits for the row (landSpawn), which is
    /// then selected and armed: the person's own Start.
    func remoteSpawned(_ key: AgentSessionKey, request: Int, _ res: DchActionResult) {
        guard newSession?.request == request, newSession?.starting == key else { return }   // closed or replaced meanwhile
        if let why = AgentNewSession.remoteFailure(res, host: String(key.dir.dropFirst()), name: key.name) {
            newSession?.starting = nil
            newSession?.status = why
            return
        }
        pendingSpawn = (key, now(), now())
        remoteAt = nil   // the list again at once
        remoteGap = Self.remoteEvery
        refresh()
    }

    /// #1731: the name Start uses: the typed one, trimmed. "" when none is typed: Start refuses (no generated name).
    var newSessionName: String {
        (newSession?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var newSessionErrors: (folder: String?, name: String?) {
        guard let f = newSession else { return (nil, nil) }
        if let host = f.host {
            return (AgentNewSession.remoteFolderError(newSessionFolder),
                    AgentNewSession.nameError(newSessionName, taken: remoteTaken(host), dir: island().spawnDir()))
        }
        return (AgentNewSession.folderError(AgentNewSession.expand(f.folder, home: home), exists: folderExists),
                AgentNewSession.nameError(newSessionName, taken: spawnTaken, dir: island().spawnDir()))
    }

    /// #847 D7.4: the argv that runs, `--name` included.
    var newSessionRuns: String {
        let argv = AgentIsland.naming(AgentNewSession.argv(newSession?.command ?? "", shell: newSessionShell),
                                    name: newSessionName.isEmpty ? "<name>" : newSessionName)
        return AgentIsland.shellLine(argv) + (AgentIsland.shellWords(newSession?.command ?? "").isEmpty ? " (your login shell)" : "")
    }

    var newSessionRecents: [String] {
        if let host = newSession?.host {
            return AgentNewSession.remoteRecents(host: host, sessions: remoteSessions, history: remoteHistory)
        }
        return AgentNewSession.recents(last: Preferences.agentWindowNewSessionFolder, history: store?.history ?? [], exists: folderExists)
    }

    /// The status slot: starting, else the gate's refusal, else the last failure or busy text.
    var newSessionStatus: String? {
        guard let f = newSession else { return nil }
        if let k = f.starting { return "Starting \(k.name)…" }
        if let why = store?.resumeGate.refusal { return "Controls \(why)" }
        return f.status
    }

    /// Every check, against the store as it is now.
    var canStartNewSession: Bool { !newSessionName.isEmpty && canStartNewShell }

    /// #1919: Start's checks without the Name's presence: New shell takes the folder's free name when none is typed.
    /// A typed name keeps its errors.
    var canStartNewShell: Bool {
        guard newSession?.starting == nil, (newSession?.pasting ?? 0) == 0, store?.resumeGate.isOK == true else { return false }   // #1836
        if let host = newSession?.host, !newSessionHosts.contains(host) { return false }   // #1323: gone, or dch too old
        let e = newSessionErrors
        return e.folder == nil && e.name == nil
    }

    /// Start or Return: nothing runs unless every check passes now. #1846 n132: `persist` false (an agent's start over the
    /// control channel) leaves the person's saved folder as it is. #1997: no Start saves the command (Settings does).
    @discardableResult
    func startNewSession(persist: Bool = true) -> Bool {
        guard let f = newSession, canStartNewSession else { return false }
        if let host = f.host {
            return spawnRemote(host, AgentNewSession.argv(f.command, shell: nil), name: newSessionName)
        }
        // #847 D6.1: the prompt only for a Claude (#1992: or a Codex); it never joins the spawn's argv.
        return spawn(AgentNewSession.expand(f.folder, home: home), AgentNewSession.argv(f.command, shell: shell),
                     name: newSessionName, prompt: newSessionTakesPrompt ? f.prompt : "", persist: persist)
    }

    /// ⇧⌘N, [>_] and the form's New shell: the login shell. With the form open, in its folder and name;
    /// else at once in ⌘N's folder with its free name.
    @discardableResult
    func startShell() -> Bool {
        let argv = [AgentNewSession.loginShell(shell), "-l"]
        if let f = newSession {
            guard canStartNewShell, newSessionShellRefusal == nil else { return false }
            let dir = island().spawnDir(), typed = newSessionName
            if let host = f.host {
                let name = typed.isEmpty ? AgentNewSession.shellName(folder: newSessionFolder, taken: remoteTaken(host), dir: dir) : typed
                return spawnRemote(host, [AgentNewSession.loginShell(nil), "-l"], name: name)
            }
            let folder = AgentNewSession.expand(f.folder, home: home)   // #1919: empty Name: what ⇧⌘N would pick for it
            let name = typed.isEmpty ? AgentNewSession.shellName(folder: folder, taken: spawnTaken, dir: dir) : typed
            return spawn(folder, argv, name: name)
        }
        guard store?.resumeGate.isOK == true else {
            store?.resumeGate.refusal.map { sayOnDirLine("Controls \($0)", until: .gate) }   // #887 (QA #747 INFO-3): Shift-Command-N says why
            return false
        }
        let folder = newSessionDefaultFolder
        return spawn(folder, argv, name: AgentNewSession.shellName(folder: folder, taken: spawnTaken, dir: island().spawnDir()))
    }

    private func spawn(_ folder: String, _ argv: [String], name: String, prompt: String = "",
                       persist: Bool = true) -> Bool {
        requests += 1
        unlisted = nil
        let request = newSession == nil ? nil : requests, asked = now()   // nil: a quick shell, no form's
        guard let key = spawnSession(folder, argv, name, { [weak self] key, failure in
            self?.spawned(key, failure, name: name, folder: folder, request: request, asked: asked,
                          prompt: prompt, codex: AgentIsland.isInteractiveCodex(argv), persist: persist)
        }) else {
            let why = spawnRefusal(name)
            // never dropped silently; #948 F2: a gate refusal goes when the gate opens, a name or busy one with the form
            if newSession != nil {
                newSession?.status = why
            } else {
                sayOnDirLine(why, until: store?.resumeGate.isOK == false ? .gate : nil)
            }
            return false
        }
        claimed[name] = .infinity
        newSession?.starting = key
        newSession?.request = requests
        newSession?.status = nil
        if launchKey == key {   // #2058: its pane now, before dch answers, with the keys
            follow()
            terminal.focus()
        }
        return true
    }

    /// QA #736 INFO-3: why the island refused, re-checked in its own order: the gate, the name, then the runner.
    private func spawnRefusal(_ name: String) -> String {
        if let why = store?.resumeGate.refusal ?? (store == nil ? "Agent Island is off" : nil) { return "Controls \(why)" }
        return AgentNewSession.nameError(name, taken: [], dir: island().spawnDir()) ?? "\(name) is busy: try again"
    }

    /// With no form open: the spawn dir's dir-wide line, which the window draws in its sidebar strip
    /// (AgentDirStatusStrip) and the island on its own line; the runner's failures land there too.
    /// #948 F2: the one rule for a line this window wrote there: it goes when its cause is gone (`until`: the gate opens,
    /// a session of that name lists; nil: never by itself) or the form opens, in the same fixed slot. A line the island
    /// or a later action wrote over it is not the window's any more and is left alone.
    private func sayOnDirLine(_ text: String, until cause: DirLineCause? = nil) {
        guard let store else { return }
        let key = AgentSessionKey(dir: island().spawnDir(), name: "")
        dirLine = (key, text, cause)
        store.actions[key] = text
    }

    enum DirLineCause: Equatable { case gate, listed(String) }
    /// #948 F2: the window's own dir-wide line, while it is still the one up.
    private(set) var dirLine: (key: AgentSessionKey, text: String, cause: DirLineCause?)?

    private func clearDirLine() {
        guard let l = dirLine else { return }
        dirLine = nil
        if store?.actions[l.key] == l.text { store?.actions[l.key] = nil }
    }

    /// #948 F2, on every visible refresh (the values as published): replaced or cleared, it is forgotten; its cause
    /// gone, cleared. The gate is the store's (on a publish of `sessions` alone, one publish late).
    private func expireDirLine(sessions: [AgentSession], actions: [AgentSessionKey: String]) {
        guard let l = dirLine else { return }
        guard actions[l.key] == l.text else { dirLine = nil; return }
        let gone = switch l.cause {
        case .gate?: store?.resumeGate.isOK == true
        case .listed(let name)?: sessions.contains { $0.key == AgentSessionKey(dir: l.key.dir, name: name) }
        case nil: false
        }
        // Never inside an `actions` publish (its value lands after this sink and would put the line back): the next one.
        guard gone, let store, store.actions == actions else { return }
        dirLine = nil
        store.actions[l.key] = nil
    }

    /// #948 F3: the History read after the deadline answered: a record of that name that started since the request
    /// (whole seconds: 1 s of slack) puts its end in the sentence, where the sentence still is.
    private func endUnlisted(_ history: [DchHistoryRecord]) {
        guard let u = unlisted,
              let r = history.first(where: { $0.key == u.key && !$0.end.isEmpty && $0.started >= u.asked - 1 }) else { return }
        unlisted = nil
        let end = r.end.hasPrefix("exit ") && Int(r.end.dropFirst(5)) != nil ? r.end : AgentIsland.endLabel(r.end)   // R948-n2: raw only for a number
        let plain = Self.notListedText(u.key.name), said = Self.notListedText(u.key.name, end: end)
        if newSession?.status == plain {
            newSession?.status = said
        } else if newSession == nil, let l = dirLine, l.text == Self.notListedText(u.key.name, command: false),
                  store?.actions[l.key] == l.text {   // #1096 4: the dir line is a quick shell's
            sayOnDirLine(Self.notListedText(u.key.name, end: end, command: false), until: l.cause)
        }
    }

    /// The runner's answer. Success keeps the folder (#1997: never the command, a form edit is for that form only),
    /// selects the session once its row shows (R2 F5: the form stays "Starting…" over the pane until then);
    /// failure re-enables the form with dch's line.
    /// QA #713 INFO-4: an answer touches the form only when it answers the open form's own request.
    private func spawned(_ key: AgentSessionKey?, _ failure: String?, name: String, folder: String,
                         request: Int?, asked: TimeInterval, prompt: String, codex: Bool, persist: Bool) {
        let mine = request != nil && newSession?.request == request && newSession?.starting != nil
        guard let key else {
            claimed[name] = nil
            if mine {
                newSession?.starting = nil
                newSession?.status = failure
                follow()   // #2058: the form again over the pane, its line saying why
                newSessionFocus += 1
            }
            // #1313: no form open: the island wrote the same line; the window owns it, gone when the form opens or the name lists.
            else if newSession == nil, let failure { sayOnDirLine(failure, until: .listed(name)) }
            return
        }
        claimed[name] = now()
        if persist { Preferences.agentWindowNewSessionFolder = folder }
        if request != nil {
            guard mine else { return }   // closed or replaced meanwhile: the human moved on (no message)
            newSession?.starting = key   // R2 F5: the form stays "Starting…" over the pane until the row lands
            launchAnswered = key   // #2058: its pane's client may start
            terminal.launched(key)
            if !prompt.isEmpty, prompt == lastPrompt { lastPrompt = "" }   // #847 D2.4: this start took it (#1809: not another text)
        } else if newSession != nil {
            return   // a quick shell's answer under a form opened since: the form keeps the pane
        }
        pendingSpawn = (key, now(), asked)
        refresh()
        firstMessages(main: key, prompt: prompt, codex: codex)
    }

    /// #847 D3.7: sayFirst(main, prompt); a blank prompt skips the call. The text goes only through the seam, never into
    /// the spawn's argv.
    private func firstMessages(main: AgentSessionKey, prompt: String, codex: Bool) {
        if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sayFirst(main, prompt, codex, nil) }
    }

    /// The pending spawn's row is there: Terminal (a reused name's Transcript choice dropped), selected, the keys in.
    /// #887 (QA #747 INFO-2): the row first, so a window shown again past the slack still lands a row already listed.
    private func landSpawn() {
        // #1096 1a: the row lists after the expiry: the form that still says so lands it (a second Start would make
        // a duplicate under the next free name).
        if let k = lateSpawn, let s = row(.live(k))?.session {
            lateSpawn = nil
            if newSession?.starting == nil, newSession?.status?.hasPrefix(Self.notListedText(k.name)) == true {
                // #1434 (R1096-s1): only the form as it was at the expiry (its status aside: History may add the end);
                // an edited one keeps its edits and the keys, and says the session started.
                var form = newSession
                form?.status = lateForm?.status
                if form == lateForm {
                    select(.live(s.key))   // a manual pick: the form closes
                    focusSelection()
                } else {
                    newSession?.status = Self.startedAfterAllText(k.name)
                }
            }
            lateForm = nil
        }
        guard let p = pendingSpawn else { return }
        // #1323: a remote start's row is in Other machines; selecting it is the person's pick, so it arms one attach.
        if p.key.dir.hasPrefix("@") {
            let id = AgentSidebar.RowID.remote(host: String(p.key.dir.dropFirst()), name: p.key.name)
            if row(id) != nil {
                select(id)
                focusSelection()
                return
            }
        }
        guard let s = row(.live(p.key))?.session else {
            guard !spawnSeen else {   // #1096 1c: listed while hidden, gone now: it ran and ended, it did start
                if newSession?.starting == p.key { cancelNewSession() }
                pendingSpawn = nil
                return
            }
            guard now() - p.at > Self.spawnSlack else { return }
            // QA #747 INFO-1: answered but never listed: the form stays, re-enabled, and says so; a quick shell, the dir line.
            pendingSpawn = nil
            let why = Self.notListedText(p.key.name, command: newSession != nil)   // no form: a quick shell
            if newSession?.starting == p.key {
                newSession?.starting = nil
                newSession?.status = why
                lateSpawn = p.key
                lateForm = newSession
                follow()   // #2058: the form again over the pane
            } else if newSession == nil {
                sayOnDirLine(why, until: .listed(p.key.name))
            }
            // #948 F3: one History read when the sentence is up; its records (a refresh) may name how the command ended.
            if newSession?.status == why || dirLine?.text == why {
                unlisted = (p.key, p.asked)
                island().refreshHistory()
            }
            return
        }
        pendingSpawn = nil
        select(.live(s.key))
        focusSelection()
    }

    // MARK: #829 Restart agent, Stop, Kill (ask, then act)

    /// #1289 (G5): a PR chip's way out; tests replace it (the island's seam opens nothing under XCTest).
    var openURL: @MainActor (URL) -> Void = { AgentIsland.openURL($0) }

    /// #1289 (G5): an allowlisted chip opens its URL; a chip with none opens nothing.
    func openPR(_ chip: AgentIsland.PRChip) {
        guard let url = chip.url else { return }
        openURL(url)
    }

    /// #1289 (G2/G8): Cmd-Backspace on the selected row only asks: Stop on a live session, Remove on a History record (the
    /// strip; confirm re-checks the gate and says why it runs nothing). No row selected: nothing.
    func askStopOrRemove() {
        guard let row = selectedRow else { return }
        if let s = row.session { ask(.stop, s) } else if let r = row.record { act(.remove, r) }
    }

    /// #1469: a Model or Effort item, on the store's row for `s` now (gone: nothing); every notice on that row's line.
    func switchSession(_ c: AgentModelSwitch.Command, _ s: AgentSession) {
        guard let live = store?.sessions.first(where: { $0.key == s.key }) else { return }
        let key = s.key
        interaction.switchTo(c, live) { [weak self] text in self?.refusal = AgentWindowRefusal(id: .live(key), text: text) }
    }

    /// A header "⋯" or row context-menu item: selects the row first (R6), then asks.
    func ask(_ verb: AgentWindowVerb, _ s: AgentSession) {
        if ended?.row.id == .live(s.key) { return }   // QA #668 F1, 4.4 (d): it ended, nothing to ask
        select(.live(s.key))
        refusal = nil
        renameEdit = nil
        if case .switchTo(let c) = verb { return switchSession(c, s) }
        // G4: Rename edits the title in place and asks nothing; only a session still listed live.
        if verb == .rename {
            confirming = nil
            // QA #693 INFO-3: prefilled from the store, which holds a rename's alias before the poller lists it.
            if let live = store?.sessions.first(where: { $0.key == s.key }) {
                renameEdit = AgentRenameEdit(key: s.key, text: live.alias)
                dropPendingFocus()   // QA #694 INFO-2: the field has the keys
            }
            return
        }
        confirming = AgentWindowConfirm(verb: verb, key: s.key)
    }

    /// G4: the title field's end, for the edit it was opened with. An edit that is not the open one (a
    /// replaced field's late end, on another row or this one) changes nothing. `text` nil: Esc or the focus left, nothing
    /// runs. Else Return: the session is re-read by key (gone: nothing) and the controller runs `dch -m`
    /// unless the text is its alias already. An empty text clears the alias.
    /// #853 (QA #693 INFO-4): a Return the controller refused while another job runs on the row keeps
    /// the field open with the text, and the row's line says why over the running text ("Restarting…",
    /// which store.actions keeps for the input lock) until that text goes (refresh). True: the edit goes on.
    @discardableResult
    func endRename(_ edit: AgentRenameEdit, _ text: String?) -> Bool {
        guard renameEdit === edit else { return false }   // #853 r2: a replaced edit's late end, even on the same row
        let key = edit.key
        refusal = nil
        guard let text, let s = store?.sessions.first(where: { $0.key == key }),
              AgentIsland.renameArgs(s.name, text, current: s.alias) != nil else { renameEdit = nil; return false }
        // Past the checks above, a rename not run with a control dch there is a busy row.
        guard !renameSession(s, text), store?.controlDch != nil else { renameEdit = nil; return false }
        edit.text = text
        refusal = AgentWindowRefusal(id: .live(key), text: AgentIsland.renameBusyText)
        return true
    }

    /// #829 G6-G8: a History row's context menu or detail button: selects the row first (R6).
    /// Resume, Resume (no message) and Pin/Unpin act at once (the island does not ask); Remove asks.
    func act(_ verb: AgentWindowVerb, _ r: DchHistoryRecord) {
        select(.history(r.id))
        refusal = nil
        resumeStarted = true
        switch verb {
        // #1324 (b): a remote record has Resume only (no pin, remove or no-message there: they would run here).
        case .resume where Self.isRemote(r): resumeRemote(r)
        case _ where Self.isRemote(r): break
        case .resume: resume(r)
        case .resumeNoMessage: resumeNoMessage(r)
        case .pin: pinRecord(r)
        case .remove: confirming = AgentWindowConfirm(verb: .remove, key: r.id)
        case .restart, .stop, .kill, .rename, .switchTo: break
        }
    }

    /// #1924: the pane History card's verbs. Its Resume and Resume (no message) also follow the session they start: once
    /// it lists, this pane shows it with the keys in its terminal (landResume). The sidebar's menu calls act() alone.
    /// Not armed: another machine's record (#1324: it lists in Other machines, never attached), a closed gate (nothing runs).
    func actInPane(_ verb: AgentWindowVerb, _ r: DchHistoryRecord) {
        act(verb, r)
        guard verb == .resume || verb == .resumeNoMessage, !Self.isRemote(r), let store,
              (verb == .resume ? store.resumeGate : store.reviveNoMessageGate).isOK else { return }
        guard resumeStarted, refusalText(.history(r.id)) == nil else { return }   // #1935: refused or busy: nothing to follow
        // The island's name for it: a live name revives under the first free <name>-N.
        let live = Set(store.sessions.filter { $0.key.dir == r.key.dir }.map(\.name))
        let records = Set(store.history.filter { $0.key.dir == r.key.dir && $0.key != r.key }.map(\.name))
        let name = AgentIsland.reviveAs(r, live: live, records: records) ?? r.name
        pendingResume = (AgentSessionKey(dir: r.key.dir, name: name), layout.focused, focusedTarget, r.id)
    }

    /// #1924: the card's resume waiting for its session to list; the pane and the target (the record) it was asked from.
    /// Dropped when the person moves on: a manual pick, a sidebar mouse-down (dropPendingFocus), a key typed, the window
    /// no longer key (dropPendingResume), a hidden or closed window; at the landing, another target in the focused pane
    /// (another pane focused, another layout, any pick: a layout never shows one target in two panes).
    private(set) var pendingResume: (key: AgentSessionKey, pane: UUID, target: PaneTarget?, record: AgentSessionKey)?

    func dropPendingResume() { pendingResume = nil }

    /// #1924: the resumed session listed: into the pane it was asked from (choose: the pane takes it and the keys; a
    /// .session pane that resolves to it already only takes the keys), once, and only if that pane still holds the target
    /// it was asked on.
    private func landResume() {
        guard let p = pendingResume, row(.live(p.key))?.session != nil else { return }
        pendingResume = nil
        guard p.target == focusedTarget else { return }   // moved on
        // The exact target: a pane holding the record has the session's identity too (PaneTarget.identity: the name).
        if focusedTarget == target(.live(p.key)) { focusSelection() } else { choose(.live(p.key), into: p.pane) }
    }

    /// #1324: a record from another machine (its dir is "@" + host; a socket dir is an absolute path).
    nonisolated static func isRemote(_ r: DchHistoryRecord) -> Bool { r.key.dir.hasPrefix("@") }

    /// #1324 (b): `dch --host <h> --revive <file>.json --json` (`--as` a free name when the name runs on that host), the
    /// unambiguous form: `--revive host:name` would revive a local record of that exact name (README.md:3346-3360 at
    /// v1.74.0). Never `--all`. Its text is the island's: resumingText, then rowText; the resumed session shows in
    /// "Other machines" on the next list, never attached or selected by this.
    func resumeRemote(_ r: DchHistoryRecord) {
        guard Self.isRemote(r), let store, case .ok(let dch) = store.resumeGate else { return }
        let host = String(r.key.dir.dropFirst()), key = r.id, name = r.name
        let live = Set(remoteSessions.filter { $0.host == host }.map(\.name))
        let records = Set(remoteHistory.filter { $0.host == host && $0.record.key != r.key }.map(\.record.name))
        let arg = r.recordArg(exact: true, taken: live.union(records))   // #1340: the argument reviveArgs passes
        guard AgentSidebar.remoteOK(host), let args = AgentIsland.reviveArgs(r, live: live, records: records, exact: true)
        else { return }
        let started = remoteVerb(key, dch, ["--host", host] + args) { [weak self] res in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.remoteResumed(key, name: name, arg: arg, res) } }
        }
        guard started else { return }   // busy: nothing ran, nothing shown (the island's rule)
        remoteResumeText[key] = AgentIsland.resumingText
        refresh()
    }

    /// #1324 (c): the result in the island's words; then the list and History are read again at once.
    func remoteResumed(_ key: AgentSessionKey, name: String, arg: String, _ res: DchActionResult) {
        remoteResumeText[key] = res.stopped
            ? "\(AgentIsland.Verb.resume.rawValue) cancelled: no answer in \(Int(Self.remoteReviveBound / 60))m"
            : OutsideText.shown(AgentIsland.rowText(DchControlOps.renamed(res, arg, to: name), name: name, .resume))   // R1330-s1: the other machine's text
        remoteAt = nil
        remoteHistoryAt = nil
        remoteGap = Self.remoteEvery
        refresh()
    }

    /// The asked session as it is now (nil: it ended).
    var confirmingSession: AgentSession? {
        confirming.flatMap { c in c.verb == .remove ? nil : store?.sessions.first { $0.key == c.key } }
    }


    /// The asked History record as it is now (nil: it went).
    var confirmingRecord: DchHistoryRecord? {
        confirming.flatMap { c in c.verb == .remove ? store?.history.first { $0.id == c.key } : nil }
    }

    /// R5: the open question's text, re-read from the store each draw (a gone session or record: none, no card).
    var confirmQuestion: String? {
        guard let c = confirming else { return nil }
        return confirmingSession.map { AgentWindowControls.question(c.verb, $0) }
            ?? confirmingRecord.map { AgentWindowControls.removeQuestion($0, in: store?.history ?? []) }
    }

    /// #1930: the pane the confirmation card sits over: among `shown` (tiling order), the first whose content is the
    /// asked session or record, else the focused pane.
    func confirmPane(among shown: [UUID]) -> UUID {
        guard let c = confirming else { return layout.focused }
        let row: AgentSidebar.RowID = c.verb == .remove ? .history(c.key) : .live(c.key)
        return Self.confirmPane(row, focused: layout.focused, panes: shown.map { ($0, runtimes[$0]?.content) })
    }

    nonisolated static func confirmPane(_ row: AgentSidebar.RowID, focused: UUID, panes: [(UUID, PaneContent?)]) -> UUID {
        panes.first { resolvedRow($0.1) == row }?.0 ?? focused
    }

    /// The strip's answer. The session (or record) is re-resolved by key now: gone, nothing runs;
    /// QA #665 INFO-6: its gate closed since the question, nothing runs and the row says why.
    func confirm(_ yes: Bool) {
        guard let c = confirming, let store else { confirming = nil; return }
        let s = confirmingSession, r = confirmingRecord
        confirming = nil
        guard yes else { return }
        if let r {
            if let why = AgentWindowControls.notRun(AgentWindowControls.historyMenu(r, store: store), .remove,
                                                    absent: AgentWindowControls.historyOff(.remove, r, store: store)) {
                refusal = AgentWindowRefusal(id: .history(r.id), text: why)
                return
            }
            removing = r.id
            removingPanes = layout.panes.filter { Self.resolvedRow(resolvedContent(of: $0.id, $0.target)) == .history(r.id) }
            removeRecord(r)
            return
        }
        guard let s else { return }
        if let why = AgentWindowControls.notRun(AgentWindowControls.menu(s, store: store), c.verb) {
            refusal = AgentWindowRefusal(id: .live(s.key), text: why)
            return
        }
        switch c.verb {
        case .restart: _ = restartSession(s)
        case .stop: _ = stopSession(s)   // #831 B1: the pane goes Ended, then its record by resolve (4.5)
        case .kill: _ = killSession(s)
        case .resume, .resumeNoMessage, .pin, .remove, .rename, .switchTo: break
        }
    }

    /// The refusal for the row `id`, if any.
    func refusalText(_ id: AgentSidebar.RowID) -> String? { refusal?.id == id ? refusal?.text : nil }

    func setVisible(_ v: Bool) {
        guard !closed, v != visible else { return }
        visible = v
        onVisible(v)
        if !v { stopFollow(); pendingResume = nil }   // #1555: none while hidden (close hides first); #1924
        clock?.invalidate()
        clock = nil
        if v {
            remoteGap = Self.remoteEvery   // #1634: a showing lists at dch's own pace again
            let t = Self.makeAgeClock(ageInterval) { [weak self] in self?.refresh() }
            // R1115-1: common modes, so the ages keep ticking while a scroll or a drag is tracking.
            RunLoop.main.add(t, forMode: .common)
            clock = t
            refresh()
        }
        follow()
    }

    /// #1632: the age clock, built but not scheduled (a row reads its tolerance without arming it). Ages show to the
    /// minute, so a 10 % slack lets macOS coalesce the wakeup.
    static func makeAgeClock(_ every: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> Timer {
        let t = Timer(timeInterval: every, repeats: true) { _ in MainActor.assumeIsolated { fire() } }
        t.tolerance = every / 10
        return t
    }

    /// The window closed: stop everything for good.
    func close() {
        guard !closed else { return }
        dragEnded()   // R900-5a-1: a drag under way is saved once and the terminal's hold released, before saves stop
        setVisible(false)
        closed = true
        pendingSpawn = nil   // its deadline timer goes with it
        subscription = nil
        // 11.2 "window closed: runtime freed": every pane's model stopped, then released (no pane model outlives this).
        for r in runtimes.values { r.transcript.stop(); r.terminal?.attach(nil) }
        runtimes = [:]
        restPending = [:]
        rebind()   // closed: the sinks go
        interaction.follow(nil)
        terminal.attach(nil)
    }

    /// 11.2 per pane runtime: a shown `.live` pane of a visible window runs; an Ended pane keeps its blocks suspended
    /// (4.4 (c): no IO, shown or not, hidden or not); anything else is stopped (a pane not shown holds no blocks
    /// unless Ended). Every stop and suspend comes before any start; the focused pane starts first.
    /// #900 B2 step 2 (R1193-5, 11.2, 7.4): with the split gate on, a `.live` pane of a visible window that is in the
    /// layout but not shown (zoomed away, too-small hidden) is suspended, not stopped: blocks and offset kept, one
    /// catch-up poll when shown again. A pane that left the layout was already stopped by syncRuntimes.
    /// #822: the terminal attaches to a visible, focused, live session in Terminal mode and detaches on anything else.
    /// The pane's transcript model still runs behind the terminal: the header's cwd and todos come from it.
    /// #847 D2.3, #1471 b: a first message the island could not send shows as the pane's notice (Terminal has no input
    /// box to seed). selectedOnly: only while `key` is the focused pane's live session of a visible window (follow()'s).
    private func showUnsentFirst(_ key: AgentSessionKey, selectedOnly: Bool) {
        if selectedOnly {
            guard visible, !closed, let f = focusedRuntime, f.ended == nil, case .live(let s)? = f.content, s.key == key else { return }
        }
        if let t = interaction.controller?.unsentFirst[key], unsentFirst != UnsentFirst(key: key, text: t) {
            unsentFirst = UnsentFirst(key: key, text: t)
        }
    }

    /// The notice's Dismiss: the notice goes and the island forgets the message.
    func dismissUnsentFirst() {
        guard let u = unsentFirst else { return }
        interaction.controller?.dropUnsentFirst(u.key)
        unsentFirst = nil
    }

    /// The notice's Copy: the whole raw text (newlines kept), to the app's pasteboard (tests hand in `put`).
    func copyUnsentFirst(_ put: ((String) -> Void)? = nil) {
        guard let t = unsentFirst?.text else { return }
        if let put { put(t) } else { Pasteboard.general.clearContents(); Pasteboard.general.setString(t, forType: .string) }
    }

    /// R1471b-m1: Send acts only when the focused terminal is live and attached to the notice's session (input() drops
    /// bytes with no client, and Send then forgets the text). Otherwise the notice and the record stay.
    var canSendUnsentFirst: Bool {
        guard let u = unsentFirst else { return false }
        return terminal.phase == .live && terminal.key == u.key
    }

    /// The notice's Send: the whole text as one bracketed paste, sanitized as the terminal's own paste, no Return (the
    /// person reads it in the prompt and sends it). Then as Dismiss. `write` is the focused terminal's input (tests: a recorder).
    func sendUnsentFirst(_ write: (([UInt8]) -> Void)? = nil) {
        guard canSendUnsentFirst, let t = unsentFirst?.text else { return }
        let bytes = Self.bracketedPaste(t)
        if let write { write(bytes) } else { terminal.input(bytes) }
        dismissUnsentFirst()
    }

    nonisolated static func bracketedPaste(_ text: String) -> [UInt8] {
        Array(("\u{1B}[200~" + AgentTerminalController.pasteText(text) + "\u{1B}[201~").utf8)
    }

    private func follow() {
        guard !closed else { return }
        let shown = visible ? shownPanes : []
        let keep = visible && AgentPaneLayout.splitsEnabled   // hidden or the gate off: stopped as before
        for r in runtimes.values {
            if r.ended != nil {
                r.transcript.suspend()
            } else if keep, !shown.contains(r.pane), Self.isLive(r.content) {
                r.transcript.suspend()
            } else if !shown.contains(r.pane) || !Self.isLive(r.content) {
                if r.transcript.running || r.transcript.suspended { r.transcript.stop() }
            }
        }
        for id in Self.focusedFirst(layout) where shown.contains(id) {
            guard let r = runtimes[id], r.ended == nil, case .live(let s)? = r.content else { continue }
            r.transcript.update(AgentSidebar.source(s))
            r.transcript.start()
        }
        rebind()
        if AgentPaneLayout.splitsEnabled { followUnfocusedTerminals(shown) }
        // #836 (b): a listed remote row attaches its terminal; no transcript, input box, hook or plan lookup for it.
        // #1330 (R836-q1): only when armed; a show, a restore, a re-list or the form closing shows the Attach card.
        if visible, newSession == nil, let r = focusedRemote {
            interaction.follow(nil)
            let k = AgentTerminalSpawn.remoteKey(host: r.host, name: r.name)
            if terminal.armed == k { terminal.attach(k) } else { terminal.hold(k) }
            return
        }
        // #2058: a local Start shows its own terminal at once; its client waits for dch's answer.
        if visible, let k = launchKey {
            interaction.follow(nil)
            if launchAnswered == k { terminal.attach(k, leave: .detach) } else { terminal.attachLaunching(k) }
            return
        }
        guard visible, let f = focusedRuntime, f.ended == nil, case .live(let s)? = f.content else {
            interaction.follow(nil)   // 4.4 (d): nothing on an ended pane takes input; hidden or not live: nothing
            // #1477: gate on, an Ended pane's terminal keeps its last frame (its client already gone)
            // (its pending focus dropped: the session it was asked for is gone)
            if AgentPaneLayout.splitsEnabled && focusedRuntime?.ended != nil { terminal.dropPendingFocus() } else {
                // #1790: hidden (closed into the grace, occluded): the shown client is kept with the rest, zero CPU; a
                // row not live: only the shown one goes
                terminal.attach(nil, leave: visible ? .detach : .keep)
            }
            // #1471 b: the session ended: its unsent-first notice goes with it (the record too: nothing can send it now).
            // An Ended pane holds `.notRunning` content; its session is the kept target's (settle(_:target:)).
            if let u = unsentFirst, let e = focusedRuntime?.ended, Self.rowID(e.target) == .live(u.key) {
                dismissUnsentFirst()
            }
            return
        }
        let transcript = f.transcript
        interaction.ask = transcript.pendingAsk   // this session's, never the last one's
        interaction.plan = withConfigDir(transcript.pendingPlan)
        showUnsentFirst(s.key, selectedOnly: false)
        // #822: no input box (the terminal is the input); #1471: Terminal is the only mode.
        interaction.follow(nil)
        // #847: the New session form covers the pane, so no terminal under it.
        terminal.attach(newSession == nil ? s.key : nil, leave: .detach)   // #1790: the form leaves the kept ones
    }

    /// #1477 (11.2, spec 15 C): gate on, each unfocused pane's own terminal. A shown, live local session in Terminal mode
    /// attaches after the 250 ms rest (a rest under way for the same session is not restarted; at its end the pane is
    /// checked again); an Ended pane's terminal is left as it is (its last frame, no client); anything else (hidden
    /// window, not shown, Transcript, not live) detaches now. The focused pane's terminal is follow()'s, attached at once.
    /// #1477 part b: the most recently focused panes first, each session to one pane only (the focused pane's session is
    /// taken first: two clients of one session would WINCH it each to its own size and land an OSC 52 write twice), and
    /// at most attachCap - 1 beside the focused pane's (11.3). A pane refused for either is in connectPanes. A pane that
    /// is merely not shown (zoomed away, too small) in a visible window is parked: detached, its last frame kept (11.2).
    private func followUnfocusedTerminals(_ shown: Set<UUID>) {
        if focusedAt[layout.focused] != focusTick {
            focusTick += 1
            focusedAt[layout.focused] = focusTick
        }
        var taken = Set(focusedLive.map { [$0.key] } ?? [])
        var room = Self.attachCap - 1, refused: Set<UUID> = []
        let index = Dictionary(uniqueKeysWithValues: layout.order.enumerated().map { ($1, $0) })
        let ranked = runtimes.values.sorted {
            (focusedAt[$0.pane] ?? 0, -(index[$0.pane] ?? 0)) > (focusedAt[$1.pane] ?? 0, -(index[$1.pane] ?? 0))
        }
        for r in ranked where r.pane != layout.focused && r.ended == nil {
            let want = unfocusedTerminalKey(r, shown)
            if let k = want, taken.contains(k) || room == 0 { refused.insert(r.pane) }
            // #902 (11.2 remote column): a shown, listed remote pane nobody picked since it was last shown: Connect, 0 spawns
            if want == nil, shown.contains(r.pane), paneRemote(r.pane) != nil { refused.insert(r.pane) }
            guard let k = want, !refused.contains(r.pane) else {
                restPending[r.pane] = nil
                if r.terminal?.key != nil {
                    if visible, unfocusedTerminalKey(r, Set(layout.order)) != nil { r.terminal?.park() } else {
                        r.terminal?.attach(nil, leave: visible ? .detach : .keep)   // #1790: as the focused pane's
                    }
                }
                continue
            }
            taken.insert(k)
            room -= 1
            if r.terminal?.key == k || restPending[r.pane] == k { continue }
            // another session: the old client is kept (#1790: the window-wide cap) and the rest waits
            if r.terminal?.key != nil { r.terminal?.attach(nil, leave: .keep) }
            restPending[r.pane] = k
            let id = r.pane
            paneAfter(Self.attachRest) { [weak self] in
                guard let self, self.restPending[id] == k else { return }
                self.restPending[id] = nil
                guard !self.closed, id != self.layout.focused, let r = self.runtimes[id], r.ended == nil,
                      self.unfocusedTerminalKey(r, self.visible ? self.shownPanes : []) == k else { return }
                self.paneTerminal(r).attach(k)
            }
        }
        if connectPanes != refused { connectPanes = refused }
    }

    private func unfocusedTerminalKey(_ r: AgentPaneRuntime, _ shown: Set<UUID>) -> AgentSessionKey? {
        guard shown.contains(r.pane) else { return nil }
        // #902 (11.2): a remote pane keeps its client unfocused only while the human's pick (its arm) holds, and the arm
        // goes with any detach (zoomed away, hidden, over the cap), so it never reattaches by itself; it counts in the cap.
        if let x = paneRemote(r.pane) {
            let k = AgentTerminalSpawn.remoteKey(host: x.host, name: x.name)
            return r.terminal?.armed == k ? k : nil
        }
        guard case .live(let s)? = r.content else { return nil }
        return s.key
    }

    /// #902: pane `pane`'s remote session while the remote list has it; nil for any other target (a remote target the
    /// list lacks stays "isn't running", 4.1).
    func paneRemote(_ pane: UUID) -> AgentSidebar.Remote? {
        guard case let .remote(h, n)? = layout.panes.first(where: { $0.id == pane })?.target else { return nil }
        return row(.remote(host: h, name: n))?.remote
    }

    /// #902 (11.2, 11.3): Connect on an unfocused pane is the human's pick: a remote pane's attach is armed, then the pane
    /// takes the focus (and so attaches, the least recently focused other pane going over the cap).
    func connectPane(_ pane: UUID) {
        if let x = paneRemote(pane), let r = runtimes[pane] {
            paneTerminal(r).arm(AgentTerminalSpawn.remoteKey(host: x.host, name: x.name))
        }
        focusPane(pane)
    }

    /// 11.2: the start order, the focused pane first, then the others in tree order.
    nonisolated static func focusedFirst(_ l: PaneLayout) -> [UUID] { [l.focused] + l.order.filter { $0 != l.focused } }

    nonisolated static func isLive(_ c: PaneContent?) -> Bool {
        if case .live? = c { return true }
        return false
    }
}


/// #1923 (operator 2026-11-24): the Full sidebar's width (Slide's overlay too), dragged at its 1 pt line. Remembered per Mac
/// (Preferences.agentSidebarWidth) in points at UI scale 1.0 and drawn times the scale: never under TIP's width
/// (AgentWindowModel.fullSidebarWidth), never over `share` of the window's content (the minimum wins), and in a window
/// below its minimum never so wide that the panes lose their last `strip`. Observed by the sidebar column alone, so a
/// drag redraws that column and the layout, not the model's other views.
@MainActor
final class AgentSidebarWidth: ObservableObject {
    static let share: CGFloat = 0.4
    /// The panes' least visible width (·s units): #1925 the window's minimum keeps it beside the sidebar column
    /// (AgentsWindow.contentMinSize), and a window still under that (an old frame) never loses it to the sidebar.
    static let strip: CGFloat = 40
    @Published private(set) var points: CGFloat? = Preferences.agentSidebarWidth.map { CGFloat($0) }
    /// The root view's content width (AgentWindowRootView writes it on a change; 0: not measured, the minimum is drawn).
    /// Publishes only when the drawn width moves, so a window resize while under the 40% line redraws nothing here.
    var content: CGFloat = 0 {
        didSet { if Self.width(stored: points, content: content) != Self.width(stored: points, content: oldValue) { objectWillChange.send() } }
    }
    /// The drawn width when the drag began; nil between drags.
    private var start: CGFloat?
    var dragging: Bool { start != nil }
    var drawn: CGFloat { Self.width(stored: points, content: content) }

    /// The drawn width for `stored` points (nil: the minimum) in a content `content` wide, at the current UI scale.
    static func width(stored: CGFloat?, content: CGFloat) -> CGFloat {
        let least = AgentWindowModel.fullSidebarWidth
        guard content > 0 else { return least }
        let w = max(least, min((stored ?? 0) * ThemeRuntime.scale, content * share))
        return max(0, min(w, content - 1 - sz(strip)))
    }

    /// The line moved `dx` points since the drag began (right is positive: wider). Kept clamped; published only on a change.
    func dragged(by dx: CGFloat) {
        let from = start ?? drawn
        start = from
        let p = Self.width(stored: (from + dx) / ThemeRuntime.scale, content: content) / ThemeRuntime.scale
        if p != points { points = p }
    }

    /// The drag is over: the width is written once (while dragging only the in-memory value moves).
    func ended() {
        start = nil
        if let points { Preferences.agentSidebarWidth = Double(points) }
    }
}
