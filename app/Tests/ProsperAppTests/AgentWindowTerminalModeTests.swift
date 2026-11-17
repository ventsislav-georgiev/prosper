import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #822 P1: Transcript | Terminal in the Agent Sessions window. Terminal is the default for a live session,
/// Transcript remembered per session name, rows with nothing to attach shown as Transcript,
/// the terminal attached only to a visible, selected, live session in Terminal mode, the window's
/// key routing, and offscreen renders showing a toggle moves neither the header nor the sidebar.
/// No dch runs: the terminal's spawn is a recorder. Windows are never shown, keys are built events.
extension AgentWindowD1Tests {

    static let modePref = "agentWindowTranscriptSessions"

    func mapped(_ name: String, _ state: AgentState = .idle, ago: TimeInterval = 60) -> AgentSession {
        session(name, state, ago: ago, path: "/Users/example/.claude/projects/p/0b7c2f3e-1111-2222-3333-444455556666.jsonl")
    }

    /// QA #690 INFO-1: one main-queue turn, the app's next one. Every block queued on main before this call runs
    /// (the queue is FIFO), so a screen's grid report sent through `events.resize` has landed after it.
    static func drainMain() {
        let turn = XCTestExpectation(description: "main queue turn")
        DispatchQueue.main.async { turn.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [turn], timeout: 2), .completed, "a main-queue turn")
    }

    /// The window model's terminal on recorders; the grid known, as if its view had laid out.
    /// The readers first give the app one main turn, so a read sees what the app's next turn would.
    @MainActor
    func fakeTerminal(_ m: AgentWindowModel) -> (spawned: () -> [AgentTerminalSpawn], children: () -> [AgentTerminalTests.FakeChild]) {
        final class Log { var spawns: [AgentTerminalSpawn] = []; var children: [AgentTerminalTests.FakeChild] = [] }
        let log = Log()
        m.terminal.request = { AgentTerminalSpawn.local($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
        m.terminal.spawn = { req, _ in
            log.spawns.append(req)
            let c = AgentTerminalTests.FakeChild()
            log.children.append(c)
            return c
        }
        m.terminal.makeScreen = { [weak t = m.terminal] events in
            // The screen runs at the view's grid and reports it through the controller's own resize event, as libghostty
            // does from its IO thread: the report lands on a later main turn, after begin() set the screen and the phase.
            if let g = t?.grid { events.resize(g.cols, g.rows) }
            return AgentTerminalTests.FakeScreen(events)
        }
        m.terminal.after = { _, _ in }
        m.terminal.clientVersion = { _ in [1, 40, 0] }
        m.terminal.gridChanged(cols: 80, rows: 24)
        return ({ Self.drainMain(); return log.spawns }, { Self.drainMain(); return log.children })
    }

    @MainActor
    func withModePref(_ body: () throws -> Void) rethrows {
        let saved = Preferences.defaults.object(forKey: Self.modePref)
        defer { Preferences.defaults.set(saved, forKey: Self.modePref) }
        Preferences.defaults.removeObject(forKey: Self.modePref)
        try body()
    }

    // MARK: Terminal by default, Transcript remembered by session name

    /// History, an ended session's held row, a session gone, nothing selected: Transcript, nothing remembered,
    /// no client, and the toggle off (⌘T passes).
    @MainActor
    func testAgentWindowTerminalModeNeverShowsWhereNothingCanAttach() throws {
        splitsOff()   // #1477: this row pins the gate-off (one pane) behaviour
        try withModePref {
            let a = mapped("a"), b = mapped("b")
            let st = store([a, b], history: [record("h")])
            st.controlDch = bin([1, 38, 0])
            let m = windowModel(st)
            let t = fakeTerminal(m)
            Calls().wire(m)
            m.setVisible(true)
            defer { m.close() }
            XCTAssertEqual(t.spawned().count, 1, "shown: the first row is selected, in Terminal")
            m.select(nil)
            XCTAssertEqual(t.children().map(\.terminated), [1], "nothing selected: detached")
            XCTAssertEqual(m.paneMode, .transcript, "nothing selected")
            m.select(.history(AgentSessionKey(dir: "/tmp/dch-test", name: "h")))
            XCTAssertEqual(m.paneMode, .transcript, "a History row")
            XCTAssertEqual(t.spawned().count, 1, "a History row: nothing attached")
            m.select(.live(a.key))
            XCTAssertEqual(m.paneMode, .terminal)
            XCTAssertEqual(t.spawned().count, 2)
            // Stopped from the window: the row goes before its record, the pane is Ended (#831 B1, rewrite 10).
            m.ask(.stop, a)
            m.confirm(true)
            st.sessions = [b]
            XCTAssertTrue(m.focusedEnded)
            XCTAssertNil(m.selection)
            XCTAssertEqual(m.paneMode, .transcript, "ended: Transcript, no terminal card")
            XCTAssertEqual(t.children().last?.terminated, 1, "Ended: the client goes")
            XCTAssertEqual(m.paneMode, .transcript)
            XCTAssertEqual(t.spawned().count, 2, "and nothing attaches to an ended session")
            XCTAssertNil(m.interaction.session, "nor takes input")
            // The held row's reason (the notice's "..." help reads it; offscreen render for review).
            XCTAssertEqual(AgentPaneModeToggle.endedReason, "This session ended: there is no terminal to attach to")
            try save(render(AgentWindowRootView(model: m, scrolls: false), size: CGSize(width: 1000, height: 680), dark: true),
                     "822-ended-1.0")
            XCTAssertFalse(m.terminal.isSelected(a.key), "OQ-66: a held (ended) row is no selection a write can use")
            // Any session that ends in the pane: Ended (no highlight), Transcript, nothing attached.
            m.select(.live(b.key))
            st.sessions = []
            XCTAssertNil(m.selection)
            XCTAssertTrue(m.focusedEnded)
            XCTAssertEqual(m.paneMode, .transcript, "nothing to attach (#1471: the answer XrayRefLink reads)")
        }
    }

    // MARK: Attach conditions

    @MainActor
    func testAgentWindowTerminalAttachesOnlyToAVisibleSelectedLiveSessionInTerminalMode() throws {
        splitsOff()   // #1477: this row pins the gate-off (one pane) behaviour
        try withModePref {
            let one = mapped("one"), two = mapped("two")
            let st = store([one, two], history: [record("h")])
            let m = windowModel(st)
            let t = fakeTerminal(m)
            func terminated() -> [Int] { t.children().map(\.terminated) }
            m.setVisible(true)
            m.select(.live(one.key))
            XCTAssertEqual(t.spawned().map(\.args), [["-E", "-a", "one", "--scrollback", "2000"]], "a live session attaches")
            XCTAssertTrue(m.terminal.isSelected(one.key), "OQ-66: the selection is the session a write may come from")
            XCTAssertFalse(m.terminal.isSelected(two.key))
            XCTAssertEqual(m.terminal.phase, .live)
            XCTAssertNil(m.interaction.session, "no input box, no prompt reads")
            XCTAssertTrue(m.transcript.running, "the transcript keeps the header's cwd and todos")
            m.setVisible(false)
            XCTAssertEqual(terminated(), [1], "hidden: detached")
            XCTAssertEqual(m.terminal.phase, .idle)
            m.setVisible(true)
            XCTAssertEqual(t.spawned().count, 2, "shown again: attached again")
            m.select(.live(two.key))
            XCTAssertNil(m.interaction.session, "#1471: every live pane is a terminal: no input box")
            XCTAssertEqual(t.spawned().last?.args, ["-E", "-a", "two", "--scrollback", "2000"], "#1471: another live session attaches too")
            XCTAssertEqual(Array(terminated().prefix(2)), [1, 1], "one's client went")
            m.select(.history(AgentSessionKey(dir: "/tmp/dch-test", name: "h")))
            XCTAssertEqual(terminated().last, 1, "a History row: nothing attached")
            XCTAssertEqual(t.spawned().count, 3)
            m.select(.live(one.key))
            m.refresh()
            m.select(.live(one.key))
            XCTAssertEqual(t.spawned().count, 4, "a refresh or the same selection does not reattach")
            st.sessions = [two]
            XCTAssertNil(m.selection)
            XCTAssertTrue(m.focusedEnded, "#831 B1, rewrite 15: Ended, transcript suspended, nothing attached")
            XCTAssertFalse(m.transcript.running)
            XCTAssertEqual(terminated().last, 1, "the session ended: detached")
            m.select(.live(two.key))
            XCTAssertEqual(t.spawned().last?.args, ["-E", "-a", "two", "--scrollback", "2000"])
            Self.drainMain()   // the app's turn before the close: the screen's report lands, the 5th client starts
            m.close()
            XCTAssertEqual(terminated().last, 1, "closed: detached")
            XCTAssertEqual(m.terminal.phase, .idle)
            XCTAssertEqual(t.spawned().count, 5)
            XCTAssertNil(Preferences.defaults.stringArray(forKey: Self.modePref), "#1471: no mode is ever written")
            // The held row (an ended session): testAgentWindowTerminalModeNeverShowsWhereNothingCanAttach.
        }
    }

    // MARK: Keys (spec 5.3, QA #669)

    @MainActor
    func testAgentWindowKeyRoutesForEveryResponder() {
        let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        func key(_ code: UInt16, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: win.windowNumber,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        typealias R = AgentsNSWindow.KeyRoute
        func route(_ e: NSEvent, _ r: AgentsNSWindow.ResponderKind, sidebar: Bool = false, terminal: Bool = true) -> R {
            AgentsNSWindow.route(e, responder: r, sidebarFocused: sidebar, terminalMode: terminal)
        }
        let all: [AgentsNSWindow.ResponderKind] = [.text, .terminal, .other]
        let up = key(126, "\u{F700}", [.command, .numericPad, .function])
        let down = key(125, "\u{F701}", [.command, .numericPad, .function])
        for r in all {
            XCTAssertEqual(route(key(13, "w", .command), r), .close)
            XCTAssertEqual(route(key(17, "t", .command), r), .pass, "#1471: Command-T is no window key (\(r))")
            XCTAssertEqual(route(key(17, "t", .command), r, terminal: false), .pass)
            XCTAssertEqual(route(key(3, "f", .command), r), .find)
            XCTAssertEqual(route(key(3, "f", .command), r, terminal: false), .pass, "no find bar over the transcript")
            XCTAssertEqual(route(key(5, "g", .command), r), .findNext(true))
            XCTAssertEqual(route(key(5, "g", [.command, .shift]), r), .findNext(false))
            XCTAssertEqual(route(key(18, "1", [.command, .option]), r), .jump(10), "#1470: Option-Command-1 is row 10 (\(r))")
            XCTAssertEqual(route(key(18, "1", [.command, .option]), r, terminal: false), .jump(10))
        }
        // QA #669: ⌘↑/⌘↓ move between sessions, except in a text view (start / end of the text there).
        XCTAssertEqual(route(up, .text), .pass)
        XCTAssertEqual(route(down, .text, terminal: false), .pass)
        XCTAssertEqual(route(up, .terminal), .session(-1))
        XCTAssertEqual(route(down, .terminal), .session(1))
        XCTAssertEqual(route(up, .other, terminal: false), .session(-1))
        XCTAssertEqual(route(down, .other, sidebar: true), .session(1))
        XCTAssertEqual(route(key(126, "\u{F700}", [.command, .shift]), .other), .pass, "⇧⌘↑ is not the window's")
        // The program's keys: Esc, Tab, ⇧Tab, ⌃C, arrows, Return, ⇧Return, function keys.
        for e in [key(53, "\u{1b}"), key(48, "\t"), key(48, "\t", .shift), key(8, "c", .control), key(126, "\u{F700}"),
                  key(36, "\r"), key(36, "\r", .shift), key(122, "\u{F704}", .function), key(0, "a"), key(14, "é", .option)] {
            XCTAssertEqual(route(e, .terminal, sidebar: true), .pass, "key \(e.keyCode) goes to the terminal")
            XCTAssertEqual(route(e, .text, sidebar: true), .pass)
        }
        // The sidebar's plain keys: only while it has the focus and nothing that types does.
        for code: UInt16 in [126, 125, 123, 124, 36, 76] {
            XCTAssertEqual(route(key(code), .other, sidebar: true), .sidebar)
            XCTAssertEqual(route(key(code), .other, sidebar: false), .pass)
            XCTAssertEqual(route(key(code), .terminal, sidebar: true), .pass, "the terminal keeps its arrows and Return")
            XCTAssertEqual(route(key(code), .text, sidebar: true), .pass)
        }
        let keyUp = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17)!
        XCTAssertEqual(route(keyUp, .other), .pass)
    }

    @MainActor
    func testAgentWindowCommandArrowsSkipATextViewAndTheTerminalKeepsItsKeys() throws {
        try withModePref {
            var opened: [String] = []
            let m = windowModel(store([mapped("a", ago: 1), mapped("b", ago: 2), mapped("c", ago: 3)]), opened: { opened.append($0.name) })
            _ = fakeTerminal(m)
            m.setVisible(true)
            defer { m.close() }
            let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                     backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            win.model = m
            func key(_ code: UInt16, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: win.windowNumber,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            }
            let cmdDown = key(125, "\u{F701}", [.command, .numericPad, .function])
            let cmdUp = key(126, "\u{F700}", [.command, .numericPad, .function])
            m.select(live("a"))
            // A text view (the composer, a field) first: ⌘↓ is its own (end of text).
            let tv = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 20))
            tv.string = "draft"
            win.contentView?.addSubview(tv)
            XCTAssertTrue(win.makeFirstResponder(tv))
            XCTAssertFalse(win.performKeyEquivalent(with: cmdDown))
            XCTAssertEqual(m.selection, live("a"), "⌘↓ stayed in the text view")
            // Nothing that types: previous / next session.
            XCTAssertTrue(win.makeFirstResponder(nil))
            XCTAssertTrue(win.performKeyEquivalent(with: cmdDown))
            XCTAssertEqual(m.selection, live("b"))
            XCTAssertTrue(win.performKeyEquivalent(with: cmdUp))
            XCTAssertEqual(m.selection, live("a"))
            // #1471: Command-T is no window key (no Transcript mode); focusing the pane sends the keys to the terminal once its
            // view is in the window.
            XCTAssertEqual(m.paneMode, .terminal, "the only mode")
            XCTAssertFalse(win.performKeyEquivalent(with: key(17, "t", .command)), "#1471: Command-T is not the window's")
            XCTAssertEqual(m.paneMode, .terminal)
            XCTAssertTrue(m.focusSelection())
            XCTAssertTrue(m.terminal.focusPending)
            // The app's turn before SwiftUI builds the view: the screen's report lands and the client goes live (#845: only
            // a live client takes the keys), the focus still pending on the view.
            Self.drainMain()
            let host = AgentTerminalHostView(frame: .init(x: 0, y: 0, width: 200, height: 100))
            host.owner = m.terminal
            m.terminal.view = host
            win.contentView?.addSubview(host)
            XCTAssertTrue(win.firstResponder === host, "the pending focus landed when the view joined the window")
            XCTAssertFalse(m.terminal.focusPending)
            XCTAssertEqual(win.responderKind, .terminal)
            // The terminal keeps plain arrows and Tab even with the sidebar focused; ⌘↓ is still the window's.
            win.sidebarFocused = true
            win.sendEvent(key(125, "\u{F701}", [.numericPad, .function]))
            XCTAssertEqual(m.selection, live("a"), "↓ went to the terminal, not the sidebar")
            win.sendEvent(key(48, "\t"))
            XCTAssertTrue(win.sidebarFocused, "Tab is the program's (mode cycle): the focus did not move on")
            XCTAssertTrue(win.performKeyEquivalent(with: cmdDown))
            XCTAssertEqual(m.selection, live("b"), "⌘↓ from the terminal")
            XCTAssertEqual(m.paneMode, .terminal, "#1471: b is a terminal too")
            XCTAssertTrue(win.performKeyEquivalent(with: cmdUp))
            XCTAssertEqual(m.paneMode, .terminal)
            Self.drainMain()   // the app's turn before the next key: a's fresh client is live
            // Option-Command-1 in Terminal mode (#1470: row 10, none here): taken, the level unchanged.
            let level = m.verbosity
            XCTAssertTrue(win.performKeyEquivalent(with: key(18, "1", [.command, .option])))
            XCTAssertEqual(m.verbosity, level)
            // Return on the sidebar row in Terminal mode: into the terminal, Ghostty not opened.
            XCTAssertTrue(win.makeFirstResponder(nil))
            win.sidebarFocused = true
            win.sendEvent(key(36, "\r"))
            XCTAssertEqual(opened, [], "Terminal mode: Return does not open Ghostty")
            XCTAssertTrue(win.firstResponder === host)
            // A click beside the sidebar leaves the keys with the terminal; a sidebar click takes them back,
            // so the arrows select again. (y 250: above the host view, so neither click lands on it.)
            func click(_ x: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: 250), modifierFlags: [], timestamp: 0,
                                   windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            win.sendEvent(click(sz(350)))
            XCTAssertFalse(win.sidebarFocused)
            XCTAssertTrue(win.firstResponder === host, "a click outside the sidebar keeps the terminal's keys")
            win.sendEvent(click(sz(100)))
            XCTAssertTrue(win.sidebarFocused)
            XCTAssertFalse(win.firstResponder === host, "a sidebar click resigns the terminal")
            win.sendEvent(key(125, "\u{F701}", [.numericPad, .function]))
            XCTAssertEqual(m.selection, live("b"), "the sidebar's down again")
            win.sendEvent(key(126, "\u{F700}", [.numericPad, .function]))
            XCTAssertEqual(m.selection, live("a"))
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    // MARK: Offscreen: a toggle moves nothing (spec 5.5)

    /// The first row under the header's top where the colour steps (the header's bottom edge).
    /// #860: the header sits on the window's backdrop gradient, so each row is compared with the
    /// row above it, not with the top row: a gradient drifts past 0.03 without any edge. Its dither
    /// steps up to ~0.031 row to row; the header's edge steps 0.19 or more (dark and light), so 0.1.
    func headerBottom(_ rep: NSBitmapImageRep, x: Int) -> Int? {
        guard var above = rep.colorAt(x: x, y: 4)?.usingColorSpace(.sRGB) else { return nil }
        for y in 5..<rep.pixelsHigh {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if abs(c.redComponent - above.redComponent) + abs(c.greenComponent - above.greenComponent)
                + abs(c.blueComponent - above.blueComponent) > 0.1 { return y }
            above = c
        }
        return nil
    }

    /// Pixels in the box that differ between `a` and `b` (`b` read `dx` pixels to the right).
    /// Reps of one layout compare raw bytes first, a row at a time: equal bytes are the same colour,
    /// so only a pixel whose bytes differ goes through colorAt and same() (#829 P3 r3: the per-pixel
    /// NSColors made the rename render test take 292 s).
    /// `tolerance`: see same(); the "⋯" ±1 px compares pass 0.06 (#860: shifted 1 px, the backdrop
    /// gradient's dither differs by up to ~0.035 where the glyph does not).
    func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, x: Range<Int>, y: Range<Int>, dx: Int = 0,
                   tolerance: CGFloat = 0.03) -> Int {
        let raw = RawPixels.pair(a, b)
        // The boxes colorAt answers for: in both reps, `b` shifted by dx.
        let lo = max(x.lowerBound, 0, -dx), hi = min(x.upperBound, a.pixelsWide, b.pixelsWide, b.pixelsWide - dx)
        guard lo < hi else { return 0 }
        var n = 0
        for yy in max(y.lowerBound, 0)..<max(y.lowerBound, 0, min(y.upperBound, a.pixelsHigh, b.pixelsHigh)) {
            if let r = raw, r.0.equal(lo, yy, r.1, lo + dx, yy, count: hi - lo) { continue }
            // colorAt and usingColorSpace autorelease 4 NSColors a pixel: drained per row, or a
            // whole-window compare loop holds them all (#829 P3 grew one xctest to 34 GB).
            autoreleasepool {
                for xx in lo..<hi {
                    if let r = raw, r.0.equal(xx, yy, r.1, xx + dx, yy) { continue }
                    if let c = a.colorAt(x: xx, y: yy), let d = b.colorAt(x: xx + dx, y: yy), !same(c, d, tolerance: tolerance) { n += 1 }
                }
            }
        }
        return n
    }

    /// Pixels in the box unlike its top-left one (the same raw bytes as it: alike, no colorAt).
    func unlike(_ rep: NSBitmapImageRep, x: Range<Int>, y: Range<Int>) -> Int {
        guard let ref = rep.colorAt(x: x.lowerBound, y: y.lowerBound) else { return -1 }
        let raw = RawPixels(rep)
        var n = 0
        for yy in y where yy < rep.pixelsHigh {
            autoreleasepool {
                for xx in x where xx < rep.pixelsWide {
                    if let raw, xx >= 0, yy >= 0, raw.equal(xx, yy, raw, x.lowerBound, y.lowerBound) { continue }
                    if let p = rep.colorAt(x: xx, y: yy), !same(p, ref) { n += 1 }
                }
            }
        }
        return n
    }

    func same(_ p: NSColor, _ q: NSColor, tolerance: CGFloat = 0.03) -> Bool {
        guard let p = p.usingColorSpace(.sRGB), let q = q.usingColorSpace(.sRGB) else { return false }
        return abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent)
            + abs(p.blueComponent - q.blueComponent) <= tolerance
    }
}

