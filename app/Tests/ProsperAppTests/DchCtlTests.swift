import Darwin
import Network
import os
import XCTest
@testable import ProsperApp

/// #838: the remote-frames "ctl" op (0x30 → 0x31/0x32 chunks, then 0x33). The "dch" every test runs
/// is a /bin/sh script in a tempDir(), never dch; frames go to sendOverride, the NWConnection never
/// starts. Children are killed by the pids they record, never by name.
final class DchCtlTests: XCTestCase {
    private final class Frames: @unchecked Sendable {
        let lock = NSLock()
        var all: [Data] = []
    }

    private struct Rig {
        let conn: DchConnection
        let queue: DispatchQueue
        let frames: Frames
        let closes: Recorder
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t += s } }
    }

    /// #856: DchCtlOps.after's recorder: each armed timeout's delay and its fire, run only by hand.
    /// One never armed reads nil and fires nothing, so a failing test fails instead of trapping.
    private final class Timers: @unchecked Sendable {
        private let lock = NSLock()
        private var armed: [(delay: TimeInterval, fire: @Sendable () -> Void)] = []
        func add(_ d: TimeInterval, _ f: @escaping @Sendable () -> Void) { lock.withLock { armed.append((d, f)) } }
        var count: Int { lock.withLock { armed.count } }
        func delay(_ i: Int) -> TimeInterval? { lock.withLock { armed.indices.contains(i) ? armed[i].delay : nil } }
        func fire(_ i: Int) { lock.withLock { armed.indices.contains(i) ? armed[i].fire : nil }?() }
    }

    private func rig(_ script: String? = nil, timeout: TimeInterval = 60, agentTimeout: TimeInterval = 660,
                     cap: Int = 8 << 20, reached: Recorder? = nil, timers: Timers? = nil) -> Rig {
        let queue = DispatchQueue(label: "test.dchconn.ctl")
        let frames = Frames(), closes = Recorder()
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { @Sendable _ in closes.add() })
        conn.sendOverride = { f in frames.lock.withLock { frames.all.append(f) } }
        let sock = tempDir("ctl-sock").path
        conn.ctl.path = { reached?.add(); return script }
        conn.ctl.env = { ["DCH_SOCKET_DIR": sock, "PATH": "/usr/bin:/bin"] }
        conn.ctl.timeout = timeout
        conn.ctl.agentTimeout = agentTimeout
        conn.ctl.cap = cap
        if let timers { conn.ctl.after = { timers.add($0, $1) } }
        conn.clipboard.enabled = { false }
        conn.commands.enabled = { false }
        // QA #688 F2: every default that forks dch (DchCommand.dchPath, against the real socket dir) is seamed.
        conn.listSessions = { [] }
        conn.kill = { _ in }
        conn.rename = { _, _ in nil }
        conn.spawn = { _, _, _, _, _, _ in throw PtyChild.PtyError.forkFailed }
        addTeardownBlock { queue.sync { conn.close() } }
        return Rig(conn: conn, queue: queue, frames: frames, closes: closes)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    /// A fake dch: `body` after a shebang, with $D its own dir. Every pid it writes to $D/pid or
    /// $D/kid is SIGKILLed at teardown if still alive.
    private func fake(_ body: String) throws -> (path: String, dir: URL) {
        let dir = tempDir("ctl-fake")
        let path = dir.appendingPathComponent("dch").path
        try "#!/bin/sh\nD='\(dir.path)'\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        addTeardownBlock {
            for f in ["pid", "kid"] {
                if let s = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8),
                   let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, Darwin.kill(pid, 0) == 0 {
                    Darwin.kill(pid, SIGKILL)
                }
            }
        }
        return (path, dir)
    }

    private static func ctl(_ argv: [String], _ extra: [String: Any] = [:]) -> Data {
        DchFrame.encode(DchFrame.ctl, json: extra.merging(["argv": argv]) { $1 })
    }
    private static func type(_ f: Data) -> UInt8 { f[f.startIndex] }
    private static func body(_ f: Data) -> Data { f.subdata(in: (f.startIndex + 5)..<f.endIndex) }
    private static func object(_ f: Data?) -> [String: Any] {
        f.flatMap { (try? JSONSerialization.jsonObject(with: body($0))) as? [String: Any] } ?? [:]
    }

    private func all(_ r: Rig) -> [Data] { r.frames.lock.withLock { r.frames.all } }
    private func send(_ r: Rig, _ frame: Data) { r.queue.sync { r.conn.ingest(frame) } }
    private func bytes(_ r: Rig, _ type: UInt8) -> Data {
        all(r).filter { Self.type($0) == type }.map(Self.body).reduce(Data(), +)
    }
    private func finals(_ r: Rig) -> [Data] {
        all(r).filter { [DchFrame.ctlExit, DchFrame.error].contains(Self.type($0)) }
    }

    @discardableResult
    private func wait(_ secs: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date() + secs
        while Date() < end { if cond() { return true }; usleep(20_000) }
        return cond()
    }

    private func pid(_ dir: URL, _ name: String) -> pid_t? {
        var p: pid_t?
        wait(5) {
            p = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return p != nil
        }
        return p
    }

    /// The pid a fake recorded, read once (no wait): nil when it never got that far.
    private func recorded(_ dir: URL) -> pid_t? {
        (try? String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func dead(_ pid: pid_t?) -> Bool {
        guard let pid else { return false }
        return wait(5) { Darwin.kill(pid, 0) != 0 }
    }

    // MARK: - The allowlist

    func testAllowlistMatrix() {
        let ok: [[String]] = [
            ["--read", "alpha"], ["--read", "alpha", "--ansi"], ["--read", "alpha", "--cursor", "--ansi"],
            ["--read", "alpha", "--recent"], ["--read", "alpha", "--recent", "40", "--ansi"],
            ["--read", "alpha", "--recent", "65535"], ["--read", "alpha", "--recent", "00001"], ["--read", "alpha", "--recent", "--ansi"],
            ["--send", "alpha", "hello", "-k", "x"], ["--send", "alpha", "--", "-k"], ["--send", "alpha", "-"],
            ["--run", "alpha", "ls", "-la"], ["--keys", "alpha", "ctrl+c", "up"],
            ["--follow", "alpha"], ["--status", "alpha"], ["-k", "alpha"], ["-d", "alpha"],
            ["-m", "alpha", ""], ["-m", "alpha", "--all"],
            ["--spawn", "alpha"], ["--spawn", "alpha", "--", "/bin/sh", "-c", "x"], ["--spawn", "alpha", "claude"],
            ["--history", "--json"],
            ["--revive", "alpha", "--json"], ["--revive", "work.1700000000.json", "--as", "alpha-2", "--no-message", "--json"],
            ["--pin", "alpha", "beta", "--json"], ["--unpin", "alpha", "--json"], ["--forget", "alpha", "--json"],
            ["--forget", "--all", "--json"], ["--stop", "alpha", "beta", "--json"],
            ["--say", "alpha", "--json", "--", "carry", "on"], ["--say", "alpha", "--json", "--", "-k"],
            ["--send", "alpha"] + Array(repeating: "w", count: 1022),
            ["--read", String(repeating: "n", count: 255)], ["--read", "naïve é"],
        ]
        for argv in ok { XCTAssertNil(DchCtl.refusal(argv, create: true), "\(argv)") }
        let refused: [([String], String)] = [
            ([], "ctl needs a verb and its arguments"), (["--status"], "ctl needs a verb and its arguments"),
            (["--config", "x"], "ctl does not run --config"), (["serve", "--bind"], "ctl does not run serve"),
            (["-h", "x"], "ctl does not run -h"), (["--help", "x"], "ctl does not run --help"),
            (["--restart", "alpha"], "ctl does not run --restart"), (["--meta", "alpha", "{}"], "ctl does not run --meta"),
            (["-kl", "x"], "ctl does not run -kl"), (["--wait", "alpha"], "ctl does not run --wait"),
            (["--read", "alpha", "--config"], "ctl does not allow --config with --read"),
            (["--read", "alpha", "x"], "ctl does not allow x with --read"),
            (["--read", "alpha", "--recent", "5x"], "--recent wants 1..65535 lines"),
            (["--read", "alpha", "--recent", "0"], "--recent wants 1..65535 lines"),
            (["--read", "alpha", "--recent", "65536"], "--recent wants 1..65535 lines"),
            (["--read", "alpha", "--recent", "000001"], "--recent wants 1..65535 lines"),
            (["--send", "alpha"] + Array(repeating: "w", count: 1023), "too many arguments"),
            (["--read", "serve"], "invalid session name"), (["--pin", "serve", "--json"], "invalid session name"),
            (["--read", "alpha", "-h"], "ctl does not allow -h with --read"),
            (["--send", "alpha", "-k", "beta"], "ctl does not allow -k with --send"),
            (["--run", "alpha", "--config", "x"], "ctl does not allow --config with --run"),
            (["--keys", "alpha", "--ls-json"], "ctl does not allow --ls-json with --keys"),
            (["--spawn", "alpha", "--size", "80x24"], "ctl does not allow --size with --spawn"),
            (["--spawn", "alpha", "--env", "A=1"], "ctl does not allow --env with --spawn"),
            (["--follow", "alpha", "-k"], "--follow takes nothing after the session name"),
            (["--status", "alpha", "beta"], "--status takes nothing after the session name"),
            (["-k", "alpha", "beta"], "-k takes nothing after the session name"),
            (["-d", "alpha", "--all"], "-d takes nothing after the session name"),
            (["-m", "alpha", "a", "b"], "-m takes a session name and an alias"),
            (["-m", "alpha"], "-m takes a session name and an alias"),
            (["--history"], "ctl needs a verb and its arguments"), (["--history", "alpha"], "--history takes only --json"),
            (["--history", "--json", "-f"], "--history takes only --json"),
            (["--revive", "--all", "--json"], DchControlOps.dashNameRefusal),
            (["--revive", "alpha", "-f"], "ctl does not allow -f with --revive"),
            (["--revive", "alpha", "--as"], "--as needs a session name"),
            (["--revive", "alpha", "--as", "-x"], DchControlOps.dashNameRefusal),
            (["--revive", "alpha", "--as", "a/b"], "invalid session name"),
            (["--pin", "alpha", "-f"], "ctl does not allow -f with --pin"),
            (["--pin", "--all", "--json"], "ctl does not allow --all with --pin"),
            (["--forget", "alpha", "-f", "--json"], "ctl does not allow -f with --forget"),
            (["--forget", "--json"], "--forget takes session names, or --all"),
            (["--forget", "alpha", "--all", "--json"], "--forget takes session names, or --all"),
            (["--pin", "--json"], "--pin needs a session name"),
            (["--revive", "alpha"], "--revive needs --json"), (["--revive", "alpha", "--as", "b", "--no-message"], "--revive needs --json"),
            (["--pin", "alpha"], "--pin needs --json"), (["--unpin", "alpha"], "--unpin needs --json"),
            (["--forget", "alpha"], "--forget needs --json"), (["--forget", "--all"], "--forget needs --json"),
            (["--stop", "alpha", "beta"], "--stop needs --json"), (["--say", "alpha", "--", "hi"], "--say needs --json"),
            (["--say", "alpha", "--", "--json"], "--say needs --json"),
            (["--stop", "--all"], "ctl does not allow --all with --stop"),
            (["--stop", "alpha", "a/b"], "invalid session name"),
            (["--say", "alpha", "hi"], "--say needs -- before its text"),
            (["--say", "alpha", "--json", "hi"], "--say needs -- before its text"),
            (["--say", "--all", "--", "hi"], DchControlOps.dashNameRefusal),
            (["--read", "-alpha"], DchControlOps.dashNameRefusal), (["-k", "--all"], DchControlOps.dashNameRefusal),
            (["--read", ""], "invalid session name"), (["--read", "a/b"], "invalid session name"),
            (["--read", "a\u{1b}[2J"], "invalid session name"), (["--read", "a\u{7f}"], "invalid session name"),
            (["--read", "a\u{85}"], "invalid session name"), (["--read", "a\u{202e}b"], "invalid session name"),
            (["--read", "a\u{2066}b"], "invalid session name"), (["--read", "a\u{2069}"], "invalid session name"),
            (["--read", String(repeating: "n", count: 256)], "invalid session name"),
        ]
        for (argv, why) in refused { XCTAssertEqual(DchCtl.refusal(argv, create: true), why, "\(argv)") }
    }

    func testSpawnAndReviveNeedCreate() {
        for argv in [["--spawn", "alpha"], ["--spawn", "alpha", "--", "/bin/sh"], ["--revive", "alpha", "--json"]] {
            XCTAssertEqual(DchCtl.refusal(argv, create: false), DchCtl.createOff, "\(argv)")
            XCTAssertNil(DchCtl.refusal(argv, create: true), "\(argv)")
        }
        for argv in [["--read", "alpha"], ["--send", "alpha", "x"], ["--history", "--json"], ["--forget", "--all", "--json"]] {
            XCTAssertNil(DchCtl.refusal(argv, create: false), "only --spawn and --revive start a process: \(argv)")
        }
    }

    /// dch dea6fd4: the child dch reads a name with ':' as host:name and dials the next host with
    /// this Mac's identity. Every name position refuses ':'; free text and -m's alias keep it.
    func testAColonNameIsLocalOnly() {
        let refused: [[String]] = [
            ["--read", "h:a"], ["--send", "h:a", "x"], ["--run", "h:a", "ls"], ["--keys", "h:a", "up"], ["--follow", "h:a"],
            ["--status", "h:a"], ["-k", "h:a"], ["-m", "h:a", "A"], ["-d", "h:a"], ["--spawn", "h:a", "--", "/bin/sh"],
            ["--revive", "h:a", "--json"], ["--revive", "alpha", "--as", "h:a", "--json"], ["--revive", "alpha", "--as", ":", "--json"],
            ["--pin", "alpha", "h:a", "--json"], ["--unpin", "h:a", "--json"], ["--forget", "alpha", "h:a", "--json"],
            ["--stop", "h:a", "beta", "--json"], ["--say", "h:a", "--json", "--", "x"], ["--xray", "h:a", "--json"],
            ["--read", ":a"], ["--read", "a:"],
        ]
        for argv in refused { XCTAssertEqual(DchCtl.refusal(argv, create: true), DchCtl.localOnly, "\(argv)") }
        XCTAssertEqual(DchCtl.refusal(["--read", "h:a/b"], create: true), "invalid session name", "name_ok first, as dch")
        let text: [[String]] = [
            ["--send", "alpha", "h:a"], ["--send", "alpha", "--", "h:a"], ["--run", "alpha", "ssh", "h:a"], ["--keys", "alpha", "a:b"],
            ["--say", "alpha", "--json", "--", "h:a"], ["--spawn", "alpha", "h:a"], ["--spawn", "alpha", "--", "/bin/sh", "-c", "h:a"],
            ["-m", "alpha", "h:a"], ["--xray", "alpha", "--ref", "h:a", "--json"], ["--xray", "alpha", "--chapter", "c:1", "--json"],
        ]
        for argv in text { XCTAssertNil(DchCtl.refusal(argv, create: true), "\(argv)") }
    }

    func testCwdMustBeAnAbsoluteExistingDirectoryAndOnlyForSpawn() throws {
        let dir = tempDir("ctl-cwd")
        let file = dir.appendingPathComponent("f")
        try Data().write(to: file)
        XCTAssertNil(DchCtl.cwdRefusal(nil, verb: "--spawn"))
        XCTAssertNil(DchCtl.cwdRefusal(dir.path, verb: "--spawn"))
        XCTAssertNil(DchCtl.cwdRefusal("/", verb: "--spawn"))
        for bad in [file.path, dir.appendingPathComponent("missing").path, "relative/dir", "", 7, ["/"]] as [Any] {
            XCTAssertEqual(DchCtl.cwdRefusal(bad, verb: "--spawn"), DchCtl.noDirectory, "\(bad)")
        }
        XCTAssertEqual(DchCtl.cwdRefusal(dir.path, verb: "--read"), "cwd is only for --spawn")
    }

    /// amendments 3 and 4: --xray's four read-only forms; each flag once, in any order; none behind
    /// create. --chapter takes an anchor, --ref 1-256 bytes with no control, --budget-ms 50-300.
    func testXrayAllowlist() {
        let long = String(repeating: "r", count: 256), anchor = String(repeating: "a", count: 128)
        let ok: [[String]] = [
            ["--xray", "alpha", "--json"], ["--xray", "alpha", "--ref", "why did it stop", "--json"],
            ["--xray", "alpha", "--json", "--ref", "x"], ["--xray", "alpha", "--ref", "x", "--full", "--json"],
            ["--xray", "alpha", "--ref", "x", "--scope", "session", "--full", "--json"],
            ["--xray", "alpha", "--scope", "project", "--ref", "x", "--json"], ["--xray", "alpha", "--ref", "x", "--scope", "all", "--json"],
            ["--xray", "alpha", "--ref", "naïve é ✓", "--json"], ["--xray", "alpha", "--ref", long, "--json"],
            ["--xray", "alpha", "--ref", "-k", "--json"], ["--xray", "alpha", "--ref", "--follow", "--json"],
            ["--xray", "alpha", "--ref", "x", "--budget-ms", "50", "--json"], ["--xray", "alpha", "--budget-ms", "300", "--ref", "x", "--json"],
            ["--xray", "alpha", "--follow", "--json"], ["--xray", "alpha", "--json", "--follow"],
            ["--xray", "alpha", "--chapter", "0", "--json"], ["--xray", "alpha", "--chapter", "c3:turn_12.a-b", "--json"],
            ["--xray", "alpha", "--chapter", "-1", "--json"], ["--xray", "alpha", "--chapter", anchor, "--json"],
        ]
        for argv in ok {
            XCTAssertNil(DchCtl.refusal(argv, create: true), "\(argv)")
            XCTAssertNil(DchCtl.refusal(argv, create: false), "not behind create: \(argv)")
        }
        let scope = "--scope takes session, project or all"
        let refused: [([String], String)] = [
            (["--xray", "alpha"], "--xray needs --json"), (["--xray", "alpha", "--ref", "x"], "--xray needs --json"),
            (["--xray", "alpha", "--json", "-k"], "ctl does not allow -k with --xray"),
            (["--xray", "alpha", "--json", "--config"], "ctl does not allow --config with --xray"),
            (["--xray", "alpha", "--json", "x"], "ctl does not allow x with --xray"),
            (["--xray", "alpha", "--json", "--all"], "ctl does not allow --all with --xray"),
            (["--xray", "alpha", "--json", "--"], "ctl does not allow -- with --xray"),
            (["--xray", "alpha", "--scope", "session", "--json"], "--scope goes with --ref"),
            (["--xray", "alpha", "--full", "--json"], "--full goes with --ref"),
            (["--xray", "alpha", "--follow", "--full", "--json"], "--full goes with --ref"),
            (["--xray", "alpha", "--budget-ms", "100", "--json"], "--budget-ms goes with --ref"),
            (["--xray", "alpha", "--ref", "x", "--scope", "global", "--json"], scope),
            (["--xray", "alpha", "--ref", "x", "--scope", "Session", "--json"], scope),
            (["--xray", "alpha", "--ref", "x", "--scope", "", "--json"], scope),
            (["--xray", "alpha", "--ref", "x", "--scope", "--json"], scope),
            (["--xray", "alpha", "--ref", "x", "--json", "--scope"], "--scope needs a value"),
            (["--xray", "alpha", "--json", "--chapter"], "--chapter needs a value"),
            (["--xray", "alpha", "--ref", "x", "--follow", "--json"], "--xray takes one of --ref, --follow, --chapter"),
            (["--xray", "alpha", "--follow", "--chapter", "1", "--json"], "--xray takes one of --ref, --follow, --chapter"),
            (["--xray", "alpha", "--json", "--json"], "--xray takes --json once"),
            (["--xray", "alpha", "--ref", "x", "--ref", "y", "--json"], "--xray takes --ref once"),
            (["--xray", "-alpha", "--json"], DchControlOps.dashNameRefusal), (["--xray", "--json"], DchControlOps.dashNameRefusal),
            (["--xray", "a/b", "--json"], "invalid session name"), (["--xray"], "ctl needs a verb and its arguments"),
        ]
        for (argv, why) in refused { XCTAssertEqual(DchCtl.refusal(argv, create: true), why, "\(argv)") }
        for bad in ["", anchor + "a", "a b", "a/b", "é", "a\n", " 1", "+3", "a,b", "~x", "a\u{0}"] {
            XCTAssertEqual(DchCtl.refusal(["--xray", "alpha", "--chapter", bad, "--json"], create: true), DchCtl.anchorShape, bad.debugDescription)
        }
        for bad in ["", long + "r", String(repeating: "é", count: 129), "a\u{1b}[2J", "a\u{7f}", "a\u{85}", "a\u{9b}", "a\nb", "a\tb", "a\u{0}",
                    "a\u{200e}", "a\u{200f}", "a\u{202a}", "a\u{202e}b", "a\u{2066}", "a\u{2069}"] {
            XCTAssertEqual(DchCtl.refusal(["--xray", "alpha", "--ref", bad, "--json"], create: true), DchCtl.refText, bad.debugDescription)
        }
        for bad in ["49", "301", "0", "", "1e2", "0050", "-50", "100.0", "abc", "\u{FF15}0"] {
            XCTAssertEqual(DchCtl.refusal(["--xray", "alpha", "--ref", "x", "--budget-ms", bad, "--json"], create: true), DchCtl.budgetRange,
                           bad.debugDescription)
        }
        XCTAssertTrue(DchCtl.follows(["--xray", "alpha", "--follow", "--json"]))
        XCTAssertTrue(DchCtl.follows(["--follow", "alpha"]))
        XCTAssertFalse(DchCtl.follows(["--xray", "alpha", "--json"]))
        XCTAssertFalse(DchCtl.follows(["--xray", "alpha", "--ref", "--follow", "--json"]), "a --ref text, not the flag")
        XCTAssertEqual(DchCtlOps().timeout(of: "--xray"), 60, "--ref and the rest: 60 s")
    }

    /// amendment 3: "xray" is in ops only while the dch ctl runs has --xray: a version gate whose
    /// minimum is a placeholder out of reach today.
    func testXrayOpsFollowTheDchVersion() {
        XCTAssertFalse(DchCtl.hasXray(nil))
        XCTAssertFalse(DchCtl.hasXray([1, 41, 0]))
        XCTAssertFalse(DchCtl.hasXray([998, 99, 99]))
        XCTAssertTrue(DchCtl.hasXray(DchCtl.xrayMinDch))
        XCTAssertTrue(DchCtl.hasXray([999, 0, 1]))
        XCTAssertFalse(DchCtlOps().xray(), "off today, and no test probes a dch")
        func ops(_ xray: Bool) -> [String] {
            DchFrame.machineInfo(deviceID: "d", hostname: "h", wakeId: nil, xray: xray)["ops"] as? [String] ?? []
        }
        XCTAssertFalse(ops(false).contains("xray"))
        XCTAssertTrue(ops(true).contains("xray"))
        XCTAssertTrue(ops(false).contains("ctl"))
        for on in [false, true] {
            let r = rig()
            r.conn.ctl.xray = { on }
            send(r, DchFrame.encode(DchFrame.machineInfo, []))
            XCTAssertTrue(wait(5) { all(r).contains { Self.type($0) == DchFrame.machineInfoResp } })
            let info = Self.object(all(r).first { Self.type($0) == DchFrame.machineInfoResp })
            XCTAssertEqual((info["ops"] as? [String] ?? []).contains("xray"), on, "the 0x08 reply follows the gate")
        }
    }

    /// amendment 3: while the gate is off, a well-formed --xray is one 0x13 and runs nothing; on, it runs.
    /// #841: that 0x13 is a refusal, so the FIN follows it (dch 1.42 golden 32).
    func testXrayIsRefusedWhileTheHostLacksIt() throws {
        let f = try fake("printf '%s\\n' \"$@\" > \"$D/argv\"; printf '{\"chapter\":0}\\n'")
        let r = rig(f.path)
        r.conn.ctl.xray = { false }
        send(r, Self.ctl(["--xray", "alpha", "--chapter", "0", "--json"]))
        XCTAssertTrue(wait(5) { !finals(r).isEmpty })
        XCTAssertEqual(all(r).count, 1)
        XCTAssertEqual(Self.object(finals(r).first)["message"] as? String, DchCtl.xrayOff)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.dir.appendingPathComponent("argv").path), "nothing ran")
        XCTAssertTrue(wait(2) { r.closes.count == 1 }, "the FIN follows the refusal")
        let on = rig(f.path)
        on.conn.ctl.xray = { true }
        send(on, Self.ctl(["--xray", "alpha", "--chapter", "0", "--json"]))
        XCTAssertTrue(wait(5) { finals(on).count == 1 })
        XCTAssertEqual(Self.object(finals(on).last) as NSDictionary, ["exit": 0] as NSDictionary)
        XCTAssertEqual(on.closes.count, 0, "a ctl that ran leaves the connection warm")
        XCTAssertEqual(bytes(on, DchFrame.ctlStdout), Data("{\"chapter\":0}\n".utf8))
        XCTAssertEqual(try String(contentsOf: f.dir.appendingPathComponent("argv"), encoding: .utf8), "--xray\nalpha\n--chapter\n0\n--json\n")
    }

    /// #841 (QA #680 INFO-6): dch serve refuses --xray first, whatever follows (rframe.c ctl_check),
    /// so with the gate off a malformed --xray gets "not supported", not its shape error, then the FIN.
    func testXrayNotSupportedComesBeforeItsShapeError() throws {
        for argv in [["--xray"], ["--xray", "alpha"], ["--xray", "-alpha", "--json"], ["--xray", "alpha", "--json", "--bogus"]] {
            let r = rig("/nonexistent/dch")
            r.conn.ctl.xray = { false }
            send(r, Self.ctl(argv))
            XCTAssertTrue(wait(5) { r.closes.count == 1 }, "\(argv)")
            XCTAssertEqual(all(r).count, 1, "\(argv)")
            XCTAssertEqual(Self.object(all(r).first)["message"] as? String, DchCtl.xrayOff, "\(argv)")
        }
        let on = rig("/nonexistent/dch")
        on.conn.ctl.xray = { true }
        send(on, Self.ctl(["--xray", "alpha"]))
        XCTAssertTrue(wait(5) { on.closes.count == 1 })
        XCTAssertEqual(Self.object(all(on).first)["message"] as? String, "--xray needs --json", "with the gate on, its shape")
    }

    /// amendment 3: --xray --follow streams with no timeout and no cap; a close sends SIGTERM, as for --follow.
    func testXrayFollowHasNoTimeoutAndCloseTermsIt() throws {
        let f = try fake("""
            echo $$ > "$D/pid"; trap 'echo term > "$D/sig"; exit 0' TERM
            /usr/bin/head -c 100 /dev/zero | /usr/bin/tr '\\0' x; while :; do /bin/sleep 0.05; done
            """)
        let r = rig(f.path, timeout: 0.3, cap: 10)
        r.conn.ctl.xray = { true }
        send(r, Self.ctl(["--xray", "alpha", "--follow", "--json"]))
        let script = pid(f.dir, "pid")
        XCTAssertTrue(wait(5) { bytes(r, DchFrame.ctlStdout).count == 100 }, "no cap")
        usleep(800_000)
        XCTAssertEqual(finals(r).count, 0, "no timeout")
        r.queue.sync { r.conn.close() }
        XCTAssertTrue(dead(script))
        XCTAssertEqual(try? String(contentsOf: f.dir.appendingPathComponent("sig"), encoding: .utf8), "term\n")
        XCTAssertEqual(finals(r).count, 0)
    }

    /// An unstubbed test never reaches a real dch: under XCTest the default path is a test's override or nil.
    func testTheDefaultPathRunsNoDchUnderXCTest() {
        XCTAssertNil(DchCommand.dchPathOverride)
        XCTAssertNil(DchCtlOps().path())
    }

    // MARK: - Running

    func testReadRoundTripStreamsStdoutAndStderrThenTheExit() throws {
        let f = try fake("""
            printf '%s\\n' "$@" > "$D/argv"; /bin/pwd -P > "$D/pwd"; printf '%s' "$DCH_SOCKET_DIR" > "$D/sock"
            printf 'screen'; printf 'warn' >&2; exit 3
            """)
        let r = rig(f.path)
        let sock = tempDir("ctl-env").path
        r.conn.ctl.env = { ["DCH_SOCKET_DIR": sock, "PATH": "/usr/bin:/bin"] }
        send(r, Self.ctl(["--read", "alpha", "--ansi", "--recent", "5"]))
        XCTAssertTrue(wait(5) { !finals(r).isEmpty })
        let frames = all(r)
        XCTAssertEqual(Self.type(try XCTUnwrap(frames.last)), DchFrame.ctlExit, "0x33 is the last frame")
        XCTAssertEqual(finals(r).count, 1)
        XCTAssertEqual(Self.object(frames.last) as NSDictionary, ["exit": 3] as NSDictionary, "dch's own exit, no why")
        XCTAssertEqual(bytes(r, DchFrame.ctlStdout), Data("screen".utf8))
        XCTAssertEqual(bytes(r, DchFrame.ctlStderr), Data("warn".utf8))
        let argv = try String(contentsOf: f.dir.appendingPathComponent("argv"), encoding: .utf8)
        XCTAssertEqual(argv, "--read\nalpha\n--ansi\n--recent\n5\n", "argv as sent, no shell")
        let home = (NSHomeDirectory() as NSString).resolvingSymlinksInPath
        XCTAssertEqual(try String(contentsOf: f.dir.appendingPathComponent("pwd"), encoding: .utf8), home + "\n",
                       "no cwd: the host user's home")
        XCTAssertEqual(try String(contentsOf: f.dir.appendingPathComponent("sock"), encoding: .utf8), sock, "the env seam's dir")
        XCTAssertFalse(r.queue.sync { r.conn.inFlight }, "the exit ends the request")
    }

    func testSpawnRunsInTheGivenCwd() throws {
        let f = try fake("/bin/pwd -P > \"$D/pwd\"; printf 'alpha\\n'")
        let cwd = tempDir("ctl-spawn-cwd")
        let r = rig(f.path)
        send(r, Self.ctl(["--spawn", "alpha", "--", "/bin/sh"], ["cwd": cwd.path]))
        XCTAssertTrue(wait(5) { !finals(r).isEmpty })
        XCTAssertEqual(Self.object(finals(r).first)["exit"] as? Int, 0)
        XCTAssertEqual(try String(contentsOf: f.dir.appendingPathComponent("pwd"), encoding: .utf8),
                       try XCTUnwrap(realpath(cwd.path, nil).map { p in defer { free(p) }; return String(cString: p) }) + "\n",
                       "pwd -P: /private/var, which NSString's resolving would strip")
    }

    /// The cap: what fits goes out (exactly `cap` bytes), then 0x33 {"exit": 2, "why": "cap"} and nothing
    /// after; the child's whole group (the script and the sleep it started) is killed.
    func testCapKillsTheGroupAndEndsWithCap() throws {
        let f = try fake("""
            echo $$ > "$D/pid"; /bin/sleep 30 & echo $! > "$D/kid"
            /usr/bin/head -c 5000 /dev/zero | /usr/bin/tr '\\0' a; wait
            """)
        let r = rig(f.path, cap: 1000)
        send(r, Self.ctl(["--read", "alpha"]))
        XCTAssertTrue(wait(5) { !finals(r).isEmpty })
        XCTAssertEqual(Self.object(finals(r).first) as NSDictionary, ["exit": 2, "why": "cap"] as NSDictionary)
        XCTAssertTrue(dead(pid(f.dir, "pid")), "the script")
        XCTAssertTrue(dead(pid(f.dir, "kid")), "its child: the group")
        usleep(300_000)
        XCTAssertEqual(bytes(r, DchFrame.ctlStdout).count, 1000, "exactly the cap")
        XCTAssertEqual(Self.type(try XCTUnwrap(all(r).last)), DchFrame.ctlExit, "nothing after the cap")
        XCTAssertFalse(r.queue.sync { r.conn.inFlight })
    }

    func testTimeoutKillsTheGroupAndEndsWithTimeout() throws {
        let f = try fake("echo $$ > \"$D/pid\"; /bin/sleep 30 & echo $! > \"$D/kid\"; echo started; wait")
        let timers = Timers()
        let r = rig(f.path, timeout: 0.5, timers: timers)
        send(r, Self.ctl(["--read", "alpha"]))   // #852: --run has the 660 s timeout now
        // #856: the timeout fires once both pids are written (a 0.5 s timer under load beat the script's start).
        let script = pid(f.dir, "pid"), kid = pid(f.dir, "kid")
        XCTAssertTrue(wait(5) { timers.count == 1 })
        XCTAssertEqual(timers.delay(0), 0.5)
        XCTAssertEqual(finals(r).count, 0)
        timers.fire(0)
        XCTAssertTrue(wait(5) { !finals(r).isEmpty })
        XCTAssertEqual(Self.object(finals(r).first) as NSDictionary, ["exit": 2, "why": "timeout"] as NSDictionary)
        XCTAssertTrue(dead(script))
        XCTAssertTrue(dead(kid))
        usleep(300_000)
        XCTAssertEqual(Self.type(try XCTUnwrap(all(r).last)), DchFrame.ctlExit)
        XCTAssertEqual(finals(r).count, 1)
    }

    /// Review round 1: a timeout that fires after dch was reaped while a child still holds the pipe
    /// ends nothing: the request ends with dch's own exit, not "timeout". #841 review: 2 s of timeout
    /// for a shell that exits at once (0.3 s fired first under full-suite load); the child holds the
    /// pipe 5 s, well past it.
    func testATimeoutAfterTheExitEndsWithTheRealExit() throws {
        let f = try fake("/bin/sleep 5 & echo $! > \"$D/kid\"; echo done; exit 0")
        let r = rig(f.path, timeout: 2)
        let start = Date()
        send(r, Self.ctl(["--status", "alpha"]))
        XCTAssertTrue(wait(10) { !finals(r).isEmpty })
        XCTAssertEqual(Self.object(finals(r).first) as NSDictionary, ["exit": 0] as NSDictionary)
        XCTAssertEqual(bytes(r, DchFrame.ctlStdout), Data("done\n".utf8))
        usleep(useconds_t(max(0, 2.5 - Date().timeIntervalSince(start)) * 1_000_000))   // the timeout has passed
        XCTAssertEqual(Darwin.kill(try XCTUnwrap(pid(f.dir, "kid")), 0), 0, "the child still holds the pipe")
        XCTAssertEqual(finals(r).count, 1)
    }

    /// #856: the timeout's end and its 0x33 are one step. Before, the timer's end() SIGTERMed dch, the reap
    /// ran run() to its return (whose defer clears the timeout's reply) before the timer sent, and the
    /// request never got a final: its connection answered "busy" for good. The kill seam holds the timer
    /// thread right after the SIGTERM until run() returns; with the fix run() waits for the timer's 0x33
    /// instead, so the hold only ends at its 3 s bound.
    func testATimeoutRacingTheReapStillSendsItsFinal() throws {
        let f = try fake("echo $$ > \"$D/pid\"; exec /bin/sleep 30")   // #874: exec keeps the pid, so teardown reaps it
        let returned = DispatchSemaphore(value: 0), replies = Frames()
        let saved = CodexHarness.sendSignal
        defer { CodexHarness.sendSignal = saved }
        CodexHarness.sendSignal = { pid, sig in
            let r = Darwin.kill(pid, sig)
            if sig == SIGTERM, pid < -1 { _ = returned.wait(timeout: .now() + 3) }   // killGroup's SIGTERM only
            return r
        }
        let job = DchCtlJob()
        DispatchQueue.global().async {
            job.run(path: f.path, argv: ["--status", "alpha"], env: ["PATH": "/usr/bin:/bin"], cwd: nil, follow: false,
                    cap: 1 << 20, timeout: 0.05, grace: DchCtl.cancelGrace, send: { _ in true },
                    reply: { d in replies.lock.withLock { replies.all.append(d) } })
            returned.signal()
        }
        XCTAssertTrue(wait(10) { replies.lock.withLock { !replies.all.isEmpty } }, "the timeout's 0x33 is sent")
        XCTAssertEqual(replies.lock.withLock { replies.all }, [DchCtl.exitFrame(2, why: "timeout")])
        XCTAssertEqual(returned.wait(timeout: .now() + 5), .success, "run() returned")
        // The 0.05 s timeout can end the shell before it records its pid: then nothing is left to reap.
        if let p = recorded(f.dir) { XCTAssertTrue(dead(p), "the recorded pid (teardown's reap) is the one the timeout ended") }
    }

    /// #874 (QA #710 INFO-2): DchCtlOps' default `after` (not a recorder) arms a real timer: it fires
    /// once, off the test's thread, and not before its delay. A no-op default would disable every timeout.
    func testTheDefaultTimerFiresAfterItsDelayOffTheTestsThread() throws {
        final class Fired: @unchecked Sendable {
            let lock = NSLock()
            var at: [(Date, Bool)] = []
        }
        let fired = Fired(), done = DispatchSemaphore(value: 0), start = Date()
        DchCtlOps().after(0.3) {
            fired.lock.withLock { fired.at.append((Date(), Thread.isMainThread)) }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "the default fires its closure")
        usleep(200_000)
        let at = fired.lock.withLock { fired.at }
        XCTAssertEqual(at.count, 1, "once")
        let first = try XCTUnwrap(at.first)
        XCTAssertGreaterThanOrEqual(first.0.timeIntervalSince(start), 0.29, "not before its delay")
        XCTAssertFalse(first.1, "on a queue that is not the test's (main) thread")
    }

    /// #874: through a real ctl with the default ops' timer (no Timers recorder), a dch that never exits
    /// is ended by the timeout: 0x33 {"exit": 2, "why": "timeout"} and its pid gone.
    func testTheDefaultTimerEndsADchThatNeverExits() throws {
        let f = try fake("echo $$ > \"$D/pid\"; exec /bin/sleep 30")
        let r = rig(f.path, timeout: 1)
        send(r, Self.ctl(["--status", "alpha"]))
        XCTAssertTrue(wait(10) { finals(r).count == 1 }, "the timeout ended it")
        // Only a dch still unreaped when the timer fires ends with why "timeout".
        XCTAssertEqual(Self.object(finals(r).first) as NSDictionary, ["exit": 2, "why": "timeout"] as NSDictionary)
        // Under load the timer can beat the pid write; a recorded one is gone.
        if let p = recorded(f.dir) { XCTAssertTrue(dead(p), "killed by the timeout") }
    }

    /// #841 (QA #680 INFO-3): as dch 1.42 serve's ctl_read, the request ends at dch's reap: a process
    /// dch started that keeps the pipe open holds neither the 0x33 nor the slot, and what dch wrote
    /// before it exited still goes out first. --follow (no timeout) too.
    func testTheReapEndsTheRequestWhateverHoldsThePipe() throws {
        let f = try fake("/bin/sleep 30 & echo $! >> \"$D/kid\"; /usr/bin/head -c 70000 /dev/zero | /usr/bin/tr '\\0' a; echo done; exit 4")
        let kidFile = f.dir.appendingPathComponent("kid")
        let kids: @Sendable () -> [pid_t] = { (try? String(contentsOf: kidFile, encoding: .utf8))?
            .split(separator: "\n").compactMap { pid_t($0) } ?? [] }
        addTeardownBlock { for k in kids() where k > 1 && Darwin.kill(k, 0) == 0 { Darwin.kill(k, SIGKILL) } }   // the leftovers it started
        for argv in [["--status", "alpha"], ["--follow", "alpha"]] {
            let r = rig(f.path)
            let start = Date()
            send(r, Self.ctl(argv))
            XCTAssertTrue(wait(5) { finals(r).count == 1 }, "\(argv)")
            XCTAssertLessThan(Date().timeIntervalSince(start), 5, "\(argv)")
            XCTAssertEqual(Self.object(finals(r).first) as NSDictionary, ["exit": 4] as NSDictionary, "\(argv)")
            XCTAssertEqual(bytes(r, DchFrame.ctlStdout), Data(String(repeating: "a", count: 70000).utf8) + Data("done\n".utf8), "\(argv)")
            XCTAssertTrue(wait(2) { !r.queue.sync { r.conn.inFlight } }, "\(argv): the slot is free")
        }
        XCTAssertEqual(kids().count, 2)
    }

    /// --follow has neither the timeout nor the cap; the client's close sends dch SIGTERM and nothing after.
    func testFollowRunsPastTimeoutAndCapAndCloseTermsIt() throws {
        let f = try fake("""
            echo $$ > "$D/pid"; trap 'echo term > "$D/sig"; exit 0' TERM
            /usr/bin/head -c 100 /dev/zero | /usr/bin/tr '\\0' f; while :; do /bin/sleep 0.05; done
            """)
        let r = rig(f.path, timeout: 0.3, cap: 10)
        send(r, Self.ctl(["--follow", "alpha"]))
        let script = pid(f.dir, "pid")
        XCTAssertTrue(wait(5) { bytes(r, DchFrame.ctlStdout).count == 100 }, "no cap on --follow")
        usleep(800_000)
        XCTAssertEqual(finals(r).count, 0, "no timeout on --follow")
        XCTAssertNotNil(script)
        XCTAssertEqual(Darwin.kill(try XCTUnwrap(script), 0), 0, "still running")
        r.queue.sync { r.conn.close() }
        XCTAssertTrue(dead(script), "the close ended it")
        XCTAssertEqual(try? String(contentsOf: f.dir.appendingPathComponent("sig"), encoding: .utf8), "term\n", "by SIGTERM")
        usleep(300_000)
        XCTAssertEqual(finals(r).count, 0, "nothing after the close")
    }

    /// QA #688 INFO-2 and r4: a close sends dch SIGTERM, which --stop answers by typing its resume
    /// message (past 2 s here: an agent verb's grace is 660 s), and SIGKILL to its group the verb's
    /// grace later only if it is still unreaped: 2 s for --read. No frame either way.
    func testCloseSendsSIGTERMThenSIGKILLsTheGroupAfter2s() throws {
        let f = try fake("""
            echo $$ > "$D/pid"
            trap 'echo term >> "$D/sig"; /bin/sleep 3; echo resumed >> "$D/sig"; exit 0' TERM
            printf '{"stopping":"alpha"}\\n'; while :; do /bin/sleep 0.05; done
            """)
        let r = rig(f.path)
        send(r, Self.ctl(["--stop", "alpha", "--json"]))
        let script = pid(f.dir, "pid")
        XCTAssertTrue(wait(5) { !bytes(r, DchFrame.ctlStdout).isEmpty })
        r.queue.sync { r.conn.close() }
        XCTAssertTrue(wait(8) { (try? String(contentsOf: f.dir.appendingPathComponent("sig"), encoding: .utf8)) == "term\nresumed\n" },
                      "one SIGTERM, then dch's own time to finish: no SIGKILL at 2 s for --stop")
        XCTAssertTrue(dead(script))
        XCTAssertEqual(finals(r).count, 0, "nothing after the close")
        // A --read that outlives the SIGTERM: its group is SIGKILLed 2 s after it, not sooner.
        let g = try fake("""
            echo $$ > "$D/pid"; /bin/sleep 30 & echo $! > "$D/kid"
            trap 'echo term >> "$D/sig"' TERM
            printf 'working\\n'; while :; do /bin/sleep 0.05; done
            """)
        let s = rig(g.path)
        send(s, Self.ctl(["--read", "alpha"]))
        let stuck = pid(g.dir, "pid"), kid = pid(g.dir, "kid")
        XCTAssertTrue(wait(5) { !bytes(s, DchFrame.ctlStdout).isEmpty })
        let start = Date()
        s.queue.sync { s.conn.close() }
        XCTAssertTrue(wait(1.5) { (try? String(contentsOf: g.dir.appendingPathComponent("sig"), encoding: .utf8)) != nil })
        XCTAssertEqual(Darwin.kill(try XCTUnwrap(stuck), 0), 0, "alive inside the grace")
        XCTAssertTrue(dead(stuck), "SIGKILLed")
        XCTAssertTrue(dead(kid), "its group too")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 1.9)
        usleep(300_000)
        XCTAssertEqual(finals(s).count, 0, "nothing after the close")
    }

    /// #841 r4, dch's ruling (2026-11-10): the SIGKILL backstop after a SIGTERM is 660 s for --say,
    /// --stop, --revive and --run (their clean-up on SIGTERM can take tens of seconds),
    /// 2 s for every other verb.
    func testTheSIGKILLGraceIsPerVerb() {
        XCTAssertEqual(DchCtl.agentGrace, 660)
        XCTAssertEqual(DchCtl.cancelGrace, 2)
        let ops = DchCtlOps(), long: Set = ["--say", "--stop", "--revive", "--run"]
        for verb in DchCtl.rules.keys { XCTAssertEqual(ops.grace(of: verb), long.contains(verb) ? 660 : 2, verb) }
    }

    /// A dch that ignores SIGTERM, with a kid in its group, runs `argv`; then a close or a 0x34.
    /// fake()'s teardown SIGKILLs both by their recorded pids.
    private func stuck(_ argv: [String], cancel: Bool, agentGrace: TimeInterval? = nil) throws
        -> (r: Rig, dch: pid_t, kid: pid_t, at: Date) {
        let f = try fake("""
            echo $$ > "$D/pid"; /bin/sleep 30 & echo $! > "$D/kid"
            trap 'echo term >> "$D/sig"' TERM
            printf 'working\\n'; while :; do /bin/sleep 0.05; done
            """)
        let r = rig(f.path)
        if let agentGrace { r.conn.ctl.agentGrace = agentGrace }
        send(r, Self.ctl(argv))
        let dch = try XCTUnwrap(pid(f.dir, "pid")), kid = try XCTUnwrap(pid(f.dir, "kid"))
        XCTAssertTrue(wait(5) { !bytes(r, DchFrame.ctlStdout).isEmpty })
        let at = Date()
        if cancel { send(r, DchFrame.encode(DchFrame.ctlCancel, [])) } else { r.queue.sync { r.conn.close() } }
        XCTAssertTrue(wait(1.5) { (try? String(contentsOf: f.dir.appendingPathComponent("sig"), encoding: .utf8)) != nil },
                      "the SIGTERM: \(argv[0])")
        return (r, dch, kid, at)
    }

    /// #841 r4: an agent verb whose dch outlives the SIGTERM is not SIGKILLed at 2 s, after a close or a
    /// 0x34. Its backstop (660 s, set to 3.5 s here) still ends it and its group; a cancel's 0x33 follows.
    func testAnAgentVerbGetsTheLongGraceOnCloseAndCancel() throws {
        let waiting: [([String], Bool)] = [(["--say", "alpha", "--json", "--", "hi"], false), (["--run", "alpha", "ls"], true)]
        for (argv, cancel) in waiting {
            let s = try stuck(argv, cancel: cancel)
            usleep(useconds_t(max(0, 2.5 - Date().timeIntervalSince(s.at)) * 1_000_000))
            XCTAssertEqual(Darwin.kill(s.dch, 0), 0, "alive past 2 s: \(argv[0])")
            XCTAssertEqual(Darwin.kill(s.kid, 0), 0, "its group too: \(argv[0])")
            XCTAssertEqual(finals(s.r).count, 0, "no 0x33 while it runs: \(argv[0])")
        }
        let backstop: [([String], Bool)] = [(["--stop", "alpha", "--json"], false), (["--revive", "alpha", "--json"], true)]
        for (argv, cancel) in backstop {
            let s = try stuck(argv, cancel: cancel, agentGrace: 3.5)
            usleep(useconds_t(max(0, 2.5 - Date().timeIntervalSince(s.at)) * 1_000_000))
            XCTAssertEqual(Darwin.kill(s.dch, 0), 0, "alive past 2 s: \(argv[0])")
            XCTAssertTrue(dead(s.dch), "SIGKILLed at the backstop: \(argv[0])")
            XCTAssertTrue(dead(s.kid), "its group too: \(argv[0])")
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(s.at), 3.4, argv[0])
            if cancel {
                XCTAssertTrue(wait(5) { finals(s.r).count == 1 })
                XCTAssertEqual(Self.object(finals(s.r).first) as NSDictionary, ["exit": 2, "why": "cancel"] as NSDictionary)
            } else {
                XCTAssertEqual(finals(s.r).count, 0, "nothing after the close")
            }
        }
    }

    /// QA #688 F1: a finished ctl keeps no fd. 20 on one warm connection plus 5 whose dch could not be
    /// run (the p.run() failure path) leave the process's open fd count where it was, long before any
    /// timeout (600 s here) fires.
    func testFinishedCtlsLeaveNoOpenFds() throws {
        let f = try fake("printf ok; printf err >&2")
        func fds() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }
        let r = rig(f.path, timeout: 600)
        send(r, Self.ctl(["--status", "alpha"]))   // the first run's one-time allocations are not counted
        XCTAssertTrue(wait(5) { finals(r).count == 1 })
        usleep(200_000)
        let before = fds()
        XCTAssertGreaterThan(before, 0)
        for i in 2...21 {
            send(r, Self.ctl(["--status", "alpha"]))
            XCTAssertTrue(wait(5) { finals(r).count == i }, "ctl \(i)")
        }
        XCTAssertEqual(finals(r).map(Self.object) as [NSDictionary], Array(repeating: ["exit": 0] as NSDictionary, count: 21))
        let missing = tempDir("ctl-missing").appendingPathComponent("no-dch").path
        for _ in 0..<5 {
            let m = rig(missing, timeout: 600)
            send(m, Self.ctl(["--status", "alpha"]))
            XCTAssertTrue(wait(5) { m.closes.count == 1 })
            XCTAssertEqual(Self.object(finals(m).last)["message"] as? String, "dch could not be run")
        }
        XCTAssertTrue(wait(5) { fds() <= before + 2 }, "fds: \(before) before, \(fds()) after 25 ctls")
    }

    /// QA #688 F1: the timeout's timer holds the job weakly, so a finished job is freed at once, not when
    /// its timeout would have fired.
    func testAFinishedJobIsFreedBeforeItsTimeout() throws {
        let f = try fake("printf ok")
        let replies = Frames()
        weak var gone: DchCtlJob?
        do {
            let job = DchCtlJob()
            gone = job
            job.run(path: f.path, argv: ["--status", "alpha"], env: ["PATH": "/usr/bin:/bin"], cwd: nil, follow: false,
                    cap: 1 << 20, timeout: 600, grace: DchCtl.cancelGrace, send: { _ in true },
                    reply: { d in replies.lock.withLock { replies.all.append(d) } })
        }
        XCTAssertEqual(replies.lock.withLock { replies.all.map(Self.object) } as [NSDictionary], [["exit": 0] as NSDictionary])
        XCTAssertTrue(wait(5) { gone == nil }, "freed long before its 600 s timeout")
        // Closed mid-run: the connection keeps its ctlJob and `reply` holds the connection, so the job
        // must let go of `reply` once run() returns, or the two hold each other for good.
        final class Owner: @unchecked Sendable { var job: DchCtlJob? }
        let g = try fake("echo $$ > \"$D/pid\"; trap 'exit 0' TERM; while :; do /bin/sleep 0.05; done")
        let ran = DispatchSemaphore(value: 0)
        weak var held: DchCtlJob?
        do {
            let owner = Owner(), job = DchCtlJob()
            owner.job = job
            held = job
            DispatchQueue.global().async {
                job.run(path: g.path, argv: ["--stop", "alpha", "--json"], env: ["PATH": "/usr/bin:/bin"], cwd: nil,
                        follow: false, cap: 1 << 20, timeout: 600, grace: DchCtl.agentGrace, send: { _ in true },
                        reply: { _ in _ = owner.job })
                ran.signal()
            }
            XCTAssertNotNil(pid(g.dir, "pid"), "dch is running")
            job.cancel()   // the connection's close
        }
        XCTAssertEqual(ran.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(wait(5) { held == nil }, "a closed connection's job is freed with it")
    }

    /// QA #688 INFO-5: exitFrame sorts its keys, so the cancel 0x33 is serve's bytes whatever the
    /// dictionary's order (each instance hashes with its own seed, so 64 tries see both orders).
    func testExitFrameKeysAreSorted() {
        for _ in 0..<64 {
            XCTAssertEqual(Self.body(DchCtl.exitFrame(2, why: "cancel")), Data(#"{"exit":2,"why":"cancel"}"#.utf8))
        }
        XCTAssertEqual(Self.body(DchCtl.exitFrame(7)), Data(#"{"exit":7}"#.utf8))
    }

    /// amendment 2: chunks go out as dch writes them, before it exits (--say/--stop/--revive stream progress).
    func testStdoutStreamsBeforeTheExit() throws {
        let f = try fake("""
            echo $$ > "$D/pid"; printf '{"progress":1}\\n'
            while [ ! -e "$D/go" ]; do /bin/sleep 0.05; done; printf '{"done":true}\\n'
            """)
        let r = rig(f.path)
        send(r, Self.ctl(["--say", "alpha", "--json", "--", "go", "on"]))
        XCTAssertTrue(wait(5) { bytes(r, DchFrame.ctlStdout) == Data("{\"progress\":1}\n".utf8) }, "before dch exits")
        XCTAssertEqual(finals(r).count, 0)
        XCTAssertEqual(Darwin.kill(try XCTUnwrap(pid(f.dir, "pid")), 0), 0, "dch still running")
        try Data().write(to: f.dir.appendingPathComponent("go"))
        XCTAssertTrue(wait(5) { !finals(r).isEmpty })
        XCTAssertEqual(Self.object(finals(r).first) as NSDictionary, ["exit": 0] as NSDictionary)
        XCTAssertEqual(bytes(r, DchFrame.ctlStdout), Data("{\"progress\":1}\n{\"done\":true}\n".utf8))
    }

    /// amendment 2: --say, --stop and --revive wait for an agent: 660 s; every other non-follow verb 60 s.
    /// #852: --run too, as dch serve 1.45.0's CTL_LONG (rframe.c:470@v1.45.0, v1.57.0 :474): typing into an agent can take ~60 s.
    func testTheTimeoutIsPerVerb() throws {
        let ops = DchCtlOps()
        for v in ["--say", "--stop", "--revive", "--run"] { XCTAssertEqual(ops.timeout(of: v), 660, v) }
        for v in ["--read", "--send", "--keys", "--status", "-k", "-m", "-d", "--spawn", "--history",
                  "--pin", "--unpin", "--forget"] { XCTAssertEqual(ops.timeout(of: v), 60, v) }
        // #856: each ctl's armed delay is read off the timer seam, and only --status's timer is fired.
        let f = try fake("[ \"$1\" = --status ] && { echo $$ > \"$D/pid\"; exec /bin/sleep 30; }; printf ok")
        let timers = Timers()
        let r = rig(f.path, timeout: 0.3, agentTimeout: 20, timers: timers)
        for (argv, delay, want) in [(["--stop", "alpha", "--json"], 20, ["exit": 0]), (["--status", "alpha"], 0.3, ["exit": 2, "why": "timeout"]),
                                    (["--revive", "alpha", "--json"], 20, ["exit": 0]), (["--say", "alpha", "--json", "--", "hi"], 20, ["exit": 0]),
                                    (["--run", "alpha", "ls"], 20, ["exit": 0])]
                as [([String], TimeInterval, [String: Any])] {
            let n = finals(r).count, i = timers.count
            send(r, Self.ctl(argv))
            XCTAssertTrue(wait(10) { timers.count == i + 1 }, "\(argv)")
            XCTAssertEqual(timers.delay(i), delay, "\(argv)")
            if argv[0] == "--status" {
                XCTAssertNotNil(pid(f.dir, "pid"), "recorded before the fire, so teardown can reap it")
                timers.fire(i)
            }
            XCTAssertTrue(wait(10) { finals(r).count == n + 1 }, "\(argv)")
            XCTAssertEqual(Self.object(finals(r).last) as NSDictionary, want as NSDictionary, "\(argv)")
        }
        XCTAssertTrue(dead(pid(f.dir, "pid")), "--status's sleep: recorded for teardown, ended by the fired timeout")
    }

    func testFollowEndsWithTheRealExitWhenTheSessionEnds() throws {
        let f = try fake("printf 'frame'; exit 0")
        let r = rig(f.path, timeout: 0.01)
        send(r, Self.ctl(["--follow", "alpha"]))
        XCTAssertTrue(wait(5) { !finals(r).isEmpty })
        XCTAssertEqual(Self.object(finals(r).first) as NSDictionary, ["exit": 0] as NSDictionary)
        XCTAssertEqual(bytes(r, DchFrame.ctlStdout), Data("frame".utf8))
    }

    /// One ctl at a time per connection: another meanwhile is answered "busy" at once and runs nothing.
    /// #841: dch 1.42 serve's coded busy, byte for byte (its golden 42), and nothing closes.
    func testASecondCtlWhileOneRunsIsBusy() throws {
        let f = try fake("echo x >> \"$D/runs\"; echo $$ > \"$D/pid\"; while [ ! -e \"$D/go\" ]; do /bin/sleep 0.05; done; printf done")
        let r = rig(f.path)
        send(r, Self.ctl(["--status", "alpha"]))
        XCTAssertTrue(wait(5) { FileManager.default.fileExists(atPath: f.dir.appendingPathComponent("runs").path) })
        send(r, Self.ctl(["--status", "beta"]))
        send(r, Self.ctl(["--bogus", "beta"]))   // busy before any check, as serve's ctl_action
        let busy = finals(r)
        XCTAssertEqual(busy, [DchCtl.busy, DchCtl.busy])
        XCTAssertEqual(DchCtl.busy, RemoteFramesGoldenTests.unhex(
            "13 00000047 7b22636f6465223a2262757379222c226d657373616765223a22612063746c20697320616c72656164792072756e6e696e67206f6e207468697320636f6e6e656374696f6e227d"),
                       "dch serve.c BUSY_JSON")
        XCTAssertEqual(r.closes.count, 0, "busy closes nothing")
        try Data().write(to: f.dir.appendingPathComponent("go"))
        XCTAssertTrue(wait(5) { finals(r).count == 3 })
        XCTAssertEqual(finals(r).dropFirst(2).first.map(Self.type), DchFrame.ctlExit, "the running one went on")
        send(r, Self.ctl(["--status", "gamma"]))
        XCTAssertTrue(wait(5) { finals(r).count == 4 }, "free again once the first ended")
        XCTAssertEqual(try String(contentsOf: f.dir.appendingPathComponent("runs"), encoding: .utf8), "x\nx\n")
    }

    // MARK: - Amendment 4: 0x34 cancel, warm reuse, idle close

    /// 0x34 SIGTERMs dch; the request still ends with its one 0x33. #841, as dch 1.42 serve (its golden
    /// 41): {"exit": 2, "why": "cancel"} whatever dch exits with, and nothing dch writes after the 0x34.
    func testCancelSIGTERMsAndEndsWithWhyCancel() throws {
        let f = try fake("""
            echo $$ > "$D/pid"; trap 'printf bye; exit 7' TERM
            printf 'working\\n'; while :; do /bin/sleep 0.05; done
            """)
        let r = rig(f.path)
        send(r, Self.ctl(["--read", "alpha"]))
        XCTAssertTrue(wait(5) { !bytes(r, DchFrame.ctlStdout).isEmpty })
        send(r, DchFrame.encode(DchFrame.ctlCancel, []))
        XCTAssertTrue(wait(5) { !finals(r).isEmpty })
        XCTAssertEqual(Self.object(finals(r).first) as NSDictionary, ["exit": 2, "why": "cancel"] as NSDictionary)
        XCTAssertEqual(bytes(r, DchFrame.ctlStdout), Data("working\n".utf8), "no output after the 0x34")
        XCTAssertTrue(dead(pid(f.dir, "pid")))
        send(r, DchFrame.encode(DchFrame.ctlCancel, []))
        usleep(300_000)
        XCTAssertEqual(finals(r).count, 1, "exactly one final; a second 0x34 is late and ignored")
        XCTAssertEqual(Self.type(try XCTUnwrap(all(r).last)), DchFrame.ctlExit)
        XCTAssertEqual(r.closes.count, 0, "the connection stays open")
    }

    /// #841: a dch that outlives its 0x34's SIGTERM gets SIGKILL on its whole group 2 s later (serve's
    /// CTL_GRACE_MS), not sooner; a second 0x34 meanwhile sends nothing more, and the timeout passing
    /// meanwhile changes nothing (one why per request, serve's ctl_tick).
    func testCancelEscalatesToSIGKILLOfTheGroupAfter2s() throws {
        let f = try fake("""
            echo $$ > "$D/pid"; /bin/sleep 30 & echo $! > "$D/kid"
            trap 'echo term >> "$D/sig"' TERM
            printf 'working\\n'; while :; do /bin/sleep 0.05; done
            """)
        // #856: the timeout fires inside the 2 s grace, by hand (a 1.5 s timer under load fired before dch printed).
        let timers = Timers()
        let r = rig(f.path, timeout: 1.5, timers: timers)
        send(r, Self.ctl(["--read", "alpha"]))
        let script = pid(f.dir, "pid"), kid = pid(f.dir, "kid")
        XCTAssertTrue(wait(5) { !bytes(r, DchFrame.ctlStdout).isEmpty })
        let start = Date()
        send(r, DchFrame.encode(DchFrame.ctlCancel, []))
        XCTAssertTrue(wait(1.5) { (try? String(contentsOf: f.dir.appendingPathComponent("sig"), encoding: .utf8)) != nil })
        XCTAssertEqual(Darwin.kill(try XCTUnwrap(script), 0), 0, "alive inside the grace")
        // After the trap ran: two SIGTERMs sent back to back coalesce into one pending signal.
        send(r, DchFrame.encode(DchFrame.ctlCancel, []))
        XCTAssertEqual(timers.count, 1)
        timers.fire(0)
        usleep(300_000)
        XCTAssertEqual(try? String(contentsOf: f.dir.appendingPathComponent("sig"), encoding: .utf8), "term\n", "one SIGTERM")
        XCTAssertEqual(finals(r).count, 0)
        XCTAssertTrue(dead(script), "SIGKILLed")
        XCTAssertTrue(dead(kid), "its group too")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 1.9)
        XCTAssertTrue(wait(5) { finals(r).count == 1 })
        XCTAssertEqual(Self.object(finals(r).first) as NSDictionary, ["exit": 2, "why": "cancel"] as NSDictionary)
    }

    /// #852: a timeout's cut (a cap's too), as dch serve's ctl_cut (serve.c:1263-1264@v1.45.1): SIGTERM, then
    /// SIGKILL to the group CTL_GRACE_MS (2 s) later, not 1 s. Its 0x33 still goes out at once (#856).
    func testATimeoutCutGetsServesTwoSecondGrace() throws {
        let f = try fake("""
            echo $$ > "$D/pid"; trap 'echo term >> "$D/sig"' TERM
            printf 'working\\n'; while :; do /bin/sleep 0.05; done
            """)
        let timers = Timers()
        let r = rig(f.path, timers: timers)
        send(r, Self.ctl(["--read", "alpha"]))
        let script = try XCTUnwrap(pid(f.dir, "pid"))
        XCTAssertTrue(wait(5) { !bytes(r, DchFrame.ctlStdout).isEmpty && timers.count == 1 })
        let start = Date()
        timers.fire(0)
        // #874 (QA #729 INFO-4): one poll to the end state, not a sample at one instant, so a loaded
        // machine only delays the observations: `alive` is a lower bound of the last instant dch was
        // seen running (taken before the probe), `finalWhileAlive` that the 0x33 came before the SIGKILL.
        var alive = start, finalWhileAlive = false
        let gone = wait(10) {
            let t = Date(), sent = finals(r).count == 1
            guard Darwin.kill(script, 0) == 0 else { return true }
            alive = t
            finalWhileAlive = finalWhileAlive || sent
            return false
        }
        XCTAssertTrue(gone, "SIGKILLed")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 1.9, "not before the 2 s grace")
        XCTAssertGreaterThanOrEqual(alive.timeIntervalSince(start), 1.3, "seen alive past 1 s: the grace is 2 s")
        XCTAssertTrue(finalWhileAlive, "the 0x33 goes out at once, not at the reap")
        XCTAssertEqual(finals(r).count, 1)
        XCTAssertEqual(Self.object(finals(r).first) as NSDictionary, ["exit": 2, "why": "timeout"] as NSDictionary)
        XCTAssertEqual(try? String(contentsOf: f.dir.appendingPathComponent("sig"), encoding: .utf8), "term\n", "a SIGTERM first")
    }

    /// #852: a server stop (DchSessionServer.stop, through DchConnection.serverStop) cuts with dch serve's
    /// 2 s grace whatever the verb (serve.c:1251@v1.45.1, :1480-1481@v1.45.1; v1.57.0 serve.c:1281-1286, :1522-1523): an agent verb's 660 s goes, and so
    /// does the long grace of one a 0x34 cut before the stop.
    func testAServerStopCutsWithTheTwoSecondGrace() throws {
        for cancelFirst in [false, true] {
            let f = try fake("""
                echo $$ > "$D/pid"; /bin/sleep 30 & echo $! > "$D/kid"
                trap 'echo term >> "$D/sig"' TERM
                printf 'working\\n'; while :; do /bin/sleep 0.05; done
                """)
            let r = rig(f.path)
            send(r, Self.ctl(["--say", "alpha", "--json", "--", "hi"]))
            let dch = try XCTUnwrap(pid(f.dir, "pid")), kid = try XCTUnwrap(pid(f.dir, "kid"))
            XCTAssertTrue(wait(5) { !bytes(r, DchFrame.ctlStdout).isEmpty })
            if cancelFirst {
                send(r, DchFrame.encode(DchFrame.ctlCancel, []))
                XCTAssertTrue(wait(5) { (try? String(contentsOf: f.dir.appendingPathComponent("sig"), encoding: .utf8)) != nil })
            }
            let at = Date()
            r.queue.sync { r.conn.serverStop() }
            XCTAssertEqual(r.closes.count, 1, "closed")
            // #874 (QA #729 INFO-4): a late observation only adds time, so the lower bound holds under load;
            // the upper one is 15 s, far under the 660 s it rules out.
            XCTAssertTrue(wait(15) { Darwin.kill(dch, 0) != 0 }, "SIGKILLed (cancelFirst \(cancelFirst))")
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(at), 1.9, "not before the grace")
            XCTAssertTrue(wait(15) { Darwin.kill(kid, 0) != 0 }, "its group too (cancelFirst \(cancelFirst))")
            XCTAssertLessThan(Date().timeIntervalSince(at), 15, "2 s, not 660 s")
        }
    }

    /// #841: a 0x34 that lands before the spawn (the --xray probe still running) runs nothing and ends the
    /// request with the cancel 0x33.
    func testACancelBeforeTheSpawnRunsNothing() throws {
        let f = try fake("printf '%s\\n' \"$@\" > \"$D/argv\"; echo $$ > \"$D/pid\"; while :; do /bin/sleep 0.05; done")
        let r = rig(f.path)
        let probing = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        r.conn.ctl.xray = { probing.signal(); release.wait(); return true }
        send(r, Self.ctl(["--xray", "alpha", "--follow", "--json"]))
        XCTAssertEqual(probing.wait(timeout: .now() + 5), .success)
        send(r, DchFrame.encode(DchFrame.ctlCancel, []))
        release.signal()
        XCTAssertTrue(wait(5) { finals(r).count == 1 })
        XCTAssertEqual(Self.object(finals(r).first) as NSDictionary, ["exit": 2, "why": "cancel"] as NSDictionary)
        usleep(300_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.dir.appendingPathComponent("argv").path), "nothing ran")
        XCTAssertEqual(r.closes.count, 0)
    }

    /// A 0x34 with nothing running, or after the 0x33, gets no frame; after a 0x33 the same
    /// connection takes the next 0x30 (warm reuse).
    func testAStrayCancelIsIgnoredAndTheConnectionIsReused() throws {
        let f = try fake("printf '%s\\n' \"$1\" >> \"$D/ran\"; printf ok")
        let r = rig(f.path)
        send(r, DchFrame.encode(DchFrame.ctlCancel, []))
        usleep(200_000)
        XCTAssertEqual(all(r).count, 0, "nothing running: no frame")
        for (i, verb) in ["--status", "--read", "-k"].enumerated() {
            send(r, Self.ctl([verb, "alpha"]))
            XCTAssertTrue(wait(5) { finals(r).count == i + 1 }, verb)
            XCTAssertEqual(Self.object(finals(r).last) as NSDictionary, ["exit": 0] as NSDictionary, "no why: \(verb)")
            let n = all(r).count
            send(r, DchFrame.encode(DchFrame.ctlCancel, []))
            usleep(200_000)
            XCTAssertEqual(all(r).count, n, "after the 0x33: no frame")
        }
        XCTAssertEqual(try String(contentsOf: f.dir.appendingPathComponent("ran"), encoding: .utf8), "--status\n--read\n-k\n")
        XCTAssertEqual(r.closes.count, 0)
        let ops = DchFrame.machineInfo(deviceID: "d", hostname: "h", wakeId: nil)["ops"] as? [String] ?? []
        XCTAssertTrue(ops.contains("ctl") && ops.contains("ctl-cancel"), "\(ops)")
    }

    /// A warm connection (it sent a 0x30) closes 300 s after the last frame or reply, through the
    /// injected clock; never while a request runs.
    func testAWarmConnectionClosesAfter300sIdle() throws {
        let f = try fake("[ \"$1\" = --follow ] && { echo $$ > \"$D/pid\"; while [ ! -e \"$D/go\" ]; do /bin/sleep 0.05; done; }; printf ok")
        let r = rig(f.path), clock = Clock()
        r.conn.clock = { clock.now }
        XCTAssertEqual(r.conn.ctlIdle, 300)
        send(r, Self.ctl(["--status", "alpha"]))
        XCTAssertTrue(wait(5) { finals(r).count == 1 })
        clock.advance(299)
        r.queue.sync { r.conn.idleTick() }
        XCTAssertEqual(r.closes.count, 0, "299 s")
        send(r, DchFrame.encode(DchFrame.ctlCancel, []))   // a frame: the idle time starts again
        clock.advance(250)
        r.queue.sync { r.conn.idleTick() }
        XCTAssertEqual(r.closes.count, 0, "250 s since the last frame")
        send(r, Self.ctl(["--follow", "alpha"]))
        clock.advance(1000)
        r.queue.sync { r.conn.idleTick() }
        XCTAssertEqual(r.closes.count, 0, "a running request is not idle")
        try Data().write(to: f.dir.appendingPathComponent("go"))
        XCTAssertTrue(wait(5) { finals(r).count == 2 })
        clock.advance(299)
        r.queue.sync { r.conn.idleTick() }
        XCTAssertEqual(r.closes.count, 0, "299 s since the reply")
        clock.advance(1)
        r.queue.sync { r.conn.idleTick() }
        XCTAssertEqual(r.closes.count, 1, "300 s: closed")
    }

    /// The idle check is armed by the 0x30 itself: with a short idle it closes on its own.
    func testTheIdleCheckRunsOnItsOwn() throws {
        let f = try fake("printf ok")
        let r = rig(f.path)
        r.conn.ctlIdle = 0.3
        send(r, Self.ctl(["--status", "alpha"]))
        XCTAssertTrue(wait(5) { finals(r).count == 1 })
        XCTAssertTrue(wait(5) { r.closes.count == 1 }, "closed without a tick from the test")
        let cold = rig(f.path)
        cold.conn.ctlIdle = 0.3
        send(cold, DchFrame.encode(DchFrame.ctlCancel, []))
        usleep(1_800_000)
        XCTAssertEqual(cold.closes.count, 0, "a connection that never sent a 0x30 is not warm")
    }

    /// Every refusal is one 0x13 and runs nothing: the dch is never even chosen. #841, as dch 1.42
    /// serve: the FIN follows it, on a fresh connection and on a warm one.
    func testRefusalsRunNothingAndClose() throws {
        let missing = tempDir("ctl-missing").appendingPathComponent("nope").path
        let bad: [Data] = [
            DchFrame.encode(DchFrame.ctl, Array("not json".utf8)), DchFrame.encode(DchFrame.ctl, []),
            DchFrame.encode(DchFrame.ctl, json: ["argv": ["--read", 7] as [Any]]), DchFrame.encode(DchFrame.ctl, json: ["args": ["--read", "a"]]),
            Self.ctl(["--status"]), Self.ctl(["--config", "x"]), Self.ctl(["serve", "x"]), Self.ctl(["-h", "x"]),
            Self.ctl(["--read", "alpha", "--config"]), Self.ctl(["--read", "-alpha"]), Self.ctl(["--send", "alpha", "-k", "b"]),
            Self.ctl(["--read", "alpha"], ["cwd": "/"]), Self.ctl(["--spawn", "alpha"], ["cwd": missing]),
            Self.ctl(["--forget", "alpha", "-f"]), Self.ctl(["--read", "otherhost:alpha"]),
        ]
        for (i, frame) in bad.enumerated() {
            let reached = Recorder()
            let r = rig("/nonexistent/dch", reached: reached)
            send(r, frame)
            XCTAssertEqual(all(r).count, 1, "\(i): one reply")
            XCTAssertEqual(all(r).first.map(Self.type), DchFrame.error, "\(i)")
            XCTAssertNil(Self.object(all(r).first)["code"], "\(i): uncoded, as serve's")
            XCTAssertEqual(r.closes.count, 1, "\(i): then the FIN")
            XCTAssertEqual(reached.count, 0, "\(i)")
            XCTAssertFalse(r.queue.sync { r.conn.inFlight }, "\(i)")
            if i == 12 { XCTAssertEqual(Self.object(all(r).first)["message"] as? String, DchCtl.noDirectory) }
            if i == 14 { XCTAssertEqual(Self.object(all(r).first)["message"] as? String, DchCtl.localOnly) }
        }
        // A dch that cannot start: one 0x13, then the FIN.
        let r = rig("/nonexistent/dch")
        send(r, Self.ctl(["--status", "alpha"]))
        XCTAssertTrue(wait(5) { r.closes.count == 1 })
        XCTAssertEqual(all(r).count, 1)
        XCTAssertEqual(Self.object(all(r).last)["message"] as? String, "dch could not be run")
        XCTAssertFalse(r.queue.sync { r.conn.inFlight })
        // No dch at all: the same.
        let none = rig(nil)
        send(none, Self.ctl(["--status", "alpha"]))
        XCTAssertEqual(Self.object(all(none).last)["message"] as? String, "dch is not available on this Mac")
        XCTAssertEqual(none.closes.count, 1)
        // A warm connection too (serve: closing is set before every 0x30 that does not run).
        let f = try fake("printf ok")
        let warm = rig(f.path)
        send(warm, Self.ctl(["--status", "alpha"]))
        XCTAssertTrue(wait(5) { finals(warm).count == 1 })
        XCTAssertEqual(warm.closes.count, 0)
        send(warm, Self.ctl(["--read", "-alpha"]))
        XCTAssertEqual(Self.object(all(warm).last)["message"] as? String, DchControlOps.dashNameRefusal)
        XCTAssertEqual(warm.closes.count, 1)
    }

    /// "Run commands from iPhone" gates only 0x28/0x29: ctl's mutating verbs follow attach input
    /// (0x10), which no setting gates; the peer and owner check is the gate (RemoteFramesGoldenTests).
    func testMutatingVerbsDoNotFollowTheCommandsSetting() throws {
        let f = try fake("printf '%s ' \"$@\" >> \"$D/ran\"; echo >> \"$D/ran\"")
        let r = rig(f.path)
        XCTAssertFalse(r.conn.commands.enabled())
        for argv in [["--send", "alpha", "--", "hi"], ["--run", "alpha", "ls"], ["--keys", "alpha", "ctrl+c"],
                     ["-k", "alpha"], ["-m", "alpha", "A"], ["-d", "alpha"], ["--say", "alpha", "--json", "--", "go"]] {
            let n = finals(r).count
            send(r, Self.ctl(argv))
            XCTAssertTrue(wait(5) { finals(r).count == n + 1 }, "\(argv)")
            XCTAssertEqual(Self.object(finals(r).last)["exit"] as? Int, 0, "\(argv)")
        }
        XCTAssertEqual(try String(contentsOf: f.dir.appendingPathComponent("ran"), encoding: .utf8).split(separator: "\n").count, 7)
        let ops = DchFrame.machineInfo(deviceID: "d", hostname: "h", wakeId: nil, commands: false)["ops"] as? [String] ?? []
        XCTAssertTrue(ops.contains("ctl"), "listed whatever the commands setting says")
    }

    /// --spawn, --revive and 0x02 share one create gate, and "create" leaves ops with it. #841 (QA #680
    /// INFO-8): the Mac-only 0x0c revive and 0x0d restart start processes too, so they follow it.
    func testCreateGateCoversSpawnReviveAndCreate() throws {
        let f = try fake("printf '%s\\n' \"$1\" >> \"$D/ran\"")
        for argv in [["--spawn", "alpha", "--", "/bin/sh"], ["--revive", "alpha", "--json"]] {
            let r = rig(f.path)
            r.conn.createAllowed = { false }
            send(r, Self.ctl(argv))
            XCTAssertEqual(Self.object(all(r).last)["message"] as? String, DchCtl.createOff, "\(argv)")
            XCTAssertEqual(r.closes.count, 1, "\(argv): a refusal, then the FIN")
        }
        let r = rig(f.path)
        r.conn.createAllowed = { false }
        send(r, DchFrame.encode(DchFrame.create, json: ["name": "alpha", "command": ["/bin/sh"]]))
        XCTAssertEqual(Self.object(all(r).last)["message"] as? String, DchCtl.createOff, "0x02 too")
        XCTAssertNil(r.conn.attachedSession, "nothing attached")
        for (frame, json) in [(DchFrame.revive, ["name": "alpha"]), (DchFrame.restart, ["names": ["alpha"]])] as [(UInt8, [String: Any])] {
            let n = all(r).count
            send(r, DchFrame.encode(frame, json: json))
            XCTAssertEqual(all(r).count, n + 1, "answered at once, before any dch is looked at")
            XCTAssertEqual(Self.object(all(r).last)["message"] as? String, DchCtl.createOff, "\(frame)")
            XCTAssertFalse(r.queue.sync { r.conn.inFlight })
        }
        XCTAssertEqual(r.closes.count, 0, "a Mac-only refusal closes nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.dir.appendingPathComponent("ran").path))
        let off = DchFrame.machineInfo(deviceID: "d", hostname: "h", wakeId: nil, create: false)["ops"] as? [String] ?? []
        XCTAssertFalse(off.contains("create"))
        XCTAssertTrue(off.contains("ctl"))
        let on = rig(f.path)
        for (frame, json) in [(DchFrame.revive, ["name": "alpha"]), (DchFrame.restart, ["names": ["alpha"]])] as [(UInt8, [String: Any])] {
            let n = finals(on).count
            send(on, DchFrame.encode(frame, json: json))
            XCTAssertTrue(wait(5) { finals(on).count == n + 1 })
            XCTAssertNotEqual(Self.object(finals(on).last)["message"] as? String, DchCtl.createOff, "create on: past the gate (\(frame))")
        }
        for argv in [["--spawn", "alpha", "--", "/bin/sh"], ["--revive", "alpha", "--json"]] {
            let n = finals(on).count
            send(on, Self.ctl(argv))
            XCTAssertTrue(wait(5) { finals(on).count == n + 1 })
            XCTAssertEqual(finals(on).last.map(Self.type), DchFrame.ctlExit, "\(argv)")
        }
        XCTAssertEqual(try String(contentsOf: f.dir.appendingPathComponent("ran"), encoding: .utf8), "--spawn\n--revive\n")
    }

    // MARK: - #841: dch 1.42 serve's connection rules

    /// A ctl connection, running or warm, takes 0x08, 0x03, 0x30 and 0x34 only; any other frame serve reads
    /// whole (0x01-0x09, 0x2e) is one 0x13 "a ctl connection takes only ctl frames", then the FIN, and is
    /// not handled. QA #680 INFO-2: a 0x2e there is refused, so no watch stream lives on a connection the
    /// ctl idle check closes. QA #688 INFO-1: the rest (0x10, 0x0a, a Mac-only request, an unknown type)
    /// is dropped unread as serve drops it: no frame, no close, and the connection still runs a 0x30.
    func testACtlConnectionTakesOnlyCtlFrames() throws {
        let f = try fake("[ \"$1\" = --follow ] && { echo $$ > \"$D/pid\"; while :; do /bin/sleep 0.05; done; }; printf ok")
        func warm() -> Rig {
            let r = rig(f.path)
            send(r, Self.ctl(["--status", "alpha"]))
            XCTAssertTrue(wait(5) { finals(r).count == 1 })
            return r
        }
        let r = warm()
        send(r, DchFrame.encode(DchFrame.machineInfo, []))
        XCTAssertTrue(wait(5) { all(r).contains { Self.type($0) == DchFrame.machineInfoResp } }, "0x08")
        send(r, DchFrame.encode(DchFrame.list, []))
        XCTAssertTrue(wait(5) { all(r).contains { Self.type($0) == DchFrame.listResp } }, "0x03")
        send(r, DchFrame.encode(DchFrame.ctlCancel, []))
        XCTAssertEqual(r.closes.count, 0)
        let kills = Recorder()
        let others: [Data] = [
            DchFrame.encode(DchFrame.watch, json: [:]), DchFrame.encode(DchFrame.attach, json: ["name": "alpha"]),
            DchFrame.encode(DchFrame.create, json: ["name": "alpha"]), DchFrame.encode(DchFrame.kill, json: ["name": "alpha"]),
            DchFrame.encode(DchFrame.rename, json: ["name": "alpha", "alias": "A"]), DchFrame.encode(DchFrame.snapshot, []),
            DchFrame.encode(DchFrame.resize, json: [:]), DchFrame.encode(DchFrame.redraw, []),
        ]
        for frame in others {
            let w = warm()
            w.conn.kill = { _ in kills.add() }
            w.conn.rename = { _, _ in kills.add(); return nil }
            send(w, frame)
            XCTAssertEqual(all(w).count, 3, "one reply: \(Self.type(frame))")
            XCTAssertEqual(Self.object(all(w).last)["message"] as? String, DchCtl.ctlOnly, "\(Self.type(frame))")
            XCTAssertEqual(w.closes.count, 1, "then the FIN: \(Self.type(frame))")
            XCTAssertFalse(w.conn.watching)
            XCTAssertNil(w.conn.attachedSession)
        }
        XCTAssertEqual(kills.count, 0, "nothing handled")
        let dropped: [Data] = [
            DchFrame.encode(DchFrame.data, [0x61]), DchFrame.encode(DchFrame.putClipboard, []),
            DchFrame.encode(DchFrame.history, []), DchFrame.encode(0x7f, []),
        ]
        let handled = Recorder()
        for frame in dropped {
            let w = warm()
            w.conn.ops.binary = { handled.add(); return nil }
            send(w, frame)
            usleep(100_000)
            XCTAssertEqual(all(w).count, 2, "no reply: \(Self.type(frame))")
            XCTAssertEqual(w.closes.count, 0, "no close: \(Self.type(frame))")
            send(w, Self.ctl(["--status", "alpha"]))
            XCTAssertTrue(wait(5) { finals(w).count == 2 }, "still a ctl connection: \(Self.type(frame))")
        }
        XCTAssertEqual(handled.count, 0, "nothing handled")
        // While the ctl runs: the refusal closes, and the close ends the ctl.
        let running = rig(f.path)
        send(running, Self.ctl(["--follow", "alpha"]))
        let script = pid(f.dir, "pid")
        send(running, DchFrame.encode(DchFrame.snapshot, []))
        XCTAssertEqual(Self.object(all(running).last)["message"] as? String, DchCtl.ctlOnly)
        XCTAssertEqual(running.closes.count, 1)
        XCTAssertTrue(dead(script))
        // A connection that never ran a ctl is not one: a refused 0x30 closes it before anything else matters.
        let cold = rig(f.path)
        send(cold, DchFrame.encode(DchFrame.ctlCancel, []))
        send(cold, DchFrame.encode(DchFrame.snapshot, []))
        XCTAssertEqual(all(cold).map(Self.type), [DchFrame.snapshotResp])
    }

    /// serve's on_ctl: a 0x30 on an attached or watch connection, or beside a Mac-only request in flight,
    /// is one 0x13 "ctl needs its own connection"; nothing runs, nothing closes, no idle check is armed.
    func testCtlNeedsItsOwnConnection() throws {
        let f = try fake("printf '%s\\n' \"$1\" >> \"$D/ran\"")
        // A watch stream.
        let w = rig(f.path)
        let hub = DchWatchHub(schedule: DchWatchHub.schedule(on: w.queue))
        hub.remoteDir = { "/ctl-test" }
        hub.sidekick = { DchSidekickOps.Value(pattern: "", updated: 0) }
        w.queue.sync { hub.island(DchWatchHub.Cache(dir: "/ctl-test", rows: [])) }
        w.conn.watch = hub
        w.conn.ctlIdle = 0.3
        send(w, DchFrame.encode(DchFrame.watch, json: [:]))
        XCTAssertTrue(w.queue.sync { w.conn.watching })
        let n = all(w).count
        send(w, Self.ctl(["--status", "alpha"]))
        XCTAssertEqual(all(w).count, n + 1)
        XCTAssertEqual(Self.object(all(w).last)["message"] as? String, DchCtl.ownConnection)
        // An attached connection (a pty running /bin/cat, never dch).
        let a = rig(f.path)
        a.conn.ctlIdle = 0.3
        a.conn.spawn = { _, _, cols, rows, out, exit in
            try PtyChild(exe: "/bin/cat", args: [], env: ["PATH": "/usr/bin:/bin"], cols: cols, rows: rows, onOutput: out, onExit: exit)
        }
        send(a, DchFrame.encode(DchFrame.attach, json: ["name": "alpha"]))
        XCTAssertEqual(a.conn.attachedSession, "alpha")
        send(a, Self.ctl(["--status", "alpha"]))
        XCTAssertEqual(Self.object(all(a).last)["message"] as? String, DchCtl.ownConnection)
        // A Mac-only request in flight (its dch lookup held).
        let m = rig(f.path)
        let held = DispatchSemaphore(value: 0), asked = DispatchSemaphore(value: 0)
        m.conn.ops.binary = { asked.signal(); held.wait(); return nil }
        send(m, DchFrame.encode(DchFrame.history, []))
        XCTAssertEqual(asked.wait(timeout: .now() + 5), .success)
        send(m, Self.ctl(["--status", "alpha"]))
        XCTAssertEqual(all(m).count, 1)
        XCTAssertEqual(Self.object(all(m).last)["message"] as? String, DchCtl.ownConnection)
        held.signal()
        XCTAssertTrue(wait(5) { all(m).count == 2 }, "the history request still gets its reply")
        usleep(1_500_000)
        for c in [w, a, m] { XCTAssertEqual(c.closes.count, 0, "no close, no idle check") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.dir.appendingPathComponent("ran").path), "nothing ran")
    }

    /// The idle re-check waits at least 1 s: with a 0 s idle and a ctl running it ticks once a second,
    /// never in a loop on the connection's queue.
    func testTheIdleCheckNeverSpins() throws {
        let f = try fake("echo $$ > \"$D/pid\"; while [ ! -e \"$D/go\" ]; do /bin/sleep 0.05; done; printf ok")
        let r = rig(f.path), ticks = Recorder()
        r.conn.ctlIdle = 0
        r.conn.clock = { ticks.add(); return Date() }
        send(r, Self.ctl(["--status", "alpha"]))
        usleep(1_500_000)
        XCTAssertLessThan(ticks.count, 10, "a tick a second while it runs")
        XCTAssertEqual(r.closes.count, 0, "running: not idle")
        try Data().write(to: f.dir.appendingPathComponent("go"))
        XCTAssertTrue(wait(5) { r.closes.count == 1 }, "idle once it ended")
    }
}
