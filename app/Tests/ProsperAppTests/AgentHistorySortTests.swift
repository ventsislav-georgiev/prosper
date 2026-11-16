import AppKit
import XCTest
@testable import ProsperApp

/// #1347: History is sorted as dch's picker does (picker.c pk_hcmp at v1.78.0): pinned first, then the rest, each by
/// the shown title, case folded, digit runs by value; the cap (50 names) keeps the newest, the sort comes after.
/// The window, the island and the phone share AgentIsland.cappedHistory. Fakes only: no dch runs, nothing is shown.
final class AgentHistorySortTests: XCTestCase {
    private static let dir = "/Users/example/.dch", now: TimeInterval = 2_000_000_000
    private let notched = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)

    private func record(_ name: String, ago: TimeInterval = 100, pinned: Bool = false, alias: String = "") -> DchHistoryRecord {
        DchHistoryRecord(key: AgentSessionKey(dir: Self.dir, name: name), alias: alias, started: Self.now - ago - 60,
                         updated: Self.now - ago, ended: Self.now - ago, end: "stopped", pinned: pinned)
    }

    private func names(_ list: [String], pinned: Set<String> = []) -> [String] {
        AgentIsland.cappedHistory(list.map { record($0, pinned: pinned.contains($0)) }).map(\.name)
    }

    func testMixedCaseSortsFoldedNotByByteValue() {
        XCTAssertEqual(names(["beta", "Alpha", "gamma", "Delta"]), ["Alpha", "beta", "Delta", "gamma"])
    }

    /// dch's pk_natcmp: "cost-1" < "cost-2" < "cost-10" (digit runs by value) < "cost-qa" (a digit before a letter).
    func testDigitsAndDashesOrderAsDchOrdersThem() {
        XCTAssertEqual(names(["cost-qa", "cost-10", "cost-2", "cost-1"]), ["cost-1", "cost-2", "cost-10", "cost-qa"])
        XCTAssertEqual(names(["dch-qa", "dch", "dch-2"]), ["dch", "dch-2", "dch-qa"], "a prefix first")
    }

    /// '-' (0x2d) < '.' (0x2e) < a digit < a letter; nothing is stripped.
    func testADotOrdersByItsByteValue() {
        XCTAssertEqual(names(["example2", "example.user", "example-b", "example"]),
                       ["example", "example-b", "example.user", "example2"])
    }

    /// "a01" and "a1" tie on the title: the newest first (dch's `when`), then the name.
    func testATieGoesToTheNewestFirst() {
        let rows = AgentIsland.cappedHistory([record("a1", ago: 500), record("a01", ago: 100), record("A1", ago: 100)])
        XCTAssertEqual(rows.map(\.name), ["A1", "a01", "a1"])
    }

    func testPinnedLeadThenTheRestEachAToZ() {
        let rows = AgentIsland.cappedHistory([record("alpha"), record("zed", pinned: true), record("Carl"),
                                              record("Bob", pinned: true), record("aaa", alias: "Zulu")])
        XCTAssertEqual(rows.map(\.name), ["Bob", "zed", "alpha", "Carl", "aaa"], "the shown title (alias) decides: Zulu last")
        XCTAssertEqual(rows.map(\.pinned), [true, true, false, false, false])
    }

    /// 60 unpinned names, n59 the newest, and two pins that are the oldest: 48 unpinned rows fit under the cap of 50,
    /// the newest 48 (n12 to n59), and then they are sorted (not the 48 first of the sorted list: n0 to n47).
    func testTheCapKeepsTheNewestThenSorts() {
        let unpinned = (0..<60).map { record("n\($0)", ago: TimeInterval(1000 - $0)) }
        let pins = [record("pz", ago: 9000, pinned: true), record("pa", ago: 9500, pinned: true)]
        let rows = AgentIsland.cappedHistory((unpinned + pins).sorted { $0.lastSeen > $1.lastSeen })
        XCTAssertEqual(rows.count, AgentIsland.historyCap)
        XCTAssertEqual(rows.map(\.name), ["pa", "pz"] + (12..<60).map { "n\($0)" })
    }

    /// The island's tab and the window's section read the same list: pinned first, A to Z, a live name left out.
    @MainActor
    func testTheIslandAndTheWindowAgree() {
        let history = [record("zeta"), record("beta", pinned: true), record("Alpha"), record("cost-10"), record("cost-2"),
                       record("live", pinned: true), record("Yak", pinned: true)]
        let session = AgentSession(key: AgentSessionKey(dir: Self.dir, name: "live"), alias: "", activity: Self.now - 60,
                                   state: .working, agents: 0, version: "1.25.0")
        let store = AgentIslandStore(geometry: notched)
        store.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 25, 0])
        store.sessions = [session]
        store.history = history
        store.historyTab = true
        let want = ["beta", "Yak", "Alpha", "cost-2", "cost-10", "zeta"]
        XCTAssertEqual(store.shownHistory.map(\.name), want)
        let rows = AgentSidebar.sections(sessions: [session], history: history, sort: .name, sidekickPattern: "-qa",
                                         details: .all, now: Self.now).first { $0.title == "History" }?.rows ?? []
        XCTAssertEqual(rows.map(\.title), want)
    }
}
