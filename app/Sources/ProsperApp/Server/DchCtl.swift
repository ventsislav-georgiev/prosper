import Darwin
import Foundation

/// #838: the remote-frames "ctl" op (docs/protocol/remote-frames.md, 0x30-0x33). A client sends
/// dch's argv minus the program; this Mac runs its own dch with it, never through a shell, behind
/// a per-verb and per-flag allowlist, and streams stdout and stderr back. Seamed: no test runs dch.
struct DchCtlOps: Sendable {
    /// The dch attach and create run (DchCommand.dchPath, the bundled one first). Under XCTest only
    /// a test's dchPathOverride: nil there refuses the request, so an unstubbed test runs no dch.
    var path: @Sendable () -> String? = {
        NSClassFromString("XCTestCase") == nil || DchCommand.dchPathOverride != nil ? DchCommand.dchPath : nil
    }
    /// Remote Terminal's one dir, as list, kill and rename.
    var env: @Sendable () -> [String: String] = { DchCommand.remoteEnv() }
    /// Non-follow verbs only: dch #112's composer gate on --run can take ~30 s plus 5 s re-presses.
    var timeout: TimeInterval = 60
    /// --say, --stop, --revive wait for an agent: dch's own 600 s idle wait (DCH_AGENT_TIMEOUT_MS) plus margin.
    var agentTimeout: TimeInterval = 660
    /// stdout + stderr of a non-follow verb.
    var cap = 8 << 20

    /// The timeout `verb` runs under (not --follow: it has none).
    func timeout(of verb: String) -> TimeInterval { DchCtl.agentVerbs.contains(verb) ? agentTimeout : timeout }

    /// "xray" in ops, and --xray allowed: the dch ctl runs answers `--version` with at least
    /// DchCtl.xrayMinDch. The probe is DchCommand's (cached per path and mtime, bounded at 4 s), so
    /// never on the connection's queue. Under XCTest false: no test probes a dch.
    var xray: @Sendable () -> Bool = {
        NSClassFromString("XCTestCase") == nil && DchCtl.hasXray(DchCommand.probedVersion(DchCommand.dchPath))
    }
}

