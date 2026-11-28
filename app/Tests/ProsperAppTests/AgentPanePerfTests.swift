import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #2077 (phase 1, measure only): the main-thread time of the Agent Sessions window's pane and X-ray drawer operations,
/// from the action to the frame's layout and display. Each op runs 5 warm-up times, then 50 timed times; a run is the
/// action, `layoutSubtreeIfNeeded()`, `displayIfNeeded()` plus a CATransaction flush on the content view, and one zero-length
/// run loop pass with a second layout and display (work the action queued on the main queue). The terminal's GPU draw is
/// not measurable here (never-shown window). Offscreen only: the window is built by AgentsWindow.makeWindow with no
/// autosave and never shown, ordered in or made key; no event is built or posted; the dch reads go through fakes (an open's
/// read parks until it is cancelled, so the drawer's first frame is the placeholder's; data is applied by the op that
/// times it); the terminal spawns a FakeChild. Heavy only (PROSPER_HEAVY_TESTS=1). No budget asserts (CI machines differ):
/// a gross guard of 1 s p95 per op (Self.grossGuard). Prints "PERF <op> p50 .. p95 .. max .." lines and a split per phase.
@MainActor
final class AgentPanePerfTests: XCTestCase {
    private let d1 = AgentWindowD1Tests()
    static let warm = 5, runs = 50
    /// A regression to seconds only: on a loaded Mac p95 reached 126 ms (release) and 495 ms (debug) on today's code (#2077 runs 2, 3).
    static let grossGuard = 1000.0
    static let names = ["api", "api-qa", "web", "web-qa", "docs", "docs-qa", "ops", "ops-qa", "cli", "cli-qa", "db", "db-qa"]

    func key(_ n: String) -> AgentSessionKey { AgentSessionKey(dir: "/tmp/dch-test", name: n) }

    /// 12 sessions: 2 blocked (Needs you), the rest in Sessions and two groups (QA: "-qa$", Docs: "^doc"); some with
    /// subagents, shells and open PRs; 10 history records.
    func store() -> AgentIslandStore {
        let pr = { (n: Int) in DchSessionMeta.PR(url: "https://github.com/acme/repo/pull/\(n)", repo: "acme/repo", num: n, title: "t") }
        let sessions = Self.names.enumerated().map { i, n in
            var s = d1.session(n, i % 6 == 1 ? .blocked : i % 3 == 0 ? .working : .idle, ago: TimeInterval(60 * (i + 1)),
                               agents: i % 4 == 0 ? 3 : 0, meta: i % 3 == 2 ? DchSessionMeta(openPRs: (1...(i % 5 + 1)).map(pr), merged: i) : nil)
            if i % 2 == 0 { s.shells = (1...2).map { DchShell(id: "\($0)", pid: $0, started: 0, command: "make test") } }
            s.cwd = "/Users/example/\(n)"
            return s
        }
        let st = d1.store(sessions, history: (1...10).map { d1.record("old-\($0)") })
        st.sessionGroups = [SessionGroup(id: "qa", name: "QA", pattern: "-qa$"), SessionGroup(id: "docs", name: "Docs", pattern: "^doc")]
        return st
    }

