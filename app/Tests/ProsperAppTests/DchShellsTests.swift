import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1558: dch 1.101's `--ls-json` `shells` (README.md:473@v1.101.0): decoded in DchListRow (the key left out = an older
/// dch, the row unchanged), the Agent Sessions row's shells count and the list its help shows, every text cleaned
/// through OutsideText.shown. Pure: no dch, no window.
final class DchShellsTests: XCTestCase {

    /// A dch 1.101 row as the README writes it: one shell a subagent started in the background, one from the main
    /// conversation, one dch could not place (a foreground call: no agent key).
    static let newRow = """
    [{"name":"api","alias":"","harness":"api","activity_epoch":1784995163,"state":"working","agents":1,
      "claude_session_id":"0b6c1d4e-1111-4222-8333-944455556666",
      "shells":[
        {"id":"b7x1","pid":4242,"started":1784995100,"command":"swift test --filter Api","agent":"a1b2c3",
         "agent_description":"Run the suite","description":"Run the API tests","background":true},
        {"id":"b7x0","pid":4100,"started":1784995000,"command":"npm run dev","agent":null,"description":"Dev server",
         "background":true},
        {"id":"b6z9","pid":4001,"started":1784994900,"command":"sleep 30"}],
      "cwd":"/Users/example/src/api"}]
    """

    func rows(_ json: String) -> [DchListRow] { DchCommand.parseListJSON(Data(json.utf8)) }

    // MARK: Decode

    func testDecodesTheNewShapeInDchOrder() throws {
        let shells = try XCTUnwrap(rows(Self.newRow).first?.shells)
        XCTAssertEqual(shells.map(\.id), ["b7x1", "b7x0", "b6z9"], "newest first, as dch gives them")
        XCTAssertEqual(shells.first, DchShell(id: "b7x1", pid: 4242, started: 1784995100, command: "swift test --filter Api",
                                              agent: .some("a1b2c3"), agentDescription: "Run the suite",
                                              description: "Run the API tests", background: true))
        XCTAssertTrue(shells.dropFirst().first?.agent == .some(nil), "agent null: the main conversation")
        XCTAssertTrue(shells.last?.agent == nil, "no agent key: unknown")
        XCTAssertEqual(shells.last?.background, false)
        XCTAssertTrue(shells.last?.description == nil)
    }

