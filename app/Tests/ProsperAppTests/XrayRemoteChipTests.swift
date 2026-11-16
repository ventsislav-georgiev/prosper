import AppKit
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
                AgentRemoteHeader.todosTapped(in: win) { none += 1 }
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
                    AgentRemoteHeader.todosTapped(in: win) { none += 1 }
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
}
