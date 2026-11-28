import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1759 (#1755 phase C): one Agent Sessions sidebar section and one Agent Island tab per session group with sessions,
/// in list order, titled with the group's name; a section folds by its group's id. Offscreen only: models and stores
/// built outright, the tab row measured in an NSHostingController that is never put in a window; Preferences are the
/// XCTest in-memory store, the fold key saved and restored per row.
@MainActor
final class SessionGroupSectionsTests: XCTestCase {
    private let d1 = AgentWindowD1Tests()
    private static let pref = "agentWindowCollapsedSections"

    override func setUp() {
        super.setUp()
        let saved = Preferences.defaults.object(forKey: Self.pref)
        addTeardownBlock {
            if let saved { Preferences.defaults.set(saved, forKey: Self.pref) } else { Preferences.defaults.removeObject(forKey: Self.pref) }
        }
        Preferences.defaults.removeObject(forKey: Self.pref)
    }

    private static let three = [SessionGroup(id: "g-rev", name: "Reviews", pattern: "-rev$"),
                                SessionGroup(id: "g-qa", name: "QA", pattern: "-qa$"),
                                SessionGroup(id: "g-doc", name: "Docs", pattern: "-doc$")]

    private func live(_ name: String) -> AgentSession { d1.session(name, .idle) }
    private func tabSession(_ name: String) -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: "/d", name: name), alias: "", activity: 0, state: .idle, agents: 0, version: "1.24.1")
    }
    private func storeWith(_ groups: [SessionGroup], _ names: [String]) -> AgentIslandStore {
        let s = d1.store(names.map(live))
        s.sessionGroups = groups
        return s
    }

    // MARK: - Sidebar

    func testThreeGroupsSplitIntoThreeSectionsInListOrderWithTheirNames() {
        let names = ["api", "api-doc", "api-qa", "web-rev", "web-qa"]
        let secs = AgentSidebar.sections(sessions: names.map(live), history: [], sort: .name, groups: Self.three,
                                         details: .all, now: AgentWindowD1Tests.now)
        XCTAssertEqual(secs.map(\.title), ["Sessions", "Reviews", "QA", "Docs"], "the list's order, not the sessions'")
        XCTAssertEqual(secs.map(\.id), ["Sessions", "group:g-rev", "group:g-qa", "group:g-doc"])
        XCTAssertEqual(secs.first { $0.id == "group:g-qa" }?.rows.compactMap { $0.session?.name }, ["api-qa", "web-qa"])
        XCTAssertEqual(AgentSidebar.reaged(secs, sessions: names.map(live), sort: .name, now: AgentWindowD1Tests.now + 60)?.map(\.id),
                       secs.map(\.id), "a clock-only rebuild keeps each group's fold key")
        let noDocs = AgentSidebar.sections(sessions: ["api", "web-rev"].map(live), history: [], sort: .name, groups: Self.three,
                                           details: .all, now: AgentWindowD1Tests.now)
        XCTAssertEqual(noDocs.map(\.title), ["Sessions", "Reviews", "QA", "Docs"], "#2106: a group with no sessions still shows")
        let none = AgentSidebar.sections(sessions: names.map(live), history: [], sort: .name, groups: [],
                                         details: .all, now: AgentWindowD1Tests.now)
        XCTAssertEqual(none.map(\.title), ["Sessions"], "an empty list: every session in Sessions, no group section")
    }

    func testAGroupFoldKeysByIdAndSurvivesARenameAndAReorder() {
        let store = storeWith(Self.three, ["api", "api-qa", "web-rev"])
        let m = d1.windowModel(store)
        m.setVisible(true)
        defer { m.close() }
        m.setCollapsed(AgentSidebar.groupFold("g-qa"), true)
        XCTAssertEqual(Preferences.defaults.stringArray(forKey: Self.pref), ["group:g-qa"], "stored in the #828 string form")
        XCTAssertFalse(m.navigableIDs.contains(.live(live("api-qa").key)), "the folded group's rows are not walked")
        // Renamed to Reviews' old name and moved first: the fold follows the id, not the title or the place.
        store.sessionGroups = [SessionGroup(id: "g-qa", name: "Reviews", pattern: "-qa$"), SessionGroup(id: "g-rev", name: "Reviews", pattern: "-rev$")]
        m.refresh()
        XCTAssertEqual(m.sections.map(\.title), ["Sessions", "Reviews", "Reviews"])
        XCTAssertEqual(m.sections.map { m.isCollapsed($0.id) }, [false, true, false], "two groups of one name never share a fold")
        let next = d1.windowModel(store)
        next.setVisible(true)
        defer { next.close() }
        XCTAssertTrue(next.isCollapsed(AgentSidebar.groupFold("g-qa")), "a new window reads it back")
        XCTAssertFalse(AgentSidebar.folds("Reviews"), "a group's name is never a fold key")
    }

    /// #1775: a group NAMED "History" is not the History section: its live sessions stay in the pane switcher and the header's
    /// count source. Red at base: both filters compared the title.
    func testAGroupNamedHistoryKeepsItsLiveSessionsInTheSwitcherAndTheCount() {
        let store = storeWith([SessionGroup(id: "g-hist", name: "History", pattern: "-h$")], ["api", "api-h"])
        let m = d1.windowModel(store)
        m.setVisible(true)
        defer { m.close() }
        XCTAssertEqual(m.sections.map(\.id), ["Sessions", "group:g-hist"], "control: the group section is titled History, id differs")
        XCTAssertEqual(m.sections.map(\.title), ["Sessions", "History"])
        let pane = UUID()
        XCTAssertEqual(Set(m.switcherRows(for: pane).map(\.row.title)), ["api", "api-h"], "the switcher keeps the group's session")
        XCTAssertEqual(m.sections.filter { $0.id != "History" }.flatMap(\.rows).count, 2, "the header's count source")
    }

    func testTheLegacySidekicksFoldCarriesToTheSidekicksGroup() {
        Preferences.defaults.set(["History", "Sidekicks"], forKey: Self.pref)
        XCTAssertEqual(Preferences.agentWindowCollapsedSections, ["History", "group:sidekicks"])
        let m = d1.windowModel(d1.store(["api", "api-qa"].map(live), pattern: "-qa"))
        m.setVisible(true)
        defer { m.close() }
        XCTAssertEqual(m.sections.map(\.id), ["Sessions", "group:sidekicks"])
        XCTAssertTrue(m.isCollapsed(AgentSidebar.groupFold(SessionGroup.sidekicksID)), "the pre-groups fold is kept")
        XCTAssertFalse(m.isCollapsed("Sidekicks"), "the title itself no longer folds")
        m.setCollapsed("Sessions", true)
        XCTAssertEqual(Preferences.defaults.stringArray(forKey: Self.pref), ["History", "Sessions", "group:sidekicks"],
                       "the next write stores the id form")
    }

    // MARK: - #2106: empty groups

    /// Every group shows by default, an empty one as a header with no rows, in list order; Hide empty groups leaves it
    /// out (the old rule); no group list: no group section either way. Red at base: the empty groups were dropped.
    func testAnEmptyGroupShowsByDefaultAndHideEmptyGroupsLeavesItOut() {
        func secs(_ hide: Bool?) -> [AgentSidebar.Section] {
            let s = ["api", "web-qa"].map(live)
            return hide.map { AgentSidebar.sections(sessions: s, history: [], sort: .name, groups: Self.three, details: .all,
                                                    now: AgentWindowD1Tests.now, hideEmptyGroups: $0) }
                ?? AgentSidebar.sections(sessions: s, history: [], sort: .name, groups: Self.three, details: .all, now: AgentWindowD1Tests.now)
        }
        XCTAssertEqual(secs(nil).map(\.id), ["Sessions", "group:g-rev", "group:g-qa", "group:g-doc"], "the default shows every group")
        XCTAssertEqual(secs(false).map { $0.rows.count }, [1, 0, 1, 0], "an empty group: a header, no rows")
        XCTAssertEqual(secs(true).map(\.id), ["Sessions", "group:g-qa"], "Hide empty groups: today's rule")
        let rev = secs(false).first { $0.id == "group:g-rev" }
        XCTAssertEqual(rev.flatMap(AgentSidebar.groupSessions)?.count, 0, "its header gets its (empty) rows: a menu")
        XCTAssertTrue(rev.map { AgentSidebar.drawsHeader($0, items: 0) } == true, "an empty group's header is drawn")
        XCTAssertFalse(AgentSidebar.drawsHeader(AgentSidebar.Section(title: "Sessions", rows: []), items: 0), "no other empty header")
        XCTAssertEqual(AgentSidebar.sections(sessions: ["api"].map(live), history: [], sort: .name, groups: [], details: .all,
                                             now: AgentWindowD1Tests.now).map(\.id), ["Sessions"], "Group tabs off: no group at all")
    }

    /// The preference is off when unset (scratch store) and is what the store hands the sidebar: the window follows a flip
    /// on the next groups publish (the controller sets it just before). Red at base: no such key; the window dropped empties.
    func testHideEmptyGroupsDefaultsOffAndTheWindowFollowsIt() {
        let key = "agentIslandHideEmptyGroups", saved = Preferences.defaults.object(forKey: key)
        defer { if let saved { Preferences.defaults.set(saved, forKey: key) } else { Preferences.defaults.removeObject(forKey: key) } }
        Preferences.defaults.removeObject(forKey: key)
        XCTAssertFalse(Preferences.agentIslandHideEmptyGroups, "off by default")
        Preferences.agentIslandHideEmptyGroups = true
        XCTAssertTrue(Preferences.defaults.bool(forKey: key), "stored under its key with the other group settings")
        XCTAssertTrue(Preferences.agentIslandHideEmptyGroups)
        let store = storeWith(Self.three, ["api", "api-qa"])
        XCTAssertFalse(store.hideEmptyGroups, "a new store shows every group")
        let m = d1.windowModel(store)
        m.setVisible(true)
        defer { m.close() }
        XCTAssertEqual(m.sections.map(\.id), ["Sessions", "group:g-rev", "group:g-qa", "group:g-doc"])
        store.hideEmptyGroups = true
        store.sessionGroups = store.sessionGroups   // the controller's order: the flag, then the groups' publish
        XCTAssertEqual(m.sections.map(\.id), ["Sessions", "group:g-qa"], "the setting on: the empty groups go")
        store.hideEmptyGroups = false
        store.sessionGroups = store.sessionGroups
        XCTAssertEqual(m.sections.map(\.id), ["Sessions", "group:g-rev", "group:g-qa", "group:g-doc"], "and come back")
    }

    /// An empty group's header is no row: the Command-N numbers count the sessions only, a fold on an empty group hides
    /// nothing, and Right with nothing shown unfolds the first folded section that has rows, not an empty group's.
    func testAnEmptyGroupKeepsTheNumbersAndTheFold() {
        let store = storeWith(Self.three, ["api", "api-qa"])
        let m = d1.windowModel(store)
        m.setVisible(true)
        defer { m.close() }
        let api = AgentSidebar.RowID.live(live("api").key), qa = AgentSidebar.RowID.live(live("api-qa").key)
        XCTAssertEqual(m.sections.map(\.id), ["Sessions", "group:g-rev", "group:g-qa", "group:g-doc"], "precondition: two empty groups")
        XCTAssertEqual(m.number(api), 1)
        XCTAssertEqual(m.number(qa), 2, "the empty Reviews header between takes no number")
        XCTAssertEqual(m.numberedItems().count, 2)
        m.setCollapsed(AgentSidebar.groupFold("g-rev"), true)
        XCTAssertTrue(m.isCollapsed(AgentSidebar.groupFold("g-rev")), "an empty group folds by its id")
        XCTAssertEqual(m.navigableIDs, [api, qa], "folding an empty group hides no row")
        XCTAssertEqual(m.number(qa), 2)
        let only = storeWith(Self.three, ["api-qa"])   // no Sessions section: Reviews (empty) is the first section
        let n = d1.windowModel(only)
        n.setVisible(true)
        defer { n.close() }
        n.setCollapsed(AgentSidebar.groupFold("g-rev"), true)
        n.setCollapsed(AgentSidebar.groupFold("g-qa"), true)
        n.select(nil)
        XCTAssertTrue(n.selection == nil && n.navigableIDs.isEmpty, "precondition: nothing shown, nothing selected")
        n.collapseSelected(false)
        XCTAssertFalse(n.isCollapsed(AgentSidebar.groupFold("g-qa")), "Right unfolds the folded group with rows")
        XCTAssertTrue(n.isCollapsed(AgentSidebar.groupFold("g-rev")), "not the empty one before it")
        XCTAssertEqual(n.selection, qa, "and selects its row")
    }

    // MARK: - Island

    func testTheIslandDrawsOneTabPerGroupWithSessionsInListOrder() {
        let store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry, sort: .name)
        store.sessionGroups = Self.three
        store.sessions = ["web-qa", "api", "web-rev", "api-qa"].map(tabSession)
        XCTAssertTrue(store.showsTabs)
        XCTAssertEqual(store.split.shownGroups.map { "\($0.group.name) (\($0.sessions.count))" }, ["Reviews (1)", "QA (2)"],
                       "Docs has no session: no tab")
        XCTAssertEqual(store.sessionTab.label, "Sessions")
        store.groupTab = "g-qa"
        XCTAssertEqual(store.sessionTab.label, "QA")
        XCTAssertEqual(store.visible.map(\.name), ["api-qa", "web-qa"])
        store.groupTab = "g-rev"
        XCTAssertEqual(store.visible.map(\.name), ["web-rev"])
        store.groupTab = "g-doc"
        XCTAssertEqual(store.sessionTab.label, "Sessions", "an empty group has no tab: Sessions shows")
        XCTAssertEqual(store.visible.map(\.name), ["api"])
    }

    func testRemovingOrEmptyingTheSelectedGroupFallsBackToSessions() {
        let store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry, sort: .name)
        store.sessionGroups = Self.three
        store.sessions = ["api", "api-qa", "web-rev"].map(tabSession)
        store.groupTab = "g-qa"
        store.sessionGroups = [Self.three[0], Self.three[2]]
        XCTAssertTrue(store.groupTab == nil, "the selected group removed")
        XCTAssertEqual(store.sessionTab.label, "Sessions")
        XCTAssertEqual(store.visible.map(\.name), ["api", "api-qa"])
        store.groupTab = "g-rev"
        store.sessions = ["api", "api-qa"].map(tabSession)
        XCTAssertTrue(store.groupTab == nil, "the selected group emptied")
        store.sessions = ["api-qa", "web-rev"].map(tabSession)
        XCTAssertEqual(store.sessionTab.label, "Sessions", "a group's new session does not switch the list")
        store.sessions = ["web-rev"].map(tabSession)
        XCTAssertEqual(store.sessionTab.label, "Reviews", "groups are all there is: the first with sessions")
    }

    func testStopAllAndEndAllOnAGroupTabNameThatGroup() {
        let store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry, sort: .name)
        store.sessionGroups = Self.three
        store.sessions = ["api", "api-qa", "web-qa", "web-rev"].map(tabSession)
        store.groupTab = "g-qa"
        let t = store.stopTargets(global: false)
        XCTAssertEqual(t.stop.map(\.name), ["api-qa", "web-qa"], "the shown group's rows only")
        store.ask(t.stop, skipped: t.skipped, global: false)
        XCTAssertEqual(store.asked.tab, "QA")
        XCTAssertEqual(store.stopAllQuestion, "Stop 2 sessions in QA?")
        XCTAssertEqual(store.killAllTargets.map(\.name), ["api-qa", "web-qa"])
        store.ask(store.sessions, skipped: 0, global: true)
        XCTAssertEqual(store.stopAllQuestion, "Stop 4 sessions in every tab?")
    }

    func testAnEmptyListDrawsNoGroupTab() {
        let store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry, sort: .name)
        store.sessionGroups = []
        store.sessions = ["api", "api-qa"].map(tabSession)
        XCTAssertFalse(store.showsTabs)
        XCTAssertTrue(store.split.shownGroups.isEmpty)
        XCTAssertEqual(store.visible.map(\.name), ["api", "api-qa"])
    }

    /// Eight groups of 32-byte names: the tab row scrolls sideways inside the island's width (no wrap, no spill).
    func testManyGroupTabsScrollInsideTheIslandWidth() {
        let groups = (1...8).map { SessionGroup(id: "g\($0)", name: String(repeating: "W", count: 30) + "-\($0)", pattern: "-g\($0)$") }
        let store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry, sort: .name)
        store.sessionGroups = groups
        store.sessions = (1...8).map { tabSession("api-g\($0)") } + [tabSession("api")]
        store.expanded = true
        XCTAssertEqual(store.split.shownGroups.count, 8)
        let width = store.size.width
        let host = NSHostingController(rootView: AgentIslandView(store: store).tabRow)
        let fit = host.sizeThatFits(in: CGSize(width: width, height: AgentIslandGeometry.tabsHeight))
        XCTAssertLessThanOrEqual(fit.width, width + 0.5, "the row never spills past the island")
        XCTAssertLessThanOrEqual(fit.height, AgentIslandGeometry.tabsHeight + 0.5, "one line: no tab wraps")
    }
}