/// #829 P3 r3: a rep's pixel bytes. Within one rep, or two of one layout, equal bytes are the same
/// colour, so a compare skips colorAt for them; any other pixel still goes through colorAt and same().
/// nil for a planar or not 8-bit rep (colorAt only).
struct RawPixels {
    let base: UnsafeMutablePointer<UInt8>, row: Int, size: Int

    init?(_ rep: NSBitmapImageRep) {
        guard !rep.isPlanar, rep.bitsPerSample == 8, rep.bitsPerPixel % 8 == 0, let d = rep.bitmapData else { return nil }
        base = d; row = rep.bytesPerRow; size = rep.bitsPerPixel / 8
    }

    /// Both, when `a` and `b` lay their bytes out alike (format, depth, colour space); else nil.
    static func pair(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (RawPixels, RawPixels)? {
        guard a.bitmapFormat == b.bitmapFormat, a.bitsPerPixel == b.bitsPerPixel, a.samplesPerPixel == b.samplesPerPixel,
              a.colorSpace == b.colorSpace, let p = RawPixels(a), let q = RawPixels(b) else { return nil }
        return (p, q)
    }

    /// `count` pixels from (x, y) here equal, byte for byte, those from (ox, oy) in `o`.
    func equal(_ x: Int, _ y: Int, _ o: RawPixels, _ ox: Int, _ oy: Int, count: Int = 1) -> Bool {
        memcmp(base + y * row + x * size, o.base + oy * o.row + ox * o.size, count * size) == 0
    }
}

extension XCTestCase {
    /// #822: a live session opens in Terminal. A test of Transcript behavior (the input box, the prompt
    /// panel, Return moving the keys into the input box) shows its sessions as Transcript, the store's by default;
    /// the per-Mac pref is put back at teardown so no later test inherits the choice.
    @MainActor
    func showTranscript(_ m: AgentWindowModel, _ sessions: [AgentSession]? = nil) {
        let key = "agentWindowTranscriptSessions"
        let saved = Preferences.defaults.stringArray(forKey: key)
        addTeardownBlock { Preferences.defaults.set(saved, forKey: key) }
        _ = sessions   // #1471: no Transcript mode to show: every pane is a terminal (part b drops the callers' halves)
    }
}

/// #1337 (QA #690 INFO-1): fakeTerminal's screen reports its grid the way libghostty does, through the controller's own
/// resize event (AgentTerminalController.begin(): DispatchQueue.main.async -> gridChanged), not inside makeScreen.
final class AgentWindowFake1337Tests: XCTestCase {
    @MainActor
    func testTheFakeScreensGridReportLandsAfterBeginSetTheScreenAndPhase() throws {
        let d = AgentWindowD1Tests()
        try d.withModePref {
            let one = d.mapped("one")
            let m = d.windowModel(d.store([one]))
            let t = d.fakeTerminal(m)
            defer { m.close() }
            m.setVisible(true)
            m.select(.live(one.key))
            XCTAssertEqual(m.terminal.key, one.key)
            XCTAssertEqual(m.terminal.phase, .attaching, "begin() set the phase; the screen's report has not landed")
            XCTAssertNotNil(m.terminal.screen, "begin() set the screen")
            XCTAssertTrue(m.terminal.screenGrid == nil, "no report inside makeScreen")
            AgentWindowD1Tests.drainMain()
            XCTAssertEqual(m.terminal.screenGrid?.cols, 80, "the report, on the next main turn")
            XCTAssertEqual(m.terminal.screenGrid?.rows, 24)
            XCTAssertEqual(m.terminal.phase, .live, "the report matched the view's grid: the client started")
            XCTAssertEqual(t.spawned().map(\.args), [["-E", "-a", "one", "--scrollback", "2000"]], "one client")
        }
    }
}
