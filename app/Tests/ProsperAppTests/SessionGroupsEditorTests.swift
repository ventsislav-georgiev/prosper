import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1758 (#1755 phase B): the Settings groups editor. The rules on the editor value (add, rename, reorder, remove, what is
/// not saved and why) round-trip through Preferences on the XCTest scratch suite; the section is rendered offscreen in a
/// never-shown window and read on its accessibility tree. Nothing is clicked, no event is posted; each row puts the keys back.
final class SessionGroupsEditorTests: XCTestCase {
    private static let keys = ["agentIslandSessionGroups", "agentIslandSidekickPattern", "agentIslandSidekickPatternUpdated",
                               "agentIslandSidekickTabs", "agentIslandSessionGroupsUpdated"]

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

    private static let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Add

    func testAddAppendsGroupNUpToEightThenAddIsOff() {
        var e = SessionGroupsEditor([])
        for _ in 0..<10 { e.add() }
        XCTAssertEqual(e.rows.count, SessionGroup.maxCount)
        XCTAssertFalse(e.canAdd)
        XCTAssertEqual(e.rows.map(\.name), (1...8).map { "Group \($0)" })
        XCTAssertTrue(e.rows.allSatisfy { $0.pattern.isEmpty && $0.id != SessionGroup.sidekicksID && $0.id.count == 8 })
        XCTAssertEqual(Set(e.rows.map(\.id)).count, 8, "a new id each time")
        var taken = SessionGroupsEditor([Self.g("x", "group 2", "-x$")])
        taken.add()
        XCTAssertEqual(taken.rows.last?.name, "Group 3", "a name a row has is skipped")
    }

    // MARK: - Round trips

    @MainActor
    func testRenameReorderAndRemoveSidekicksRoundTrip() {
        var e = SessionGroupsEditor()
        XCTAssertEqual(e.rows, [Self.g(SessionGroup.sidekicksID, "Sidekicks", "-qa")], "the migrated default group")
        e.add()
        guard e.rows.count == 2 else { return XCTFail("Sidekicks and the new row") }
        let id = e.rows.last?.id ?? ""
        e.rows[e.rows.count - 1].name = "Reviews"
        e.rows[e.rows.count - 1].pattern = "-rev$"
        SessionGroupsEditor.save(e, now: Self.t0)
        XCTAssertEqual(Preferences.agentIslandSessionGroups, [Self.g(SessionGroup.sidekicksID, "Sidekicks", "-qa"), Self.g(id, "Reviews", "-rev$")])
        e.rows[0].name = "QA"   // rename
        SessionGroupsEditor.save(e, now: Self.t0)
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.name), ["QA", "Reviews"])
        e.move(id, by: -1)   // reorder
        e.move(id, by: -1)   // already first: nothing
        SessionGroupsEditor.save(e, now: Self.t0)
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.name), ["Reviews", "QA"])
        XCTAssertEqual(SessionGroupsEditor(), e, "a fresh editor reads what was saved")
        e.remove(SessionGroup.sidekicksID)   // Sidekicks is an ordinary row
        SessionGroupsEditor.save(e, now: Self.t0)
        XCTAssertEqual(Preferences.agentIslandSessionGroups, [Self.g(id, "Reviews", "-rev$")])
        e.remove(id)
        SessionGroupsEditor.save(e, now: Self.t0)
        XCTAssertEqual(Preferences.agentIslandSessionGroups, [], "every group removed: no split")
        XCTAssertTrue(Preferences.defaults.object(forKey: "agentIslandSessionGroups") != nil, "stored as [], not the migrated default")
        XCTAssertEqual(Preferences.agentIslandSidekickPattern, "")
    }

    @MainActor
    func testAnUnchangedEditorStoresNothing() {
        SessionGroupsEditor.save(SessionGroupsEditor(), now: Self.t0)
        XCTAssertTrue(Preferences.defaults.object(forKey: "agentIslandSessionGroups") == nil, "the migration stays lazy")
        XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, 0)
    }

    // MARK: - Not saved, and why

    @MainActor
    func testEachBadInputShowsItsReasonAndLeavesTheStoredListUnchanged() {
        let start = [Self.g(SessionGroup.sidekicksID, "Sidekicks", "-qa"), Self.g("r1", "Reviews", "-rev$")]
        Preferences.agentIslandSessionGroups = start
        Preferences.agentIslandSidekickPatternUpdated = 7
        // `other`: the other row's name, for the duplicate.
        let cases: [(what: String, edit: (inout SessionGroup, String) -> Void, reason: String)] = [
            ("invalid regex", { g, _ in g.pattern = "a(" }, "Not a valid regex: not saved"),
            ("match everything", { g, _ in g.pattern = ".*" }, "Matches every session: not saved"),
            ("bad name", { g, _ in g.name = "a=b" }, "A name is 1-32 bytes, without \"=\": not saved"),
            ("empty name", { g, _ in g.name = "  " }, "A name is 1-32 bytes, without \"=\": not saved"),
            ("duplicate name", { g, other in g.name = " \(other.uppercased()) " }, "Another group has this name: not saved"),
            ("no pattern", { g, _ in g.pattern = "" }, "No pattern yet: not saved"),
        ]
        for c in cases {
            for i in [0, 1] {
                var e = SessionGroupsEditor()
                guard e.rows.count == 2 else { return XCTFail("the stored two rows") }
                c.edit(&e.rows[i], e.rows[1 - i].name)
                XCTAssertEqual(e.reason(e.rows[i]), c.reason, "\(c.what) on row \(i)")
                XCTAssertEqual(e.reason(e.rows[1 - i]) != nil, c.what == "duplicate name",
                               "\(c.what) on row \(i): only a duplicate flags the other row too")
                SessionGroupsEditor.save(e, now: Self.t0)
                XCTAssertEqual(Preferences.agentIslandSessionGroups, start, "\(c.what) on row \(i): stored list unchanged")
                XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, 7, "\(c.what) on row \(i): no stamp")
            }
        }
        // A new row that is not valid is kept in the editor and not saved; a valid edit beside it is.
        var e = SessionGroupsEditor()
        e.add()
        guard e.rows.count == 3 else { return XCTFail("two stored rows and the new one") }
        e.rows[1].pattern = "-rev2$"
        SessionGroupsEditor.save(e, now: Self.t0)
        XCTAssertEqual(e.rows.count, 3)
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.pattern), ["-qa", "-rev2$"], "the empty new row is left out")
        e.rows[2].pattern = "b("
        SessionGroupsEditor.save(e, now: Self.t0)
        XCTAssertEqual(Preferences.agentIslandSessionGroups.count, 2, "an invalid new row is left out")
        e.rows[2].pattern = "-new$"
        SessionGroupsEditor.save(e, now: Self.t0)
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.name), ["Sidekicks", "Reviews", "Group 3"])
    }

    // MARK: - The phone's stamp

    @MainActor
    func testTheFirstGroupsPatternMovesTheStampASecondGroupsDoesNot() {
        var e = SessionGroupsEditor([Self.g(SessionGroup.sidekicksID, "Sidekicks", "-qa"), Self.g("r1", "Reviews", "-rev$")])
        SessionGroupsEditor.save(e, now: Self.t0)
        XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, 0, "the first pattern did not change")
        e.rows[1].pattern = "-review$"
        SessionGroupsEditor.save(e, now: Self.t0)
        XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, 0, "a second group's edit does not stamp")
        e.rows[0].pattern = "-(qa|test)$"
        SessionGroupsEditor.save(e, now: Self.t0)
        XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, 1_000_000_000)
        XCTAssertEqual(Preferences.agentIslandSidekickPattern, "-(qa|test)$", "the stamp and the list agree")
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.pattern), ["-(qa|test)$", "-review$"])
        e.move("r1", by: -1)   // a new first group is a new first pattern
        SessionGroupsEditor.save(e, now: Self.t0.addingTimeInterval(1))
        XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, 1_000_001_000)
        XCTAssertEqual(Preferences.agentIslandSidekickPattern, "-review$")
    }

    // MARK: - The section, offscreen

    @MainActor
    private func axTree(until done: ([AXTreeNode]) -> Bool) -> [AXTreeNode] {
        AXTreeSupport.tree(AgentIslandListSection().frame(width: sz(560)).preferredColorScheme(.dark),
                           CGSize(width: sz(560), height: sz(1200)), until: done)
    }

    @MainActor
    func testEveryControlNamesItsGroupAndAddIsOffAtEight() {
        Preferences.agentIslandSidekickTabs = true
        Preferences.agentIslandSessionGroups = [Self.g(SessionGroup.sidekicksID, "Sidekicks", "-qa"), Self.g("r1", "Reviews", "-rev$")]
        let names = ["Name of group Sidekicks", "Pattern of group Sidekicks", "Move group Sidekicks up", "Move group Sidekicks down",
                     "Remove group Sidekicks", "Name of group Reviews", "Pattern of group Reviews", "Move group Reviews up",
                     "Move group Reviews down", "Remove group Reviews", "Add group", "Group tabs"]
        func node(_ t: [AXTreeNode], _ n: String) -> AXTreeNode? { t.first { $0.reads(n) } }
        let tree = axTree { t in names.allSatisfy { node(t, $0) != nil } }
        for n in names { XCTAssertTrue(node(tree, n) != nil, n) }
        XCTAssertEqual(node(tree, "Move group Sidekicks up")?.enabled, false, "the first row does not move up")
        XCTAssertEqual(node(tree, "Move group Reviews down")?.enabled, false, "the last row does not move down")
        XCTAssertEqual(node(tree, "Remove group Sidekicks")?.enabled, true, "Sidekicks is removable")
        XCTAssertEqual(node(tree, "Add group")?.enabled, true)

        Preferences.agentIslandSessionGroups = (1...8).map { Self.g("g\($0)", "G\($0)", "-g\($0)$") }
        let full = axTree { t in node(t, "Remove group G8") != nil && node(t, "Add group") != nil }
        XCTAssertTrue(node(full, "Remove group G8") != nil, "eight rows drawn")
        XCTAssertEqual(node(full, "Add group")?.enabled, false, "Add is off at eight")
    }

    @MainActor
    func testThePhonesAdoptReloadsTheEditor() {
        Preferences.agentIslandSidekickTabs = true
        Preferences.agentIslandSessionGroups = [Self.g(SessionGroup.sidekicksID, "Sidekicks", "-qa"), Self.g("r1", "Reviews", "-rev$")]
        var posted = false
        func value(_ t: [AXTreeNode]) -> String? { t.first { $0.role == "AXTextField" && $0.label == "Pattern of group Sidekicks" }?.value }
        let tree = axTree { t in
            // Once the editor is drawn with the stored list, the phone's pattern is adopted and announced, as sidekickSync does.
            if !posted, value(t) == "-qa" {
                posted = true
                Preferences.adoptSidekickPattern("-phone$", updated: 99)
                NotificationCenter.default.post(name: .sidekickPatternChangedExternally, object: nil)
            }
            return value(t) == "-phone$"
        }
        XCTAssertTrue(posted)
        XCTAssertEqual(value(tree), "-phone$", "the editor shows the adopted pattern")
        XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, 99, "the reload stamps nothing")
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.pattern), ["-phone$", "-rev$"])
    }
}
