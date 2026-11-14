import AppKit
import XCTest
@testable import ProsperApp

/// #831 phase A2 (spec v3.1 3.5, 4.1a, 8.2, 14.1): the window model holds one in-memory layout and `selection` is
/// a view of its focused pane's target by the raw mapping; the lastLive map is stamped by store publishes; the
/// layout store's Preferences accessors and their bounded backup. Offscreen only: no window shown, no event posted;
/// the Preferences rows use a private in-memory suite (`XCTestDefaults`), never the app's defaults.
extension AgentWindowD1Tests {
    func paneKey(_ name: String) -> AgentSessionKey { AgentSessionKey(dir: "/tmp/dch-test", name: name) }

    /// 3.5 from phase B1 (#831 B1 step 1; was the phase A raw mapping): one pane, focused, and `selection` is the row
    /// of its target resolved against the store now (`.live` and `.history` give their rows, anything else nil),
    /// computed here independently of the model's own last resolve. No store: the raw mapping.
    @MainActor
    func assertSelectionIsTheFocusedPane(_ m: AgentWindowModel, _ why: String, line: UInt = #line) {
        XCTAssertEqual(m.layout.panes.count, 1, "one pane (\(why))", line: line)
        XCTAssertEqual(m.layout.panes.first?.id, m.layout.focused, why, line: line)
        let target = m.layout.panes.first?.target
        guard let st = m.store, let t = target else {
            return XCTAssertEqual(m.selection, AgentWindowModel.rowID(target), why, line: line)
        }
        let c = AgentPaneLayout.resolve(t, sessions: st.sessions, history: st.history,
                                        lastLive: m.lastLive[AgentPaneLayout.PaneSlot(layout: m.layout.id, pane: m.layout.focused)])
        XCTAssertEqual(m.selection, AgentWindowModel.resolvedRow(c), why, line: line)
    }

    @MainActor
    func testAgentWindowPaneSelectionIsTheFocusedPanesResolvedTarget() throws {
        let old = record("old", ago: 7200)
        let st = store([session("api", .idle), session("web", .idle)], history: [old])
        let shared = Preferences.defaults.data(forKey: "agentWindowLayouts")
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        let layoutID = m.layout.id
        assertSelectionIsTheFocusedPane(m, "the first-row pick")
        XCTAssertTrue(m.selection != nil)
        m.select(.live(paneKey("web")))
        assertSelectionIsTheFocusedPane(m, "a click")
        XCTAssertEqual(m.layout.panes.first?.target, .session(dir: "/tmp/dch-test", name: "web"))
        m.select(.history(old.id))
        assertSelectionIsTheFocusedPane(m, "a History click")
        let seen = try XCTUnwrap(m.row(.history(old.id))?.record?.lastSeen)
        XCTAssertEqual(m.layout.panes.first?.target, .history(dir: "/tmp/dch-test", id: old.id.name, seen: seen),
                       "a History pick carries the record's lastSeen (3.1)")
        m.select(nil)
        assertSelectionIsTheFocusedPane(m, "nothing")
        XCTAssertTrue(m.layout.panes.first?.target == nil, "an empty pane")
        m.select(.live(paneKey("api")))
        st.sessions = [session("web", .idle)]
        assertSelectionIsTheFocusedPane(m, "the selected session ended")
        XCTAssertTrue(m.selection == nil, "nothing live to highlight")
        XCTAssertEqual(m.layout.panes.first?.target, .session(dir: "/tmp/dch-test", name: "api"),
                       "B1 (4.4): the pane keeps its target, Ended; resolve never retargets")
        XCTAssertTrue(m.focusedEnded)
        m.select(.live(paneKey("web")))
        m.bind(nil)
        assertSelectionIsTheFocusedPane(m, "the island off")
        XCTAssertTrue(m.selection == nil)
        XCTAssertEqual(m.layout.id, layoutID, "one layout for the window's life")
        XCTAssertFalse(AgentPaneLayout.splitsEnabled, "15.0: the gate stays off")
        // #1217: AgentsWindow.show() loads and saves the shared key now (its rows remove it in setUp); a model built
        // with no suite, as here, neither reads nor writes it, whatever an earlier row left there.
        XCTAssertEqual(Preferences.defaults.data(forKey: "agentWindowLayouts"), shared, "no suite: the shared key as it was")
        XCTAssertEqual(m.layoutWrites, 0, "no suite: nothing saved")
    }

