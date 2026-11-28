import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1758 (#1755 phase B): the Settings groups editor. The rules on the editor value (add, rename, reorder, remove, what is
/// not saved and why) round-trip through Preferences on the XCTest scratch suite; the section is rendered offscreen in a
/// never-shown window and read on its accessibility tree. Nothing is clicked, no event is posted; each row puts the keys back.
final class SessionGroupsEditorTests: XCTestCase {
    private static let keys = ["agentIslandSessionGroups", "agentIslandSidekickPattern", "agentIslandSidekickPatternUpdated",
                               "agentIslandSidekickTabs", "agentIslandSessionGroupsUpdated",
                               "agentIslandSessionGroupAutoColors"]

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
            ("reserved name", { g, _ in g.name = " History\t" }, "dch uses this name for its own tab: not saved"),
            ("reserved name Sessions", { g, _ in g.name = "SESSIONS" }, "dch uses this name for its own tab: not saved"),
            ("empty name", { g, _ in g.name = "  " }, "A name is 1-32 bytes, without \"=\": not saved"),
            ("duplicate name", { g, other in g.name = " \(other.uppercased()) " }, "Another group has this name: not saved"),
            // #1777 (QA n96): 513 bytes, more than the phone can echo.
            ("long pattern", { g, _ in g.pattern = String(repeating: "é", count: 256) + "x" }, "Pattern over 512 bytes: not saved"),
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
        XCTAssertTrue(SessionGroupsEditor().reason(Self.g("e", "Edge", String(repeating: "é", count: 256))) == nil, "512 bytes is saved")
        // A new row that is not valid is kept in the editor and not saved; a valid edit beside it is.
        var e = SessionGroupsEditor()
        e.add()
        guard e.rows.count == 3 else { return XCTFail("two stored rows and the new one") }
        e.rows[1].pattern = "-rev2$"
        SessionGroupsEditor.save(e, now: Self.t0)
        XCTAssertEqual(e.rows.count, 3)
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.pattern), ["-qa", "-rev2$", ""], "#2062: the empty new row is manual-only, saved")
        e.rows[2].pattern = "b("
        SessionGroupsEditor.save(e, now: Self.t0)
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.pattern), ["-qa", "-rev2$", ""], "an invalid edit keeps the stored row")
        e.rows[2].pattern = "-new$"
        SessionGroupsEditor.save(e, now: Self.t0)
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.name), ["Sidekicks", "Reviews", "Group 3"])
    }

    /// QA R1758 n90: an invalid row keeps its stored name, so a duplicate is judged against that name and nothing stored is lost.
    @MainActor
    func testAnInvalidRowsStoredNameCountsForTheDuplicateCheck() {
        for aFirst in [true, false] {
            let a = Self.g("a", "Foo", "-a$"), b = Self.g("b", "Bar", "-b$")
            let start = aFirst ? [a, b] : [b, a]
            Preferences.agentIslandSessionGroups = start
            var e = SessionGroupsEditor()
            guard let ia = e.rows.firstIndex(where: { $0.id == "a" }), let ib = e.rows.firstIndex(where: { $0.id == "b" }) else { return XCTFail("rows") }
            e.rows[ia].name = ""
            e.rows[ib].name = " FOO "
            XCTAssertEqual(e.reason(e.rows[ib]), "Another group has this name: not saved", "aFirst \(aFirst)")
            XCTAssertEqual(e.saved(stored: start), start, "aFirst \(aFirst): nothing stored is lost")
            // Equal names by nameKey among valid rows still flag both.
            e.rows[ia].name = "x"
            e.rows[ib].name = " X "
            XCTAssertTrue(e.reason(e.rows[ia]) != nil && e.reason(e.rows[ib]) != nil, "aFirst \(aFirst)")
            XCTAssertEqual(e.saved(stored: start), start, "aFirst \(aFirst)")
        }
        // A third row's edit onto a stored name that a duplicate pair falls back to is flagged too (the repeat).
        let s3 = [Self.g("a", "Foo", "-a$"), Self.g("b", "Bar", "-b$"), Self.g("c", "Baz", "-c$")]
        var e = SessionGroupsEditor(s3)
        e.rows[0].name = "Y"; e.rows[1].name = "y"; e.rows[2].name = "foo"
        XCTAssertEqual(e.saved(stored: s3), s3)
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
                     "Move group Reviews down", "Remove group Reviews", "Add group", "Group tabs", "Hide empty groups",
                     "Colour of group Sidekicks", "Colour of group Reviews"]   // #2107
        func node(_ t: [AXTreeNode], _ n: String) -> AXTreeNode? { t.first { $0.reads(n) } }
        let tree = axTree { t in names.allSatisfy { node(t, $0) != nil } }
        for n in names { XCTAssertTrue(node(tree, n) != nil, n) }
        XCTAssertEqual(node(tree, "Move group Sidekicks up")?.enabled, false, "the first row does not move up")
        XCTAssertEqual(node(tree, "Move group Reviews down")?.enabled, false, "the last row does not move down")
        XCTAssertEqual(node(tree, "Remove group Sidekicks")?.enabled, true, "Sidekicks is removable")
        XCTAssertEqual(node(tree, "Add group")?.enabled, true)
        XCTAssertEqual(node(tree, "Colour of group Sidekicks")?.value, "Blue, Automatic", "#2107: its automatic colour by name")
        XCTAssertEqual(node(tree, "Colour of group Reviews")?.value, "Green, Automatic")

        Preferences.agentIslandSessionGroups = (1...8).map { Self.g("g\($0)", "G\($0)", "-g\($0)$") }
        let full = axTree { t in node(t, "Remove group G8") != nil && node(t, "Add group") != nil }
        XCTAssertTrue(node(full, "Remove group G8") != nil, "eight rows drawn")
        XCTAssertEqual(node(full, "Add group")?.enabled, false, "Add is off at eight")
    }

    // MARK: - #2107: a row's colour

    /// The swatch shows what the sidebar draws (Preferences.sessionGroupColors): a pick, and an automatic group's colour,
    /// the stored one when there is one, else the first free palette colour.
    func testSwatchColourIsTheSidebarsForAPickAndAnAutomaticGroup() {
        var a = Self.g("a", "Alpha", "-a$"); a.color = SessionGroup.palette[3].hex
        Preferences.agentIslandSessionGroups = [a, Self.g("b", "Beta", "-b$")]
        let e = SessionGroupsEditor()
        XCTAssertEqual(e.shownColors(), ["a": SessionGroup.palette[3].hex, "b": SessionGroup.palette[0].hex])
        XCTAssertEqual(e.shownColors(), Preferences.sessionGroupColors(), "the sidebar's colours")
        Preferences.defaults.set(["b": SessionGroup.palette[5].hex], forKey: "agentIslandSessionGroupAutoColors")
        XCTAssertEqual(e.shownColors()["b"], SessionGroup.palette[5].hex, "a kept automatic colour")
        XCTAssertEqual(e.shownColors(), Preferences.sessionGroupColors())
        XCTAssertEqual(SessionGroupsEditor.colourValue(SessionGroup.palette[3].hex, automatic: false), "Purple")
        XCTAssertEqual(SessionGroupsEditor.colourValue(SessionGroup.palette[5].hex, automatic: true), "Teal, Automatic")
    }

    /// Each item the swatch offers is the group menu's Colour ▸ item (same titles, checks and verbs); a pick stores its
    /// hex on that group only, as the group menu's runGroup stores it; Automatic stores nil.
    @MainActor
    func testAPickFromSettingsStoresWhatTheGroupMenuStores() {
        Preferences.agentIslandSessionGroups = [Self.g("a", "Alpha", "-a$"), Self.g("b", "Beta", "-b$")]
        var e = SessionGroupsEditor()
        let items = AgentWindowControls.colourItems(shown: e.shownColors()["a"], automatic: true)
        let verbs = items.compactMap { (x: AgentSidebarMenuEntry) -> AgentSidebarVerb? in
            if case .item(_, _, _, let v) = x { return v }
            return nil
        }
        XCTAssertEqual(verbs, SessionGroup.palette.map { .groupColor($0.hex) } + [.groupColor(nil)])
        for case .groupColor(let hex) in verbs {
            e.pick("a", hex)
            SessionGroupsEditor.save(e, now: Self.t0)
            XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.color), [hex, nil], "the pick \(hex ?? "Automatic")")
        }
        e.pick("b", SessionGroup.palette[6].hex)
        e.rows[1].name = "a=b"   // a name not saved: the row's pick still is, on its stored group
        SessionGroupsEditor.save(e, now: Self.t0)
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(Preferences.agentIslandSessionGroups.last?.color, SessionGroup.palette[6].hex)
    }

    /// A pick stored from the sidebar's Colour ▸ (the list saved, then the window's notice) reaches the editor's row; the
    /// row's unsaved name edit stays.
    func testAdoptColorsTakesTheStoredPicksAndKeepsEdits() {
        Preferences.agentIslandSessionGroups = [Self.g("a", "Alpha", "-a$")]
        var e = SessionGroupsEditor()
        e.rows[0].name = "Edited"
        var stored = Preferences.agentIslandSessionGroups
        stored[0].color = SessionGroup.palette[2].hex
        e.adoptColors(stored)
        XCTAssertEqual(e.rows.first?.color, SessionGroup.palette[2].hex)
        XCTAssertEqual(e.rows.first?.name, "Edited")
        stored[0].color = nil
        e.adoptColors(stored)
        XCTAssertTrue(e.rows.first?.color == nil, "Automatic from the sidebar")
    }

    /// Offscreen: the section is drawn, then the sidebar stores a pick and posts its notice; the row's swatch reads it.
    @MainActor
    func testASidebarPickShowsOnTheSettingsRow() {
        Preferences.agentIslandSidekickTabs = true
        Preferences.agentIslandSessionGroups = [Self.g("r1", "Reviews", "-rev$")]
        var posted = false
        func value(_ t: [AXTreeNode]) -> String? { t.first { $0.reads("Colour of group Reviews") }?.value }   // any name field, as the sibling row
        let tree = axTree { t in
            if !posted, value(t) == "Blue, Automatic" {
                posted = true
                var list = Preferences.agentIslandSessionGroups
                list[0].color = SessionGroup.palette[3].hex
                Preferences.agentIslandSessionGroups = list
                NotificationCenter.default.post(name: .sessionGroupColorPickedInWindow, object: nil)
            }
            return value(t) == "Purple"
        }
        XCTAssertTrue(posted)
        XCTAssertEqual(value(tree), "Purple")
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