enum DchCtl {
    static let createOff = "creating sessions is off on this host"
    static let noDirectory = "no such directory"
    static let xrayOff = "xray not supported by this host"
    static let localOnly = "a session name with ':' is local only"
    /// #841, dch 1.42 serve's words: a 0x30 on an attached or watch connection (or beside another request), no close.
    static let ownConnection = "ctl needs its own connection"
    /// #841: anything but 0x08, 0x03, 0x30 or 0x34 on a ctl connection (running or warm), then the FIN.
    static let ctlOnly = "a ctl connection takes only ctl frames"
    /// #841: a 0x30 while this connection's ctl runs; the connection stays open. serve.c's BUSY_JSON byte for byte.
    static let busy = DchFrame.encode(DchFrame.error, Array(#"{"code":"busy","message":"a ctl is already running on this connection"}"#.utf8))
    /// #841: serve's CTL_GRACE_MS: a 0x34's SIGTERM, then SIGKILL to the group this long after.
    static let cancelGrace: TimeInterval = 2
    /// dch's CTL_ARGV_MAX.
    static let argvMax = 1024

    /// PLACEHOLDER: the first dch release with --xray is not out yet, so this is set out of reach and
    /// "xray" stays off. Set it to that release's version once Prosper bundles it.
    static let xrayMinDch = [999, 0, 0]
    static func hasXray(_ version: [Int]?) -> Bool { version.map { DchCommand.isAtLeast($0, xrayMinDch) } ?? false }

    /// What each allowlisted verb takes after itself. Anything else is refused before dch runs.
    enum Rule {
        case name            // <name>
        case alias           // -m <name> <alias>
        case text            // <name> [--] <words...>: no flag before the words
        case read            // <name> [--ansi] [--cursor] [--recent [N]]
        case history         // --json, no name
        case revive          // <name> [--as <new>] [--no-message] --json
        case names(all: Bool)  // <name>... --json; --forget: or --all
        case say             // <name> --json -- <text...>
        case xray            // <name> --json | --ref <text> [--scope s] [--full] [--budget-ms n] --json | --follow --json | --chapter <anchor> --json
    }

    static let rules: [String: Rule] = [
        "--read": .read, "--send": .text, "--run": .text, "--keys": .text, "--follow": .name, "--status": .name,
        "-k": .name, "-m": .alias, "-d": .name, "--spawn": .text, "--history": .history, "--revive": .revive,
        "--pin": .names(all: false), "--unpin": .names(all: false), "--forget": .names(all: true),
        "--stop": .names(all: false), "--say": .say, "--xray": .xray,
    ]

    /// The verbs that start a process: the create gate (0x02's) decides them.
    static let creating: Set<String> = ["--spawn", "--revive"]

    /// The verbs that wait for an agent and stream NDJSON progress meanwhile: the long timeout.
    static let agentVerbs: Set<String> = ["--say", "--stop", "--revive"]

    /// --follow, and --xray --follow: no cap, no timeout. Read from --xray's parse, so a --ref
    /// whose text is "--follow" is not one.
    static func follows(_ argv: [String]) -> Bool {
        argv.first == "--follow" || argv.first == "--xray" && xrayScan(Array(argv.dropFirst(2))).seen["--follow"] != nil
    }

    /// dch's flag test (dch.c main): "-" alone is a word, not a flag.
    static func isFlag(_ w: String) -> Bool { w.hasPrefix("-") && w.utf8.count > 1 }

    /// dch serve's ctl_name: name_ok (non-empty, at most 255 bytes, no leading "-", no "/", no
    /// control: C0, DEL, C1, bidi overrides), not "serve", then no ':' (dch dea6fd4: the child dch
    /// reads a:b as host:name and dials on with this Mac's identity). The leading "-" has 0x04's message.
    static func nameRefusal(_ n: String) -> String? {
        if n.hasPrefix("-") { return DchControlOps.dashNameRefusal }
        let bad = n.unicodeScalars.contains { c in
            let v = c.value
            return v == 0x2f || v < 0x20 || (0x7f..<0xa0).contains(v) || (0x202a...0x202e).contains(v) || (0x2066...0x2069).contains(v)
        }
        if n.isEmpty || n.utf8.count > 255 || bad || n == "serve" { return "invalid session name" }
        return n.contains(":") ? localOnly : nil
    }

    private static func shown(_ w: String) -> String { w.count > 64 ? String(w.prefix(64)) + "…" : w }
    private static func unlisted(_ w: String, _ verb: String) -> String { "ctl does not allow \(shown(w)) with \(verb)" }

    /// nil when `argv` may run, else 0x13's reason. `create`: the create gate.
    static func refusal(_ argv: [String], create: Bool) -> String? {
        guard argv.count >= 2 else { return "ctl needs a verb and its arguments" }
        guard argv.count <= argvMax else { return "too many arguments" }
        let verb = argv[0], rest = Array(argv.dropFirst())
        guard let rule = rules[verb] else { return "ctl does not run \(shown(verb))" }
        if creating.contains(verb), !create { return createOff }
        switch rule {
        case .history:
            return rest == ["--json"] ? nil : "--history takes only --json"
        case .names(let all):
            var named = false, everything = false
            for w in rest {
                if w == "--json" || (all && w == "--all") { everything = everything || w == "--all"; continue }
                if isFlag(w) { return unlisted(w, verb) }
                if let why = nameRefusal(w) { return why }
                named = true
            }
            if named == everything { return all ? "--forget takes session names, or --all" : "\(verb) needs a session name" }
            return json(rest, verb)
        default:
            break
        }
        if let why = nameRefusal(rest[0]) { return why }
        let after = Array(rest.dropFirst())
        switch rule {
        case .name:
            return after.isEmpty ? nil : "\(verb) takes nothing after the session name"
        case .alias:
            return after.count == 1 ? nil : "-m takes a session name and an alias"
        case .text:
            // dch reads flags until "--" or the first plain word; after either, every word is text.
            guard let first = after.first, isFlag(first), first != "--" else { return nil }
            return unlisted(first, verb)
        case .read:
            var i = 0
            while i < after.count {
                switch after[i] {
                case "--ansi", "--cursor": i += 1
                case "--recent":
                    i += 1
                    // dch's ctl_count: a word that starts with a digit is the count, 1-5 digits, 1..65535.
                    if i < after.count, let d = after[i].utf8.first, (0x30...0x39).contains(d) {
                        let n = after[i]
                        guard n.utf8.count <= 5, n.utf8.allSatisfy({ (0x30...0x39).contains($0) }), (1...65535).contains(Int(n) ?? 0)
                        else { return "--recent wants 1..65535 lines" }
                        i += 1
                    }
                default: return unlisted(after[i], verb)
                }
            }
            return nil
        case .revive:
            var i = 0
            while i < after.count {
                switch after[i] {
                case "--no-message", "--json": i += 1
                case "--as":
                    guard i + 1 < after.count else { return "--as needs a session name" }
                    if let why = nameRefusal(after[i + 1]) { return why }
                    i += 2
                default: return unlisted(after[i], verb)
                }
            }
            return json(after, verb)
        case .say:
            let text = after.first == "--json" ? Array(after.dropFirst()) : after
            guard text.first == "--" else { return "--say needs -- before its text" }
            return after.first == "--json" ? nil : "--say needs --json"
        case .xray:
            return xrayRefusal(after)
        case .history, .names:
            return nil
        }
    }

    /// dch's CTL_JSON: --json is required (the flags were already checked, so any "--json" is one).
    private static func json(_ words: [String], _ verb: String) -> String? { words.contains("--json") ? nil : "\(verb) needs --json" }

    static let refText = "--ref takes 1-256 bytes of text with no control characters"
    static let anchorShape = "--chapter takes an anchor: 1-128 of A-Z a-z 0-9 : _ . -"
    static let budgetRange = "--budget-ms takes a whole number from 50 to 300"

    /// --ref's text (amendment 4): 1-256 bytes of UTF-8, no C0, DEL, C1 or bidi control
    /// (U+200E/F, U+202A-E, U+2066-9).
    static func refOK(_ t: String) -> Bool {
        (1...256).contains(t.utf8.count) && !t.unicodeScalars.contains { c in
            let v = c.value
            return v < 0x20 || (0x7f..<0xa0).contains(v) || v == 0x200e || v == 0x200f
                || (0x202a...0x202e).contains(v) || (0x2066...0x2069).contains(v)
        }
    }

    /// --chapter's anchor, as --xray --json gives it (amendment 4): [A-Za-z0-9:_.-], 1-128 bytes.
    static func anchorOK(_ a: String) -> Bool {
        (1...128).contains(a.utf8.count) && a.utf8.allSatisfy { b in
            (0x30...0x39).contains(b) || (0x41...0x5a).contains(b) || (0x61...0x7a).contains(b) || [0x3a, 0x5f, 0x2e, 0x2d].contains(b)
        }
    }

    /// --xray after its name: each flag once, in any order, its value checked. `seen`: flag to value.
    private static func xrayScan(_ after: [String]) -> (seen: [String: String], why: String?) {
        var seen: [String: String] = [:], i = 0
        while i < after.count {
            let w = after[i]
            guard ["--json", "--full", "--follow", "--ref", "--scope", "--chapter", "--budget-ms"].contains(w) else {
                return (seen, unlisted(w, "--xray"))
            }
            guard seen[w] == nil else { return (seen, "--xray takes \(w) once") }
            var value = ""
            if ["--ref", "--scope", "--chapter", "--budget-ms"].contains(w) {
                guard i + 1 < after.count else { return (seen, "\(w) needs a value") }
                value = after[i + 1]
                i += 1
            }
            switch w {
            case "--ref" where !refOK(value): return (seen, refText)
            case "--scope" where !["session", "project", "all"].contains(value):
                return (seen, "--scope takes session, project or all")
            case "--chapter" where !anchorOK(value): return (seen, anchorShape)
            case "--budget-ms" where !(value.utf8.count <= 3 && value.utf8.allSatisfy({ (0x30...0x39).contains($0) })
                                       && (50...300).contains(Int(value) ?? 0)):
                return (seen, budgetRange)
            default: break
            }
            seen[w] = value
            i += 1
        }
        return (seen, nil)
    }

    /// --xray after its name: --json, and at most one of --ref (with --scope, --full, --budget-ms),
    /// --follow, --chapter.
    private static func xrayRefusal(_ after: [String]) -> String? {
        let (seen, why) = xrayScan(after)
        if let why { return why }
        guard seen["--json"] != nil else { return "--xray needs --json" }
        let modes = ["--ref", "--follow", "--chapter"].filter { seen[$0] != nil }
        guard modes.count <= 1 else { return "--xray takes one of --ref, --follow, --chapter" }
        if seen["--ref"] == nil, let extra = ["--scope", "--full", "--budget-ms"].first(where: { seen[$0] != nil }) {
            return "\(extra) goes with --ref"
        }
        return nil
    }

    /// 0x30's "cwd" (--spawn only): nil when it may run there, else 0x13's reason.
    static func cwdRefusal(_ cwd: Any?, verb: String) -> String? {
        guard let cwd else { return nil }
        guard verb == "--spawn" else { return "cwd is only for --spawn" }
        var isDir: ObjCBool = false
        guard let path = cwd as? String, path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return noDirectory }
        return nil
    }

    /// #841: keys sorted, so {"exit":2,"why":"cancel"} is dch serve's bytes (its goldens compare them).
    static func exitFrame(_ code: Int32, why: String? = nil) -> Data {
        var o: [String: Any] = ["exit": Int(code)]
        if let why { o["why"] = why }
        return DchFrame.encode(DchFrame.ctlExit, [UInt8]((try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()))
    }
}

/// #838: one ctl request's dch child. Its stdout and stderr go out as 0x31/0x32 chunks, then one
/// final frame: 0x33 with dch's exit, 0x33 {"exit": 2, "why"} once the cap, the timeout or a 0x34
/// cut it, or 0x13 when dch could not start. `cancel` (the connection closed) sends dch SIGTERM only, and
/// nothing more: --stop and --say answer it by leaving the session running with their resume
/// message. The cap and timeout kill is ShellRunner's: SIGTERM to the child's whole process group
/// (Foundation makes it the leader), SIGKILL to the group after 1 s.
final class DchCtlJob: @unchecked Sendable {
    enum Stop { case none, term, killGroup }

    private let lock = NSLock()      // pid, ended, cancelled
    private let sendLock = NSLock()  // chunks, then the one final frame
    private var pid: pid_t = 0
    private var ended = false
    private var cancelled = false
    private var sent = 0
    /// #841: written once dch is reaped, so the pump stops waiting on a pipe a leftover writer holds.
    private let wake = Pipe()

    /// Ends the request once: true for the one caller that did. `running` (the timeout): only while
    /// dch is not yet reaped (one that exited in time ends with its own exit) and not cut by a 0x34
    /// (serve's ctl_tick: one why per request).
    private func end(_ stop: Stop, running: Bool = false) -> Bool {
        let pid: pid_t? = lock.withLock {
            guard !ended, !(running && (self.pid == 0 || cancelled)) else { return nil }
            ended = true
            return self.pid
        }
        guard let pid else { return false }
        guard pid > 0 else { return true }
        switch stop {
        case .none: break
        case .term: Darwin.kill(pid, SIGTERM)
        case .killGroup: CodexHarness.killGroup(pid, grace: 1)
        }
        return true
    }

    func cancel() { _ = end(.term) }

    /// 0x34, as dch 1.42 serve's ctl_cut "cancel": nothing more is forwarded, dch gets SIGTERM and,
    /// still unreaped `DchCtl.cancelGrace` later, its group SIGKILL; once reaped the request ends with
    /// 0x33 {"exit": 2, "why": "cancel"}. Nothing once it ended or was already cancelled (a late 0x34).
    func cancelRequest() {
        let pid: pid_t? = lock.withLock {
            guard !ended, !cancelled else { return nil }
            cancelled = true
            return self.pid
        }
        guard let pid, pid > 0 else { return }   // before the spawn: run() sees `cancelled` and runs nothing
        Darwin.kill(pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + DchCtl.cancelGrace) {
            self.lock.withLock { if self.pid == pid, CodexHarness.mayKillGroup(pid) { Darwin.kill(-pid, SIGKILL) } }
        }
    }

    /// Blocks its thread (never the connection's queue) until dch exits or is killed.
    func run(path: String, argv: [String], env: [String: String], cwd: String?, follow: Bool, cap: Int,
             timeout: TimeInterval, send: @escaping @Sendable (Data) -> Bool, reply: @escaping @Sendable (Data) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = argv
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: cwd ?? NSHomeDirectory(), isDirectory: true)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0), poke = wake.fileHandleForWriting.fileDescriptor
        // Cleared once reaped: a late kill must not signal a recycled pid.
        p.terminationHandler = { [lock] _ in
            lock.withLock { self.pid = 0 }
            var b: UInt8 = 0
            _ = Darwin.write(poke, &b, 1)
            exited.signal()
        }
        lock.lock()   // a cancel either sees the pid or stops the spawn
        guard !ended else { lock.unlock(); return }
        if cancelled {   // a 0x34 that came before the spawn: nothing runs
            ended = true
            lock.unlock()
            return reply(DchCtl.exitFrame(2, why: "cancel"))
        }
        do { try p.run() } catch {
            lock.unlock()
            if end(.none) { reply(DchControlOps.error("dch could not be run")) }
            return
        }
        pid = p.processIdentifier
        lock.unlock()
        if !follow {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard self.end(.killGroup, running: true) else { return }
                self.sendLock.withLock { reply(DchCtl.exitFrame(2, why: "timeout")) }
            }
        }
        pump([(out.fileHandleForReading, DchFrame.ctlStdout), (err.fileHandleForReading, DchFrame.ctlStderr)],
             follow: follow, cap: cap, send: send, reply: reply)
        exited.wait()
        let code = p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
        let frame = lock.withLock { cancelled } ? DchCtl.exitFrame(2, why: "cancel") : DchCtl.exitFrame(code)
        sendLock.withLock { if end(.none) { reply(frame) } }
    }

    /// #841 (QA #680 INFO-3): dch's stdout and stderr, each chunk as it comes (--say/--stop/--revive
    /// stream progress), as dch 1.42 serve's ctl_read: once dch is reaped an empty pipe is done, so a
    /// leftover writer (a process dch started that kept the pipe) holds neither the 0x33 nor the slot.
    /// Until the reap the pipes are read even after the end (dropped), so a child writing into a full
    /// pipe still exits.
    private func pump(_ pipes: [(FileHandle, UInt8)], follow: Bool, cap: Int,
                      send: (Data) -> Bool, reply: (Data) -> Void) {
        var open = pipes.map { (fd: $0.0.fileDescriptor, type: $0.1) }
        let woken = wake.fileHandleForReading.fileDescriptor
        for fd in open.map(\.fd) { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while !open.isEmpty {
            let reaped = lock.withLock { pid == 0 }
            if !reaped {
                var fds = (open.map(\.fd) + [woken]).map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
                _ = poll(&fds, nfds_t(fds.count), -1)
            }
            open = open.filter { p in
                for _ in 0..<16 {   // one pass, then the reap is checked again
                    let n = Darwin.read(p.fd, &buf, buf.count)
                    if n > 0 { deliver(p.type, Data(buf[..<n]), follow: follow, cap: cap, send: send, reply: reply); continue }
                    if n < 0, errno == EINTR { continue }
                    return n < 0 && errno == EAGAIN && !reaped   // EOF, or empty after the reap: done
                }
                // shortcut: after the reap one 1 MiB pass per pipe; a leftover writer still filling it is cut off there.
                return !reaped
            }
        }
    }

    /// One chunk, in order with the final frame. A non-follow verb stops at `cap` bytes: what fits
    /// goes out, then the kill and 0x33 cap; nothing after. Nothing after a 0x34 either.
    private func deliver(_ type: UInt8, _ chunk: Data, follow: Bool, cap: Int,
                         send: (Data) -> Bool, reply: (Data) -> Void) {
        sendLock.lock()
        defer { sendLock.unlock() }
        guard !lock.withLock({ ended || cancelled }) else { return }
        if !follow, sent + chunk.count > cap {
            if cap > sent { _ = send(DchFrame.encode(type, [UInt8](chunk.prefix(cap - sent)))) }
            sent = cap
            if end(.killGroup) { reply(DchCtl.exitFrame(2, why: "cap")) }
            return
        }
        sent += chunk.count
        if !send(DchFrame.encode(type, [UInt8](chunk))) { _ = end(.term) }   // the connection is gone: a close
    }
}