    /// G2 (follow-to-History) and G8 (a removal hands on) pick through the same pane. #831 B1 step 1 (rewritten:
    /// spec 3.5 retires the raw mapping in B1, so this A2 row was not on rewrites-B1.txt): the ended session's pane
    /// keeps its `.session` target and resolves to the name's own record (4.5), never through the empty pane;
    /// removing that record from its card hands on (G8, 4.5).
    @MainActor
    func testAgentWindowPaneFollowAndRemovalGoThroughTheFocusedPane() throws {
        let st = store([session("a", .idle), session("b", .idle)],
                       history: [record("a", ago: 7200), record("h1", ago: 100), record("h2", ago: 200)])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        let calls = Calls()
        calls.wire(m)
        m.setVisible(true)
        defer { m.close() }
        let a = try XCTUnwrap(st.sessions.first { $0.name == "a" }), b = try XCTUnwrap(st.sessions.first { $0.name == "b" })
        m.select(.live(a.key))
        st.sessions = [a, b]   // a poll while a shows: its last live sight (4.1a)
        let pane = try XCTUnwrap(m.layout.panes.first?.id)
        m.ask(.stop, a)
        m.confirm(true)
        st.sessions = [b]
        XCTAssertEqual(m.layout.panes.first?.target, .session(dir: "/tmp/dch-test", name: "a"), "Ended: the pane keeps it")
        assertSelectionIsTheFocusedPane(m, "Ended")
        XCTAssertTrue(m.focusedEnded)
        st.history = [record("a", ago: 0), record("h1", ago: 100), record("h2", ago: 200)]
        XCTAssertEqual(m.selection, .history(a.key), "4.5: its own record")
        assertSelectionIsTheFocusedPane(m, "the swap")
        XCTAssertEqual(m.layout.panes.first?.id, pane, "the same pane")
        XCTAssertEqual(m.layout.panes.first?.target, .session(dir: "/tmp/dch-test", name: "a"), "resolve never retargets")

        // G8 from that pane's History card (act() picks the record's row first: the pane swaps to it in place, #580):
        // the next History row, never the empty pane.
        m.act(.remove, record("a", ago: 0))
        XCTAssertEqual(m.layout.panes.first?.id, pane, "in place (#580)")
        m.confirm(true)
        st.history = [record("h1", ago: 100), record("h2", ago: 200)]
        XCTAssertEqual(m.selection, .history(paneKey("h1")), "G8: the next History row")
        assertSelectionIsTheFocusedPane(m, "G8 from the swapped pane")
        XCTAssertEqual(m.layout.panes.first?.id, pane)

        let h1 = record("h1", ago: 100)
        m.select(.history(h1.id))
        m.act(.remove, h1)
        m.confirm(true)
        st.history = [record("h2", ago: 200)]
        XCTAssertEqual(m.selection, .history(paneKey("h2")), "G8: the next History row")
        assertSelectionIsTheFocusedPane(m, "G8")
        XCTAssertEqual(m.layout.panes.first?.id, pane)
    }

    /// 4.1a (entry 898 item a): a store publish stamps the shown pane whose session it lists live, at the publish's
    /// time (`now()` as it publishes); the age tick (`refresh()`) never stamps; a hidden window never stamps; a
    /// retarget clears the pane's sight (QA 794 rider 3).
    @MainActor
    func testAgentWindowLastLiveIsStampedByAPublishWhileShownAndClearedOnRetarget() throws {
        let live = [session("api", .idle), session("web", .idle)]
        let st = store(live)
        let m = windowModel(st)
        var t = Self.now
        m.now = { t }
        defer { m.close() }
        st.sessions = live
        XCTAssertTrue(m.lastLive.isEmpty, "hidden: a publish stamps nothing")
        m.setVisible(true)
        XCTAssertTrue(m.lastLive.isEmpty, "showing reads the store but is not a publish")
        let first = try XCTUnwrap(m.selection)
        let slot = AgentPaneLayout.PaneSlot(layout: m.layout.id, pane: m.layout.focused)
        t = Self.now + 10
        st.sessions = live
        XCTAssertEqual(m.lastLive, [slot: LastLive(at: Self.now + 10, claudeSessionID: "")], "the publish's time")
        t = Self.now + 500
        m.refresh()   // the age tick
        XCTAssertEqual(m.lastLive[slot]?.at, Self.now + 10, "the age tick never stamps")
        t = Self.now + 600
        st.history = []   // any publish
        XCTAssertEqual(m.lastLive[slot]?.at, Self.now + 600)
        m.setVisible(false)
        t = Self.now + 700
        st.sessions = live
        XCTAssertEqual(m.lastLive[slot]?.at, Self.now + 600, "hidden: kept, not stamped")
        m.setVisible(true)
        let other = try XCTUnwrap([AgentSidebar.RowID.live(paneKey("api")), .live(paneKey("web"))].first { $0 != first })
        m.select(other)
        XCTAssertEqual(m.layout.focused, slot.pane, "the same pane, retargeted")
        XCTAssertTrue(m.lastLive.isEmpty, "a new target has no last sight")
        t = Self.now + 800
        st.sessions = live
        XCTAssertEqual(m.lastLive, [slot: LastLive(at: Self.now + 800, claudeSessionID: "")])
        m.select(nil)
        XCTAssertTrue(m.lastLive.isEmpty, "emptied: cleared")
        st.sessions = live
        XCTAssertTrue(m.lastLive.isEmpty, "an empty pane is never stamped")
    }

