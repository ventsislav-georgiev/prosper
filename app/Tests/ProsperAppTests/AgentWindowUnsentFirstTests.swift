import XCTest
@testable import ProsperApp

/// #847 D2.3, #1471 b (R1471a-m1): the unsent first message's notice over the terminal. Pure rows: the shown line and
/// the bytes Send writes. No window, no pasteboard, no terminal, no dch. The model and window rows are below (D1).
final class AgentWindowUnsentFirstTests: XCTestCase {

    /// A 3-line prompt with a ZWJ family emoji across character 79-80: one line, cut on a whole Character, the emoji's
    /// parts all in or all out (OutsideText drops the joiners it cannot draw, never a part of the cut).
    func testShownIsOneLineCutWholeAtEighty() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let raw = "first line\nsecond line\r\n" + String(repeating: "x", count: 54) + family + "\nthird line tail"
        let shown = AgentUnsentFirstLine.shown(raw)
        XCTAssertFalse(shown.contains("\n") || shown.contains("\r"), "one line")
        XCTAssertTrue(shown.hasPrefix("first line second line "), "newlines folded to spaces")
        XCTAssertTrue(shown.hasSuffix("\u{2026}"), "cut")
        let long = String(repeating: "y", count: 200)
        XCTAssertEqual(AgentUnsentFirstLine.shown(long), String(repeating: "y", count: 79) + "\u{2026}", "80 Characters")
        let parts: [Unicode.Scalar] = ["\u{1F468}", "\u{1F469}", "\u{1F467}"]
        let inside = parts.filter { p in shown.unicodeScalars.contains(p) }.count
        XCTAssertTrue(inside == 0 || inside == parts.count, "the emoji whole or not at all: \(inside) of 3")
        XCTAssertEqual(AgentUnsentFirstLine.shown("short"), "short", "under the cap: unchanged")
    }

    /// Send's bytes: exactly one bracketed paste of the sanitized text, nothing after it (no CR, no LF appended);
    /// an ESC in the text cannot end the paste early.
    func testSendIsOneBracketedPasteWithNoReturn() {
        let bytes = AgentWindowModel.bracketedPaste("fix the build\nthen ship\u{1B}[201~x")
        let s = String(decoding: bytes, as: UTF8.self)
        XCTAssertEqual(s, "\u{1B}[200~fix the build\nthen ship[201~x\u{1B}[201~")
        XCTAssertEqual(s.components(separatedBy: "\u{1B}[200~").count - 1, 1, "one paste start")
        XCTAssertEqual(s.components(separatedBy: "\u{1B}[201~").count - 1, 1, "one paste end")
        XCTAssertTrue(s.hasSuffix("\u{1B}[201~"), "nothing after the paste: no Return")
    }
}

/// #1471 b (R3, R1471a-m1/s1): the notice on a window model. The island's io is dch-lite (an empty read with no mirror), so
/// its sayFirst fails at once and no dch runs; the terminal is fakeTerminal's (a recorder child); Copy and Send take
/// recorders (never the pasteboard, never the pty); the AX read hosts the root view in a never-shown window.
extension AgentWindowD1Tests {
    static let unsentRaw = "fix the build\nthen run the suite\nand ship it"

    /// api selected, live and focused in a visible model; its first message failed while it was selected.
    @MainActor
    func withUnsentFirst(terminalSetup: (AgentWindowModel, AgentSession) -> Void = { _, _ in },
                         _ body: (AgentWindowModel, AgentIslandStore, AgentIslandController, AgentSession,
                                  () -> [UInt8]) throws -> Void) rethrows {
        try withNewSessionPrefs {
            let a = session("api", .idle), st = store([a])
            let spawns = SpawnCalls(), m = newSessionModel(st, spawns)
            defer { m.close() }
            let t = fakeTerminal(m)
            let island = m.island()
            m.interaction.controller = island
            m.setVisible(true)
            m.select(.live(a.key))
            terminalSetup(m, a)
            let done = expectation(description: "the first message fails")
            var why: String?
            m.sayFirst(a.key, Self.unsentRaw, false) { why = $0; done.fulfill() }
            wait(for: [done], timeout: 10)
            XCTAssertTrue(why != nil, "#1877: the model's sayFirst passes the controller's reason on")
            try body(m, st, island, a, { m.terminal.writer.flush(); return t.children().flatMap(\.written) })
            XCTAssertTrue(spawns.calls.isEmpty, "no session started")
        }
    }

