import XCTest
@testable import ProsperApp

/// #1757 (#1755 phase A): the ordered session groups: their storage and the migration from the one sidekick pattern,
/// first-match splitting, dch's caps (8 groups, 1-32 byte names) and the phone's 0x2d carrying the first group's pattern.
/// Preferences is the in-memory XCTest store; each row puts the keys back.
final class SessionGroupsTests: XCTestCase {
    private static let keys = ["agentIslandSessionGroups", "agentIslandSidekickPattern", "agentIslandSidekickPatternUpdated"]

    override func setUp() {
        super.setUp()
        let saved = Self.keys.map { Preferences.defaults.object(forKey: $0) }
        addTeardownBlock {
            for (k, v) in zip(Self.keys, saved) {
                if let v { Preferences.defaults.set(v, forKey: k) } else { Preferences.defaults.removeObject(forKey: k) }
            }
        }
        Self.keys.forEach(Preferences.defaults.removeObject(forKey:))
    }

    private static func group(_ name: String, _ pattern: String) -> SessionGroup {
        SessionGroup(id: name, name: name, pattern: pattern)
    }

    private static func session(_ name: String, alias: String = "", title: String = "") -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: "/d", name: name), alias: alias, activity: 0, state: .idle, agents: 0, harness: title)
    }

    // MARK: - Migration

    func testUnsetReadsTheOneSidekicksGroupWithTheDefaultPattern() {
        XCTAssertEqual(Preferences.agentIslandSessionGroups,
                       [SessionGroup(id: SessionGroup.sidekicksID, name: "Sidekicks", pattern: "-qa")])
        XCTAssertTrue(Preferences.defaults.object(forKey: "agentIslandSessionGroups") == nil, "a read writes nothing")
    }

    func testAChangedPatternMigratesIntoTheSidekicksGroupAndKeepsItsStamp() {
        Preferences.defaults.set("-(qa|rev)$", forKey: "agentIslandSidekickPattern")
        Preferences.agentIslandSidekickPatternUpdated = 42
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.pattern), ["-(qa|rev)$"])
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.name), ["Sidekicks"])
        XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, 42, "the phone sync's stamp is kept")
        Preferences.defaults.set("", forKey: "agentIslandSidekickPattern")
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.pattern), [""], "an emptied pattern stays: no split")
        // Before a list is stored, the single-pattern setter keeps writing the #571 key.
        Preferences.agentIslandSidekickPattern = "-x"
        XCTAssertEqual(Preferences.defaults.string(forKey: "agentIslandSidekickPattern"), "-x")
        XCTAssertTrue(Preferences.defaults.object(forKey: "agentIslandSessionGroups") == nil)
    }

    func testAStoredListWinsAndThePatternSetterEditsItsFirstGroup() {
        Preferences.defaults.set("-legacy", forKey: "agentIslandSidekickPattern")
        Preferences.agentIslandSessionGroups = [Self.group("Reviews", "-rev$"), Self.group("QA", "-qa$")]
        XCTAssertEqual(Preferences.agentIslandSidekickPattern, "-rev$", "the first group's pattern")
        Preferences.agentIslandSidekickPattern = "-r$"
        XCTAssertEqual(Preferences.agentIslandSessionGroups, [Self.group("Reviews", "-r$"), Self.group("QA", "-qa$")])
        Preferences.agentIslandSessionGroups = []
        XCTAssertEqual(Preferences.agentIslandSidekickPattern, "", "no groups: no pattern")
        Preferences.agentIslandSidekickPattern = ""
        XCTAssertEqual(Preferences.agentIslandSessionGroups, [], "an empty pattern adds no group")
        Preferences.agentIslandSidekickPattern = "-qa"
        XCTAssertEqual(Preferences.agentIslandSessionGroups, SessionGroup.sidekicks("-qa"), "a pattern brings Sidekicks back")
    }

    // MARK: - dch's caps

    func testAtMostEightGroupsAndNamesOfOneTo32Bytes() {
        let ok32 = String(repeating: "é", count: 16)   // 32 bytes
        XCTAssertTrue(SessionGroup.validName(ok32))
        XCTAssertTrue(SessionGroup.validName(" x "), "trimmed")
        for bad in ["", "   ", ok32 + "a", "a=b", "a\nb", "a\u{7F}"] {
            XCTAssertFalse(SessionGroup.validName(bad), bad.debugDescription)
        }
        let list = [Self.group("", "a"), Self.group("a=b", "b")] + (1...10).map { Self.group(" g\($0) ", "p\($0)") }
        Preferences.agentIslandSessionGroups = list
        let kept = Preferences.agentIslandSessionGroups
        XCTAssertEqual(kept.count, SessionGroup.maxCount)
        XCTAssertEqual(kept.map(\.name), (1...8).map { "g\($0)" }, "invalid names dropped, the first 8 kept, names trimmed")
    }

    // MARK: - Matching

    func testASessionGoesIntoTheFirstGroupItMatchesElseTheMainList() {
        let list = [Self.session("api-qa"), Self.session("qa-tool"), Self.session("web"),
                    Self.session("docs", alias: "qa-docs"), Self.session("ops", title: "QA bot")]
        let s = AgentIsland.split(list, groups: [Self.group("A", "-qa$"), Self.group("B", "qa"), Self.group("C", "web|api")])
        XCTAssertEqual(s.groups.map(\.group.name), ["A", "B", "C"], "every group, in order")
        XCTAssertEqual(s.groups.map { $0.sessions.map(\.name) }, [["api-qa"], ["qa-tool", "docs", "ops"], ["web"]],
                       "api-qa only in A though C matches it too; B by name, alias and harness title, case-insensitive")
        XCTAssertEqual(s.primary.map(\.name), [])
        XCTAssertEqual(s.firstGroup.map(\.name), ["api-qa"])
        let none = AgentIsland.split(list, groups: [])
        XCTAssertEqual(none.primary.map(\.name), list.map(\.name), "no groups: every session in the main list")
        XCTAssertTrue(none.groups.isEmpty && none.firstGroup.isEmpty)
    }

    func testTheDefaultListSplitsAsTheOnePatternDid() {
        let list = ["b", "a-qa", "c", "x-QA"].map { Self.session($0) }
        let one = AgentIsland.split(list, pattern: "-qa"), groups = AgentIsland.split(list, groups: SessionGroup.sidekicks("-qa"))
        XCTAssertEqual(one.primary.map(\.name), ["b", "c"])
        XCTAssertEqual(groups.primary.map(\.name), one.primary.map(\.name))
        XCTAssertEqual(groups.firstGroup.map(\.name), ["a-qa", "x-QA"])
        XCTAssertEqual(groups.groups.map(\.group.name), ["Sidekicks"])
        XCTAssertTrue(SessionGroup.sidekicks(" ").isEmpty, "a blank pattern is no group")
    }

    // MARK: - The phone (0x2d)

    func testThePhoneFrameCarriesAndAdoptsTheFirstGroupsPattern() {
        Preferences.agentIslandSessionGroups = [Self.group("Reviews", "-rev$"), Self.group("QA", "-qa$")]
        Preferences.agentIslandSidekickPatternUpdated = 5
        XCTAssertEqual(DchSidekickOps.current(), .init(pattern: "-rev$", updated: 5))
        let frame = String(decoding: DchSidekickOps.watchFrame(DchSidekickOps.current()), as: UTF8.self)
        XCTAssertTrue(frame.contains("-rev$") && !frame.contains("-qa$"), frame)
        let adopted = expectation(description: "the phone's reply")
        DchSidekickOps().handle(Data(#"{"pattern":"-n$","updated":4102444800000}"#.utf8)) { _ in adopted.fulfill() }
        wait(for: [adopted], timeout: 5)
        let main = expectation(description: "main hops")
        DispatchQueue.main.async { main.fulfill() }
        wait(for: [main], timeout: 5)
        XCTAssertEqual(Preferences.agentIslandSessionGroups, [Self.group("Reviews", "-n$"), Self.group("QA", "-qa$")],
                       "the adopt edits the first group only")
        XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, 4102444800000)
    }
}
