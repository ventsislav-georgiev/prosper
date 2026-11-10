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

    private func rig(_ script: String? = nil, timeout: TimeInterval = 60, agentTimeout: TimeInterval = 660,
                     cap: Int = 8 << 20, reached: Recorder? = nil) -> Rig {
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
        conn.clipboard.enabled = { false }
        conn.commands.enabled = { false }
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
    func testXrayIsRefusedWhileTheHostLacksIt() throws {
        let f = try fake("printf '%s\\n' \"$@\" > \"$D/argv\"; printf '{\"chapter\":0}\\n'")
        let r = rig(f.path)
        r.conn.ctl.xray = { false }
        send(r, Self.ctl(["--xray", "alpha", "--chapter", "0", "--json"]))
        XCTAssertTrue(wait(5) { !finals(r).isEmpty })
        XCTAssertEqual(all(r).count, 1)
        XCTAssertEqual(Self.object(finals(r).first)["message"] as? String, DchCtl.xrayOff)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.dir.appendingPathComponent("argv").path), "nothing ran")
        XCTAssertTrue(wait(2) { !r.queue.sync { r.conn.inFlight } }, "the slot is free again")
        r.conn.ctl.xray = { true }
        send(r, Self.ctl(["--xray", "alpha", "--chapter", "0", "--json"]))
        XCTAssertTrue(wait(5) { finals(r).count == 2 })
        XCTAssertEqual(Self.object(finals(r).last) as NSDictionary, ["exit": 0] as NSDictionary)
        XCTAssertEqual(bytes(r, DchFrame.ctlStdout), Data("{\"chapter\":0}\n".utf8))
        XCTAssertEqual(try String(contentsOf: f.dir.appendingPathComponent("argv"), encoding: .utf8), "--xray\nalpha\n--chapter\n0\n--json\n")
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
        let r = rig(f.path, timeout: 0.5)
        let start = Date()
        send(r, Self.ctl(["--run", "alpha", "hi"]))
        XCTAssertTrue(wait(10) { !finals(r).isEmpty })
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(Self.object(finals(r).first) as NSDictionary, ["exit": 2, "why": "timeout"] as NSDictionary)
        XCTAssertTrue(dead(pid(f.dir, "pid")))
        XCTAssertTrue(dead(pid(f.dir, "kid")))
        usleep(300_000)
        XCTAssertEqual(Self.type(try XCTUnwrap(all(r).last)), DchFrame.ctlExit)
        XCTAssertEqual(finals(r).count, 1)
    }

    /// Review round 1: a timeout that fires after dch was reaped, before its output drained (a child
    /// still holds the pipe), ends with dch's own exit, not "timeout".
    func testATimeoutAfterTheExitEndsWithTheRealExit() throws {
        let f = try fake("/bin/sleep 1 & echo $! > \"$D/kid\"; echo done; exit 0")
        let r = rig(f.path, timeout: 0.3)
        send(r, Self.ctl(["--status", "alpha"]))
        XCTAssertTrue(wait(10) { !finals(r).isEmpty })
        XCTAssertEqual(Self.object(finals(r).first) as NSDictionary, ["exit": 0] as NSDictionary)
        XCTAssertEqual(bytes(r, DchFrame.ctlStdout), Data("done\n".utf8))
        XCTAssertEqual(finals(r).count, 1)
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

    /// amendment 2: a close sends a non-follow dch SIGTERM only, never a SIGKILL after it: --stop and
    /// --say answer it by typing their resume message, which takes its time.
    func testCloseSendsSIGTERMOnlyAndNothingAfter() throws {
        let f = try fake("""
            echo $$ > "$D/pid"
            trap 'echo term >> "$D/sig"; /bin/sleep 2; echo resumed >> "$D/sig"; exit 0' TERM
            printf '{"stopping":"alpha"}\\n'; while :; do /bin/sleep 0.05; done
            """)
        let r = rig(f.path)
        send(r, Self.ctl(["--stop", "alpha", "--json"]))
        let script = pid(f.dir, "pid")
        XCTAssertTrue(wait(5) { !bytes(r, DchFrame.ctlStdout).isEmpty })
        r.queue.sync { r.conn.close() }
        XCTAssertTrue(wait(8) { (try? String(contentsOf: f.dir.appendingPathComponent("sig"), encoding: .utf8)) == "term\nresumed\n" },
                      "one SIGTERM, then dch's own time to finish: no SIGKILL 1 s later")
        XCTAssertTrue(dead(script))
        XCTAssertEqual(finals(r).count, 0, "nothing after the close")
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
    func testTheTimeoutIsPerVerb() throws {
        let ops = DchCtlOps()
        for v in ["--say", "--stop", "--revive"] { XCTAssertEqual(ops.timeout(of: v), 660, v) }
        for v in ["--read", "--send", "--run", "--keys", "--status", "-k", "-m", "-d", "--spawn", "--history",
                  "--pin", "--unpin", "--forget"] { XCTAssertEqual(ops.timeout(of: v), 60, v) }
        let f = try fake("/bin/sleep 1; printf ok")
        let r = rig(f.path, timeout: 0.3, agentTimeout: 20)
        for (argv, want) in [(["--stop", "alpha", "--json"], ["exit": 0]), (["--status", "alpha"], ["exit": 2, "why": "timeout"]),
                             (["--revive", "alpha", "--json"], ["exit": 0]), (["--say", "alpha", "--json", "--", "hi"], ["exit": 0])] as [([String], [String: Any])] {
            let n = finals(r).count
            send(r, Self.ctl(argv))
            XCTAssertTrue(wait(10) { finals(r).count == n + 1 }, "\(argv)")
            XCTAssertEqual(Self.object(finals(r).last) as NSDictionary, want as NSDictionary, "\(argv)")
        }
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
    func testASecondCtlWhileOneRunsIsBusy() throws {
        let f = try fake("echo x >> \"$D/runs\"; while [ ! -e \"$D/go\" ]; do /bin/sleep 0.05; done; printf done")
        let r = rig(f.path)
        send(r, Self.ctl(["--status", "alpha"]))
        XCTAssertTrue(wait(5) { FileManager.default.fileExists(atPath: f.dir.appendingPathComponent("runs").path) })
        send(r, Self.ctl(["--status", "beta"]))
        send(r, DchFrame.encode(DchFrame.history, []))
        let busy = finals(r)
        XCTAssertEqual(busy.count, 2)
        for b in busy {
            XCTAssertEqual(Self.type(b), DchFrame.error)
            XCTAssertEqual(Self.object(b)["message"] as? String, "busy with an earlier request")
        }
        try Data().write(to: f.dir.appendingPathComponent("go"))
        XCTAssertTrue(wait(5) { finals(r).count == 3 })
        XCTAssertEqual(finals(r).dropFirst(2).first.map(Self.type), DchFrame.ctlExit)
        send(r, Self.ctl(["--status", "gamma"]))
        XCTAssertTrue(wait(5) { finals(r).count == 4 }, "free again once the first ended")
        XCTAssertEqual(try String(contentsOf: f.dir.appendingPathComponent("runs"), encoding: .utf8), "x\nx\n")
    }

    // MARK: - Amendment 4: 0x34 cancel, warm reuse, idle close

    /// 0x34 SIGTERMs dch; the request still ends with its one 0x33, now {"exit": dch's, "why": "cancel"},
    /// after whatever dch wrote on the way out.
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
        XCTAssertEqual(Self.object(finals(r).first) as NSDictionary, ["exit": 7, "why": "cancel"] as NSDictionary)
        XCTAssertEqual(bytes(r, DchFrame.ctlStdout), Data("working\nbye".utf8))
        XCTAssertTrue(dead(pid(f.dir, "pid")))
        send(r, DchFrame.encode(DchFrame.ctlCancel, []))
        usleep(300_000)
        XCTAssertEqual(finals(r).count, 1, "exactly one final; a second 0x34 is late and ignored")
        XCTAssertEqual(Self.type(try XCTUnwrap(all(r).last)), DchFrame.ctlExit)
        XCTAssertEqual(r.closes.count, 0, "the connection stays open")
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
        let f = try fake("[ \"$1\" = --follow ] && { while [ ! -e \"$D/go\" ]; do /bin/sleep 0.05; done; }; printf ok")
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

    /// Every refusal is one 0x13 and runs nothing: the dch is never even chosen.
    func testRefusalsRunNothing() throws {
        let reached = Recorder()
        let r = rig("/nonexistent/dch", reached: reached)
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
            send(r, frame)
            guard all(r).count == i + 1 else { return XCTFail("\(i): one reply each, got \(all(r).count) in all") }
            XCTAssertEqual(Self.type(all(r)[i]), DchFrame.error, "\(i)")
        }
        XCTAssertEqual(Self.object(all(r).dropFirst(12).first)["message"] as? String, DchCtl.noDirectory)
        XCTAssertEqual(Self.object(all(r).dropFirst(14).first)["message"] as? String, DchCtl.localOnly)
        XCTAssertEqual(reached.count, 0)
        XCTAssertFalse(r.queue.sync { r.conn.inFlight })
        // A dch that cannot start: one 0x13, and the connection is free again.
        send(r, Self.ctl(["--status", "alpha"]))
        XCTAssertTrue(wait(5) { all(r).count == bad.count + 1 })
        XCTAssertEqual(Self.object(all(r).last)["message"] as? String, "dch could not be run")
        XCTAssertTrue(wait(2) { !r.queue.sync { r.conn.inFlight } })
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

    /// --spawn, --revive and 0x02 share one create gate, and "create" leaves ops with it.
    func testCreateGateCoversSpawnReviveAndCreate() throws {
        let f = try fake("printf '%s\\n' \"$1\" >> \"$D/ran\"")
        let r = rig(f.path)
        r.conn.createAllowed = { false }
        for argv in [["--spawn", "alpha", "--", "/bin/sh"], ["--revive", "alpha", "--json"]] {
            send(r, Self.ctl(argv))
            XCTAssertEqual(Self.object(all(r).last)["message"] as? String, DchCtl.createOff, "\(argv)")
        }
        send(r, DchFrame.encode(DchFrame.create, json: ["name": "alpha", "command": ["/bin/sh"]]))
        XCTAssertEqual(Self.object(all(r).last)["message"] as? String, DchCtl.createOff, "0x02 too")
        XCTAssertNil(r.conn.attachedSession, "nothing attached")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.dir.appendingPathComponent("ran").path))
        let off = DchFrame.machineInfo(deviceID: "d", hostname: "h", wakeId: nil, create: false)["ops"] as? [String] ?? []
        XCTAssertFalse(off.contains("create"))
        XCTAssertTrue(off.contains("ctl"))
        r.conn.createAllowed = { true }
        for argv in [["--spawn", "alpha", "--", "/bin/sh"], ["--revive", "alpha", "--json"]] {
            let n = finals(r).count
            send(r, Self.ctl(argv))
            XCTAssertTrue(wait(5) { finals(r).count == n + 1 })
            XCTAssertEqual(finals(r).last.map(Self.type), DchFrame.ctlExit, "\(argv)")
        }
        XCTAssertEqual(try String(contentsOf: f.dir.appendingPathComponent("ran"), encoding: .utf8), "--spawn\n--revive\n")
    }
}
