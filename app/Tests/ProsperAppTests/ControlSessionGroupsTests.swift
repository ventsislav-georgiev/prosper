import Foundation
import XCTest
@testable import ProsperApp

/// #1856: sessions.groups.list/set, island.showGroup, history.pin/unpin. Groups live in `Preferences.defaults` (the
/// in-memory XCTest store; the keys are put back at teardown); the island's tab clicks and the pin toggle are recorders;
/// the island store is a test store. No dch, no controller, no window, no real notice.
@MainActor
final class ControlSessionGroupsTests: XCTestCase {
    let base = AgentWindowD1Tests()
    var shown: [String?] = []
    var historyShown = 0
    var stored: [[SessionGroup]] = []
    var pinned: [String] = []
    var notices: [String] = []

    func withSeams(store st: AgentIslandStore? = nil, _ body: (ControlChanges) throws -> Void) rethrows {
        let keys = ["agentIslandSessionGroups", "agentIslandSessionGroupsUpdated", "agentIslandSidekickPattern",
                    "agentIslandSidekickPatternUpdated", "agentIslandSidekickTabs"]
        let savedKeys = keys.map { Preferences.defaults.object(forKey: $0) }
        let saved = (ControlSessions.model, ControlSessions.islandStore, ControlSessionGroups.store, ControlSessionGroups.showGroup,
                     ControlSessionGroups.showHistory, ControlSessionGroups.pinRecord)
        defer {
            for (k, v) in zip(keys, savedKeys) {
                if let v { Preferences.defaults.set(v, forKey: k) } else { Preferences.defaults.removeObject(forKey: k) }
            }
            (ControlSessions.model, ControlSessions.islandStore, ControlSessionGroups.store, ControlSessionGroups.showGroup,
             ControlSessionGroups.showHistory, ControlSessionGroups.pinRecord) = saved
        }
        shown = []; historyShown = 0; stored = []; pinned = []; notices = []
        ControlSessions.model = { nil }
        ControlSessions.islandStore = { st }
        // The store seam keeps Settings' write and drops only the controller's regroup (the shared controller).
        ControlSessionGroups.store = { Preferences.editSessionGroups($0); self.stored.append($0) }
        ControlSessionGroups.showGroup = { self.shown.append($0); st?.groupTab = $0; st?.historyTab = false }
        ControlSessionGroups.showHistory = { self.historyShown += 1; st?.historyTab = true }
        ControlSessionGroups.pinRecord = { self.pinned.append($0.name) }
        let changes = ControlChanges()
        changes.present = { text, _ in self.notices.append(text) }
        try body(changes)
    }

    func group(_ name: String, _ pattern: String, id: String? = nil) -> ControlJSON {
        var o: [String: ControlJSON] = ["name": .string(name), "pattern": .string(pattern)]
        if let id { o["id"] = .string(id) }
        return .object(o)
    }

    func groups(_ rows: ControlJSON...) -> [String: ControlJSON] { ["groups": .array(rows)] }

