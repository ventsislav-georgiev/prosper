import Network
import os
import XCTest
@testable import ProsperApp

/// #879: dch 1.55.0's cp_ctl (v1.57.0 rframe.c:70-81) also counts the bidi marks U+200E, U+200F, U+061C and
/// the separators U+2028, U+2029 as controls, so name_ok (:437-450) refuses a name holding one. Each path
/// dch serve checks a name on: 0x01/0x02 (v1.57.0 serve.c:1001-1006), 0x04/0x06 (serve.c:1174-1184), every
/// ctl name (ctl_name, rframe.c:560-569). Every dch is a recorder seam; frames go to sendOverride, the
/// NWConnection never starts.
final class DchNameCodePointTests: XCTestCase {
    private static let points: [Unicode.Scalar] = ["\u{200E}", "\u{200F}", "\u{061C}", "\u{2028}", "\u{2029}"]
    /// One name per code point, the point in the middle: "a<cp>b".
    private static func named(_ cp: Unicode.Scalar) -> String { "a" + String(Character(cp)) + "b" }
    private static func hex(_ cp: Unicode.Scalar) -> String { "U+" + String(cp.value, radix: 16, uppercase: true) }

    private static let invalid = DchControlOps.error(DchCtl.invalidName)
    private static let ok = DchFrame.encode(DchFrame.ok, [])