    /// It shows: the model's notice is api's whole text, the island keeps the record, the window reads the notice and
    /// its three buttons by their labels, and nothing was typed into the terminal.
    @MainActor
    func testUnsentFirstShowsOverTheTerminalAndTypesNothing() throws {
        let restoreAX = bandAXOn()
        defer { restoreAX() }
        try withUnsentFirst { m, _, island, a, written in
            XCTAssertEqual(m.unsentFirst, AgentWindowModel.UnsentFirst(key: a.key, text: Self.unsentRaw))
            XCTAssertEqual(island.unsentFirst[a.key], Self.unsentRaw, "the record is kept until Send or Dismiss")
            XCTAssertTrue(m.paneHasTerminal)
            let names = [AgentUnsentFirstLine.title, "Copy first message", "Send first message to the terminal", "Dismiss"]
            let tree = bandTree(AgentWindowRootView(model: m, scrolls: false), CGSize(width: 1000, height: 680), until: names).tree
            for n in names { XCTAssertEqual(bandCount(tree, n), 1, "\"\(n)\" is read once") }
            let typed = String(decoding: written(), as: UTF8.self)
            XCTAssertFalse(typed.contains("fix the build") || typed.contains("\u{1B}[200~"), "nothing typed before Send: \(typed.debugDescription)")
        }
    }

    /// Copy hands the WHOLE raw text (three lines, newlines kept, not the cut line) to the recorder; the notice stays.
    @MainActor
    func testUnsentFirstCopyHandsTheWholeRawText() throws {
        try withUnsentFirst { m, _, island, a, _ in
            var got: [String] = []
            m.copyUnsentFirst { got.append($0) }
            XCTAssertEqual(got, [Self.unsentRaw])
            XCTAssertEqual(got.first?.components(separatedBy: "\n").count, 3)
            XCTAssertEqual(m.unsentFirst?.text, Self.unsentRaw, "Copy keeps the notice")
            XCTAssertEqual(island.unsentFirst[a.key], Self.unsentRaw)
        }
    }

    /// Send: exactly one write, one bracketed paste of the text with nothing after it (no Return); then the notice and the
    /// record are gone, and a second Send writes nothing.
    @MainActor
    func testUnsentFirstSendWritesOnePasteThenClears() throws {
        try withUnsentFirst { m, _, island, a, written in
            let before = written()
            var writes: [[UInt8]] = []
            m.sendUnsentFirst { writes.append($0) }
            XCTAssertEqual(writes.count, 1, "one write")
            XCTAssertEqual(writes.first, AgentWindowModel.bracketedPaste(Self.unsentRaw))
            let s = String(decoding: writes.first ?? [], as: UTF8.self)
            XCTAssertTrue(s.hasPrefix("\u{1B}[200~") && s.hasSuffix("\u{1B}[201~"), "one paste, nothing after it: \(s.debugDescription)")
            XCTAssertTrue(m.unsentFirst == nil, "the notice goes")
            XCTAssertTrue(island.unsentFirst[a.key] == nil, "the record goes")
            m.sendUnsentFirst { writes.append($0) }
            XCTAssertEqual(writes.count, 1, "no notice: nothing more")
            XCTAssertEqual(written(), before, "the recorder took it: the pty saw nothing")
        }
    }

    /// R1471b-m1: Send on a terminal with no live client writes nothing and keeps the notice and the record (input() would
    /// drop the bytes silently and Send would then forget the text). .attaching: the screen never reports its grid.
    @MainActor
    func testUnsentFirstSendWhileAttachingKeepsBoth() throws {
        try withUnsentFirst(terminalSetup: { m, a in
            m.terminal.attach(nil)   // a fresh attach under the row's seams (the model's first row is already live)
            m.terminal.makeScreen = { AgentTerminalTests.FakeScreen($0) }
            m.terminal.attach(a.key)
        }) { m, _, island, a, _ in
            XCTAssertTrue(m.terminal.phase == .attaching, "control: attaching, got \(m.terminal.phase)")
            assertSendKeepsBoth(m, island, a)
        }
    }

    /// The same for a failed attach (the spawn throws).
    @MainActor
    func testUnsentFirstSendAfterAFailedAttachKeepsBoth() throws {
        struct Boom: Error {}
        try withUnsentFirst(terminalSetup: { m, a in
            m.terminal.attach(nil)
            m.terminal.spawn = { _, _ in throw Boom() }
            m.terminal.attach(a.key)
        }) { m, _, island, a, _ in
            if case .failed = m.terminal.phase {} else { XCTFail("control: failed, got \(m.terminal.phase)") }
            assertSendKeepsBoth(m, island, a)
        }
    }

    /// Live, but attached to another session: Send writes nothing and keeps both.
    @MainActor
    func testUnsentFirstSendWhileAttachedToAnotherSessionKeepsBoth() throws {
        try withUnsentFirst { m, st, island, a, written in
            let w = session("web", .idle)
            st.sessions = [a, w]
            m.terminal.attach(w.key)
            _ = written()
            XCTAssertTrue(m.terminal.phase == .live && m.terminal.key == w.key, "control: live on web, got \(m.terminal.phase)")
            assertSendKeepsBoth(m, island, a)
        }
    }

