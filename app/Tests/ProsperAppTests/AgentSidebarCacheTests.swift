import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1785 (#1778 R4): the sidebar's drawn items and its numbers are built once per change of their
/// inputs, never per session switch or draw; and every input clears them (a stale sidebar is worse than a slow one).
/// Counted by builds, never timed. Offscreen: the sidebar is hosted in a never-shown window, the terminal is a fake.
extension AgentWindowD1Tests {

    /// The drawn items and numbers rebuilt from scratch: what the caches must always equal.
    @MainActor
    func freshDrawn(_ m: AgentWindowModel, _ st: AgentIslandStore) -> [String: [AgentSidebar.Item]] {
        AgentSidebar.items(m.sections)
    }

    @MainActor
    func assertCacheFresh(_ m: AgentWindowModel, _ st: AgentIslandStore, _ why: String, line: UInt = #line) {
        XCTAssertEqual(m.drawnItems, freshDrawn(m, st), "drawn items: \(why)", line: line)
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
    /// and no numbers (before #1785: 5 items, 5 numbers, one each per draw).
    @MainActor
    func testSessionSwitchRebuildsNoSidebarCache() {
        withCachePrefs {
            let names = ["api", "api-qa", "web", "s1", "s2", "s3"]
            let st = store(names.enumerated().map { session($1, .idle, ago: Double($0 + 1) * 10) }, history: [record("old")])
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
            let drawn = m.drawnBuilds, numbered = m.numberedBuilds
            for n in ["web", "s1", "s2", "s3", "api-qa"] {
                m.click(live(n))
                spin()
                XCTAssertEqual(m.selection, live(n))
            }
            XCTAssertEqual(m.drawnBuilds - drawn, 0, "5 switches build no drawn items")
            XCTAssertEqual(m.numberedBuilds - numbered, 0, "5 switches build no numbers")
            assertCacheFresh(m, st, "after the switches")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// Every input of the drawn items invalidates them: the sections (sessions, history), the #1757 session groups, the
    /// store itself (bind). One build per change, and each time the cache equals a fresh build.
    @MainActor
    func testEveryDrawnItemsInputInvalidates() {
        withCachePrefs {
            let st = store([session("api", .idle, ago: 10), session("api-qa", .idle, ago: 20), session("web", .idle, ago: 30)])
            let m = windowModel(st)
            _ = fakeTerminal(m)
            m.setVisible(true)
            defer { m.close() }
            XCTAssertTrue(m.drawnItems.values.joined().allSatisfy { $0.rows.count == 1 }, "#1820: one row per item")
            XCTAssertEqual(m.numberedIDs.count, 3)
            var builds = m.drawnBuilds
            @MainActor func rebuilt(_ why: String, line: UInt = #line) {
                _ = m.drawnItems
                XCTAssertEqual(m.drawnBuilds, builds + 1, "one build: \(why)", line: line)
                builds = m.drawnBuilds
                assertCacheFresh(m, st, why, line: line)
            }
            // sessions: a new live session is its own row and number.
            st.sessions += [session("api-qa2", .idle, ago: 40)]
            rebuilt("sessions")
            XCTAssertEqual(m.numberedIDs.count, 4, "#1820: every session its own number")
            // history: a History row.
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

    /// The store itself: another store with the same sessions (equal sections, no sections publish) still rebuilds once.
    @MainActor
    func testStoreSwapInvalidatesDrawnItems() {
        withCachePrefs {
            let list = [session("api", .idle, ago: 10), session("api-qa", .idle, ago: 20)]
            let a = store(list), b = store(list)
            let m = windowModel(a)
            _ = fakeTerminal(m)
            m.setVisible(true)
            defer { m.close() }
            _ = m.drawnItems
            let sections = m.sections, builds = m.drawnBuilds
            m.bind(b)
            XCTAssertEqual(m.sections, sections, "the sections did not change")
            _ = m.drawnItems
            XCTAssertEqual(m.drawnBuilds, builds + 1, "the store's identity alone clears the memo")
            XCTAssertEqual(m.numberedIDs, [live("api"), live("api-qa")])
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
}
