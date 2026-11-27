import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #2062: session groups by hand. dch 1.196's `group`/`group_manual` place a row, a live row's Move to group runs
/// `--group-set`, and New group… adds a group with an empty pattern. Offscreen only: no menu popped, no window shown,
/// no real dch (the controller's runner is a recorder that launches nothing), no defaults written (the model's seams).
final class AgentSessionGroupMoveTests: XCTestCase {
    static let dir = "/tmp/dch-test"
    static let v196 = DchCommand.Binary(path: "/fake/dch", version: [1, 196, 0])

    func session(_ name: String, group: String? = nil, manual: String? = nil) -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: Self.dir, name: name), alias: "", activity: 0, state: .idle, agents: 0,
                     group: group, groupManual: manual)
    }

    let work = SessionGroup(id: "w1", name: "Work", pattern: "zzz")
    let qa = SessionGroup(id: SessionGroup.sidekicksID, name: "Sidekicks", pattern: "-qa")

    @MainActor
    func store(_ sessions: [AgentSession], dch: DchCommand.Binary? = v196) -> AgentIslandStore {
        let s = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        s.controlDch = dch
        s.sessions = sessions
        s.sessionGroups = [work, qa]
        s.storedGroupCount = 2
        return s
    }

    /// The argv of every launch; each answers `status` and `output`.
    final class Launches: @unchecked Sendable {
        let lock = NSLock()
        var all: [[String]] = []
        var status: Int32 = 0
        var output = ""
        var args: [[String]] { lock.withLock { all } }
    }

    @MainActor
    func controller(_ st: AgentIslandStore, _ rec: Launches) -> AgentIslandController {
        let c = AgentIslandController()
        c.showsPanel = false
        c.monitorClicks = { _ in nil }
        let dch = st.controlDch
        c.controlDch = { dch }
        c.controlEnv = { ["DCH_SOCKET_DIR": $0] }
        c.readHistory = { _, _ in [] }
        c.historyDirs = { [Self.dir] }
        c.readLiveRecords = { _ in [] }
        c.seedDirs = { [] }
        c.listSessions = { _ in [] }
        c.runner = DchActionRunner(bound: 60, launch: { _, args, _, _, onPid, onOutput in
            let (status, out) = rec.lock.withLock { rec.all.append(args); return (rec.status, Data(rec.output.utf8)) }
            onPid(4242)
            onOutput(out)
            return (status, out)
        }, signal: { _ in })
        c.store = st
        return c
    }

    @MainActor
    func settle(_ c: AgentIslandController, until: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        repeat {
            c.queue.sync {}
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while !until() && Date() < end
    }

    // MARK: - Decoding and placement

    /// `group`/`group_manual` decode as names ("" for null); a row without them (older dch) keeps both nil.
    func testListRowsDecodeGroupAndManualAndARowWithoutThemHasNeither() {
        let rows = DchCommand.parseListJSON(Data("""
            [{"name":"api","group":"Work","group_manual":"Work"},
             {"name":"api-qa","group":null,"group_manual":null},
             {"name":"bad","group":"a=b","group_manual":7},
             {"name":"old"}]
            """.utf8))
        XCTAssertEqual(rows.map(\.group), ["Work", "", "", nil])
        XCTAssertEqual(rows.map(\.groupManual), ["Work", "", nil, nil])
    }

    /// dch's group places a row (any case; its manual one wins over the pattern); "" or a group these groups do not have
    /// is the main list; a row without the key is matched by the patterns as before.
    func testSplitPlacesByDchsGroupAndKeepsPatternGroupingForOlderRows() {
        let list = [session("api", group: "work", manual: "Work"), session("api-qa", group: ""),
                    session("old-qa"), session("x", group: "Gone"), session("plain")]
        let s = AgentIsland.split(list, groups: [work, qa])
        XCTAssertEqual(s.groups.first?.sessions.map(\.name), ["api"], "the manual group, not the pattern")
        XCTAssertEqual(s.groups.last?.sessions.map(\.name), ["old-qa"], "no key: the pattern places it")
        XCTAssertEqual(s.primary.map(\.name), ["api-qa", "x", "plain"], "list order kept")
        let old = AgentIsland.split([session("api"), session("api-qa")], groups: [work, qa])
        XCTAssertEqual(old.groups.last?.sessions.map(\.name), ["api-qa"], "an older dch: today's pattern grouping")
    }

    // MARK: - The row menu

    @MainActor
    func items(_ e: [AgentSidebarMenuEntry]) -> [AgentSidebarMenuEntry] {
        guard case .submenu(AgentIsland.moveToGroupLabel, true, let items)? = e.first, e.count == 1 else { return [] }
        return items
    }

    /// Every group (the manual one checked), a divider, Automatic (checked only with no manual group), New group…;
    /// none for an older row, an older control dch or a name dch reads as a flag; New group… off at the cap.
    @MainActor
    func testMoveToGroupMenuItemsAndChecksForAManualAndAnAutomaticSession() {
        let manual = session("api", group: "Work", manual: "work"), auto = session("api-qa", group: "Sidekicks")
        let st = store([manual, auto])
        let newGroup = AgentSidebarMenuEntry.item(AgentIsland.newGroupLabel, enabled: true, checked: nil, verb: .newGroup)
        XCTAssertEqual(items(AgentWindowControls.moveToGroupMenu(manual, store: st)), [
            .item("Work", enabled: true, checked: true, verb: .moveToGroup("Work")),
            .item("Sidekicks", enabled: true, checked: false, verb: .moveToGroup("Sidekicks")),
            .divider,
            .item(AgentIsland.automaticGroupLabel, enabled: true, checked: false, verb: .moveToGroup(nil)),
            newGroup,
        ])
        XCTAssertEqual(items(AgentWindowControls.moveToGroupMenu(auto, store: st)), [
            .item("Work", enabled: true, checked: false, verb: .moveToGroup("Work")),
            .item("Sidekicks", enabled: true, checked: false, verb: .moveToGroup("Sidekicks")),
            .divider,
            .item(AgentIsland.automaticGroupLabel, enabled: true, checked: true, verb: .moveToGroup(nil)),
            newGroup,
        ])
        XCTAssertEqual(AgentWindowControls.moveToGroupMenu(session("old"), store: st), [], "no group key: an older dch")
        XCTAssertEqual(AgentWindowControls.moveToGroupMenu(session("-x", group: ""), store: st), [], "a flag-like name")
        XCTAssertEqual(AgentWindowControls.moveToGroupMenu(auto, store: store([auto], dch: DchCommand.Binary(path: "/fake/dch",
                                                                                                            version: [1, 195, 0]))), [])
        st.storedGroupCount = SessionGroup.maxCount
        XCTAssertEqual(items(AgentWindowControls.moveToGroupMenu(auto, store: st)).last,
                       .item(AgentIsland.groupsFullText, enabled: false, checked: nil, verb: .newGroup))
        XCTAssertEqual(AgentWindowControls.sidebarMenu(store: st, autoAllow: false).dropFirst().first,
                       .item(AgentIsland.groupsFullText, enabled: false, checked: nil, verb: .newGroup), "the sidebar's too")
    }

    // MARK: - --group-set

    /// A group sends exactly `--group-set <name> <group> --json`, Automatic `--auto`; a failed reply's reason is the
    /// row's line and nothing runs again.
    @MainActor
    func testChoosingAGroupSendsGroupSetAndAFailedReplyReachesTheRowOnce() throws {
        let s = session("api", group: "Work", manual: ""), rec = Launches()
        let st = store([s]), c = controller(st, rec)
        // Each run waits for its launch, the runner to free the row and the answer's hop to main (the line it leaves).
        func run(_ g: String?, line: String? = nil) {
            let n = rec.args.count
            XCTAssertTrue(c.setGroup(s, group: g))
            settle(c) { rec.args.count > n && !c.runner.isBusy(s.key) && st.actions[s.key] == line }
        }
        rec.output = #"{"name":"api","group":"Work","result":"ok"}"# + "\n"
        run("Work")
        XCTAssertEqual(rec.args.last, ["--group-set", "api", "Work", "--json"])
        run(nil)
        XCTAssertEqual(rec.args.last, ["--group-set", "api", "--auto", "--json"])
        XCTAssertTrue(st.actions[s.key] == nil, "ok: no line")
        rec.lock.withLock {
            rec.status = 1
            rec.output = #"{"name":"api","group":null,"result":"failed","reason":"no_group"}"# + "\n"
        }
        run("Gone", line: AgentIsland.noGroupText)
        XCTAssertEqual(st.actions[s.key], AgentIsland.noGroupText)
        XCTAssertEqual(rec.args.count, 3, "never retried")
        rec.lock.withLock { rec.status = 0; rec.output = #"{"name":"api","group":"Work","result":"ok"}"# + "\n" }
        run("Work")
        XCTAssertTrue(st.actions[s.key] == nil, "the next move that works drops the failure")
        XCTAssertFalse(c.setGroup(session("gone", group: ""), group: "Work"), "not live: nothing")
        XCTAssertEqual(rec.args.count, 4)
    }

    func testGroupSetFailureWordsEachReasonAndHowTheCallEnded() {
        func r(_ status: Int32, _ reason: String?, stopped: Bool = false) -> DchActionResult {
            DchActionResult(status: status, json: reason.map { [DchJSONLine(name: "api", result: "failed", reason: $0)] } ?? [],
                            stopped: stopped)
        }
        XCTAssertTrue(AgentIsland.groupSetFailure(DchActionResult(status: 0, json: [DchJSONLine(name: "api", result: "ok")])) == nil)
        XCTAssertEqual(AgentIsland.groupSetFailure(r(1, "no_group")), "That group no longer exists")
        XCTAssertEqual(AgentIsland.groupSetFailure(r(1, "no_session")), "That session is no longer running")
        XCTAssertEqual(AgentIsland.groupSetFailure(r(1, "io_error")), "Couldn't save the group: dch could not write it")
        XCTAssertEqual(AgentIsland.groupSetFailure(r(2, nil)), "Couldn't move to the group: dch exited 2")
        XCTAssertEqual(AgentIsland.groupSetFailure(r(-1, nil, stopped: true)), "Couldn't move to the group: dch timed out")
        XCTAssertTrue(AgentIsland.isGroupSetFailure("Couldn't move to the group: dch exited 2"))
        XCTAssertEqual(AgentIsland.groupSetArgs("-x", "Work"), nil)
    }

    // MARK: - New group…

    func testNewGroupAddsAValidNameWithAnEmptyPatternAndRefusesBadOnesAndTheNinth() {
        guard case .success(let list) = AgentWindowControls.addingGroup("  Ops ", to: [work]) else { return XCTFail("added") }
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.last?.name, "Ops")
        XCTAssertEqual(list.last?.pattern, "", "an empty pattern: Automatic never puts a session there")
        for bad in ["", "   ", "a=b", "Sessions", "history", "WORK", String(repeating: "x", count: 33)] {
            if case .success = AgentWindowControls.addingGroup(bad, to: [work]) { XCTFail("\(bad) refused") }
        }
        let eight = (1...SessionGroup.maxCount).map { SessionGroup(id: "g\($0)", name: "G\($0)", pattern: "p\($0)") }
        XCTAssertEqual(AgentWindowControls.newGroupRefusal("Ninth", stored: eight), AgentIsland.groupsFullText)
        XCTAssertNil(AgentWindowControls.newGroupRefusal("Ninth", stored: Array(eight.dropLast())))
    }

    /// The sidebar's New group… stores the group and moves nothing; a row's stores it, then moves that row into it once;
    /// a refused name stays in the field with its reason and nothing is stored.
    @MainActor
    func testTheNameFieldStoresTheGroupAndARowsAskMovesItIn() {
        let m = AgentWindowModel(lastLive: AgentLastLiveHome(), layouts: nil)
        m.onNewRuntime = { r in
            r.transcript.offMain = { $0() }
            r.transcript.makeWatch = { _, _ in NSObject() }
            r.transcript.tickInterval = 3600
        }
        m.runtimes.values.forEach(m.onNewRuntime)
        var stored = [work], moves: [(String, String?)] = []
        m.storedGroups = { stored }
        m.saveGroups = { stored = $0 }
        m.setGroup = { moves.append(($0.name, $1)) }
        m.runSidebar(.newGroup)
        XCTAssertEqual(m.newGroup, AgentWindowModel.NewGroupAsk())
        m.newGroup?.name = "a=b"
        m.answerNewGroup(true)
        XCTAssertEqual(stored.count, 1, "refused: nothing stored")
        XCTAssertNotNil(m.newGroup?.refused)
        m.newGroup?.name = "Ops"
        m.answerNewGroup(true)
        XCTAssertTrue(m.newGroup == nil)
        XCTAssertEqual(stored.map(\.name), ["Work", "Ops"])
        XCTAssertTrue(moves.isEmpty, "the sidebar's: no session moved")
        let s = session("api", group: "")
        m.runMove(.newGroup, s)
        m.newGroup?.name = "Ops 2"
        m.answerNewGroup(true)
        XCTAssertEqual(stored.last?.pattern, "")
        XCTAssertEqual(moves.map(\.0), ["api"])
        XCTAssertEqual(moves.last?.1, "Ops 2")
        m.runMove(.moveToGroup(nil), s)
        XCTAssertEqual(moves.count, 2)
        XCTAssertTrue(moves.last?.1 == nil, "Automatic: --auto")
        m.runSidebar(.newGroup)
        m.answerNewGroup(false)
        XCTAssertTrue(m.newGroup == nil, "Cancel")
        XCTAssertEqual(stored.count, 3)
    }
}
