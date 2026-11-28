import Network
import os
import XCTest
@testable import ProsperApp

/// #1756: 0x2f groupsSync, the session groups the phone shows (contract agreed with prosper-ios 2026-11-20), the groups
/// stamp, and the 0x2e watch frame carrying them. Preferences is the in-memory XCTest store; each row puts the keys back.
/// No socket, no dch: the handler and DchConnection's sendOverride seam.
final class GroupsSyncTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var frames: [Data] = []
        var adopts = 0
    }

    private static let keys = ["agentIslandSessionGroups", "agentIslandSidekickPattern", "agentIslandSidekickPatternUpdated",
                               "agentIslandSessionGroupsUpdated", "agentIslandSidekickTabs"]

    override func setUp() {
        super.setUp()
        XCTAssertTrue(Preferences.defaults is XCTestDefaults, "the scratch in-memory suite, never the app's")
        let saved = Self.keys.map { Preferences.defaults.object(forKey: $0) }
        addTeardownBlock {
            for (k, v) in zip(Self.keys, saved) {
                if let v { Preferences.defaults.set(v, forKey: k) } else { Preferences.defaults.removeObject(forKey: k) }
            }
        }
        Self.keys.forEach(Preferences.defaults.removeObject(forKey:))
    }

    private static func g(_ id: String, _ name: String, _ pattern: String) -> SessionGroup {
        SessionGroup(id: id, name: name, pattern: pattern)
    }

    private static func body(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }
    private static func body(_ s: String) -> Data { Data(s.utf8) }

    private static func decode(_ f: Data) -> (type: UInt8, json: NSDictionary) {
        (f.first ?? 0, ((try? JSONSerialization.jsonObject(with: f.dropFirst(5))) as? NSDictionary) ?? [:])
    }

    private static func object(_ s: String) -> NSDictionary {
        ((try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? NSDictionary) ?? ["unparsed": s]
    }

    /// One request through the handler (adopt counted, not run); exactly one reply.
    private func call(_ payload: Data, file: StaticString = #filePath, line: UInt = #line) -> (type: UInt8, json: NSDictionary, adopts: Int) {
        let box = Box(), replied = expectation(description: "reply")
        var ops = DchGroupsOps()
        ops.adopted = { box.lock.withLock { box.adopts += 1 } }
        ops.handle(payload) { f in box.lock.withLock { box.frames.append(f) }; replied.fulfill() }
        wait(for: [replied], timeout: 5)
        let (frames, adopts) = box.lock.withLock { (box.frames, box.adopts) }
        XCTAssertEqual(frames.count, 1, "one reply", file: file, line: line)
        let r = Self.decode(frames.first ?? Data())
        return (r.type, r.json, adopts)
    }

    private static let macList = [g(SessionGroup.sidekicksID, "Sidekicks", "-qa"), g("r1", "Reviews", "-rev$")]

    private func stored() -> DchGroupsOps.Value { DchGroupsOps.current() }

    // MARK: - Wire

    func testFrameByteAndOps() {
        XCTAssertEqual(DchFrame.groupsSync, 0x2f)
        XCTAssertTrue((DchFrame.machineInfo(deviceID: "i", hostname: "h", wakeId: nil)["ops"] as? [String] ?? []).contains("groups"),
                      "always advertised")
    }

    /// The contract's ok example, byte for byte once parsed: the migrated default list, never edited.
    func testContractOkExampleForTheDefaultList() {
        let r = call(Self.body("{}"))
        XCTAssertEqual(r.type, 0x14)
        XCTAssertEqual(r.json, Self.object(#"{"groups":[{"id":"sidekicks","name":"Sidekicks","pattern":"-qa"}],"updated":0}"#))
        XCTAssertEqual(r.adopts, 0)
        XCTAssertTrue(Preferences.defaults.object(forKey: "agentIslandSessionGroups") == nil, "a read writes nothing")
        XCTAssertTrue(Preferences.defaults.object(forKey: "agentIslandSessionGroupsUpdated") == nil)
    }

    func testReadAnswersTheMacListAndStamp() {
        Preferences.agentIslandSessionGroups = Self.macList
        Preferences.agentIslandSessionGroupsUpdated = 1_784_995_200_000
        for read in [Self.body("{}"), Self.body(["updated": 9]), Self.body(["other": "x"])] {
            let r = call(read)
            XCTAssertEqual(r.type, DchFrame.ok)
            XCTAssertEqual(r.json, Self.object(#"{"groups":[{"id":"sidekicks","name":"Sidekicks","pattern":"-qa"},"#
                + #"{"id":"r1","name":"Reviews","pattern":"-rev$"}],"updated":1784995200000}"#))
            XCTAssertEqual(r.adopts, 0)
        }
        Preferences.agentIslandSessionGroups = []
        XCTAssertEqual(call(Self.body("{}")).json, Self.object(#"{"groups":[],"updated":1784995200000}"#), "[] = no split")
    }

    // MARK: - The stamp

    func testTheStampReadsTheSidekickStampUntilAListIsSaved() {
        XCTAssertEqual(Preferences.agentIslandSessionGroupsUpdated, 0, "never edited")
        Preferences.agentIslandSidekickPatternUpdated = 42
        XCTAssertEqual(Preferences.agentIslandSessionGroupsUpdated, 42, "before a list is stored: the sidekick stamp")
        Preferences.agentIslandSessionGroupsUpdated = 7
        XCTAssertEqual(Preferences.agentIslandSessionGroupsUpdated, 7, "its own once set")
        XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, 42, "0x2d's stamp stays")
    }

    @MainActor
    func testEditorSaveMovesTheGroupsStampAndTheSidekickStampOnlyForGroupZero() {
        Preferences.agentIslandSessionGroups = Self.macList
        var e = SessionGroupsEditor()
        guard e.rows.count == 2 else { return XCTFail("the stored list") }
        e.rows[1].pattern = "-review$"   // a second group's edit
        SessionGroupsEditor.save(e, now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(Preferences.agentIslandSessionGroupsUpdated, 1_000_000_000, "every list save stamps now")
        XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, 0, "group 0 did not change: 0x2d's stamp stays")
        SessionGroupsEditor.save(e, now: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertEqual(Preferences.agentIslandSessionGroupsUpdated, 1_000_000_000, "an unchanged editor stores and stamps nothing")
        e.rows[0].pattern = "-test$"
        SessionGroupsEditor.save(e, now: Date(timeIntervalSince1970: 500_000))   // a clock behind the stamp
        XCTAssertEqual(Preferences.agentIslandSessionGroupsUpdated, 1_000_000_001, "one past the stored stamp")
        XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, 500_000_000, "group 0 changed: 0x2d's stamp moves as before")
    }

    /// 0x2d still carries and adopts group 0's pattern; its adopt edits the list, so the groups stamp follows (never back).
    func testSidekickAdoptStillMirrorsGroupZeroAndMovesTheGroupsStamp() {
        Preferences.agentIslandSessionGroups = Self.macList
        Preferences.agentIslandSessionGroupsUpdated = 50
        Preferences.adoptSidekickPattern("-phone$", updated: 99)
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.pattern), ["-phone$", "-rev$"])
        XCTAssertEqual(DchSidekickOps.current(), .init(pattern: "-phone$", updated: 99))
        XCTAssertEqual(Preferences.agentIslandSessionGroupsUpdated, 99)
        Preferences.agentIslandSessionGroupsUpdated = 500
        Preferences.adoptSidekickPattern("-p2$", updated: 120, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(Preferences.agentIslandSessionGroupsUpdated, 501,
                       "#1777 n95: group 0 rewritten under a later groups stamp: it moves as an edit, so the phone re-reads")
        XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, 120)
        Preferences.adoptSidekickPattern("-p2$", updated: 130, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(Preferences.agentIslandSessionGroupsUpdated, 501, "the same pattern rewrites nothing: the stamp stays")
        Preferences.adoptSidekickPattern("-p3$", updated: 501, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(Preferences.agentIslandSessionGroupsUpdated, 502, "a tie moves it too")
    }

    /// #1777 (QA b1): a 0x2f adopt that changes group 0 moves the sidekick stamp, so a 0x2d write stamped between the
    /// two stamps loses against the newer list instead of rewriting its group 0.
    func testGroupsAdoptChangingGroupZeroMovesTheSidekickStampSoAnOlderSidekickWriteLoses() {
        Preferences.agentIslandSessionGroups = Self.macList
        Preferences.agentIslandSessionGroupsUpdated = 100
        Preferences.agentIslandSidekickPatternUpdated = 50
        XCTAssertEqual(call(Self.body(#"{"groups":[{"id":"q","name":"QA","pattern":"-qa$"}],"updated":101}"#)).adopts, 1)
        XCTAssertEqual(DchSidekickOps.current(), .init(pattern: "-qa$", updated: 101))
        let box = Box(), replied = expectation(description: "reply")
        var ops = DchSidekickOps()
        ops.adopted = { box.lock.withLock { box.adopts += 1 } }
        ops.handle(Self.body(#"{"pattern":"-old$","updated":70}"#)) { f in box.lock.withLock { box.frames.append(f) }; replied.fulfill() }
        wait(for: [replied], timeout: 5)
        let r = Self.decode(box.lock.withLock { box.frames.first ?? Data() })
        XCTAssertEqual(r.json, Self.object(#"{"pattern":"-qa$","updated":101}"#), "the newer list's group 0 wins")
        XCTAssertEqual(box.lock.withLock { box.adopts }, 0)
        XCTAssertEqual(stored(), .init(groups: [Self.g("q", "QA", "-qa$")], updated: 101), "the list is untouched")
        // A list whose group 0 is unchanged leaves the sidekick stamp alone; it never moves back.
        XCTAssertEqual(call(Self.body(#"{"groups":[{"id":"q","name":"QA","pattern":"-qa$"},{"id":"r","name":"R","pattern":"-r"}],"updated":102}"#)).adopts, 1)
        XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, 101)
        Preferences.agentIslandSidekickPatternUpdated = 900
        XCTAssertEqual(call(Self.body(#"{"groups":[{"id":"q","name":"QA","pattern":"-new$"}],"updated":103}"#)).adopts, 1)
        XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, 900, "max(itself, updated)")
    }

    // MARK: - Merge

    func testANewerPhoneWriteIsAdopted() {
        Preferences.agentIslandSessionGroups = Self.macList
        Preferences.agentIslandSessionGroupsUpdated = 100
        Preferences.agentIslandSidekickPatternUpdated = 50
        let r = call(Self.body(#"{"groups":[{"id":"q","name":" QA ","pattern":"-qa$","color":"red"}],"updated":101,"device_id":"x"}"#))
        XCTAssertEqual(r.type, DchFrame.ok)
        XCTAssertEqual(r.json, Self.object(#"{"groups":[{"id":"q","name":"QA","pattern":"-qa$"}],"updated":101}"#),
                       "the winner, name trimmed, unknown keys ignored")
        XCTAssertEqual(r.adopts, 1)
        XCTAssertEqual(stored(), .init(groups: [Self.g("q", "QA", "-qa$")], updated: 101), "the phone's list and stamp, never now")
        XCTAssertEqual(DchSidekickOps.current(), .init(pattern: "-qa$", updated: 101), "0x2d mirrors group 0; #1777 b1: its stamp moves")
        let empty = call(Self.body(#"{"groups":[],"updated":102}"#))
        XCTAssertEqual(empty.json, Self.object(#"{"groups":[],"updated":102}"#))
        XCTAssertEqual(stored(), .init(groups: [], updated: 102))
        XCTAssertEqual(Preferences.agentIslandSidekickPattern, "", "no groups: an empty sidekick pattern")
    }

    func testAnOlderOrTiedWriteIsAnsweredWithTheMacs() {
        Preferences.agentIslandSessionGroups = Self.macList
        Preferences.agentIslandSessionGroupsUpdated = 100
        for t in [99, 100] {
            let r = call(Self.body(["groups": [["id": "q", "name": "QA", "pattern": "-qa$"]], "updated": t]))
            XCTAssertEqual(r.type, DchFrame.ok)
            XCTAssertEqual(r.json, DchGroupsOps.Value(groups: Self.macList, updated: 100).json as NSDictionary, "\(t)")
            XCTAssertEqual(r.adopts, 0, "\(t)")
        }
        XCTAssertEqual(stored(), .init(groups: Self.macList, updated: 100))
        // Both never edited: the Mac's.
        Preferences.defaults.removeObject(forKey: "agentIslandSessionGroupsUpdated")
        XCTAssertEqual(call(Self.body(#"{"groups":[],"updated":0}"#)).adopts, 0)
    }

    // MARK: - Errors

    func testEveryMalformedOrOverLimitWriteGetsItsExactErrorAndChangesNothing() {
        Preferences.agentIslandSessionGroups = Self.macList
        Preferences.agentIslandSessionGroupsUpdated = 100
        let malformed = "malformed groupsSync request: send {} to read, or {\"groups\": [...], \"updated\": <ms>}"
        func grp(_ id: Any = "a", _ name: Any = "A", _ pattern: Any = "-a") -> [String: Any] { ["id": id, "name": name, "pattern": pattern] }
        let long = String(repeating: "é", count: 256) + "x"   // 513 bytes
        let cases: [(Data, String)] = [
            (Self.body(""), malformed), (Self.body("[]"), malformed), (Self.body("nope"), malformed),
            (Self.body(["groups": "x", "updated": 200]), malformed), (Self.body(["groups": NSNull(), "updated": 200]), malformed),
            (Self.body(["groups": [grp()]]), malformed), (Self.body(["groups": [grp()], "updated": "200"]), malformed),
            (Self.body(["groups": [grp()], "updated": true]), malformed), (Self.body(["groups": [grp()], "updated": 200.5]), malformed),
            (Self.body(["groups": ["x"], "updated": 200]), malformed), (Self.body(["groups": [grp(1)], "updated": 200]), malformed),
            (Self.body(["groups": [grp("a", NSNull())], "updated": 200]), malformed),
            (Self.body(["groups": [grp("a", "A", 5)], "updated": 200]), malformed),
            (Self.body(["groups": [["id": "a", "name": "A"]], "updated": 200]), malformed),
            (Self.body(["groups": [grp("")], "updated": 200]), malformed),
            (Self.body(["groups": [grp(String(repeating: "a", count: 65))], "updated": 200]), malformed),
            (Self.body(["groups": [grp("a b")], "updated": 200]), malformed), (Self.body(["groups": [grp("é")], "updated": 200]), malformed),
            (Self.body(["groups": (1...9).map { grp("g\($0)", "G\($0)") }, "updated": 200]), "more than 8 groups"),
            (Self.body(["groups": [grp("a", "")], "updated": 200]), "group name must be 1-32 UTF-8 bytes without = or control characters"),
            (Self.body(["groups": [grp("a", "  ")], "updated": 200]), "group name must be 1-32 UTF-8 bytes without = or control characters"),
            (Self.body(["groups": [grp("a", "a=b")], "updated": 200]), "group name must be 1-32 UTF-8 bytes without = or control characters"),
            (Self.body(["groups": [grp("a", "a\tb")], "updated": 200]), "group name must be 1-32 UTF-8 bytes without = or control characters"),
            (Self.body(["groups": [grp("a", String(repeating: "é", count: 17))], "updated": 200]),
             "group name must be 1-32 UTF-8 bytes without = or control characters"),
            (Self.body(["groups": [grp("a", "A"), grp("a", "B")], "updated": 200]), "duplicate group id or name"),
            (Self.body(["groups": [grp("a", "QA"), grp("b", " qa ")], "updated": 200]), "duplicate group id or name"),
            (Self.body(["groups": [grp("a", "A", long)], "updated": 200]), "group pattern over 512 UTF-8 bytes"),
            // #1777 n99: the 9th item ends the walk: the malformed ones after it are never read.
            (Self.body(["groups": (1...8).map { grp("g\($0)", "G\($0)") as Any } + Array(repeating: "x" as Any, count: 10_000), "updated": 200]),
             "more than 8 groups"),
            // An older write is checked too.
            (Self.body(["groups": (1...9).map { grp("g\($0)", "G\($0)") }, "updated": 1]), "more than 8 groups"),
        ]
        for (i, (payload, message)) in cases.enumerated() {
            let r = call(payload)
            XCTAssertEqual(r.type, DchFrame.error, "case \(i)")
            XCTAssertEqual(r.json, ["message": message] as NSDictionary, "case \(i)")
            XCTAssertEqual(r.adopts, 0, "case \(i)")
        }
        XCTAssertEqual(stored(), .init(groups: Self.macList, updated: 100), "nothing changed")
        // The limits' edges are accepted.
        let ok = call(Self.body(["groups": [grp(String(repeating: "a", count: 64), String(repeating: "é", count: 16),
                                               String(repeating: "é", count: 256))] + (2...8).map { grp("g\($0)", "G\($0)") },
                                 "updated": 300]))
        XCTAssertEqual(ok.type, DchFrame.ok)
        XCTAssertEqual(stored().groups.count, 8)
        XCTAssertEqual(stored().updated, 300)
    }

    /// #1777 (QA n96): the limits guard the adopt only. An echo of a Mac list over them (a tie or an older write) is
    /// answered with the Mac's list; the same list winning is refused.
    func testLimitsAreCheckedOnlyWhenThePhoneWins() {
        let big = String(repeating: "p", count: 600)
        Preferences.agentIslandSessionGroups = [Self.g("a", "A", big)]
        Preferences.agentIslandSessionGroupsUpdated = 100
        let mac = DchGroupsOps.Value(groups: [Self.g("a", "A", big)], updated: 100).json as NSDictionary
        for t in [100, 99] {
            let echo = call(Self.body(["groups": [["id": "a", "name": "A", "pattern": big]], "updated": t]))
            XCTAssertEqual(echo.type, DchFrame.ok, "\(t)")
            XCTAssertEqual(echo.json, mac, "\(t)")
            let older = call(Self.body(["groups": [["id": "a", "name": "a=b", "pattern": ""], ["id": "b", "name": "A", "pattern": "-b"]], "updated": t]))
            XCTAssertEqual(older.json, mac, "an older write over every limit: the Mac's list, \(t)")
        }
        let win = call(Self.body(["groups": [["id": "a", "name": "A", "pattern": big]], "updated": 101]))
        XCTAssertEqual(win.type, DchFrame.error)
        XCTAssertEqual(win.json, ["message": "group pattern over 512 UTF-8 bytes"] as NSDictionary)
        XCTAssertEqual(win.adopts, 0)
        XCTAssertEqual(stored().updated, 100)
    }

    /// The contract's error example, byte for byte once parsed.
    func testContractErrorExample() {
        let r = call(Self.body("not json"))
        XCTAssertEqual(r.json, Self.object(#"{"message":"malformed groupsSync request: send {} to read, or {\"groups\": [...], \"updated\": <ms>}"}"#))
    }

    // MARK: - The live adopt

    @MainActor
    func testLiveAdoptPostsTheSettingsNotification() throws {
        try XCTSkipIf(AgentIslandController.shared.store != nil, "an island store is up: keep its panel untouched")
        let seen = expectation(forNotification: .sidekickPatternChangedExternally, object: nil) { _ in
            Thread.isMainThread && Preferences.agentIslandSessionGroups.map(\.id) == ["n"]
        }
        let replied = expectation(description: "reply")
        DchGroupsOps().handle(Self.body(#"{"groups":[{"id":"n","name":"N","pattern":"-n$"}],"updated":3}"#)) { _ in replied.fulfill() }
        wait(for: [seen, replied], timeout: 5)
    }

    // MARK: - The watch frame

    /// The contract's watch example: "sidekick" mirrors group 0 beside "groups", what 0x2f answers.
    /// #2069: a blank pattern is a manual-only group (#2062): the push is adopted with it, a phone echoing the Mac's list
    /// works, and the other checks (a bad name, a duplicate) still refuse. Red at base: "group pattern must not be blank".
    func testABlankPatternIsAcceptedAsAManualOnlyGroup() {
        Preferences.agentIslandSessionGroups = Self.macList
        Preferences.agentIslandSessionGroupsUpdated = 100
        let list = [["id": "sidekicks", "name": "Sidekicks", "pattern": "-qa"], ["id": "m1", "name": "Manual", "pattern": ""],
                    ["id": "m2", "name": "Spaces", "pattern": " \n "]]
        let r = call(Self.body(["groups": list, "updated": 200]))
        XCTAssertEqual(r.type, DchFrame.ok)
        XCTAssertEqual(r.adopts, 1)
        XCTAssertEqual(stored().groups.map(\.pattern), ["-qa", "", " \n "])
        XCTAssertTrue(stored().groups.dropFirst().allSatisfy(\.isManual))
        let bad = call(Self.body(["groups": [["id": "m1", "name": "a=b", "pattern": ""]], "updated": 300]))
        XCTAssertEqual(bad.json, ["message": DchGroupsOps.badName] as NSDictionary)
        let dup = call(Self.body(["groups": [["id": "m1", "name": "A", "pattern": ""], ["id": "m2", "name": "a", "pattern": ""]], "updated": 300]))
        XCTAssertEqual(dup.json, ["message": DchGroupsOps.duplicate] as NSDictionary)
        XCTAssertEqual(stored().updated, 200, "refused: nothing changed")
    }

    /// #2069 (QA n9): a blank legacy Sidekicks (isOff) is kept in the stored list, as an old phone sent it, but neither the
    /// reply nor the watch frame shows it. Red at base: it is listed.
    func testABlankSidekicksIsKeptStoredAndNeverSent() {
        Preferences.agentIslandSessionGroups = Self.macList
        Preferences.agentIslandSessionGroupsUpdated = 100
        let r = call(Self.body(["groups": [["id": "sidekicks", "name": "Sidekicks", "pattern": ""], ["id": "m1", "name": "Manual", "pattern": ""]],
                                "updated": 200]))
        XCTAssertEqual(r.json, Self.object(#"{"groups":[{"id":"m1","name":"Manual","pattern":""}],"updated":200}"#), "the reply")
        XCTAssertEqual(stored().groups.map(\.id), ["sidekicks", "m1"], "stored unchanged")
        let f = Self.decode(DchSidekickOps.watchFrame(DchSidekickOps.current(), groups: DchGroupsOps.current())).json
        XCTAssertEqual((f["groups"] as? NSDictionary)?["groups"] as? NSArray, [["id": "m1", "name": "Manual", "pattern": ""]] as NSArray, "the watch frame")
        XCTAssertEqual(call(Self.body("{}")).json, Self.object(#"{"groups":[{"id":"m1","name":"Manual","pattern":""}],"updated":200}"#), "a read")
    }

    /// #2069 (QA n1): 0x2d reads and writes the first non-manual group, not group 0. Red at base: it reads "" and the adopt
    /// patterns the manual group.
    func testLegacySidekickPatternIsTheFirstNonManualGroup() {
        Preferences.agentIslandSessionGroups = [Self.g("m1", "Manual", ""), Self.g("r1", "Reviews", "-rev$")]
        XCTAssertEqual(Preferences.agentIslandSidekickPattern, "-rev$")
        Preferences.adoptSidekickPattern("-phone$", updated: 99)
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.pattern), ["", "-phone$"])
        Preferences.editSessionGroups([Self.g("m1", "Manual", ""), Self.g("r1", "Reviews", "-x$")], now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.pattern), ["", "-x$"], "an editor save does not write the pattern into the manual group")
        Preferences.agentIslandSessionGroups = [Self.g("m1", "Manual", "")]
        XCTAssertEqual(Preferences.agentIslandSidekickPattern, "")
        Preferences.adoptSidekickPattern("-p$", updated: 120)
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.id), ["m1", SessionGroup.sidekicksID])
        XCTAssertEqual(Preferences.agentIslandSessionGroups.first?.pattern, "", "the manual group stays manual")
    }

    /// One 0x2d request through DchSidekickOps (adopt counted, not run); exactly one reply.
    private func sidekick(_ pattern: String, _ updated: Int64, file: StaticString = #filePath, line: UInt = #line) -> (type: UInt8, json: NSDictionary) {
        let box = Box(), replied = expectation(description: "reply")
        var ops = DchSidekickOps()
        ops.adopted = { box.lock.withLock { box.adopts += 1 } }
        ops.handle(Self.body(["pattern": pattern, "updated": updated])) { f in box.lock.withLock { box.frames.append(f) }; replied.fulfill() }
        wait(for: [replied], timeout: 5)
        let frames = box.lock.withLock { box.frames }
        XCTAssertEqual(frames.count, 1, "one reply", file: file, line: line)
        return Self.decode(frames.first ?? Data())
    }

    /// #2069 round 2 (QA R2069a F1): an old phone clearing the group 0x2d points at, when another group has a pattern,
    /// is refused with an error and nothing stored changes, so 0x2d does not hop to that group. Red without the refusal:
    /// the reply is ok, Reviews turns manual and the read gives "-qa$".
    func testALegacyClearThatWouldMoveToAnotherGroupIsRefused() {
        let list = [Self.g("r1", "Reviews", "-rev$"), Self.g("q1", "QA", "-qa$")]
        Preferences.agentIslandSessionGroups = list
        Preferences.agentIslandSessionGroupsUpdated = 50
        Preferences.agentIslandSidekickPatternUpdated = 50
        let r = sidekick("", 99)
        XCTAssertEqual(r.type, DchFrame.error)
        XCTAssertEqual(r.json, ["message": Preferences.legacyClearRefused] as NSDictionary)
        XCTAssertEqual(sidekick(" \n", 100).json, ["message": Preferences.legacyClearRefused] as NSDictionary, "whitespace is a clear")
        XCTAssertEqual(Preferences.agentIslandSessionGroups, list, "stored unchanged")
        XCTAssertEqual(DchSidekickOps.current(), .init(pattern: "-rev$", updated: 50))
        XCTAssertEqual(Preferences.agentIslandSessionGroupsUpdated, 50)
        Preferences.agentIslandSidekickPattern = ""
        XCTAssertEqual(Preferences.agentIslandSessionGroups, list, "a Mac-side write of the setter cannot hop it either")
        XCTAssertEqual(sidekick("-r$", 101).type, DchFrame.ok, "a non-blank edit still lands")
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.pattern), ["-r$", "-qa$"])
    }

    /// #2069 round 2: clearing Sidekicks is allowed (it turns isOff and 0x2d stays on it), and so is clearing the only
    /// non-manual group (it turns manual, 0x2d reads ""). Red with the refusal widened to every clear.
    func testALegacyClearOfSidekicksOrOfTheOnlyPatternedGroupIsAllowed() {
        Preferences.agentIslandSessionGroups = [Self.g(SessionGroup.sidekicksID, "Sidekicks", "-s"), Self.g("q1", "QA", "-qa$")]
        XCTAssertEqual(sidekick("", 99).type, DchFrame.ok)
        XCTAssertEqual(Preferences.agentIslandSidekickPattern, "")
        XCTAssertEqual(sidekick("x", 100).type, DchFrame.ok)
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.pattern), ["x", "-qa$"], "the next set lands on Sidekicks")
        Preferences.agentIslandSessionGroups = [Self.g("r1", "Reviews", "-rev$"), Self.g("m1", "Manual", "")]
        XCTAssertEqual(sidekick("", 200).type, DchFrame.ok)
        XCTAssertEqual(Preferences.agentIslandSidekickPattern, "")
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.pattern), ["", ""])
    }

    /// #2069 round 2 (QA n10a): with no patterned group and a manual group named Sidekicks, the appended Sidekicks would be
    /// dropped by normalized (one name per section); the write is refused instead of lost silently. Red without it: ok.
    func testALegacyWriteIsRefusedWhenAManualGroupHoldsTheNameSidekicks() {
        let list = [Self.g("m1", "sidekicks ", "")]
        Preferences.agentIslandSessionGroups = list
        let r = sidekick("-p$", 99)
        XCTAssertEqual(r.type, DchFrame.error)
        XCTAssertEqual(r.json, ["message": Preferences.legacySidekicksNameTaken] as NSDictionary)
        XCTAssertEqual(Preferences.agentIslandSessionGroups, [Self.g("m1", "sidekicks", "")], "stored unchanged")
        XCTAssertEqual(sidekick("", 100).type, DchFrame.ok, "a clear adds nothing, so it is no loss")
        Preferences.agentIslandSessionGroups = [Self.g("m1", "Manual", "")]
        XCTAssertEqual(sidekick("-p$", 101).type, DchFrame.ok, "another name: Sidekicks is appended")
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.id), ["m1", SessionGroup.sidekicksID])
    }

    func testWatchFrameCarriesSidekickAndGroups() {
        Preferences.agentIslandSessionGroups = Self.macList
        Preferences.agentIslandSidekickPatternUpdated = 5
        Preferences.agentIslandSessionGroupsUpdated = 6
        let f = DchSidekickOps.watchFrame(DchSidekickOps.current(), groups: DchGroupsOps.current())
        XCTAssertEqual(f.first, DchFrame.ok)
        XCTAssertEqual(Self.decode(f).json, Self.object(#"{"sidekick":{"pattern":"-qa","updated":5},"#
            + #""groups":{"groups":[{"id":"sidekicks","name":"Sidekicks","pattern":"-qa"},{"id":"r1","name":"Reviews","pattern":"-rev$"}],"updated":6}}"#))
        Preferences.agentIslandSessionGroups = []
        let none = Self.decode(DchSidekickOps.watchFrame(DchSidekickOps.current(), groups: DchGroupsOps.current())).json
        XCTAssertEqual(none, Self.object(#"{"sidekick":{"pattern":"","updated":5},"groups":{"groups":[],"updated":6}}"#),
                       "no groups: an empty sidekick pattern")
    }

    // MARK: - Through DchConnection

    func testConnectionReplies() {
        Preferences.agentIslandSessionGroups = Self.macList
        Preferences.agentIslandSessionGroupsUpdated = 10
        let queue = DispatchQueue(label: "test.dchconn.groups")
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { _ in })
        let box = Box(), replied = expectation(description: "reply")
        conn.groups.adopted = { box.lock.withLock { box.adopts += 1 } }
        conn.sendOverride = { f in box.lock.withLock { box.frames.append(f) }; replied.fulfill() }
        queue.sync { conn.handle(type: DchFrame.groupsSync, payload: Self.body(#"{"groups":[{"id":"p","name":"P","pattern":"-p"}],"updated":11}"#)) }
        wait(for: [replied], timeout: 5)
        let r = Self.decode(box.lock.withLock { box.frames.first ?? Data() })
        XCTAssertEqual(r.type, DchFrame.ok)
        XCTAssertEqual(r.json, Self.object(#"{"groups":[{"id":"p","name":"P","pattern":"-p"}],"updated":11}"#))
        XCTAssertEqual(box.lock.withLock { box.adopts }, 1)
        XCTAssertEqual(stored(), .init(groups: [Self.g("p", "P", "-p")], updated: 11))
        XCTAssertFalse(queue.sync { conn.inFlight }, "the one reply cleared inFlight")
        addTeardownBlock { queue.sync { conn.close() } }
    }
}
