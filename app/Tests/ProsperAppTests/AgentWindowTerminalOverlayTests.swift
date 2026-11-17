import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #895 P2 step 3 (spec 5.4, 5.5): in Terminal mode the notice line and the todos list are overlays over the
/// terminal's top: the terminal pane keeps its frame with them shown or not, and reaches the window's bottom.
/// Offscreen only: the window is built by AgentsWindow.makeWindow and never shown or made key, its content is hosted
/// at a forced 1x and 2x backing, no event is posted. The terminal is the recorder of the terminal-mode rows
/// (fakeTerminal): no dch, no child, no pty. The frame comes from AgentPaneProbe("terminal"), set before the host is made
/// (nil in the product, no observer).
extension AgentWindowD1Tests {
    /// Never shown; reports the backing a row forces (the way the measurement rows do).
    final class OverlayBackingWindow: NSWindow {
        var fixedBacking: CGFloat = 1
        override var backingScaleFactor: CGFloat { fixedBacking }
    }

    /// One hosted window and the frames its probe saw (kind to the latest frame). `seen` is written by the probe action,
    /// which SwiftUI runs on the main actor from layout.
    @MainActor
    final class OverlayRig {
        final class Seen { var d: [String: CGRect] = [:] }
        let box: Seen
        var seen: [String: CGRect] { box.d }
        let win: OverlayBackingWindow
        let host: NSViewController
        let model: AgentWindowModel
        init(_ m: AgentWindowModel, size: CGSize, backing: CGFloat) {
            model = m
            // Before the host is made: the probe modifier attaches its observer only while the probe is set.
            let b = Seen()
            box = b
            AgentPaneArea.probe = { kind, _, r in b.d[kind] = r }
            let built = AgentWindowStyleTests.makeStandardWindow(m)
            host = built.contentViewController ?? NSViewController()
            built.contentViewController = nil   // the hosting controller moves into the forced-backing window
            win = OverlayBackingWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            win.fixedBacking = backing
            win.contentView = host.view
            host.view.frame = CGRect(origin: .zero, size: size)
            built.close()
        }
        /// Layout passes until the terminal's frame has been reported (a bounded count), then three more for a change.
        func settle(_ test: AgentWindowD1Tests) {
            for _ in 0..<40 where seen["terminal"] == nil { test.settle(host.view) }
            for _ in 0..<3 { test.settle(host.view) }
        }
        func close() {
            AgentPaneArea.probe = nil
            win.contentView = nil
            win.close()
        }
    }

    /// A live session with a TodoWrite list in its transcript, in Terminal mode, on the terminal recorder.
    @MainActor
    func overlayModel() throws -> (AgentWindowModel, AgentIslandStore, AgentSessionKey) {
        let convo = Self.corpus.appendingPathComponent("2.1.318/d-todowrite.jsonl")
        let s = session("api", .working, ago: 20, path: convo.path)
        let st = store([s])
        let m = windowModel(st)
        _ = fakeTerminal(m)
        m.setVisible(true)
        m.select(.live(s.key))
        XCTAssertEqual(m.paneMode, .terminal, "a live session opens in Terminal")
        XCTAssertTrue(m.transcript.todos != nil, "the fixture's list is read")
        return (m, st, s.key)
    }

    @MainActor
    func overlayRows(_ body: (CGFloat, CGSize) throws -> Void) rethrows {
        for backing: CGFloat in [1, 2] {
            for size in [CGSize(width: 1000, height: 680), CGSize(width: 720, height: 460)] { try body(backing, size) }
        }
    }

    // MARK: A notice never moves the terminal

