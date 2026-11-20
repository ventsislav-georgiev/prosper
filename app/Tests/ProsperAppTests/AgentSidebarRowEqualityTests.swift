import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1786 (#1778 R5): the sidebar's rows are Equatable and drawn with `.equatable()`, so a session switch evaluates only
/// the two rows whose selection changed; every value a row draws still redraws it (a stale row is worse than a slow one).
/// Counted by row bodies (AgentSidebarRowView.bodyProbe), never timed. Offscreen: a never-shown window, a fake terminal.
extension AgentWindowD1Tests {

    /// Runs `body` with the row-body probe recording each evaluated row's title; the probe is cleared after.
    @MainActor
    func withRowBodies(_ body: (_ take: () -> [String]) throws -> Void) rethrows {
        var seen: [String] = []
        AgentSidebarRowView.bodyProbe = { seen.append($0) }
        defer { AgentSidebarRowView.bodyProbe = nil }
        try body { defer { seen = [] }; return seen }
    }

    /// The real sidebar hosted offscreen over `names` (idle, no group), the model visible; closed by the caller's defer.
    @MainActor
    func rowRig(_ names: [String]) -> (AgentIslandStore, AgentWindowModel, NSWindow, () -> Void) {
        let st = store(names.enumerated().map { session($1, .idle, ago: Double($0 + 1) * 10) })
        let m = windowModel(st)
        _ = fakeTerminal(m)
        m.setVisible(true)
        let (win, host) = AXTreeSupport.hosted(AgentSidebarView(model: m), CGSize(width: 320, height: 600))
        let spin: () -> Void = {
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        return (st, m, win, spin)
    }

    /// The counting row: each switch evaluates exactly the old and the new selected rows' bodies (at base: every realized
    /// row, 6 per switch in lag1778a's probe: the row's openPR closure made every row unequal).
    @MainActor
    func testSessionSwitchRedrawsOnlyTheTwoRowsWhoseSelectionChanged() {
        withCachePrefs {
            let names = ["s1", "s2", "s3", "s4", "s5", "s6"]
            let (_, m, win, spin) = rowRig(names)
            defer { win.contentView = nil; win.close(); m.close() }
            withRowBodies { take in
                m.click(live("s1"))
                spin()
                _ = take()   // the first draw (and whatever selection the model started with)
                var prev = "s1"
                for n in ["s4", "s2", "s6", "s1"] {
                    m.click(live(n))
                    spin()
                    XCTAssertEqual(m.selection, live(n))
                    let bodies = take()
                    XCTAssertEqual(Set(bodies), [prev, n], "only the old and the new selection redraw: \(prev) -> \(n)")
                    XCTAssertEqual(bodies.count, 2, "one body each: \(prev) -> \(n), drew \(bodies)")
                    prev = n
                }
            }
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// Every drawn change still redraws its row through the equality: a state change (title line, detail, age), a new
    /// number (a session added above shifts them), Row details (every row), the UI size (the row's own liveTheme, which
    /// `==` does not see), and an unchanged publish redraws none.
    @MainActor
    func testEveryDrawnChangeStillRedrawsItsRow() {
        withRethemeStore {
            withCachePrefs {
                let (st, m, win, spin) = rowRig(["s1", "s2", "s3"])
                defer { win.contentView = nil; win.close(); m.close() }
                withRowBodies { take in
                    m.click(live("s1"))
                    spin()
                    _ = take()
                    st.sessions = st.sessions   // an equal publish: no row changed
                    spin()
                    XCTAssertEqual(take(), [], "an equal publish redraws no row")

                    st.sessions = st.sessions.map { $0.key.name == "s2" ? session("s2", .blocked, ago: 20) : $0 }
                    spin()
                    XCTAssertTrue(take().contains("s2"), "s2's state change redraws s2")

                    st.sessions = [session("s0", .idle, ago: 1)] + st.sessions   // numbers shift by one
                    spin()
                    // s2 (Needs you, number 1) keeps its number; s1 and s3 move down one.
                    XCTAssertTrue(Set(["s1", "s3"]).isSubset(of: Set(take())), "a shifted number redraws its row")

                    var d = st.details
                    d.state.toggle()
                    st.details = d
                    spin()
                    XCTAssertTrue(Set(["s0", "s1", "s2", "s3"]).isSubset(of: Set(take())), "Row details redraw every row")

                    ThemeStore.shared.setScale(0.85)
                    spin()
                    XCTAssertTrue(Set(["s0", "s1", "s2", "s3"]).isSubset(of: Set(take())), "the UI size redraws every row")
                }
            }
        }
    }

    /// The equality itself: equal inputs compare equal (so a row can be skipped), and a change to each input the row
    /// draws compares unequal. AgentSidebar.Row's == is synthesized over all its stored fields; a few are pinned here.
    @MainActor
    func testEveryRowInputBreaksEquality() {
        let row = AgentSidebar.row(session("api", .idle, ago: 30), details: .all, now: Self.now)
        let m = windowModel(store([]))
        defer { m.close() }
        let tip = AgentMiniTip()
        let base = AgentSidebarRowView(row: row, selected: false, number: 1, inView: false, model: m, mini: false, show: .all,
                                       tip: tip)
        XCTAssertTrue(base == AgentSidebarRowView(row: row, selected: false, number: 1, inView: false, model: m, mini: false,
                                                  show: .all, tip: tip), "equal inputs: equal (the row can be skipped)")
        func with(_ f: (inout AgentSidebarRowView) -> Void) -> AgentSidebarRowView { var v = base; f(&v); return v }
        func rowWith(_ f: (inout AgentSidebar.Row) -> Void) -> AgentSidebarRowView { var r = row; f(&r); return base.withRow(r) }
        let other = windowModel(nil)
        defer { other.close() }
        var noState = AgentIslandRowDetails.all
        noState.state = false
        var noShortcut = AgentIslandRowDetails.all
        noShortcut.shortcut = false
        let inks = AgentSidebarRowView.Inks(primary: .red, quiet: .gray, blue: .blue, blocked: .orange, mark: .green,
                                            badges: ThemeRuntime.palette)
        let changed: [(String, AgentSidebarRowView)] = [
            ("title", base.withRow(AgentSidebar.row(session("web", .idle, ago: 30), details: .all, now: Self.now))),
            ("state", base.withRow(AgentSidebar.row(session("api", .blocked, ago: 30), details: .all, now: Self.now))),
            ("age", rowWith { $0.age = "9h" }),
            ("open PR count", rowWith { $0.prCount = 3 }),
            ("PR links", rowWith { $0.prLinks = [AgentIsland.PRChip(label: "repo#1", title: "t", url: nil)] }),
            ("agents", rowWith { $0.agents = 2 }),
            ("merged", rowWith { $0.merged = 4 }),
            ("host", rowWith { $0.host = "box" }),
            ("remote", rowWith { $0.remote = AgentSidebar.Remote(host: "box", name: "api", alias: "", stale: false, cwd: nil) }),
            ("model slot", rowWith { $0.modelSlot.toggle() }),
            ("model", rowWith { $0.model = "Opus 4.7" }),
            ("effort", rowWith { $0.effort = "high" }),
            ("session", rowWith { $0.session = nil }),
            ("selected", with { $0 = AgentSidebarRowView(row: row, selected: true, number: 1, model: m, tip: tip) }),
            ("number", with { $0.number = 2 }),
            ("no number", with { $0.number = nil }),
            ("in view", with { $0.inView = true }),
            ("mini", with { $0.mini = true }),
            ("inks", with { $0.inks = inks }),
            ("Row details: state", with { $0.show = noState }),
            ("Row details: shortcut", with { $0.show = noShortcut }),
            ("tip", with { $0.tip = AgentMiniTip() }),
            ("no tip", with { $0.tip = nil }),
            ("model (another window)", with { $0.model = other }),
        ]
        for (name, v) in changed { XCTAssertFalse(base == v, "a change to \(name) redraws the row") }
    }

    /// The PR chip's click moved from a closure to the row's model (#1786): the sidebar row's "Open pull request" action
    /// still opens through the window model's openURL seam (a recorder; nothing opens). Read through this process's own
    /// accessibility tree of a never-shown window; no event.
    @MainActor
    func testARowsPRChipOpensThroughItsModel() {
        withCachePrefs {
            let pr = DchSessionMeta.PR(url: "https://github.com/acme/api/pull/12", repo: "acme/api", num: 12, title: "t")
            let st = store([session("api", .idle, ago: 10, meta: DchSessionMeta(openPRs: [pr], merged: 0))])
            let m = windowModel(st)
            _ = fakeTerminal(m)
            m.setVisible(true)
            var opened: [String] = []
            m.openURL = { opened.append($0.absoluteString) }
            let restore = AXTreeSupport.axOn()
            defer { restore() }
            let (win, host) = AXTreeSupport.hosted(AgentSidebarView(model: m), CGSize(width: 320, height: 600))
            defer { win.contentView = nil; win.close(); m.close() }
            var actions: [NSAccessibilityCustomAction] = []
            let end = Date().addingTimeInterval(5)
            while actions.isEmpty && Date() < end {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                actions = rowActions(host).filter { $0.name.hasPrefix("Open pull request") }
            }
            XCTAssertEqual(actions.count, 1, "the row's one PR action: \(actions.map(\.name))")
            for a in actions { XCTAssertTrue(a.handler?() ?? false, a.name) }
            XCTAssertEqual(opened, ["https://github.com/acme/api/pull/12"], "through the model's openURL seam, once")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// Every custom accessibility action under `host`, each name once (a wrapper can repeat its button's).
    func rowActions(_ host: NSView) -> [NSAccessibilityCustomAction] {
        var out: [NSAccessibilityCustomAction] = []
        func walk(_ e: Any, depth: Int) {
            guard depth < 60, let o = e as? NSObject else { return }
            if o.responds(to: Selector(("accessibilityCustomActions"))) {
                out += o.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction] ?? []
            }
            for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { walk(k, depth: depth + 1) }
        }
        walk(host, depth: 0)
        return out.reduce(into: []) { acc, a in if !acc.contains(where: { $0.name == a.name }) { acc.append(a) } }
    }
}

private extension AgentSidebarRowView {
    /// The same inputs over another row.
    func withRow(_ r: AgentSidebar.Row) -> AgentSidebarRowView {
        AgentSidebarRowView(row: r, selected: selected, number: number, inView: inView, model: model, mini: mini, show: show,
                            tip: tip)
    }
}
