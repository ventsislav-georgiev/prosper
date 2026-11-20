import AppKit
import XCTest
@testable import ProsperApp

/// #1364: a History record whose session is live in its socket dir is not listed while the live row shows (the
/// window's sections, the island's tab and the phone share AgentIsland.cappedHistory). It comes back, pin and all,
/// when the session ends. Fakes only: no dch runs, no window or island is shown.
final class AgentHistoryLiveDedupeTests: XCTestCase {
    private static let dir = "/Users/example/.dch", otherDir = "/Users/example/.dch-iso", now: TimeInterval = 2_000_000_000
    private let notched = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)

    private func live(_ name: String, dir: String = AgentHistoryLiveDedupeTests.dir) -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: dir, name: name), alias: "", activity: Self.now - 60, state: .working,
                     agents: 0, version: "1.25.0")
    }

    /// `file` "" is the name's own record; "<name>.<ended>" the aside one a cold start leaves (#714, #743).
    private func record(_ name: String, dir: String = AgentHistoryLiveDedupeTests.dir, file: String = "", pinned: Bool = false,
                        cwd: String = "/Users/example/work/acme") -> DchHistoryRecord {
        DchHistoryRecord(key: AgentSessionKey(dir: dir, name: name), cwd: cwd, started: Self.now - 9 * 86400 - 3600,
                         updated: Self.now - 9 * 86400, ended: Self.now - 9 * 86400, end: "stopped", pinned: pinned, file: file)
    }

    /// The window's History section: titles and pins.
    private func windowHistory(_ sessions: [AgentSession], _ history: [DchHistoryRecord]) -> [String: Bool] {
        let rows = AgentSidebar.sections(sessions: sessions, history: history, sort: .name, groups: SessionGroup.sidekicks("-qa"),
                                         details: .all, now: Self.now).first { $0.title == "History" }?.rows ?? []
        return Dictionary(rows.map { ($0.title, $0.record?.pinned ?? false) }, uniquingKeysWith: { a, _ in a })
    }

    @MainActor
    private func island(_ sessions: [AgentSession], _ history: [DchHistoryRecord]) -> AgentIslandStore {
        let store = AgentIslandStore(geometry: notched)
        store.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 25, 0])
        store.sessions = sessions
        store.history = history
        store.historyTab = true
        return store
    }

    /// The operator's case: live weekly and its pinned record in the same socket dir.
    @MainActor
    func testLiveWeeklyHidesItsPinnedRecordUntilItEnds() {
        let history = [record("weekly", pinned: true), record("api")]
        XCTAssertEqual(windowHistory([live("weekly")], history), ["api": false])
        let store = island([live("weekly")], history)
        XCTAssertEqual(store.cappedHistory.map(\.name), ["api"])
        XCTAssertEqual(store.shownHistory.map(\.name), ["api"])
        XCTAssertEqual(windowHistory([], history), ["weekly": true, "api": false], "ended: back, pinned")
        store.sessions = []
        XCTAssertEqual(store.cappedHistory.map { [$0.name: $0.pinned] }, [["weekly": true], ["api": false]])
    }

    /// The cause found: a cold start under the name moved its record aside (file weekly.<ended>, pin copied); the
    /// aside record keeps the live name and the socket dir, so at TIP it was listed next to the live row.
    @MainActor
    func testAsideRecordOfALiveNameIsNotListed() {
        let aside = record("weekly", file: "weekly.1762000000", pinned: true)
        XCTAssertTrue(aside.isAside)
        XCTAssertEqual(aside.id, AgentSessionKey(dir: Self.dir, name: "weekly.1762000000"))
        XCTAssertEqual(AgentIsland.cappedHistory([aside], live: [AgentSessionKey(dir: Self.dir, name: "weekly")]), [])
        XCTAssertEqual(windowHistory([live("weekly")], [aside]), [:])
        XCTAssertEqual(island([live("weekly")], [aside]).cappedHistory, [])
        XCTAssertEqual(windowHistory([], [aside]), ["weekly": true])
    }

    /// An unpinned record of a live name is not listed either.
    @MainActor
    func testUnpinnedRecordOfALiveNameIsNotListed() {
        XCTAssertEqual(windowHistory([live("api")], [record("api")]), [:])
        XCTAssertEqual(island([live("api")], [record("api")]).cappedHistory, [])
        XCTAssertEqual(windowHistory([], [record("api")]), ["api": false])
    }

    /// The key is the socket dir and the name, as dch's (one live session per name per socket dir): another socket
    /// dir is another session, its record stays; the cwd is not part of it (a trailing slash there changes nothing).
    @MainActor
    func testTheRuleIsTheSocketDirAndTheNameNotTheCwd() {
        let far = record("api", dir: Self.otherDir)
        XCTAssertEqual(windowHistory([live("api")], [far]), ["api": false], "another socket dir: listed")
        XCTAssertEqual(island([live("api")], [far]).cappedHistory.map(\.key), [AgentSessionKey(dir: Self.otherDir, name: "api")])
        let slash = record("api", cwd: "/Users/example/work/acme/")
        XCTAssertEqual(windowHistory([live("api")], [slash]), [:], "same key, whatever the record's cwd: hidden")
    }

    /// A sidekick follows the same rule: live api-qa hides its record; the main's record (not live) stays.
    @MainActor
    func testLiveSidekickHidesOnlyItsOwnRecord() {
        let history = [record("api-qa", pinned: true), record("api")]
        XCTAssertEqual(windowHistory([live("api-qa")], history), ["api": false])
        XCTAssertEqual(island([live("api-qa")], history).cappedHistory.map(\.name), ["api"])
        XCTAssertEqual(windowHistory([], history), ["api-qa": true, "api": false])
    }

    /// Back after the end, the row acts as before: Resume, Pin (here an unpin) and, unpinned, Remove reach the record.
    @MainActor
    func testTheRowThatComesBackActsOnItsRecord() {
        let pinned = record("weekly", pinned: true), plain = record("api")
        let store = island([live("weekly"), live("api")], [pinned, plain])
        var calls: [String] = []
        func drawn() -> [AgentIslandView.HistoryDrawn] {
            AgentIslandView(store: store, onResume: { calls.append("resume " + $0.name) }, onPin: { calls.append("pin " + $0.name) },
                            onRemove: { calls.append("remove " + $0.name) }).historyDrawn
        }
        XCTAssertEqual(drawn().count, 0)
        store.sessions = []
        let rows = drawn()
        XCTAssertEqual(rows.map(\.record), [pinned, plain])
        for r in rows { r.resume(); r.pin?(); r.remove?() }
        XCTAssertEqual(calls, ["resume weekly", "pin weekly", "resume api", "pin api", "remove api"], "a pinned row has no Remove")
    }
}
