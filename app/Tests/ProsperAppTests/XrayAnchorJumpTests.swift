import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1352 (#1346 design 3.3): a task row or a memory's "Read the prompt" jumps to the block of dch's anchor
/// f<inode>:<offset>. A fake transcript in tempDir() read inline by a standalone model (JumpFixture: no watch, no timer,
/// no dch); the jump is the jumper's request (no view, no scroll); cards go to a recorder of the panel's present seam or
/// to FakeCardPresenter. No window is shown, no key is posted, no real dch runs.
@MainActor
final class XrayAnchorJumpTests: XCTestCase {

    /// A transcript of `turns` turns (JumpFixture: turn i = "Prompt i", a Bash call, "Done i"), each line's start offset
    /// by its text, and the file's inode.
    struct Scene {
        let url: URL
        let model: AgentTranscriptModel
        let inode: UInt64
        let starts: [UInt64]
        func anchor(line: Int) -> String { "f\(inode):\(starts[line])" }
    }

    func scene(turns: Int = 10, pageBytes: UInt64 = 1 << 20, maxBlocks: Int = 2_000) throws -> Scene {
        let url = tempDir().appendingPathComponent("x.jsonl")
        let lines = JumpFixture.turns(turns).map(JumpFixture.line)
        try lines.reduce(Data(), +).write(to: url)
        var starts: [UInt64] = [], at: UInt64 = 0
        for l in lines { starts.append(at); at += UInt64(l.count) }
        let m = AgentTranscriptModel()
        m.offMain = { $0() }
        m.makeWatch = { _, _ in NSObject() }
        m.tickInterval = 3600
        m.pageBytes = pageBytes
        m.maxBlocks = maxBlocks
        m.update(AgentTranscriptSource(key: AgentSessionKey(dir: "/tmp/dch-test", name: "api"), dchVersion: "1.30.0",
                                       dchState: "idle", sessionId: "0b7c2f3e-1111-2222-3333-444455556666",
                                       transcriptPath: url.path))
        m.start()
        m.showAnyway = true
        var st = stat()
        XCTAssertEqual(stat(url.path, &st), 0)
        return Scene(url: url, model: m, inode: UInt64(st.st_ino), starts: starts)
    }

    /// The prompt text of the block a jump asked for.
    func prompt(_ m: AgentTranscriptModel, _ id: Int?) -> String? {
        guard let b = m.blocks.first(where: { $0.id == id }), case .user(let c) = b.body else { return nil }
        return c.text
    }

    /// JumpFixture: turn i's prompt is line 4i (prompt, tool call, result, reply).
    static func promptLine(_ turn: Int) -> Int { 4 * turn }

    /// Red with no-anchorOK: a 130-digit offset of zeros parses to 0 and would pass. #1471: the transcript jump is gone;
    /// the anchor check stays (X-ray's card opens from it).
    func testBadAnchorIsRefused() throws {
        let s = try scene()
        defer { s.model.stop() }
        let padded = "f\(s.inode):" + String(repeating: "0", count: 130)
        XCTAssertFalse(DchCtl.anchorOK(padded), "over 128 bytes")
        XCTAssertTrue(DchCtl.anchorOK("f\(s.inode):0"), "control: the same anchor unpadded")
    }

    /// A command row (no chapter) and a "?<n>" row open the card; so does a refused anchor.
    func testCommandRowOpensTheCard() throws {
        let s = try scene()
        defer { s.model.stop() }
        let out = XrayPanelTasksTests.ndjson([#"{"schema":1,"session":"api","session_id":"s-1","source":"command","title":"Example Org ledger","partial":false}"#,
            #"{"task":{"id":"OQ-7","title":"Ship it","status":"pending","chapter":null,"created_chapter":null,"url":"https://example.org/x"}}"#,
            #"{"task":{"id":"?3","title":"Create pending","status":"pending","chapter":null}}"#,
            #"{"task":{"id":"4","title":"Bad","status":"pending","chapter":"f1:2;x"}}"#, XrayPanelTasksTests.done])
        let tasks = XrayTasks.parse(out).tasks
        XCTAssertEqual(tasks.count, 3)
        let p = XrayPanelModel(target: XrayTarget(name: "api", dir: "/tmp/dch-test"), tab: .tasks)
        var cards: [String] = []
        p.presentCard = { cards.append($0.id) }
        for t in tasks { p.activate(t) }
        XCTAssertEqual(cards, ["OQ-7", "?3", "4"])
    }

    /// Terminal mode, and a remote row: no transcript, so the card (through the window's presenter for a task).
    func testTerminalModeAndRemoteOpenTheCard() async throws {
        let key = AgentSessionKey(dir: "/tmp/dch-test", name: "api")
        let store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        store.sessions = [AgentSession(key: key, alias: "", activity: AgentWindowD1Tests.now - 60, state: .idle, agents: 0,
                                       version: "1.78.0")]
        let m = AgentWindowModel(lastLive: AgentLastLiveHome(), layouts: nil)
        m.now = { AgentWindowD1Tests.now }
        m.openSession = { _ in }
        m.resume = { _ in }
        m.onVisible = { _ in }
        m.ageInterval = 3600
        m.onNewRuntime = { r in
            r.transcript.offMain = { $0() }
            r.transcript.makeWatch = { _, _ in NSObject() }
            r.transcript.tickInterval = 3600
        }
        m.runtimes.values.forEach(m.onNewRuntime)
        final class Spawns { var count = 0 }
        let spawns = Spawns()
        m.terminal.request = { AgentTerminalSpawn.local($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
        m.terminal.spawn = { _, _ in spawns.count += 1; return AgentTerminalTests.FakeChild() }
        m.bind(store)
        m.setVisible(true)
        m.select(.live(key))
        defer { m.close() }
        let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        win.model = m
        let cards = FakeCardPresenter()
        win.cards = cards
        let (dch, run, model, window) = (XrayPanels.dch, XrayPanels.run, XrayPanels.model, XrayPanels.window)
        defer { (XrayPanels.dch, XrayPanels.run, XrayPanels.model, XrayPanels.window) = (dch, run, model, window); XrayPanels.shared.open = [:] }
        XrayPanels.dch = XrayPanelTasksTests.gate([1, 78, 0])
        let row = #"{"task":{"id":"12","title":"Fix the login test","status":"pending","chapter":"f5:100","blocked_by":[]}}"#
        XrayPanels.run = XrayPanelTasksTests.FakeRun(tasks: (0, XrayPanelTasksTests.ndjson([XrayPanelTasksTests.header, row,
                                                                                         XrayPanelTasksTests.done]))).run
        XrayPanels.model = { [weak m] _ in m }
        XrayPanels.window = { [weak win] _ in win }
        let pane = m.layout.focused
        XCTAssertTrue(m.paneHasTerminal)
        XCTAssertTrue(win.toggleXray())
        let p = try XCTUnwrap(XrayPanels.shared.open[pane])
        await p.reading?.value
        let t = try XCTUnwrap(p.shownGroups.flatMap(\.tasks).first)   // a pending task: the first group (In progress) is empty
        p.activate(t)
        XCTAssertEqual(cards.presents, 1, "the task card through the window's presenter")
        XCTAssertEqual(cards.size, XrayTaskCard.size)
        let mem = try XCTUnwrap(p.memory?.items.first)
        p.openMemoryCard(mem)
        XCTAssertEqual(cards.presents, 2, "the memory card through the same presenter (XrayPanels.window)")
        XCTAssertEqual(cards.size, XrayMemoryCard.size)
        XCTAssertTrue(m.paneHasTerminal, "#1471: still a terminal (no mode to switch to)")
        XCTAssertTrue(XrayPanels.fromDch(pane, p.target) && XrayPanels.fromDch(pane, XrayTarget(name: "host:api", dir: nil)),
                      "#1471: a local and a remote row both read dch")
        XCTAssertEqual(spawns.count, 0, "no terminal spawned")
        XCTAssertFalse(win.isVisible, "never shown")
    }
}
