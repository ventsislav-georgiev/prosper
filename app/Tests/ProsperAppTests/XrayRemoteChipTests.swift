import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1388 (X-ray P5): the Todos chip on a session on another machine opens X-ray on Tasks as the local chip does, and
/// opens nothing, saying why, when the host's read finds no Tasks tab. Fake runner and fake list only: no dch, no host,
/// no window shown.
@MainActor
final class XrayRemoteChipTests: XCTestCase {

    typealias FakeRun = XrayPanelTasksTests.FakeRun

    nonisolated static let list = #"[{"name":"api","alias":"","host":"example-host","state":"idle","stale":false,"cwd":null}]"#
    static let remoteID = AgentSidebar.RowID.remote(host: "example-host", name: "api")

    /// The product gate and runner swapped for a fake dch of `version`, put back after (as XrayPanelTasksTests does).
    func withSeams(_ version: [Int], _ fake: FakeRun, _ body: () async throws -> Void) async rethrows {
        let (dch, run) = (XrayPanels.dch, XrayPanels.run)
        defer { (XrayPanels.dch, XrayPanels.run) = (dch, run); XrayPanels.shared.open = [:] }
        XrayPanels.dch = XrayPanelTasksTests.gate(version)
        XrayPanels.run = fake.run
        try await body()
    }

