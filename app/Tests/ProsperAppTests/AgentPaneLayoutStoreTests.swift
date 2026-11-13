import XCTest
@testable import ProsperApp

/// #831 Phase A (spec v3.1 §14.1): `resolve` and the lastLive map (4.1, 4.1a), and the layout store blob
/// (8.1, 8.2). Pure values only: no defaults are read or written, nothing runs.
final class AgentPaneLayoutStoreTests: XCTestCase {
    typealias F = PaneFixtures
    let t: TimeInterval = 1_762_700_000

    func key(_ name: String) -> AgentSessionKey { AgentSessionKey(dir: F.dir, name: name) }

    func session(_ name: String, sid: String? = nil) -> AgentSession {
        AgentSession(key: key(name), alias: "", activity: 0, state: .idle, agents: 0, claudeSessionID: sid)
    }

    func record(_ name: String, file: String = "", updated: TimeInterval = 0, ended: TimeInterval = 0,
                sid: String? = nil) -> DchHistoryRecord {
        var r = DchHistoryRecord(key: key(name))
        r.file = file
        r.updated = updated
        r.ended = ended
        if let sid { r.agent = DchHistoryRecord.Agent(sessionID: sid) }
        return r
    }

    func resolve(_ target: PaneTarget, _ sessions: [AgentSession] = [], _ history: [DchHistoryRecord] = [],
                 _ lastLive: LastLive? = nil) -> PaneContent {
        AgentPaneLayout.resolve(target, sessions: sessions, history: history, lastLive: lastLive)
    }

    // MARK: resolve (4.1): .session

    func testASessionTargetIsLiveWhileItsSessionIsEvenWithAMatchingRecord() {
        let live = session("api", sid: "S2"), own = record("api", ended: t, sid: "S2")
        XCTAssertEqual(resolve(F.s("api"), [live], [own], LastLive(at: t, claudeSessionID: "S2")), .live(live),
                       "live wins over a record that shares its key (#580)")
        XCTAssertEqual(resolve(F.s("api"), [live], [own]), .live(live))
    }

    func testWithoutALastLiveSightASessionTargetIsNotRunningEvenWithARecordOfTheName() {
        XCTAssertEqual(resolve(F.s("api"), [], [record("api", ended: t, sid: "S1"), record("api", updated: t - 5)]),
                       .notRunning(key("api")), "after a relaunch: never the newest record (QA #669 F1)")
        XCTAssertEqual(resolve(F.s("api")), .notRunning(key("api")))
    }

    func testTheRecordMustBeTheEndedInstancesOwnByClaudeSessionID() {
        let last = LastLive(at: t, claudeSessionID: "S2")
        let r1 = record("api", ended: t - 30, sid: "S1"), r2 = record("api", ended: t + 5, sid: "S2")
        // The same name ended twice within 65 s: only R1 has landed, and it is the earlier instance's.
        XCTAssertEqual(resolve(F.s("api"), [], [r1], last), .notRunning(key("api")))
        XCTAssertEqual(resolve(F.s("api"), [], [r1, r2], last), .history(r2))
        XCTAssertEqual(resolve(F.s("api"), [], [r2, r1], last), .history(r2))
        // Another name's record never matches.
        XCTAssertEqual(resolve(F.s("api"), [], [record("docs", ended: t, sid: "S2")], last), .notRunning(key("api")))
    }

    func testWithoutBothSessionIDsTheTimeRuleBindsTheRecord() {
        let noID = LastLive(at: t, claudeSessionID: "")
        // A vanished master: ended 0, updated a minute-write before death.
        XCTAssertEqual(resolve(F.s("api"), [], [record("api", updated: t - 60)], noID), .history(record("api", updated: t - 60)))
        XCTAssertEqual(resolve(F.s("api"), [], [record("api", updated: t - 66)], noID), .notRunning(key("api")))
        XCTAssertEqual(resolve(F.s("api"), [], [record("api", updated: t - 65)], noID), .history(record("api", updated: t - 65)))
        // One side has an id and the other not: the time rule too.
        let withID = record("api", ended: t - 10, sid: "S9")
        XCTAssertEqual(resolve(F.s("api"), [], [withID], noID), .history(withID))
        XCTAssertEqual(resolve(F.s("api"), [], [record("api", ended: t - 10)], LastLive(at: t, claudeSessionID: "S1")),
                       .history(record("api", ended: t - 10)))
        // A stale record only (older than the slack, no ids): Ended stays.
        XCTAssertEqual(resolve(F.s("api"), [], [record("api", ended: t - 600)], noID), .notRunning(key("api")))
        // Two matches: the newest.
        let a = record("api", file: "api.1", ended: t - 20), b = record("api", ended: t - 5)
        XCTAssertEqual(resolve(F.s("api"), [], [a, b], noID), .history(b))
        XCTAssertTrue(AgentPaneLayout.matches(record("api", updated: t - 60), noID))
        XCTAssertFalse(AgentPaneLayout.matches(record("api", updated: t - 60), noID, slack: 10))
    }

