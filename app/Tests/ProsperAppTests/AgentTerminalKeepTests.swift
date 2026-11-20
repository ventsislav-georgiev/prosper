import AppKit
import XCTest
@testable import ProsperApp

/// #1782 (#1778 R1): a pane keeps its last `keptSessions` sessions attached; a switch back swaps the kept surface in with
/// no new client, no new screen and no replay, and a kept one costs no parse, draw, resize or timer while not shown.
/// Fakes only (AgentTerminalTests.Rig: a recorded spawn, a fake screen, an injected clock); the views live in windows
/// that are never ordered in. No dch runs.
final class AgentTerminalKeepTests: XCTestCase {

    static func key(_ name: String) -> AgentSessionKey { AgentSessionKey(dir: "/Users/example/.dch-test", name: name) }

    @MainActor
    func spin(_ t: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    @MainActor
    func wait(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() > end { return XCTFail("timed out: \(what)", file: file, line: line) }
            spin(0.01)
        }
    }

    /// The counting row: a -> b -> a starts 2 clients (not 3) on 2 screens (2 begins), ends none, and a comes back on its
    /// own screen with what it printed while kept, fed once on the way back (never while kept: one main hop for 3 chunks).
    @MainActor
    func testSwitchBackSwapsTheKeptSessionInWithNoNewClient() {
        let rig = AgentTerminalTests.Rig(keep: AgentTerminalController.keptSessions)
        let c = rig.c, a = Self.key("api"), b = Self.key("api-qa")
        c.attach(a)
        rig.grid(100, 30)
        XCTAssertEqual(c.phase, .live)
        let screenA = c.screen
        c.attach(b)
        XCTAssertEqual(c.phase, .live, "b attached at the known grid")
        XCTAssertEqual(c.keptKeys, [a])
        for n in [1, 2] {   // one chunk, its main turn, then two more: they find the drain still scheduled
            for _ in 0..<n { rig.ios.first?.output(Array("kept|".utf8)) }
            spin()
        }
        XCTAssertTrue(rig.screens.first?.fed.isEmpty == true, "a kept session's bytes are not parsed")
        XCTAssertEqual(c.keptInboxBytes, 15, "they wait in its inbox")
        XCTAssertEqual(c.keptDrains, 1, "one main hop for three chunks")
        c.attach(a)
        XCTAssertEqual(rig.requests.count, 2, "a -> b -> a: 2 clients, not 3")
        XCTAssertEqual(rig.screens.count, 2, "2 begins: no new screen for a")
        XCTAssertEqual(rig.children.map(\.terminated), [0, 0], "no client ended")
        XCTAssertTrue(c.screen === screenA, "a's own screen")
        XCTAssertEqual(c.phase, .live)
        XCTAssertTrue(c.revealed, "shown at once: no cover, no wait")
        XCTAssertEqual(String(decoding: rig.screens.first?.fed ?? [], as: UTF8.self), "kept|kept|kept|", "fed on the way back")
        XCTAssertEqual(c.keptKeys, [b])
        XCTAssertEqual(c.keptInboxBytes, 0)
        rig.screens.first?.events.backlog(true)   // a's own screen still speaks for it after the swap
        spin()
        rig.ios.first?.output(Array("late|".utf8))
        spin()
        XCTAssertEqual(rig.screens.first?.fed.count, 15, "a's renderer backlog holds the drain")
        rig.screens.first?.events.backlog(false)
        spin()
        XCTAssertEqual(rig.screens.first?.fed.count, 20, "and its end lets it go")
        c.input([0x61])
        c.writer.flush()
        XCTAssertEqual(rig.children.first?.written, [0x61], "the keys reach a's client")
        XCTAssertEqual(rig.children.last?.written, [], "never b's")
        rig.clock.advance(2)
        XCTAssertEqual(rig.children.map(\.redraws), [0, 0], "no timer of either attach fired on the other")
        XCTAssertEqual(rig.children.map(\.resizes), [[], []], "no size went out: the grid held")
        c.attach(nil)
        XCTAssertEqual(rig.children.map(\.terminated), [1, 1], "detach: the shown and the kept client end")
    }

    /// a -> b -> c -> d -> e with the cap of 4: exactly one client ends, the oldest (a); b, c, d stay kept.
    @MainActor
    func testAFifthSessionEndsExactlyTheOldestKeptClient() {
        let rig = AgentTerminalTests.Rig(keep: AgentTerminalController.keptSessions)
        let keys = ["api", "api-qa", "web", "docs", "build"].map(Self.key)
        rig.c.attach(keys.first)
        rig.grid(100, 30)
        for k in keys.dropFirst() { rig.c.attach(k) }
        XCTAssertEqual(rig.requests.count, 5)
        XCTAssertEqual(rig.children.map(\.terminated), [1, 0, 0, 0, 0], "one ended: the oldest")
        XCTAssertEqual(rig.c.keptKeys, Array(keys[1...3]))
        XCTAssertEqual(rig.c.key, keys.last)
        rig.c.attach(keys[1])
        XCTAssertEqual(rig.requests.count, 5, "a kept one comes back with no client")
        XCTAssertEqual(rig.children.map(\.terminated), [1, 0, 0, 0, 0], "and ends none")
        rig.c.attach(nil)
    }

