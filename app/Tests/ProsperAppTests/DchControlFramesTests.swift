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
        var launches: [(path: String, args: [String], dir: String?)] = []
        var historyPaths: [String?] = []
        var refreshes = 0

        var launchedArgs: [[String]] { lock.withLock { launches.map(\.args) } }
    }

    private func ops(_ f: Fake, dirs: [String] = ["/d"], binary: DchCommand.Binary? = v1241) -> DchControlOps {
        var o = DchControlOps()
        o.dirs = { dirs }
        o.binary = { binary }
        o.read = { args, env, path in
            f.lock.withLock {
                let dir = env["DCH_SOCKET_DIR"] ?? ""
                switch args.first {
                case "--ls-json": return Data((f.ls[dir] ?? "[]").utf8)
                case "--history":
                    f.historyPaths.append(path)
                    return Data((f.hist[dir] ?? "[]").utf8)
                default: return Data()
                }
            }
        }
        o.env = { ["DCH_SOCKET_DIR": $0] }
        o.runner = DchActionRunner(launch: { path, args, env, _, onPid, _ in
            onPid(4242)
            return f.lock.withLock {
                f.launches.append((path, args, env["DCH_SOCKET_DIR"]))
                return (f.status, Data((f.out[args.joined(separator: " ")] ?? "").utf8))
            }
        }, signal: { _ in })
        o.now = { Self.now }
        o.refresh = { f.lock.withLock { f.refreshes += 1 } }
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
        XCTAssertTrue(message(call(ops(f, dirs: ["/d", "/e"]), DchFrame.revive, ["name": "a"])).contains("more than one"))
        XCTAssertTrue(f.launches.isEmpty)
    }

    func testAFailedReviveRepliesDchsWords() {
        let f = Fake()
        f.hist["/d"] = Self.hist([["name": "a", "updated": Self.now - 60, "end": "signal 9"]])
        f.out["--revive a --json"] = Self.json(["name": "a", "result": "failed", "reason": "no_record", "detail": "a: no record"])
        XCTAssertEqual(message(call(ops(f), DchFrame.revive, ["name": "a"])), "no record")
        f.out["--revive a --json"] = "dch: cannot reach the socket dir"
        f.status = 1
        XCTAssertEqual(message(call(ops(f), DchFrame.revive, ["name": "a"])), "Resume failed: dch: cannot reach the socket dir")
    }

    // MARK: - restart 0x0d

    func testRestartNamesRunsRestartArgsPerName() {
        let f = Fake()
        f.ls["/d"] = Self.ls([("a", "1.24.1"), ("b", "1.24.1"), ("c", "1.24.1")])
        f.out[AgentIsland.restartArgs("a").joined(separator: " ")] = Self.ok("a", phase: "master") + "\n" + Self.ok("a")
        f.out[AgentIsland.restartArgs("b").joined(separator: " ")] = Self.ok("b")
        let r = call(ops(f), DchFrame.restart, ["names": ["a", "b", "a"]])
        XCTAssertEqual(Set(f.launchedArgs), [AgentIsland.restartArgs("a"), AgentIsland.restartArgs("b")], "deduplicated")
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
        XCTAssertTrue(message(call(ops(f, dirs: ["/d", "/e"]), DchFrame.restart, ["names": ["a"]])).contains("more than one"))
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
        f.out[AgentIsland.stopArgs(["a", "b"]).joined(separator: " ")] = Self.ok("a") + "\n" + Self.ok("b")
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
        XCTAssertEqual(info["ops"] as? [String], ["history", "revive", "restart", "stop"])
        XCTAssertEqual(info["device_id"] as? String, "id")
        XCTAssertEqual(info["hostname"] as? String, "mac")
        XCTAssertNil(info["wakeId"])
        XCTAssertEqual(DchFrame.machineInfo(deviceID: "id", hostname: "mac", wakeId: "w")["wakeId"] as? String, "w")
    }

    func testFrameBytesAreThePhonesContract() {
        XCTAssertEqual([DchFrame.history, DchFrame.revive, DchFrame.restart, DchFrame.stop, DchFrame.historyResp],
                       [0x0b, 0x0c, 0x0d, 0x0e, 0x1b])
        XCTAssertEqual([DchFrame.ok, DchFrame.error, DchFrame.machineInfoResp], [0x14, 0x13, 0x18])
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

    /// Unstubbed under XCTest: no control binary, so every verb is refused before any dch fork.
    func testUnstubbedOpsRefuseUnderXCTest() {
        let o = DchControlOps()
        for (t, p) in [(DchFrame.history, Data()), (DchFrame.revive, Data("{\"all\":true}".utf8)),
                       (DchFrame.restart, Data("{\"all\":true}".utf8)), (DchFrame.stop, Data("{\"names\":[\"a\"]}".utf8))] {
            XCTAssertTrue(message(call(o, t, raw: p)).contains("needs dch"))
        }
    }
}
