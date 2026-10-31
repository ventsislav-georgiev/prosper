import Network
import os
import XCTest
@testable import ProsperApp

/// #591: the phone's history 0x0b, revive 0x0c, restart 0x0d and stop 0x0e frames,
/// machineInfoResp's "ops". Every dch call goes through a fake: the reads return
/// canned JSON, the runner's launch records argv and returns canned --json lines.
/// No test runs dch, opens a socket or starts a connection.
final class DchControlFramesTests: XCTestCase {
    private static let v1241 = DchCommand.Binary(path: "/fake/dch", version: [1, 24, 1])
    private static let now: TimeInterval = 1_000_000

    private final class Fake: @unchecked Sendable {
        let lock = NSLock()
        /// dir → --ls-json / --history --json stdout.
        var ls: [String: String] = [:]
        var hist: [String: String] = [:]
        /// argv joined by " " → the launch's stdout; status for every launch.
        var out: [String: String] = [:]
        var status: Int32 = 0
        /// argv joined by " " → that launch's exit, else `status`.
        var statusFor: [String: Int32] = [:]
        var launches: [(path: String, args: [String], dir: String?)] = []
        var historyPaths: [String?] = []
        /// Every read: its first arg and its DCH_SOCKET_DIR.
        var reads: [(arg: String, dir: String)] = []
        var refreshes = 0
        /// A launch with exactly these args, or any --history read while holdHistory,
        /// fulfils `held` and waits on `hold` (outside the lock).
        var holdArgs: [String]?
        var holdHistory = false
        let hold = DispatchSemaphore(value: 0)
        var held: XCTestExpectation?
        var onRefresh: XCTestExpectation?

        var launchedArgs: [[String]] { lock.withLock { launches.map(\.args) } }
    }

    private func ops(_ f: Fake, dirs: [String] = ["/d"], binary: DchCommand.Binary? = v1241) -> DchControlOps {
        var o = DchControlOps()
        o.dirs = { dirs }
        o.binary = { binary }
        o.read = { args, env, path in
            let dir = env["DCH_SOCKET_DIR"] ?? ""
            let (data, holding) = f.lock.withLock { () -> (Data, Bool) in
                f.reads.append((args.first ?? "", dir))
                switch args.first {
                case "--ls-json": return (Data((f.ls[dir] ?? "[]").utf8), false)
                case "--history":
                    f.historyPaths.append(path)
                    return (Data((f.hist[dir] ?? "[]").utf8), f.holdHistory)
                default: return (Data(), false)
                }
            }
            if holding { f.held?.fulfill(); f.hold.wait() }
            return data
        }
        o.env = { ["DCH_SOCKET_DIR": $0] }
        o.runner = DchActionRunner(launch: { path, args, env, _, onPid, _ in
            onPid(4242)
            let holding = f.lock.withLock { () -> Bool in
                f.launches.append((path, args, env["DCH_SOCKET_DIR"]))
                return args == f.holdArgs
            }
            if holding { f.held?.fulfill(); f.hold.wait() }
            return f.lock.withLock {
                let k = args.joined(separator: " ")
                return (f.statusFor[k] ?? f.status, Data((f.out[k] ?? "").utf8))
            }
        }, signal: { _ in })
        o.now = { Self.now }
        o.refresh = {
            f.lock.withLock { f.refreshes += 1 }
            f.onRefresh?.fulfill()
        }
        return o
    }

    private final class Frames: @unchecked Sendable {
        let lock = NSLock()
        var all: [Data] = []
    }

    /// One request; fails unless exactly one reply comes within 5 s.
    private func call(_ o: DchControlOps, _ type: UInt8, raw: Data, file: StaticString = #filePath, line: UInt = #line)
        -> (type: UInt8, json: Any?) {
        let frames = Frames(), got = expectation(description: "one reply")
        o.handle(type, raw) { frame in
            frames.lock.withLock { frames.all.append(frame) }
            got.fulfill()
        }
        wait(for: [got], timeout: 5)
        let all = frames.lock.withLock { frames.all }
        guard all.count == 1, let f = all.first else {
            XCTFail("expected one reply, got \(all.count)", file: file, line: line)
            return (0, nil)
        }
        return Self.decode(f)
    }

    private func call(_ o: DchControlOps, _ type: UInt8, _ json: Any, file: StaticString = #filePath, line: UInt = #line)
        -> (type: UInt8, json: Any?) {
        call(o, type, raw: try! JSONSerialization.data(withJSONObject: json), file: file, line: line)
    }

    private static func decode(_ f: Data) -> (type: UInt8, json: Any?) {
        let b = [UInt8](f)
        let len = (Int(b[1]) << 24) | (Int(b[2]) << 16) | (Int(b[3]) << 8) | Int(b[4])
        XCTAssertEqual(len, b.count - 5, "length prefix")
        let payload = Data(b.dropFirst(5))
        return (b[0], payload.isEmpty ? nil : try? JSONSerialization.jsonObject(with: payload))
    }

    private func names(_ r: (type: UInt8, json: Any?), file: StaticString = #filePath, line: UInt = #line) -> [String]? {
        XCTAssertEqual(r.type, DchFrame.ok, "\(String(describing: r.json))", file: file, line: line)
        return (r.json as? [String: Any])?["names"] as? [String]
    }

    private func message(_ r: (type: UInt8, json: Any?), file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertEqual(r.type, DchFrame.error, "\(String(describing: r.json))", file: file, line: line)
        return ((r.json as? [String: Any])?["message"] as? String) ?? ""
    }

    private static func ls(_ rows: [(String, String)]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: rows.map { ["name": $0.0, "version": $0.1] }), as: UTF8.self)
    }

    private static func hist(_ rows: [[String: Any]]) -> String { json(rows) }

    private static func json(_ o: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }

    private static func ok(_ name: String, as revived: String? = nil, phase: String? = nil) -> String {
        var o: [String: Any] = ["name": name, "result": "ok", "reason": "", "detail": "", "session_id": "s"]
        if let revived { o["as"] = revived }
        if let phase { o["phase"] = phase }
        return json(o)
    }

    // MARK: - history 0x0b

    func testHistoryRespHasTheTabsRowsFieldsAndTakes() {
        let f = Fake()
        f.hist["/d"] = Self.hist([
            ["name": "crashy", "alias": "Crashy", "cwd": "/src", "argv": ["claude", "--model", "x"],
             "started": Self.now - 3600, "updated": Self.now - 60, "ended": Self.now - 60, "end": "signal 9"],
            ["name": "clean", "started": Self.now - 7200, "updated": Self.now - 30, "ended": Self.now - 30, "end": "exit 0"],
        ])
        let r = call(ops(f), DchFrame.history, raw: Data())
        XCTAssertEqual(r.type, DchFrame.historyResp)
        let rows = r.json as? [[String: Any]] ?? []
        XCTAssertEqual(rows.map { $0["name"] as? String }, ["clean", "crashy"], "newest first, as the History tab")
        let crashy = rows.last ?? [:], clean = rows.first ?? [:]
        XCTAssertEqual(crashy["alias"] as? String, "Crashy")
        XCTAssertEqual(crashy["end"] as? String, "signal 9")
        XCTAssertEqual(crashy["last_seen"] as? Int, Int(Self.now) - 60)
        XCTAssertEqual(crashy["started"] as? Int, Int(Self.now) - 3600)
        XCTAssertEqual(crashy["runtime"] as? Int, 3540)
        XCTAssertEqual(crashy["cwd"] as? String, "/src")
        XCTAssertEqual(crashy["command"] as? [String], ["claude", "--model", "x"])
        XCTAssertEqual(crashy["takes"] as? Bool, true, "signal 9, an hour, a minute ago: --revive --all takes it")
        XCTAssertEqual(clean["takes"] as? Bool, false, "exit 0 is never taken")
        XCTAssertEqual(clean["end"] as? String, "exit 0")
        XCTAssertEqual(clean["runtime"] as? Int, 7170)
        for k in ["alias", "cwd", "command"] { XCTAssertNil(clean[k], "\(k) omitted when the record has none") }
        XCTAssertEqual(f.historyPaths, ["/fake/dch"], "read with the control binary")
        XCTAssertTrue(f.launches.isEmpty)
    }