    private final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var frames: [Data] = []
        var spawned: [[String]] = []
        var killed: [String] = []
        var renamed: [[String]] = []
        var listed = 0
        var ctl = 0
        var closes = 0
    }

    private func rig(listed names: [String] = []) -> (DchConnection, DispatchQueue, Calls) {
        let queue = DispatchQueue(label: "test.dchconn.codepoint")
        let calls = Calls()
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"),
                                 onClose: { @Sendable _ in calls.lock.withLock { calls.closes += 1 } })
        conn.sendOverride = { f in calls.lock.withLock { calls.frames.append(f) } }
        conn.clipboard.enabled = { false }
        conn.commands.enabled = { false }
        let rows = names.map { DchListRow(name: $0, alias: "", activityEpoch: 1, state: "", agents: 0) }
        conn.listSessions = { calls.lock.withLock { calls.listed += 1 }; return rows }
        conn.kill = { n in calls.lock.withLock { calls.killed.append(n) } }
        conn.rename = { n, a in calls.lock.withLock { calls.renamed.append([n, a]) }; return nil }
        conn.spawn = { _, args, _, _, _, _ in
            calls.lock.withLock { calls.spawned.append(args) }
            throw PtyChild.PtyError.forkFailed
        }
        // The fake's call log: a ctl that got past every check would choose a dch here.
        conn.ctl.path = { calls.lock.withLock { calls.ctl += 1 }; return "/nonexistent/dch" }
        addTeardownBlock { queue.sync { conn.close() } }
        return (conn, queue, calls)
    }

    private func send(_ type: UInt8, _ payload: [String: Any], listed: [String] = []) -> Calls {
        let (conn, queue, calls) = rig(listed: listed)
        queue.sync { conn.ingest(DchFrame.encode(type, json: payload)) }
        return calls
    }

    // MARK: - The predicate

    /// Each of the five, alone, first, last or inside, is not name_ok; their neighbours still are (so the set
    /// is the five, not a range).
    func testNameOkRefusesEachOfTheFiveAndOnlyThem() {
        for cp in Self.points {
            let c = String(Character(cp))
            for name in [c, c + "work", "work" + c, Self.named(cp)] {
                XCTAssertFalse(DchCtl.nameOK(name), "\(Self.hex(cp)) in \(name.debugDescription)")
                XCTAssertEqual(DchCtl.nameRefusal(name), DchCtl.invalidName, "\(Self.hex(cp))")
            }
        }
        XCTAssertFalse(DchCtl.nameOK("a\u{200E}"))
        for ok in ["a\u{200D}b", "a\u{200B}b", "a\u{2010}b", "a\u{2027}b", "a\u{202F}b", "a\u{061B}b", "a\u{061D}b", "a\u{2030}b"] {
            XCTAssertTrue(DchCtl.nameOK(ok), "\(ok.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    // MARK: - 0x01 attach, 0x02 create

    /// serve.c:1001-1006: "invalid session name", before any dch call and before the list is read.
    func testAttachAndCreateRefuseEachBeforeAnyDchCall() {
        for type in [DchFrame.attach, DchFrame.create] {
            for cp in Self.points {
                let r = send(type, ["name": Self.named(cp), "command": ["claude"], "cols": 80, "rows": 24])
                let tag = "0x\(String(type, radix: 16)) \(Self.hex(cp))"
                r.lock.withLock {
                    XCTAssertEqual(r.frames, [Self.invalid], tag)
                    XCTAssertEqual(r.spawned, [], "no dch: \(tag)")
                    XCTAssertEqual(r.listed, 0, "no list read: \(tag)")
                }
            }
        }
    }

    /// A session that already holds one (started outside Remote Terminal: dch's own CLI does not check
    /// names) still goes out in the 0x11 list, as dch serve's rows_wire (v1.57.0 serve.c:328-395) does not
    /// filter names; an attach to it is refused as dch serve refuses it, before the list is read.
    func testAnExistingSessionStillListsButIsNotAttached() throws {
        for cp in Self.points {
            let name = Self.named(cp)
            let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: DchFrame.listPayload(
                [DchListRow(name: name, alias: "", activityEpoch: 1, state: "", agents: 0)])) as? [[String: Any]])
            XCTAssertEqual(rows.first?["name"] as? String, name, Self.hex(cp))
            let listed = send(DchFrame.list, [:], listed: [name])
            listed.lock.withLock {
                XCTAssertEqual(listed.frames, [DchFrame.encode(DchFrame.listResp, [UInt8](DchFrame.listPayload(
                    [DchListRow(name: name, alias: "", activityEpoch: 1, state: "", agents: 0)])))], Self.hex(cp))
            }
            let r = send(DchFrame.attach, ["name": name, "cols": 80, "rows": 24], listed: [name])
            r.lock.withLock {
                XCTAssertEqual(r.frames, [Self.invalid], Self.hex(cp))
                XCTAssertEqual(r.spawned, [])
                XCTAssertEqual(r.listed, 0)
            }
        }
    }

    // MARK: - 0x04 kill, 0x06 rename

    /// serve.c:1174-1184: no dch -m for such a name. dch serve answers the empty 0x14; Prosper says why (as it
    /// reports every rename it does not do, #811). The alias is not name_ok'd on either server.
    func testRenameRunsNoDchForEach() {
        for cp in Self.points {
            let r = send(DchFrame.rename, ["name": Self.named(cp), "alias": "Work"])
            r.lock.withLock {
                XCTAssertEqual(r.frames, [Self.invalid], Self.hex(cp))
                XCTAssertEqual(r.renamed, [], "no dch -m: \(Self.hex(cp))")
                XCTAssertEqual(r.listed, 0)
            }
            let alias = send(DchFrame.rename, ["name": "work", "alias": Self.named(cp)])
            alias.lock.withLock {
                XCTAssertEqual(alias.frames, [Self.ok], "an alias holding \(Self.hex(cp)) is dch's to store")
                XCTAssertEqual(alias.renamed, [["work", Self.named(cp)]])
            }
        }
        // A dash name keeps its #863 path: dch -m runs it (the alias is not id-shaped).
        let dash = send(DchFrame.rename, ["name": "-a\u{2028}b", "alias": "Work"])
        dash.lock.withLock { XCTAssertEqual(dash.renamed, [["-a\u{2028}b", "Work"]]) }
    }

    /// serve.c:1174-1184: no dch -k for such a name, and the empty 0x14 all the same (both servers).
    func testKillRunsNoDchForEach() {
        for cp in Self.points {
            let r = send(DchFrame.kill, ["name": Self.named(cp)])
            r.lock.withLock {
                XCTAssertEqual(r.frames, [Self.ok], Self.hex(cp))
                XCTAssertEqual(r.killed, [], "no dch -k: \(Self.hex(cp))")
            }
        }
        let plain = send(DchFrame.kill, ["name": "work"])
        plain.lock.withLock { XCTAssertEqual(plain.killed, ["work"], "a name_ok name is still killed") }
    }

    // MARK: - ctl

    /// Every allowlisted verb that takes a name, each name position (ctl_name, rframe.c:560-569, from
    /// ctl_check :689, :726, :761): the refusal, then over the wire one 0x13 and the FIN, no dch chosen.
    private static func argvs(_ n: String) -> [[String]] {
        [["--read", n], ["--read", n, "--ansi"], ["--send", n, "hi"], ["--run", n, "hi"], ["--keys", n, "Enter"],
         ["--follow", n], ["--status", n], ["-k", n], ["-m", n, "Work"], ["-d", n], ["--spawn", n, "--", "/bin/sh"],
         ["--revive", n, "--json"], ["--revive", "work", "--as", n, "--json"],
         ["--pin", n, "--json"], ["--pin", "work", n, "--json"], ["--unpin", n, "--json"], ["--forget", n, "--json"],
         ["--stop", "work", n, "--json"], ["--say", n, "--json", "--", "hi"]]
    }

    func testEveryCtlNameRefusesEach() {
        for cp in Self.points {
            for argv in Self.argvs(Self.named(cp)) {
                let tag = "\(argv[0]) \(Self.hex(cp)) \(argv.count)"
                XCTAssertEqual(DchCtl.refusal(argv, create: true), DchCtl.invalidName, tag)
                let r = send(DchFrame.ctl, ["argv": argv])
                r.lock.withLock {
                    XCTAssertEqual(r.frames, [Self.invalid], tag)
                    XCTAssertEqual(r.closes, 1, "then the FIN: \(tag)")
                    XCTAssertEqual(r.ctl, 0, "no dch chosen: \(tag)")
                    XCTAssertEqual(r.listed, 0, tag)
                }
            }
            // --xray: its own name check once the op is on; while it is off (always under XCTest) the off reply first.
            let xray = ["--xray", Self.named(cp), "--json"]
            XCTAssertEqual(DchCtl.refusal(xray, create: true), DchCtl.invalidName, Self.hex(cp))
        }
    }

    // MARK: - QA #741 riders

    private func sendRaw(_ type: UInt8, _ bytes: [UInt8]) -> Calls {
        let (conn, queue, calls) = rig()
        queue.sync { conn.ingest(DchFrame.encode(type, bytes)) }
        return calls
    }

    /// R1: serve's rq_json (v1.57.0 serve.c:142-159) refuses a payload that is not a JSON object, or holds a NUL,
    /// with "malformed attach request" / "malformed create request" (:986-991) before any dch; empty reads as {}.
    func testAPayloadThatIsNoJSONObjectIsMalformed() {
        for (type, why) in [(DchFrame.attach, "malformed attach request"), (DchFrame.create, "malformed create request")] {
            for raw in ["not json", "[1]", "\"work\"", "{\"name\":\"work\"", "{\"name\":\"work\"}\u{0}"] {
                let r = sendRaw(type, Array(raw.utf8))
                r.lock.withLock {
                    XCTAssertEqual(r.frames, [DchControlOps.error(why)], "0x\(String(type, radix: 16)) \(raw.debugDescription)")
                    XCTAssertEqual(r.spawned, [], raw.debugDescription)
                    XCTAssertEqual(r.listed, 0)
                    XCTAssertEqual(r.closes, 0, "the connection stays open, as serve's out_err")
                }
            }
        }
        let attach = sendRaw(DchFrame.attach, []), create = sendRaw(DchFrame.create, [])
        attach.lock.withLock { XCTAssertEqual(attach.frames, [DchControlOps.error(DchConnection.needsName)], "empty is {}") }
        create.lock.withLock { XCTAssertEqual(create.spawned, [["-E"]], "empty is {}: a nameless create runs") }
    }

    /// #879 r2: JSONSerialization detects the encoding, so {"name":"work"} in UTF-16 LE/BE (with or without a BOM),
    /// UTF-32 LE/BE and UTF-32 BE with a BOM parse into an object, NUL bytes and all. serve's rq_json refuses any
    /// payload holding a NUL byte (`memchr(p, 0, n)`, v1.57.0 serve.c:148) as malformed (:986-991), so these
    /// must be too: the NUL test, not the parse, is what refuses them. (UTF-32 LE with a BOM does not parse; the
    /// first case below is that it is not why.)
    func testAWideEncodedObjectIsMalformed() {
        let json = #"{"name":"work"}"#
        func wide(_ e: String.Encoding, _ bom: [UInt8] = []) -> [UInt8] { bom + [UInt8](json.data(using: e)!) }
        let payloads: [(String, [UInt8])] = [
            ("utf16le", wide(.utf16LittleEndian)), ("utf16le+BOM", wide(.utf16LittleEndian, [0xff, 0xfe])),
            ("utf16be", wide(.utf16BigEndian)), ("utf16be+BOM", wide(.utf16BigEndian, [0xfe, 0xff])),
            ("utf32le", wide(.utf32LittleEndian)), ("utf32be", wide(.utf32BigEndian)),
            ("utf32be+BOM", wide(.utf32BigEndian, [0, 0, 0xfe, 0xff])),
        ]
        for (label, bytes) in payloads {
            let parsed = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any]
            XCTAssertEqual(parsed?["name"] as? String, "work", "\(label) parses, so only the NUL test refuses it")
            for (type, why) in [(DchFrame.attach, "malformed attach request"), (DchFrame.create, "malformed create request")] {
                let r = sendRaw(type, bytes)
                r.lock.withLock {
                    XCTAssertEqual(r.frames, [DchControlOps.error(why)], "0x\(String(type, radix: 16)) \(label)")
                    XCTAssertEqual(r.spawned, [], label)
                    XCTAssertEqual(r.listed, 0, label)
                    XCTAssertEqual(r.closes, 0, "the connection stays open: \(label)")
                }
            }
        }
    }

    /// #879 r2: a "\u0000" escape holds no NUL byte and parses on both sides, but dch's decoder refuses a decoded
    /// NUL (utf8_ok, v1.57.0 json.c:48-53), so jstr fails and serve answers "attach needs a session name"
    /// (v1.57.0 serve.c:992-998: r < 0) for a create too, before name_ok.
    func testAnEscapedNulNameNeedsAName() {
        for type in [DchFrame.attach, DchFrame.create] {
            let r = sendRaw(type, Array(#"{"name":"wo\u0000rk"}"#.utf8))
            r.lock.withLock {
                XCTAssertEqual(r.frames, [DchControlOps.error(DchConnection.needsName)], "0x\(String(type, radix: 16))")
                XCTAssertEqual(r.spawned, [])
                XCTAssertEqual(r.listed, 0)
            }
        }
    }

    /// R2: 0x04's dash test is the first byte (v1.57.0 serve.c:1164-1168), as attach's and create's: "-" + U+0301
    /// is one Character, which a hasPrefix("-") test let through to dch -k.
    func testKillsDashTestIsTheFirstByte() {
        for name in ["-\u{301}x", "-x", "--all"] {
            let r = send(DchFrame.kill, ["name": name])
            r.lock.withLock {
                XCTAssertEqual(r.frames, [DchControlOps.error(DchControlOps.dashNameRefusal)], name.debugDescription)
                XCTAssertEqual(r.killed, [], name.debugDescription)
            }
        }
    }

    /// R3: an attach that starts a session names an interactive Claude after it, as a create does (#877).
    func testAnAttachStartingClaudeIsNamedToo() {
        let r = send(DchFrame.attach, ["name": "work", "command": ["claude"], "cols": 80, "rows": 24])
        r.lock.withLock { XCTAssertEqual(r.spawned, [["-E", "-f", "-n", "work", "--", "claude", "--name", "work"]]) }
    }

    /// #879 rider: serve's ':' test is strchr (v1.57.0 serve.c:1246-1254), a byte; ":" then a combining
    /// mark is one Character, which a Character test misses and the child dch still reads as host:name.
    func testTheColonTestIsTheByte() {
        XCTAssertFalse("a:\u{301}b".contains(Character(":")), "the grapheme trap this guards against")
        XCTAssertEqual(DchCtl.nameRefusal("a:\u{301}b"), DchCtl.localOnly)
        XCTAssertEqual(DchCtl.refusal(["--read", "a:\u{301}b"], create: true), DchCtl.localOnly)
    }
}
