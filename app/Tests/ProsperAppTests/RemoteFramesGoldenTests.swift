import Darwin
import Foundation
import Network
import os.log
import XCTest
@testable import ProsperApp

/// #776: docs/protocol/golden's fixtures against a real DchSessionServer on 127.0.0.1, on a
/// kernel-picked port, so Prosper's CI holds the server to the spec any server must pass.
/// Fakes only: the list, kill and rename are recorders, the watch hub is fed by hand, and
/// attach runs a shell script that prints a repaint and echoes, never dch (#800: a create that
/// names a command runs that command instead, as dch would). Never 8771,
/// never the Tailscale address, and `onReady` is a no-op so no real dch client is swept.
final class RemoteFramesGoldenTests: XCTestCase {

    private static let golden = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/protocol/golden")

    private static let rows = [
        DchListRow(name: "alpha", alias: "Alpha", activityEpoch: 1, state: "working", agents: 2),
        DchListRow(name: "beta", alias: "", activityEpoch: 2, state: "", agents: 0),
    ]

    private var server: DchSessionServer!
    private var port: UInt16 = 0
    private let ran = Recorder()

    override func setUpWithError() throws {
        let script = tempDir("golden-dch").appendingPathComponent("fake-dch")
        // dch's spawn args are -E [-f] [-n name] [command...] (DchCommand.spawnArgs).
        try ("#!/bin/sh\nwhile [ $# -gt 0 ]; do case $1 in -E|-f) shift;; -n) shift 2;; *) break;; esac; done\n"
            + "[ $# -gt 0 ] && exec \"$@\"\nprintf '\\033[2J\\033[Hgolden repaint\\r\\n'\nexec /bin/cat\n")
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        DchCommand.dchPathOverride = script.path
        let ran = ran, rows = Self.rows
        server = DchSessionServer(bindHost: { "127.0.0.1" }, port: 0, retryBase: 60, onReady: {},
                                  allowPeer: { _ in true },
                                  configure: { c in
                                      c.listSessions = { rows }
                                      c.kill = { ran.add(["-k", $0]) }
                                      c.rename = { ran.add(["-m", $0, $1]) }
                                      c.clipboard.enabled = { false }
                                      c.commands.enabled = { false }
                                  })
        let s = server!
        s.queue.sync {
            s.watch.remoteDir = { "/golden" }
            s.watch.sidekick = { DchSidekickOps.Value(pattern: "", updated: 0) }
            s.watch.island(DchWatchHub.Cache(dir: "/golden", rows: rows))
        }
        try s.start()
        port = try XCTUnwrap(s.boundPort)
        XCTAssertNotEqual(port, 0)
        XCTAssertNotEqual(port, DchSessionServer.port, "never the live server's port")
    }

    override func tearDown() {
        server?.stop()
        _ = server?.isRunning
        server?.queue.sync {}   // closes every connection, which SIGHUPs the fake dch
        DchCommand.dchPathOverride = nil
        server = nil
        super.tearDown()
    }

    // MARK: - Golden fixtures

