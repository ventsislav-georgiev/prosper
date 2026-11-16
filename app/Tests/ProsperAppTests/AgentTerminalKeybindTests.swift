import AppKit
import XCTest
@testable import ProsperApp

/// #1376: Ghostty's macOS text keybinds in the Agent Sessions terminal, as in standalone Ghostty: Cmd-Backspace sends ^U
/// (line kill), Cmd-Left/Right ^A/^E, Option-Left/Right ESC b / ESC f. Real libghostty on AgentTerminalTests' offscreen
/// rig: the window is never shown or made key, keys are built with NSEvent.keyEvent and handed to the window's own
/// performKeyEquivalent/sendEvent (never posted), the pty is a recorder (no shell, no dch).
final class AgentTerminalKeybindTests: XCTestCase {

    /// The chord, the key event that types it and the bytes Ghostty sends for it.
    static let table: [(bind: String, code: UInt16, chars: String, flags: NSEvent.ModifierFlags, bytes: String)] = [
        ("super+backspace=text:\\x15", 51, "\u{7F}", [.command], "\u{15}"),
        ("super+arrow_left=text:\\x01", 123, "\u{F702}", [.command, .numericPad, .function], "\u{01}"),
        ("super+arrow_right=text:\\x05", 124, "\u{F703}", [.command, .numericPad, .function], "\u{05}"),
        ("alt+arrow_left=esc:b", 123, "\u{F702}", [.option, .numericPad, .function], "\u{1B}b"),
        ("alt+arrow_right=esc:f", 124, "\u{F703}", [.option, .numericPad, .function], "\u{1B}f"),
    ]

    @MainActor
    func spin(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    /// AgentTerminalTests' offscreen view rig, attached, its (recorder) client started.
    @MainActor
    func startedView() -> AgentTerminalTests.ViewRig {
        let v = AgentTerminalTests.ViewRig()
        v.start()
        let end = Date().addingTimeInterval(10)
        while v.rig.child == nil, Date() < end { spin(0.01) }
        XCTAssertTrue(v.rig.child != nil, "the surface reports its grid and the client starts")
        return v
    }

    /// Bytes the program got since the last take: waits up to 10 s for the first, then 0.1 s for any more.
    @MainActor
    func take(_ v: AgentTerminalTests.ViewRig, waitForAny: Bool = true) -> [UInt8] {
        let end = Date().addingTimeInterval(10)
        while waitForAny, Date() < end {
            v.rig.c.writer.flush()
            if v.rig.child?.written.isEmpty == false { break }
            spin(0.01)
        }
        spin(0.1)
        v.rig.c.writer.flush()
        let out = v.rig.child?.written ?? []
        v.rig.child?.clear()
        return out
    }

    @MainActor
    func testCmdBackspaceSendsTheLineKillOnce() {
        let v = startedView()
        defer { v.tearDown() }
        _ = take(v, waitForAny: false)
        v.press(51, "\u{7F}", .command)
        XCTAssertEqual(take(v), [0x15], "^U once, as Ghostty's cmd+backspace")
    }

    @MainActor
    func testGhosttyTextKeybindsSendTheirBytes() {
        XCTAssertEqual(Set(Self.table.map(\.bind)), Set(AgentTerminalLook.textKeybinds), "exactly these chords are bound")
        XCTAssertEqual(AgentTerminalLook.textKeybinds.count, Self.table.count)
        let v = startedView()
        defer { v.tearDown() }
        _ = take(v, waitForAny: false)
        for row in Self.table {
            v.press(row.code, row.chars, row.flags)
            XCTAssertEqual(String(decoding: take(v), as: UTF8.self), row.bytes, row.bind)
        }
    }

    @MainActor
    func testATextFieldWithTheKeysSendsTheTerminalNothing() {
        let v = startedView()
        defer { v.tearDown() }
        _ = take(v, waitForAny: false)
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 22))
        v.host.addSubview(field)
        XCTAssertTrue(v.window.makeFirstResponder(field))
        XCTAssertFalse(v.window.firstResponder === v.host, "premise: the field has the keys")
        for row in Self.table { v.press(row.code, row.chars, row.flags) }
        XCTAssertEqual(take(v, waitForAny: false), [], "no bytes reach the program")
        XCTAssertFalse(v.window.isVisible, "never shown")
        XCTAssertFalse(v.window.isKeyWindow)
    }
}

extension AgentWindowSidebarMenuTests {

    /// #1376 with #1289: a live terminal in the window, the sidebar focused: Cmd-Backspace still asks Stop, and the
    /// terminal's program gets no byte.
    @MainActor
    func testShortcutCmdBackspaceFromTheSidebarAsksAndSendsTheTerminalNothing() {
        let st = store([session("api")], dch: bin([1, 30, 0])), rec = Launches(), m = model(st, controller(st, rec))
        defer { m.close() }
        var stops = 0
        m.stopSession = { _ in stops += 1; return true }
        let win = shortcutWindow(m)
        defer { win.close() }
        let v = AgentTerminalTests.ViewRig()
        defer { v.tearDown() }
        v.rig.c.attach(AgentTerminalTests.key)
        v.host.show(v.rig.c.screen as? AgentGhosttyScreen)
        win.contentView?.addSubview(v.host)
        settle { v.rig.child != nil }
        XCTAssertTrue(v.rig.child != nil, "premise: the terminal's client started")
        m.setVisible(true)   // the rows are built while the window shows
        settle { !m.sections.isEmpty }
        m.select(.live(AgentSessionKey(dir: Self.dir, name: "api")))
        m.keyFocus = .sidebar
        XCTAssertEqual(win.responderKind, .other, "premise: nothing that types has the keys")
        v.rig.c.writer.flush()
        v.rig.child?.clear()
        XCTAssertTrue(win.performKeyEquivalent(with: cmdBackspace(win)))
        XCTAssertEqual(m.confirming?.verb, .stop, "the #1289 ask")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        v.rig.c.writer.flush()
        XCTAssertEqual(v.rig.child?.written ?? [], [], "no bytes to the terminal")
        XCTAssertEqual(stops, 0, "asked, not stopped")
        XCTAssertTrue(rec.args.isEmpty, "no dch")
    }
}
