import Network
import os
import XCTest
@testable import ProsperApp

/// #885: parity with dch serve 1.58.0. 0x07 re-arms the attached dch client with SIGURG after the jiggle
/// (serve.c:1815-1829), and every frame serve also reads takes its payload as serve's rq_json and jstr do
/// (DchFrame.request): a UTF-8 BOM is malformed, a key given twice or a string holding a NUL or a lone
/// surrogate once decoded is unreadable, and no such string reaches an argv. Signals go through PtyChild's
/// seam, which records them: the only real signals here are terminate()'s SIGHUP to a child this test spawned.
final class DchServeParityTests: XCTestCase {
    // MARK: - 0x07 re-arm (PtyChild)

    /// The signal seam's log: each (pid, signal), whether the shrink was already on (read under PtyChild's
    /// lock, which the seam runs under) and whether it ran on the connection's queue.
    private final class Signals: @unchecked Sendable {
        struct Sent: Equatable { let pid: pid_t, sig: Int32, shrunk: Bool, onQueue: Bool }
        let lock = NSLock()
        private var sent: [Sent] = []
        weak var child: PtyChild?
        var pid: pid_t = 0
        let key = DispatchSpecificKey<Bool>()

        func record(_ pid: pid_t, _ sig: Int32) {
            let shrunk = lock.withLock { child }?.isJiggling ?? false
            let onQueue = DispatchQueue.getSpecific(key: key) == true
            lock.withLock { sent.append(Sent(pid: pid, sig: sig, shrunk: shrunk, onQueue: onQueue)) }
        }
        var all: [Sent] { lock.withLock { sent } }
        func gotPid(_ bytes: [UInt8]) -> Bool {
            guard let m = String(decoding: bytes, as: UTF8.self).firstMatch(of: /PID([0-9]+)/), let p = pid_t(m.1) else { return false }
            lock.withLock { pid = p }
            return true
        }
        var childPid: pid_t { lock.withLock { pid } }
    }

    /// A shell that prints its pid, then becomes `then` (cat: runs until terminate()'s SIGHUP).
    private func child(_ signals: Signals, then: String = "exec /bin/cat",
                       onExit: @escaping (Int32) -> Void = { _ in }) throws -> PtyChild {
        let started = expectation(description: "pid printed")
        started.assertForOverFulfill = false
        let c = try PtyChild(exe: "/bin/sh", args: ["-c", "echo PID$$; \(then)"], env: ["PATH": "/usr/bin:/bin"],
                             cols: 80, rows: 24, signal: { signals.record($0, $1) },
                             onOutput: { if signals.gotPid($0) { started.fulfill() } }, onExit: onExit)
        signals.lock.withLock { signals.child = c }
        c.run()
        wait(for: [started], timeout: 15)
        return c
    }

    /// serve.c:1815-1829: the shrink first, then SIGURG to this connection's own client (p2, p3).
    func testRearmSignalsItsOwnChildAfterTheShrink() throws {
        let s = Signals()
        let c = try child(s)
        defer { c.terminate() }
        c.redraw(rearm: true)
        XCTAssertGreaterThan(s.childPid, 0)
        XCTAssertEqual(s.all, [.init(pid: s.childPid, sig: SIGURG, shrunk: true, onQueue: false)])
    }

    /// serve sends SIGURG whether a jiggle starts or not: a second 0x07 while the first shrink is pending
    /// signals again and shrinks no further.
    func testRearmGoesOutWhileAShrinkIsPending() throws {
        let s = Signals()
        let c = try child(s)
        defer { c.terminate() }
        c.redraw(rearm: true)
        c.redraw(rearm: true)
        XCTAssertEqual(s.all.map(\.sig), [SIGURG, SIGURG])
        XCTAssertEqual(Set(s.all.map(\.pid)), [s.childPid])
    }

    /// AgentTerminal's redraw() (the default) stays a jiggle only.
    func testRedrawWithoutRearmSignalsNothing() throws {
        let s = Signals()
        let c = try child(s)
        defer { c.terminate() }
        c.redraw()
        XCTAssertEqual(s.all, [])
    }

    /// A child that already exited and was reaped gets nothing: reap() sets done under the lock before its
    /// waitpid, and the signal goes out under that lock only while !done (p1).
    func testNoSignalOnceTheChildHasExited() throws {
        let s = Signals()
        let exited = expectation(description: "reaped")
        let c = try child(s, then: "exit 0", onExit: { _ in exited.fulfill() })
        wait(for: [exited], timeout: 15)
        c.redraw(rearm: true)
        c.redraw(rearm: true)
        XCTAssertEqual(s.all, [], "no signal to a reaped pid, which the system may have handed on")
        XCTAssertFalse(c.isJiggling, "nor a jiggle")
    }