    /// Big answers: 60 tasks, 300 chapters (with responses), 20 memory items.
    static let tasks: (Int32, Data) = (0, XrayPanelTasksTests.ndjson([XrayPanelTasksTests.header] + (1...60).map {
        #"{"task":{"id":"\#($0)","title":"Task number \#($0) with a longer title","status":"\#($0 % 3 == 0 ? "done" : "pending")","label":"pending","note":"a note","created":"2026-11-16T09:00:00Z","updated":"2026-11-16T11:00:00Z","blocked_by":[]}}"#
    } + [#"{"done":true,"count":60,"dropped":0}"#]))
    static let memory: (Int32, Data) = (0, XrayPanelTasksTests.ndjson([XrayPanelTasksTests.memory[0]] + (1...20).map {
        #"{"memory":{"id":"m\#($0)","title":"Memory item \#($0)","kind":"feedback","scope":"user","path":"/Users/example/m\#($0).md","session":null}}"#
    } + [#"{"done":true,"count":20,"dropped":0}"#]))
    static let chapters: (Int32, Data) = (0, Data((#"{"schema":1,"session":"api","session_id":"0b1f6a52-4c1e-4d7a-9a51-2f6d8c3e7a10","live":true,"corpus":"claude","reason":null,"available":true,"chapters":["#
        + (1...300).map { #"{"anchor":"f3a41c:\#($0 * 100)","offset":\#($0 * 100),"i":\#($0),"at":\#(1794304860 + $0),"title":"Prompt number \#($0): please look at the parser and fix the failing row","kind":"prompt","partial":false,"error":false,"response":"Done: fixed the parser row \#($0) and reran the suite","tools":"Bash \#($0 % 7)"}"# }.joined(separator: ",")
        + #"],"chapters_evicted":false,"refs":[],"dropped_keys":0}"#).utf8))

    struct Samples {
        var total: [Double] = [], model: [Double] = [], layout: [Double] = [], display: [Double] = [], tail: [Double] = []
        static func pct(_ v: [Double], _ p: Double) -> Double {
            let s = v.sorted()
            guard !s.isEmpty else { return 0 }
            return s[min(s.count - 1, Int((Double(s.count) * p).rounded(.up)) - 1)]
        }
    }

    static func ms(_ body: () -> Void) -> Double {
        let c = ContinuousClock(), t = c.now
        body()
        let d = c.now - t
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// Lets queued work land outside the timed part (debounced refreshes, the panel's parked reads starting).
    func settle(_ v: NSView) {
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            v.layoutSubtreeIfNeeded()
            v.displayIfNeeded()
        }
    }

    /// `op`'s run i, timed with the view's update; `before`/`after` untimed (setup and undo of the op).
    @discardableResult
    func measure(_ name: String, _ v: NSView, before: (Int) -> Void = { _ in }, after: (Int) -> Void = { _ in },
                 _ op: (Int) -> Void) -> Samples {
        var s = Samples()
        for i in 0..<(Self.warm + Self.runs) {
            before(i)
            settle(v)
            let m = Self.ms { op(i) }
            let l = Self.ms { v.layoutSubtreeIfNeeded() }
            let d = Self.ms { v.displayIfNeeded(); CATransaction.flush() }
            let t = Self.ms {
                RunLoop.current.run(until: Date())
                v.layoutSubtreeIfNeeded()
                v.displayIfNeeded()
                CATransaction.flush()
            }
            after(i)
            guard i >= Self.warm else { continue }
            s.total.append(m + l + d + t); s.model.append(m); s.layout.append(l); s.display.append(d); s.tail.append(t)
        }
        let f = { (x: Double) in String(format: "%.2f", x) }
        let p = Samples.pct
        print("PERF \(name) p50 \(f(p(s.total, 0.5))) p95 \(f(p(s.total, 0.95))) max \(f(s.total.max() ?? 0)) ms | p50 split: "
              + "action \(f(p(s.model, 0.5))) layout \(f(p(s.layout, 0.5))) display \(f(p(s.display, 0.5))) tail \(f(p(s.tail, 0.5)))"
              + " | p95 split: action \(f(p(s.model, 0.95))) layout \(f(p(s.layout, 0.95))) display \(f(p(s.display, 0.95))) tail \(f(p(s.tail, 0.95)))")
        XCTAssertLessThan(p(s.total, 0.95), Self.grossGuard, "\(name): a gross regression (p95 over \(Self.grossGuard) ms)")
        // Hotspot split (untimed): the sidebar rows' body evaluations per run (AgentSidebarRowView.bodyProbe).
        var bodies = 0
        AgentSidebarRowView.bodyProbe = { _ in bodies += 1 }
        defer { AgentSidebarRowView.bodyProbe = nil }
        for i in 0..<10 { before(i); settle(v); op(i); v.layoutSubtreeIfNeeded(); settle(v); after(i) }
        print("PERF-COUNT \(name): sidebar row bodies per run \(Double(bodies) / 10)")
        return s
    }

    /// The window on the 12-session store, 1600x900 at scale 1, the gate on, the X-ray seams faked; all put back after.
    func rig(panes: Int, _ body: (AgentWindowModel, AgentsNSWindow, NSView) throws -> Void) throws {
        try requireHeavyTests()
        let d = Preferences.defaults, keys = ["agentWindowStyle", "xrayBottomTab", "xrayBottomFraction"]
        XCTAssertFalse(d === UserDefaults.standard, "a private defaults store")
        let saved = keys.map { d.object(forKey: $0) }
        let theme = (ThemeRuntime.scale, ThemeRuntime.opacity, ThemeRuntime.frost), gate = AgentPaneLayout.splitsEnabled
        let seams = (XrayPanels.dch, XrayPanels.run, XrayPanels.model, XrayPanels.window, XrayPanels.chaptersRead, XrayPanels.keepRows)
        let remembered = XrayPanels.shared.remembered
        defer {
            for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
            (ThemeRuntime.scale, ThemeRuntime.opacity, ThemeRuntime.frost) = theme
            AgentPaneLayout.splitsEnabled = gate
            XrayPanels.shared.open = [:]
            (XrayPanels.dch, XrayPanels.run, XrayPanels.model, XrayPanels.window, XrayPanels.chaptersRead, XrayPanels.keepRows) = seams
            XrayPanels.shared.remembered = remembered
        }
        (ThemeRuntime.scale, ThemeRuntime.opacity, ThemeRuntime.frost) = (1, 1, false)
        AgentPaneLayout.splitsEnabled = true
        let m = d1.windowModel(store())
        defer { m.close() }
        m.terminal.request = { AgentTerminalSpawn.local($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
        m.terminal.spawn = { _, _ in AgentTerminalTests.FakeChild() }
        m.setVisible(true)
        m.select(.live(key("api")))
        if panes > 1 { m.adopt(d1.paneLayout(Self.names.prefix(panes).map { d1.paneTarget($0) })) }
        XrayPanels.dch = XrayPanelTasksTests.gate([1, 171, 0])
        // An open's read parks until its panel stops (cancel): the drawer draws its placeholder; ops apply data themselves.
        XrayPanels.run = { _, _, _ in try? await Task.sleep(for: .seconds(3600)); return (-1, Data()) }
        XrayPanels.model = { [weak m] _ in m }
        XrayPanels.chaptersRead = XrayPanels.fromDch
        XrayPanels.keepRows = { false }
        let win = AgentsWindow.makeWindow(m, autosave: nil)
        defer { XrayPanels.shared.open = [:]; win.contentViewController = nil; win.close() }   // QA R2077 n1: close it too
        XrayPanels.window = { [weak win] _ in win }
        win.setContentSize(NSSize(width: 1600, height: 900))
        let v = try XCTUnwrap(win.contentView)
        settle(v)
        XCTAssertEqual(m.layout.panes.count, panes, "the fixture's panes")
        try body(m, win, v)
        XCTAssertFalse(win.isVisible, "never shown")
    }

    func ids(_ m: AgentWindowModel) -> [AgentSidebar.RowID] { Self.names.map { .live(key($0)) } }

    /// Op 1: a sidebar click on another session (one pane), and the keyboard's next/previous.
    func testSessionSwitchOnePane() throws {
        try rig(panes: 1) { m, _, v in
            let ids = ids(m)
            measure("agents.switch click (1 pane)", v) { i in m.select(ids[(i + 1) % ids.count]) }
            measure("agents.switch key down/up (1 pane)", v) { i in m.move((i / 8) % 2 == 0 ? 1 : -1) }
            XCTAssertEqual(m.layout.panes.count, 1)
        }
    }

    /// Op 1 and 3: on a 3-pane layout, a click on a session another pane shows (that pane takes the focus), with the drawer
    /// closed, then open (the drawer follows the focus: xrayFollow).
    func testSessionSwitchThreePanesAndDrawerFollow() throws {
        try rig(panes: 3) { m, win, v in
            let shown = Self.names.prefix(3).map { AgentSidebar.RowID.live(key($0)) }
            measure("agents.switch focus pane (3 panes, drawer closed)", v) { i in m.select(shown[(i + 1) % 3]) }
            XCTAssertEqual(m.layout.panes.count, 3, "a shown session focuses its pane, no park")
            XCTAssertTrue(win.toggleXray())
            settle(v)
            measure("xray.follow focus pane (3 panes, drawer open)", v) { i in m.select(shown[(i + 1) % 3]) }
            XCTAssertTrue(XrayPanels.shared.open[m.layout.focused] != nil, "the drawer followed the focus")
            measure("agents.switch click unshown session (3 panes, drawer open)", v) { i in m.select(ids(m)[3 + i % 9]) }
        }
    }

    /// Op 2: on 2 panes (3 columns at 1600 pt leave no room for a 4th), split the focused pane (2 -> 3), close it
    /// (3 -> 2); Open to the Side (2 -> 3) and close.
    func testPaneOpenAndClose() throws {
        try rig(panes: 2) { m, _, v in
            measure("agents.paneOpen split (2->3)", v, after: { _ in
                XCTAssertEqual(m.layout.panes.count, 3, "split, not refused")
                if m.layout.panes.count == 3 { m.perform(.closePane); self.settle(v) }
            }) { _ in XCTAssertTrue(m.perform(.split(.columns))) }
            measure("agents.paneClose (3->2)", v, before: { _ in
                if m.layout.panes.count == 2 { m.perform(.split(.columns)); self.settle(v) }
            }) { _ in XCTAssertTrue(m.perform(.closePane)) }
            XCTAssertEqual(m.layout.panes.count, 2)
            measure("agents.paneOpen open to the side (2->3)", v, after: { _ in
                XCTAssertEqual(m.layout.panes.count, 3, "opened to the side, not refused")
                if m.layout.panes.count == 3 { m.perform(.closePane); self.settle(v) }
            }) { i in m.openToTheSide(.live(self.key(Self.names[3 + i % 9]))) }
            XCTAssertEqual(m.layout.panes.count, 2)
        }
    }

    /// Op 3: the drawer opens (first frame: the placeholder, the reads parked) and closes, on 1 and 3 panes; and a re-open
    /// that draws the kept rows on its first frame (#1976).
    func testDrawerOpenAndClose() throws {
        for panes in [1, 3] {
            try rig(panes: panes) { m, win, v in
                measure("xray.open (\(panes) pane, placeholder)", v, after: { _ in win.toggleXray(); self.settle(v) }) { _ in
                    XCTAssertTrue(win.toggleXray())
                }
                measure("xray.close (\(panes) pane)", v, before: { _ in win.toggleXray(); self.settle(v) }) { _ in
                    XCTAssertTrue(win.toggleXray())
                }
                XCTAssertTrue(XrayPanels.shared.open.isEmpty)
                guard panes == 3 else { return }
                XrayPanels.keepRows = { true }
                XCTAssertTrue(win.toggleXray())
                XrayPanels.shared.open[m.layout.focused]?.apply(tasks: Self.tasks, memory: Self.memory, chapters: Self.chapters)
                win.toggleXray()   // closed: its rows are kept for the next open
                settle(v)
                measure("xray.open (3 panes, kept rows: 60 tasks, 300 prompts)", v, after: { _ in win.toggleXray(); self.settle(v) }) { _ in
                    XCTAssertTrue(win.toggleXray())
                }
            }
        }
    }

    /// Op 4: the drawer's tab strip (each tab the big answers give) and the bottom pane's tabs.
    func testDrawerTabSwitch() throws {
        try rig(panes: 3) { m, win, v in
            XCTAssertTrue(win.toggleXray())
            let p = try XCTUnwrap(XrayPanels.shared.open[m.layout.focused])
            p.apply(tasks: Self.tasks, memory: Self.memory, chapters: Self.chapters)
            settle(v)
            let tabs = p.tabs
            XCTAssertTrue(tabs.count >= 3, "\(tabs)")
            measure("xray.tab (\(tabs.map(\.rawValue).joined(separator: "/")))", v) { i in p.select(tabs[(i + 1) % tabs.count]) }
            for t in tabs {
                measure("xray.tab -> \(t.rawValue)", v, before: { _ in p.select(tabs.first { $0 != t } ?? t) }) { _ in p.select(t) }
            }
            let bottom = XrayBottomTab.allCases
            measure("xray.bottomTab", v) { i in XrayBottomPane.shared.show(bottom[(i + 1) % bottom.count]) }
        }
    }

    /// Calibration: the forced layout and display with nothing changed. Split: the drawer's view alone (XrayPanelView in a
    /// never-shown window at the drawer's size) for a tab switch and an apply, against the same ops in the whole window.
    func testCalibrationAndDrawerAlone() throws {
        try rig(panes: 3) { _, _, v in measure("noop (3 panes, whole window)", v) { _ in } }
        let p = XrayPanelModel(target: XrayChaptersTests.local, tab: .tasks)
        p.now = { XrayPanelTasksTests.now }
        p.apply(tasks: Self.tasks, memory: Self.memory, chapters: Self.chapters)
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 860), styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Themed(keepsViews: true) { XrayPanelView(panel: p) })
        host.frame = CGRect(x: 0, y: 0, width: 440, height: 860)
        win.contentView = host
        defer { win.contentView = nil; win.close(); p.stop() }   // QA R2077 n1
        settle(host)
        let tabs = p.tabs
        measure("xray.tab alone (drawer view only)", host) { i in p.select(tabs[(i + 1) % tabs.count]) }
        p.select(.prompts)
        measure("xray.apply alone, Prompts (drawer view only)", host, before: { _ in
            p.apply(tasks: (1, Data()), memory: (1, Data()), chapters: (1, Data()))
        }) { _ in p.apply(tasks: Self.tasks, memory: Self.memory, chapters: Self.chapters) }
        XCTAssertFalse(win.isVisible)
    }

    /// Op 5: an answer applied to an open drawer (the main-thread part: parse in take*, publish, layout), the big answers
    /// on Tasks and on Prompts; the parse alone for the split.
    func testDrawerApply() throws {
        try rig(panes: 3) { m, win, v in
            for tab in [XrayTab.tasks, .prompts] {
                var p: XrayPanelModel?
                measure("xray.apply (\(tab.rawValue) shown; 60 tasks, 20 memory, 300 prompts)", v, before: { _ in
                    if let p = XrayPanels.shared.open[m.layout.focused] { p.close() }
                    XCTAssertTrue(win.toggleXray(on: tab))
                    p = XrayPanels.shared.open[m.layout.focused]
                }) { _ in p?.apply(tasks: Self.tasks, memory: Self.memory, chapters: Self.chapters) }
                XCTAssertTrue(p?.loaded == true && p?.tab == tab)
                // #2091: what the main thread does for a read's answer now: the parse ran off main (readBoth), the take here
                let parsed = [XrayPanelModel.parse(.tasks, Self.tasks), XrayPanelModel.parse(.memory, Self.memory),
                              XrayPanelModel.parse(.chapters, Self.chapters)]
                measure("xray.apply main thread only, pre-parsed (\(tab.rawValue) shown)", v, before: { _ in
                    if let p = XrayPanels.shared.open[m.layout.focused] { p.close() }
                    XCTAssertTrue(win.toggleXray(on: tab))
                    p = XrayPanels.shared.open[m.layout.focused]
                }) { _ in p?.apply(parsed) }
                XCTAssertTrue(p?.loaded == true && p?.tab == tab)
            }
            var parse = [Double]()
            for _ in 0..<Self.runs {
                parse.append(Self.ms {
                    _ = XrayTasks.parse(Self.tasks.1); _ = XrayMemory.parse(Self.memory.1); _ = XrayChapters.parse(Self.chapters.1)
                })
            }
            print(String(format: "PERF xray.apply parse only p50 %.2f p95 %.2f ms", Samples.pct(parse, 0.5), Samples.pct(parse, 0.95)))
            var one = [Double]()   // #2091: the parse the reads run off main (one JSON decode for the chapters' four reads)
            for _ in 0..<Self.runs {
                one.append(Self.ms {
                    _ = XrayPanelModel.parse(.tasks, Self.tasks); _ = XrayPanelModel.parse(.memory, Self.memory)
                    _ = XrayPanelModel.parse(.chapters, Self.chapters)
                })
            }
            print(String(format: "PERF xray.apply off-main parse (XrayPanelModel.parse) p50 %.2f p95 %.2f ms", Samples.pct(one, 0.5), Samples.pct(one, 0.95)))
        }
    }
}
