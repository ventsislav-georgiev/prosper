import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1785 (#1778 R4): the sidebar's drawn items, its numbers and the store's groups are built once per change of their
/// inputs, never per session switch or draw; and every input clears them (a stale sidebar is worse than a slow one).
/// Counted by builds, never timed. Offscreen: the sidebar is hosted in a never-shown window, the terminal is a fake.
extension AgentWindowD1Tests {

    /// The drawn items and numbers rebuilt from scratch: what the caches must always equal.
    @MainActor
    func freshDrawn(_ m: AgentWindowModel, _ st: AgentIslandStore) -> [String: [AgentSidebar.Item]] {
        AgentSidebar.items(m.sections) {
            AgentIsland.groups(st.sessions.map(\.key) + st.history.map(\.key), suffix: st.pairSuffix)
        }
    }

    @MainActor
    func assertCacheFresh(_ m: AgentWindowModel, _ st: AgentIslandStore, _ why: String, line: UInt = #line) {
        XCTAssertEqual(m.drawnItems, freshDrawn(m, st), "drawn items: \(why)", line: line)
        XCTAssertEqual(st.groups, AgentIsland.groups(st.sessions.map(\.key) + st.history.map(\.key), suffix: st.pairSuffix),
                       "store groups: \(why)", line: line)
    }

    /// Runs `body` with the folds and the sidebar mode cleared, both put back after.
    @MainActor
    func withCachePrefs(_ body: () throws -> Void) rethrows {
        let saved = Preferences.defaults.object(forKey: "agentSidebarMode")
        defer { Preferences.defaults.set(saved, forKey: "agentSidebarMode") }
        Preferences.defaults.removeObject(forKey: "agentSidebarMode")
        try withDigitPrefs(body)
    }

    /// The counting row: 5 session switches through the row's click path with the real sidebar drawn build no items,
    /// no numbers and no store groups (before #1785: 5 items, 5 numbers, 10 groups, one each per draw).
    @MainActor
    func testSessionSwitchRebuildsNoSidebarCache() {
        withCachePrefs {
            let names = ["api", "api-qa", "web", "s1", "s2", "s3"]
            let st = store(names.enumerated().map { session($1, .idle, ago: Double($0 + 1) * 10) }, history: [record("old")])
            st.pairSuffix = "-qa"
            let m = windowModel(st)
            _ = fakeTerminal(m)
            m.setVisible(true)
            let (win, host) = AXTreeSupport.hosted(AgentSidebarView(model: m), CGSize(width: 320, height: 600))
            defer { win.contentView = nil; win.close(); m.close() }
            @MainActor func spin() {
                for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            }
            m.click(live("api"))
            spin()
            XCTAssertTrue(m.drawnItems.values.joined().contains { $0.stem == "api" }, "api and api-qa are one group row")
            let drawn = m.drawnBuilds, numbered = m.numberedBuilds, groups = st.groupsBuilds
            for n in ["web", "s1", "s2", "s3", "api-qa"] {
                m.click(live(n))
                spin()
                XCTAssertEqual(m.selection, live(n))
            }
            XCTAssertEqual(m.drawnBuilds - drawn, 0, "5 switches build no drawn items")
            XCTAssertEqual(m.numberedBuilds - numbered, 0, "5 switches build no numbers")
            XCTAssertEqual(st.groupsBuilds - groups, 0, "5 switches build no store groups")
            assertCacheFresh(m, st, "after the switches")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// Every input of the drawn items invalidates them: the sections (a session added), the store's groups through each
    /// of their inputs (pairSuffix alone: the sections stay equal; history; sessions), the #1757 session groups, the store
    /// itself (bind). One build per change, and each time the cache equals a fresh build.
    @MainActor
    func testEveryDrawnItemsInputInvalidates() {
        withCachePrefs {
            let st = store([session("api", .idle, ago: 10), session("api-qa", .idle, ago: 20), session("web", .idle, ago: 30)])
            let m = windowModel(st)
            _ = fakeTerminal(m)
            m.setVisible(true)
            defer { m.close() }
            XCTAssertFalse(m.drawnItems.values.joined().contains { $0.stem != nil }, "no suffix: no group row")
            XCTAssertEqual(m.numberedIDs.count, 3)
            var builds = m.drawnBuilds
            @MainActor func rebuilt(_ why: String, line: UInt = #line) {
                _ = m.drawnItems
                XCTAssertEqual(m.drawnBuilds, builds + 1, "one build: \(why)", line: line)
                builds = m.drawnBuilds
                assertCacheFresh(m, st, why, line: line)
            }
            // pairSuffix: not a sections input, so only the store's generation can tell.
            let sections = m.sections
            st.pairSuffix = "-qa"
            XCTAssertEqual(m.sections, sections, "the sections did not change")
            rebuilt("pairSuffix")
            XCTAssertTrue(m.drawnItems.values.joined().contains { $0.stem == "api" }, "api and api-qa one row")
            XCTAssertEqual(m.numberedIDs.count, 2, "#1111: a group is one number")
            // sessions: a new live member joins the group.
            st.sessions += [session("api-qa2", .idle, ago: 40)]
            rebuilt("sessions")
            XCTAssertEqual(m.drawnItems.values.joined().first { $0.stem == "api" }?.rows.count, 3)
            // history: a record named like a member changes the groups (a History row too).
            st.history = [record("web-qa")]
            rebuilt("history")
            // #1757 session groups: web moves into its own section.
            st.sessionGroups = [SessionGroup(id: "g1", name: "Web", pattern: "^web$")]
            rebuilt("session groups")
            XCTAssertNotNil(m.drawnItems[AgentSidebar.groupFold("g1")], "the group section is drawn")
            // Nothing changed: no build.
            _ = m.drawnItems; _ = m.numberedIDs
            XCTAssertEqual(m.drawnBuilds, builds, "a read with no change builds nothing")
            // The store gone: nothing drawn, nothing numbered.
            m.bind(nil)
            XCTAssertEqual(m.drawnItems, [:])
            XCTAssertEqual(m.numberedIDs, [])
        }
    }

    /// The store itself: another store at the same groups generation, with the same sessions (equal sections, no sections
    /// publish) but another pair suffix, draws its own groups.
    @MainActor
    func testStoreSwapInvalidatesDrawnItems() {
        withCachePrefs {
            let list = [session("api", .idle, ago: 10), session("api-qa", .idle, ago: 20)]
            let a = store(list), b = store(list)
            a.pairSuffix = "-none" // a real change that pairs nothing: a no-op set does not bump (#1797)
            b.pairSuffix = "-qa"
            XCTAssertEqual(a.groupsGeneration, b.groupsGeneration, "the same generation: only the store's identity tells")
            let m = windowModel(a)
            _ = fakeTerminal(m)
            m.setVisible(true)
            defer { m.close() }
            XCTAssertFalse(m.drawnItems.values.joined().contains { $0.stem != nil })
            let sections = m.sections
            m.bind(b)
            XCTAssertEqual(m.sections, sections, "the sections did not change")
            XCTAssertTrue(m.drawnItems.values.joined().contains { $0.stem == "api" }, "b's groups")
            XCTAssertEqual(m.numberedIDs, [live("api")])
        }
    }

    /// The numbers' own inputs: a fold, the sidebar mode (Mini folds nothing) and the drawn items; reading twice builds once.
    @MainActor
    func testEveryNumbersInputInvalidates() {
        withCachePrefs {
            let st = store([session("api", .idle, ago: 10), session("web", .idle, ago: 20), session("x-qa", .idle, ago: 30)],
                           pattern: "-qa")
            let m = windowModel(st)
            _ = fakeTerminal(m)
            m.setVisible(true)
            defer { m.close() }
            XCTAssertEqual(m.numberedIDs, ["api", "web", "x-qa"].map(live))
            let n = m.numberedBuilds
            XCTAssertEqual(m.number(live("x-qa")), 3)
            XCTAssertEqual(m.numbers[live("web")], 2)
            XCTAssertEqual(m.numberedBuilds, n, "reads build nothing")
            m.setCollapsed("Sessions", true)
            XCTAssertEqual(m.numberedIDs, [live("x-qa")], "a fold")
            XCTAssertEqual(m.number(live("x-qa")), 1)
            XCTAssertTrue(m.number(live("api")) == nil)
            m.setSidebarMode(.mini)
            XCTAssertEqual(m.numberedIDs, ["api", "web", "x-qa"].map(live), "Mini folds nothing")
            m.setSidebarMode(.full)
            XCTAssertEqual(m.numberedIDs, [live("x-qa")], "back to the fold")
            m.setCollapsed("Sessions", false)
            XCTAssertEqual(m.numberedIDs, ["api", "web", "x-qa"].map(live), "unfolded: the memo now matches fold and mode")
            st.sessions = [session("web", .idle, ago: 5)] + st.sessions.filter { $0.name != "web" }
            XCTAssertEqual(m.numberedIDs, ["web", "api", "x-qa"].map(live), "the drawn items' change")
            XCTAssertEqual(m.number(live("web")), 1)
        }
    }

    /// The store's groups: built once per generation; sessions, history and pairSuffix each bump it.
    @MainActor
    func testStoreGroupsCacheFollowsEveryInput() {
        let st = store([session("api", .idle)])
        _ = st.groups
        let b = st.groupsBuilds
        _ = st.groups
        XCTAssertEqual(st.groupsBuilds, b, "a second read builds nothing")
        XCTAssertEqual(st.groups, [])
        st.pairSuffix = "-qa"
        st.history = [record("api-qa")]
        XCTAssertEqual(st.groups.map(\.stem), ["api"], "history: api-qa's record")
        st.history = []
        XCTAssertEqual(st.groups, [], "history")
        st.sessions += [session("api-qa", .idle)]
        XCTAssertEqual(st.groups.map(\.stem), ["api"], "sessions")
        st.pairSuffix = ""
        XCTAssertEqual(st.groups, [], "pairSuffix")
        XCTAssertEqual(st.groupsBuilds, b + 4, "one build per read after a change")
    }

    /// #1797: a poll that sets the same keys (other states) builds nothing; a changed key builds once.
    @MainActor
    func testStoreGroupsPollWithSameKeysBuildsNothing() {
        let st = store([session("api", .idle)])
        _ = st.groups
        let b = st.groupsBuilds
        for _ in 0..<10 { st.sessions = [session("api", .working)]; st.history = []; st.pairSuffix = st.pairSuffix; _ = st.groups }
        XCTAssertEqual(st.groupsBuilds, b, "10 polls with the same keys: no build")
        st.sessions = [session("web", .idle)]
        _ = st.groups; _ = st.groups
        XCTAssertEqual(st.groupsBuilds, b + 1, "a changed key builds once")
    }
}
