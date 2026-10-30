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

struct AgentSession: Equatable, Identifiable {
    let key: AgentSessionKey
    let alias: String
    /// Last pty output, seconds since 1970. Refreshed every tick from the stat'd
    /// `.sock.act` mtime, so the age ticks without a dch fork.
    var activity: TimeInterval
    let state: AgentState
    let agents: Int
    /// #506: dch 1.22's `meta` (open PRs, task counts); nil from older dch or none set.
    var meta: DchSessionMeta? = nil
    /// #578: its master's dch version, "" when too old to say (the control gate).
    var version: String = ""

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
/// Row details). Per Mac, never synced. prosper-ios (#533) has the same six
/// labels and defaults: Agents, Open PRs and Merged on; Tasks done, In progress
/// and Queued off, so a fresh install draws no task summary on line 2.
/// #587: Session name (the dch name beside an alias on line 2) is Mac only, off.
/// The pure functions below take it as a parameter and never read defaults.
struct AgentIslandRowDetails: Equatable {
    var agents = true
    var openPRs = true
    var merged = true
    var tasksDone = false
    var inProgress = false
    var queued = false
    var sessionName = false

    static let all = AgentIslandRowDetails(agents: true, openPRs: true, merged: true,
                                           tasksDone: true, inProgress: true, queued: true, sessionName: true)
}

/// #571: Settings › Agent Island › Sort sessions. Per Mac, never synced.
enum AgentIslandSort: String, CaseIterable {
    case activity, name

    /// Unset or unknown = last activity, the order before the setting existed.
    init(raw: String?) { self = raw.flatMap(Self.init(rawValue:)) ?? .activity }

    var label: String {
        switch self {
        case .activity: "Last activity"
        case .name: "Name"
        }
    }
}

enum AgentIsland {
    // MARK: - Display

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

    // MARK: - Sidekicks (#571, prosper-ios DchSession.split)

    static let sidekickDefault = "-qa"

    typealias Split = (primary: [AgentSession], sidekicks: [AgentSession])

    /// A sidekick's name or alias contains `pattern` (trimmed), case-insensitive.
    /// An empty pattern means no split. Order is kept in both halves.
    static func split(_ list: [AgentSession], pattern: String) -> Split {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return (list, []) }
        let isSidekick = { (s: AgentSession) in [s.name, s.alias].contains { $0.range(of: p, options: .caseInsensitive) != nil } }
        return (list.filter { !isSidekick($0) }, list.filter(isSidekick))
    }

    /// Never without sidekicks; always when they are all there is; else the chosen tab.
    static func showsSidekicks(_ split: Split, tab: Bool) -> Bool {
        !split.sidekicks.isEmpty && (tab || split.primary.isEmpty)
    }

