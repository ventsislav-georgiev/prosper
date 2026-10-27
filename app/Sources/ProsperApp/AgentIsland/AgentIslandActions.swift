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
    /// "exit N", "signal N", "killed", "vanished" ("" reads as vanished); 1.24.0 adds "stopped".
    var end = ""
    var agent: Agent?

    var id: AgentSessionKey { key }
    var name: String { key.name }
    var title: String { alias.isEmpty ? key.name : alias }
    /// dch's own "last seen": ended, else updated.
    var lastSeen: TimeInterval { ended > 0 ? ended : updated }
}

/// One finished long verb: the exit code and the last non-empty output line.
/// `stopped`: the bound expired and the runner sent its one SIGTERM.
struct DchActionResult: Equatable, Sendable {
    let status: Int32
    let line: String
    var stopped = false
}

extension AgentIsland {
    // MARK: - History

    /// --history and --revive arrived in dch 1.23.0.
    static let reviveMinimum = [1, 23, 0]
    /// The History tab lists at most this many records, newest first.
    static let historyCap = 50

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
                })
        }
    }

    /// Every dir's records, newest first (dch's array is not in end order: a
    /// vanished record has ended 0). `run` is bound to the control binary.
    static func history(dirs: [String], run: Runner) -> [DchHistoryRecord] {
        dirs.flatMap { parseHistory(run(["--history", "--json"], listEnv(dir: $0)) ?? Data(), dir: $0) }
            .sorted { $0.lastSeen != $1.lastSeen ? $0.lastSeen > $1.lastSeen : ($0.name, $0.key.dir) < ($1.name, $1.key.dir) }
    }

    /// The end in words: "crashed (signal 9)", "exited (1)", "vanished",
    /// "killed"; anything else ("stopped", 1.24.0) as dch wrote it.
    static func endLabel(_ end: String) -> String {
        if end.isEmpty { return "vanished" }
        if end.hasPrefix("signal ") { return "crashed (\(end))" }
        if end.hasPrefix("exit ") { return "exited (\(end.dropFirst(5)))" }
        return end
    }

    /// `--revive <name>`; a name live now goes to `--as` the first free
    /// `<name>-2`, `-3`, … — free of live sessions and of other records in the dir
    /// (dch would overwrite that record).
    static func reviveArgs(_ r: DchHistoryRecord, live: Set<String>, records: Set<String>) -> [String] {
        guard live.contains(r.name) else { return ["--revive", r.name] }
        let free = (2...).lazy.map { "\(r.name)-\($0)" }.first { !live.contains($0) && !records.contains($0) }!
        return ["--revive", r.name, "--as", free]
    }

    // MARK: - Action results

    /// The one place a verb's output becomes a result. dch 1.24.0's `--json`
    /// NDJSON ({"name","phase"}, then {"name","result","reason"} per session)
    /// parses here (#580); 1.23.0 prints text: the exit code and the last
    /// non-empty line.
    static func actionResult(status: Int32, output: Data, stopped: Bool = false) -> DchActionResult {
        let last = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        return DchActionResult(status: status, line: last, stopped: stopped)
    }

    /// What a Resume row says when it finishes: nil when it worked (the row goes
    /// away with the next history read); else the failure as static text.
    /// `all`: the Resume crashed line also reports a success (dch's last line).
    static func resumeText(_ r: DchActionResult, all: Bool = false) -> String? {
        if r.stopped { return "Resume stopped: no answer in \(Int(DchActionRunner.bound / 60))m" }
        if r.status == 0 { return all && !r.line.isEmpty ? r.line : nil }
        return r.line.isEmpty ? "Resume failed (exit \(r.status))" : "Resume failed: \(r.line)"
    }

    static let resumingText = "Resuming…"
    static let resumeAllLabel = "Resume crashed"
    /// QA #445 I2: `--revive --all` takes every abnormal end, not only signals.
    static let resumeAllHelp = "Brings back the sessions that crashed, exited with an error or vanished "
        + "(a reboot) in the last 3 days, after running at least 5 minutes"

    /// The env every control verb runs with: listEnv (DCH_SOCKET_DIR, no
    /// DCH_SESSION) plus the user's PATH. QA #445 M1: under launchd the PATH is
    /// /usr/bin:/bin:/usr/sbin:/sbin, and a revived record whose argv[0] is a
    /// bare "headroom" or "claude" dies at once while dch prints "revived".
    /// #579's --spawn must use this builder too. `login`: LoginPath.read(), nil
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
/// just its args: Resume today, Stop and Restart (#580) later. `key.name == ""`
/// stands for a whole socket dir (`--revive --all`): it and any row of its dir
/// exclude each other. A busy request is refused, never queued.
final class DchActionRunner: @unchecked Sendable {
    /// A revive waits up to dch's DCH_AGENT_STEP_MS (60 s) per agent step.
    static let bound: TimeInterval = 300

    /// Starts the process, reports its pid, waits for it: (exit code, stdout+stderr).
    typealias Launch = @Sendable (_ path: String, _ args: [String], _ env: [String: String],
                                  _ onPid: @escaping @Sendable (pid_t) -> Void) -> (status: Int32, out: Data)

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
         launch: @escaping Launch = { path, args, env, onPid in
             let r = DchCommand.runCapturingBoth(args: args, env: env, path: path, merge: true, onPid: onPid)
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
    @discardableResult
    /// `env` is built on the job's thread (it may probe the login shell).
    func start(_ key: AgentSessionKey, path: String, args: [String], env: @escaping @Sendable () -> [String: String],
               done: @escaping @Sendable (DchActionResult) -> Void) -> Bool {
        let job = Job()
        guard lock.withLock({ () -> Bool in
            guard !conflicts(key) else { return false }
            jobs[key] = job
            return true
        }) else { return false }
        let launch = launch
        DispatchQueue.global(qos: .utility).async { [self] in
            let r = launch(path, args, env()) { pid in
                // Cancelled before the pid was known: its one SIGTERM goes now.
                let late = self.lock.withLock { () -> pid_t? in
                    job.pid = pid
                    return job.cancelled ? self.claimSignal(job) : nil
                }
                if let late { self.signal(late) }
            }
            let stopped = lock.withLock { () -> Bool in
                jobs[key] = nil
                job.pid = nil   // reaped: never signalled again (the pid may be reused)
                return job.cancelled
            }
            done(AgentIsland.actionResult(status: r.status, output: r.out, stopped: stopped))
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + bound) { [weak self] in
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