    func testARecordWithTheInstancesOwnIDButOlderThanTheSlackDoesNotMatch() {
        let last = LastLive(at: t, claudeSessionID: "S2")
        let stale = record("api", ended: t - 66, sid: "S2")
        XCTAssertFalse(AgentPaneLayout.matches(stale, last), "QA INFO-N8: the time rule AND the ids")
        XCTAssertEqual(resolve(F.s("api"), [], [stale], last), .notRunning(key("api")), "the pane stays Ended")
        let fresh = record("api", ended: t - 65, sid: "S2")
        XCTAssertTrue(AgentPaneLayout.matches(fresh, last))
        XCTAssertEqual(resolve(F.s("api"), [], [fresh], last), .history(fresh))
    }

    func testAHandResumeOnTheSameIDNeverBindsTheOlderAsideRecord() {
        // QA INFO-N8: X1 ended (R1, id c); X2 cold-started (R1 moved aside), then `claude --resume c` by hand.
        let last = LastLive(at: t, claudeSessionID: "c")
        let aside = record("api", file: "api.1762699000", ended: t - 600, sid: "c")
        XCTAssertEqual(resolve(F.s("api"), [], [aside], last), .notRunning(key("api")), "X2's own record not landed yet")
        let own = record("api", ended: t + 5, sid: "c")
        XCTAssertEqual(resolve(F.s("api"), [], [aside, own], last), .history(own))
        XCTAssertEqual(resolve(F.s("api"), [], [own, aside], last), .history(own))
    }

    // MARK: resolve (4.1): .history and .remote

    func testAHistoryTargetResolvesByRecordIDNeverToTheLiveSession() {
        let own = record("api", ended: t)
        XCTAssertEqual(resolve(F.h("api"), [session("api")], [own]), .history(own), "#580: the record id stays")
        XCTAssertEqual(resolve(F.h("api", seen: t), [], [own]), .history(own))
        XCTAssertEqual(resolve(F.h("api"), [session("api")], []), .removed(F.h("api")))
        XCTAssertEqual(resolve(F.h("docs"), [], [own]), .removed(F.h("docs")))
        let aside = record("api", file: "api.1762700000", ended: t)
        XCTAssertEqual(resolve(F.h("api.1762700000"), [], [aside]), .history(aside), "an aside record by its id, not its key")
        XCTAssertEqual(resolve(F.h("api.1762700000"), [], [own]), .removed(F.h("api.1762700000")))
        XCTAssertEqual(resolve(.history(dir: "/Users/example/other", id: "api", seen: nil), [], [own]),
                       .removed(.history(dir: "/Users/example/other", id: "api", seen: nil)), "same dir only")
    }

    func testAHistoryTargetFollowsItsRecordMovedAsideByAColdStart() {
        let aside = record("api", file: "api.1762700000", ended: t)
        XCTAssertEqual(resolve(F.h("api", seen: t), [session("api")], [aside]), .history(aside), "QA INFO-14")
        // QA #669 G1: the cold start ended too and its record took the bare id, with another lastSeen.
        let newcomer = record("api", ended: t + 500)
        XCTAssertEqual(resolve(F.h("api", seen: t), [], [newcomer, aside]), .history(aside))
        XCTAssertEqual(resolve(F.h("api", seen: t), [], [newcomer]), .removed(F.h("api", seen: t)))
        // Without a seen there is no way to tell the record moved: the bare id only.
        XCTAssertEqual(resolve(F.h("api"), [], [aside]), .removed(F.h("api")))
    }

    func testARemoteTargetIsNotRunningUntilTheRemoteListExists() {
        XCTAssertEqual(resolve(.remote(host: "build.example.com", name: "ci-watch"), [session("ci-watch")]),
                       .notRunning(AgentSessionKey(dir: "@build.example.com", name: "ci-watch")))
    }

