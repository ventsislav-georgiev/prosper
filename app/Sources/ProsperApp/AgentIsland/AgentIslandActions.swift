// Agent Island session controls (#578, phase 1a): the History tab's records
// (`dch --history --json`), Resume (`dch --revive`), and the runner every long
// dch verb goes through. Pure or seamed like AgentIslandModel: no test runs a
// real dch. The binary these verbs run with is DchCommand.controlDch(), gated
// by DchCommand.gate.

import Darwin
import Foundation

/// One `dch --history --json` record, keyed like a live session (socket dir, name).
/// Unknown fields are ignored and missing ones read as empty or 0.
struct DchHistoryRecord: Equatable, Identifiable {
    struct Agent: Equatable {
        var kind = "", sessionID = "", name = "", cwd = ""
        var launch: [String] = []
    }

    let key: AgentSessionKey
    var alias = ""
    var cwd = ""
    var argv: [String] = []
    var started: TimeInterval = 0
    var updated: TimeInterval = 0
    /// 0 while running, or after a master that died without a word.
    var ended: TimeInterval = 0
    /// "exit N", "signal N", "killed" (dch -k), "stopped" (--stop, 1.24.0), "vanished"
    /// ("" reads as vanished). endLabel puts them in words.
    var end = ""
    var agent: Agent?
    /// #605: dch 1.25.0's `--pin`: kept by every prune and by `--forget --all`.
    var pinned = false

    var id: AgentSessionKey { key }
    var name: String { key.name }
    /// #592: display only (revive, keys and sorting use `name`): the alias, else
    /// the agent's session name, else the dch name, like a Sessions row's title.
    var title: String {
        if !alias.isEmpty { return alias }
        if let a = agent?.name, !a.isEmpty { return a }
        return key.name
    }
    /// dch's own "last seen": ended, else updated.
    var lastSeen: TimeInterval { ended > 0 ? ended : updated }
}

/// #580: one `--json` stdout line of a long verb (dch 1.24.0's "Machine-readable
/// output"). A phase is {"name","phase"}; a result {"name","result","reason",
/// "detail","session_id"} (`--revive` adds "as"); --restart's master pass
/// carries both, with phase "master". Missing fields decode as nil.
struct DchJSONLine: Decodable, Equatable, Sendable {
    var name: String
    var phase: String?
    var result: String?
    var reason: String?
    var detail: String?
    var revivedAs: String?
    var sessionID: String?

    enum CodingKeys: String, CodingKey {
        case name, phase, result, reason, detail
        case revivedAs = "as", sessionID = "session_id"
    }

    /// QA #452: a result is an object with "result" and no "phase", or phase
    /// "master"; any other object with a "phase" is progress.
    var isMaster: Bool { phase == "master" && result != nil }
    /// A step on the way ("pausing", "starting", …), never a result.
    var isPhase: Bool { phase != nil && phase != "master" }
    /// One session's result (an agent's, for --restart); the master pass is not one.
    var isFinal: Bool { result != nil && phase == nil }
    var failed: Bool { result == "failed" || result == "interrupted" }
}

/// One finished long verb. `json`: its NDJSON objects in order; `text`: every
/// other non-empty line, trimmed (stderr's human text; all of --spawn's).
/// `stopped`: the bound expired and the runner sent its one SIGTERM.
struct DchActionResult: Equatable, Sendable {
    let status: Int32
    var json: [DchJSONLine] = []
    var text: [String] = []
    var stopped = false

    var line: String { text.last ?? "" }
    /// QA #449 L1: the reason behind a failure no result names.
    var dchLine: String? { text.last { $0.hasPrefix("dch: ") } }
}

extension AgentIsland {
    // MARK: - History

    /// #580: every control (and the History read) needs dch 1.24.0: --json, and
    /// --stop. Also a row's master minimum for Stop (a 1.23.x master records the
    /// stop as a crash).
    static let controlMinimum = [1, 24, 0]
    /// #580 addendum 2: Restart agent, Restart all and Stop need 1.24.1. 1.24.0
    /// sends /exit to a claude typed into a session's shell, and the shell then
    /// runs whatever followed it (`claude && git push`); 1.24.1 skips that case
    /// (reason in_shell) and its --stop never types /exit there.
    static let restartMinimum = [1, 24, 1]

    /// A risky verb's label while the control dch is under `restartMinimum`.
    static func label(_ label: String, needs: String?) -> String { needs.map { "\(label) (\($0))" } ?? label }
    /// #605: --pin, --unpin and --forget (the History tab's pin, X and Clear unpinned).
    static let historyEditMinimum = [1, 25, 0]
    /// The History tab lists this many records in all, newest first, unless more
    /// are pinned: pinned ones are never capped, unpinned ones fill the rest.
    static let historyCap = 50