    /// A never-shown window on a model whose selected row is the remote "api" on "example-host"; the terminal on a recorder.
    func window(_ body: (AgentsNSWindow, AgentWindowModel) async throws -> Void) async rethrows {
        let store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        let m = AgentWindowModel()
        m.now = { AgentWindowD1Tests.now }
        m.openSession = { _ in }
        m.resume = { _ in }
        m.onVisible = { _ in }
        m.ageInterval = 3600
        m.remoteRun = { _, _ in Data(Self.list.utf8) }
        m.remoteClock = { 100 }
        m.terminal.request = { AgentTerminalSpawn.attach($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
        m.terminal.spawn = { _, _ in AgentTerminalTests.FakeChild() }
        m.terminal.makeScreen = { events in AgentTerminalTests.FakeScreen(events) }
        m.terminal.after = { _, _ in }
        m.terminal.clientVersion = { _ in [1, 78, 0] }
        m.terminal.gridChanged(cols: 80, rows: 24)
        m.bind(store)
        m.setVisible(true)
        m.click(Self.remoteID)
        defer { m.close() }
        let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        win.model = m
        win.cards = FakeCardPresenter()
        try await body(win, m)
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// Red at TIP: AgentRemoteHeader.todosTapped does not exist (the icon was inert: nothing called todosChipTapped).
    func testRemoteChipOpensXrayOnTasksWhenTheTabExists() async throws {
        let fake = FakeRun()
        try await withSeams([1, 78, 0], fake) {
            try await window { win, m in
                XCTAssertEqual(m.selectedRow?.id, Self.remoteID)
                var none = 0
                AgentRemoteHeader.todosTapped(in: win, clear: {}) { none += 1 }
                let p = try XCTUnwrap(XrayPanels.shared.open[m.layout.focused])
                await p.reading?.value
                XCTAssertEqual(p.tab, .tasks)
                XCTAssertEqual(p.tabs, [.tasks, .memory])
                XCTAssertEqual(none, 0, "a Tasks tab: no reason")
                XCTAssertEqual(Set(fake.calls), [["/fake/dch", "--xray", "example-host:api", "--tasks", "--json"],
                                                 ["/fake/dch", "--xray", "example-host:api", "--memory", "--json"]])
            }
        }
    }

    /// The host's dch does not know the flag (exit 1) or the read is refused (exit 6): no tab, nothing opens, the reason.
    func testRemoteChipWithNoTasksTabOpensNothingAndSaysWhy() async throws {
        for status: Int32 in [1, 6] {
            let fake = FakeRun(tasks: (status, Data("the host's dch does not know --tasks\n".utf8)))
            try await withSeams([1, 78, 0], fake) {
                try await window { win, m in
                    var none = 0
                    AgentRemoteHeader.todosTapped(in: win, clear: {}) { none += 1 }
                    await XrayPanels.shared.open[m.layout.focused]?.reading?.value
                    XCTAssertTrue(XrayPanels.shared.open[m.layout.focused] == nil, "exit \(status): nothing opens")
                    XCTAssertEqual(none, 1, "exit \(status): the reason is shown once")
                    XCTAssertEqual(AgentRemoteHeader.todosHelp(noList: true), "No task list on that host")
                    XCTAssertEqual(AgentRemoteHeader.todosReason, "No task list on that host")
                    XCTAssertNotEqual(AgentRemoteHeader.todosHelp(noList: false), AgentRemoteHeader.todosReason,
                                      "before a click the help says what a click does")
                }
            }
        }
    }

    /// Red at TIP: todosTapped has no `clear` (the Button never cleared the reason: a later click that finds the tab left it).
    func testReasonClearsWhenALaterClickFindsTheTasksTab() async throws {
        let bad = FakeRun(tasks: (1, Data("the host's dch does not know --tasks\n".utf8)))
        try await withSeams([1, 78, 0], bad) {
            try await window { win, m in
                var reason: AgentSidebar.RowID? = nil
                let row = Self.remoteID
                AgentRemoteHeader.todosTapped(in: win, clear: { reason = nil }) { reason = row }
                await XrayPanels.shared.open[m.layout.focused]?.reading?.value
                XCTAssertTrue(reason == row, "no Tasks tab: the reason is set")
                XCTAssertTrue(XrayPanels.shared.open[m.layout.focused] == nil, "nothing opens")
                XrayPanels.run = FakeRun().run
                AgentRemoteHeader.todosTapped(in: win, clear: { reason = nil }) { reason = row }
                let p = try XCTUnwrap(XrayPanels.shared.open[m.layout.focused])
                await p.reading?.value
                XCTAssertEqual(p.tab, .tasks, "X-ray opens on Tasks")
                XCTAssertTrue(reason == nil, "and the reason is gone")
            }
        }
    }

    /// Red at TIP: not red (the lookup is unchanged there); a mutant of window(of:) turns it red. Pins the lookup the header Button uses.
    func testTheButtonsWindowLookupFindsTheWindowOfTheFocusedPane() async throws {
        try await window { win, m in
            let anchor = NSView()   // the header's anchor, registered as the drawn one would be
            win.contentView?.addSubview(anchor)
            let saved = XrayCardAnchor.views
            XrayCardAnchor.register(anchor, m.layout.focused)
            defer { XrayCardAnchor.views = saved }
            XCTAssertTrue(AgentsNSWindow.window(of: m.layout.focused) === win, "the pane's header window is the window")
        }
    }

    /// Lays `host` out, driven by the run loop (sync: RunLoop is unavailable from async code), until `done` or 10 s.
    static func layOut(_ host: NSView, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !done() && Date() < deadline {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// #1951: a real XrayCardAnchor for `pane` (nil: the environment's default, the shared key) in a hosting view added to
    /// `parent`, laid out until its anchor is `pane`'s newest one.
    static func anchorHost(_ pane: UUID?, in parent: NSView) -> NSView {
        let host = NSHostingView(rootView: XrayCardAnchor().environment(\.agentPaneID, pane).frame(width: 20, height: 20))
        host.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        parent.addSubview(host)
        layOut(host, until: { XrayCardAnchor.views[pane]?.last?.view?.isDescendant(of: host) == true })
        return host
    }

    /// #1951: an anchor for `pane` made and laid out in a never-shown plain window, then taken out of it (as SwiftUI leaves
    /// a header instance it updated last and then removed); the caller holds the returned host, so the anchor stays alive.
    static func staleAnchor(_ pane: UUID?) -> NSView {
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let host = anchorHost(pane, in: other.contentView ?? NSView())
        host.removeFromSuperview()
        return host
    }

    /// #1951. Red at TIP (AgentsWindow.swift:672, `views[pane]?.view ?? views[nil]?.view`: one entry per pane, the last
    /// registered, and a view that is there but in no Agents window ends the lookup at nil): a second XrayCardAnchor for
    /// the pane, made after the drawn one, in another window, then out of any window, then freed, never hides the window
    /// that draws the pane; the pane reads dch (fromDch: the Prompts tab) and a card hangs from the drawn anchor.
    func testAnAnchorRegisteredLaterOutsideTheWindowNeverHidesIt() async throws {
        try await window { win, m in
            let saved = XrayCardAnchor.views
            XrayCardAnchor.views = [:]
            defer { XrayCardAnchor.views = saved }
            let pane = m.layout.focused, target = XrayTarget(name: "example-host:api", dir: nil)
            let drawn = Self.anchorHost(pane, in: try XCTUnwrap(win.contentView))
            defer { drawn.removeFromSuperview() }
            XCTAssertTrue(AgentsNSWindow.window(of: pane) === win, "the drawn anchor names the window")
            let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
            other.isReleasedWhenClosed = false
            defer { other.close() }
            var stale: NSView? = Self.anchorHost(pane, in: try XCTUnwrap(other.contentView))
            XCTAssertTrue(XrayCardAnchor.views[pane]?.last?.view?.window === other, "the newest anchor is in a plain window")
            XCTAssertTrue(AgentsNSWindow.window(of: pane) === win, "in another window: skipped")
            XCTAssertTrue(XrayPanels.fromDch(pane, target), "the pane reads dch")
            stale?.removeFromSuperview()
            XCTAssertTrue(XrayCardAnchor.views[pane]?.last?.view.map { $0.window == nil } == true, "the newest anchor is out of any window")
            XCTAssertTrue(AgentsNSWindow.window(of: pane) === win, "out of any window: skipped")
            XCTAssertTrue(XrayPanels.fromDch(pane, target))
            XCTAssertTrue(XrayCardAnchor.view(for: pane, in: win)?.isDescendant(of: drawn) == true, "the card hangs from the drawn anchor")
            stale = nil
            XCTAssertTrue(AgentsNSWindow.window(of: pane) === win, "freed: skipped")
        }
    }

    /// #1951. Red at TIP (AgentsWindow.swift:672: the `??` falls back only on a freed view, never on one out of a window):
    /// the header drawn with no pane id registers under the shared key; a pane-keyed anchor out of any window, registered
    /// later, does not hide it.
    func testAPaneAnchorOutOfAWindowFallsBackToTheSharedOne() async throws {
        try await window { win, m in
            let saved = XrayCardAnchor.views
            XrayCardAnchor.views = [:]
            defer { XrayCardAnchor.views = saved }
            let pane = m.layout.focused
            let drawn = Self.anchorHost(nil, in: try XCTUnwrap(win.contentView))
            defer { drawn.removeFromSuperview() }
            let stale = Self.staleAnchor(pane)
            XCTAssertTrue(XrayCardAnchor.views[pane]?.last?.view?.isDescendant(of: stale) == true)
            XCTAssertTrue(AgentsNSWindow.window(of: pane) === win, "the shared anchor's window")
            XCTAssertTrue(XrayCardAnchor.view(for: pane, in: win)?.isDescendant(of: drawn) == true)
        }
    }

    /// #1951: the registry holds live anchors, each once: an anchor SwiftUI updates 100 times is one entry, and a freed one
    /// goes at the next registration (the list never grows with header updates).
    func testTheRegistryKeepsEachLiveAnchorOnce() {
        let saved = XrayCardAnchor.views
        XrayCardAnchor.views = [:]
        defer { XrayCardAnchor.views = saved }
        let pane = UUID(), kept = NSView()
        for _ in 0..<100 { XrayCardAnchor.register(kept, pane) }
        XCTAssertEqual(XrayCardAnchor.views[pane]?.count, 1, "one entry for 100 updates")
        autoreleasepool { XrayCardAnchor.register(NSView(), pane) }
        XrayCardAnchor.register(kept, pane)
        XCTAssertEqual(XrayCardAnchor.views[pane]?.count, 1, "the freed one went")
        XCTAssertTrue(XrayCardAnchor.views[pane]?.last?.view === kept)
        XCTAssertTrue(XrayCardAnchor.views[nil] == nil, "no other key touched")
    }

    /// Red at TIP (AgentsWindow.swift:1675-1690, AgentRemoteHeader draws no XrayCardAnchor): the real remote branch of
    /// AgentDetailView, in the pane environment, registers an anchor, so window(of:) finds the window and the chip's tap opens Tasks.
    func testRemoteHeaderRegistersTheAnchorSoTheChipFindsItsWindow() async throws {
        let fake = FakeRun()
        try await withSeams([1, 78, 0], fake) {
            try await window { win, m in
                let saved = XrayCardAnchor.views
                XrayCardAnchor.views = [:]   // nothing registered by an earlier row
                defer { XrayCardAnchor.views = saved }
                let pane = m.layout.focused
                let host = NSHostingView(rootView: AgentDetailView(model: m, transcript: m.transcript, scrolls: false)
                    .environment(\.agentPaneID, pane).frame(width: 800, height: 500))
                host.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
                win.contentView = host
                Self.layOut(host, until: { AgentsNSWindow.window(of: pane) != nil })
                XCTAssertTrue(AgentsNSWindow.window(of: pane) === win, "the remote header's anchor names the window")
                AgentRemoteHeader.todosTapped(in: AgentsNSWindow.window(of: pane), clear: {}) { XCTFail("a Tasks tab: no reason") }
                let p = try XCTUnwrap(XrayPanels.shared.open[pane])
                await p.reading?.value
                XCTAssertEqual(p.tab, .tasks)
            }
        }
    }
}