    @MainActor
    func testTheRecordSlackIsTheWindowModels() {
        XCTAssertEqual(AgentPaneLayout.recordSlack, AgentWindowModel.recordSlack)
    }

    // MARK: The lastLive map (4.1a)

    func testStampingRecordsVisibleLiveSessionPanesAtThePollTime() {
        let p = [F.pane(F.s("api")), F.pane(F.s("docs")), F.pane(F.s("web")), F.pane(F.h("api")), F.pane()]
        let visible = Set([p[0].id, p[2].id, p[3].id, p[4].id])
        let old = LastLive(at: t - 100, claudeSessionID: "S0")
        let map = AgentPaneLayout.stamp([p[1].id: old], panes: p, visible: visible,
                                        sessions: [session("api", sid: "S1"), session("docs", sid: "S2"), session("x")], at: t)
        XCTAssertEqual(map, [p[0].id: LastLive(at: t, claudeSessionID: "S1"), p[1].id: old],
                       "hidden keeps its last stamp; not live, History and empty panes get none")
        let noID = AgentPaneLayout.stamp([:], panes: [p[2]], visible: [p[2].id], sessions: [session("web")], at: t)
        XCTAssertEqual(noID, [p[2].id: LastLive(at: t, claudeSessionID: "")])
    }

    func testPruningDropsEntriesForPanesInNoLayout() {
        let store = PaneLayoutStore.makeDefault()
        let kept = store.layouts.first?.focused ?? UUID()
        let entry = LastLive(at: t, claudeSessionID: "")
        XCTAssertEqual(AgentPaneLayout.pruned([kept: entry, UUID(): entry], keeping: store), [kept: entry])
    }

    // MARK: The store (8.1, 8.2)

    let ids = (1...12).map { UUID(uuidString: String(format: "6F1C0D2E-0000-4000-8000-%012d", $0)) ?? UUID() }

    /// The spec's 8.2 example, with a fake socket dir.
    var specBlob: String { """
        {
          "v": 1,
          "active": "6F1C0D2E-0000-4000-8000-000000000001",
          "mru": ["6F1C0D2E-0000-4000-8000-000000000001", "6F1C0D2E-0000-4000-8000-000000000002"],
          "layouts": [
            {
              "id": "6F1C0D2E-0000-4000-8000-000000000001",
              "name": null,
              "focused": "A0000000-0000-4000-8000-00000000000A",
              "zoomed": null,
              "tree": {
                "split": "columns", "ratio": 0.5,
                "first":  { "pane": "A0000000-0000-4000-8000-00000000000A",
                            "session": { "dir": "/Users/example/dch-sockets", "name": "api-fix" } },
                "second": { "pane": "B0000000-0000-4000-8000-00000000000B",
                            "history": { "dir": "/Users/example/dch-sockets", "id": "docs.1762700000",
                                         "seen": 1762700000 } }
              }
            },
            {
              "id": "6F1C0D2E-0000-4000-8000-000000000002",
              "name": "Review",
              "focused": "C0000000-0000-4000-8000-00000000000C",
              "zoomed": null,
              "tree": { "pane": "C0000000-0000-4000-8000-00000000000C",
                        "remote": { "host": "build.example.com", "name": "ci-watch" } }
            }
          ]
        }
        """ }

    func decode(_ json: String) -> (store: PaneLayoutStore, repairs: [PaneRepair], needsBackup: Bool) {
        PaneLayoutStore.decode(Data(json.utf8))
    }