    /// The 0x07 path end to end on the connection's real queue: the attach's own child gets SIGURG after
    /// the shrink, from that queue; a 0x07 before any attach signals nothing.
    func testRedrawFrameOnTheConnectionQueueRearmsItsClient() throws {
        let s = Signals()
        let queue = DispatchQueue(label: "test.dchconn.rearm")
        queue.setSpecific(key: s.key, value: true)
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { @Sendable _ in })
        conn.sendOverride = { _ in }
        conn.clipboard.enabled = { false }
        conn.commands.enabled = { false }
        conn.listSessions = { [] }
        let started = expectation(description: "pid printed")
        started.assertForOverFulfill = false
        var spawned: [String] = []
        conn.spawn = { _, args, cols, rows, _, onExit in
            spawned = args
            let c = try PtyChild(exe: "/bin/sh", args: ["-c", "echo PID$$; exec /bin/cat"], env: ["PATH": "/usr/bin:/bin"],
                                 cols: cols, rows: rows, signal: { s.record($0, $1) },
                                 onOutput: { if s.gotPid($0) { started.fulfill() } }, onExit: onExit)
            s.lock.withLock { s.child = c }
            return c
        }
        addTeardownBlock { queue.sync { conn.close() } }

        queue.sync { conn.ingest(DchFrame.encode(DchFrame.redraw, [])) }
        XCTAssertEqual(s.all, [], "no pty yet")
        queue.sync { conn.ingest(DchFrame.encode(DchFrame.attach, json: ["name": "work", "cols": 80, "rows": 24])) }
        XCTAssertEqual(queue.sync { spawned }, ["-E", "-f", "-n", "work"])
        wait(for: [started], timeout: 15)
        queue.sync { conn.ingest(DchFrame.encode(DchFrame.redraw, [])) }
        XCTAssertEqual(s.all, [.init(pid: s.childPid, sig: SIGURG, shrunk: true, onQueue: true)])
    }

    // MARK: - Frame payloads (DchConnection, every dch a recorder)

    private final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var frames: [Data] = []
        var spawned: [[String]] = []
        var killed: [String] = []
        var renamed: [[String]] = []
        var ctl = 0
        var closes = 0
    }

    private func sendRaw(_ type: UInt8, _ bytes: [UInt8]) -> Calls {
        let queue = DispatchQueue(label: "test.dchconn.parity")
        let calls = Calls()
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"),
                                 onClose: { @Sendable _ in calls.lock.withLock { calls.closes += 1 } })
        conn.sendOverride = { f in calls.lock.withLock { calls.frames.append(f) } }
        conn.clipboard.enabled = { false }
        conn.commands.enabled = { false }
        conn.listSessions = { [] }
        conn.kill = { n in calls.lock.withLock { calls.killed.append(n) } }
        conn.rename = { n, a in calls.lock.withLock { calls.renamed.append([n, a]) }; return nil }
        conn.spawn = { _, args, _, _, _, _ in
            calls.lock.withLock { calls.spawned.append(args) }
            throw PtyChild.PtyError.forkFailed
        }
        conn.ctl.path = { calls.lock.withLock { calls.ctl += 1 }; return "/nonexistent/dch" }
        addTeardownBlock { queue.sync { conn.close() } }
        queue.sync { conn.ingest(DchFrame.encode(type, bytes)) }
        return calls
    }

    private func send(_ type: UInt8, _ json: String) -> Calls { sendRaw(type, Array(json.utf8)) }

    private static let bom: [UInt8] = [0xef, 0xbb, 0xbf]
    private static let ok = DchFrame.encode(DchFrame.ok, [])
    private static let needsName = DchControlOps.error(DchConnection.needsName)
    private static let unreadable = DchControlOps.error(DchCtl.unreadable)
    private static let badCommand = DchControlOps.error(DchConnection.badCommand)
    private static let spawnFailed = DchControlOps.error(DchConnection.spawnFailed)
    private static func malformed(_ type: UInt8) -> Data {
        DchControlOps.error(type == DchFrame.create ? "malformed create request" : "malformed attach request")
    }

    /// Rider (a), p4: rq_json's parser skips only space, tab, CR and LF (v1.58.0 json.c:67-70), so a BOM
    /// before the object is malformed (serve.c:999-1003); JSONSerialization alone skips it.
    func testABomBeforeTheObjectIsMalformed() {
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(Self.bom + Array(#"{"name":"w"}"#.utf8))),
                        "the trap this guards against")
        for type in [DchFrame.attach, DchFrame.create] {
            let r = sendRaw(type, Self.bom + Array(#"{"name":"work","cols":80,"rows":24}"#.utf8))
            r.lock.withLock {
                XCTAssertEqual(r.frames, [Self.malformed(type)])
                XCTAssertEqual(r.spawned, [])
            }
        }
        XCTAssertNil(DchFrame.request(Data(Self.bom + Array("{}".utf8))))
        XCTAssertEqual(DchFrame.request(Data(" \t\r\n{}".utf8))?.count, 0, "serve's own whitespace still reads")
        XCTAssertEqual(DchFrame.request(Data())?.count, 0, "empty reads as {}")
    }

    /// Rider (b), p5: a "name" given twice is no readable name (json_field -2, json.c:366-384; jstr -1),
    /// so "attach needs a session name" (serve.c:1005-1011), create too; an escaped spelling of the key is the
    /// same key (json_key_eq decodes, :359-364).
    func testANameGivenTwiceNeedsAName() {
        for type in [DchFrame.attach, DchFrame.create] {
            for raw in [#"{"name":"work","name":"work"}"#, #"{"name":"a","name":"b"}"#, #"{"name":"a", "name" :1}"#] {
                let r = send(type, raw)
                r.lock.withLock {
                    XCTAssertEqual(r.frames, [Self.needsName], raw)
                    XCTAssertEqual(r.spawned, [], raw)
                }
            }
        }
    }

    /// R2: a lone surrogate escape in "name" fails json_decode (json.c:288-357), so jstr fails and serve
    /// answers "attach needs a session name"; JSONSerialization refuses the whole document instead, which
    /// read as "malformed attach request" before. A valid pair in raw UTF-8 still decodes (an escaped pair:
    /// testAnEscapedSurrogatePairDecodes).
    func testALoneSurrogateNameNeedsAName() {
        for type in [DchFrame.attach, DchFrame.create] {
            for raw in [#"{"name":"w\ud800x"}"#, #"{"name":"\udc00"}"#, #"{"name":"\ud800\ud800"}"#, #"{"name":"\uDBFF"}"#,
                        #"{"name":"a\ude00\ud83d"}"#] {
                let r = send(type, raw)
                r.lock.withLock {
                    XCTAssertEqual(r.frames, [Self.needsName], raw)
                    XCTAssertEqual(r.spawned, [], raw)
                }
            }
        }
        let r = send(DchFrame.attach, #"{"name":"w😀"}"#)
        r.lock.withLock {
            XCTAssertEqual(r.spawned, [["-E", "-f", "-n", "w\u{1F600}"]])
            XCTAssertEqual(r.frames, [Self.spawnFailed])
        }
    }

    /// #886 (QA #755 INFO-1): an escaped valid pair (high then low, either case) is copied through as 12 bytes and
    /// decodes on both servers (json_decode joins it, v1.58.0 json.c:317-324): the name reaches dch as the emoji.
    func testAnEscapedSurrogatePairDecodes() throws {
        for raw in [#"{"name":"w\ud83d\ude00"}"#, #"{"name":"w\uD83D\uDE00"}"#] {
            let o = try XCTUnwrap(DchFrame.request(Data(raw.utf8)), raw)
            XCTAssertEqual(o["name"] as? String, "w\u{1F600}", raw)
            let r = send(DchFrame.attach, raw)
            r.lock.withLock {
                XCTAssertEqual(r.spawned, [["-E", "-f", "-n", "w\u{1F600}"]], raw)
                XCTAssertEqual(r.frames, [Self.spawnFailed], raw)
            }
        }
    }

    /// #886 (QA #755 INFO-2): space, tab, CR or LF between a key and its ':' still makes it that key (json_parse_object
    /// skips it before the ':', v1.58.0 json.c:190-191), so a "name" given twice that way is no readable name either.
    func testAKeyWithSpaceBeforeItsColonCountsAsGivenTwice() throws {
        for raw in [#"{"name":"a", "name" :"a"}"#, "{\"name\":\"a\",\"name\"\t\r\n:\"a\"}"] {
            let o = try XCTUnwrap(DchFrame.request(Data(raw.utf8)), raw)
            XCTAssertTrue(o["name"] is NSNull, raw)
            for type in [DchFrame.attach, DchFrame.create] {
                let r = send(type, raw)
                r.lock.withLock {
                    XCTAssertEqual(r.frames, [Self.needsName], raw)
                    XCTAssertEqual(r.spawned, [], raw)
                }
            }
        }
    }

    /// #886 (required by the #885 review): two low surrogate escapes in a row. dch serve's json_decode fails a
    /// low surrogate that comes first (v1.58.0 json.c:325-326), so jstr fails and serve answers "attach needs a
    /// session name"; the other keys still read. scan's bound `u <= 0xdbff` keeps the first from passing as the
    /// high half of a pair: at 0xdfff both escapes went through and JSONSerialization refused the whole request.
    func testTwoLowSurrogatesInARowNeedAName() throws {
        let o = try XCTUnwrap(DchFrame.request(Data(#"{"name":"\udc00\udc00","cols":90}"#.utf8)))
        XCTAssertTrue(o["name"] is NSNull)
        XCTAssertEqual(o["cols"] as? Int, 90)
        for type in [DchFrame.attach, DchFrame.create] {
            let r = send(type, #"{"name":"\udc00\udc00"}"#)
            r.lock.withLock {
                XCTAssertEqual(r.frames, [Self.needsName])
                XCTAssertEqual(r.spawned, [])
            }
        }
    }

    /// R1: one guard for every frame serve also parses. UTF-16 JSON (a NUL byte) and a BOM are refused with
    /// each frame's own answer: 0x01/0x02 malformed, 0x04/0x06 the empty 0x14 with no dch, 0x30 the malformed
    /// ctl 0x13 then the FIN, 0x2e the malformed watch 0x13. 0x05 and 0x07 answer nothing (DchFrame.request).
    func testEveryJsonFrameRefusesUtf16AndABom() throws {
        let object = #"{"name":"work","alias":"x","argv":["--read","work"],"cols":80,"rows":24}"#
        let utf16 = [UInt8](try XCTUnwrap(object.data(using: .utf16LittleEndian)))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(utf16)), "the trap this guards against")
        for bad in [utf16, Self.bom + Array(object.utf8)] {
            XCTAssertNil(DchFrame.request(Data(bad)))
            for type in [DchFrame.attach, DchFrame.create] {
                let r = sendRaw(type, bad)
                r.lock.withLock { XCTAssertEqual(r.frames, [Self.malformed(type)]); XCTAssertEqual(r.spawned, []) }
            }
            for type in [DchFrame.kill, DchFrame.rename] {
                let r = sendRaw(type, bad)
                r.lock.withLock {
                    XCTAssertEqual(r.frames, [Self.ok], "0x\(String(type, radix: 16))")
                    XCTAssertEqual(r.killed, [])
                    XCTAssertEqual(r.renamed, [])
                }
            }
            let c = sendRaw(DchFrame.ctl, bad)
            c.lock.withLock {
                XCTAssertEqual(c.frames.count, 1)
                XCTAssertEqual(c.ctl, 0)
                let m = (try? JSONSerialization.jsonObject(with: c.frames.first?.dropFirst(5) ?? Data())) as? [String: String]
                XCTAssertTrue(m?["message"]?.hasPrefix("malformed ctl request: send") == true, "\(m ?? [:])")
            }
            let w = sendRaw(DchFrame.watch, bad)
            w.lock.withLock { XCTAssertEqual(w.frames, [DchControlOps.error("malformed watch request: send {}")]) }
        }
    }

    /// R3: no phone string serve's jstr or dch_json_strv cannot read reaches a dch argv. rename's alias (a
    /// NUL, a lone surrogate, given twice, not a string, 1024 bytes or more) runs no dch -m and answers the
    /// empty 0x14 (alias[1024], v1.58.0 serve.c:1167, :1174, :1187), where Prosper ran dch -m <name> "" for some.
    func testRenameRunsNoDchForAnAliasServeCannotRead() {
        for raw in [#"{"name":"work","alias":"a\u0000b"}"#, #"{"name":"work","alias":"a\udc00"}"#,
                    #"{"name":"work","alias":"a","alias":"b"}"#, #"{"name":"work","alias":7}"#,
                    #"{"name":"work","alias":null}"#, #"{"name":"work","alias":"\#(String(repeating: "a", count: 1024))"}"#,
                    #"{"name":"-w\u0000","alias":"a"}"#, #"{"name":"work\u0000","alias":"a"}"#, #"{"name":"w","name":"w","alias":"a"}"#] {
            let r = send(DchFrame.rename, raw)
            r.lock.withLock {
                XCTAssertEqual(r.frames, [Self.ok], String(raw.prefix(60)))
                XCTAssertEqual(r.renamed, [], String(raw.prefix(60)))
            }
        }
        let fits = String(repeating: "a", count: 1023)
        for (raw, want) in [(#"{"name":"work","alias":"\#(fits)"}"#, ["work", fits]), (#"{"name":"work"}"#, ["work", ""]),
                            (#"{"name":"-w","alias":"a"}"#, ["-w", "a"])] {
            let r = send(DchFrame.rename, raw)
            r.lock.withLock { XCTAssertEqual(r.renamed, [want]) }
        }
    }

    /// R3: kill's name the same (jstr -1, no dch -k, the empty 0x14).
    func testKillRunsNoDchForANameServeCannotRead() {
        for raw in [#"{"name":"work\u0000"}"#, #"{"name":"w\ud800"}"#, #"{"name":"work","name":"work"}"#] {
            let r = send(DchFrame.kill, raw)
            r.lock.withLock { XCTAssertEqual(r.frames, [Self.ok], raw); XCTAssertEqual(r.killed, [], raw) }
        }
    }

    /// R3: a create's command serve cannot read (serve.c:1043-1056, MAX_CMD 256) starts nothing; an attach's
    /// unreadable command is no command, so no NUL reaches the argv either way.
    func testCreateRefusesACommandServeCannotRead() {
        let many = "[" + Array(repeating: #""x""#, count: 257).joined(separator: ",") + "]"
        for raw in [#"{"command":["sh","-c","a\u0000b"]}"#, #"{"command":["a\udc00"]}"#, #"{"command":"sh"}"#,
                    #"{"command":[1]}"#, #"{"command":null}"#, #"{"command":["a"],"command":["a"]}"#,
                    #"{"name":"work","command":["a\u0000"]}"#, #"{"command":\#(many)}"#] {
            let r = send(DchFrame.create, raw)
            r.lock.withLock {
                XCTAssertEqual(r.frames, [Self.badCommand], String(raw.prefix(60)))
                XCTAssertEqual(r.spawned, [], String(raw.prefix(60)))
            }
        }
        let fits = Array(repeating: "x", count: 256)
        let r = sendRaw(DchFrame.create, Array((try? JSONSerialization.data(withJSONObject: ["command": fits])) ?? Data()))
        r.lock.withLock { XCTAssertEqual(r.spawned, [["-E", "--"] + fits]) }
        let e = send(DchFrame.create, #"{"command":[]}"#)
        e.lock.withLock { XCTAssertEqual(e.spawned, [["-E"]]) }
        let a = send(DchFrame.attach, #"{"name":"work","command":["sh","a\u0000"]}"#)
        a.lock.withLock { XCTAssertEqual(a.spawned, [["-E", "-f", "-n", "work"]]) }
    }

    /// R3 and the ctl refusal serve 1.58.0 makes that Prosper did not: an argv or cwd it cannot read gets
    /// serve's own words, then the FIN, before any other check (ctl_request, serve.c:1223-1233).
    func testCtlRefusesAnArgvOrCwdServeCannotRead() {
        let longCwd = "/" + String(repeating: "a", count: 1023)
        for raw in [#"{"argv":["--read","a\u0000"]}"#, #"{"argv":["--read","a\ud800"]}"#,
                    #"{"argv":["--read","w"],"argv":["--read","w"]}"#, #"{"argv":["--read",5]}"#, #"{"argv":"--read w"}"#,
                    #"{"argv":null}"#, #"{"argv":["--spawn","w"],"cwd":5}"#, #"{"argv":["--spawn","w"],"cwd":"/\u0000"}"#,
                    #"{"argv":["--spawn","w"],"cwd":"/","cwd":"/"}"#, #"{"argv":["--spawn","w"],"cwd":"\#(longCwd)"}"#,
                    #"{"argv":["ctl does not run"],"cwd":7}"#] {
            let r = send(DchFrame.ctl, raw)
            r.lock.withLock {
                XCTAssertEqual(r.frames, [Self.unreadable], String(raw.prefix(60)))
                XCTAssertEqual(r.ctl, 0)
                XCTAssertEqual(r.closes, 1, "the FIN")
            }
        }
        XCTAssertEqual(DchCtl.unreadable, "malformed ctl request: argv must be an array of strings, cwd a string")
        // A cwd that reads is left to the checks after it.
        let r = send(DchFrame.ctl, #"{"argv":["--spawn","w","--","/bin/sh"],"cwd":"\#(String(longCwd.dropLast()))"}"#)
        r.lock.withLock { XCTAssertEqual(r.frames, [DchControlOps.error(DchCtl.noDirectory)]) }
    }

    /// R4: rename checks the id-shaped alias before name_ok (serve.c:1182-1186 before :1187), so a refused
    /// name with an id-shaped alias gets the session_id message, not "invalid session name".
    func testRenameChecksTheIdShapeBeforeTheName() {
        let r = send(DchFrame.rename, #"{"name":"a/b","alias":"m0123456789abcdef"}"#)
        r.lock.withLock {
            XCTAssertEqual(r.frames, [DchControlOps.error(DchControlOps.idShapedRefusal)])
            XCTAssertEqual(r.renamed, [])
        }
        let n = send(DchFrame.rename, #"{"name":"a/b","alias":"plain"}"#)
        n.lock.withLock { XCTAssertEqual(n.frames, [DchControlOps.error(DchCtl.invalidName)]) }
    }

    // MARK: - DchFrame.request and size

    func testRequestCountsOnlyTopLevelKeysAndReadsStringsWhole() throws {
        let o = try XCTUnwrap(DchFrame.request(Data(#"{"o":{"name":1,"name":2},"name":"w","s":"{\"name\":"}"#.utf8)))
        XCTAssertEqual(o["name"] as? String, "w", "a nested key and a key-like string are not top-level keys")
        XCTAssertEqual(o["s"] as? String, #"{"name":"#)
        let p = try XCTUnwrap(DchFrame.request(Data(#"{"a":"\\","name":"\\ud800"}"#.utf8)))
        XCTAssertEqual(p["name"] as? String, #"\ud800"#, "an escaped backslash is not an escape")
        let q = try XCTUnwrap(DchFrame.request(Data(#"{"name":"\ud800","x":"😀"}"#.utf8)))
        XCTAssertTrue(q["name"] is NSNull)
        XCTAssertEqual(q["x"] as? String, "\u{1F600}")
        XCTAssertNil(DchFrame.request(Data("[]".utf8)))
        XCTAssertNil(DchFrame.request(Data(#"{"a":1"#.utf8)))
    }

    /// rq_size (serve.c:168-179): a positive integer, at most 1000; anything else the default. Unclamped, a
    /// rows of 70000 trapped in PtyChild's UInt16(rows).
    func testSizeIsServesRqSize() throws {
        func size(_ raw: String) throws -> [Int] {
            let s = DchFrame.size(try XCTUnwrap(DchFrame.request(Data(raw.utf8))))
            return [s.cols, s.rows]
        }
        XCTAssertEqual(try size("{}"), [80, 24])
        XCTAssertEqual(try size(#"{"cols":100,"rows":30}"#), [100, 30])
        XCTAssertEqual(try size(#"{"cols":70000,"rows":1001}"#), [1000, 1000])
        XCTAssertEqual(try size(#"{"cols":0,"rows":-5}"#), [80, 24])
        XCTAssertEqual(try size(#"{"cols":"100","rows":1.5}"#), [80, 24])
        XCTAssertEqual(try size(#"{"cols":100,"cols":100,"rows":99999999999999999999}"#), [80, 24])
    }

    /// #886 (QA #755 INFO-3): rq_size reads cols and rows with jint, whose tok_int takes only a JSON integer
    /// (strtoll over the whole token, v1.58.0 rframe.c:282-298): 30.0, 1e2, true and "30" are none, so 80x24;
    /// 0 and below too; 65536 is capped to 1000 (serve.c:168-179).
    func testSizeReadsOnlyAPositiveJsonInteger() throws {
        func size(_ v: String) throws -> [Int] {
            let s = DchFrame.size(try XCTUnwrap(DchFrame.request(Data(#"{"cols":\#(v),"rows":\#(v)}"#.utf8)), v))
            return [s.cols, s.rows]
        }
        for v in ["30.0", "1e2", "true", #""30""#, "0", "-7", "1.5E1", "false", "null"] {
            XCTAssertEqual(try size(v), [80, 24], v)
        }
        XCTAssertEqual(try size("65536"), [1000, 1000])
        XCTAssertEqual(try size("30"), [30, 30])
        XCTAssertEqual(try size("1"), [1, 1], "1 is an integer, true is not")
    }

    // MARK: - #951 serve's whole-request refusals (QA #755 INFO-7)

    /// {"name":"<bytes>"}, the bytes raw inside the string.
    private static func named(_ bytes: UInt8...) -> [UInt8] { Array(#"{"name":""#.utf8) + bytes + Array(#""}"#.utf8) }

    /// `n` nested containers: the object, then n - 1 arrays.
    private static func nested(_ n: Int) -> [UInt8] {
        Array(#"{"a":"#.utf8) + [UInt8](repeating: 0x5b, count: n - 1) + [UInt8](repeating: 0x5d, count: n - 1) + [0x7d]
    }

    /// Every input dch serve's json_parse refuses whole (json.c, the same bytes at v1.58.0 and v1.61.0) is nil here:
    /// utf8_ok (:16-53), json_number (:142-171), JSON_MAX_DEPTH (:59, :262-263), and a trailing comma (json_parse_object
    /// :185-189, json_parse_array :218-221). `foundation`: JSONSerialization alone refuses the row too, so request needs
    /// no pre-check for it (a Foundation that starts reading one fails here, naming the row); false: it reads the row
    /// and scan's comma check refuses it.
    func testServesWholeRequestRefusalsAreMalformed() {
        let rows: [(String, [UInt8], foundation: Bool)] = [
            ("C3 then the closing quote", Self.named(0xc3), true),
            ("a stray continuation byte", Self.named(0x80), true),
            ("lead C0", Self.named(0xc0, 0x80), true),
            ("lead C1", Self.named(0xc1, 0xbf), true),
            ("lead F5", Self.named(0xf5, 0x80, 0x80, 0x80), true),
            ("lead FF", Self.named(0xff), true),
            ("overlong 3-byte", Self.named(0xe0, 0x80, 0xaf), true),
            ("overlong 4-byte", Self.named(0xf0, 0x80, 0x80, 0xaf), true),
            ("surrogate ED A0 80", Self.named(0xed, 0xa0, 0x80), true),
            ("surrogate ED BF BF", Self.named(0xed, 0xbf, 0xbf), true),
            ("past U+10FFFF", Self.named(0xf4, 0x90, 0x80, 0x80), true),
            ("80 in a key", [0x7b, 0x22, 0x80, 0x22, 0x3a, 0x31, 0x7d], true),
            ("01", Array(#"{"cols":01}"#.utf8), true),
            ("-01", Array(#"{"cols":-01}"#.utf8), true),
            ("a bare -", Array(#"{"cols":-}"#.utf8), true),
            ("1.", Array(#"{"cols":1.}"#.utf8), true),
            (".5", Array(#"{"cols":.5}"#.utf8), true),
            ("1e", Array(#"{"cols":1e}"#.utf8), true),
            ("1e+", Array(#"{"cols":1e+}"#.utf8), true),
            ("1025 deep", Self.nested(1025), true),
            ("a trailing comma in the object", Array(#"{"name":"w",}"#.utf8), false),
            ("a trailing comma in an array", Array(#"{"command":["sh",]}"#.utf8), false),
            ("spaces around it", Array(#"{"name":"w" , }"#.utf8), false),
            ("tab, CR and LF before the }", Array("{\"name\":\"w\",\t\r\n}".utf8), false),
            ("a newline before the ]", Array("{\"a\":[1,\n]}".utf8), false),
            ("nested", Array(#"{"a":{"b":1,}}"#.utf8), false),
        ]
        for (label, bytes, foundation) in rows {
            XCTAssertTrue(DchFrame.request(Data(bytes)) == nil, label)
            XCTAssertEqual((try? JSONSerialization.jsonObject(with: Data(bytes))) == nil, foundation, "JSONSerialization: \(label)")
        }
    }

    /// The neighbours of those rows serve reads, and a comma that is no trailing one.
    func testServesReadableNeighboursStillRead() throws {
        XCTAssertEqual(DchFrame.request(Data(Self.named(0xed, 0x9f, 0xbf)))?["name"] as? String, "\u{D7FF}")
        XCTAssertEqual(DchFrame.request(Data(Self.named(0xf4, 0x8f, 0xbf, 0xbf)))?["name"] as? String, "\u{10FFFF}")
        XCTAssertEqual(DchFrame.request(Data(#"{"cols":0,"rows":-0,"x":1e05}"#.utf8))?.count, 3)
        XCTAssertEqual(DchFrame.request(Data(#"{"command":["sh","-c"]}"#.utf8))?["command"] as? [String], ["sh", "-c"])
        let o = try XCTUnwrap(DchFrame.request(Data(#"{"s":",}","t":[",]"],"u":{"v":[1, 2]}}"#.utf8)))
        XCTAssertEqual(o["s"] as? String, ",}", "a comma inside a string is text")
        XCTAssertEqual(o["t"] as? [String], [",]"])
        XCTAssertTrue(DchFrame.request(Data(Self.nested(513))) != nil)
    }

    /// Where Prosper refuses more than serve (remote-frames.md, Framing): JSONSerialization reads 513 nested containers
    /// and refuses 514 (serve reads up to 1024), and refuses a number past a double (serve's json_number is syntax only).
    func testJsonSerializationRefusesWhatServeReads() {
        for bytes in [Self.nested(514), Self.nested(1024), Array(#"{"cols":1e400}"#.utf8)] {
            XCTAssertTrue((try? JSONSerialization.jsonObject(with: Data(bytes))) == nil)
            XCTAssertTrue(DchFrame.request(Data(bytes)) == nil)
        }
    }

    /// The phone's answer for a trailing comma: each frame's malformed answer, as for the BOM (R1), nothing run.
    func testATrailingCommaGetsEachFramesMalformedAnswer() {
        let bad = Array(#"{"name":"work","argv":["--read","work"],}"#.utf8)
        for type in [DchFrame.attach, DchFrame.create] {
            let r = sendRaw(type, bad)
            r.lock.withLock { XCTAssertEqual(r.frames, [Self.malformed(type)]); XCTAssertEqual(r.spawned, []) }
        }
        let k = sendRaw(DchFrame.kill, bad)
        k.lock.withLock { XCTAssertEqual(k.frames, [Self.ok]); XCTAssertEqual(k.killed, []) }
        let c = sendRaw(DchFrame.ctl, bad)
        c.lock.withLock {
            XCTAssertEqual(c.ctl, 0)
            let m = (try? JSONSerialization.jsonObject(with: c.frames.first?.dropFirst(5) ?? Data())) as? [String: String]
            XCTAssertTrue(m?["message"]?.hasPrefix("malformed ctl request: send") == true, "\(m ?? [:])")
        }
    }

    // MARK: - #951 the all-requests' answers (#886 round 2 review)

    private static func reply(_ d: Data) -> (type: UInt8?, json: [String: Any]) {
        (d.first, ((try? JSONSerialization.jsonObject(with: d.dropFirst(5))) as? [String: Any]) ?? [:])
    }

    private static let unsentLine = #"{"name":"a","as":"a","result":"failed","reason":"prompt","detail":"x","session_id":"s","running":true}"#
    private static let dashLine = #"{"name":"-x","result":"failed","reason":"not_started","detail":"-x: not started","session_id":""}"#
    private static let okLine = #"{"name":"b","result":"ok","reason":"","detail":"","session_id":"s"}"#

    private static func dir(_ status: Int32, _ lines: String...) -> DchActionResult {
        AgentIsland.actionResult(status: status, output: Data(lines.map { $0 + "\n" }.joined().utf8))
    }

    /// Item 1: an unsent resume message and a dash refusal in one run keep the per-session line; the dash sentence
    /// follows it (it was the tally alone). With no unsent line the tally stays.
    func testResumeAllKeepsTheUnsentLineBeforeTheDashSentence() {
        let r = Self.reply(DchControlOps.answer(all: Self.dir(1, Self.unsentLine, Self.dashLine), .resume))
        XCTAssertEqual(r.type, DchFrame.ok)
        XCTAssertEqual(r.json["names"] as? [String], ["a"])
        XCTAssertEqual(r.json["message"] as? String, "a: Resumed; the resume message wasn't sent; 1 session has a name dch can no longer start")
        let t = Self.reply(DchControlOps.answer(all: Self.dir(1, Self.okLine, Self.dashLine), .resume))
        XCTAssertEqual(t.json["message"] as? String, "1 resumed, 1 session has a name dch can no longer start")
    }

    /// Item 2: per-dir results. A dir that exited non-zero with no failed line, beside a dir whose failed line reads
    /// ok (unsent, or a dash refusal next to a resumed session), makes the answer the error: the summary, then that
    /// dir's failedText. Merged, its exit was hidden behind the first dir's and the answer was ok.
    func testAllRequestFailsForADirThatFailedWithoutAResultLine() {
        let silent = AgentIsland.actionResult(status: 2, output: Data("dch: cannot read the history\n".utf8))
        let want = DchControlOps.error("1 resumed (1 resume message not sent), failed: dch: cannot read the history")
        XCTAssertEqual(DchControlOps.answer(all: [Self.dir(1, Self.unsentLine), silent], .resume), want)
        XCTAssertEqual(DchControlOps.answer(all: [silent, Self.dir(1, Self.unsentLine)], .resume), want)
        XCTAssertEqual(DchControlOps.answer(all: [Self.dir(1, Self.okLine, Self.dashLine), Self.dir(3)], .resume),
                       DchControlOps.error("1 resumed, 1 session has a name dch can no longer start, failed (exit 3)"))
        // A dir that exited 0, or failed with its line: the answer as before.
        let ok = Self.reply(DchControlOps.answer(all: [Self.dir(1, Self.unsentLine), Self.dir(0, Self.okLine)], .resume))
        XCTAssertEqual(ok.type, DchFrame.ok)
        XCTAssertEqual(ok.json["names"] as? [String], ["a", "b"])
        let split = Self.reply(DchControlOps.answer(all: [Self.dir(1, Self.unsentLine), Self.dir(0), Self.dir(1, Self.dashLine)], .resume))
        XCTAssertEqual(split.type, DchFrame.ok)
        XCTAssertEqual(split.json["names"] as? [String], ["a"])
        XCTAssertEqual(split.json["message"] as? String, "a: Resumed; the resume message wasn't sent; 1 session has a name dch can no longer start")
        // No failed line anywhere: the merged exit names it already, once.
        XCTAssertEqual(DchControlOps.answer(all: [Self.dir(0, Self.okLine), Self.dir(3)], .resume), DchControlOps.error("1 resumed, failed (exit 3)"))
        // Restart all was an error already; its summary now names the silent dir too.
        let agent = #"{"name":"c","result":"failed","reason":"","detail":"c: no agent","session_id":"s"}"#
        XCTAssertEqual(DchControlOps.answer(all: [Self.dir(1, agent), Self.dir(2)], .restart), DchControlOps.error("1 failed, failed (exit 2)"))
    }
}