    func refused<T>(_ expr: @autoclosure () throws -> T, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) {
            XCTAssertEqual(($0 as? ControlError)?.message, message, file: file, line: line)
        }
    }

    func names(_ j: ControlJSON) -> [String] {
        guard case .object(let o) = j, case .array(let a)? = o["groups"] else { return [] }
        return a.compactMap { if case .object(let r) = $0, case .string(let n)? = r["name"] { n } else { nil } }
    }

    // MARK: - sessions.groups.list / set

    /// The list reads the stored groups in order, with the tabs toggle; the shown strings are cleaned outside text.
    func testListReadsTheStoredGroupsAndTheToggle() throws {
        try withSeams { _ in
            Preferences.agentIslandSessionGroups = [SessionGroup(id: "a", name: "Qa\u{202E}", pattern: "qa"), SessionGroup(id: "b", name: "Docs", pattern: "doc")]
            Preferences.agentIslandSidekickTabs = true
            let j = ControlSessionGroups.list()
            XCTAssertEqual(names(j), ["Qa", "Docs"])
            guard case .object(let o) = j else { return XCTFail("object") }
            XCTAssertEqual(o["tabs"], .bool(true))
            Preferences.agentIslandSidekickTabs = false
            guard case .object(let off) = ControlSessionGroups.list() else { return XCTFail("object") }
            XCTAssertEqual(off["tabs"], .bool(false))
        }
    }

    /// set stores through Settings' path (stamps move), keeps the id of a same-named group, notices once, and undo stores
    /// the old list back.
    func testSetStoresReusesIdsAndUndoRestoresTheOldList() throws {
        try withSeams { changes in
            Preferences.agentIslandSessionGroups = [SessionGroup(id: "keep", name: "Qa", pattern: "qa")]
            let stamp = Preferences.agentIslandSessionGroupsUpdated
            let c = try ControlSessionGroups.set(groups(group("qa", "api-qa"), group("Docs", "doc")))
            let now = Preferences.agentIslandSessionGroups
            XCTAssertEqual(now.map(\.name), ["qa", "Docs"])
            XCTAssertEqual(now.first?.id, "keep", "the same name keeps its id: its tab stays chosen")
            XCTAssertEqual(now.last?.id.count, 8)
            XCTAssertEqual(now.first?.pattern, "api-qa")
            XCTAssertTrue(Preferences.agentIslandSessionGroupsUpdated > stamp, "stamped as a Settings save is")
            XCTAssertEqual(stored.count, 1)
            XCTAssertEqual(c.result, .number(2))
            XCTAssertNotNil(c.undo)
            let entry = changes.record(command: "sessions.groups.set", summary: c.summary, verb: c.verb, undo: c.undo)
            XCTAssertEqual(notices.last, "Agent set session groups: groups qa, Docs")
            XCTAssertTrue(changes.undo(entry.id))
            XCTAssertEqual(Preferences.agentIslandSessionGroups, [SessionGroup(id: "keep", name: "Qa", pattern: "qa")])
            XCTAssertEqual(stored.count, 2)
        }
    }

    /// [] clears the list; the same list again changes nothing.
    func testSetEmptyClearsAndTheSameListIsRefused() throws {
        try withSeams { _ in
            Preferences.agentIslandSessionGroups = [SessionGroup(id: "a", name: "Qa", pattern: "qa")]
            refused(try ControlSessionGroups.set(groups(group("Qa", "qa", id: "a"))), "these are already the groups")
            XCTAssertEqual(stored.count, 0)
            _ = try ControlSessionGroups.set(["groups": .array([])])
            XCTAssertEqual(Preferences.agentIslandSessionGroups, [])
        }
    }

    /// A row Settings would not save refuses the whole call with the row's reason and stores nothing.
    func testSetRefusesWhatSettingsWouldNotSaveAndStoresNothing() throws {
        try withSeams { _ in
            let before = [SessionGroup(id: "a", name: "Qa", pattern: "qa")]
            Preferences.agentIslandSessionGroups = before
            refused(try ControlSessionGroups.set(groups(group("Ok", "ok"), group("", "x"))),
                    "group 2: A name is 1-32 bytes, without \"=\": not saved")
            refused(try ControlSessionGroups.set(groups(group("a=b", "x"))), "group 1: A name is 1-32 bytes, without \"=\": not saved")
            refused(try ControlSessionGroups.set(groups(group(String(repeating: "n", count: 33), "x"))),
                    "group 1: A name is 1-32 bytes, without \"=\": not saved")
            refused(try ControlSessionGroups.set(groups(group("History", "x"))), "group 1: dch uses this name for its own tab: not saved")
            refused(try ControlSessionGroups.set(groups(group("Docs", "  "))), "group 1: No pattern yet: not saved")
            refused(try ControlSessionGroups.set(groups(group("Docs", "(unclosed"))), "group 1: Not a valid regex: not saved")
            refused(try ControlSessionGroups.set(groups(group("Docs", ".*"))), "group 1: Matches every session: not saved")
            refused(try ControlSessionGroups.set(groups(group("Docs", "a"), group("docs", "b"))), "group 1: Another group has this name: not saved")
            refused(try ControlSessionGroups.set(groups(group("A", "a", id: "x"), group("B", "b", id: "x"))), "two groups have the same id")
            refused(try ControlSessionGroups.set(groups(group("Docs\u{202E}", "a"))), "group 1 has a control or hidden character")
            refused(try ControlSessionGroups.set(groups(group("Docs", "a\nb"))), "group 1 has a control or hidden character")
            refused(try ControlSessionGroups.set(groups(.object(["name": .string("Docs")]))), "group 1 needs a string name and a string pattern")
            refused(try ControlSessionGroups.set(["groups": .string("x")]), "argument 'groups' must be a list")
            refused(try ControlSessionGroups.set(["groups": .array((0..<9).map { group("g\($0)", "p\($0)") })]), "at most 8 groups")
            XCTAssertEqual(Preferences.agentIslandSessionGroups, before)
            XCTAssertEqual(stored.count, 0)
            XCTAssertEqual(notices.count, 0)
        }
    }

    // MARK: - island.showGroup

    func showStore() -> AgentIslandStore {
        base.store([base.session("api-qa", .idle), base.session("api", .idle)], history: [base.record("old")], pattern: "qa")
    }

    /// A tab by id or by name (case folded) or "sessions"; undo shows the tab before, History included; a tab already
    /// shown, an unknown one, and a group with no session are refused.
    func testShowGroupPicksTheTabAndUndoShowsTheOneBefore() throws {
        let st = showStore()
        try withSeams(store: st) { changes in
            var c = try ControlSessionGroups.show(["group": .string("SIDEKICKS")])
            XCTAssertEqual(shown, ["sidekicks"])
            XCTAssertEqual(c.result, .string("sidekicks"))
            refused(try ControlSessionGroups.show(["group": .string("sidekicks")]), "that tab is already shown")
            c.undo?()
            XCTAssertEqual(shown, ["sidekicks", nil])
            c = try ControlSessionGroups.show(["group": .string("sidekicks")])
            c = try ControlSessionGroups.show(["group": .string("Sessions")])
            XCTAssertEqual(c.result, .string("sessions"))
            XCTAssertTrue(shown.last == .some(nil))
            c.undo?()
            XCTAssertTrue(shown.last == .some("sidekicks"))
            // History chosen: showing a group is a change; its undo comes back to History.
            st.historyTab = true
            c = try ControlSessionGroups.show(["group": .string("sidekicks")])
            c.undo?()
            XCTAssertEqual(historyShown, 1)
            refused(try ControlSessionGroups.show(["group": .string("nope")]),
                    "no group tab nope: a group has a tab only while it has a session")
            refused(try ControlSessionGroups.show([:]), "argument 'group' is empty")
            _ = changes
        }
    }

    /// No group with a session, no tabs: refused; no island: refused.
    func testShowGroupRefusesWithoutTabsOrIsland() throws {
        try withSeams(store: base.store([base.session("api", .idle)])) { _ in
            XCTAssertThrowsError(try ControlSessionGroups.show(["group": .string("sessions")]))
            XCTAssertTrue(shown.isEmpty)
        }
        try withSeams(store: nil) { _ in
            refused(try ControlSessionGroups.show(["group": .string("x")]), ControlSessions.islandOff)
        }
    }

    // MARK: - history.pin / history.unpin

    func pinStore(version: [Int]? = [1, 30, 0]) -> AgentIslandStore {
        var web = base.record("web")
        web.pinned = true
        let st = base.store([], history: [base.record("api"), web, base.record("--all")])
        st.controlDch = version.map { DchCommand.Binary(path: "/fake/dch", version: $0) }
        return st
    }

    /// pin toggles the History row through the controller's pin; undo toggles back only while the record still is as the
    /// call left it; already pinned / unpinned and an unknown id are refused before anything runs.
    func testPinAndUnpinToggleAndUndoOnlyWhileTheRecordIsAsLeft() throws {
        let st = pinStore()
        try withSeams(store: st) { changes in
            refused(try ControlSessionGroups.pin(["id": .string("web")], pinned: true), "web is already pinned")
            refused(try ControlSessionGroups.pin(["id": .string("api")], pinned: false), "api is already unpinned")
            refused(try ControlSessionGroups.pin(["id": .string("zzz")], pinned: true), "no History record zzz (sessions.history lists them)")
            XCTAssertTrue(pinned.isEmpty)
            let c = try ControlSessionGroups.pin(["id": .string("api")], pinned: true)
            XCTAssertEqual(pinned, ["api"])
            XCTAssertEqual(c.verb, "pinned")
            // The record is not pinned yet (dch runs off main): an undo now finds it as it was and does nothing.
            c.undo?()
            XCTAssertEqual(pinned, ["api"])
            st.history[0].pinned = true
            c.undo?()
            XCTAssertEqual(pinned, ["api", "api"])
            let u = try ControlSessionGroups.pin(["id": .string("web")], pinned: false)
            XCTAssertEqual(pinned.last, "web")
            XCTAssertEqual(u.verb, "unpinned")
            XCTAssertEqual(u.summary, "web")
            _ = changes
        }
    }

    /// The History menu's gate: an old dch and a flag-shaped name refuse; nothing runs.
    func testPinIsRefusedOnTheMenusGate() throws {
        try withSeams(store: pinStore(version: [1, 24, 0])) { _ in
            XCTAssertThrowsError(try ControlSessionGroups.pin(["id": .string("api")], pinned: true))
            XCTAssertTrue(pinned.isEmpty)
        }
        try withSeams(store: pinStore()) { _ in
            XCTAssertThrowsError(try ControlSessionGroups.pin(["id": .string("--all")], pinned: true))
            XCTAssertTrue(pinned.isEmpty)
        }
    }

    // MARK: - registry

    /// The read is not a change; the four others are; forget and clear stay unregistered.
    func testRegistryDeclaresOneReadAndFourChanges() {
        var r = ControlRegistry()
        ControlRegistry.registerSessionGroups(&r)
        XCTAssertEqual(r.commands.keys.sorted(), ["history.pin", "history.unpin", "island.showGroup", "sessions.groups.list", "sessions.groups.set"])
        XCTAssertEqual(r.commands["sessions.groups.list"]?.mutates, false)
        for n in ["history.pin", "history.unpin", "island.showGroup", "sessions.groups.set"] { XCTAssertEqual(r.commands[n]?.mutates, true, n) }
        XCTAssertEqual(r.commands["sessions.groups.set"]?.args["groups"]?.type, "array")
    }
}