    func testTheSpecBlobDecodesAndRoundTrips() throws {
        let (store, repairs, backup) = decode(specBlob)
        XCTAssertEqual(repairs, [])
        XCTAssertFalse(backup)
        XCTAssertEqual(store.layouts.map(\.id), [ids[0], ids[1]])
        XCTAssertEqual(store.active, ids[0])
        XCTAssertEqual(store.mru, [ids[0], ids[1]])
        XCTAssertEqual(store.previous, ids[1])
        XCTAssertEqual(store.layouts.first?.panes.map(\.target),
                       [.session(dir: F.dir, name: "api-fix"), .history(dir: F.dir, id: "docs.1762700000", seen: 1_762_700_000)])
        if case let .history(_, _, seen)? = store.layouts.first?.panes.last?.target { XCTAssertEqual(seen, 1_762_700_000) } else {
            XCTFail("the History leaf")
        }
        XCTAssertEqual(store.layouts.last?.name, "Review")
        XCTAssertEqual(store.layouts.last?.panes.map(\.target), [.remote(host: "build.example.com", name: "ci-watch")])
        let again = PaneLayoutStore.decode(try store.encode())
        XCTAssertEqual(again.store, store)
        XCTAssertEqual(again.repairs, [])
        XCTAssertEqual(try again.store.encode(), try store.encode(), "the encoding is stable")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: try store.encode()) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
    }

    func testMissingOptionalFieldsAreNilAndUnknownFieldsAreIgnored() {
        let (store, repairs, backup) = decode("""
            {"future": [1, 2], "layouts": [{"id": "\(ids[2])", "focused": "\(ids[3])", "colour": "red",
              "tree": {"pane": "\(ids[3])", "pinned": true, "session": {"dir": "/Users/example/d", "name": "api", "x": 1}}}]}
            """)
        XCTAssertEqual(repairs, [])
        XCTAssertFalse(backup)
        XCTAssertEqual(store.active, ids[2])
        XCTAssertEqual(store.mru, [ids[2]])
        let l = store.layouts.first
        XCTAssertTrue(l?.name == nil && l?.zoomed == nil)
        XCTAssertEqual(l?.panes.map(\.target), [.session(dir: "/Users/example/d", name: "api")])
        XCTAssertEqual(l?.focused, ids[3])
    }

    func testAnUnknownTargetKindIsAnEmptyPane() {
        let (store, repairs, _) = decode("""
            {"v": 1, "layouts": [{"id": "\(ids[2])", "focused": "\(ids[3])", "tree": {"split": "rows", "ratio": 0.5,
              "first": {"pane": "\(ids[3])", "ssh": {"host": "example.com"}},
              "second": {"split": "columns", "first": {"pane": "\(ids[4])", "session": {"dir": 5}},
                         "second": {"pane": "\(ids[5])"}}}}]}
            """)
        XCTAssertEqual(repairs, [])
        XCTAssertEqual(store.layouts.first?.panes.map(\.id), [ids[3], ids[4], ids[5]])
        XCTAssertEqual(store.layouts.first?.panes.map(\.target), [nil, nil, nil])
        XCTAssertEqual(store.layouts.first.map { F.ratios($0.tree) }, [0.5, 0.5], "a missing ratio is 0.5")
    }

    func testACorruptBlobGivesTheDefaultStoreWithoutACrash() {
        for bad in ["not json", "{}", "[]", "{\"layouts\": 3}", "{\"layouts\": [{\"id\": \"x\"}]}", ""] {
            let (store, repairs, backup) = decode(bad)
            XCTAssertEqual(repairs, [.corruptBlob], bad)
            XCTAssertEqual(backup, !bad.isEmpty, "a blob that does not decode is kept before the first write: \(bad)")
            XCTAssertEqual(store.layouts.count, 1, bad)
            XCTAssertEqual(store.layouts.first?.panes.count, 1, bad)
        }
        let (none, repairs, _) = decode("{\"layouts\": []}")
        XCTAssertEqual(repairs, [.noLayouts])
        XCTAssertEqual(none.layouts.count, 1)
        let (fresh, nothing, backup) = PaneLayoutStore.decode(nil)
        XCTAssertEqual(nothing, [])
        XCTAssertFalse(backup)
        XCTAssertEqual(fresh.layouts.count, 1)
        XCTAssertEqual(fresh.mru, [fresh.active])
        XCTAssertEqual(fresh.layouts.first?.id, fresh.active)
        XCTAssertTrue(fresh.layouts.first?.panes.first?.target == nil, "one empty pane that follows the sidebar")
    }

    func testABlobOverTheSizeCapIsCorruptBeforeAnyJSONWork() {
        var atCap = Data(specBlob.utf8)
        XCTAssertLessThan(atCap.count, PaneLayoutStore.maxBlobBytes)
        atCap.append(Data(repeating: 0x20, count: PaneLayoutStore.maxBlobBytes - atCap.count))
        XCTAssertEqual(atCap.count, PaneLayoutStore.maxBlobBytes)
        let kept = PaneLayoutStore.decode(atCap)
        XCTAssertEqual(kept.repairs, [], "at the cap: not refused for size")
        XCTAssertFalse(kept.needsBackup)
        XCTAssertEqual(kept.store.layouts.count, 2)
        var over = atCap
        over.append(0x20)
        let refused = PaneLayoutStore.decode(over)
        XCTAssertEqual(refused.repairs, [.corruptBlob], "one byte over")
        XCTAssertTrue(refused.needsBackup, "the raw bytes are kept")
        XCTAssertEqual(refused.store.layouts.count, 1)
    }

    func testAZoomOnAnotherLeafThanTheFocusDecodesWithTheZoomCleared() {
        func blob(zoomed: UUID) -> String { """
            {"v": 1, "layouts": [{"id": "\(ids[2])", "focused": "\(ids[3])", "zoomed": "\(zoomed)",
              "tree": {"split": "columns", "ratio": 0.5, "first": {"pane": "\(ids[3])"}, "second": {"pane": "\(ids[4])"}}}]}
            """ }
        let (store, repairs, backup) = decode(blob(zoomed: ids[4]))
        XCTAssertEqual(repairs, [.zoomNotFocused])
        XCTAssertFalse(backup)
        XCTAssertTrue(store.layouts.first?.zoomed == nil)
        XCTAssertEqual(store.layouts.first?.focused, ids[3])
        XCTAssertEqual(store.layouts.first?.order, [ids[3], ids[4]], "repair never drops a pane")
        let onFocus = decode(blob(zoomed: ids[3]))
        XCTAssertEqual(onFocus.repairs, [])
        XCTAssertEqual(onFocus.store.layouts.first?.zoomed, ids[3])
    }

    func testANewerVersionAsksForTheBackupOnce() {
        let newer = specBlob.replacingOccurrences(of: "\"v\": 1", with: "\"v\": 2")
        let (store, repairs, backup) = decode(newer)
        XCTAssertTrue(backup)
        XCTAssertEqual(repairs, [])
        XCTAssertEqual(store.layouts.count, 2, "this build decodes what it understands")
        XCTAssertTrue(decode("{\"v\": 7, \"layouts\": \"from the future\"}").needsBackup, "unreadable but newer: still kept")
        XCTAssertFalse(decode(specBlob).needsBackup)
        XCTAssertFalse(decode("{\"v\": 0, \"layouts\": []}").needsBackup)
        // A string "v" fails the Blob decode (v is Int?): a corrupt non-empty blob, kept since A1b.
        XCTAssertTrue(decode("{\"v\": \"2\", \"layouts\": []}").needsBackup)
    }

    func testRepairNeverDropsALayout() {
        let (store, repairs, _) = decode("""
            {"v": 1, "active": "\(ids[0])", "layouts": [
              {"id": "\(ids[0])", "focused": "\(ids[3])", "tree": {"pane": "\(ids[3])"}},
              {"id": "\(ids[1])", "focused": "\(ids[9])", "zoomed": "\(ids[10])", "tree": {"split": "columns", "ratio": 1.4,
                "first": {"pane": "\(ids[4])", "session": {"dir": "/Users/example/d", "name": "api"}},
                "second": {"pane": "\(ids[5])", "history": {"dir": "/Users/example/d", "id": "api"}}}}]}
            """)
        XCTAssertEqual(store.layouts.map(\.id), [ids[0], ids[1]])
        XCTAssertEqual(repairs, [.duplicateTarget, .ratioClamped, .danglingFocus, .danglingZoom])
        let fixed = store.layouts.last
        XCTAssertEqual(fixed?.panes.map(\.id), [ids[4], ids[5]])
        XCTAssertEqual(fixed?.panes.map(\.target), [.session(dir: "/Users/example/d", name: "api"), nil])
        XCTAssertEqual(fixed?.focused, ids[4])
        XCTAssertTrue(fixed?.zoomed == nil)
        XCTAssertEqual(fixed.map { F.ratios($0.tree) }, [0.9])
        XCTAssertTrue(store.layouts.allSatisfy { $0.validate() })
    }

    func testStoreRepairsDuplicateLayoutIDsADanglingActiveAndTheMRU() {
        let leaf = { (i: Int) in "{\"id\": \"\(self.ids[0])\", \"focused\": \"\(self.ids[i])\", \"tree\": {\"pane\": \"\(self.ids[i])\"}}" }
        let (store, repairs, _) = decode("""
            {"active": "\(ids[11])", "mru": ["\(ids[11])", "\(ids[0])", "\(ids[0])"], "layouts": [\(leaf(3)), \(leaf(4))]}
            """)
        XCTAssertEqual(store.layouts.count, 2)
        XCTAssertEqual(store.layouts.first?.id, ids[0])
        XCTAssertNotEqual(store.layouts.last?.id, ids[0])
        XCTAssertEqual(store.layouts.last?.focused, ids[4])
        XCTAssertEqual(store.active, ids[0])
        XCTAssertEqual(store.mru, [ids[0]])
        XCTAssertEqual(repairs, [.duplicateLayoutID, .danglingActive, .mru])
    }

    func testAtMostNineLayoutsAndTheLastCannotBeDeleted() throws {
        var store = PaneLayoutStore.makeDefault()
        XCTAssertEqual(store.deleting(store.active).refused, .lastLayout)
        for _ in 1..<9 { store = try store.adding(.single()).get() }
        XCTAssertEqual(store.layouts.count, 9)
        XCTAssertEqual(store.adding(.single()).refused, .layoutCap)
        XCTAssertEqual(PaneRefusal.layoutCap.menuSuffix, "(9 layouts max)")
        let blob = try store.encode()
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: blob) as? [String: Any])
        var layouts = try XCTUnwrap(object["layouts"] as? [Any])
        layouts += layouts.prefix(2).map { _ -> Any in ["id": UUID().uuidString, "focused": ids[7].uuidString,
                                                 "tree": ["pane": ids[7].uuidString]] as [String: Any] }
        var over = object
        over["layouts"] = layouts
        let (cut, repairs, _) = PaneLayoutStore.decode(try JSONSerialization.data(withJSONObject: over))
        XCTAssertEqual(cut.layouts.map(\.id), store.layouts.map(\.id))
        XCTAssertEqual(repairs, [.tooManyLayouts])
        // Deleting the active layout hands over to the previous one; a deleted id leaves the MRU.
        let first = try XCTUnwrap(store.layouts.first?.id), second = try XCTUnwrap(store.layouts.last?.id)
        let switched = try store.activate(second).get()
        let deleted = try switched.deleting(second).get()
        XCTAssertEqual(deleted.active, first)
        XCTAssertFalse(deleted.mru.contains(second))
        XCTAssertEqual(deleted.layouts.count, 8)
        XCTAssertEqual(store.deleting(UUID()).refused, .noSuchLayout)
    }

    func testTheMRUFollowsSwitches() throws {
        var store = PaneLayoutStore.makeDefault()
        let a = store.active
        let (b, c) = (PaneLayout.single(), PaneLayout.single())
        store = try store.adding(b).get().adding(c).get()
        XCTAssertEqual(store.mru, [a])
        XCTAssertTrue(store.previous == nil)
        store = try store.activate(b.id).get().activate(c.id).get()
        XCTAssertEqual(store.active, c.id)
        XCTAssertEqual(store.previous, b.id, "⌃Tab goes back to the last layout")
        store = try store.activate(b.id).get()
        XCTAssertEqual(store.mru, [b.id, c.id, a])
        XCTAssertEqual(store.previous, c.id)
        XCTAssertEqual(store.activate(UUID()).refused, .noSuchLayout)
        let reloaded = PaneLayoutStore.decode(try store.encode()).store
        XCTAssertEqual(reloaded.mru, [b.id, c.id, a])
        XCTAssertEqual(reloaded.active, b.id)
    }

    func testOddCharactersInADirAndNameRoundTrip() throws {
        let dir = "/Users/example/dch \"q\" \\ é 🚀\n\t:%", name = "a/b: c\u{0}"
        var l = PaneLayout.single(.session(dir: dir, name: name))
        l.name = "Ünïcode \"name\""
        l = try l.split(axis: .columns, target: .history(dir: dir, id: name + ".1", seen: 0.25), minimum: .zero,
                        in: CGRect(x: 0, y: 0, width: 1000, height: 600)).get()
        let store = PaneLayoutStore(layouts: [l], active: l.id, mru: [l.id])
        let (back, repairs, _) = PaneLayoutStore.decode(try store.encode())
        XCTAssertEqual(repairs, [])
        XCTAssertEqual(back, store)
        XCTAssertEqual(back.layouts.first?.panes.map(\.target), [.session(dir: dir, name: name), .history(dir: dir, id: name + ".1", seen: 0.25)])
        if case let .history(_, _, seen)? = back.layouts.first?.panes.last?.target { XCTAssertEqual(seen, 0.25) } else {
            XCTFail("the History leaf")
        }
    }
}

private extension Result {
    var refused: Failure? {
        if case let .failure(e) = self { return e }
        return nil
    }
}