    @MainActor
    func testTerminalFrameIsTheSameWithAndWithoutANotice() throws {
        try withModePref {
            try overlayRows { backing, size in
                let (m, st, key) = try overlayModel()
                defer { m.close() }
                let tag = "backing \(backing) size \(size)"
                let rig = OverlayRig(m, size: size, backing: backing)
                defer { rig.close() }
                rig.settle(self)
                XCTAssertFalse(rig.win.isVisible, "never on screen")
                let without = rig.seen["terminal"]
                XCTAssertTrue(without != nil && without!.height > 0, "the terminal pane reports a frame (\(tag))")
                XCTAssertTrue(AgentWindowControls.notice(st, key) == nil)
                st.notices[key] = "Attach command copied"   // the notice line draws it at once
                rig.settle(self)
                XCTAssertTrue(AgentWindowControls.notice(st, key) != nil)
                assertSame(rig.seen["terminal"], without, "the notice shown moved or resized the terminal (\(tag))")
                // A window built with the notice already up, laid out from the start.
                let again = OverlayRig(m, size: size, backing: backing)
                defer { again.close() }
                again.settle(self)
                assertSame(again.seen["terminal"], without, "a fresh window with the notice (\(tag))")
                st.notices[key] = nil
                again.settle(self)
                assertSame(again.seen["terminal"], without, "the notice gone (\(tag))")
            }
        }
    }

    // MARK: The todos list never moves the terminal

    @MainActor
    func testTerminalFrameIsTheSameWithTheTodosListOpen() throws {
        try withModePref {
            let saved = Preferences.agentWindowVerbosity
            defer { Preferences.agentWindowVerbosity = saved }
            Preferences.agentWindowVerbosity = .default
            try overlayRows { backing, size in
                let (m, _, _) = try overlayModel()
                defer { m.close() }
                let tag = "backing \(backing) size \(size)"
                XCTAssertEqual(m.verbosity, .default, "the list shows at the Default level only")
                XCTAssertFalse(m.transcript.todosOpen)
                let rig = OverlayRig(m, size: size, backing: backing)
                defer { rig.close() }
                rig.settle(self)
                let closed = rig.seen["terminal"]
                XCTAssertTrue(closed != nil && closed!.height > 0, "the terminal pane reports a frame (\(tag))")
                m.transcript.todosOpen = true   // what the header's chip does in Terminal mode (floatingTodos)
                rig.settle(self)
                assertSame(rig.seen["terminal"], closed, "the list open moved or resized the terminal (\(tag))")
                let open = OverlayRig(m, size: size, backing: backing)
                defer { open.close() }
                open.settle(self)
                assertSame(open.seen["terminal"], closed, "a fresh window with the list open (\(tag))")
                m.transcript.todosOpen = false
                open.settle(self)
                assertSame(open.seen["terminal"], closed, "the list closed (\(tag))")
            }
        }
    }

    // MARK: The terminal reaches the window's bottom

    @MainActor
    func testTerminalReachesTheWindowBottomInTerminalMode() throws {
        try withModePref {
            try overlayRows { backing, size in
                let (m, _, _) = try overlayModel()
                defer { m.close() }
                let tag = "backing \(backing) size \(size)"
                let rig = OverlayRig(m, size: size, backing: backing)
                defer { rig.close() }
                rig.settle(self)
                guard let term = rig.seen["terminal"], let pane = rig.seen["pane"], let header = rig.seen["header"] else {
                    return XCTFail("terminal, pane and header frames expected, got \(rig.seen.keys.sorted()) (\(tag))")
                }
                XCTAssertEqual(term.maxY, pane.maxY, accuracy: 1 / backing, "the terminal ends where the pane ends (\(tag))")
                XCTAssertEqual(term.maxY, m.paneArea.height, accuracy: 1 / backing, "and the pane area ends at the window's bottom (\(tag))")
                XCTAssertEqual(term.minX, pane.minX, accuracy: 1 / backing, "full width, left (\(tag))")
                XCTAssertEqual(term.width, pane.width, accuracy: 1 / backing, "full width (\(tag))")
                XCTAssertGreaterThanOrEqual(term.minY, header.maxY - 1 / backing, "the terminal sits under the header (\(tag))")
                XCTAssertLessThanOrEqual(term.minY, header.maxY + 2.5, "the header and its line only above it, no band between (\(tag))")
            }
        }
    }
    // The header's height across the Transcript/Terminal toggle: testAgentWindowToggleMovesNeitherHeaderNorSidebar
    // (AgentWindowTerminalModeTests) already measures it; not repeated here.
}