    // MARK: 8.2 storage (Preferences)

    /// A private suite per row, never the app's defaults: an `XCTestDefaults` keeps its values in the object (no
    /// CFPreferences write, no file), so the suite and its values go when the row drops it.
    func paneDefaults() -> UserDefaults {
        XCTestDefaults(suiteName: "prosper-pane-layouts-\(UUID().uuidString)")!
    }

    func twoLayouts() throws -> PaneLayoutStore {
        let s = PaneLayoutStore.makeDefault()
        return try s.adding(.single(.session(dir: "/Users/example/dch-sockets", name: "api"))).get()
    }

    func testAgentWindowLayoutsRoundTripThroughTheirKey() throws {
        let d = paneDefaults()
        XCTAssertEqual(Preferences.agentWindowLayouts(in: d).layouts.count, 1, "unset: the default store")
        let two = try twoLayouts()
        Preferences.setAgentWindowLayouts(two, in: d)
        XCTAssertEqual(Preferences.agentWindowLayouts(in: d), two)
        Preferences.setAgentWindowLayouts(.makeDefault(), in: d)
        XCTAssertTrue(d.object(forKey: "agentWindowLayoutsBackup") == nil, "a good blob is never copied")
        XCTAssertTrue(d.object(forKey: "agentWindowLayoutsCorrupt") == nil)
    }

    /// 8.2 (Q5): a corrupt blob reads as the default store; its bytes go to the corrupt copy before the first write.
    func testACorruptBlobReadsAsTheDefaultAndIsKeptBeforeTheWrite() throws {
        let d = paneDefaults()
        let bad = Data(#"{"v": 1, "layouts": [{"id": "nope"}]}"#.utf8)
        d.set(bad, forKey: "agentWindowLayouts")
        XCTAssertEqual(Preferences.agentWindowLayouts(in: d).layouts.count, 1)
        XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), bad, "a read writes nothing")
        let two = try twoLayouts()
        Preferences.setAgentWindowLayouts(two, in: d)
        XCTAssertEqual(d.data(forKey: "agentWindowLayoutsCorrupt"), bad)
        XCTAssertTrue(d.object(forKey: "agentWindowLayoutsBackup") == nil)
        XCTAssertEqual(Preferences.agentWindowLayouts(in: d), two, "then the blob is replaced")
    }

    /// 8.2: a newer build's blob is kept in the backup key before this build writes; a corrupt blob never overwrites
    /// that copy, nor the other way round (entry 898 item c), whichever comes first.
    func testANewerVersionsBlobAndACorruptOneKeepSeparateCopies() throws {
        let newer = Data(#"{"v": 2, "layouts": [], "tabs": [1]}"#.utf8)
        let bad = Data("not json".utf8)
        for order in [[newer, bad], [bad, newer]] {
            let d = paneDefaults()
            for blob in order {
                d.set(blob, forKey: "agentWindowLayouts")
                Preferences.setAgentWindowLayouts(.makeDefault(), in: d)
            }
            XCTAssertEqual(d.data(forKey: "agentWindowLayoutsBackup"), newer, "the newer copy, \(order.first == newer)")
            XCTAssertEqual(d.data(forKey: "agentWindowLayoutsCorrupt"), bad)
            XCTAssertEqual(Preferences.agentWindowLayouts(in: d).layouts.count, 1)
        }
    }

    /// The copy is bounded: an oversized blob keeps its first `maxBlobBytes` bytes only.
    func testAnOversizedBlobsCopyIsBoundedToItsPrefix() throws {
        let d = paneDefaults()
        let cap = PaneLayoutStore.maxBlobBytes
        var big = Data(#"{"v": 1, "pad": ""#.utf8)
        big.append(Data(repeating: UInt8(ascii: "x"), count: cap))
        big.append(Data(#""}"#.utf8))
        XCTAssertGreaterThan(big.count, cap)
        d.set(big, forKey: "agentWindowLayouts")
        Preferences.setAgentWindowLayouts(.makeDefault(), in: d)
        let kept = try XCTUnwrap(d.data(forKey: "agentWindowLayoutsCorrupt"))
        XCTAssertEqual(kept.count, cap)
        XCTAssertEqual(kept, big.prefix(cap))
        XCTAssertTrue(d.object(forKey: "agentWindowLayoutsBackup") == nil)
        XCTAssertLessThan(try XCTUnwrap(d.data(forKey: "agentWindowLayouts")).count, 1024, "replaced by the new store")
    }
}
