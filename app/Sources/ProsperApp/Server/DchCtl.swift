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
    /// Non-follow verbs but DchCtl.longVerbs: dch serve's CTL_MS.
    var timeout: TimeInterval = 60
    /// DchCtl.longVerbs wait for an agent: dch's own 600 s idle wait (DCH_AGENT_TIMEOUT_MS) plus margin,
    /// dch serve's CTL_LONG_MS. #852: --run too (rframe.c:470@v1.45.1): typing into an agent can take ~60 s.
    var agentTimeout: TimeInterval = 660
    /// #856: arms the timeout's timer; tests record it and fire it by hand.
    var after: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = DchCtl.after
    /// #1680: waits `delay` s (serve's CTL_RETRY_MS) before the one rerun of a follow that was busy at its start; tests
    /// record it and return at once. The wait ends early never: a cut or 0x34 during it is seen by the rerun.
    var retryWait: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    /// #1693: runs between a run's reap and its busy decision; tests cut the job there, the window a cut can land in.
    var afterReap: @Sendable () -> Void = {}
    /// stdout + stderr of a non-follow verb.
    var cap = 8 << 20
    /// #1013: dch serve's STALL_MS (#201, serve.c:85 and :2262-2270@v1.73.0): a 0x31/0x32 the socket has not taken
    /// this long closes the connection, counted from the send or from the ctl's timeout when that is later.
    var stall: TimeInterval = 20

    /// The timeout `verb` runs under (not --follow: it has none).
    func timeout(of verb: String) -> TimeInterval { DchCtl.longVerbs.contains(verb) ? agentTimeout : timeout }

    /// #841 r4: the SIGKILL backstop after a 0x34's or a close's SIGTERM (tests set it small).
    var agentGrace: TimeInterval = DchCtl.agentGrace
    /// The grace `verb` gets: `agentGrace` for DchCtl.longVerbs, else DchCtl.cancelGrace.
    func grace(of verb: String) -> TimeInterval { DchCtl.longVerbs.contains(verb) ? agentGrace : DchCtl.cancelGrace }

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
    /// #885: dch serve's words for an argv or cwd it cannot read (ctl_request, v1.58.0 serve.c:1232-1233), then the FIN.
    static let unreadable = "malformed ctl request: argv must be an array of strings, cwd a string"
    static let xrayOff = "xray not supported by this host"
    static let localOnly = "a session name with ':' is local only"
    /// #841, dch 1.42 serve's words: a 0x30 on an attached or watch connection (or beside another request), no close.
    static let ownConnection = "ctl needs its own connection"
    /// #841: a frame dch serve reads whole (0x01-0x09, 0x2e) but 0x08 or 0x03, on a ctl connection (running or warm), then the FIN.
    static let ctlOnly = "a ctl connection takes only ctl frames"
    /// #841: a 0x30 while this connection's ctl runs; the connection stays open. serve.c's BUSY_JSON byte for byte.
    static let busy = DchFrame.encode(DchFrame.error, Array(#"{"code":"busy","message":"a ctl is already running on this connection"}"#.utf8))
    /// #841: serve's CTL_GRACE_MS: a 0x34's or a close's SIGTERM, then SIGKILL to the group this long after.
    /// #852: a cap's and a timeout's too, and every cut's on a server stop (serve.c:1251-1264@v1.45.1).
    static let cancelGrace: TimeInterval = 2
    /// #841 r4 (dch's ruling, 2026-11-10): an agent verb's grace instead. On SIGTERM dch 1.46.0+ --say/--run/--revive
    /// stop at a safe point (Ctrl-U take-back, up to 30 s DCH_AGENT_LAND_MS for a paste to paint) and --stop
    /// types its resume message; a SIGKILL at 2 s cuts that short. dch serve's CTL_LONG_MS.
    static let agentGrace: TimeInterval = 660
    /// dch serve's CTL_LONG verbs (rframe.c:470-485@v1.45.1): the 660 s timeout and grace.
    static let longVerbs: Set<String> = ["--say", "--stop", "--revive", "--run"]
    /// dch's CTL_ARGV_MAX.
    static let argvMax = 1024
    /// #1680: serve's CTL_RETRY_MS (serve.c:101@v1.99.0) and the stderr of a follow the master had no subscriber slot for.
    static let retryDelay: TimeInterval = 1
    static let busyText = Array("dch: busy\n".utf8)

    /// #1357 (P9): the first dch whose serve ctl_xray is `.xray`'s allowlist. #1247 ported rframe.c@v1.99.0 (flags, words,
    /// order of checks, --budget-ms, refOK's code points). Re-read at v1.78.0 (rframe.c:630-694): the same eleven flags,
    /// words, order, anchor/scope/budget/search checks, but no #446 exemption, so serve refuses --follow with --tasks or
    /// --memory (:673-680) where `.xray` allows it. That exemption is v1.91.0's (rframe.c:676); ctl_xray and its helpers are
    /// byte-identical from v1.91.0 to v1.99.0. Left as before: xr_ref_parse's grammar ("not a ref": only a blank text and
    /// a text starting with "-" are refused here, the dch child refuses the rest when it runs) and a 60-byte cut of a
    /// shown word at a scalar boundary.
    static let xrayMinDch = [1, 91, 0]
    static func hasXray(_ version: [Int]?) -> Bool { version.map { DchCommand.isAtLeast($0, xrayMinDch) } ?? false }

    /// The timeout's timer (DchCtlOps.after's default).
    @Sendable static func after(_ delay: TimeInterval, _ fire: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: fire)
    }

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

    /// --follow, and --xray --follow: no cap, no timeout. Read from --xray's parse, so a --ref
    /// whose text is "--follow" is not one.
    static func follows(_ argv: [String]) -> Bool {
        argv.first == "--follow" || argv.first == "--xray" && xrayScan(Array(argv.dropFirst(2))).seen["--follow"] != nil
    }

    /// dch's flag test (dch.c main): "-" alone is a word, not a flag.
    static func isFlag(_ w: String) -> Bool { w.utf8.first == 0x2d && w.utf8.count > 1 }   // #877: the byte, as dch

    /// dch serve's ctl_name (v1.57.0 rframe.c:560-569): name_ok (see nameOK), not "serve", then no ':'
    /// (dch dea6fd4, v1.57.0 serve.c:1246-1254: the child dch reads a:b as host:name and dials on with this
    /// Mac's identity). The leading "-" has 0x04's message.
    static func nameRefusal(_ n: String) -> String? {
        if n.utf8.first == 0x2d { return DchControlOps.dashNameRefusal }   // QA #727 INFO-4: the byte, not a Character
        if !nameOK(n) || n == "serve" { return invalidName }
        return n.utf8.contains(0x3a) ? localOnly : nil   // #879: the byte, as serve's strchr (":" + a combining mark is one Character)
    }

    static let invalidName = "invalid session name"
    /// dch's NAME_CAP (rframe.h:29@v1.54.0): name_ok's byte bound.
    static let nameCap = 255

    /// dch's name_ok (v1.57.0 rframe.c:437-450): non-empty, at most 255 bytes, no leading "-", no "/",
    /// no control (cp_ctl, v1.57.0 rframe.c:70-81: C0, DEL, C1, the bidi embeddings, overrides and isolates
    /// U+202A-E and U+2066-9, and since dch 1.55.0 (#879) the bidi marks U+200E, U+200F, U+061C and the
    /// line and paragraph separators U+2028, U+2029). Scalars, as cp_ctl reads code points.
    static func nameOK(_ n: String) -> Bool {
        !n.isEmpty && n.utf8.count <= nameCap && n.utf8.first != 0x2d && !n.unicodeScalars.contains { c in
            let v = c.value
            return v == 0x2f || v < 0x20 || (0x7f..<0xa0).contains(v) || (0x202a...0x202e).contains(v) || (0x2066...0x2069).contains(v)
                || [0x200e, 0x200f, 0x061c, 0x2028, 0x2029].contains(v)
        }
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

    static let refText = "bad ref"                 // serve.c ctl_request: xr_ref_ok
    static let notARef = "not a ref"               // serve.c ctl_request: xr_ref_parse
    static let anchorShape = "bad anchor"          // rframe.c:688
    static let scopeShape = "bad scope"            // :690
    static let budgetRange = "bad budget"          // :692

    /// --ref's text (amendment 4): 1-256 bytes of UTF-8, no C0, DEL, C1 or bidi control
    /// (U+200E/F, U+202A-E, U+2066-9), and (#1247, dch's cp_ctl) U+061C, U+2028, U+2029.
    static func refOK(_ t: String) -> Bool {
        (1...256).contains(t.utf8.count) && !t.unicodeScalars.contains { c in
            let v = c.value
            return v < 0x20 || (0x7f..<0xa0).contains(v) || v == 0x200e || v == 0x200f
                || (0x202a...0x202e).contains(v) || (0x2066...0x2069).contains(v) || v == 0x061c || v == 0x2028 || v == 0x2029
        }
    }

    /// --chapter's anchor, as --xray --json gives it (amendment 4): [A-Za-z0-9:_.-], 1-128 bytes.
    static func anchorOK(_ a: String) -> Bool {
        (1...128).contains(a.utf8.count) && a.utf8.allSatisfy { b in
            (0x30...0x39).contains(b) || (0x41...0x5a).contains(b) || (0x61...0x7a).contains(b) || [0x3a, 0x5f, 0x2e, 0x2d].contains(b)
        }
    }

    /// dch serve's ctl_xray flag list (rframe.c:631-692@v1.99.0), and which take a value (k 4...8).
    static let xrayFlags: Set<String> = ["--json", "--follow", "--clear", "--full", "--ref", "--chapter", "--scope", "--budget-ms",
                                         "--search", "--tasks", "--memory"]
    static let xrayValued: Set<String> = ["--ref", "--chapter", "--scope", "--budget-ms", "--search"]
    static let xrayNeedsJSON = "--xray needs --json (the view is client-side only)"   // rframe.c:679-680
    static let xrayExclusion = "--ref, --search, --tasks, --memory, --follow, --chapter and --clear exclude each other"   // :682-683
    static let xrayWithRef = "--scope, --full and --budget-ms come with --ref"   // :685-686
    static let searchShape = "bad search: 2 to 200 bytes, no control character"   // :694-695

    /// dch's xray_search_ok (rframe.c:591-604): 2 to 200 bytes of UTF-8, no cp_ctl code point (cp_ctl, rframe.c:75-81:
    /// C0, DEL, C1, U+202A-E, U+2066-9, U+200E/F, U+061C, U+2028/9). A Swift String is valid UTF-8 already.
    static func searchOK(_ t: String) -> Bool {
        (2...200).contains(t.utf8.count) && !t.unicodeScalars.contains { c in
            let v = c.value
            return v < 0x20 || (0x7f..<0xa0).contains(v) || (0x202a...0x202e).contains(v) || (0x2066...0x2069).contains(v)
                || v == 0x200e || v == 0x200f || v == 0x061c || v == 0x2028 || v == 0x2029
        }
    }

    /// dch's xray_budget (rframe.c:607-617): a run of ASCII digits of any length, clamped at 1000 as it is read, then 50 to 300.
    static func budgetOK(_ s: String) -> Bool {
        var v = 0
        for b in s.utf8 {
            guard (0x30...0x39).contains(b) else { return false }
            v = min(v * 10 + Int(b - 0x30), 1000)   // v <= 1000 before the step: no overflow
        }
        return !s.isEmpty && (50...300).contains(v)
    }

    /// rframe.c:656-661: "%.60s", the first 60 bytes (here cut at a scalar boundary: a String holds no torn scalar).
    private static func xrayShown(_ w: String) -> String {
        var out = "", n = 0
        for c in w.unicodeScalars { n += String(c).utf8.count; if n > 60 { break }; out.unicodeScalars.append(c) }
        return out
    }

    /// An element that is no --xray flag, as rframe.c:656-661 words it.
    private static func xrayUnlisted(_ w: String) -> String {
        let s = xrayShown(w)
        if ["--config", "serve", "-h", "--help", "-f", "--all"].contains(w) { return "\(s) is not allowed" }
        return w.hasPrefix("-") ? "\(s) is not allowed with --xray" : "unexpected \(s) after --xray"
    }

    /// --xray after its name: each flag once, in any order, a value taken as the next element. `seen`: flag to value.
    private static func xrayScan(_ after: [String]) -> (seen: [String: String], why: String?) {
        var seen: [String: String] = [:], i = 0
        while i < after.count {
            let w = after[i]
            guard xrayFlags.contains(w) else { return (seen, xrayUnlisted(w)) }
            guard seen[w] == nil else { return (seen, "\(w) twice") }
            var value = ""
            if xrayValued.contains(w) {
                guard i + 1 < after.count else { return (seen, "\(w) needs a value") }
                value = after[i + 1]
                i += 1
            }
            seen[w] = value
            i += 1
        }
        return (seen, nil)
    }

    /// --xray after its name, in rframe.c's order (ctl_xray :631-697, then ctl_request's --ref check): the scan (unknown, twice,
    /// needs a value), --json, the exclusion (--follow takes --tasks and --memory, #446), --scope/--full/--budget-ms
    /// with --ref, then the values (anchor, scope, budget, search), then --ref's bytes and shape.
    private static func xrayRefusal(_ after: [String]) -> String? {
        let (seen, why) = xrayScan(after)
        if let why { return why }
        guard seen["--json"] != nil else { return xrayNeedsJSON }
        var one = ["--follow", "--clear", "--ref", "--chapter", "--search", "--tasks", "--memory"].filter { seen[$0] != nil }
        if seen["--follow"] != nil { one.removeAll { $0 == "--tasks" || $0 == "--memory" } }
        guard one.count <= 1 else { return xrayExclusion }
        if seen["--ref"] == nil, ["--scope", "--full", "--budget-ms"].contains(where: { seen[$0] != nil }) { return xrayWithRef }
        if let v = seen["--chapter"], !anchorOK(v) { return anchorShape }
        if let v = seen["--scope"], !["session", "project", "all"].contains(v) { return scopeShape }
        if let v = seen["--budget-ms"], !budgetOK(v) { return budgetRange }
        if let v = seen["--search"], !searchOK(v) { return searchShape }
        if let v = seen["--ref"] {
            if !refOK(v) { return refText }
            // R1348-i1: a leading "-" as runRef refuses it (dch 1.83.0 reads "--ref -" from stdin, here /dev/null: exit 2);
            // a blank text parses to no ref in dch's grammar (trim of White_Space, then no span).
            if v.hasPrefix("-") || v.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) { return notARef }
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
/// cut it, or 0x13 when dch could not start. `cancel` (the connection closed) ends it as a 0x34 does
/// but sends no frame: SIGTERM (the four agent verbs clean up on it, see DchCtl.agentGrace), SIGKILL
/// to the group the verb's grace later if dch is still unreaped (DchCtlOps.grace: 660 s for the agent
/// verbs, 2 s for the rest, as dch serve 1.45.1+). The cap and timeout kill is CodexHarness.killGroup: SIGTERM to the child's
/// whole process group (Foundation makes it the leader), SIGKILL to the group DchCtl.cancelGrace (2 s) later (#852).
/// QA #729 F1: a dch is SIGTERMed once per request, whatever comes after the cut: dch's ty_on_sig _exits on a
/// second signal (dch.c:6256-6272@v1.54.0) and so would skip its take-back; serve's conn_end cuts only an uncut ctl.
/// #1556: dch serve's MAX_FOLLOW_PER_DEV (serve.c:100@v1.99.0): one device runs at most 2 `--xray --follow` of one
/// session, across its connections; a third cuts that device's oldest as a timeout (kids_note, serve.c:2526-2544).
/// The device is the peer's address, as serve's `kids[i].ip`. The session is its socket's st_dev and st_ino
/// (serve's fino/fdev: `svf` and `SVF` on a case-insensitive volume are one), so a session re-created under the
/// same name is a new one; with no socket to stat, its path. A job leaves when its run ends (serve's "F <pid> ").
final class DchFollows: @unchecked Sendable {
    static let shared = DchFollows()
    static let perDevice = 2

    struct Key: Hashable {
        let device: String
        let path: String   // "" once the socket was stat'ed
        let dev: UInt64
        let ino: UInt64
    }

    private let lock = NSLock()
    private var live: [(key: Key, job: DchCtlJob)] = []   // oldest first

    /// `name`'s session in socket dir `dir`, as `device` follows it.
    static func key(device: String, dir: String, name: String) -> Key {
        let path = "\(dir)/\(name).sock"
        var st = stat()
        guard stat(path, &st) == 0 else { return Key(device: device, path: path, dev: 0, ino: 0) }
        return Key(device: device, path: "", dev: UInt64(UInt32(bitPattern: st.st_dev)), ino: UInt64(st.st_ino))
    }

    /// Adds `job` under `key`; returns the jobs it puts past the cap, oldest first, taken out (serve clears their
    /// follow before the SIGUSR1, so a cut one is not counted again). `job` itself is never one: it is the newest.
    func add(_ job: DchCtlJob, _ key: Key) -> [DchCtlJob] {
        lock.withLock {
            live.append((key, job))
            var cut: [DchCtlJob] = []
            while live.filter({ $0.key == key }).count > Self.perDevice, let i = live.firstIndex(where: { $0.key == key }) {
                cut.append(live.remove(at: i).job)
            }
            return cut
        }
    }

    func remove(_ job: DchCtlJob) { lock.withLock { live.removeAll { $0.job === job } } }

    /// The jobs counted under `key` (tests).
    func count(_ key: Key) -> Int { lock.withLock { live.filter { $0.key == key }.count } }
}

final class DchCtlJob: @unchecked Sendable {
    enum Stop { case none, term, killGroup }

    private let lock = NSLock()      // pid, ended, cancelled, grace, stopping
    private let sendLock = NSLock()  // chunks, then the one final frame
    private var pid: pid_t = 0
    private var ended = false
    private var cancelled = false
    /// A server stop came (serverStop): its 2 s grace wins over the verb's that run() sets (QA #729 INFO-1).
    private var stopping = false
    private var sent = 0
    /// The SIGKILL grace after a SIGTERM (DchCtlOps.grace of the verb). Set in run(), before the pid.
    private var grace = DchCtl.cancelGrace
    /// The timeout's 0x33 goes here, so the timer holds nothing but a weak job (QA #688 F1). Set in run(), before the
    /// spawn: #1556's cut (cutTimeout) may come from another connection as soon as the pid is set.
    private var timeoutReply: (@Sendable (Data) -> Void)?
    /// #1680 (under sendLock): the first run of a counted follow holds its stderr, at most busyText's length, until
    /// stdout or other stderr shows it is not a busy start. `waiting` (under lock): busy, between the two runs.
    private var hold = false
    private var held: [UInt8] = []
    private var waiting = false
    /// #1693 (under lock): the run was reaped (pid 0 after a spawn), and a cut found it so: busy or not, it is not rerun.
    private var reapedRun = false
    private var cutAfterReap = false

    /// Ends the request once: true for the one caller that did. `running` (the timeout): only while
    /// dch is not yet reaped (one that exited in time ends with its own exit) and not cut by a 0x34
    /// (serve's ctl_tick: one why per request).
    /// A 0x34 already SIGTERMed it, so nothing is signalled here then (QA #729 F1): its grace timer stands.
    private func end(_ stop: Stop, running: Bool = false) -> Bool {
        let pid: pid_t? = lock.withLock {
            guard !ended, !(running && (self.pid == 0 || cancelled)) else { return nil }
            ended = true
            return cancelled ? 0 : self.pid
        }
        guard let pid else { return false }
        guard pid > 0 else { return true }
        switch stop {
        case .none: break
        case .term: term(pid)
        case .killGroup: CodexHarness.killGroup(pid, grace: DchCtl.cancelGrace)   // #852: serve's cap/timeout cut, CTL_GRACE_MS
        }
        return true
    }

    func cancel() { _ = end(.term) }

    /// The timeout's cut, and #1556's: a newer `--xray --follow` of the session from this device ends this one as
    /// a timeout does (serve.c:2198-2208@v1.99.0: ctl_cut "timeout", 0x33 {"exit": 2, "why": "timeout"}, the
    /// connection stays warm). Only while dch runs (serve: an unreaped, uncut ctl); the end and its 0x33 under
    /// one sendLock, as the cap's: between the two the reap could end run(), whose defer clears timeoutReply.
    func cutTimeout() {
        sendLock.withLock {
            if end(.killGroup, running: true) { timeoutReply?(DchCtl.exitFrame(2, why: "timeout")) }
            // #1680: cut between a busy start and its rerun (serve: "cut while it waited: its 0x33 now"); the rerun then runs nothing.
            else if lock.withLock({ if !ended && !cancelled && reapedRun { cutAfterReap = true }; return waiting }), end(.none) { timeoutReply?(DchCtl.exitFrame(2, why: "timeout")) }
        }
    }

    /// #1013: no dch of this job is left to reap (never spawned, or reaped). Until then a cut's early 0x33 leaves
    /// the connection's ctl slot taken, as dch serve's ctl stays c->ctl > 0 until its reap (serve.c:1603, :1632@v1.73.0).
    var reaped: Bool { lock.withLock { pid == 0 } }

    /// #852: a server stop, as dch serve's: an uncut ctl is cut with DchCtl.cancelGrace whatever the verb
    /// (ctl_grace, serve.c:1261-1267@v1.54.0). QA #729 F1: one already cut (a 0x34, a timeout, a cap) gets no
    /// second SIGTERM; its group SIGKILL only comes no later than DchCtl.cancelGrace from now (ctl_wait under
    /// g_stop, serve.c:1502-1503@v1.54.0). The earlier timer stays, guarded by the pid like every other.
    func serverStop() {
        let cut: pid_t? = lock.withLock {
            (grace, stopping) = (DchCtl.cancelGrace, true)
            return cancelled || ended ? pid : nil
        }
        guard let cut else { return cancel() }
        if cut > 0 { killGroup(cut, after: DchCtl.cancelGrace) }
    }

    /// The one SIGTERM path, a 0x34's and a close's: SIGTERM to dch, then SIGKILL to its group `grace` later.
    private func term(_ pid: pid_t) {
        // #1024: through the seam, on the caller's queue (a close's, 0x34's and stop's: the connection queue); only -pid sends stay off it.
        _ = CodexHarness.sendSignal(pid, SIGTERM)
        killGroup(pid, after: lock.withLock { grace })
    }

    /// SIGKILL to dch's group `delay` from now while it is still unreaped. A reaped dch left pid 0, so
    /// nothing is signalled however late, and a recycled pid never.
    private func killGroup(_ pid: pid_t, after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }   // run() returned: dch was reaped
            self.lock.withLock { if self.pid == pid, CodexHarness.mayKillGroup(pid) { _ = CodexHarness.sendSignal(-pid, SIGKILL) } }
        }
    }

    /// 0x34, as dch 1.42 serve's ctl_cut "cancel": nothing more is forwarded, dch gets SIGTERM and,
    /// still unreaped its verb's grace later, its group SIGKILL; once reaped the request ends with
    /// 0x33 {"exit": 2, "why": "cancel"}. Nothing once it ended or was already cancelled (a late 0x34).
    func cancelRequest() {
        let pid: pid_t? = lock.withLock {
            guard !ended, !cancelled else { return nil }
            cancelled = true
            return self.pid
        }
        guard let pid, pid > 0 else { return }   // before the spawn: run() sees `cancelled` and runs nothing
        term(pid)
    }

    /// Blocks its thread (never the connection's queue) until dch exits or is killed.
    /// #1680: `holdBusy` (serve's ctl_hold, a counted follow's first run): when it ends with exit 1, no stdout and stderr
    /// exactly "dch: busy\n" (the master's 4 subscriber slots full while the oldest is cut), nothing is sent, the job
    /// stays open and this returns true: the caller waits retryDelay and runs it once more. Else false, as before.
    @discardableResult
    func run(path: String, argv: [String], env: [String: String], cwd: String?, follow: Bool, cap: Int,
             holdBusy: Bool = false, afterReap: @Sendable () -> Void = {}, timeout: TimeInterval, grace: TimeInterval, after: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = DchCtl.after,
             send: @escaping @Sendable (Data) -> Bool, reply: @escaping @Sendable (Data) -> Void) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = argv
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: cwd ?? NSHomeDirectory(), isDirectory: true)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        // #841: the reap writes `wake`, so the pump stops waiting on a pipe a leftover writer holds.
        // QA #688 F1: closed here on every return. The early returns never spawn, so nothing writes it;
        // past the spawn, run() returns only after exited.wait(), which follows the handler's one write,
        // and after the pump, the one reader: no write or poll can reach a closed (or reused) fd number.
        var wake: [Int32] = [-1, -1]
        guard Darwin.pipe(&wake) == 0 else {
            if end(.none) { reply(DchControlOps.error("dch could not be run")) }
            return false
        }
        defer { Darwin.close(wake[0]); Darwin.close(wake[1]) }
        // A closed connection keeps its ctlJob, and `reply` holds the connection: clear it, or the two hold each other.
        // #1680: not while it waits for its rerun, which a cut in between needs.
        var again = false
        defer { if !again { sendLock.withLock { timeoutReply = nil } } }
        for fd in wake { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }   // no forkpty child inherits them
        sendLock.withLock { timeoutReply = reply; hold = holdBusy; held = [] }
        let exited = DispatchSemaphore(value: 0), poke = wake[1]
        // Cleared once reaped: a late kill must not signal a recycled pid.
        p.terminationHandler = { [lock] _ in
            lock.withLock { self.pid = 0; self.reapedRun = true }
            var b: UInt8 = 0
            _ = Darwin.write(poke, &b, 1)
            exited.signal()
        }
        lock.lock()   // a cancel either sees the pid or stops the spawn
        if !stopping { self.grace = grace }   // QA #729 INFO-1: a stop that came first keeps its 2 s
        waiting = false; reapedRun = false; cutAfterReap = false
        guard !ended else { lock.unlock(); return false }
        if cancelled {   // a 0x34 that came before the spawn: nothing runs
            ended = true
            lock.unlock()
            reply(DchCtl.exitFrame(2, why: "cancel"))
            return false
        }
        do { try p.run() } catch {
            lock.unlock()
            if end(.none) { reply(DchControlOps.error("dch could not be run")) }
            return false
        }
        pid = p.processIdentifier
        lock.unlock()
        if !follow {
            // QA #688 F1: weak, so a finished job (and what it holds) goes now, not when the timer fires.
            after(timeout) { [weak self] in self?.cutTimeout() }   // gone: it ended
        }
        pump([(out.fileHandleForReading, DchFrame.ctlStdout), (err.fileHandleForReading, DchFrame.ctlStderr)],
             woken: wake[0], follow: follow, cap: cap, send: send, reply: reply)
        exited.wait()
        let code = p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
        let frame = lock.withLock { cancelled } ? DchCtl.exitFrame(2, why: "cancel") : DchCtl.exitFrame(code)
        afterReap()
        sendLock.withLock {
            if hold {
                hold = false
                let live = lock.withLock { !ended && !cancelled }
                if live, held == DchCtl.busyText, code == 1, p.terminationReason == .exit {
                    // #1693: a cut that came after the reap (cutTimeout saw pid 0): the job ends here with its 0x33, no rerun.
                    if lock.withLock({ cutAfterReap }) {
                        held = []
                        if end(.none) { reply(DchCtl.exitFrame(2, why: "timeout")) }
                        return
                    }
                    held = []
                    lock.withLock { waiting = true }
                    again = true
                    return
                }
                if live, !held.isEmpty { sent += held.count; _ = send(DchFrame.encode(DchFrame.ctlStderr, held)) }
                held = []
            }
            if end(.none) { reply(frame) }
        }
        return again
    }

    /// #841 (QA #680 INFO-3): dch's stdout and stderr, each chunk as it comes (--say/--stop/--revive
    /// stream progress), as dch 1.42 serve's ctl_read: once dch is reaped an empty pipe is done, so a
    /// leftover writer (a process dch started that kept the pipe) holds neither the 0x33 nor the slot.
    /// Until the reap the pipes are read even after the end (dropped), so a child writing into a full
    /// pipe still exits.
    private func pump(_ pipes: [(FileHandle, UInt8)], woken: Int32, follow: Bool, cap: Int,
                      send: (Data) -> Bool, reply: (Data) -> Void) {
        var open = pipes.map { (fd: $0.0.fileDescriptor, type: $0.1) }
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
        if hold {
            if type == DchFrame.ctlStderr, held.count + chunk.count <= DchCtl.busyText.count { held += chunk; return }
            hold = false   // not a busy start: what was held goes first, in order
            if !held.isEmpty { sent += held.count; _ = send(DchFrame.encode(DchFrame.ctlStderr, held)); held = [] }
        }
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