    /// #605: the History tab's rows: every pinned record (never capped), then
    /// unpinned ones up to `historyCap` minus the pinned count; each part newest
    /// first (`history` is).
    static func cappedHistory(_ history: [DchHistoryRecord]) -> [DchHistoryRecord] {
        let pinned = history.filter(\.pinned)
        return pinned + history.filter { !$0.pinned }.prefix(max(0, historyCap - pinned.count))
    }

    static func parseHistory(_ data: Data, dir: String) -> [DchHistoryRecord] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        func num(_ v: Any?) -> TimeInterval { (v as? NSNumber)?.doubleValue ?? 0 }
        func strings(_ v: Any?) -> [String] { (v as? [Any])?.compactMap { $0 as? String } ?? [] }
        return rows.compactMap { o in
            guard let name = o["name"] as? String, !name.isEmpty else { return nil }
            let a = o["agent"] as? [String: Any]
            return DchHistoryRecord(
                key: AgentSessionKey(dir: dir, name: name), alias: o["alias"] as? String ?? "",
                cwd: o["cwd"] as? String ?? "", argv: strings(o["argv"]), started: num(o["started"]),
                updated: num(o["updated"]), ended: num(o["ended"]), end: o["end"] as? String ?? "",
                agent: a.map {
                    .init(kind: $0["kind"] as? String ?? "", sessionID: $0["session_id"] as? String ?? "",
                          name: $0["name"] as? String ?? "", cwd: $0["cwd"] as? String ?? "", launch: strings($0["launch"]))
                }, pinned: o["pinned"] as? Bool ?? false)
        }
    }

    /// Every dir's records, newest first (dch's array is not in end order: a
    /// vanished record has ended 0). `run` is bound to the control binary.
    static func history(dirs: [String], run: Runner) -> [DchHistoryRecord] {
        dirs.flatMap { parseHistory(run(["--history", "--json"], listEnv(dir: $0)) ?? Data(), dir: $0) }
            .sorted { $0.lastSeen != $1.lastSeen ? $0.lastSeen > $1.lastSeen : ($0.name, $0.key.dir) < ($1.name, $1.key.dir) }
    }

    /// #585: the end in neutral words; nothing the user did on purpose reads as
    /// a crash. "closed" (dch -k), "stopped", "exited" / "exited (N)", "ended
    /// (signal N)" for TERM, HUP and INT (also logout and reboot), "crashed
    /// (signal N)" for any other signal, "vanished" ("" too); else as dch wrote it.
    static func endLabel(_ end: String) -> String {
        switch end {
        case "", "vanished": return "vanished"
        case "killed": return "closed"
        case "exit 0": return "exited"
        case "signal 15", "signal 1", "signal 2": return "ended (\(end))"
        default:
            if end.hasPrefix("signal ") { return "crashed (\(end))" }
            if end.hasPrefix("exit ") { return "exited (\(end.dropFirst(5)))" }
            return end
        }
    }

    /// #585: dch's own `--revive --all` rule (rv_all_takes, dch 1.24.1): an
    /// abnormal end (not exit 0, killed or stopped; vanished counts), last seen
    /// within 3 days, after running at least 5 minutes (last seen minus started).
    static func reviveAllTakes(_ r: DchHistoryRecord, now: TimeInterval) -> Bool {
        !["exit 0", "killed", "stopped"].contains(r.end)
            && r.lastSeen >= now - 3 * 86400 && r.lastSeen - r.started >= 5 * 60
    }

    /// `--revive <name>`; a name live now goes to `--as` the first free
    /// `<name>-2`, `-3`, … — free of live sessions and of other records in the dir
    /// (dch would overwrite that record).
    static func reviveArgs(_ r: DchHistoryRecord, live: Set<String>, records: Set<String>) -> [String]? {
        guard live.contains(r.name) else { return named("--revive", [r.name]) }
        return named("--revive", [r.name], ["--as", freeName(r.name, taken: live.union(records)), "--json"])
    }

    /// #627: dch takes a session name that starts with '-' and its argv has no
    /// "--", so a record named "--all" makes `--forget <name>` `--forget --all`.
    static func passable(_ name: String) -> Bool { !name.hasPrefix("-") }

    /// Every verb that names sessions builds its argv here: `verb names… rest`,
    /// nil (nothing runs) when any name is not `passable`.
    static func named(_ verb: String, _ names: [String], _ rest: [String] = ["--json"]) -> [String]? {
        names.allSatisfy(passable) ? [verb] + names + rest : nil
    }

    /// Resume interrupted. dch skips stopped, killed and exit 0 records itself.
    static let reviveAllArgs = ["--revive", "--all", "--json"]

    /// `name` when free, else the first free `<name>-2`, `-3`, ….
    static func freeName(_ name: String, taken: Set<String>) -> String {
        taken.contains(name) ? (2...).lazy.map { "\(name)-\($0)" }.first { !taken.contains($0) }! : name
    }

    // MARK: - Restart (#579)

    static let restartingText = "Restarting…"
    static let restartAllRunningText = "Restarting stale agents…"
    static let restartLabel = "Restart agent"
    static let restartAllLabel = "Restart all agents"
    static let restartAllQuestion = "Restart stale agents? Each pauses for up to minutes."

    /// An explicit row click: `-f`, so a current agent restarts too.
    static func restartArgs(_ name: String) -> [String]? { named("--restart", [name], ["--include-agents", "-f", "--json"]) }
    /// No `-f`: only stale agents restart.
    static let restartAllArgs = ["--restart", "--all", "--include-agents", "--json"]

    // MARK: - --json results (#580)

    /// A row's verb: its done word and the minutes of its bound.
    enum Verb: String {
        case restart = "Restart", stop = "Stop", resume = "Resume"
        /// #605: a History row's pin toggle and X, and Clear unpinned.
        case pin = "Pin", unpin = "Unpin", remove = "Remove", clear = "Clear"

        var done: String {
            switch self {
            case .restart: "Restarted"
            case .stop: "Stopped"
            case .resume: "Resumed"
            case .pin: "Pinned"
            case .unpin: "Unpinned"
            case .remove: "Removed"
            case .clear: "Cleared"
            }
        }
        var minutes: Int { Int((self == .restart || self == .stop ? DchActionRunner.restartBound : DchActionRunner.bound) / 60) }
    }

    /// One output line as a --json object; nil for anything else (stderr's text,
    /// a stray line, an object with neither a phase nor a result).
    static func jsonLine(_ line: String) -> DchJSONLine? {
        guard line.hasPrefix("{"), let o = try? JSONDecoder().decode(DchJSONLine.self, from: Data(line.utf8)),
              o.phase != nil || o.result != nil else { return nil }
        return o
    }

    /// A phase as a row's running text: "Pausing…", "Exiting…", "Relaunching…",
    /// "Resuming…", "Starting…", "Ending…"; nil for a result or the master pass.
    static func phaseText(_ o: DchJSONLine) -> String? {
        guard o.isPhase, let p = o.phase, phaseWords.contains(p) else { return nil }
        return p.prefix(1).uppercased() + p.dropFirst() + "…"
    }

    static let phaseWords = ["pausing", "exiting", "relaunching", "resuming", "starting", "ending"]

    /// The texts a row shows while a job runs; a dir job clears any left when it ends.
    static var runningTexts: Set<String> {
        Set(phaseWords.map { $0.prefix(1).uppercased() + $0.dropFirst() + "…" } + [restartingText, stoppingText, resumingText])
    }

    /// A result as its row's text: a short word for ok, else dch's detail
    /// without a leading "<name>: ".
    static func finalText(_ o: DchJSONLine, _ verb: Verb) -> String {
        if o.result == "ok" {
            guard verb == .resume else { return verb.done }
            if o.reason == "no_screen" { return "Resumed (resume message not typed)" }   // dch-lite
            if let a = o.revivedAs, !a.isEmpty, a != o.name { return "Resumed as \(a)" }
            return "Resumed"
        }
        let detail = o.detail ?? ""
        let d = detail.hasPrefix(o.name + ": ") ? String(detail.dropFirst(o.name.count + 2)) : detail
        return d.isEmpty ? "\(verb.rawValue) \(o.result ?? "failed") (\(o.reason ?? ""))" : d
    }

    /// "failed: <last dch: line>", else "failed (exit N)".
    static func failedText(_ r: DchActionResult) -> String {
        r.dchLine.map { "failed: \($0)" } ?? "failed (exit \(r.status))"
    }

    /// A one-row job's text: its last result for `name` (for --restart the
    /// agent's, else the master pass's), else the exit.
    static func rowText(_ r: DchActionResult, name: String, _ verb: Verb) -> String {
        if r.stopped { return "\(verb.rawValue) cancelled: no answer in \(verb.minutes)m" }
        if let f = r.json.last(where: { $0.name == name && ($0.isFinal || $0.isMaster) }) { return finalText(f, verb) }
        return r.status == 0 ? verb.done : "\(verb.rawValue) \(failedText(r))"
    }

    /// Restart all's one line: the masters moved to this dch, the agents
    /// restarted, failed and skipped (not_claude and current are no skip), else
    /// "all agents current". A non-zero exit no result explains reads as failed.
    static func restartAllSummary(_ r: DchActionResult) -> String {
        if r.stopped { return "Restart all cancelled: no answer in \(Verb.restart.minutes)m" }
        let masters = r.json.filter(\.isMaster), agents = r.json.filter(\.isFinal), all = masters + agents
        let moved = masters.filter { $0.result == "ok" }
        let restarted = agents.filter { $0.result == "ok" }.count
        let failed = all.filter(\.failed).count
        let skipped = all.filter { $0.result == "skipped" && !["not_claude", "current"].contains($0.reason ?? "") }.count
        let other = r.status != 0 && failed == 0 ? failedText(r) : nil
        guard !moved.isEmpty || restarted + failed > 0 else {
            if let other { return "Restart all \(other)" }
            return "all agents current" + (skipped > 0 ? " (\(skipped) skipped)" : "")
        }
        let dch = moved.last?.detail.flatMap { $0.isEmpty ? nil : $0 } ?? "restarted"
        return [moved.isEmpty ? nil : "\(moved.count) session\(moved.count == 1 ? "" : "s") \(dch)",
                restarted > 0 ? "\(restarted) agent\(restarted == 1 ? "" : "s") restarted" : nil,
                failed > 0 ? "\(failed) failed" : nil, skipped > 0 ? "\(skipped) skipped" : nil, other]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// Resume interrupted's and Stop all's one line: "N resumed|stopped, N failed,
    /// N skipped"; `empty` when dch named no session and exited 0.
    static func tally(_ r: DchActionResult, _ verb: Verb, title: String, empty: String) -> String {
        if r.stopped { return "\(title) cancelled: no answer in \(verb.minutes)m" }
        let finals = r.json.filter(\.isFinal)
        let failed = finals.filter(\.failed).count
        let other = r.status != 0 && failed == 0 ? failedText(r) : nil
        let parts = [(finals.filter { $0.result == "ok" }.count, verb.done.lowercased()), (failed, "failed"),
                     (finals.filter { $0.result == "skipped" }.count, "skipped")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        if parts.isEmpty { return other.map { "\(title) \($0)" } ?? empty }
        return (parts + [other].compactMap { $0 }).joined(separator: ", ")
    }

    // MARK: - Pin, Remove and Clear unpinned (#605)

    static let pinLabel = "Pin"
    static let unpinLabel = "Unpin"
    static let removeLabel = "Remove from History"
    static let clearUnpinnedLabel = "Clear unpinned"
    static let clearingText = "Clearing…"

    static func clearQuestion(_ n: Int) -> String { "Clear \(n) unpinned?" }

    /// `--pin|--unpin <name> --json`; `--forget <name> --json`, never -f (a pin protects).
    static func pinArgs(_ name: String, pin: Bool) -> [String]? { named(pin ? "--pin" : "--unpin", [name]) }
    static func forgetArgs(_ name: String) -> [String]? { named("--forget", [name]) }
    /// Every record neither live nor pinned; dch skips those (-f is a usage error here).
    static let forgetAllArgs = ["--forget", "--all", "--json"]

    /// A pin, unpin or remove's line for its dir's status; nil when it worked.
    /// dch's detail for a failed result (io_error's is the OS error), else the exit.
    static func editFailure(_ r: DchActionResult, name: String, _ verb: Verb) -> String? {
        let what = "\(verb.rawValue) \(name)"
        if r.stopped { return "\(what) cancelled: no answer in \(verb.minutes)m" }
        if let f = r.json.first(where: { $0.isFinal && $0.failed }) {
            if f.reason == "pinned" { return "\(what) failed: pinned, unpin it first" }
            let d = f.detail ?? ""
            return "\(what) failed: \(d.isEmpty ? f.reason ?? "" : d)"
        }
        return r.status == 0 ? nil : "\(what) \(failedText(r))"
    }

    // MARK: - Stop (#580)

    static let stopLabel = "Stop"
    static let stopOldMasterLabel = "Stop (restart this session first)"
    static let stoppingText = "Stopping…"

    static func stopAllLabel(tab: String) -> String { "Stop all in \(tab)…" }

    static func stopAllQuestion(_ n: Int, skipped: Int) -> String {
        "Stop \(n) session\(n == 1 ? "" : "s")?" + (skipped > 0 ? " \(skipped) on an old dch skipped." : "")
    }

    /// Named sessions only, never `--all`.
    static func stopArgs(_ names: [String]) -> [String]? { named("--stop", names) }

    /// A row's master can stop: its --ls-json version reads >= 1.24.0, compared
    /// numerically. A 1.23.x master records a stop as a crash; "" is too old to say.
    static func canStop(_ s: AgentSession) -> Bool {
        !s.version.isEmpty && DchCommand.isAtLeast(DchCommand.masterVersion(s.version), controlMinimum)
    }

    // MARK: - New session (#579)

    static let newSessionLabel = "New session"
    static let chooseFolderLabel = "Choose folder…"
    static let recentFoldersMax = 8

    /// A record's folder: its Claude agent's cwd, else the session's.
    static func folder(_ r: DchHistoryRecord) -> String {
        if let c = r.agent?.cwd, !c.isEmpty { return c }
        return r.cwd
    }

    /// Distinct folders of the agent records that still exist, newest first
    /// (`history` is), at most 8. One stat per distinct folder, stopping at 8.
    static func recentFolders(_ history: [DchHistoryRecord], exists: (String) -> Bool = isFolder) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for r in history where r.agent != nil && out.count < recentFoldersMax {
            let f = folder(r)
            if !f.isEmpty, seen.insert(f).inserted, exists(f) { out.append(f) }
        }
        return out
    }

    static func isFolder(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    /// A record's agent command, dch's revive_spawn choice: the session's argv
    /// when it holds a `claude` token (RV_ARGV, which keeps a wrapper such as
    /// `headroom wrap claude`, since agent.launch is the process below the
    /// session's child), else agent.launch (RV_SHELL: claude typed into a shell).
    /// A record with no agent, or an empty command, is no source.
    static func recordCommand(_ r: DchHistoryRecord) -> [String]? {
        guard let agent = r.agent else { return nil }
        let argv = r.argv.contains { ($0 as NSString).lastPathComponent == "claude" } ? r.argv : agent.launch
        return argv.isEmpty ? nil : argv
    }

    /// #606: the command the user runs, while the setting is unset: the first
    /// live session's record with one (newest activity first), else the newest
    /// history record's; resume flags stripped. nil: no source (New session runs
    /// `claude` and nothing is stored).
    static func inferredCommand(live: [DchHistoryRecord], history: [DchHistoryRecord]) -> [String]? {
        (live + history).lazy.compactMap(recordCommand).first.map(strippingResume)
    }

    /// #606: a command line as argv, no expansion of any kind. Whitespace
    /// separates words; '…' is literal; "…" groups, a backslash in it escaping
    /// only " and \; outside quotes a backslash takes the next character as is
    /// (so `shellLine`'s '\'' reads back). An unclosed quote runs to the end.
    static func shellWords(_ s: String) -> [String] {
        let cs = Array(s)
        var out: [String] = [], word = "", started = false, quote: Character?, i = 0
        while i < cs.count {
            let c = cs[i]
            i += 1
            if quote == "'" {
                if c == "'" { quote = nil } else { word.append(c) }
            } else if c == "\\", i < cs.count, quote == nil || cs[i] == "\"" || cs[i] == "\\" {
                word.append(cs[i])
                i += 1
                started = true
            } else if quote == "\"" {
                if c == "\"" { quote = nil } else { word.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c
                started = true
            } else if c.isWhitespace {
                if started { out.append(word) }
                word = ""
                started = false
            } else {
                word.append(c)
                started = true
            }
        }
        if started { out.append(word) }
        return out
    }

    /// #606: argv as one line that `shellWords` reads back word for word.
    static func shellLine(_ argv: [String]) -> String { argv.map(shellQuoted).joined(separator: " ") }

    /// #606: dch's record of each live session, newest activity first (dch's
    /// README contract: `$XDG_STATE_HOME/dch/sessions/<slug>/<name>.json`,
    /// `~/.local/state` when XDG_STATE_HOME is unset or relative; <slug> is the
    /// socket dir with each `/` as `-`). The master rewrites it while it runs,
    /// and `--history` leaves it out. Its command gets run, so as dch's
    /// hrec_load (#608): the slug dir lstat'd ours and closed to others, as
    /// dch_history_dir does (and dch/, sessions/ above it, stricter than dch);
    /// the record opened O_NOFOLLOW and its fd a regular file, ours, closed to
    /// others, at most 1 MB; its sock_dir the session's own (the slug folds /
    /// and -); and only one still running.
    static func liveRecords(_ sessions: [AgentSession],
                            env: [String: String] = ProcessInfo.processInfo.environment) -> [DchHistoryRecord] {
        let xdg = env["XDG_STATE_HOME"] ?? ""
        let root = xdg.hasPrefix("/") ? xdg : (env["HOME"] ?? NSHomeDirectory()) + "/.local/state"
        return sessions.sorted { $0.activity > $1.activity }.compactMap { s -> DchHistoryRecord? in
            let dir = "\(root)/dch/sessions/\(s.key.dir.replacingOccurrences(of: "/", with: "-"))"
            guard ["\(root)/dch", "\(root)/dch/sessions", dir].allSatisfy({ p in
                var st = stat()
                return lstat(p, &st) == 0 && isOurs(st, type: S_IFDIR)
            }) else { return nil }
            let fd = Darwin.open("\(dir)/\(s.name).json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { return nil }
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var st = stat()
            guard fstat(fd, &st) == 0, isOurs(st, type: S_IFREG), st.st_size <= 1 << 20,
                  let body = try? h.read(upToCount: Int(st.st_size)),
                  (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["sock_dir"] as? String == s.key.dir
            else { return nil }
            return parseHistory(Data("[".utf8) + body + Data("]".utf8), dir: s.key.dir).first { $0.end.isEmpty }
        }
    }

    /// #608: of `type`, our uid's and closed to others (no group or other write).
    static func isOurs(_ st: stat, type: mode_t) -> Bool {
        st.st_mode & S_IFMT == type && st.st_uid == getuid() && st.st_mode & 0o022 == 0
    }

    /// dch's resume_argv rules, so a new session never resumes a recorded
    /// conversation a second time (only --revive may carry --resume). After the
    /// `claude` token (else after argv[0]), up to a bare `--`: --resume/-r and
    /// a next token not starting with '-'; --session-id and its next token;
    /// --resume=, --session-id=, --continue, -c, --fork-session alone.
    static func strippingResume(_ argv: [String]) -> [String] {
        let tok = argv.firstIndex { ($0 as NSString).lastPathComponent == "claude" } ?? 0
        var out = Array(argv.prefix(tok + 1)), k = tok + 1
        while k < argv.count {
            let a = argv[k]
            k += 1
            switch a {
            case "--":
                return out + argv[(k - 1)...]
            case "--resume", "-r":
                if k < argv.count, !argv[k].hasPrefix("-") { k += 1 }
            case "--session-id":
                k += 1
            case "--continue", "-c", "--fork-session":
                break
            case _ where a.hasPrefix("--resume=") || a.hasPrefix("--session-id="):
                break
            default:
                out.append(a)
            }
        }
        return out
    }

    /// The folder's basename as a session name: [A-Za-z0-9._-] kept, any other
    /// run as one "-", no leading "-" or "." (dch would read a flag), never empty.
    static func sessionName(folder: String) -> String {
        var out = ""
        for c in (folder as NSString).lastPathComponent {
            let ok = c.isASCII && (c.isLetter || c.isNumber || "._-".contains(c))
            if ok { out.append(c) } else if out.last != "-" { out.append("-") }
        }
        let trimmed = out.drop { $0 == "-" || $0 == "." }.reversed().drop { $0 == "-" }.reversed()
        return trimmed.isEmpty ? "session" : String(trimmed)
    }

    /// `--spawn <name> [launch argv]`; the name is free of the dir's live
    /// sessions and records (a record of that name would be overwritten).
    static func newSessionArgs(folder: String, command: [String], taken: Set<String>) -> [String] {
        ["--spawn", freeName(sessionName(folder: folder), taken: taken)] + command
    }

    /// --spawn passes its env to the session: a Claude Code identity in it
    /// would make the child Claude think it runs inside the caller's.
    static func spawnEnv(_ env: [String: String]) -> [String: String] {
        env.filter { k, _ in !(k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE_") || k == "CLAUDE_PID" || k == "CLAUDE_EFFORT") }
    }

    /// --spawn has no --json. #580 (QA #452 L1): a program that cannot be executed
    /// prints "dch: <name>: <cmd>: <reason>", then "dch: failed to spawn session":
    /// the last "dch: <name>: " line says why; else the last line.
    static func spawnText(_ r: DchActionResult, name: String) -> String? {
        if r.status == 0 { return nil }
        let line = r.text.last { $0.hasPrefix("dch: \(name): ") } ?? r.line
        return line.isEmpty ? "New session failed (exit \(r.status))" : "New session failed: \(line)"
    }

    // MARK: - Action results

    /// The one place a verb's output becomes a result: #580's --json objects
    /// (a line that does not decode is text, never an error) and the other lines.
    static func actionResult(status: Int32, output: Data, stopped: Bool = false) -> DchActionResult {
        var r = DchActionResult(status: status, stopped: stopped)
        for l in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = l.trimmingCharacters(in: .whitespaces)
            if let o = jsonLine(line) { r.json.append(o) } else if !line.isEmpty { r.text.append(line) }
        }
        return r
    }

    static let resumingText = "Resuming…"
    /// #585: shown only with n > 0 records reviveAllTakes.
    static func resumeAllLabel(_ n: Int) -> String { "Resume interrupted (\(n))" }
    /// QA #445 I2: `--revive --all` takes every abnormal end, not only signals.
    /// #580: never a stopped or closed session (dch skips them).
    static let resumeAllHelp = "Brings back the sessions that ended on a signal, crashed, exited with an error "
        + "or vanished (a reboot) in the last 3 days, after running at least 5 minutes. Closed, stopped and "
        + "cleanly exited sessions come back only from their own row"

    /// The env every control verb runs with: listEnv (DCH_SOCKET_DIR, no
    /// DCH_SESSION) plus the user's PATH. QA #445 M1: under launchd the PATH is
    /// /usr/bin:/bin:/usr/sbin:/sbin, and a revived record whose argv[0] is a
    /// bare "headroom" or "claude" dies at once while dch prints "revived".
    /// #579's --spawn uses it too, with spawnEnv on top. `login`: LoginPath.read(), nil
    /// when the probe failed (the well-known dirs go in front of the process PATH).
    static func controlEnv(dir: String, login: String?,
                           base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = listEnv(dir: dir, base: base)
        env["PATH"] = LoginPath.path(login: login, process: base["PATH"] ?? "",
                                     home: base["HOME"] ?? NSHomeDirectory())
        return env
    }
}

/// The user's login PATH, read once from `$SHELL -lc` (#578 r2).
enum LoginPath {
    static let marker = "__PROSPER_LOGIN_PATH__"
    /// Markers around the value, so profile output before or after is ignored.
    static let script = "printf '\(marker)%s\(marker)' \"$PATH\""
    static let timeout: TimeInterval = 4

    /// stdout of `shell -lc script`; nil when it timed out.
    typealias Probe = @Sendable (_ shell: String, _ script: String) -> Data?

    static let shellProbe: Probe = { shell, script in
        DchCommand.bounded(timeout) { onPid in
            DchCommand.runCapturingBoth(args: ["-lc", script], env: ProcessInfo.processInfo.environment,
                                        path: shell, onPid: onPid).out
        }
    }

    /// The text between the first two markers; nil without both or when empty.
    static func parse(_ out: String) -> String? {
        let parts = out.components(separatedBy: marker)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    /// Always present: `zsh -l` reads no .zshrc, where ~/.local/bin (headroom)
    /// is usually added.
    static func wellKnown(home: String) -> [String] {
        ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", home + "/.local/bin"]
    }

    /// The login PATH with any missing well-known dir after it (its order wins);
    /// without one, the well-known dirs in front of the process PATH. Deduplicated.
    static func path(login: String?, process: String, home: String) -> String {
        let split = { (p: String) in p.split(separator: ":").map(String.init) }
        let dirs = login.map { split($0) + wellKnown(home: home) } ?? wellKnown(home: home) + split(process)
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var path: String?
    }
    static let shared = Cache()

    /// Probed at most once per process once it works; a timeout or a parse
    /// failure is not cached, so the next control use retries. Off main.
    static func read(shell: String? = ProcessInfo.processInfo.environment["SHELL"],
                     cache: Cache = shared, probe: Probe = shellProbe) -> String? {
        if let hit = cache.lock.withLock({ cache.path }) { return hit }
        let shell = shell.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        guard let out = probe(shell, script), let p = parse(String(decoding: out, as: UTF8.self)) else { return nil }
        cache.lock.withLock { cache.path = p }
        return p
    }
}

/// #578: runs the long dch verbs, one per row at a time, off main. The verb is
/// just its args: Resume, Restart and New session (#579), Stop (#580). `key.name == ""`
/// stands for a whole socket dir (`--revive --all`, Restart all, Stop all): it and
/// any row of its dir exclude each other. A busy request is refused, never queued.
final class DchActionRunner: @unchecked Sendable {
    /// A revive waits up to dch's DCH_AGENT_STEP_MS (60 s) per agent step.
    static let bound: TimeInterval = 300
    /// #579: a restart waits up to DCH_AGENT_TIMEOUT_MS (10 min) for its agents
    /// to pause, then up to DCH_AGENT_STEP_MS per step. #580: --stop waits the same.
    static let restartBound: TimeInterval = 900
    /// #591 r2 (QA #462 M2): the one runner the island's buttons and the phone's
    /// verbs share, so a phone job and an island job on one row or dir exclude each other.
    static let shared = DchActionRunner()

    /// Starts the process in `cwd` (nil: ours), reports its pid and each output
    /// chunk as it comes, waits for it: (exit code, stdout+stderr).
    typealias Launch = @Sendable (_ path: String, _ args: [String], _ env: [String: String], _ cwd: String?,
                                  _ onPid: @escaping @Sendable (pid_t) -> Void,
                                  _ onOutput: @escaping @Sendable (Data) -> Void) -> (status: Int32, out: Data)

    private final class Job: @unchecked Sendable {   // touched under `lock` only
        var pid: pid_t?
        var cancelled = false
        var signalled = false
    }

    private let lock = NSLock()
    private var jobs: [AgentSessionKey: Job] = [:]
    private let bound: TimeInterval
    private let launch: Launch
    private let signal: @Sendable (pid_t) -> Void

    init(bound: TimeInterval = DchActionRunner.bound,
         launch: @escaping Launch = { path, args, env, cwd, onPid, onOutput in
             let r = DchCommand.runCapturingBoth(args: args, env: env, path: path, merge: true, cwd: cwd,
                                                 onPid: onPid, onOutput: onOutput)
             return (r.status, r.out)
         },
         signal: @escaping @Sendable (pid_t) -> Void = { _ = Darwin.kill($0, SIGTERM) }) {
        self.bound = bound
        self.launch = launch
        self.signal = signal
    }

    func isBusy(_ key: AgentSessionKey) -> Bool { lock.withLock { conflicts(key) } }

    private func conflicts(_ key: AgentSessionKey) -> Bool {
        jobs[key] != nil || jobs[AgentSessionKey(dir: key.dir, name: "")] != nil
            || (key.name.isEmpty && jobs.keys.contains { $0.dir == key.dir })
    }

    /// false: the row (or its dir's --all) is busy and nothing ran. `done` runs
    /// on the runner's thread once the process has exited.
    /// `env` is built on the job's thread (it may probe the login shell).
    /// #579: `cwd` for --spawn, `bound` overrides the runner's, and `onLine` gets
    /// each non-empty output line (trimmed) as it comes, all before `done`.
    @discardableResult
    func start(_ key: AgentSessionKey, path: String, args: [String], cwd: String? = nil, bound: TimeInterval? = nil,
               env: @escaping @Sendable () -> [String: String], onLine: (@Sendable (String) -> Void)? = nil,
               done: @escaping @Sendable (DchActionResult) -> Void) -> Bool {
        let job = Job()
        guard lock.withLock({ () -> Bool in
            guard !conflicts(key) else { return false }
            jobs[key] = job
            return true
        }) else { return false }
        let launch = launch, lines = LineSplitter(onLine)
        DispatchQueue.global(qos: .utility).async { [self] in
            let r = launch(path, args, env(), cwd, { pid in
                // Cancelled before the pid was known: its one SIGTERM goes now.
                let late = self.lock.withLock { () -> pid_t? in
                    job.pid = pid
                    return job.cancelled ? self.claimSignal(job) : nil
                }
                if let late { self.signal(late) }
            }, { lines.add($0) })
            lines.flush()
            let stopped = lock.withLock { () -> Bool in
                jobs[key] = nil
                job.pid = nil   // reaped: never signalled again (the pid may be reused)
                return job.cancelled
            }
            done(AgentIsland.actionResult(status: r.status, output: r.out, stopped: stopped))
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (bound ?? self.bound)) { [weak self] in
            self?.cancel(job)
        }
        return true
    }

    /// Exactly one SIGTERM to the recorded dch client pid; the job's own wait
    /// carries on until it exits. Never SIGKILL and never a second signal: a
    /// second one can leave agents paused. The bound expiring cancels too.
    func cancel(_ key: AgentSessionKey) {
        guard let job = lock.withLock({ jobs[key] }) else { return }
        cancel(job)
    }

    private func cancel(_ job: Job) {
        let pid = lock.withLock { () -> pid_t? in
            job.cancelled = true
            return claimSignal(job)
        }
        if let pid { signal(pid) }
    }

    /// Under `lock`: the pid to signal, at most once per job; nil before the pid is known or after the reap.
    private func claimSignal(_ job: Job) -> pid_t? {
        guard !job.signalled, let pid = job.pid else { return nil }
        job.signalled = true
        return pid
    }
}

/// Output chunks into lines for `DchActionRunner.start`'s `onLine`. Bytes are
/// buffered until a newline, so a multi-byte character split across chunks
/// decodes whole. Touched only on the job's thread.
private final class LineSplitter: @unchecked Sendable {
    private var buf = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(_ onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func add(_ chunk: Data) {
        guard onLine != nil else { return }
        buf.append(chunk)
        while let nl = buf.firstIndex(of: 0x0A) {
            emit(buf[buf.startIndex..<nl])
            buf = Data(buf[(nl + 1)...])
        }
    }

    /// The last line when it had no newline.
    func flush() {
        emit(buf)
        buf = Data()
    }

    private func emit(_ bytes: Data) {
        let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if !line.isEmpty { onLine?(line) }
    }
}