    func testEveryGoldenFixturePassesAgainstTheServer() throws {
        let files = try FileManager.default.contentsOfDirectory(at: try goldenDir(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(files.count, 16, "the fixtures are read from \(Self.golden.path)")
        let ops = try handshakeOps()
        XCTAssertTrue(ops.contains("watch"), "the hub has a list, so every requires_op fixture runs")
        for file in files {
            let fx = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let id = fx["id"] as? String ?? file.lastPathComponent
            if let op = fx["requires_op"] as? String { XCTAssertTrue(ops.contains(op), "\(id) would be skipped") }
            do { try run(fx) } catch { XCTFail("\(id): \(error)") }
            for hex in fx["cleanup"] as? [String] ?? [] {
                let c = try Client(port: port)
                try c.send(Self.unhex(hex))
                _ = try c.frame()
            }
        }
        let calls = ran.all
        XCTAssertTrue(calls.contains(["-k", "golden-776-no-such-session"]), "\(calls)")
        XCTAssertTrue(calls.contains(["-m", "golden-776-no-such-session", ""]), "\(calls)")
        XCTAssertTrue(calls.contains(["-k", "golden-776"]), "the attach fixture's cleanup: \(calls)")
        // QA #625 INFO-R3-6: 14 and 15 own their session names, so a dying master of one fixture's
        // session cannot reach the next fixture.
        XCTAssertTrue(calls.contains(["-k", "golden-776-14"]), "14's cleanup: \(calls)")
        XCTAssertTrue(calls.contains(["-k", "golden-776-15"]), "15's cleanup: \(calls)")
        XCTAssertTrue(calls.contains(["-k", "golden-776-16"]), "16's cleanup: \(calls)")
        XCTAssertFalse(calls.contains { $0.contains("-golden-776") }, "13: a dash name never reaches dch: \(calls)")
    }

    /// The runner dch CI uses, against the same server: it must read the fixtures as this test does.
    func testPythonRunnerPassesAgainstTheServer() throws {
        let (status, text) = try python([try goldenDir().appendingPathComponent("run.py").path, "127.0.0.1:\(port)", "--mutating"])
        XCTAssertEqual(status, 0, text)
        XCTAssertTrue(text.contains("server=prosper proto=1.0"), text)
        XCTAssertFalse(text.contains("SKIP"), text)
        XCTAssertFalse(text.contains("FAIL"), text)
        XCTAssertTrue(text.contains("OK (0 failed)"), text)
    }

    /// QA #625 INFO-6: without --mutating, run.py runs nothing that reaches dch on the server:
    /// 07 (kill), 08 (rename), 12, 14 and 15 (attach), 16 (create) are skipped, the read-only rest passes.
    func testPythonRunnerSkipsMutatingFixturesByDefault() throws {
        let (status, text) = try python([try goldenDir().appendingPathComponent("run.py").path, "127.0.0.1:\(port)"])
        XCTAssertEqual(status, 0, text)
        for id in ["07-kill-unknown-name", "08-rename-unknown-name", "12-attach-redraws", "14-attach-twice-ignored",
                   "15-session-exit-closes", "16-create-exit-closes"] {
            XCTAssertTrue(text.contains("SKIP \(id): mutating"), text)
        }
        XCTAssertTrue(text.contains("PASS 13-kill-dash-refused"), text)
        XCTAssertFalse(text.contains("FAIL"), text)
        XCTAssertEqual(ran.all, [], "no kill or rename reached the server's dch")
    }

    /// QA #625 INFO-R2: fixture 12's expect_quiet catches a server that answers resize (an empty
    /// 0x14, the likeliest wrong reply): both runners fail it against a loopback fake that does,
    /// and pass it against the same fake when resize gets no reply.
    func testBothRunnersFailFixture12WhenResizeIsAnswered() throws {
        let fx = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: try goldenDir().appendingPathComponent("12-attach-redraws.json"))) as? [String: Any])
        let code = """
            import json, sys
            sys.path.insert(0, sys.argv[1])
            import run
            try:
                run.run(json.loads(sys.argv[2]), ("127.0.0.1", int(sys.argv[3])), 5)
                print("PASS")
            except run.Fail as e:
                print("FAIL", e)
            """
        let fxJSON = String(decoding: try JSONSerialization.data(withJSONObject: fx), as: UTF8.self)
        for answered in [false, true] {
            let fake = try FakeServer(resizeReply: answered ? DchFrame.encode(DchFrame.ok, []) : nil)
            defer { fake.stop() }
            var swift = "PASS"
            do { try run(fx, port: fake.port) } catch { swift = "FAIL \(error)" }
            let (status, out) = try python(["-B", "-c", code, try goldenDir().path, fxJSON, "\(fake.port)"])
            XCTAssertEqual(status, 0, out)
            if answered {
                XCTAssertEqual(swift, "FAIL want no reply, got 14", "the Swift runner")
                XCTAssertTrue(out.hasPrefix("FAIL want no reply, got 0x14"), "run.py: \(out)")
            } else {
                XCTAssertEqual(swift, "PASS", "the Swift runner, resize unanswered")
                XCTAssertEqual(out, "PASS\n", "run.py, resize unanswered")
            }
        }
    }

    /// QA #625 INFO-R3-4: a session that keeps drawing and never exits fails fixture 15's
    /// expect_close in both runners within the step's deadline (1 s here), not one recv timeout
    /// after the last byte, i.e. never. Hard bounds: run.py is SIGKILLed after 15 s, and the Swift
    /// runner runs off this thread and is given 15 s before the fake is stopped under it.
    func testBothRunnersFailExpectCloseWhenTheSessionKeepsDrawing() throws {
        let fx = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: try goldenDir().appendingPathComponent("15-session-exit-closes.json"))) as? [String: Any])
        let fake = try FakeServer(redrawForever: true)
        defer { fake.stop() }

        let result = OSAllocatedUnfairLock(initialState: "")
        let done = DispatchSemaphore(value: 0)
        let started = Date(), port = fake.port
        Thread.detachNewThread { [self] in
            let r: String
            do { try run(fx, port: port, timeout: 1); r = "PASS" } catch { r = "FAIL \(error)" }
            result.withLock { $0 = r }
            done.signal()
        }
        if done.wait(timeout: .now() + 15) == .timedOut {
            XCTFail("the Swift runner hung on a session that keeps drawing")
            fake.stop()   // ends the stream and closes the socket, so the thread can finish
            _ = done.wait(timeout: .now() + 10)
        }
        let swiftSecs = Date().timeIntervalSince(started)
        XCTAssertEqual(result.withLock { $0 }, "FAIL the server did not close the connection", "the Swift runner")
        XCTAssertLessThan(swiftSecs, 4, "one 1 s deadline for the step, not per read")

        let code = """
            import json, sys
            sys.path.insert(0, sys.argv[1])
            import run
            try:
                run.run(json.loads(sys.argv[2]), ("127.0.0.1", int(sys.argv[3])), 1)
                print("PASS")
            except run.Fail as e:
                print("FAIL", e)
            """
        let fxJSON = String(decoding: try JSONSerialization.data(withJSONObject: fx), as: UTF8.self)
        let pyFake = try FakeServer(redrawForever: true)   // its own, whatever the Swift half did to `fake`
        defer { pyFake.stop() }
        let pyStart = Date()
        let (status, out) = try python(["-B", "-c", code, try goldenDir().path, fxJSON, "\(pyFake.port)"], kill: 15)
        let pySecs = Date().timeIntervalSince(pyStart)
        XCTAssertEqual(status, 0, "run.py was killed (it hung): \(out)")
        XCTAssertEqual(out, "FAIL the server did not close the connection\n", "run.py")
        XCTAssertLessThan(pySecs, 5, "one 1 s deadline for the step, not per read")
    }

    /// QA #627 INFO-4: both runners arm the deadline per step, not once per connection. A fake
    /// answers the 0x08 with two 0x14s, each 0.9 s after the last (0.6 of the 1.5 s step timeout):
    /// every expect step gets its frame in time, while one deadline from the connect expires
    /// before the second (1.8 s > 1.5 s). Mutants: run.py without run()'s c.arm(), the Swift
    /// runner with `end` hoisted out of the step loop; each fails here.
    func testBothRunnersArmTheDeadlinePerStep() throws {
        let fx: [String: Any] = ["id": "per-step", "steps": [["send": "08 00000000"],
                                                             ["expect": ["type": "14"]], ["expect": ["type": "14"]]]]
        let fake = try FakeServer(pacedReplies: 0.9)
        defer { fake.stop() }
        var swift = "PASS"
        do { try run(fx, port: fake.port, timeout: 1.5) } catch { swift = "FAIL \(error)" }
        XCTAssertEqual(swift, "PASS", "the Swift runner")

        let code = """
            import json, sys
            sys.path.insert(0, sys.argv[1])
            import run
            try:
                run.run(json.loads(sys.argv[2]), ("127.0.0.1", int(sys.argv[3])), 1.5)
                print("PASS")
            except run.Fail as e:
                print("FAIL", e)
            """
        let fxJSON = String(decoding: try JSONSerialization.data(withJSONObject: fx), as: UTF8.self)
        let pyFake = try FakeServer(pacedReplies: 0.9)
        defer { pyFake.stop() }
        let (status, out) = try python(["-B", "-c", code, try goldenDir().path, fxJSON, "\(pyFake.port)"], kill: 15)
        XCTAssertEqual(status, 0, out)
        XCTAssertEqual(out, "PASS\n", "run.py")
    }

    /// QA #625 INFO-7: the Swift checker and run.py's shape_ok agree, a trailing newline included
    /// (both reject it: ICU's `$` alone would accept "idle\n").
    func testSwiftAndPythonShapeChecksAgree() throws {
        let json = #"[["string~idle","idle"],["string~idle","idle\n"],["string~idle","idler"],["string~.+",""],"#
            + #"["int",1],["int",1.5],["int",true],["number",1.5],["bool",true],["bool",0],"#
            + #"[{"name":"string"},{"name":1}],[{"?a":"int"},{}],[["string"],["a",2]],[[],[1]]]"#
        let cases = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[Any]])
        let swift = cases.map { Self.mismatch($0[0], $0[1]) == nil }
        XCTAssertEqual(swift, [true, false, false, false, true, false, false, true, true, false, false, true, false, true])
        let code = "import json,sys; sys.path.insert(0, sys.argv[1]); import run; "
            + "print(json.dumps([run.shape_ok(s, v) is None for s, v in json.loads(sys.argv[2])]))"
        let (status, out) = try python(["-B", "-c", code, try goldenDir().path, json])
        XCTAssertEqual(status, 0, out)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [Bool], swift, out)
    }

    /// The shape check rejects what it should: a wrong-typed key, a missing one, a regex miss.
    func testShapeCheckRejectsMismatches() {
        let row: [String: Any] = ["name": "string", "?state": "string~working|idle|blocked|done", "?agents": "int"]
        XCTAssertNil(Self.mismatch([row], [["name": "a", "state": "idle", "agents": 2]]))
        XCTAssertNotNil(Self.mismatch([row], [["name": "a", "state": "idler"]]))
        XCTAssertNotNil(Self.mismatch([row], [["alias": "a"]]))
        XCTAssertNotNil(Self.mismatch([row], [["name": "a", "agents": true]]))
        XCTAssertNotNil(Self.mismatch(["proto": "string~1\\.[0-9]+"], ["proto": "2.0"]))
        XCTAssertNotNil(Self.mismatch(["n": "int"], ["n": 1.5]))
        XCTAssertNotNil(Self.mismatch("string~idle", "idle\n"), "a trailing newline fails, as in run.py")
        XCTAssertNil(Self.mismatch(["n": "number"], ["n": 1.5]))
    }

    // MARK: - 0x08's 1.0 keys

    /// #800: "create" and "paste_image" are always listed: 0x02 and 0x0a are served whatever the
    /// clipboard, chat, commands and watch flags say.
    func testMachineInfoListsCreateAndPasteImageAlways() {
        for flag in [false, true] {
            let ops = DchFrame.machineInfo(deviceID: "d", hostname: "h", wakeId: nil, clipboard: flag, chat: flag,
                                           commands: flag, reviveNoMessage: flag, watch: flag)["ops"] as? [String] ?? []
            XCTAssertTrue(ops.contains("create"), "\(ops)")
            XCTAssertTrue(ops.contains("paste_image"), "\(ops)")
        }
    }

    func testMachineInfoCarriesServerOsNameAndProto() throws {
        let info = DchFrame.machineInfo(deviceID: "id", hostname: "Studio", wakeId: nil)
        XCTAssertEqual(info["server"] as? String, "prosper")
        XCTAssertEqual(info["name"] as? String, "Studio", "the computer name, as hostname")
        XCTAssertEqual(info["proto"] as? String, "1.0")
        XCTAssertEqual(info["os"] as? String, DchFrame.osName)
        XCTAssertNotNil(DchFrame.osName.range(of: #"^macOS [0-9]+\.[0-9]+(\.[0-9]+)?$"#, options: .regularExpression), DchFrame.osName)
        XCTAssertEqual(DchFrame.osName, DchFrame.osLabel(ProcessInfo.processInfo.operatingSystemVersion))
        // Added only: the keys an older phone reads are as before.
        XCTAssertEqual(info["device_id"] as? String, "id")
        XCTAssertEqual(info["hostname"] as? String, "Studio")
        XCTAssertEqual(info["ops"] as? [String], DchFrame.ops)
        XCTAssertNil(info["wakeId"])
    }

    /// QA #625 INFO-8: "os" drops a zero patch and keeps a non-zero one.
    func testOsLabelDropsAZeroPatch() {
        XCTAssertEqual(DchFrame.osLabel(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)), "macOS 15.0")
        XCTAssertEqual(DchFrame.osLabel(OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0)), "macOS 27.1")
        XCTAssertEqual(DchFrame.osLabel(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 1)), "macOS 15.0.1")
    }

    /// The handshake over the wire: device_id present (the phone's decodeMachineInfo needs it), proto 1.x.
    func testMachineInfoOverTheWireIsProto1() throws {
        let c = try Client(port: port)
        try c.send(Data([0x08, 0, 0, 0, 0]))
        let (type, payload) = try c.frame()
        XCTAssertEqual(type, DchFrame.machineInfoResp)
        let info = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertFalse((info["device_id"] as? String ?? "").isEmpty)
        XCTAssertEqual((info["proto"] as? String)?.split(separator: ".").first, "1")
        XCTAssertEqual(info["server"] as? String, "prosper")
    }

    // MARK: - Peer gate and close (review round 2)

    /// The production peer gate, through the init's DEFAULT allowPeer: 127.0.0.1 is outside
    /// 100.64.0.0/10, so the connection is dropped before any frame is handled. Loopback only.
    func testDefaultPeerGateDropsANonTailscalePeer() throws {
        let gated = DchSessionServer(bindHost: { "127.0.0.1" }, port: 0, retryBase: 60, onReady: {})
        defer { gated.stop(); _ = gated.isRunning; gated.queue.sync {} }
        try gated.start()
        let p = try XCTUnwrap(gated.boundPort)
        let c = try Client(port: p)
        try? c.send(Data([0x08, 0, 0, 0, 0]))   // may already fail: the server can reset first
        XCTAssertThrowsError(try c.frame(timeout: 2), "no 0x18 for a peer outside 100.64/10") {
            XCTAssertEqual($0 as? Client.Failure, .closed)
        }
        XCTAssertTrue(try c.closed(timeout: 2))
    }

    /// QA #625 INFO-1: the default peer gate takes IPv4 in 100.64.0.0/10 only; IPv6 fails closed,
    /// Tailscale's own fd7a:115c:a1e0::/48 and a v4-mapped CGNAT address included.
    func testPeerGateRefusesIPv6AndAddressesOutsideTheRange() throws {
        func peer(_ host: NWEndpoint.Host) -> Bool {
            DchSessionServer.isTailscalePeer(NWConnection(to: .hostPort(host: host, port: 9), using: .tcp))
        }
        XCTAssertTrue(peer(.ipv4(try XCTUnwrap(IPv4Address("100.100.1.2")))))
        XCTAssertFalse(peer(.ipv4(try XCTUnwrap(IPv4Address("100.128.0.1")))))
        XCTAssertFalse(peer(.ipv4(try XCTUnwrap(IPv4Address("127.0.0.1")))))
        XCTAssertFalse(peer(.ipv6(try XCTUnwrap(IPv6Address("fd7a:115c:a1e0::1")))))
        XCTAssertFalse(peer(.ipv6(try XCTUnwrap(IPv6Address("::ffff:100.100.1.2")))))
        XCTAssertFalse(peer(.ipv6(.loopback)))
    }

    /// QA #625 F1: a failed spawn's 0x13 reaches the wire before the close (it is the final
    /// message), with user copy, and a frame pipelined behind the attach is never answered.
    /// QA #625 INFO-R1: nor handled: close() empties the buffer, so drain() stops at the attach.
    func testFailedSpawnSendsItsErrorBeforeTheClose() throws {
        let lists = Recorder()
        let failing = DchSessionServer(bindHost: { "127.0.0.1" }, port: 0, retryBase: 60, onReady: {},
                                       allowPeer: { _ in true },
                                       configure: { c in
                                           c.listSessions = { lists.add(["list"]); return [] }
                                           c.spawn = { _, _, _, _, _, _ in throw PtyChild.PtyError.forkFailed }
                                       })
        defer { failing.stop(); _ = failing.isRunning; failing.queue.sync {} }
        try failing.start()
        let c = try Client(port: try XCTUnwrap(failing.boundPort))
        try c.send(DchFrame.encode(DchFrame.attach, json: ["name": "golden-776", "cols": 80, "rows": 24])
                   + DchFrame.encode(DchFrame.list, []))
        let (type, payload) = try c.frame()
        XCTAssertEqual(type, DchFrame.error)
        let message = (try JSONSerialization.jsonObject(with: payload) as? [String: Any])?["message"] as? String
        XCTAssertEqual(message, DchConnection.spawnFailed)
        XCTAssertEqual(message, "Could not start the session: the Mac could not open a terminal.")
        XCTAssertThrowsError(try c.frame(), "then the close, and no 0x11 for the pipelined list") {
            XCTAssertEqual($0 as? Client.Failure, .closed)
        }
        failing.queue.sync {}   // drain() ran before the close reached the wire; this only orders the read
        XCTAssertEqual(lists.all, [], "the list pipelined behind the failed attach is never handled")
    }

    /// QA #625 F1-R2: today's behaviour, pinned so that answering after a client's FIN is a
    /// deliberate spec change. The client sends 0x08 and shuts its write side; the reply waits
    /// for a dch probe (made slow here; 0.25 s at most), the FIN closes first, no 0x18 comes.
    func testHalfCloseDropsAPendingReply() throws {
        let slow = DchSessionServer(bindHost: { "127.0.0.1" }, port: 0, retryBase: 60, onReady: {},
                                    allowPeer: { _ in true },
                                    configure: { c in
                                        c.ops.binary = { Thread.sleep(forTimeInterval: 1); return nil }
                                        // QA #625 INFO-R3-6: 0x08 reads these; never the live Preferences.
                                        c.clipboard.enabled = { false }
                                        c.commands.enabled = { false }
                                    })
        defer { slow.stop(); _ = slow.isRunning; slow.queue.sync {} }
        try slow.start()
        let c = try Client(port: try XCTUnwrap(slow.boundPort))
        try c.send(Data([0x08, 0, 0, 0, 0]))
        c.shutdownWrite()
        XCTAssertThrowsError(try c.frame(timeout: 2), "the FIN closes the connection before the 0x18") {
            XCTAssertEqual($0 as? Client.Failure, .closed)
        }
    }

    /// QA #625 INFO-R3-6: attach on a watch connection, over the wire, is refused with the
    /// spec's text, "watch connections cannot attach or create" (golden can't express it).
    func testAttachOnAWatchConnectionIsRefusedWithItsMessage() throws {
        let c = try Client(port: port)
        try c.send(DchFrame.encode(DchFrame.watch, Array("{}".utf8)))
        XCTAssertEqual(try c.frame().0, DchFrame.listResp, "the watch snapshot")
        try c.send(DchFrame.encode(DchFrame.attach, json: ["name": "golden-776-watch", "cols": 80, "rows": 24]))
        var f = try c.frame()
        while f.0 != DchFrame.error { f = try c.frame() }   // the frames before it depend on other ops
        XCTAssertEqual((try JSONSerialization.jsonObject(with: f.1) as? [String: Any])?["message"] as? String,
                       "watch connections cannot attach or create")
    }

    /// The session's program exits: 0x12 exit {"code"} reaches the wire, then the close. Golden 15
    /// pins the close only (its pty output has no fixed frame count); this pins the 0x12.
    func testSessionExitSendsExitBeforeTheClose() throws {
        let c = try Client(port: port)
        try c.send(DchFrame.encode(DchFrame.attach, json: ["name": "golden-776-exit", "cols": 80, "rows": 24]))
        XCTAssertEqual(try c.frame().0, DchFrame.data, "the repaint")
        try c.send(DchFrame.encode(DchFrame.data, Array("exit\r\u{04}".utf8)))   // the fake's cat reads the ^D: EOF
        var f = try c.frame()
        while f.0 == DchFrame.data { f = try c.frame() }
        XCTAssertEqual(f.0, DchFrame.exit)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: f.1) as? [String: Any])?["code"] as? Int, 0)
        XCTAssertTrue(try c.closed(), "then the FIN")
    }

    /// Once closed, a connection reads nothing more: a valid list frame ingested after close()
    /// is neither handled nor answered.
    func testNothingIsReadAfterClose() {
        let queue = DispatchQueue(label: "test.dchconn.golden")
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { _ in })
        let sent = Recorder(), lists = Recorder()
        conn.sendOverride = { f in sent.add([f.map { String(format: "%02x", $0) }.joined()]) }
        conn.listSessions = { lists.add(["list"]); return Self.rows }
        queue.sync { conn.ingest(DchFrame.encode(DchFrame.list, [])) }
        XCTAssertEqual(lists.all.count, 1, "the seam answers a list while open")
        XCTAssertEqual(sent.all.count, 1)
        queue.sync {
            conn.close()
            conn.ingest(DchFrame.encode(DchFrame.list, []))
        }
        XCTAssertEqual(lists.all.count, 1, "no list handled after close")
        XCTAssertEqual(sent.all.count, 1, "nothing sent after close")
    }

    // MARK: - Framing

    /// The layout: type, u32 big-endian length, payload.
    func testFrameLayoutIsTypeThenBigEndianLength() {
        XCTAssertEqual([UInt8](DchFrame.encode(0x11, [1, 2, 3])), [0x11, 0, 0, 0, 3, 1, 2, 3])
        XCTAssertEqual([UInt8](DchFrame.encode(0x10, [UInt8](repeating: 7, count: 0x0102_03)).prefix(5)), [0x10, 0, 1, 2, 3])
    }

    /// Receive guard on the wire: a length of exactly 256 MiB waits for its payload, one more
    /// answers 0x13 "frame too large" and then closes. The error goes as the final message and
    /// the cancel waits for it: an immediate cancel dropped it before #776.
    func testReceiveGuardIs256MiBOnTheWire() throws {
        XCTAssertEqual(DchFrame.maxRequestFrame, 256 << 20)
        let at = try Client(port: port)
        try at.send(Data([0x10]) + Self.be32(DchFrame.maxRequestFrame))
        XCTAssertThrowsError(try at.frame(timeout: 0.5), "a length at the guard is accepted: nothing comes back") {
            XCTAssertEqual($0 as? Client.Failure, .timeout)
        }
        let past = try Client(port: port)
        try past.send(Data([0x10]) + Self.be32(DchFrame.maxRequestFrame + 1) + Data(repeating: 0x61, count: 4096))
        let (type, payload) = try past.frame()
        XCTAssertEqual(type, DchFrame.error, "Prosper's 0x13 reaches the wire before the close")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: payload) as? [String: Any])?["message"] as? String, "frame too large")
        XCTAssertTrue(try past.closed(), "then the server closes, and nothing else comes")
        XCTAssertTrue(try at.closed(timeout: 0.2) == false, "the one at the guard is still open")
    }

    /// Send limit, where the code has one: 8 MiB, the phone's maxFrame. The library reply is
    /// refused past it rather than sent (DchFrame.maxFrame also bounds clipboardList).
    func testSendLimitIs8MiBWhereTheCodeChecksIt() throws {
        XCTAssertEqual(DchFrame.maxFrame, 8 << 20)
        XCTAssertEqual(DchLibraryOps.maxReply, DchFrame.maxFrame)
        let fits = DchLibraryOps.encode(["etag": "e", "pad": String(repeating: "x", count: DchFrame.maxFrame - 64)])
        XCTAssertEqual(fits.first, DchFrame.libraryResp)
        XCTAssertLessThanOrEqual(fits.count - 5, DchFrame.maxFrame)
        let over = DchLibraryOps.encode(["etag": "e", "pad": String(repeating: "x", count: DchFrame.maxFrame)])
        XCTAssertEqual(over.first, DchFrame.error)
    }

    // MARK: - Fixture runner

    /// QA #625 INFO-10: the fixtures live in the repo's docs/protocol, beside app/. Missing
    /// (an app/-only copy), the tests fail saying so rather than on a file error.
    private func goldenDir() throws -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: Self.golden.path, isDirectory: &isDir), isDir.boolValue else {
            throw Mismatch(description: "docs/protocol/golden is missing at \(Self.golden.path): the golden tests read the spec's "
                + "fixtures from the repo checkout. A copy of app/ alone lacks them; copy docs/protocol beside app/.")
        }
        return Self.golden
    }

    /// /usr/bin/python3 -I with `args`: exit status and stdout+stderr. Killed (its own pid) after `kill` s.
    private func python(_ args: [String], kill: TimeInterval = 60) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let pid = p.processIdentifier
        let killer = DispatchWorkItem { if p.isRunning { Darwin.kill(pid, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + kill, execute: killer)
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, text)
    }

    private func handshakeOps() throws -> Set<String> {
        let c = try Client(port: port)
        try c.send(Data([0x08, 0, 0, 0, 0]))
        let (_, payload) = try c.frame()
        return Set((try JSONSerialization.jsonObject(with: payload) as? [String: Any])?["ops"] as? [String] ?? [])
    }

    private struct Mismatch: Error, CustomStringConvertible { let description: String }

    /// One deadline per step, `timeout` (the spec's 5 s), as run.py.
    private func run(_ fx: [String: Any], port: UInt16? = nil, timeout: TimeInterval = 5) throws {
        let c = try Client(port: port ?? self.port)
        for step in fx["steps"] as? [[String: Any]] ?? [] {
            let end = Date() + timeout   // per step, as run.py's c.arm() (QA #627 INFO-4)
            if let hex = step["send"] as? String {
                try c.send(Self.unhex(hex))
            } else if let want = step["expect"] as? [String: Any] {
                let (type, payload) = try c.frame(until: end)
                if let why = Self.check(want, type, payload) { throw Mismatch(description: why) }
            } else if let secs = (step["expect_quiet"] as? NSNumber)?.doubleValue {
                // Nothing but 0x10 pty output for `secs`: any other frame is a reply that should not come.
                let end = Date() + secs
                while true {
                    let f: (UInt8, Data)
                    do { f = try c.frame(until: end) } catch Client.Failure.timeout { break }
                    guard f.0 == DchFrame.data else { throw Mismatch(description: "want no reply, got \(String(format: "%02x", f.0))") }
                }
            } else if step["expect_close"] as? Bool == true {
                guard try c.closed(timeout: end.timeIntervalSinceNow) else { throw Mismatch(description: "the server did not close the connection") }
            }
        }
    }

    private static func check(_ want: [String: Any], _ type: UInt8, _ payload: Data) -> String? {
        guard let t = (want["type"] as? String).flatMap({ UInt8($0, radix: 16) }), t == type else {
            return "want type \(want["type"] ?? "?"), got \(String(format: "%02x", type))"
        }
        if let hex = want["payload"] as? String, payload != unhex(hex) { return "want payload \(hex), got \(payload.count) bytes" }
        if want["nonempty"] as? Bool == true, payload.isEmpty { return "want a non-empty payload" }
        if let shape = want["json"] {
            guard let v = try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]) else {
                return "payload is not JSON"
            }
            return mismatch(shape, v)
        }
        return nil
    }

    /// run.py's shape_ok, in Swift: nil on a match, else the first mismatch.
    static func mismatch(_ shape: Any, _ v: Any, _ path: String = "$") -> String? {
        if let s = shape as? String {
            let parts = s.split(separator: "~", maxSplits: 1).map(String.init)
            let n = v as? NSNumber, isBool = n.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            let ok: Bool
            switch parts[0] {
            case "any": ok = true
            case "string": ok = v is String
            case "bool": ok = isBool
            case "int": ok = n != nil && !isBool && !CFNumberIsFloatType(n! as CFNumber)
            case "number": ok = n != nil && !isBool
            case "object": ok = v is [String: Any]
            case "array": ok = v is [Any]
            default: return "\(path): unknown shape \(s)"
            }
            guard ok else { return "\(path): want \(parts[0]), got \(v)" }
            // NSRegularExpression (ICU), the same on every Foundation (String.range(of:) is not): its
            // `$` also matches before a final newline, so `\z` ends the match where re.fullmatch does.
            if parts.count == 2, let str = v as? String,
               (try? NSRegularExpression(pattern: "^(?:\(parts[1]))\\z"))?
                   .firstMatch(in: str, range: NSRange(str.startIndex..., in: str)) == nil {
                return "\(path): \(str) does not match \(parts[1])"
            }
            return nil
        }
        if let shapes = shape as? [Any] {
            guard let arr = v as? [Any] else { return "\(path): want array" }
            for (i, e) in arr.enumerated() {
                for s in shapes { if let why = mismatch(s, e, "\(path)[\(i)]") { return why } }
            }
            return nil
        }
        if let keys = shape as? [String: Any] {
            guard let o = v as? [String: Any] else { return "\(path): want object" }
            for (k, s) in keys {
                let key = k.hasPrefix("?") ? String(k.dropFirst()) : k
                guard let value = o[key] else {
                    if k.hasPrefix("?") { continue }
                    return "\(path): missing key \(key)"
                }
                if let why = mismatch(s, value, "\(path).\(key)") { return why }
            }
            return nil
        }
        return "\(path): bad shape"
    }

    static func unhex(_ s: String) -> Data {
        let h = Array(s.filter { !$0.isWhitespace }.utf8)
        return Data(stride(from: 0, to: h.count - 1, by: 2).compactMap { UInt8(String(decoding: h[$0...$0 + 1], as: UTF8.self), radix: 16) })
    }

    static func be32(_ n: Int) -> Data {
        Data([UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
    }
}

/// A blocking loopback client: one socket, a receive timeout, frames reassembled.
private final class Client {
    enum Failure: Error, Equatable { case connect, closed, timeout, oversize }

    private let fd: Int32
    private var buf = Data()

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard fd >= 0, ok else { Darwin.close(fd); throw Failure.connect }
    }

    /// An accepted socket (FakeServer's side).
    init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { Darwin.close(fd) }

    /// A half-close: the server reads EOF, the socket still reads.
    func shutdownWrite() { Darwin.shutdown(fd, SHUT_WR) }

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + off, raw.count - off, 0)
                guard n > 0 else { throw Failure.closed }
                off += n
            }
        }
    }

    /// False on EOF; throws on timeout. QA #625 INFO-R3-4: `end` bounds the whole wait, as run.py's
    /// per-step deadline, so a server that keeps sending cannot stretch it.
    private func fill(_ n: Int, until end: Date) throws -> Bool {
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while buf.count < n {
            let left = end.timeIntervalSinceNow
            guard left > 0 else { throw Failure.timeout }
            // at least 1 ms: a zero timeval waits forever
            var tv = timeval(tv_sec: Int(left), tv_usec: Int32(max((left - floor(left)) * 1e6, 1000)))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let got = recv(fd, &chunk, chunk.count, 0)
            if got == 0 || (got < 0 && errno == ECONNRESET) { return false }
            if got < 0 { throw Failure.timeout }
            buf.append(contentsOf: chunk[0..<got])
        }
        return true
    }

    /// The next frame; every frame must be within the server's 8 MiB send limit.
    func frame(timeout: TimeInterval = 5) throws -> (UInt8, Data) {
        try frame(until: Date() + timeout)
    }

    func frame(until end: Date) throws -> (UInt8, Data) {
        guard try fill(5, until: end) else { throw Failure.closed }
        let b = [UInt8](buf.prefix(5))
        let n = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
        guard n <= DchFrame.maxFrame else { throw Failure.oversize }
        guard try fill(5 + n, until: end) else { throw Failure.closed }
        let payload = buf.subdata(in: buf.startIndex + 5..<buf.startIndex + 5 + n)
        buf.removeFirst(5 + n)
        return (b[0], payload)
    }

    /// True once the server closed (EOF or reset) within `timeout`, as run.py: bytes before the close
    /// are ignored and do not extend it.
    func closed(timeout: TimeInterval = 5) throws -> Bool {
        let end = Date() + timeout
        do {
            while try fill(buf.count + 1, until: end) {}
            return true
        } catch Failure.timeout { return false }
    }
}