    func testAbsentKeyIsNilAndEmptyIsEmpty() {
        let r = rows(#"[{"name":"a","state":"idle"},{"name":"b","shells":[]},{"name":"c","shells":null},{"name":"d","shells":{}}]"#)
        XCTAssertEqual(r.count, 4)
        XCTAssertTrue(r.first?.shells == nil, "an older dch: no key")
        XCTAssertEqual(r.dropFirst().first?.shells, [], "no shells running")
        XCTAssertTrue(r.dropFirst(2).allSatisfy { $0.shells == nil }, "null or a wrong type reads as an older dch")
    }

    /// The key left out keeps the row exactly as it was: the same row with the key differs in `shells` only.
    func testAbsentKeyKeepsTheRowUnchanged() throws {
        let without = Self.newRow.replacingOccurrences(of: #""shells":["#, with: #""x":["#)
        var with = try XCTUnwrap(rows(Self.newRow).first)
        let old = try XCTUnwrap(rows(without).first)
        XCTAssertTrue(old.shells == nil)
        XCTAssertEqual(with.shells?.count, 3)
        with.shells = nil
        XCTAssertEqual(with, old)
    }

    /// Each element is checked alone: a shell missing a field or with a wrong type is dropped, the others kept.
    func testMalformedShellsAreDroppedAlone() {
        let long = String(repeating: "a", count: DchShell.maxTextBytes + 1)
        let fit = String(repeating: "a", count: DchShell.maxTextBytes)
        let json = """
        [{"name":"a","shells":[
          {"id":"ok","pid":1,"started":0,"command":"true"},
          {"id":"","pid":2,"started":0,"command":"x"},
          {"pid":3,"started":0,"command":"x"},
          {"id":"p0","pid":0,"started":0,"command":"x"},
          {"id":"pneg","pid":-4,"started":0,"command":"x"},
          {"id":"pbig","pid":2147483648,"started":0,"command":"x"},
          {"id":"pbool","pid":true,"started":0,"command":"x"},
          {"id":"pfrac","pid":1.5,"started":0,"command":"x"},
          {"id":"sneg","pid":5,"started":-1,"command":"x"},
          {"id":"snull","pid":5,"started":null,"command":"x"},
          {"id":"cnum","pid":5,"started":0,"command":7},
          {"id":"cempty","pid":5,"started":0,"command":""},
          {"id":"clong","pid":5,"started":0,"command":"\(long)"},
          {"id":"cfit","pid":2147483647,"started":0,"command":"\(fit)"},
          "not an object", 3, null]}]
        """
        XCTAssertEqual(rows(json).first?.shells?.map(\.id), ["ok", "cfit"])
    }

    /// The optional keys drop alone: a wrong type or an over-long text reads as unknown, the shell stays.
    func testOptionalKeysDropAlone() {
        let long = String(repeating: "d", count: DchShell.maxTextBytes + 1)
        let json = """
        [{"name":"a","shells":[
          {"id":"1","pid":1,"started":0,"command":"x","agent":5,"agent_description":"\(long)","description":["d"],"background":1},
          {"id":"2","pid":1,"started":0,"command":"x","agent":"","description":"","background":"true"},
          {"id":"3","pid":1,"started":0,"command":"x","background":false}]}]
        """
        let shells = rows(json).first?.shells ?? []
        XCTAssertEqual(shells.count, 3)
        for s in shells {
            XCTAssertTrue(s.agent == nil && s.agentDescription == nil && s.description == nil, s.id)
            XCTAssertFalse(s.background, s.id)
        }
    }

    func testListIsCappedAtMaxShells() {
        let one = #"{"id":"i","pid":1,"started":0,"command":"x"}"#
        let json = "[{\"name\":\"a\",\"shells\":[" + Array(repeating: one, count: DchShell.maxShells + 5).joined(separator: ",") + "]}]"
        XCTAssertEqual(rows(json).first?.shells?.count, DchShell.maxShells)
    }

    // MARK: The row

    /// #1583: the session carries its shells (AgentSession.shells), as AgentIsland.list fills it.
    func session(agents: Int = 1, shells: [DchShell] = [], state: AgentState = .working) -> AgentSession {
        var s = AgentSession(key: AgentSessionKey(dir: "/Users/example/.dch", name: "api"), alias: "", activity: 0,
                             state: state, agents: agents, meta: DchSessionMeta(openPRs: [], merged: 2))
        s.shells = shells
        return s
    }

    func shellsOff() -> AgentIslandRowDetails {
        var d = AgentIslandRowDetails.all
        d.shells = false
        return d
    }

    func testRowCountsTheShellsBesideTheAgents() throws {
        let shells = try XCTUnwrap(rows(Self.newRow).first?.shells)
        let r = AgentSidebar.row(session(shells: shells), details: .all, now: 0)
        XCTAssertEqual(r.counts.map { $0.0 }, [.agents, .shells, .merged], "shells right after the sub-agents")
        XCTAssertEqual(r.counts.map { $0.1 }, [1, 3, 2])
        XCTAssertTrue(r.countWords.contains("3 running shells"), "\(r.countWords)")
        XCTAssertEqual(r.countHelp[.shells], AgentSidebar.shellList(shells))
    }

    func testNoShellsDrawNoGroupAndKeepTheRow() {
        let plain = AgentSidebar.row(session(), details: .all, now: 0)
        XCTAssertEqual(plain.counts.map { $0.0 }, [.agents, .merged])
        XCTAssertTrue(plain.countHelp.isEmpty)
        XCTAssertTrue(plain.shells.isEmpty)
    }

    /// #1583: Row details "Shells" off draws no chip and no list, the shells still on the session.
    func testShellsOffDrawsNoChip() throws {
        let shells = try XCTUnwrap(rows(Self.newRow).first?.shells)
        let r = AgentSidebar.row(session(shells: shells), details: shellsOff(), now: 0)
        XCTAssertEqual(r.counts.map { $0.0 }, [.agents, .merged])
        XCTAssertTrue(r.countHelp.isEmpty)
        XCTAssertTrue(r.shells.isEmpty)
    }

    func testCountWords() {
        XCTAssertEqual(AgentSidebar.Count.shells.words(1), "1 running shell")
        XCTAssertEqual(AgentSidebar.Count.shells.words(2), "2 running shells")
    }

    // MARK: The list

    func testListGroupsByOwnerMainFirst() throws {
        let shells = try XCTUnwrap(rows(Self.newRow).first?.shells)
        XCTAssertEqual(AgentSidebar.shellList(shells), """
        3 running shells
        Main conversation
          npm run dev
            Dev server
        Agent: Run the suite
          swift test --filter Api
            Run the API tests
        Owner unknown
          sleep 30
        """)
    }

    /// One owner (dch 1.101 with no transcript match: every shell unplaced): no headers; an agent with no description
    /// is named by its id; each group keeps dch's order.
    func testOneGroupHasNoHeaderAndAnAgentFallsBackToItsId() {
        let a = DchShell(id: "1", pid: 1, started: 2, command: "make"), b = DchShell(id: "0", pid: 2, started: 1, command: "ls")
        XCTAssertEqual(AgentSidebar.shellList([a, b]), "2 running shells\n  make\n  ls")
        let c = DchShell(id: "2", pid: 3, started: 3, command: "rg x", agent: .some("ab12"))
        XCTAssertEqual(AgentSidebar.shellList([c, a]), "2 running shells\nAgent: ab12\n  rg x\nOwner unknown\n  make")
    }

    /// Outside text: a bidi override, a zero-width space and a control are dropped from every shown part.
    func testListTextIsCleaned() {
        let s = DchShell(id: "1", pid: 1, started: 0, command: "echo \u{202E}hi\u{200B}\u{7}", agent: .some("x"),
                         agentDescription: "Re\u{202E}view", description: "Say\u{2066} hi")
        let t = DchShell(id: "2", pid: 2, started: 0, command: "ls", agent: .some(nil))
        XCTAssertEqual(AgentSidebar.shellList([s, t]), "2 running shells\nMain conversation\n  ls\nAgent: Review\n  echo hi\n    Say hi")
    }

    func testListIsCappedWithACount() {
        let many = (0..<25).map { DchShell(id: "\($0)", pid: $0 + 1, started: 0, command: "c\($0)") }
        let lines = AgentSidebar.shellList(many).split(separator: "\n")
        XCTAssertEqual(lines.first, "25 running shells")
        XCTAssertEqual(lines.count, 1 + 20 + 1)
        XCTAssertEqual(lines.last, "and 5 more")
    }

    // MARK: The island card (#1583)

    /// The card draws the Agent Sessions row's own detail line (AgentIslandRow.sidebarRow): the shells chip right after
    /// the sub-agents count, its help the same list; a notice in the state word's place keeps it. VoiceOver says it in
    /// drawn order.
    @MainActor
    func testIslandCardCountsTheShellsBesideTheAgents() throws {
        let shells = try XCTUnwrap(rows(Self.newRow).first?.shells)
        let s = session(shells: shells)
        for notice in [nil, "Attach command copied"] {
            let r = AgentIslandRow.sidebarRow(s, show: .all, now: 0, notice: notice)
            XCTAssertEqual(r.counts.map { $0.0 }, [.agents, .shells, .merged], notice ?? "no notice")
            XCTAssertEqual(r.counts.map { $0.1 }, [1, 3, 2], notice ?? "no notice")
            XCTAssertEqual(r.countHelp[.shells], AgentSidebar.shellList(shells), notice ?? "no notice")
        }
        let label = AgentIslandRow.accessibilityLabel(s, now: 0, show: .all)
        XCTAssertTrue(label.contains("1 agent, 3 running shells, 2 merged pull requests"), label)
    }

    /// The key left out (an older dch): AgentIsland.list gives the session no shells and the card draws nothing; the same
    /// row with the key carries them through. A fake runner, no dch; no claude_session_id, so no transcript is read.
    @MainActor
    func testIslandAbsentKeyDrawsNothing() throws {
        let with = #"[{"name":"api","alias":"","activity_epoch":1,"state":"working","agents":1,"#
            + #""shells":[{"id":"b1","pid":7,"started":1,"command":"make"}]}]"#
        let without = with.replacingOccurrences(of: #""shells":"#, with: #""x":"#)
        let old = try XCTUnwrap(AgentIsland.list(dirs: ["/Users/example/.dch"]) { _, _ in Data(without.utf8) }.first)
        XCTAssertTrue(old.shells.isEmpty)
        let r = AgentIslandRow.sidebarRow(old, show: .all, now: 0, notice: nil)
        XCTAssertEqual(r.counts.map { $0.0 }, [.agents])
        XCTAssertTrue(r.countHelp.isEmpty)
        XCTAssertFalse(AgentIslandRow.accessibilityLabel(old, now: 0, show: .all).contains("shell"))
        let new = try XCTUnwrap(AgentIsland.list(dirs: ["/Users/example/.dch"]) { _, _ in Data(with.utf8) }.first)
        XCTAssertEqual(new.shells.map(\.command), ["make"])
        XCTAssertEqual(AgentIslandRow.sidebarRow(new, show: .all, now: 0, notice: nil).counts.map { $0.0 }, [.agents, .shells])
    }

    /// Row details "Shells" off: no chip, no list and no words on the card.
    @MainActor
    func testIslandShellsOffDrawsNoChip() throws {
        let s = session(shells: try XCTUnwrap(rows(Self.newRow).first?.shells))
        let r = AgentIslandRow.sidebarRow(s, show: shellsOff(), now: 0, notice: "Attach command copied")
        XCTAssertEqual(r.counts.map { $0.0 }, [.agents, .merged])
        XCTAssertTrue(r.countHelp.isEmpty)
        XCTAssertFalse(AgentIslandRow.accessibilityLabel(s, now: 0, show: shellsOff()).contains("shell"))
    }

    /// The card's list cleans a bidi override, a zero-width space and a control from the command.
    @MainActor
    func testIslandListTextIsCleaned() {
        let s = session(shells: [DchShell(id: "1", pid: 1, started: 0, command: "echo \u{202E}hi\u{200B}\u{7}")])
        XCTAssertEqual(AgentIslandRow.sidebarRow(s, show: .all, now: 0, notice: nil).countHelp[.shells], "1 running shell\n  echo hi")
    }

    /// A blocked session the island answers is published as working with its shells kept (the controller copies the
    /// session field by field).
    func testAnsweringKeepsTheShells() {
        let s = session(shells: [DchShell(id: "1", pid: 1, started: 0, command: "make")], state: .blocked)
        XCTAssertEqual(AgentIslandController.answering(s).shells, s.shells)
    }

    /// #1681 (left by #1583): a Text Viewer editor session shows an untrusted file's bytes, so AgentIsland.list gives it
    /// no shells (and idle, no Claude id) whatever dch reports; a normal session in the same answer keeps its shells.
    /// A fake runner, no dch.
    @MainActor
    func testEditSessionGetsNoShellsAndANormalOneKeepsThem() throws {
        let edit = TerminalEditor.sessionName(path: "/Users/example/notes.md")
        XCTAssertTrue(TerminalEditor.isEditSession(edit), edit)
        let shell = #""shells":[{"id":"b1","pid":7,"started":1,"command":"make"}]"#
        let json = "[{\"name\":\"\(edit)\",\"alias\":\"\",\"activity_epoch\":1,\"state\":\"working\",\"agents\":1,"
            + "\"claude_session_id\":\"0b6c1d4e-1111-4222-8333-944455556666\",\(shell)},"
            + "{\"name\":\"api\",\"alias\":\"\",\"activity_epoch\":1,\"state\":\"working\",\"agents\":1,\(shell)}]"
        let list = AgentIsland.list(dirs: ["/Users/example/.dch"]) { _, _ in Data(json.utf8) }
        let e = try XCTUnwrap(list.first { $0.key.name == edit }, "the editor session is listed")
        XCTAssertTrue(e.shells.isEmpty, "no shells for an editor session")
        XCTAssertEqual(e.state, .idle)
        XCTAssertTrue(e.claudeSessionID == nil)
        XCTAssertTrue(AgentIslandRow.sidebarRow(e, show: .all, now: 0, notice: nil).countHelp.isEmpty)
        XCTAssertFalse(AgentIslandRow.accessibilityLabel(e, now: 0, show: .all).contains("shell"))
        let api = try XCTUnwrap(list.first { $0.key.name == "api" })
        XCTAssertEqual(api.shells.map(\.command), ["make"], "a normal session keeps its shells")
    }

    // MARK: Small-scale crowding (#1681)

    /// The island card at the smallest UI scale with every count at its widest (99 shells, 999 agents, 999 merged), a
    /// notice in the state word's place or not: the shells chip is drawn as the agents' pill, in order between the agents
    /// and merged groups, below the title and left of the age, never past the card. Offscreen in a never-shown window.
    @MainActor
    func testShellsChipDoesNotOverlapTheRowTextAtTheSmallestScale() throws {
        _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 0.7
        let pixel = AXTreeSupport.devicePixel
        let many = (0..<DchShell.maxShells).map { DchShell(id: "\($0)", pid: $0 + 1, started: 0, command: "c\($0)") }
        var s = AgentSession(key: AgentSessionKey(dir: "/Users/example/.dch", name: "api-qa"), alias: "", activity: 1_000_000 - 240,
                             state: .working, agents: 999, meta: DchSessionMeta(openPRs: [], merged: 999))
        s.model = "claude-opus-4-5"
        s.effort = "high"
        s.shells = many
        let width = AgentIslandGeometry.expandedWidth - 2 * AgentIslandGeometry.listInset
        for notice in [nil, "Attach command copied"] {
            final class Box { var seen: [String: CGRect] = [:] }
            let box = Box()
            AgentSidebarRowView.probe = { kind, _, r in box.seen[kind] = r }
            defer { AgentSidebarRowView.probe = nil }
            let (win, host) = AXTreeSupport.hosted(
                AgentIslandRow(session: s, now: 1_000_000, notice: notice, show: .all) {}.frame(width: width), CGSize(width: width, height: 120))
            let end = Date().addingTimeInterval(2)
            while ["title", "age", "count.shells", "capsule.shells", "count.merged"].contains(where: { box.seen[$0] == nil }) && Date() < end {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertFalse(win.isVisible, "never on screen")
            win.contentView = nil
            win.close()
            let f = box.seen, tag = notice ?? "no notice"
            guard let chip = f["count.shells"], let pill = f["capsule.shells"], let agents = f["count.agents"],
                  let merged = f["count.merged"], let age = f["age"], let title = f["title"] else {
                return XCTFail("a part is not drawn at 0.7: \(f.keys.sorted()) \(tag)")
            }
            XCTAssertGreaterThanOrEqual(chip.minY, title.maxY - pixel, "the chip is on line two, below the title: \(tag)")
            XCTAssertLessThanOrEqual(agents.maxX, chip.minX + pixel, "agents group, then the chip: \(tag)")
            XCTAssertLessThanOrEqual(chip.maxX, merged.minX + pixel, "the chip, then merged: \(tag)")
            XCTAssertLessThanOrEqual(merged.maxX, age.minX + pixel, "the age is clear of every group: \(tag)")
            XCTAssertLessThanOrEqual(age.maxX, width + pixel, "inside the card: \(tag)")
            XCTAssertGreaterThan(chip.width, 0, tag)
            XCTAssertTrue(pill.intersects(chip), "the chip wears the pill: \(tag)")
        }
    }
}