    /// Live and attached to the notice's session: the control (Send is on, and the write goes).
    @MainActor
    func testUnsentFirstCanSendWhenLiveAndAttached() throws {
        try withUnsentFirst { m, _, _, a, written in
            _ = written()
            XCTAssertTrue(m.terminal.phase == .live && m.terminal.key == a.key, "control: live on api")
            XCTAssertTrue(m.canSendUnsentFirst)
            XCTAssertEqual(AgentUnsentFirstLine.notConnected, "Not connected yet")
        }
    }

    @MainActor
    private func assertSendKeepsBoth(_ m: AgentWindowModel, _ island: AgentIslandController, _ a: AgentSession) {
        XCTAssertFalse(m.canSendUnsentFirst, "the view's Send is off")
        var writes: [[UInt8]] = []
        m.sendUnsentFirst { writes.append($0) }
        XCTAssertEqual(writes.count, 0, "0 bytes written")
        XCTAssertEqual(m.unsentFirst, AgentWindowModel.UnsentFirst(key: a.key, text: Self.unsentRaw), "the notice stays")
        XCTAssertEqual(island.unsentFirst[a.key], Self.unsentRaw, "the record stays")
    }

    /// Dismiss: the notice goes and the island forgets the message, so selecting the session again shows nothing.
    @MainActor
    func testUnsentFirstDismissClearsTheNoticeAndDropsTheRecord() throws {
        try withUnsentFirst { m, _, island, a, written in
            m.dismissUnsentFirst()
            XCTAssertTrue(m.unsentFirst == nil)
            XCTAssertTrue(island.unsentFirst[a.key] == nil, "the record is dropped")
            m.select(nil)
            m.select(.live(a.key))
            XCTAssertTrue(m.unsentFirst == nil, "nothing comes back on reselect")
            XCTAssertFalse(String(decoding: written(), as: UTF8.self).contains("fix the build"), "nothing typed")
        }
    }

    /// The session ends in the pane: the notice goes with it, and the record (nothing can send it now).
    @MainActor
    func testUnsentFirstGoesWhenTheSessionEnds() throws {
        try withUnsentFirst { m, st, island, a, _ in
            XCTAssertTrue(m.unsentFirst != nil, "control: shown")
            st.sessions = []
            XCTAssertTrue(m.focusedEnded)
            XCTAssertTrue(m.unsentFirst == nil, "the notice goes")
            XCTAssertTrue(island.unsentFirst[a.key] == nil, "the record goes")
        }
    }

    /// Only the session that ended loses its notice: api's notice is kept while web, focused in the pane, ends.
    @MainActor
    func testUnsentFirstOfAnotherSessionStaysWhenTheFocusedOneEnds() throws {
        try withUnsentFirst { m, st, island, a, _ in
            let w = session("web", .idle)
            st.sessions = [a, w]
            m.select(.live(w.key))
            XCTAssertEqual(m.unsentFirst?.key, a.key, "control: web has none, api's is kept")
            st.sessions = [a]
            XCTAssertTrue(m.focusedEnded, "control: web ended in the pane")
            XCTAssertEqual(m.unsentFirst, AgentWindowModel.UnsentFirst(key: a.key, text: Self.unsentRaw), "api's notice stays")
            XCTAssertEqual(island.unsentFirst[a.key], Self.unsentRaw, "api's record stays")
            m.select(.live(a.key))
            XCTAssertEqual(m.unsentFirst?.key, a.key, "api shows it again")
        }
    }

    /// R1 / R1471a-s1: Command-T and Command-L in a focused terminal pane are the window's and do nothing: handled
    /// (consumed, so AppKit hands no keyDown to the terminal), 0 bytes to the pty, the pane and selection unchanged.
    @MainActor
    func testCommandTAndCommandLWriteZeroBytesInATerminalPane() throws {
        let a = session("api", .idle)
        let m = windowModel(store([a]))
        let t = fakeTerminal(m)
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(a.key))
        let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        win.model = m
        XCTAssertTrue(m.paneHasTerminal)
        for (code, chars) in [(UInt16(17), "t"), (37, "l")] {
            XCTAssertTrue(win.performKeyEquivalent(with: chapterKey(code, chars, .command)), "Command-\(chars): the window's")
            m.terminal.writer.flush()
            XCTAssertEqual(t.children().flatMap(\.written), [], "Command-\(chars): 0 bytes")
            XCTAssertEqual(m.selection, .live(a.key))
            XCTAssertTrue(m.paneHasTerminal)
        }
        XCTAssertFalse(win.isVisible, "never shown")
    }
}