    /// 12s, 4m, 2h, 3d — whole units, rounded down. Nothing for an unknown time.
    static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    static func age(of s: AgentSession, now: TimeInterval) -> String {
        s.activity > 0 ? age(now - s.activity) : ""
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

    /// #587: the grey dch name after the state label: only with Session name on,
    /// and only beside an alias (with no alias the title already is the name).
    static func sessionNameLabel(_ s: AgentSession, show d: AgentIslandRowDetails) -> String? {
        sessionNameLabel(title: s.title, name: s.name, show: d)
    }

    /// #592: the same rule for a History row (title from alias or agent name).
    static func sessionNameLabel(_ r: DchHistoryRecord, show d: AgentIslandRowDetails) -> String? {
        sessionNameLabel(title: r.title, name: r.name, show: d)
    }

    static func sessionNameLabel(title: String, name: String, show d: AgentIslandRowDetails) -> String? {
        d.sessionName && title != name ? name : nil
    }

    /// #592: a History row's VoiceOver text; the dch name only when the row draws it.
    static func historyAccessibilityLabel(_ r: DchHistoryRecord, line2: String, age: String, cwd: String,
                                          show d: AgentIslandRowDetails) -> String {
        ([r.title, line2, sessionNameLabel(r, show: d), age.isEmpty ? nil : "\(age) ago", cwd] as [String?])
            .compactMap { $0 }.joined(separator: ", ")
    }

    static func rowAccessibilityLabel(_ s: AgentSession, now: TimeInterval, show d: AgentIslandRowDetails = .all) -> String {
        let age = age(of: s, now: now)
        let (chips, more) = prChips(s.meta, show: d, budget: .infinity)
        let prs = chips.map(\.fullName).joined(separator: ", ") + (more > 0 ? " and \(more) more pending PR\(more == 1 ? "" : "s")" : "")
        return [s.title, s.state.label, age.isEmpty ? nil : "\(age) ago", metaSummary(s.meta, show: d), mergedLabel(s.meta, show: d),
                chips.isEmpty ? nil : "open pull requests " + prs]
            .compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: - Session meta (#506)

    /// Every count the row draws: "99999+" above 99999, so a runaway number
    /// cannot squeeze the title. done > total is drawn as is.
    static func count(_ n: Int) -> String { n > 99_999 ? "99999+" : "\(n)" }

    /// The second line's "22/26 done · 2 in progress · 2 queued": zero and
    /// unknown parts left out, and (#534) the parts toggled off; nil when nothing
    /// is left (the row looks as before).
    static func metaSummary(_ m: DchSessionMeta?, show d: AgentIslandRowDetails = .all) -> String? {
        guard let t = m?.tasks else { return nil }
        var parts: [String] = []
        if d.tasksDone, let total = t.total, total > 0 { parts.append("\(count(t.done ?? 0))/\(count(total)) done") }
        if d.inProgress, let n = t.inProgress, n > 0 { parts.append("\(count(n)) in progress") }
        if d.queued, let n = t.queued, n > 0 { parts.append("\(count(n)) queued") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "18 merged", right-aligned on the PR line; nil for none or Merged off.
    static func mergedLabel(_ m: DchSessionMeta?, show d: AgentIslandRowDetails = .all) -> String? {
        guard d.merged, let n = m?.merged, n > 0 else { return nil }
        return "\(count(n)) merged"
    }

    /// #525: a row draws a third line, the PR line, only for open PRs with a
    /// label or a merged count; `prChips` and the row height agree through this.
    /// #534: only the ones toggled on count, so a row with neither is 48 pt again.
    static func hasPRLine(_ m: DchSessionMeta?, show d: AgentIslandRowDetails) -> Bool {
        (d.openPRs && (m?.openPRs.contains { $0.label != nil } ?? false)) || mergedLabel(m, show: d) != nil
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
    /// next to the worst "+NN pending PRs" and "99999+ merged" (tested).
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
        let budget = budget - (mergedLabel(m, show: d).map { chipWidth($0) - 2 * chipInset + mergedGap } ?? 0)
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
                     run: Runner = { DchCommand.runIsland(args: $0, env: $1) }) -> [AgentSession] {
        dirs.flatMap { dir -> [AgentSession] in
            let env = listEnv(dir: dir)
            var rows = DchCommand.parseListJSON(run(["--ls-json"], env) ?? Data())
            if rows.isEmpty {
                guard let tsv = run(["-lj"], env) else { return previous.filter { $0.key.dir == dir } }
                rows = DchCommand.parseListTSV(String(decoding: tsv, as: UTF8.self))
            }
            return rows.map {
                AgentSession(key: AgentSessionKey(dir: dir, name: $0.name), alias: $0.alias,
                             activity: TimeInterval($0.activityEpoch), state: AgentState(dch: $0.state),
                             agents: $0.agents, meta: $0.meta, version: $0.version)
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

/// What a row click does with a session that has no local terminal window.
enum AgentIslandClick: String, CaseIterable {
    case open, copy

    /// Unset or unknown = open.
    init(raw: String?) { self = raw.flatMap(Self.init(rawValue:)) ?? .open }

    var label: String {
        switch self {
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
/// `dch --meta`'s PRs and tasks (.meta, #506).
struct AgentSidecarStamp: Equatable {
    var act: TimeInterval?
    var state: TimeInterval?
    var alias: TimeInterval?
    var meta: TimeInterval?
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
            // A dir that does not exist yet (isolation never used) is no sessions.
            guard let m = Self.mtime(dir) else { cache[dir] = nil; continue }
            if cache[dir]?.mtime != m {
                let names = readDir(dir)
                cache[dir] = (m, names.filter { $0.hasSuffix(".sock") }.map { String($0.dropLast(5)) })
            }
            for name in cache[dir]?.names ?? [] {
                let base = "\(dir)/\(name).sock"
                snap[AgentSessionKey(dir: dir, name: name)] = AgentSidecarStamp(
                    act: Self.mtime(base + ".act"), state: Self.mtime(base + ".state"),
                    alias: Self.mtime(base + ".alias"), meta: Self.mtime(base + ".meta"))
            }
        }
        cache = cache.filter { dirs.contains($0.key) }
        return snap
    }

    static func mtime(_ path: String) -> TimeInterval? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9
    }
}

/// When to fork `dch --ls-json`. Clock is wall time, the same clock as the mtimes.
struct AgentPollGate {
    static let floor: TimeInterval = 2       // never more often
    static let backstop: TimeInterval = 10   // never less often while sessions exist
    static let trailing: TimeInterval = 2    // re-read after a change: a blocker can be mid-render
    /// dch says "working" while now - act <= 5 s (whole seconds), so a session
    /// that stops printing turns idle at floor(act) + 6 without touching a file.
    static let idleAfter: TimeInterval = 6

    private(set) var lastFetch: TimeInterval?
    private var seen: AgentDirSnapshot?
    private var trailingAt: TimeInterval?
    private var idleAt: TimeInterval?

    func shouldFetch(_ snap: AgentDirSnapshot, now: TimeInterval) -> Bool {
        guard let last = lastFetch else { return true }
        guard now - last >= Self.floor else { return false }
        return snap != seen || now - last >= Self.backstop
            || trailingAt.map { now >= $0 } == true || idleAt.map { now >= $0 } == true
    }

    mutating func didFetch(_ snap: AgentDirSnapshot, sessions: [AgentSession], now: TimeInterval) {
        let changed = snap != seen
        trailingAt = changed ? now + Self.trailing : nil
        // The earliest still-working session's idle flip; one already past it is
        // working for another reason (a hook report) and arms nothing.
        idleAt = sessions.filter { $0.state == .working }
            .compactMap { snap[$0.key]?.act.map { $0.rounded(.down) + Self.idleAfter } }
            .filter { $0 > now }.min()
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
        let snap = scanner.scan(dirs)
        let t = now()
        if snap.isEmpty {
            // Nothing to list: no fork, and the next session to appear fetches at once.
            fetched = []
            gate = AgentPollGate()
        } else if gate.shouldFetch(snap, now: t) {
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
