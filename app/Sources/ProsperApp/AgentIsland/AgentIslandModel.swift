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

enum AgentIsland {
    // MARK: - Display

    /// Blocked, working, done, idle; newest activity first inside a group.
    static func sorted(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted {
            if $0.state != $1.state { return $0.state < $1.state }
            if $0.activity != $1.activity { return $0.activity > $1.activity }
            return ($0.key.name, $0.key.dir) < ($1.key.name, $1.key.dir)
        }
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
    static func islandAccessibilityLabel(_ s: Summary) -> String {
        let order: [AgentState] = [.working, .blocked, .done, .idle]
        let parts = order.compactMap { st -> String? in
            guard let n = s.counts[st], n > 0 else { return nil }
            return "\(n) \(st.label.lowercased())"
        }
        return (["Agent Island"] + (parts.isEmpty ? ["no sessions"] : parts)).joined(separator: ", ")
    }

    static func rowAccessibilityLabel(_ s: AgentSession, now: TimeInterval) -> String {
        let age = age(of: s, now: now)
        return [s.title, s.state.label, age.isEmpty ? nil : "\(age) ago"].compactMap { $0 }.joined(separator: ", ")
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

    typealias Runner = (_ args: [String], _ env: [String: String]) -> Data

    /// Every session of `dirs`, one dch fork per dir; `--ls-json`, else `-lj` (old dch).
    static func list(dirs: [String], run: Runner = { DchCommand.runCapturingBoth(args: $0, env: $1).out })
        -> [AgentSession] {
        dirs.flatMap { dir -> [AgentSession] in
            let env = listEnv(dir: dir)
            var rows = DchCommand.parseListJSON(run(["--ls-json"], env))
            if rows.isEmpty {
                rows = DchCommand.parseListTSV(String(decoding: run(["-lj"], env), as: UTF8.self))
            }
            return rows.map {
                AgentSession(key: AgentSessionKey(dir: dir, name: $0.name), alias: $0.alias,
                             activity: TimeInterval($0.activityEpoch), state: AgentState(dch: $0.state),
                             agents: $0.agents)
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
}

// MARK: - Poll gate

/// Mtimes of one session's sidecars: output (.act), a hook's reported state
/// (.state, where "done" always wins) and the alias (.alias, the title).
struct AgentSidecarStamp: Equatable {
    var act: TimeInterval?
    var state: TimeInterval?
    var alias: TimeInterval?
}

typealias AgentDirSnapshot = [AgentSessionKey: AgentSidecarStamp]

/// stat-only view of the socket dirs. readdir runs only when a dir's own mtime
/// moved (create/unlink: a session, a client, a new sidecar); a sidecar's
/// futimens leaves the dir alone, so the sidecars of known sessions are stat'd
/// every tick — about 3 stats per session per second, no fork.
final class AgentDirScanner {
    private var cache: [String: (mtime: TimeInterval, names: [String])] = [:]

    func scan(_ dirs: [String]) -> AgentDirSnapshot {
        var snap: AgentDirSnapshot = [:]
        for dir in dirs {
            // A dir that does not exist yet (isolation never used) is no sessions.
            guard let m = Self.mtime(dir) else { cache[dir] = nil; continue }
            if cache[dir]?.mtime != m {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                cache[dir] = (m, names.filter { $0.hasSuffix(".sock") }.map { String($0.dropLast(5)) })
            }
            for name in cache[dir]?.names ?? [] {
                let base = "\(dir)/\(name).sock"
                snap[AgentSessionKey(dir: dir, name: name)] = AgentSidecarStamp(
                    act: Self.mtime(base + ".act"), state: Self.mtime(base + ".state"),
                    alias: Self.mtime(base + ".alias"))
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
    private let list: ([String]) -> [AgentSession]
    private let scanner = AgentDirScanner()
    private var gate = AgentPollGate()
    private var fetched: [AgentSession] = []
    private var published: [AgentSession]?

    init(now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         dirs: @escaping () -> [String] = AgentIsland.liveSocketDirs,
         list: @escaping ([String]) -> [AgentSession] = { AgentIsland.list(dirs: $0) }) {
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
            fetched = list(dirs.filter(live.contains))
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