    /// #592: "agent_name" carries the record's agent session name, omitted when
    /// empty or absent; every other field as before.
    func testHistoryWireAgentName() {
        func rec(_ agent: String?) -> DchHistoryRecord {
            DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "dobby-main"), alias: "A", cwd: "/src", argv: ["claude"],
                             started: 10, updated: 50, ended: 60, end: "exit 0", agent: agent.map { .init(name: $0) })
        }
        let base: Set = ["name", "end", "last_seen", "started", "runtime", "takes", "alias", "cwd", "command"]
        let named = DchControlOps.historyWire(rec("dobby-qa"), now: 100)
        XCTAssertEqual(named["agent_name"] as? String, "dobby-qa")
        XCTAssertEqual(Set(named.keys), base.union(["agent_name"]))
        for a in ["", nil] as [String?] {
            let o = DchControlOps.historyWire(rec(a), now: 100)
            XCTAssertEqual(Set(o.keys), base, "agent_name omitted for \(String(describing: a))")
        }
        XCTAssertEqual(named["name"] as? String, "dobby-main", "name stays the dch name")
        XCTAssertEqual(named["alias"] as? String, "A")
        XCTAssertEqual(named["runtime"] as? Int, 50)
    }

    func testHistoryIsCappedLikeTheTab() {
        let f = Fake()
        f.hist["/d"] = Self.hist((0..<60).map { ["name": "s\($0)", "updated": Self.now - Double($0), "end": "killed"] as [String: Any] })
        let rows = call(ops(f), DchFrame.history, raw: Data()).json as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, AgentIsland.historyCap)
        XCTAssertEqual(rows.first?["name"] as? String, "s0")
    }

    func testHistoryWithoutAControlBinaryIsAnError() {
        let f = Fake()
        XCTAssertTrue(message(call(ops(f, binary: nil), DchFrame.history, raw: Data())).contains("needs dch 1.24.0"))
        let old = DchCommand.Binary(path: "/fake/dch", version: [1, 23, 0])
        XCTAssertEqual(call(ops(f, binary: old), DchFrame.history, raw: Data()).type, DchFrame.error)
        XCTAssertTrue(f.historyPaths.isEmpty, "no read with a refused binary")
    }

    // MARK: - revive 0x0c

    func testReviveByNameRunsReviveArgsAndRepliesTheName() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "signal 9"]])
        f.out["--revive a --json"] = Self.ok("a")
        let r = call(ops(f), DchFrame.revive, ["name": "a"])
        XCTAssertEqual(names(r), ["a"])
        XCTAssertEqual(f.launches.count, 1)
        XCTAssertEqual(f.launches.first?.args, ["--revive", "a", "--json"])
        XCTAssertEqual(f.launches.first?.path, "/fake/dch")
        XCTAssertEqual(f.launches.first?.dir, "/d")
        XCTAssertEqual(f.refreshes, 1, "the island re-reads its history, as after its own Resume")
    }

    func testReviveOfALiveNameGoesToTheFirstFreeAsName() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1"), ("a-2", "1.24.1")])
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "signal 9"],
                                  ["name": "a-3", "updated": Self.now - 90, "end": "exit 0"]])
        f.out["--revive a --as a-4 --json"] = Self.ok("a", as: "a-4")
        let r = call(ops(f), DchFrame.revive, ["name": "a"])
        XCTAssertEqual(f.launchedArgs, [["--revive", "a", "--as", "a-4", "--json"]], "free of live a-2 and record a-3")
        XCTAssertEqual(names(r), ["a-4"], "the name the session runs under now")
    }

    func testReviveAllRunsReviveAllArgsPerHistoryDir() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "signal 9"]])
        f.hist["/e"] = Self.hist([["name": "b", "updated": Self.now - 60, "end": "signal 9"]])
        f.out["--revive --all --json"] = Self.ok("x")
        let r = call(ops(f, dirs: ["/d", "/e"]), DchFrame.revive, ["all": true])
        XCTAssertEqual(f.launchedArgs, [AgentIsland.reviveAllArgs, AgentIsland.reviveAllArgs])
        XCTAssertEqual(Set(f.launches.map(\.dir)), ["/d", "/e"])
        XCTAssertEqual(names(r), ["x"])
    }

    func testReviveAllWithNothingToTakeIsAnEmptyOk() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "exit 0"]])
        XCTAssertEqual(names(call(ops(f), DchFrame.revive, ["all": true])), [])
    }

    func testReviveOfANameNotInHistoryIsRefusedAndRunsNothing() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("live", "1.24.1")])
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "signal 9"]])
        XCTAssertTrue(message(call(ops(f), DchFrame.revive, ["name": "live"])).contains("no history record"),
                      "a live name with no record is not revivable")
        XCTAssertEqual(call(ops(f), DchFrame.revive, ["name": "--all"]).type, DchFrame.error)
        f.hist["/e"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "signal 9"]])
        XCTAssertEqual(message(call(ops(f, dirs: ["/d", "/e"]), DchFrame.revive, ["name": "a"])), "a: 2 history records of that name",
                       "exact-one-match still holds (only a multi-dir seam can show two)")
        XCTAssertTrue(f.launches.isEmpty)
    }

    func testAFailedReviveRepliesDchsWords() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "signal 9"]])
        f.out["--revive a --json"] = Self.json(["name": "a", "result": "failed", "reason": "no_record", "detail": "a: no record"])
        XCTAssertEqual(message(call(ops(f), DchFrame.revive, ["name": "a"])), "a: no record")
        f.out["--revive a --json"] = "dch: cannot reach the socket dir"
        f.status = 1
        XCTAssertEqual(message(call(ops(f), DchFrame.revive, ["name": "a"])), "a: Resume failed: dch: cannot reach the socket dir")
    }

    // MARK: - restart 0x0d

    func testRestartNamesRunsRestartArgsPerName() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1"), ("b", "1.24.1"), ("c", "1.24.1")])
        f.out[AgentIsland.restartArgs("a")!.joined(separator: " ")] = Self.ok("a", phase: "master") + "\n" + Self.ok("a")
        f.out[AgentIsland.restartArgs("b")!.joined(separator: " ")] = Self.ok("b")
        let r = call(ops(f), DchFrame.restart, ["names": ["a", "b", "a"]])
        XCTAssertEqual(Set(f.launchedArgs), [AgentIsland.restartArgs("a")!, AgentIsland.restartArgs("b")!], "deduplicated")
        XCTAssertEqual(names(r), ["a", "b"], "request order")
        XCTAssertEqual(f.refreshes, 1)
    }

    func testRestartAllRunsRestartAllArgsPerLiveDir() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1")])
        f.out[AgentIsland.restartAllArgs.joined(separator: " ")] = Self.ok("a", phase: "master")
        let r = call(ops(f, dirs: ["/d", "/e"]), DchFrame.restart, ["all": true])
        XCTAssertEqual(f.launchedArgs, [AgentIsland.restartAllArgs], "only the dir with a live session")
        XCTAssertEqual(f.launches.first?.dir, "/d")
        XCTAssertEqual(names(r), ["a"])
    }

    func testRestartOfANonLiveNameIsRefusedWhole() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1")])
        f.hist["/d"] = Self.hist([["name": "gone", "updated": Self.now - 60, "end": "signal 9"]])
        XCTAssertTrue(message(call(ops(f), DchFrame.restart, ["names": ["a", "gone"]])).contains("gone"))
        XCTAssertEqual(call(ops(f), DchFrame.restart, ["names": ["--all"]]).type, DchFrame.error)
        f.ls["/e"] = Self.ls([("a", "1.24.1")])
        XCTAssertEqual(message(call(ops(f, dirs: ["/d", "/e"]), DchFrame.restart, ["names": ["a"]])), "a: 2 live sessions of that name")
        XCTAssertTrue(f.launches.isEmpty, "nothing runs when any name is refused")
    }

    func testRestartUnderTheIslandsGateIsRefused() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.0")])   // a 1.24.0 master: only restartMinimum refuses a 1.24.0 binary
        let v124 = DchCommand.Binary(path: "/fake/dch", version: [1, 24, 0])
        XCTAssertTrue(message(call(ops(f, binary: v124), DchFrame.restart, ["names": ["a"]])).contains("1.24.1"))
        XCTAssertTrue(message(call(ops(f, binary: nil), DchFrame.restart, ["all": true])).contains("needs dch"))
        f.ls["/d"] = Self.ls([("a", "1.25.0")])   // a live master newer than the binary
        XCTAssertTrue(message(call(ops(f), DchFrame.stop, ["names": ["a"]])).contains("1.25.0"))
        XCTAssertTrue(f.launches.isEmpty)
    }

    // MARK: - stop 0x0e

    func testStopNamesRunsOneStopArgsPerDir() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1"), ("b", "1.24.0"), ("c", "1.24.1")])
        f.out[AgentIsland.stopArgs(["a", "b"])!.joined(separator: " ")] = Self.ok("a") + "\n" + Self.ok("b")
        let r = call(ops(f), DchFrame.stop, ["names": ["a", "b"]])
        XCTAssertEqual(f.launchedArgs, [["--stop", "a", "b", "--json"]])
        XCTAssertEqual(names(r), ["a", "b"])
        XCTAssertEqual(f.refreshes, 1)
    }

    func testStopOfANonLiveNameOrAnOldMasterIsRefused() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1"), ("old", "")])
        XCTAssertTrue(message(call(ops(f), DchFrame.stop, ["names": ["a", "ghost"]])).contains("ghost"))
        XCTAssertTrue(message(call(ops(f), DchFrame.stop, ["names": ["old"]])).contains("restart this session first"))
        XCTAssertTrue(f.launches.isEmpty)
    }

    // MARK: - #627: a name dch would read as a flag

    /// A record or live session named "--all" or "-n" exists, so only the guard
    /// refuses: error 0x13, no dch run; a batch with one refuses whole; a normal
    /// name still runs.
    func testDashLedNamesAreRefusedWholeAndRunNothing() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1"), ("--all", "1.24.1"), ("-n", "1.24.1")])
        f.hist["/d"] = Self.hist([["name": "--all", "updated": Self.now - 60, "end": "signal 9"],
                                  ["name": "-n", "updated": Self.now - 70, "end": "signal 9"],
                                  ["name": "r", "updated": Self.now - 80, "end": "signal 9"]])
        let o = ops(f)
        for bad in ["--all", "-n"] {
            XCTAssertEqual(message(call(o, DchFrame.revive, ["name": bad])), DchControlOps.dashNameRefusal, bad)
            XCTAssertEqual(message(call(o, DchFrame.restart, ["names": [bad]])), DchControlOps.dashNameRefusal, bad)
            XCTAssertEqual(message(call(o, DchFrame.restart, ["names": ["a", bad]])), DchControlOps.dashNameRefusal, bad)
            XCTAssertEqual(message(call(o, DchFrame.stop, ["names": [bad]])), DchControlOps.dashNameRefusal, bad)
            XCTAssertEqual(message(call(o, DchFrame.stop, ["names": ["a", bad]])), DchControlOps.dashNameRefusal, bad)
        }
        XCTAssertEqual(DchControlOps.dashNameRefusal, "a session name starting with - can't be passed to dch")
        XCTAssertEqual(f.launchedArgs, [], "no dch run, not even for the normal name in a refused batch")
        XCTAssertEqual(f.refreshes, 0)
        f.out["--stop a --json"] = Self.ok("a")
        XCTAssertEqual(names(call(o, DchFrame.stop, ["names": ["a"]])), ["a"])
        f.out["--revive r --json"] = Self.ok("r")
        XCTAssertEqual(names(call(o, DchFrame.revive, ["name": "r"])), ["r"])
        XCTAssertEqual(f.launchedArgs, [["--stop", "a", "--json"], ["--revive", "r", "--json"]], "normal names unaffected")
    }

    // MARK: - malformed

    func testEveryMalformedRequestGetsAnErrorAndRunsNothing() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1")])
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "signal 9"]])
        let o = ops(f)
        let garbage = Data([0xff, 0x00, 0x7b])
        let cases: [(UInt8, Data)] = [
            (DchFrame.history, Data("nope".utf8)), (DchFrame.history, Data("[1]".utf8)), (DchFrame.history, garbage),
        ] + [DchFrame.revive, DchFrame.restart, DchFrame.stop].flatMap { t in
            [Data(), Data("{}".utf8), Data("[]".utf8), Data("\"a\"".utf8), garbage, Data("{\"all\":1}".utf8),
             Data("{\"all\":false}".utf8), Data("{\"all\":\"yes\"}".utf8), Data("{\"all\":null}".utf8)].map { (t, $0) }
        } + [
            (DchFrame.revive, Data("{\"name\":5}".utf8)), (DchFrame.revive, Data("{\"name\":\"\"}".utf8)),
            (DchFrame.revive, Data("{\"name\":[\"a\"]}".utf8)), (DchFrame.revive, Data("{\"name\":\"a\",\"all\":true}".utf8)),
            (DchFrame.revive, Data("{\"names\":[\"a\"]}".utf8)),
            (DchFrame.restart, Data("{\"names\":\"a\"}".utf8)), (DchFrame.restart, Data("{\"names\":[]}".utf8)),
            (DchFrame.restart, Data("{\"names\":[1]}".utf8)), (DchFrame.restart, Data("{\"names\":[\"a\",\"\"]}".utf8)),
            (DchFrame.restart, Data("{\"names\":[\"a\"],\"all\":true}".utf8)), (DchFrame.restart, Data("{\"name\":\"a\"}".utf8)),
            (DchFrame.stop, Data("{\"all\":true}".utf8)), (DchFrame.stop, Data("{\"names\":[]}".utf8)),
            (DchFrame.stop, Data("{\"name\":\"a\"}".utf8)), (DchFrame.stop, Data("{\"names\":[null]}".utf8)),
        ]
        for (t, raw) in cases {
            let r = call(o, t, raw: raw)
            XCTAssertEqual(r.type, DchFrame.error, "type \(t) payload \(String(decoding: raw, as: UTF8.self))")
            XCTAssertFalse(message(r).isEmpty)
        }
        XCTAssertTrue(f.launches.isEmpty)
    }

    // MARK: - machineInfoResp and the old frames

    func testMachineInfoCarriesOps() {
        let info = DchFrame.machineInfo(deviceID: "id", hostname: "mac", wakeId: nil)
        XCTAssertEqual(info["ops"] as? [String], ["history", "revive", "restart", "stop", "library", "pin", "forget"])
        XCTAssertEqual(info["device_id"] as? String, "id")
        XCTAssertEqual(info["hostname"] as? String, "mac")
        XCTAssertNil(info["wakeId"])
        XCTAssertEqual(DchFrame.machineInfo(deviceID: "id", hostname: "mac", wakeId: "w")["wakeId"] as? String, "w")
    }

    func testFrameBytesAreThePhonesContract() {
        XCTAssertEqual([DchFrame.history, DchFrame.revive, DchFrame.restart, DchFrame.stop, DchFrame.historyResp],
                       [0x0b, 0x0c, 0x0d, 0x0e, 0x1b])
        XCTAssertEqual([DchFrame.ok, DchFrame.error, DchFrame.machineInfoResp], [0x14, 0x13, 0x18])
        XCTAssertEqual([DchFrame.pin, DchFrame.forget, DchFrame.forgetAll], [0x24, 0x25, 0x26], "#620")
    }

    /// Through DchConnection.handle: kill and rename still ack with an empty ok, and a
    /// new frame's one reply reaches the connection. The NWConnection is never started;
    /// kill and rename run /usr/bin/true, never dch.
    func testConnectionKeepsEmptyOkForKillAndRenameAndRepliesToNewFrames() {
        let queue = DispatchQueue(label: "test.dchconn")
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { _ in })
        let frames = Frames(), replied = expectation(description: "error reply")
        conn.sendOverride = { frame in
            frames.lock.withLock { frames.all.append(frame) }
            if frame.first == DchFrame.error { replied.fulfill() }
        }
        conn.ops = ops(Fake())
        conn.kill = { _ in }
        DchCommand.dchPathOverride = "/usr/bin/true"
        defer { DchCommand.dchPathOverride = nil }
        queue.sync {
            conn.handle(type: DchFrame.kill, payload: Data("{\"name\":\"a\"}".utf8))
            conn.handle(type: DchFrame.rename, payload: Data("{\"name\":\"a\",\"alias\":\"b\"}".utf8))
            conn.handle(type: DchFrame.stop, payload: Data("{\"all\":true}".utf8))
        }
        wait(for: [replied], timeout: 5)
        let all = frames.lock.withLock { frames.all }
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(Array(all.prefix(2)), [DchFrame.encode(DchFrame.ok, []), DchFrame.encode(DchFrame.ok, [])])
    }

    /// #627: dch's -k reads no name starting with '-' ("-k --all" re-parses --all as a
    /// flag): error 0x13 and no kill; a normal name is killed and acked. Kill is a recorder.
    func testKillRefusesADashLedName() {
        let queue = DispatchQueue(label: "test.dchconn")
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { _ in })
        let frames = Frames(), killed = Frames()
        conn.kill = { n in killed.lock.withLock { killed.all.append(Data(n.utf8)) } }
        conn.sendOverride = { frame in frames.lock.withLock { frames.all.append(frame) } }
        conn.ops = ops(Fake())
        DchCommand.dchPathOverride = "/usr/bin/false"   // belt and braces: never a real dch
        defer { DchCommand.dchPathOverride = nil }
        queue.sync {
            for n in ["--all", "-n", "a"] {
                conn.handle(type: DchFrame.kill, payload: Data(try! JSONSerialization.data(withJSONObject: ["name": n])))
            }
        }
        let all = frames.lock.withLock { frames.all }
        XCTAssertEqual(all, [DchControlOps.error(DchControlOps.dashNameRefusal), DchControlOps.error(DchControlOps.dashNameRefusal),
                             DchFrame.encode(DchFrame.ok, [])])
        XCTAssertEqual(killed.lock.withLock { killed.all }, [Data("a".utf8)], "only the normal name reaches -k")
    }

    /// Unstubbed under XCTest: no control binary, so every verb is refused before any dch fork.
    func testUnstubbedOpsRefuseUnderXCTest() {
        let o = DchControlOps()
        for (t, p) in [(DchFrame.history, Data()), (DchFrame.revive, Data("{\"all\":true}".utf8)),
                       (DchFrame.restart, Data("{\"all\":true}".utf8)), (DchFrame.stop, Data("{\"names\":[\"a\"]}".utf8)),
                       (DchFrame.pin, Data("{\"name\":\"a\",\"pin\":true}".utf8)), (DchFrame.forget, Data("{\"name\":\"a\"}".utf8)),
                       (DchFrame.forgetAll, Data())] {
            XCTAssertTrue(message(call(o, t, raw: p)).contains("needs dch"))
        }
    }

    // MARK: - r2: one truthful reply (QA #462 H1, M1)

    private static func line(_ name: String, _ result: String, reason: String = "", detail: String = "", phase: String? = nil) -> String {
        var o: [String: Any] = ["name": name, "result": result, "reason": reason, "detail": detail]
        if let phase { o["phase"] = phase }
        return json(o)
    }

    /// The real --restart shape: the master pass first, then the agent's own result.
    func testRestartWhoseAgentFailedAfterAnOkMasterIsAnErrorWithTheAgentsWords() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1")])
        let a = AgentIsland.restartArgs("a")!.joined(separator: " ")
        f.out[a] = Self.ok("a", phase: "master") + "\n" + Self.line("a", "failed", reason: "not_paused", detail: "a: agent did not pause")
        f.statusFor[a] = 1
        let r = call(ops(f), DchFrame.restart, ["names": ["a"]])
        XCTAssertEqual(message(r), "a: agent did not pause", "the last result for the name, in rowText's words")
        XCTAssertNil((r.json as? [String: Any])?["names"], "nothing named ok")
        for reason in ["not_claude", "current"] {
            f.out[a] = Self.ok("a", phase: "master") + "\n" + Self.line("a", "skipped", reason: reason)
            f.statusFor[a] = 0
            XCTAssertEqual(names(call(ops(f), DchFrame.restart, ["names": ["a"]])), ["a"], "\(reason): the master moved, no agent to restart")
        }
        f.out[a] = Self.ok("a", phase: "master") + "\n" + Self.line("a", "skipped", reason: "in_shell", detail: "a: claude typed into the shell")
        XCTAssertEqual(message(call(ops(f), DchFrame.restart, ["names": ["a"]])), "a: claude typed into the shell",
                       "any other skip is not done")
    }

    /// Each name against its own job: a's clean exit with no line is ok, b's failure is the error.
    func testRestartOfTwoNamesWithOneFailedNamesOnlyTheFailedOne() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1"), ("b", "1.24.1")])
        let b = AgentIsland.restartArgs("b")!.joined(separator: " ")
        f.out[b] = Self.ok("b", phase: "master") + "\n" + Self.line("b", "failed", reason: "not_paused", detail: "b: agent did not pause")
        f.statusFor[b] = 1
        XCTAssertEqual(message(call(ops(f), DchFrame.restart, ["names": ["a", "b"]])), "b: agent did not pause")
        f.out[b] = "dch: b: master gone"
        XCTAssertEqual(message(call(ops(f), DchFrame.restart, ["names": ["b", "a"]])), "b: Restart failed: dch: b: master gone",
                       "no result line and a non-zero exit: rowText's failedText")
        f.statusFor[AgentIsland.restartArgs("a")!.joined(separator: " ")] = 1
        XCTAssertEqual(message(call(ops(f), DchFrame.restart, ["names": ["a", "b"]])),
                       "a: Restart failed (exit 1); b: Restart failed: dch: b: master gone", "every failed name, request order")
    }

    func testReviveAllWithAnOkLineAndANonZeroExitIsAnErrorWithTheTally() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "signal 9"]])
        f.out[AgentIsland.reviveAllArgs.joined(separator: " ")] = Self.ok("a")
        f.status = 1
        let want = AgentIsland.tally(AgentIsland.actionResult(status: 1, output: Data(Self.ok("a").utf8), stopped: false),
                                     .resume, title: "Resume", empty: "nothing to resume")
        XCTAssertEqual(want, "1 resumed, failed (exit 1)")
        XCTAssertEqual(message(call(ops(f), DchFrame.revive, ["all": true])), want)
        f.status = 0
        f.out[AgentIsland.reviveAllArgs.joined(separator: " ")] = Self.ok("a") + "\n" + Self.line("b", "failed", detail: "b: no agent")
        XCTAssertEqual(message(call(ops(f), DchFrame.revive, ["all": true])), "1 resumed, 1 failed", "a failed line on exit 0")
    }

    func testRestartAllWithNoResultAndANonZeroExitIsAnError() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1")])
        f.status = 1
        XCTAssertEqual(message(call(ops(f), DchFrame.restart, ["all": true])), "Restart all failed (exit 1)")
        f.status = 0
        f.out[AgentIsland.restartAllArgs.joined(separator: " ")] = Self.line("a", "skipped", reason: "current")
        XCTAssertEqual(names(call(ops(f), DchFrame.restart, ["all": true])), [], "nothing to do stays an empty ok")
    }

    func testACancelledJobRepliesTheCancelledText() {
        let line = AgentIsland.jsonLine(Self.ok("a"))!
        let named = DchControlOps.answer(named: [("a", DchActionResult(status: 0, json: [line], stopped: true))], .restart)
        XCTAssertEqual(message(Self.decode(named)), "a: Restart cancelled: no answer in 15m")
        let all = DchControlOps.answer(all: DchActionResult(status: 0, json: [line], stopped: true), .resume)
        XCTAssertEqual(message(Self.decode(all)), "Resume cancelled: no answer in 5m")
    }

    // MARK: - r2: Remote Terminal's one dir (QA #462 H2)

    func testRemoteSocketDirIsTheIsolatedDirOnlyWhileIsolating() {
        XCTAssertEqual(DchCommand.remoteSocketDir(isolate: true), DchCommand.isolatedSocketDir)
        XCTAssertEqual(DchCommand.remoteSocketDir(isolate: false), DchCommand.defaultSocketDir)
        XCTAssertNotEqual(DchCommand.isolatedSocketDir, DchCommand.defaultSocketDir)
        defer { DchCommand.isolateOverride = nil }
        for isolate in [true, false] {
            DchCommand.isolateOverride = isolate
            XCTAssertEqual(DchControlOps().dirs(), [DchCommand.remoteSocketDir(isolate: isolate)],
                           "the verbs' default dirs follow the helper, one dir, isolate \(isolate)")
        }
    }

    /// #594 (L-A): a new session's env reads the same isolation input as remoteSocketDir;
    /// isolation off adds no DCH_SOCKET_DIR of its own.
    func testChildEnvFollowsIsolateOverrideBothWays() {
        defer { DchCommand.isolateOverride = nil }
        for isolate in [true, false] {
            DchCommand.isolateOverride = isolate
            let env = DchCommand.childEnv()
            XCTAssertEqual(env["DCH_SOCKET_DIR"],
                           isolate ? DchCommand.isolatedSocketDir : ProcessInfo.processInfo.environment["DCH_SOCKET_DIR"],
                           "isolate \(isolate)")
            XCTAssertEqual(DchCommand.socketDir, DchCommand.remoteSocketDir(isolate: isolate), "isolate \(isolate)")
        }
    }

    /// The phone's kill (and list, rename) read the same helper: a stand-in dch records its DCH_SOCKET_DIR.
    func testKillRunsInTheSameDirAsTheVerbs() throws {
        let script = tempDir().appendingPathComponent("fake-dch").path
        try "#!/bin/sh\nprintf '%s' \"$DCH_SOCKET_DIR\" > \"$0.out\"\n".write(toFile: script, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(script, 0o755), 0)
        DchCommand.dchPathOverride = script
        defer { DchCommand.dchPathOverride = nil; DchCommand.isolateOverride = nil }
        for isolate in [true, false] {
            DchCommand.isolateOverride = isolate
            DchCommand.kill("a")
            XCTAssertEqual(try String(contentsOfFile: script + ".out", encoding: .utf8), DchCommand.remoteSocketDir(isolate: isolate))
        }
    }

    /// Through the seam: history and every verb read and run with DCH_SOCKET_DIR = that one dir only.
    func testVerbsAndHistoryRunOnlyInTheRemoteDir() {
        for isolate in [true, false] {
            let dir = DchCommand.remoteSocketDir(isolate: isolate), f = Fake()
            f.ls[dir] = Self.ls([("a", "1.24.1"), ("b", "1.24.1")])
            f.hist[dir] = Self.hist([["name": "c", "updated": Self.now - 60, "end": "signal 9"]])
            let o = ops(f, dirs: [dir])
            XCTAssertEqual(call(o, DchFrame.history, raw: Data()).type, DchFrame.historyResp)
            XCTAssertEqual(names(call(o, DchFrame.revive, ["name": "c"])), ["c"])
            XCTAssertEqual(names(call(o, DchFrame.revive, ["all": true])), [])
            XCTAssertEqual(names(call(o, DchFrame.restart, ["names": ["a"]])), ["a"])
            XCTAssertEqual(names(call(o, DchFrame.restart, ["all": true])), [])
            XCTAssertEqual(names(call(o, DchFrame.stop, ["names": ["b"]])), ["b"])
            XCTAssertEqual(Set(f.reads.map(\.dir)), [dir], "isolate \(isolate)")
            XCTAssertEqual(Set(f.launches.map(\.dir)), [dir], "isolate \(isolate)")
            XCTAssertEqual(f.launches.count, 5)
        }
    }

    // MARK: - r2: the Resume gate (QA #462 mutant M5b)

    func testReviveUnderALiveMasterNewerThanTheBinaryIsRefused() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("x", "1.25.0")])
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "signal 9"]])
        XCTAssertEqual(message(call(ops(f), DchFrame.revive, ["name": "a"])), "Resume needs dch 1.25.0")
        XCTAssertEqual(message(call(ops(f), DchFrame.revive, ["all": true])), "Resume needs dch 1.25.0")
        XCTAssertTrue(f.launches.isEmpty)
        XCTAssertTrue(f.historyPaths.isEmpty, "refused before the history read")
    }

    // MARK: - r2: the shared runner (QA #462 M2)

    @MainActor func testTheIslandAndThePhoneShareOneRunner() {
        XCTAssertTrue(AgentIslandController().runner === DchActionRunner.shared)
        XCTAssertTrue(DchControlOps().runner === DchActionRunner.shared)
        XCTAssertTrue(DchControlOps.live.runner === DchActionRunner.shared)
    }

    /// An island job on the shared runner makes the phone's verb on that row, or in that dir, busy.
    func testAnIslandJobOnTheSharedRunnerMakesThePhonesVerbBusy() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1"), ("b", "1.24.1")])
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "signal 9"]])
        let o = ops(f), shared = o.runner
        f.holdArgs = ["--island"]
        for key in [AgentSessionKey(dir: "/d", name: "a"), AgentSessionKey(dir: "/d", name: "")] {
            let held = expectation(description: "island job running"), done = expectation(description: "island job done")
            f.held = held
            XCTAssertTrue(shared.start(key, path: "/fake/dch", args: ["--island"], env: { [:] }) { _ in done.fulfill() })
            wait(for: [held], timeout: 5)
            let busy = "busy with an earlier request"
            XCTAssertEqual(message(call(o, DchFrame.restart, ["names": ["a"]])), "a: Restart failed: dch: \(busy)", "row key \(key)")
            XCTAssertEqual(message(call(o, DchFrame.revive, ["name": "a"])), "a: Resume failed: dch: \(busy)", "record key \(key)")
            XCTAssertEqual(message(call(o, DchFrame.stop, ["names": ["a"]])), "a: Stop failed: dch: \(busy)")
            if key.name.isEmpty {
                XCTAssertTrue(message(call(o, DchFrame.restart, ["names": ["b"]])).contains(busy), "a dir job holds every row")
                XCTAssertTrue(message(call(o, DchFrame.restart, ["all": true])).contains(busy))
            } else {
                XCTAssertEqual(names(call(o, DchFrame.restart, ["names": ["b"]])), ["b"], "another row is free")
            }
            f.hold.signal()
            wait(for: [done], timeout: 5)
        }
        XCTAssertEqual(f.launchedArgs.filter { $0 != ["--island"] }, [AgentIsland.restartArgs("b")!], "no phone job launched while busy")
    }

    /// #594 (QA #462 N7): a stop holds the dir key, not a row's, so an island job on
    /// another row in the same dir makes the phone's stop busy.
    func testAnIslandJobOnAnotherRowMakesThePhonesStopBusy() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1"), ("b", "1.24.1")])
        let o = ops(f), shared = o.runner
        f.holdArgs = ["--island"]
        let held = expectation(description: "island job running"), done = expectation(description: "island job done")
        f.held = held
        XCTAssertTrue(shared.start(AgentSessionKey(dir: "/d", name: "b"), path: "/fake/dch", args: ["--island"], env: { [:] }) { _ in
            done.fulfill()
        })
        wait(for: [held], timeout: 5)
        XCTAssertEqual(message(call(o, DchFrame.stop, ["names": ["a"]])), "a: Stop failed: dch: busy with an earlier request")
        f.hold.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(f.launchedArgs, [["--island"]], "no stop launched while busy")
    }

    // MARK: - r2: the connection (QA #462 M3)

    private func connection(_ o: DchControlOps) -> (DchConnection, DispatchQueue, Frames) {
        let queue = DispatchQueue(label: "test.dchconn")
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { _ in })
        let frames = Frames()
        conn.sendOverride = { frame in frames.lock.withLock { frames.all.append(frame) } }
        conn.ops = o
        return (conn, queue, frames)
    }

    /// Until the connection's request has had its reply hop (sent or dropped), at most 5 s.
    private func waitIdle(_ conn: DchConnection, _ queue: DispatchQueue, file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(5)
        while queue.sync(execute: { conn.inFlight }) {
            guard Date() < end else { return XCTFail("still in flight", file: file, line: line) }
            usleep(10_000)
        }
    }

    private static func payload(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    func testASecondRequestWhileAVerbIsInFlightIsBusyAndTheFirstStillReplies() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1")])
        f.out[AgentIsland.restartArgs("a")!.joined(separator: " ")] = Self.ok("a")
        f.holdArgs = AgentIsland.restartArgs("a")!
        let held = expectation(description: "restart running")
        f.held = held
        let (conn, queue, frames) = connection(ops(f))
        queue.sync { conn.handle(type: DchFrame.restart, payload: Self.payload(["names": ["a"]])) }
        wait(for: [held], timeout: 5)
        let readsBefore = f.lock.withLock { f.reads.count }
        queue.sync {
            conn.handle(type: DchFrame.restart, payload: Self.payload(["names": ["a"]]))
            conn.handle(type: DchFrame.history, payload: Data())
            conn.handle(type: DchFrame.stop, payload: Self.payload(["names": ["a"]]))
        }
        let busy = frames.lock.withLock { frames.all }.map { message(Self.decode($0)) }
        XCTAssertEqual(busy, Array(repeating: "busy with an earlier request", count: 3), "refused at once, on the queue")
        XCTAssertEqual(f.lock.withLock { f.reads.count }, readsBefore, "a refused request reads nothing")
        f.hold.signal()
        waitIdle(conn, queue)
        let all = frames.lock.withLock { frames.all }
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all.last.map { names(Self.decode($0)) } ?? nil, ["a"], "the first gets its own reply")
        XCTAssertEqual(f.launches.count, 1)
        f.lock.withLock { f.holdArgs = nil }
        queue.sync { conn.handle(type: DchFrame.restart, payload: Self.payload(["names": ["a"]])) }
        waitIdle(conn, queue)
        XCTAssertEqual(frames.lock.withLock { frames.all }.count, 5, "free again after the reply")
    }

    /// #594 (QA #462 N8): an error reply frees the connection like any other; the next request is served.
    func testAnErrorReplyFreesTheConnectionForTheNextRequest() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1")])
        f.out[AgentIsland.restartArgs("a")!.joined(separator: " ")] = Self.ok("a")
        let (conn, queue, frames) = connection(ops(f))
        func next(_ type: UInt8, _ payload: Data) -> (type: UInt8, json: Any?) {
            let before = frames.lock.withLock { frames.all.count }
            queue.sync { conn.handle(type: type, payload: payload) }
            let end = Date().addingTimeInterval(5)
            while frames.lock.withLock({ frames.all.count }) == before, Date() < end { usleep(10_000) }
            return frames.lock.withLock { frames.all.last.map(Self.decode) } ?? (0, nil)
        }
        XCTAssertTrue(message(next(DchFrame.stop, Self.payload(["all": true]))).hasPrefix("malformed"))
        XCTAssertEqual(names(next(DchFrame.restart, Self.payload(["names": ["a"]]))), ["a"], "served after a malformed request")
        XCTAssertTrue(message(next(DchFrame.stop, Self.payload(["names": ["ghost"]]))).contains("ghost"))
        XCTAssertEqual(names(next(DchFrame.restart, Self.payload(["names": ["a"]]))), ["a"], "served after a refused request")
        waitIdle(conn, queue)
        XCTAssertEqual(frames.lock.withLock { frames.all.count }, 4)
    }

    func testHistoryInFlightCountsToo() {
        let f = Fake()
        f.holdHistory = true
        let held = expectation(description: "history read running")
        f.held = held
        let (conn, queue, frames) = connection(ops(f))
        queue.sync { conn.handle(type: DchFrame.history, payload: Data()) }
        wait(for: [held], timeout: 5)
        queue.sync {
            conn.handle(type: DchFrame.history, payload: Data())
            conn.handle(type: DchFrame.revive, payload: Self.payload(["all": true]))
        }
        XCTAssertEqual(frames.lock.withLock { frames.all }.map { message(Self.decode($0)) },
                       ["busy with an earlier request", "busy with an earlier request"])
        f.hold.signal()
        waitIdle(conn, queue)
        XCTAssertEqual(frames.lock.withLock { frames.all }.last?.first, DchFrame.historyResp)
        XCTAssertEqual(f.historyPaths.count, 1)
    }

    /// QA #462 mutant M3: the reply of a verb whose connection closed meanwhile is dropped; the verb finishes.
    func testAVerbWhoseConnectionClosedMidRunSendsNothing() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1")])
        f.out[AgentIsland.restartArgs("a")!.joined(separator: " ")] = Self.ok("a")
        f.holdArgs = AgentIsland.restartArgs("a")!
        let held = expectation(description: "restart running"), refreshed = expectation(description: "verb finished")
        f.held = held
        f.onRefresh = refreshed
        let (conn, queue, frames) = connection(ops(f))
        queue.sync { conn.handle(type: DchFrame.restart, payload: Self.payload(["names": ["a"]])) }
        wait(for: [held], timeout: 5)
        queue.sync { conn.close() }
        f.hold.signal()
        wait(for: [refreshed], timeout: 5)
        waitIdle(conn, queue)
        XCTAssertTrue(frames.lock.withLock { frames.all }.isEmpty, "no frame on a closed connection")
        XCTAssertEqual(f.launches.count, 1, "the verb was not cancelled")
    }

    func testAFrameOnAClosedConnectionForksNothing() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1")])
        let (conn, queue, frames) = connection(ops(f))
        queue.sync {
            conn.close()
            conn.handle(type: DchFrame.restart, payload: Self.payload(["names": ["a"]]))
            conn.handle(type: DchFrame.history, payload: Data())
        }
        XCTAssertFalse(queue.sync { conn.inFlight }, "nothing dispatched")
        usleep(300_000)
        XCTAssertTrue(f.lock.withLock { f.reads.isEmpty }, "no dch read")
        XCTAssertTrue(f.launches.isEmpty)
        XCTAssertTrue(frames.lock.withLock { frames.all }.isEmpty)
    }

    // MARK: - r2: bounded names, unknown keys (QA #462 M4, L2)

    func testMoreThan256NamesAreRefusedBeforeAnyReadAnd256Pass() {
        let f = Fake()
        let many = (0..<256).map { "s\($0)" }
        f.ls["/d"] = Self.ls(many.map { ($0, "1.24.1") })
        for t in [DchFrame.restart, DchFrame.stop, DchFrame.revive] {
            XCTAssertEqual(message(call(ops(f), t, ["names": many + ["s0"]])), "too many names (max 256)",
                           "257 with a duplicate: the cap counts before the dedupe")
        }
        XCTAssertTrue(f.reads.isEmpty, "refused before any listing")
        XCTAssertTrue(f.launches.isEmpty)
        XCTAssertEqual(names(call(ops(f), DchFrame.stop, ["names": many])), many, "256 pass the cap and the gate")
        XCTAssertEqual(f.launchedArgs, [AgentIsland.stopArgs(many)!])
    }

    func testDuplicateNamesKeepRequestOrder() {
        XCTAssertEqual(DchControlOps.request(["names": ["b", "a", "b", "c", "a"]], key: "names", allowAll: true),
                       .names(["b", "a", "c"]))
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1"), ("b", "1.24.1")])
        XCTAssertEqual(names(call(ops(f), DchFrame.restart, ["names": ["b", "a", "b"]])), ["b", "a"])
        XCTAssertEqual(f.launches.count, 2)
    }

    func testUnknownKeysAreRefusedAndRunNothing() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1")])
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "signal 9"]])
        let cases: [(UInt8, [String: Any])] = [
            (DchFrame.restart, ["names": ["a"], "dir": "/x"]), (DchFrame.stop, ["names": ["a"], "dir": "/x"]),
            (DchFrame.revive, ["name": "a", "dir": "/x"]), (DchFrame.revive, ["all": true, "x": 1]),
            (DchFrame.restart, ["all": true, "force": true]), (DchFrame.history, ["dir": "/x"]),
        ]
        for (t, o) in cases {
            XCTAssertTrue(message(call(ops(f), t, o)).hasPrefix("malformed"), "type \(t) \(o)")
        }
        XCTAssertEqual(call(ops(f), DchFrame.history, [String: Any]()).type, DchFrame.historyResp, "{} is history's empty payload")
        XCTAssertTrue(f.launches.isEmpty)
        XCTAssertEqual(f.reads.map(\.arg), ["--history"], "only the {} history read")
    }

    // MARK: - #620: pinned rows, pin 0x24, forget 0x25, forgetAll 0x26

    private static let v125 = DchCommand.Binary(path: "/fake/dch", version: [1, 25, 0])

    /// historyResp: every pinned record first (older than the 50 newest too), then
    /// the newest unpinned up to the cap; "pinned": true only on a pinned row.
    func testHistoryRespSendsPinnedRecordsFirstUncappedAndFlagged() {
        let f = Fake()
        f.hist["/d"] = Self.hist((0..<60).map { ["name": "s\($0)", "updated": Self.now - Double($0), "end": "killed"] as [String: Any] }
            + [["name": "p1", "updated": Self.now - 500, "end": "exit 0", "pinned": true],
               ["name": "p2", "updated": Self.now - 600, "end": "exit 0", "pinned": true]])
        let rows = call(ops(f), DchFrame.history, raw: Data()).json as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, AgentIsland.historyCap)
        XCTAssertEqual(rows.prefix(3).map { $0["name"] as? String }, ["p1", "p2", "s0"])
        XCTAssertEqual(rows.last?["name"] as? String, "s47", "unpinned fill the rest")
        XCTAssertEqual(rows.prefix(2).map { $0["pinned"] as? Bool }, [true, true])
        XCTAssertTrue(rows.dropFirst(2).allSatisfy { $0["pinned"] == nil }, "no key on an unpinned row")
    }

    func testPinRunsPinOrUnpinArgsInTheRecordsDirAndRepliesTheName() {
        let f = Fake()
        f.hist["/e"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "exit 0"]])
        f.out["--pin a --json"] = Self.line("a", "ok", detail: "pinned")
        f.out["--unpin a --json"] = Self.line("a", "ok", detail: "unpinned")
        let o = ops(f, dirs: ["/d", "/e"], binary: Self.v125)
        XCTAssertEqual(names(call(o, DchFrame.pin, ["name": "a", "pin": true])), ["a"])
        XCTAssertEqual(names(call(o, DchFrame.pin, ["name": "a", "pin": false])), ["a"])
        XCTAssertEqual(f.launchedArgs, [AgentIsland.pinArgs("a", pin: true)!, AgentIsland.pinArgs("a", pin: false)!])
        XCTAssertEqual(f.launches.map(\.dir), ["/e", "/e"], "the record's dir")
        XCTAssertEqual(f.launches.first?.path, "/fake/dch")
        XCTAssertEqual(f.refreshes, 2, "the island re-reads History after each")
        f.out["--pin a --json"] = Self.line("a", "failed", reason: "io_error", detail: "Permission denied")
        f.status = 1
        XCTAssertEqual(message(call(o, DchFrame.pin, ["name": "a", "pin": true])), "a: Permission denied")
        XCTAssertEqual(message(call(o, DchFrame.pin, ["name": "ghost", "pin": true])), "ghost: no history record of that name")
        XCTAssertEqual(f.launches.count, 3, "an unknown name runs nothing")
    }

    func testForgetRunsForgetArgsAndRefusesAPinnedRecordBeforeDch() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "exit 0"],
                                  ["name": "p", "updated": Self.now - 90, "end": "exit 0", "pinned": true]])
        f.out["--forget a --json"] = Self.line("a", "ok", detail: "forgotten")
        let o = ops(f, binary: Self.v125)
        XCTAssertEqual(names(call(o, DchFrame.forget, ["name": "a"])), ["a"])
        XCTAssertEqual(f.launchedArgs, [AgentIsland.forgetArgs("a")!])
        XCTAssertEqual(f.launches.first?.dir, "/d")
        XCTAssertEqual(f.refreshes, 1)
        XCTAssertEqual(message(call(o, DchFrame.forget, ["name": "p"])), "p: pinned, unpin it first")
        XCTAssertEqual(message(call(o, DchFrame.forget, ["name": "ghost"])), "ghost: no history record of that name")
        XCTAssertEqual(f.launchedArgs, [AgentIsland.forgetArgs("a")!], "no --forget for a pinned or unknown record, never -f")
        f.out["--forget a --json"] = Self.line("a", "failed", reason: "live", detail: "session is live")
        f.status = 1
        XCTAssertEqual(message(call(o, DchFrame.forget, ["name": "a"])), "a: session is live")
    }

    /// One `--forget --all --json` per History dir; the reply sums the dirs' results
    /// (dch's tally line is not a result and adds nothing); a record's failure is
    /// counted, an unexplained failure is an error.
    func testForgetAllRunsOncePerHistoryDirAndRepliesTheSummedTally() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "exit 0"]])
        f.hist["/e"] = Self.hist([["name": "b", "updated": Self.now - 60, "end": "exit 0"]])
        f.out["--forget --all --json"] = [Self.line("a", "ok", detail: "forgotten"), Self.line("b", "ok", detail: "forgotten"),
                                          Self.line("p", "skipped", reason: "pinned", detail: "pinned"),
                                          Self.line("x", "failed", reason: "io_error", detail: "EIO"),
                                          #"{"ok":2,"skipped":1,"failed":1}"#].joined(separator: "\n")
        f.status = 1   // dch exits 1 when a record failed
        let o = ops(f, dirs: ["/d", "/e", "/empty"], binary: Self.v125)
        let r = call(o, DchFrame.forgetAll, raw: Data())
        XCTAssertEqual(r.type, DchFrame.ok)
        let tally = r.json as? [String: Int]
        XCTAssertEqual(tally, ["cleared": 4, "skipped": 2, "failed": 2])
        XCTAssertEqual(f.launchedArgs, [AgentIsland.forgetAllArgs, AgentIsland.forgetAllArgs])
        XCTAssertEqual(Set(f.launches.map(\.dir)), ["/d", "/e"], "only the dirs with history")
        XCTAssertEqual(f.refreshes, 1)
        f.out["--forget --all --json"] = "dch: cannot reach the history dir"
        XCTAssertEqual(message(call(o, DchFrame.forgetAll, [String: Any]())), "Clear unpinned failed: dch: cannot reach the history dir")
        f.hist = [:]
        XCTAssertEqual(call(o, DchFrame.forgetAll, raw: Data()).json as? [String: Int], ["cleared": 0, "skipped": 0, "failed": 0])
        XCTAssertEqual(f.launches.count, 4, "no history: nothing runs")
    }

    func testHistoryEditsUnderTheIslandsGateAreRefused() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "exit 0"]])
        for binary in [Self.v1241, nil] {
            let o = ops(f, binary: binary)
            XCTAssertEqual(message(call(o, DchFrame.pin, ["name": "a", "pin": true])), "Pin needs dch 1.25.0")
            XCTAssertEqual(message(call(o, DchFrame.forget, ["name": "a"])), "Forget needs dch 1.25.0")
            XCTAssertEqual(message(call(o, DchFrame.forgetAll, raw: Data())), "Clear unpinned needs dch 1.25.0")
        }
        f.ls["/d"] = Self.ls([("live", "1.26.0")])   // a live master newer than the binary
        XCTAssertEqual(message(call(ops(f, binary: Self.v125), DchFrame.forget, ["name": "a"])), "Forget needs dch 1.26.0")
        XCTAssertTrue(f.launches.isEmpty)
        XCTAssertTrue(f.historyPaths.isEmpty, "refused before the History read")
    }

    /// #627 for pin and forget: a record named "--all" or "-n" is refused, no dch run.
    func testPinAndForgetRefuseADashLedRecordName() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "--all", "updated": Self.now - 60, "end": "exit 0"],
                                  ["name": "-n", "updated": Self.now - 70, "end": "exit 0"]])
        let o = ops(f, binary: Self.v125)
        for bad in ["--all", "-n"] {
            XCTAssertEqual(message(call(o, DchFrame.pin, ["name": bad, "pin": true])), DchControlOps.dashNameRefusal, bad)
            XCTAssertEqual(message(call(o, DchFrame.pin, ["name": bad, "pin": false])), DchControlOps.dashNameRefusal, bad)
            XCTAssertEqual(message(call(o, DchFrame.forget, ["name": bad])), DchControlOps.dashNameRefusal, bad)
        }
        XCTAssertEqual(f.launchedArgs, [])
        XCTAssertEqual(f.refreshes, 0)
    }

    func testMalformedHistoryEditsGetAnErrorAndRunNothing() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "exit 0"]])
        let o = ops(f, binary: Self.v125)
        let cases: [(UInt8, String)] = [
            (DchFrame.pin, ""), (DchFrame.pin, "{}"), (DchFrame.pin, #"{"name":"a"}"#), (DchFrame.pin, #"{"pin":true}"#),
            (DchFrame.pin, #"{"name":"a","pin":1}"#), (DchFrame.pin, #"{"name":"a","pin":"yes"}"#),
            (DchFrame.pin, #"{"name":"","pin":true}"#), (DchFrame.pin, #"{"name":5,"pin":true}"#),
            (DchFrame.pin, #"{"name":"a","pin":true,"dir":"/x"}"#), (DchFrame.pin, #"{"names":["a"],"pin":true}"#),
            (DchFrame.forget, ""), (DchFrame.forget, "{}"), (DchFrame.forget, #"{"all":true}"#), (DchFrame.forget, #"{"names":["a"]}"#),
            (DchFrame.forget, #"{"name":5}"#), (DchFrame.forget, #"{"name":"a","f":true}"#),
            (DchFrame.forgetAll, #"{"all":true}"#), (DchFrame.forgetAll, "[]"), (DchFrame.forgetAll, "nope"),
        ]
        for (t, raw) in cases {
            XCTAssertFalse(message(call(o, t, raw: Data(raw.utf8))).isEmpty, "type \(t) payload \(raw)")
        }
        XCTAssertTrue(f.launches.isEmpty)
        XCTAssertTrue(f.historyPaths.isEmpty)
    }

    /// Through DchConnection.handle: the three frames reach DchControlOps and get one reply each.
    func testConnectionServesTheHistoryEditFrames() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "exit 0"]])
        f.out["--pin a --json"] = Self.line("a", "ok")
        f.out["--forget a --json"] = Self.line("a", "ok")
        let (conn, queue, frames) = connection(ops(f, binary: Self.v125))
        for (t, p) in [(DchFrame.pin, Self.payload(["name": "a", "pin": true])), (DchFrame.forget, Self.payload(["name": "a"])),
                       (DchFrame.forgetAll, Data())] {
            queue.sync { conn.handle(type: t, payload: p) }
            waitIdle(conn, queue)
        }
        XCTAssertEqual(frames.lock.withLock { frames.all }.map { Self.decode($0).type }, [DchFrame.ok, DchFrame.ok, DchFrame.ok])
        XCTAssertEqual(f.launchedArgs, [["--pin", "a", "--json"], ["--forget", "a", "--json"], AgentIsland.forgetAllArgs])
    }

    // MARK: - QA #489 follow-ups (#633)

    /// LOW-1 (QA mutant T6): Clear unpinned holds the History dir's key, not its first
    /// record's, so an island job on another record in that dir makes it busy.
    func testAnIslandJobOnAnotherRecordMakesThePhonesClearUnpinnedBusy() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "exit 0"],
                                  ["name": "b", "updated": Self.now - 90, "end": "exit 0"]])
        let o = ops(f, binary: Self.v125), shared = o.runner
        f.holdArgs = ["--island"]
        let held = expectation(description: "island job running"), done = expectation(description: "island job done")
        f.held = held
        XCTAssertTrue(shared.start(AgentSessionKey(dir: "/d", name: "b"), path: "/fake/dch", args: ["--island"], env: { [:] }) { _ in
            done.fulfill()
        })
        wait(for: [held], timeout: 5)
        XCTAssertEqual(message(call(o, DchFrame.forgetAll, raw: Data())), "Clear unpinned failed: dch: busy with an earlier request")
        f.hold.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(f.launchedArgs, [["--island"]], "no --forget --all launched while busy")
    }

    /// I1 (QA mutant T1): a stopped Clear is an error even when it exited 0.
    func testAStoppedClearUnpinnedIsAnErrorEvenOnExit0() {
        let r = Self.decode(DchControlOps.answer(cleared: [DchActionResult(status: 0, stopped: true)]))
        XCTAssertEqual(message(r), "Clear unpinned cancelled: no answer in \(AgentIsland.Verb.clear.minutes)m")
    }

    /// I2 (QA mutant T5): an unpin's failure names Unpin, not Pin.
    func testAFailedUnpinSaysUnpin() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "exit 0", "pinned": true]])
        f.out["--unpin a --json"] = "dch: cannot write the record"
        f.status = 1
        XCTAssertEqual(message(call(ops(f, binary: Self.v125), DchFrame.pin, ["name": "a", "pin": false])),
                       "a: Unpin failed: dch: cannot write the record")
        XCTAssertEqual(message(Self.decode(DchControlOps.answer(named: [("a", DchActionResult(status: 0, stopped: true))], .unpin))),
                       "a: Unpin cancelled: no answer in \(AgentIsland.Verb.unpin.minutes)m")
    }

    /// I5: dch's own pinned refusal (a pin between the Mac's read and dch's run) reaches
    /// the phone in the island's words, never dch's -f hint.
    func testDchsPinnedRefusalReachesThePhoneWithoutTheForceHint() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "exit 0"]])
        f.out["--forget a --json"] = Self.line("a", "failed", reason: "pinned", detail: "pinned (-f forgets it anyway)")
        f.status = 1
        XCTAssertEqual(message(call(ops(f, binary: Self.v125), DchFrame.forget, ["name": "a"])), "a: pinned, unpin it first")
        XCTAssertEqual(f.launchedArgs, [AgentIsland.forgetArgs("a")!])
    }
}