/// QA #625 INFO-R2: a loopback fake that speaks just enough of the protocol for fixture 12:
/// attach answers one 0x10, resize answers `resizeReply` (nil: nothing). One connection at a
/// time, 127.0.0.1 on a kernel-picked port, until stop().
/// QA #625 INFO-R3-4: `redrawForever` makes attach answer a 0x10 every 50 ms instead, never
/// reading or closing again, until the client goes or stop() (a session that keeps drawing).
/// QA #627 INFO-4: `pacedReplies` answers any frame with two empty 0x14s, each that many seconds after the last.
private final class FakeServer: @unchecked Sendable {
    let port: UInt16
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    init(resizeReply: Data? = nil, redrawForever: Bool = false, pacedReplies: TimeInterval? = nil) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard fd >= 0, ok else { Darwin.close(fd); throw Client.Failure.connect }
        port = UInt16(bigEndian: addr.sin_port)
        let stopped = stopped
        Thread.detachNewThread {
            defer { Darwin.close(fd) }
            while !stopped.withLock({ $0 }) {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 100) > 0 else { continue }
                let s = accept(fd, nil, nil)
                guard s >= 0 else { continue }
                let peer = Client(fd: s)
                while let (type, _) = try? peer.frame() {
                    if type == DchFrame.attach, redrawForever {
                        while !stopped.withLock({ $0 }), (try? peer.send(DchFrame.encode(DchFrame.data, [0x78]))) != nil {
                            usleep(50_000)
                        }
                        break
                    }
                    if type == DchFrame.attach { try? peer.send(DchFrame.encode(DchFrame.data, [0x78])) }
                    if type == DchFrame.resize, let resizeReply { try? peer.send(resizeReply) }
                    if let pacedReplies {
                        for _ in 0..<2 {
                            usleep(UInt32(pacedReplies * 1e6))
                            try? peer.send(DchFrame.encode(DchFrame.ok, []))
                        }
                    }
                }
            }
        }
    }

    func stop() { stopped.withLock { $0 = true } }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func add(_ c: [String]) { lock.withLock { calls.append(c) } }
    var all: [[String]] { lock.withLock { calls } }
}