    /// A kept surface's view leaves the window (libghostty stops its display link there: no frames), gets no frame change,
    /// no pty size and no grid from its screen while another is shown; its OSC 52 write lands nowhere (the gate reads the
    /// shown session only); the keys follow the swap, both ways.
    @MainActor
    func testAKeptSurfaceIsOutOfTheWindowAndGetsNoResizeOrClipboard() {
        _ = NSApplication.shared
        let rig = AgentTerminalTests.Rig(keep: AgentTerminalController.keptSessions)
        rig.view()
        let c = rig.c, a = Self.key("api"), b = Self.key("api-qa")
        let slot = AgentTerminalHostSlot(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let win = NSWindow(contentRect: slot.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = slot
        let pb = NSPasteboard(name: NSPasteboard.Name("eu.illegible.prosper.xctest.keep.\(UUID().uuidString)"))
        defer { c.attach(nil); win.contentView = nil; win.close(); pb.releaseGlobally() }
        @MainActor func mount() -> AgentTerminalHostView {   // what AgentTerminalRepresentable.updateNSView does
            let v = c.hostView()
            slot.hold(v)
            v.owner = c
            c.view = v
            v.pasteboard = { pb }
            return v
        }
        c.attach(a)
        let va = mount()
        XCTAssertTrue(win.makeFirstResponder(va))
        rig.grid(100, 30)
        let aFrame = va.frame
        c.attach(b)
        let vb = mount()
        XCTAssertFalse(va === vb, "b's own surface")
        XCTAssertTrue(va.window == nil && va.superview == nil, "a's view is out of the window: no display link, no frames")
        XCTAssertTrue(va.owner == nil, "and calls nothing")
        XCTAssertTrue(win.firstResponder === vb, "the keys followed the swap")
        slot.setFrameSize(NSSize(width: 900, height: 600))
        XCTAssertEqual(va.frame, aFrame, "the kept view's frame did not move")
        XCTAssertEqual(vb.frame.size, slot.bounds.size)
        c.gridChanged(cols: 110, rows: 33)   // b's view laid out again
        rig.screens.first?.events.resize(50, 20)   // a's screen reporting: stale
        spin()
        rig.clock.advance(1)
        XCTAssertEqual(rig.children.first?.resizes, [], "0 resizes to the kept client")
        XCTAssertEqual(rig.children.last?.resizes, [[110, 33]], "the shown one's, once")
        let kept = AgentTerminalTests.ClipRequest(.osc52Write, "from-kept")
        va.confirmClipboard(kept)
        XCTAssertEqual(kept.answers, [false])
        XCTAssertTrue(pb.string(forType: .string) == nil, "a kept session never sets the clipboard")
        let shown = AgentTerminalTests.ClipRequest(.osc52Write, "from-shown")
        vb.confirmClipboard(shown)
        XCTAssertEqual(pb.string(forType: .string), "from-shown", "the shown one does (the gate itself is open)")
        c.attach(a)
        let back = mount()
        XCTAssertTrue(back === va, "a's view, surface and all, is back")
        XCTAssertTrue(va.window === win && vb.window == nil)
        XCTAssertTrue(win.firstResponder === va, "the keys came back with it")
        XCTAssertEqual(va.frame.size, slot.bounds.size, "shown at the pane's size")
        XCTAssertEqual(rig.requests.count, 2)
    }

    /// Teardown (window closed or hidden, the pane gone: attach(nil)) ends every kept client; a kept client whose session
    /// ended (it exited) is dropped without a signal; another pane attaching a kept session ends the kept one first.
    @MainActor
    func testTeardownExitAndAnotherPaneDropKeptClients() {
        let rig = AgentTerminalTests.Rig(keep: AgentTerminalController.keptSessions)
        let keys = ["api", "api-qa", "web"].map(Self.key)
        rig.c.attach(keys[0])
        rig.grid(100, 30)
        rig.c.attach(keys[1])
        rig.c.attach(keys[2])
        XCTAssertEqual(rig.c.keptKeys, Array(keys[0...1]))
        rig.ios.first?.exit(0)   // api's session ended: its client left
        spin()
        XCTAssertEqual(rig.c.keptKeys, [keys[1]], "the exited one is dropped")
        XCTAssertEqual(rig.children.first?.terminated, 0, "it had exited: no signal")
        XCTAssertEqual(rig.c.phase, .live, "the shown session is untouched")
        let other = AgentTerminalTests.Rig(keep: AgentTerminalController.keptSessions)
        other.grid(100, 30)
        other.c.attach(keys[1])
        XCTAssertEqual(rig.children.map(\.terminated), [0, 1, 0], "one client per session: the kept api-qa ended")
        XCTAssertTrue(rig.c.keptKeys.isEmpty)
        rig.c.attach(keys[0])
        XCTAssertEqual(rig.requests.count, 4, "an ended kept session attaches anew")
        rig.c.attach(keys[2])
        XCTAssertEqual(rig.c.keptKeys, [keys[0]])
        rig.c.attach(nil)
        XCTAssertEqual(rig.children.map(\.terminated), [0, 1, 1, 1], "teardown: every client ends")
        XCTAssertTrue(rig.c.keptKeys.isEmpty)
        other.c.attach(nil)
    }

    /// A busy kept session holds at most the inbox cap unparsed: past it the pump waits (the pty is not read, the
    /// master's OUT_CAP is the bound, and its drop ends the client: dropped as above).
    @MainActor
    func testAKeptInboxStopsAtItsCap() {
        let rig = AgentTerminalTests.Rig(keep: AgentTerminalController.keptSessions)
        rig.c.attach(Self.key("api"))
        rig.grid(100, 30)
        rig.c.attach(Self.key("api-qa"))
        let io = rig.ios.first, chunk = [UInt8](repeating: 0x78, count: 64 << 10)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {   // the pump thread: 17 chunks, one past the cap
            for _ in 0..<(AgentTerminalInbox.cap / chunk.count + 1) { io?.output(chunk) }
            done.signal()
        }
        wait("the pump filled the inbox") { rig.c.keptInboxBytes >= AgentTerminalInbox.cap }
        XCTAssertEqual(done.wait(timeout: .now() + 0.3), .timedOut, "the pump waits at the cap")
        XCTAssertEqual(rig.c.keptInboxBytes, AgentTerminalInbox.cap, "no byte past it")
        XCTAssertTrue(rig.screens.first?.fed.isEmpty == true)
        rig.c.attach(nil)   // the inbox closes: the waiting pump goes
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    }

    // MARK: Memory (the operator's "light on memory": measured, printed for the report)

    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// Real libghostty surfaces in a never-shown 1000 x 680 pt window: each session gets 2000 lines of 100 columns (the
    /// --scrollback 2000 replay) and a full screen, then is kept. Counted: clients, kept keys, inbox bytes (0: all parsed
    /// while shown); measured: phys_footprint per kept session, printed as KEEP1782 for the report. The bound only
    /// catches a runaway (a leak per switch); the printed number is the measurement.
    @MainActor
    func testKeptSurfaceMemoryIsMeasuredPerSession() {
        _ = NSApplication.shared
        let rig = AgentTerminalTests.Rig(keep: AgentTerminalController.keptSessions)
        let c = rig.c
        c.makeScreen = { AgentGhosttyScreen($0) }
        let app = AgentTerminalLook.make()
        let slot = AgentTerminalHostSlot(frame: NSRect(x: 0, y: 0, width: 1000, height: 680))
        let win = NSWindow(contentRect: slot.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = slot
        defer { c.attach(nil); win.contentView = nil; win.close() }
        let line = { (i: Int) in "line \(i) " + String(repeating: "x", count: 88) + "|\r\n" }
        let replay = Array(((0..<2000).map(line).joined() + (0..<40).map(line).joined()).utf8)
        func show(_ name: String, clients: Int) {
            c.attach(Self.key(name))
            let v = c.hostView()
            slot.hold(v)
            v.look = { app }
            v.owner = c
            c.view = v
            v.show(c.screen as? AgentGhosttyScreen)
            wait("\(name) attached") { rig.requests.count == clients }
            rig.ios.last?.output(replay)
            wait("\(name) fed") { c.revealed && rig.children.count == clients }
            spin(0.05)
            (c.screen as? AgentGhosttyScreen)?.session.waitForPendingOutput()
        }
        show("api", clients: 1)
        spin(0.3)
        let one = Self.footprint()
        for (i, n) in ["api-qa", "web", "docs"].enumerated() { show(n, clients: i + 2) }
        spin(0.3)
        let four = Self.footprint()
        XCTAssertEqual(c.keptKeys.map(\.name), ["api", "api-qa", "web"])
        XCTAssertEqual(c.keptInboxBytes, 0, "everything was parsed while shown")
        XCTAssertEqual(rig.children.map(\.terminated), [0, 0, 0, 0])
        let per = max(0, four - one) / 3
        print("KEEP1782 footprint one attached \(one) four attached \(four) per kept session \(per) bytes"
              + " (\(per >> 10) KiB), grid \(c.grid.map { "\($0.cols)x\($0.rows)" } ?? "none"), scale \(win.backingScaleFactor)")
        XCTAssertLessThan(per, 256 << 20, "a kept session is bounded")
    }
}
