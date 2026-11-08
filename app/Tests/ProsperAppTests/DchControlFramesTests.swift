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
        /// #749: any launch holds, as `holdArgs`.
        var holdAny = false
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
                return args == f.holdArgs || f.holdAny
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

    /// #743: a name a by-hand start left two records of (its own and the aside one) is one
    /// row on the phone too, its newest record's; another name stays.
    func testHistoryFoldsANamesOlderRecordsLikeTheTab() {
        let f = Fake()
        f.hist["/d"] = Self.hist([
            ["name": "work", "updated": Self.now - 10, "ended": Self.now - 10, "end": "stopped", "pinned": true, "file": "work"],
            ["name": "other", "updated": Self.now - 20, "end": "killed", "file": "other"],
            ["name": "work", "updated": Self.now - 30, "ended": Self.now - 30, "end": "signal 9", "pinned": true,
             "file": "work.\(Int(Self.now) - 30)"],
        ])
        let rows = call(ops(f), DchFrame.history, raw: Data()).json as? [[String: Any]] ?? []
        XCTAssertEqual(rows.map { $0["name"] as? String }, ["work", "other"])
        XCTAssertEqual(rows.first?["end"] as? String, "stopped", "the newest record")
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
        XCTAssertEqual(message(call(ops(f, dirs: ["/d", "/e"]), DchFrame.revive, ["name": "a"])),
                       "a: history records of that name in 2 socket dirs; use the Mac's Agent Island", "#746: two sessions, not one folded row")
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
        XCTAssertEqual(info["ops"] as? [String], ["history", "revive", "restart", "stop", "library", "pin", "forget", "snippets_put",
                                                      "sidekick", "create", "paste_image"])
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

    /// #750 (QA #576 INFO-3): the phone's Restart all counts a row an island Kill ended while it
    /// ran as killed, as the island's does; the rest of its failures stay failed.
    func testPhoneRestartAllCountsARowAKillEndedAsKilled() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1"), ("b", "1.24.1")])
        let all = AgentIsland.restartAllArgs
        f.out[all.joined(separator: " ")] = Self.line("a", "failed", detail: "a: master gone") + "\n"
            + Self.line("b", "failed", detail: "b: master gone")
        f.status = 1
        f.out["-k a"] = "killed: a\n"
        f.statusFor["-k a"] = 0
        let o = ops(f)
        let frames = Frames(), held = expectation(description: "Restart all running"), replied = expectation(description: "reply")
        f.lock.withLock { f.holdArgs = all; f.held = held }
        o.handle(DchFrame.restart, try! JSONSerialization.data(withJSONObject: ["all": true])) { frame in
            frames.lock.withLock { frames.all.append(frame) }
            replied.fulfill()
        }
        wait(for: [held], timeout: 5)
        let killed = expectation(description: "kill done")
        XCTAssertTrue(o.runner.start(AgentSessionKey(dir: "/d", name: "a"), path: "/fake/dch", args: ["-k", "a"], kill: true,
                                     env: { [:] }) { _ in killed.fulfill() })
        wait(for: [killed], timeout: 5)
        f.hold.signal()
        wait(for: [replied], timeout: 5)
        let got = frames.lock.withLock { frames.all }
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first.map { message(Self.decode($0)) }, "1 killed, 1 failed")
    }

    /// #749 (QA #572 INFO-R1): an island Kill on a row cuts through the phone's Stop, Restart
    /// and Restart all there, as through the island's own; never its Resume, Pin or Remove.
    func testAnIslandKillCutsThroughOnlyThePhonesStopAndRestart() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.25.0")])
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "signal 9"]])
        let o = ops(f, binary: DchCommand.Binary(path: "/fake/dch", version: [1, 25, 0]))
        let row = AgentSessionKey(dir: "/d", name: "a")
        let cases: [(UInt8, [String: Any], Bool)] = [
            (DchFrame.stop, ["names": ["a"]], true), (DchFrame.restart, ["names": ["a"]], true),
            (DchFrame.restart, ["all": true], true), (DchFrame.revive, ["name": "a"], false),
            (DchFrame.revive, ["all": true], false), (DchFrame.pin, ["name": "a", "pin": true], false),
            (DchFrame.forget, ["name": "a"], false), (DchFrame.forgetAll, [String: Any](), false),
        ]
        for (type, req, yields) in cases {
            let what = "frame \(type) \(req)"
            let held = expectation(description: "phone job running"), replied = expectation(description: "reply")
            f.lock.withLock { f.holdAny = true; f.held = held }
            o.handle(type, try! JSONSerialization.data(withJSONObject: req)) { _ in replied.fulfill() }
            wait(for: [held], timeout: 5)
            f.lock.withLock { f.holdAny = false }
            let killed = expectation(description: "kill done")
            let started = o.runner.start(row, path: "/fake/dch", args: ["-k", "a"], kill: true, env: { [:] }) { _ in killed.fulfill() }
            XCTAssertEqual(started, yields, what)
            if !started { killed.fulfill() }
            wait(for: [killed], timeout: 5)
            f.hold.signal()
            wait(for: [replied], timeout: 5)
        }
        XCTAssertEqual(f.launchedArgs.filter { $0 == ["-k", "a"] }.count, 3, "one Kill beside each Stop or Restart")
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
        XCTAssertEqual(f.launchedArgs, [AgentIsland.pinArgs(["a"], pin: true)!, AgentIsland.pinArgs(["a"], pin: false)!])
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
        XCTAssertEqual(f.launchedArgs, [AgentIsland.forgetArgs(["a"])!])
        XCTAssertEqual(f.launches.first?.dir, "/d")
        XCTAssertEqual(f.refreshes, 1)
        XCTAssertEqual(message(call(o, DchFrame.forget, ["name": "p"])), "p: pinned, unpin it first")
        XCTAssertEqual(message(call(o, DchFrame.forget, ["name": "ghost"])), "ghost: no history record of that name")
        XCTAssertEqual(f.launchedArgs, [AgentIsland.forgetArgs(["a"])!], "no --forget for a pinned or unknown record, never -f")
        f.out["--forget a --json"] = Self.line("a", "failed", reason: "live", detail: "session is live")
        f.status = 1
        XCTAssertEqual(message(call(o, DchFrame.forget, ["name": "a"])), "a: session is live")
    }

    /// #714: dch 1.28.0 moved a's stopped record aside when a started again, so
    /// History's only record of a is that one, with its "file". Resume, pin and
    /// forget pass the file (it matches that record alone); the bare name would
    /// pin and forget the live a's record too.
    func testAsideRecordIsRevivedPinnedAndForgottenByItsFile() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.25.0")])
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "stopped", "file": "a.1762000000"]])
        f.out["--revive a.1762000000 --as a-2 --json"] = Self.ok("a", as: "a-2")
        f.out["--pin a.1762000000 --json"] = Self.line("a.1762000000", "ok", detail: "pinned")
        f.out["--forget a.1762000000 --json"] = Self.line("a", "ok", detail: "forgotten")
        let o = ops(f, binary: Self.v125)
        // The live a's row busy (an island Restart) never holds its moved-aside record: another record.
        f.holdArgs = ["--island"]
        let held = expectation(description: "island job running"), done = expectation(description: "island job done")
        f.held = held
        XCTAssertTrue(o.runner.start(AgentSessionKey(dir: "/d", name: "a"), path: "/fake/dch", args: ["--island"], env: { [:] }) { _ in
            done.fulfill()
        })
        wait(for: [held], timeout: 5)
        XCTAssertEqual(names(call(o, DchFrame.revive, ["name": "a"])), ["a-2"])
        XCTAssertEqual(names(call(o, DchFrame.pin, ["name": "a", "pin": true])), ["a"])
        XCTAssertEqual(names(call(o, DchFrame.forget, ["name": "a"])), ["a"])
        f.hold.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(f.launchedArgs, [["--island"], ["--revive", "a.1762000000", "--as", "a-2", "--json"],
                                        ["--pin", "a.1762000000", "--json"], ["--forget", "a.1762000000", "--json"]])
    }

    /// #714 round 2: under dch 1.28.1 the phone's pin and forget pass `<file>.json`
    /// (the own record's too); a pin's failure, its line named after that argument,
    /// still carries dch's detail. Below 1.28.1, round 1's bare name.
    func testPinAndForgetPassTheRecordFileFrom1281() {
        let v1281 = DchCommand.Binary(path: "/fake/dch", version: [1, 28, 1])
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "stopped", "file": "a"],
                                  ["name": "b", "updated": Self.now - 90, "end": "stopped", "file": "b.1762000000"]])
        f.out["--pin a.json --json"] = Self.line("a.json", "ok", detail: "pinned")
        f.out["--forget b.1762000000.json --json"] = Self.line("b", "ok", detail: "forgotten")
        f.out["--pin a --json"] = Self.line("a", "ok", detail: "pinned")
        let o = ops(f, binary: v1281)
        XCTAssertEqual(names(call(o, DchFrame.pin, ["name": "a", "pin": true])), ["a"])
        XCTAssertEqual(names(call(o, DchFrame.forget, ["name": "b"])), ["b"])
        XCTAssertEqual(names(call(ops(f, binary: Self.v125), DchFrame.pin, ["name": "a", "pin": true])), ["a"])
        XCTAssertEqual(f.launchedArgs, [["--pin", "a.json", "--json"], ["--forget", "b.1762000000.json", "--json"],
                                        ["--pin", "a", "--json"]])
        f.out["--pin a.json --json"] = Self.line("a.json", "failed", reason: "io_error", detail: "Permission denied")
        f.status = 1
        XCTAssertEqual(message(call(o, DchFrame.pin, ["name": "a", "pin": true])), "a: Permission denied")
    }

    /// #716 L-3: the phone's revive of an aside record that matches nothing: dch names
    /// the line after the file (1.28.0:6973-6977); the reply carries dch's detail.
    func testAsideRecordsNoHistoryReachesThePhoneInDchsWords() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "stopped", "file": "a.1762000000"]])
        f.out["--revive a.1762000000 --json"] = Self.line("a.1762000000", "failed", reason: "no_history",
                                                          detail: "no history for this session")
        f.status = 1
        XCTAssertEqual(message(call(ops(f, binary: Self.v125), DchFrame.revive, ["name": "a"])), "a: no history for this session")
        XCTAssertEqual(f.launchedArgs, [["--revive", "a.1762000000", "--json"]])
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
        XCTAssertEqual(f.launchedArgs, [AgentIsland.forgetArgs(["a"])!])
    }

    // MARK: - #669: revive with "no_message"

    private static let v126 = DchCommand.Binary(path: "/fake/dch", version: [1, 26, 9])
    private static let v127 = DchCommand.Binary(path: "/fake/dch", version: [1, 27, 0])

    /// "no_message": true reaches argv as --no-message, by name (with and without --as) and all;
    /// false is a plain revive (an explicit "no", still a JSON bool).
    func testReviveNoMessagePassesThroughAndFalseIsAPlainRevive() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("b", "1.26.0")])   // a 1.26 master does not block a 1.27 control dch
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "signal 9"],
                                  ["name": "b", "updated": Self.now - 90, "end": "signal 9"]])
        f.out["--revive a --no-message --json"] = Self.ok("a")
        f.out["--revive b --as b-2 --no-message --json"] = Self.ok("b", as: "b-2")
        f.out["--revive a --json"] = Self.ok("a")
        let o = ops(f, binary: Self.v127)
        XCTAssertEqual(names(call(o, DchFrame.revive, ["name": "a", "no_message": true])), ["a"])
        XCTAssertEqual(names(call(o, DchFrame.revive, ["name": "b", "no_message": true])), ["b-2"])
        XCTAssertEqual(names(call(o, DchFrame.revive, ["all": true, "no_message": true])), [])
        XCTAssertEqual(names(call(o, DchFrame.revive, ["name": "a", "no_message": false])), ["a"])
        XCTAssertEqual(f.launchedArgs, [["--revive", "a", "--no-message", "--json"],
                                        ["--revive", "b", "--as", "b-2", "--no-message", "--json"],
                                        AgentIsland.reviveAllNoMessageArgs, ["--revive", "a", "--json"]])
    }

    /// QA #462 L2 strictness: "no_message" must be a JSON bool (1, "yes", null are malformed),
    /// never alone, and an extra key beside it is refused. Nothing runs.
    func testReviveNoMessageMustBeAJSONBoolWithNoExtraKey() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "signal 9"]])
        let o = ops(f, binary: Self.v127)
        for raw in [#"{"name":"a","no_message":1}"#, #"{"name":"a","no_message":"yes"}"#, #"{"name":"a","no_message":null}"#,
                    #"{"all":true,"no_message":1}"#, #"{"no_message":true}"#, #"{"name":"a","no_message":true,"x":1}"#,
                    #"{"all":true,"no_message":true,"name":"a"}"#, #"{"name":"a","no_message":[true]}"#] {
            XCTAssertTrue(message(call(o, DchFrame.revive, raw: Data(raw.utf8))).hasPrefix("malformed revive request"), raw)
        }
        XCTAssertTrue(f.launches.isEmpty)
        XCTAssertTrue(f.historyPaths.isEmpty, "refused before any read")
    }

    /// Under 1.27.0 (the control dch or a live master), "no_message" is refused in the existing
    /// error shape, never run as a plain revive (that would type the message); plain Resume still runs.
    func testReviveNoMessageUnder127IsRefusedNeverAPlainRevive() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "signal 9"]])
        f.out["--revive a --json"] = Self.ok("a")
        for binary in [Self.v126, Self.v1241, nil] {
            let o = ops(f, binary: binary)
            XCTAssertEqual(message(call(o, DchFrame.revive, ["name": "a", "no_message": true])), "Resume (no message) needs dch 1.27.0")
            XCTAssertEqual(message(call(o, DchFrame.revive, ["all": true, "no_message": true])), "Resume (no message) needs dch 1.27.0")
        }
        f.ls["/d"] = Self.ls([("x", "1.28.0")])
        XCTAssertEqual(message(call(ops(f, binary: Self.v127), DchFrame.revive, ["name": "a", "no_message": true])),
                       "Resume (no message) needs dch 1.28.0")
        XCTAssertTrue(f.launches.isEmpty, "no fallback to a plain revive")
        XCTAssertTrue(f.historyPaths.isEmpty, "refused before the history read")
        f.ls["/d"] = "[]"
        XCTAssertEqual(names(call(ops(f, binary: Self.v126), DchFrame.revive, ["name": "a"])), ["a"], "plain Resume unchanged on 1.26")
        XCTAssertEqual(f.launchedArgs, [["--revive", "a", "--json"]])
    }

    /// machineInfoResp's ops: "revive_no_message" only while the control dch passes 1.27.0.
    func testMachineInfoAdvertisesReviveNoMessageOnlyFrom127() {
        func ops(_ info: [String: Any]) -> [String] { info["ops"] as? [String] ?? [] }
        XCTAssertEqual(ops(DchFrame.machineInfo(deviceID: "d", hostname: "h", wakeId: nil, reviveNoMessage: true)),
                       DchFrame.ops + ["revive_no_message"])
        XCTAssertFalse(ops(DchFrame.machineInfo(deviceID: "d", hostname: "h", wakeId: nil)).contains("revive_no_message"))
        for (binary, on) in [(Self.v127, true), (DchCommand.Binary(path: "/b", version: [1, 28, 0]), true),
                             (Self.v126, false), (nil, false)] as [(DchCommand.Binary?, Bool)] {
            let (conn, queue, frames) = connection(self.ops(Fake(), binary: binary))
            queue.sync { conn.handle(type: DchFrame.machineInfo, payload: Data()) }
            let info = machineInfoResp(frames)
            XCTAssertEqual(ops(info ?? [:]).contains("revive_no_message"), on, "\(String(describing: binary))")
        }
    }

    /// The machineInfoResp among `frames`, waiting up to 5 s (#671: it is sent after an off-queue probe).
    private func machineInfoResp(_ frames: Frames, timeout: TimeInterval = 5) -> [String: Any]? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if let f = frames.lock.withLock({ frames.all }).map(Self.decode).first(where: { $0.type == DchFrame.machineInfoResp }) {
                return f.json as? [String: Any]
            }
            usleep(5_000)
        } while Date() < end
        return nil
    }

    /// #671: a control-dch probe that hangs (a `dch --version` bounded at 4 s per candidate)
    /// never holds the server queue, which every connection and attached pty share.
    /// #704: nor the reply: the phone waits 2 s, so a probe hung 5 s still gets one in
    /// under 0.5 s, without the bit; the probe's late answer sends no second frame, and
    /// once it has returned (cached, as probedVersion caches) the next handshake has the bit.
    func testMachineInfoProbeHoldsNeitherTheQueueNorTheReply() {
        let gate = DispatchSemaphore(value: 0), probing = expectation(description: "probe started"),
            probed = expectation(description: "probe returned")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        var o = ops(Fake())
        o.binary = {
            guard calls.withLock({ $0 += 1; return $0 }) == 1 else { return Self.v127 }   // cached once returned
            probing.fulfill(); _ = gate.wait(timeout: .now() + 5); probed.fulfill(); return Self.v127
        }
        let (conn, queue, frames) = connection(o)
        let start = Date()
        queue.async { conn.handle(type: DchFrame.machineInfo, payload: Data()) }
        wait(for: [probing], timeout: 5)
        let marker = DispatchSemaphore(value: 0)
        queue.async { marker.signal() }   // a marker behind the handshake
        let held = marker.wait(timeout: .now() + 2) == .timedOut   // a held queue waits for gate.signal()
        XCTAssertFalse(held, "the probe held the queue")
        let info = machineInfoResp(frames, timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "the reply waited on the probe")
        XCTAssertNotNil(info, "no reply while the probe hangs")
        XCTAssertFalse((info?["ops"] as? [String] ?? []).contains("revive_no_message"))
        gate.signal()
        if held { marker.wait() }
        wait(for: [probed], timeout: 5)
        let (conn2, queue2, frames2) = connection(o)
        queue2.async { conn2.handle(type: DchFrame.machineInfo, payload: Data()) }
        XCTAssertTrue((machineInfoResp(frames2)?["ops"] as? [String] ?? []).contains("revive_no_message"),
                      "the returned probe's bit on the next handshake")
        queue.sync {}
        XCTAssertEqual(frames.lock.withLock { frames.all }.count, 1, "one reply per handshake")
    }

    /// #704: through the real probe (a script that hangs, never dch): a `--version`
    /// that timed out is cached, so the very next handshake answers at once and runs
    /// nothing; a new mtime probes again, and its answer carries the bit.
    /// #793: only the hung probe gets a short bound (2 s, so its count line lands before the
    /// kill); the new mtime's probe gets 30 s, so a slow fresh exec under load never times
    /// out (and caches nil for 60 s), which failed the run-count asserts in QA #615.
    func testATimedOutProbeIsNotRerunOnTheNextHandshake() throws {
        let dir = tempDir(), script = dir.appendingPathComponent("dch").path, count = dir.appendingPathComponent("count").path
        let timeout = DchCommand.islandTimeout
        DchCommand.islandTimeout = 2
        defer { DchCommand.islandTimeout = timeout }
        func install(_ body: String, mtime: TimeInterval) throws {
            try "#!/bin/sh\necho \"$1\" >> '\(count)'\n\(body)\n".write(toFile: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: Date(timeIntervalSince1970: mtime)],
                                                  ofItemAtPath: script)
        }
        func runs() -> Int { ((try? String(contentsOfFile: count, encoding: .utf8)) ?? "").split(separator: "\n").count }
        try install("exec /bin/sleep 5", mtime: 1_000)
        /// The reply's ops, the seconds to the reply and to the probe's return.
        func handshake() -> (ops: [String], reply: TimeInterval, probe: TimeInterval) {
            let probed = expectation(description: "probe returned")
            var o = ops(Fake())
            o.binary = { defer { probed.fulfill() }; return DchCommand.newest([script], version: DchCommand.probedVersion) }
            let (conn, queue, frames) = connection(o)
            let start = Date()
            queue.async { conn.handle(type: DchFrame.machineInfo, payload: Data()) }
            let info = machineInfoResp(frames, timeout: 2)
            let reply = Date().timeIntervalSince(start)
            wait(for: [probed], timeout: DchCommand.islandTimeout + 5)
            return (info?["ops"] as? [String] ?? ["no reply"], reply, Date().timeIntervalSince(start))
        }
        let first = handshake()
        XCTAssertLessThan(first.reply, 0.5, "the reply waited on the hung probe")
        XCTAssertFalse(first.ops.contains("revive_no_message"))
        XCTAssertGreaterThanOrEqual(first.probe, 2, "the probe timed out")
        let ran = runs()   // 1, or 0 when a fresh script's first exec outlasts the timeout
        let next = handshake()
        XCTAssertLessThan(next.reply, 0.5)
        XCTAssertFalse(next.ops.contains("revive_no_message"))
        XCTAssertLessThan(next.probe, 1, "the timed-out probe ran again")   // a rerun takes the 2 s bound
        XCTAssertEqual(runs(), ran, "the timed-out probe ran again")
        DchCommand.islandTimeout = 30   // the hung phase is over; this probe must answer, however slow
        try install("echo 'dch 1.27.0'", mtime: 2_000)
        _ = handshake()   // a new mtime probes again (waits for its answer); its bit may miss this reply's 0.25 s
        XCTAssertEqual(runs(), ran + 1, "a new mtime probes again")
        // The answer is cached now; a reply may still miss 0.25 s on a starved pool, so up to 3 handshakes.
        XCTAssertTrue((1...3).contains { _ in handshake().ops.contains("revive_no_message") }, "the new mtime's answer")
        XCTAssertEqual(runs(), ran + 1, "the cached answer ran nothing")
    }

    /// #704: a timed-out probe stays cached only for probeTimeoutTTL; past it, the next call runs it again.
    func testATimedOutProbeIsRerunOnceItsTTLHasPassed() throws {
        let script = tempDir().appendingPathComponent("dch").path
        let (timeout, ttl) = (DchCommand.islandTimeout, DchCommand.probeTimeoutTTL)
        DchCommand.islandTimeout = 0.3
        DchCommand.probeTimeoutTTL = 0
        defer { (DchCommand.islandTimeout, DchCommand.probeTimeoutTTL) = (timeout, ttl) }
        try "#!/bin/sh\nexec /bin/sleep 5\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        for call in 1...2 {
            let start = Date()
            XCTAssertNil(DchCommand.probedVersion(script))
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.3, "call \(call) ran no probe")
        }
        XCTAssertEqual(ttl, 60, "the shipped TTL")
    }

    /// #671: a connection that closed while its probe ran sends nothing.
    func testMachineInfoSendsNothingAfterClose() {
        let gate = DispatchSemaphore(value: 0), probing = expectation(description: "probe started"),
            probed = expectation(description: "probe returned")
        var o = ops(Fake())
        o.binary = { probing.fulfill(); gate.wait(); defer { probed.fulfill() }; return Self.v127 }
        let (conn, queue, frames) = connection(o)
        queue.async { conn.handle(type: DchFrame.machineInfo, payload: Data()) }
        wait(for: [probing], timeout: 5)
        queue.async { conn.close() }   // async: queued ahead of the reply hop, never waiting on the probe
        gate.signal()
        wait(for: [probed], timeout: 5)
        XCTAssertNil(machineInfoResp(frames, timeout: 0.3))
        XCTAssertTrue(frames.lock.withLock { frames.all }.isEmpty)
    }

    // MARK: - #719: dch 1.28.2 / 1.28.3

    private static let v1282 = DchCommand.Binary(path: "/fake/dch", version: [1, 28, 2])
    private static let v1283 = DchCommand.Binary(path: "/fake/dch", version: [1, 28, 3])

    /// A crashed record --all would take by the Mac's clock (an hour long, a minute ago and older).
    private static func taker(_ name: String, sid: String, ago: TimeInterval, end: String = "signal 9") -> [String: Any] {
        ["name": name, "file": name, "started": now - 7200, "updated": now - ago, "ended": now - ago, "end": end,
         "agent": ["kind": "claude", "session_id": sid]]
    }

    /// QA #533 F1: from 1.28.2 "takes" is dch's --revive --all, which holds Claude ids: a
    /// live session's (here "L"), each taken one ("X": the older record of X is a dup),
    /// and from 1.28.3 a newer record's that ended on purpose ("S" stopped: its older
    /// crash stays down). Below 1.28.2 every crash takes, ids or not.
    func testHistoryTakesSkipHeldClaudeIdsFrom1282() {
        let f = Fake()
        f.hist["/d"] = Self.hist([Self.taker("new", sid: "X", ago: 60), Self.taker("held", sid: "L", ago: 70),
                                  Self.taker("stop", sid: "S", ago: 80, end: "stopped"), Self.taker("old", sid: "X", ago: 90),
                                  Self.taker("crash", sid: "S", ago: 100), Self.taker("free", sid: "", ago: 110)])
        func takes(_ dch: DchCommand.Binary, _ master: String, line: UInt = #line) -> [String: Bool] {
            f.ls["/d"] = Self.ls([("b", master)])
            var o = ops(f, binary: dch)
            o.liveRecords = { s in
                XCTAssertEqual(s.map(\.name), ["b"], line: line)
                var r = DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "b"))
                r.agent = .init(kind: "claude", sessionID: "L")
                return [r]
            }
            let rows = call(o, DchFrame.history, raw: Data()).json as? [[String: Any]] ?? []
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["name"] as? String ?? "", $0["takes"] as? Bool ?? false) })
        }
        XCTAssertEqual(takes(Self.v1283, "1.28.3"),
                       ["new": true, "held": false, "stop": false, "old": false, "crash": false, "free": true])
        XCTAssertEqual(takes(Self.v1282, "1.28.2"),
                       ["new": true, "held": false, "stop": false, "old": false, "crash": true, "free": true], "1.28.2 holds no ended id")
        XCTAssertEqual(takes(Self.v1281, "1.28.1"),
                       ["new": true, "held": true, "stop": false, "old": true, "crash": true, "free": true], "below 1.28.2: unchanged")
        XCTAssertEqual(takes(Self.v1283, "1.29.0"),
                       ["new": true, "held": true, "stop": false, "old": true, "crash": true, "free": true],
                       "a newer master: the island's gate refuses, the old count")
        XCTAssertEqual(takes(Self.v1283, "1.28.1"), takes(Self.v1283, "1.28.3"),
                       "QA #535 M2: an older master leaves the gate open; --revive runs in the control dch")
    }

    /// QA #535 M-1: with Remote Terminal isolation the phone lists only the isolated dir,
    /// but dch holds a Claude from any dir: the seed lists the other socket dir's
    /// sessions too (a by-hand `claude --resume M` at the Mac), from 1.28.2 only.
    func testHistoryTakesHoldAClaudeInTheOtherSocketDirFrom1282() {
        let f = Fake()
        f.hist["/iso"] = Self.hist([Self.taker("phone", sid: "M", ago: 60)])
        f.ls["/iso"] = Self.ls([("p", "1.28.3")])
        f.ls["/mac"] = Self.ls([("m", "1.28.3")])
        func takes(_ dch: DchCommand.Binary) -> (Bool, [String]) {
            var o = ops(f, dirs: ["/iso"], binary: dch)
            o.seedDirs = { ["/mac", "/iso"] }
            o.liveRecords = { s in
                s.map { var r = DchHistoryRecord(key: $0.key); r.agent = .init(kind: "claude", sessionID: $0.name.uppercased()); return r }
            }
            f.lock.withLock { f.reads = [] }
            let rows = call(o, DchFrame.history, raw: Data()).json as? [[String: Any]] ?? []
            return (rows.first?["takes"] as? Bool ?? true, f.lock.withLock { f.reads.filter { $0.arg == "--ls-json" }.map(\.dir) })
        }
        XCTAssertEqual(takes(Self.v1283).0, false, "M runs in /mac")
        XCTAssertEqual(takes(Self.v1283).1, ["/iso", "/mac"], "the other dir once; the listed one is not listed again")
        XCTAssertEqual(takes(Self.v1281).0, true)
        XCTAssertEqual(takes(Self.v1281).1, [], "below 1.28.2 no listing")
    }

    private static let v1281 = DchCommand.Binary(path: "/fake/dch", version: [1, 28, 1])

    /// From 1.28.2 the phone's Resume passes `<file>.json`; dch's failure lines, named
    /// after that argument, read in words (live_sid, ambiguous), and the by-hand hint
    /// carries the record's config_dir. Below it, #716's argument.
    func testReviveByNamePassesTheRecordFileFrom1282() {
        let f = Fake()
        var a = Self.taker("a", sid: "S", ago: 60)
        a["agent"] = ["kind": "claude", "session_id": "S", "config_dir": "/Users/me/.claude work"]
        f.hist["/d"] = Self.hist([a, Self.taker("b", sid: "T", ago: 70).merging(["file": "b.1762000000"]) { $1 }])
        f.out["--revive a.json --json"] = Self.ok("a")
        f.out["--revive b.1762000000.json --json"] = Self.ok("b")
        let o = ops(f, binary: Self.v1282)
        XCTAssertEqual(names(call(o, DchFrame.revive, ["name": "a"])), ["a"])
        XCTAssertEqual(names(call(o, DchFrame.revive, ["name": "b"])), ["b"])
        f.out["--revive b.1762000000 --json"] = Self.ok("b")
        XCTAssertEqual(names(call(ops(f, binary: Self.v1281), DchFrame.revive, ["name": "b"])), ["b"])
        XCTAssertEqual(f.launchedArgs, [["--revive", "a.json", "--json"], ["--revive", "b.1762000000.json", "--json"],
                                        ["--revive", "b.1762000000", "--json"]])
        f.status = 1
        f.out["--revive a.json --json"] = Self.json(["name": "a", "as": "a", "result": "failed", "reason": "live_sid",
                                                     "detail": "claude S already runs in live session c", "session_id": "S"])
        XCTAssertEqual(message(call(o, DchFrame.revive, ["name": "a"])), "a: Not resumed: claude S already runs in live session c")
        f.out["--revive a.json --json"] = Self.json(["name": "a.json", "as": "a.json", "result": "failed", "reason": "ambiguous",
                                                     "detail": "ambiguous: a.json matches more than one session's records", "session_id": ""])
        XCTAssertEqual(message(call(o, DchFrame.revive, ["name": "a"])), "a: Not resumed: \(AgentIsland.ambiguousText)")
        f.out["--revive a.json --json"] = Self.json(["name": "a", "as": "a", "result": "failed", "reason": "relaunch_failed",
                                                     "detail": "revived as a in /src, but claude could not be started; resume by hand: claude --resume S",
                                                     "session_id": "S"])
        XCTAssertEqual(message(call(o, DchFrame.revive, ["name": "a"])),
                       "a: revived as a in /src, but claude could not be started; resume by hand: "
                       + "CLAUDE_CONFIG_DIR='/Users/me/.claude work' claude --resume S")
    }

    /// dch 1.28.2's unpin of a record that is gone fails not_found (exit 1): the phone
    /// hears ok, as nothing is pinned. A pin's not_found still fails.
    func testUnpinOfAGoneRecordIsOkFrom1282() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "file": "a", "updated": Self.now - 60, "end": "exit 0", "pinned": true]])
        f.out["--unpin a.json --json"] = Self.line("a.json", "failed", reason: "not_found", detail: "no history for this session")
        f.out["--pin a.json --json"] = Self.line("a.json", "failed", reason: "not_found", detail: "no history for this session")
        f.status = 1
        let o = ops(f, binary: Self.v1282)
        XCTAssertEqual(names(call(o, DchFrame.pin, ["name": "a", "pin": false])), ["a"])
        XCTAssertEqual(message(call(o, DchFrame.pin, ["name": "a", "pin": true])), "a: no history for this session")
    }

    // MARK: - #746: a folded name (QA #570 F1)

    private static let aside = "work.\(Int(now) - 30)"

    /// A by-hand `dch work` left work's own record and the aside one: one phone row (#743).
    private static func folded(newestPinned: Bool = false, asidePinned: Bool = false) -> String {
        hist([["name": "work", "file": "work", "updated": now - 10, "ended": now - 10, "end": "stopped", "pinned": newestPinned],
              ["name": "other", "file": "other", "updated": now - 20, "end": "killed"],
              ["name": "work", "file": aside, "updated": now - 30, "ended": now - 30, "end": "signal 9", "pinned": asidePinned]])
    }

    /// Resume takes the newest record of the name, as the Mac row: its file from 1.28.2,
    /// the bare name below (dch's newest ended record of it).
    func testFoldedNameIsRevivedByItsNewestRecord() {
        let f = Fake()
        f.hist["/d"] = Self.folded()
        f.out["--revive work.json --json"] = Self.ok("work")
        f.out["--revive work --json"] = Self.ok("work")
        XCTAssertEqual(names(call(ops(f, binary: Self.v1282), DchFrame.revive, ["name": "work"])), ["work"])
        XCTAssertEqual(names(call(ops(f, binary: Self.v125), DchFrame.revive, ["name": "work"])), ["work"])
        XCTAssertEqual(f.launchedArgs, [["--revive", "work.json", "--json"], ["--revive", "work", "--json"]])
    }

    /// Pin and unpin pass every record the row folds in one call (1.28.1: each file; below
    /// it the bare name, which matches them all); dch names each line after its argument.
    func testFoldedNameIsPinnedAndUnpinnedWhole() {
        let f = Fake(), files = ["work.json", "\(Self.aside).json"]
        f.hist["/d"] = Self.folded()
        for (verb, word) in [("--pin", "pinned"), ("--unpin", "unpinned")] {
            f.out[([verb] + files + ["--json"]).joined(separator: " ")] = files.map { Self.line($0, "ok", detail: word) }.joined(separator: "\n")
        }
        f.out["--pin work --json"] = Self.line("work", "ok", detail: "pinned")
        let o = ops(f, binary: Self.v1281)
        XCTAssertEqual(names(call(o, DchFrame.pin, ["name": "work", "pin": true])), ["work"])
        XCTAssertEqual(names(call(o, DchFrame.pin, ["name": "work", "pin": false])), ["work"])
        XCTAssertEqual(names(call(ops(f, binary: Self.v125), DchFrame.pin, ["name": "work", "pin": true])), ["work"])
        XCTAssertEqual(f.launchedArgs, [AgentIsland.pinArgs(files, pin: true)!, AgentIsland.pinArgs(files, pin: false)!,
                                        AgentIsland.pinArgs(["work"], pin: true)!])
    }

    /// One call, several results: a failed one is the answer even when an ok one follows
    /// (never a partial run read as done); an unpin's not_found is the record gone, ok.
    func testAFoldedEditThatFailedForOneRecordIsAnError() {
        let f = Fake(), files = ["work.json", "\(Self.aside).json"]
        f.hist["/d"] = Self.folded(newestPinned: true, asidePinned: true)
        f.status = 1
        f.out["--pin work.json \(files[1]) --json"] = [Self.line(files[0], "failed", reason: "io_error", detail: "Permission denied"),
                                                       Self.line(files[1], "ok", detail: "pinned")].joined(separator: "\n")
        f.out["--unpin work.json \(files[1]) --json"] = [Self.line(files[0], "ok", detail: "unpinned"),
                                                         Self.line(files[1], "failed", reason: "not_found",
                                                                   detail: "no history for this session")].joined(separator: "\n")
        let o = ops(f, binary: Self.v1281)
        XCTAssertEqual(message(call(o, DchFrame.pin, ["name": "work", "pin": true])), "work: Permission denied")
        XCTAssertEqual(names(call(o, DchFrame.pin, ["name": "work", "pin": false])), ["work"])
        f.out["--unpin work.json \(files[1]) --json"] = [Self.line(files[0], "failed", reason: "not_found",
                                                                   detail: "no history for this session"),
                                                         Self.line(files[1], "failed", reason: "io_error", detail: "EACCES")].joined(separator: "\n")
        XCTAssertEqual(message(call(o, DchFrame.pin, ["name": "work", "pin": false])), "work: EACCES",
                       "the older record's failure, past a gone one")
        f.hist["/d"] = Self.folded()
        f.out["--forget work.json \(files[1]) --json"] = [Self.line("work", "failed", reason: "io_error", detail: "EIO"),
                                                          Self.line("work", "ok", detail: "forgotten")].joined(separator: "\n")
        XCTAssertEqual(message(call(o, DchFrame.forget, ["name": "work"])), "work: EIO")
    }

    /// Remove forgets the row's unpinned records (dch names each line after the record's
    /// name); a pinned older one stays, as the Mac row's X. Below 1.28.1 the bare name.
    func testFoldedNameIsForgottenWhole() {
        let f = Fake()
        f.hist["/d"] = Self.folded()
        f.out["--forget work.json \(Self.aside).json --json"] = [Self.line("work", "ok", detail: "forgotten"),
                                                                 Self.line("work", "ok", detail: "forgotten")].joined(separator: "\n")
        f.out["--forget work.json --json"] = Self.line("work", "ok", detail: "forgotten")
        f.out["--forget work --json"] = Self.line("work", "ok", detail: "forgotten")
        let o = ops(f, binary: Self.v1281)
        XCTAssertEqual(names(call(o, DchFrame.forget, ["name": "work"])), ["work"])
        XCTAssertEqual(names(call(ops(f, binary: Self.v125), DchFrame.forget, ["name": "work"])), ["work"])
        f.hist["/d"] = Self.folded(asidePinned: true)
        XCTAssertEqual(names(call(o, DchFrame.forget, ["name": "work"])), ["work"])
        XCTAssertEqual(f.launchedArgs, [AgentIsland.forgetArgs(["work.json", "\(Self.aside).json"])!, AgentIsland.forgetArgs(["work"])!,
                                        AgentIsland.forgetArgs(["work.json"])!])
    }

    /// Remove of a row whose newest record is pinned is refused before dch, as before.
    func testFoldedNameWithAPinnedNewestRecordIsNotForgotten() {
        let f = Fake()
        f.hist["/d"] = Self.folded(newestPinned: true)
        XCTAssertEqual(message(call(ops(f, binary: Self.v1281), DchFrame.forget, ["name": "work"])), "work: pinned, unpin it first")
        XCTAssertTrue(f.launches.isEmpty)
    }

    /// The name in two socket dirs is two sessions: Resume, Pin and Remove refuse, run nothing.
    func testANameInTwoSocketDirsIsRefused() {
        let f = Fake()
        f.hist["/d"] = Self.folded()
        f.hist["/e"] = Self.hist([["name": "work", "file": "work", "updated": Self.now - 40, "end": "exit 0"]])
        let o = ops(f, dirs: ["/d", "/e"], binary: Self.v1282), why = "work: history records of that name in 2 socket dirs; use the Mac's Agent Island"
        XCTAssertEqual(message(call(o, DchFrame.revive, ["name": "work"])), why)
        XCTAssertEqual(message(call(o, DchFrame.pin, ["name": "work", "pin": true])), why)
        XCTAssertEqual(message(call(o, DchFrame.forget, ["name": "work"])), why)
        XCTAssertTrue(f.launches.isEmpty)
    }

    /// QA #573 INFO-1: below 1.28.1 a forget by the bare name removes the unpinned records
    /// and answers "pinned" for each pinned one (exit 1): ok with a note. A "pinned" with
    /// nothing gone, or any other failure beside it, is still the answer.
    func testABareNameForgetThatKeptAPinnedOlderRecordIsOk() {
        let f = Fake()
        f.hist["/d"] = Self.folded(asidePinned: true)
        f.status = 1
        let o = ops(f, binary: Self.v125), pinned = Self.line("work", "failed", reason: "pinned", detail: "pinned (-f forgets it anyway)")
        f.out["--forget work --json"] = [Self.line("work", "ok", detail: "forgotten"), pinned].joined(separator: "\n")
        let r = call(o, DchFrame.forget, ["name": "work"])
        XCTAssertEqual(names(r), ["work"])
        XCTAssertEqual((r.json as? [String: Any])?["message"] as? String, "work: removed the unpinned runs, kept the pinned ones")
        f.out["--forget work --json"] = pinned
        XCTAssertEqual(message(call(o, DchFrame.forget, ["name": "work"])), "work: pinned, unpin it first", "nothing went")
        f.out["--forget work --json"] = [Self.line("work", "ok", detail: "forgotten"), pinned,
                                         Self.line("work", "failed", reason: "io_error", detail: "EIO")].joined(separator: "\n")
        XCTAssertEqual(message(call(o, DchFrame.forget, ["name": "work"])), "work: EIO")
        XCTAssertEqual(f.launchedArgs, Array(repeating: AgentIsland.forgetArgs(["work"])!, count: 3))
    }

    /// QA #573 INFO-4: a forget's not_found is a failure even when an ok line follows
    /// (only an unpin's means the record went).
    func testAFoldedForgetsNotFoundIsAnError() {
        let f = Fake(), files = ["work.json", "\(Self.aside).json"]
        f.hist["/d"] = Self.folded()
        f.status = 1
        f.out["--forget \(files.joined(separator: " ")) --json"] = [Self.line(files[1], "failed", reason: "not_found", detail: "no history for this session"),
                                                                    Self.line("work", "ok", detail: "forgotten")].joined(separator: "\n")
        XCTAssertEqual(message(call(ops(f, binary: Self.v1281), DchFrame.forget, ["name": "work"])), "work: no history for this session")
    }

    /// QA #573 INFO-4: a failed line of another name (not one of the row's targets) is not
    /// the row's answer.
    func testAFoldedEditIgnoresAnotherNamesFailedLine() {
        let f = Fake(), files = ["work.json", "\(Self.aside).json"]
        f.hist["/d"] = Self.folded()
        f.status = 1
        f.out["--pin \(files.joined(separator: " ")) --json"] = [Self.line("other", "failed", reason: "io_error", detail: "EIO"),
                                                                 Self.line(files[0], "ok", detail: "pinned"),
                                                                 Self.line(files[1], "ok", detail: "pinned")].joined(separator: "\n")
        XCTAssertEqual(names(call(ops(f, binary: Self.v1281), DchFrame.pin, ["name": "work", "pin": true])), ["work"])
    }
}
