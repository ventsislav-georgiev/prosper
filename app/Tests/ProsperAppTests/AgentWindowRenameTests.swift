import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #829 Phase 3 (G4): Rename from the window. The header title turns into a field in its own slot;
/// Return saves through the island's controller (dch -m), Esc and focus loss cancel; the window's
/// shortcuts stand down while it edits. Plus QA #672's carried notes on the ended pane.
/// Offscreen only: no dch (the model's rename seam records), no window shown or made key, no
/// menu popped, no event posted outside a never-shown window.
extension AgentWindowD1Tests {
    // MARK: The args builder and the failure line

    func testAgentRenameArgsTrimFlattenCapAndSkipTheUnchanged() {
        XCTAssertEqual(AgentIsland.renameArgs("a", "  New  ", current: ""), ["-m", "a", "New"])
        XCTAssertEqual(AgentIsland.renameArgs("a", "x\ty\nz\r\nw", current: ""), ["-m", "a", "x y z w"],
                       "tabs and newlines become spaces")
        XCTAssertEqual(AgentIsland.renameArgs("a", String(repeating: "x", count: 130), current: "")?.last?.count, 120,
                       "capped at 120 characters")
        XCTAssertEqual(AgentIsland.renameArgs("a", "b" + String(repeating: " ", count: 119) + "c", current: ""), ["-m", "a", "b"],
                       "the cut's trailing spaces go too")
        XCTAssertNil(AgentIsland.renameArgs("a", "  cur \n", current: "cur"), "unchanged: nothing runs")
        XCTAssertNil(AgentIsland.renameArgs("a", "   ", current: ""), "no alias, none typed: nothing runs")
        XCTAssertEqual(AgentIsland.renameArgs("a", "", current: "cur"), ["-m", "a", ""], "empty clears the alias")
        XCTAssertEqual(AgentIsland.renameArgs("-x", "y", current: ""), ["-m", "-x", "y"], "any name, its own argv element")
        XCTAssertEqual(AgentIsland.renameHelp("a"), "Display name only; the dch session name stays a")
        XCTAssertNil(AgentIsland.renameFailure(DchActionResult(status: 0), name: "a"))
        XCTAssertEqual(AgentIsland.renameFailure(DchActionResult(status: 1, text: ["no session: a", "more"]), name: "a"),
                       "Couldn't rename a: no session: a", "dch's own words (dch.c:11909 at 7983f4b)")
        XCTAssertEqual(AgentIsland.renameFailure(DchActionResult(status: 2), name: "a"), "Couldn't rename a: dch exited 2")
        XCTAssertEqual(AgentIsland.renameFailure(DchActionResult(status: -1), name: "a"), "Couldn't rename a: dch could not be run")
        XCTAssertNotNil(AgentIsland.renameFailure(DchActionResult(status: 0, stopped: true), name: "a"), "cut off: not renamed")
    }

    /// #853 (QA #693 INFO-2): dch keeps at most 599 bytes (write_alias, dch.c:2040 at 7983f4b) and cuts on a
    /// code point; the window cuts first, on a whole character, so what dch stores is what was sent.
    func testAgentRenameTextCapsAt599BytesOnACharacter() throws {
        func sent(_ s: String) throws -> String { try XCTUnwrap(AgentIsland.renameArgs("a", s, current: "")?.last) }
        // 👍🏽 (thumb + skin tone) is one character of 8 bytes: 74 fit (592), the 75th would make 600.
        let thumbs = try sent(String(repeating: "👍🏽", count: 130))
        XCTAssertEqual(thumbs, String(repeating: "👍🏽", count: 74))
        XCTAssertEqual(thumbs.utf8.count, 592)
        // A combining mark at the boundary: e + U+0301 is one character of 3 bytes, never a bare e.
        let acute = "e\u{301}"
        let marks = try sent(String(repeating: "👍🏽", count: 74) + String(repeating: acute, count: 3))
        XCTAssertEqual(marks, String(repeating: "👍🏽", count: 74) + acute + acute, "598 bytes; the third would make 601")
        XCTAssertEqual(marks.utf8.count, 598)
        XCTAssertEqual(marks.unicodeScalars.last, "\u{301}", "the cut keeps the mark with its letter")
        // A family (four people joined by ZWJ, 25 bytes) is kept whole or not at all.
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.utf8.count, 25)
        let fam = try sent(String(repeating: "a", count: 590) + family)
        XCTAssertEqual(fam.count, 120, "120 characters first: all a's")
        let famBytes = try sent(String(repeating: "👍🏽", count: 72) + "ab" + family + "c")
        XCTAssertEqual(famBytes, String(repeating: "👍🏽", count: 72) + "ab", "578 + 25 > 599: the family goes whole")
        // Exactly 599 bytes stays; one byte more cuts the last character.
        let exact = String(repeating: "👍🏽", count: 74) + "abcde" + "\u{E9}"   // 592 + 5 + 2
        XCTAssertEqual(try sent(exact).utf8.count, 599)
        XCTAssertEqual(try sent(exact + "f"), exact)
        // The cut's trailing space goes, as the character cap's does.
        XCTAssertEqual(try sent(String(repeating: "👍🏽", count: 74) + " " + "👍🏽"), String(repeating: "👍🏽", count: 74))
        // Stored = sent: the same text again is unchanged, nothing runs.
        XCTAssertNil(AgentIsland.renameArgs("a", String(repeating: "👍🏽", count: 130), current: thumbs))
    }

    // MARK: Menu and model

    @MainActor
    func testAgentWindowRenameIsALiveSessionsAndEditsTheTitleInPlace() throws {
        let a = session("a", .idle, alias: "Alpha"), b = session("b", .working)
        let st = store([a, b], history: [record("h")])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        let calls = Calls()
        calls.wire(m)
        var renamed: [(AgentSessionKey, String)] = []
        m.renameSession = { renamed.append(($0.key, $1)); return true }
        m.setVisible(true)
        defer { m.close() }
        XCTAssertEqual(AgentWindowControls.menu(a, store: st).first, .item("Rename…", enabled: true, verb: .rename))
        XCTAssertFalse(AgentWindowControls.historyMenu(record("h"), store: st).contains {
            if case .item(_, _, .rename) = $0 { return true } else { return false }
        }, "never on a History row")
        // From the row's context menu on a row not selected: selects it (R6), then edits; nothing asked.
        m.select(.live(b.key))
        m.ask(.rename, a)
        XCTAssertEqual(m.selection, .live(a.key))
        XCTAssertEqual(m.renaming, a.key)
        XCTAssertNil(m.confirming, "no question strip")
        m.endRename(try XCTUnwrap(m.renameEdit), nil)
        XCTAssertNil(m.renaming)
        XCTAssertTrue(renamed.isEmpty, "Esc / focus loss: nothing runs")
        m.ask(.rename, a)
        m.endRename(try XCTUnwrap(m.renameEdit), "  Alpha ")
        XCTAssertTrue(renamed.isEmpty, "unchanged: nothing runs")
        m.ask(.rename, a)
        let beta = try XCTUnwrap(m.renameEdit)
        m.endRename(beta, "Beta")
        XCTAssertEqual(renamed.map(\.0), [a.key])
        XCTAssertEqual(renamed.map(\.1), ["Beta"])
        m.endRename(beta, "again")
        XCTAssertEqual(renamed.count, 1, "an end with no field runs nothing")
        m.ask(.rename, a)
        m.endRename(try XCTUnwrap(m.renameEdit), "")
        XCTAssertEqual(renamed.last?.1, "", "empty clears the alias")
        // Dropped by a selection change, an ask, and the session ending.
        m.ask(.rename, a)
        m.select(.live(b.key))
        XCTAssertNil(m.renaming)
        m.ask(.rename, b)
        m.ask(.stop, b)
        XCTAssertNil(m.renaming)
        XCTAssertNotNil(m.confirming)
        m.confirm(false)
        m.ask(.rename, b)
        XCTAssertEqual(m.renaming, b.key)
        st.sessions = [a]
        XCTAssertNil(m.renaming, "it ended: no field")
        XCTAssertEqual(renamed.count, 2)
        XCTAssertTrue(calls.all.isEmpty)
    }

    /// Review F1/F2: Rename on another row while a field is open moves the field to that row, and a
    /// late end from the replaced field (its key) neither closes the new one nor runs anything.
    @MainActor
    func testAgentWindowRenameOnAnotherRowIgnoresTheReplacedFieldsEnd() throws {
        let a = session("a", .idle, alias: "Alpha"), b = session("b", .idle)
        let st = store([a, b])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        Calls().wire(m)
        var renamed: [(AgentSessionKey, String)] = []
        m.renameSession = { renamed.append(($0.key, $1)); return true }
        m.setVisible(true)
        defer { m.close() }
        m.ask(.rename, a)
        let ea = try XCTUnwrap(m.renameEdit)
        m.ask(.rename, b)
        XCTAssertEqual(m.renaming, b.key)
        XCTAssertEqual(m.selection, .live(b.key))
        m.endRename(ea, nil)
        XCTAssertEqual(m.renaming, b.key, "a's late focus loss leaves b's field open")
        m.endRename(ea, "Typed for a")
        XCTAssertEqual(m.renaming, b.key, "a's late Return neither")
        XCTAssertTrue(renamed.isEmpty, "and runs nothing")
        m.endRename(try XCTUnwrap(m.renameEdit), "Bee")
        XCTAssertNil(m.renaming)
        XCTAssertEqual(renamed.map(\.0), [b.key])
        XCTAssertEqual(renamed.map(\.1), ["Bee"])
    }

    @MainActor
    func testAgentWindowRenameNeverOpensOnAnEndedSession() throws {
        let st = store([session("a", .idle), session("b", .idle)])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        Calls().wire(m)
        var renamed = 0
        m.renameSession = { _, _ in renamed += 1; return true }
        m.setVisible(true)
        defer { m.close() }
        let a = try XCTUnwrap(st.sessions.first { $0.name == "a" })
        m.ask(.stop, a)
        m.confirm(true)
        st.sessions = [session("b", .idle)]
        XCTAssertTrue(m.selectionIsHeld)
        m.ask(.rename, a)
        XCTAssertNil(m.renaming, "held (ended): no field")
        XCTAssertEqual(renamed, 0)
        let header = AgentSessionHeader(row: try XCTUnwrap(m.selectedRow), session: a, cwd: nil, open: {}, store: st, ended: true)
        XCTAssertNil(header.menuStore, "the ended header's \"⋯\" offers nothing, Rename included")
        // A session not listed (gone between the menu and the click): nothing.
        m.ask(.rename, session("gone", .idle))
        XCTAssertNil(m.renaming)
        // The field open, then the session ends under it: the field closes and Return renames nothing.
        // (ask(.rename) is a manual select, so it drops any follow: a held row never carries the field.)
        let b = try XCTUnwrap(st.sessions.first { $0.name == "b" })
        m.ask(.rename, b)
        XCTAssertEqual(m.renaming, b.key)
        let eb = try XCTUnwrap(m.renameEdit)
        st.sessions = []
        XCTAssertNil(m.renaming, "it ended while the field was open: no field")
        m.endRename(eb, "y")
        XCTAssertEqual(renamed, 0)
    }

    // MARK: Keys while the field edits

    @MainActor
    func testAgentWindowShortcutsStandDownWhileRenaming() {
        let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        func key(_ code: UInt16, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: win.windowNumber,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        let keys = [key(18, "1", [.command, .option]), key(19, "2", [.command, .option]), key(17, "t", .command),
                    key(3, "f", .command), key(5, "g", .command), key(5, "g", [.command, .shift]),
                    key(126, "\u{F700}", [.command, .numericPad, .function]), key(36, "\r"), key(125, "\u{F701}"),
                    key(51, "\u{7F}", .command)]   // ⌘⌫: no window key today; any future one stands down too
        for terminal in [true, false] {
            for r: AgentsNSWindow.ResponderKind in [.text, .terminal, .other] {
                for k in keys {
                    XCTAssertEqual(AgentsNSWindow.route(k, responder: r, sidebarFocused: true, terminalMode: terminal, renaming: true),
                                   .pass, "\(k.keyCode) \(r) terminal \(terminal)")
                }
                XCTAssertEqual(AgentsNSWindow.route(key(13, "w", .command), responder: r, sidebarFocused: true, terminalMode: terminal,
                                                    renaming: true), .close, "⌘W still closes")
            }
            XCTAssertNotEqual(AgentsNSWindow.route(keys[0], responder: .text, sidebarFocused: false, terminalMode: terminal), .pass,
                              "control: not renaming, the verbosity key is the window's")
        }
        XCTAssertEqual(AgentsNSWindow.route(keys[2], responder: .text, sidebarFocused: false, terminalMode: false), .toggleMode)
    }

    // MARK: The field (hosted in a window that is never shown)

    @MainActor
    private func hostedWindow<V: View>(_ view: V, _ size: CGSize, window: NSWindow? = nil) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let win = window ?? NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        return (win, host)
    }

    @MainActor
    private func subviews<T: NSView>(_ v: NSView, _ t: T.Type) -> [T] {
        ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { subviews($0, t) }
    }

    @MainActor
    func testAgentRenameFieldSavesOnReturnAndCancelsOnEscOrFocusLoss() throws {
        final class Log { var ends: [String?] = [] }
        func field(_ alias: String) throws -> (NSWindow, AgentRenameTextField, NSTextView, Log) {
            let log = Log()
            let edit = AgentRenameEdit(key: AgentSessionKey(dir: "/tmp/dch-test", name: "prosper"), text: alias)
            let (win, host) = hostedWindow(AgentRenameField(name: "prosper", edit: edit, end: { log.ends.append($1); return false })
                .frame(width: 300, height: 24), CGSize(width: 300, height: 24))
            let f = try XCTUnwrap(subviews(host, AgentRenameTextField.self).first)
            let editor = try XCTUnwrap(f.currentEditor() as? NSTextView, "the field has the keys as it shows")
            XCTAssertTrue(win.firstResponder === editor)
            return (win, f, editor, log)
        }
        // Prefilled with the alias; empty (the dch name as placeholder) when there is none.
        let (w0, f0, _, _) = try field("")
        XCTAssertEqual(f0.stringValue, "")
        XCTAssertEqual(f0.placeholderAttributedString?.string, "prosper")
        XCTAssertEqual(f0.toolTip, "Display name only; the dch session name stays prosper")
        w0.close()
        // Return saves the text, once.
        let (w1, f1, e1, log1) = try field("old")
        XCTAssertEqual(f1.stringValue, "old")
        e1.string = "New name"
        e1.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(log1.ends, ["New name"])
        XCTAssertTrue(w1.makeFirstResponder(nil))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(log1.ends, ["New name"], "the focus leaving after Return ends nothing twice")
        w1.close()
        // Esc cancels.
        let (w2, _, e2, log2) = try field("old")
        e2.string = "typed"
        e2.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(log2.ends, [nil])
        w2.close()
        // The focus leaving cancels.
        let (w3, _, e3, log3) = try field("old")
        e3.string = "typed"
        XCTAssertTrue(w3.makeFirstResponder(nil))
        XCTAssertEqual(log3.ends, [], "#853: held one turn")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(log3.ends, [nil])
        XCTAssertFalse(w3.isVisible, "never shown")
        w3.close()
    }

    /// Through the header in the window's own NSWindow subclass (never shown): one field (not one per
    /// ViewThatFits width), first responder; Return reaches the model's rename; the verbosity keys and ⌘T
    /// stand down and typing lands in the field, never in the composer.
    @MainActor
    func testAgentWindowRenameFieldHasTheKeysAndReturnRenames() throws {
        try withModePref {
            let a = session("a", .idle, alias: "Alpha")
            let st = store([a, session("b", .idle)])
            st.controlDch = bin([1, 38, 0])
            let m = windowModel(st)
            Calls().wire(m)
            var renamed: [String] = []
            m.renameSession = { renamed.append($1); return true }
            showTranscript(m)
            m.setVisible(true)
            defer { m.close() }
            m.select(.live(a.key))
            let level = m.verbosity
            m.ask(.rename, a)
            let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                                     backing: .buffered, defer: true)
            win.model = m
            let (_, host) = hostedWindow(AgentDetailView(model: m, transcript: m.transcript, scrolls: false),
                                         CGSize(width: 900, height: 600), window: win)
            defer { win.close() }
            let fields = subviews(host, AgentRenameTextField.self)
            XCTAssertEqual(fields.count, 1, "one field, in the shown width's title slot")
            let f = try XCTUnwrap(fields.first)
            XCTAssertEqual(f.stringValue, "Alpha")
            let editor = try XCTUnwrap(f.currentEditor() as? NSTextView)
            XCTAssertTrue(win.firstResponder === editor)
            XCTAssertEqual(win.responderKind, .text)
            func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: win.windowNumber,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            }
            let other: AgentVerbosity = level == .verbose ? .focused : .verbose
            _ = win.performKeyEquivalent(with: key(other.keyCode, "", [.command, .option]))
            XCTAssertEqual(m.verbosity, level, "the verbosity keys stand down")
            _ = win.performKeyEquivalent(with: key(17, "t", .command))
            XCTAssertEqual(m.paneMode, .transcript, "⌘T stands down")
            win.sendEvent(key(7, "x"))
            XCTAssertTrue(editor.string.hasSuffix("x"), "typing lands in the field: \(editor.string)")
            XCTAssertEqual(m.interaction.draft, "", "never in the composer")
            XCTAssertFalse(subviews(host, AgentComposerTextView.self).contains { win.firstResponder === $0 })
            editor.string = "Gamma"
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertEqual(renamed, ["Gamma"])
            XCTAssertNil(m.renaming)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            XCTAssertTrue(subviews(host, AgentRenameTextField.self).isEmpty, "the title is back")
            XCTAssertNotNil(AgentsNSWindow.verbosity(for: key(other.keyCode, "", [.command, .option])))
            XCTAssertTrue(win.performKeyEquivalent(with: key(other.keyCode, "", [.command, .option])))
            XCTAssertEqual(m.verbosity, other, "the keys are the window's again")
            m.verbosity = level
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// Review F1: hosted header (never shown). Rename on b while a's field edits: b gets its own field,
    /// empty with b's name as placeholder and b's tooltip, never a's alias or a's typed text; then c's
    /// shows c's alias. The replaced field's end (it leaves the window) keeps the new field open, and
    /// Return renames the session the field is for, with its own text.
    @MainActor
    func testAgentWindowRenameFieldIsPerSession() throws {
        try withModePref {
            let a = session("a", .idle, alias: "Alpha"), b = session("b", .idle), c = session("c", .idle, alias: "Cee")
            let st = store([a, b, c])
            st.controlDch = bin([1, 38, 0])
            let m = windowModel(st)
            Calls().wire(m)
            var renamed: [(AgentSessionKey, String)] = []
            m.renameSession = { renamed.append(($0.key, $1)); return true }
            showTranscript(m)
            m.setVisible(true)
            defer { m.close() }
            m.ask(.rename, a)
            let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                                     backing: .buffered, defer: true)
            win.model = m
            let (_, host) = hostedWindow(AgentDetailView(model: m, transcript: m.transcript, scrolls: false),
                                         CGSize(width: 900, height: 600), window: win)
            defer { win.close() }
            @MainActor func field() throws -> (AgentRenameTextField, NSTextView) {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                let fields = subviews(host, AgentRenameTextField.self)
                XCTAssertEqual(fields.count, 1)
                let f = try XCTUnwrap(fields.first)
                return (f, try XCTUnwrap(f.currentEditor() as? NSTextView, "the field has the keys"))
            }
            let (fa, ea) = try field()
            XCTAssertEqual(fa.stringValue, "Alpha")
            ea.string = "Typed for a"
            m.ask(.rename, b)   // the row's context menu takes no focus: a's field still edits
            let (fb, eb) = try field()
            XCTAssertFalse(fb === fa, "a new field for b")
            XCTAssertEqual(m.renaming, b.key, "a's field leaving ends nothing of b's")
            XCTAssertEqual(fb.stringValue, "", "b has no alias: empty, never a's text")
            XCTAssertEqual(eb.string, "")
            XCTAssertEqual(fb.placeholderAttributedString?.string, "b")
            XCTAssertEqual(fb.toolTip, "Display name only; the dch session name stays b")
            XCTAssertEqual(fb.accessibilityHelp(), "Display name only; the dch session name stays b")
            XCTAssertTrue(win.firstResponder === eb)
            m.ask(.rename, c)
            let (fc, ec) = try field()
            XCTAssertEqual(m.renaming, c.key)
            XCTAssertEqual(fc.stringValue, "Cee")
            XCTAssertEqual(fc.toolTip, "Display name only; the dch session name stays c")
            XCTAssertTrue(renamed.isEmpty, "no switch renamed anything")
            ec.string = "Sea"
            ec.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertEqual(renamed.map(\.0), [c.key])
            XCTAssertEqual(renamed.map(\.1), ["Sea"])
            XCTAssertNil(m.renaming)
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    // MARK: #853 (QA #693)

    /// INFO-1: a resize mid-edit swaps the header's ViewThatFits variant, which builds a new field. The
    /// edit and the typed text carry on (the model holds them), the replaced field's end changes nothing,
    /// and Return renames with the text. Both ways: narrower, then (a second edit, Esc) wider again.
    @MainActor
    func testAgentWindowRenameSurvivesAHeaderVariantSwap() throws {
        try withModePref {
            let a = session("a", .idle, alias: "Alpha")
            let st = store([a, session("b", .idle)])
            st.controlDch = bin([1, 38, 0])
            let m = windowModel(st)
            Calls().wire(m)
            var renamed: [String] = []
            m.renameSession = { renamed.append($1); return true }
            showTranscript(m)
            m.setVisible(true)
            defer { m.close() }
            m.select(.live(a.key))
            let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled],
                                     backing: .buffered, defer: true)
            win.model = m
            let (_, host) = hostedWindow(AgentDetailView(model: m, transcript: m.transcript, scrolls: false),
                                         CGSize(width: 1000, height: 600), window: win)
            defer { win.close() }
            @MainActor func field() throws -> (AgentRenameTextField, NSTextView) {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                host.layoutSubtreeIfNeeded()
                let fields = subviews(host, AgentRenameTextField.self)
                XCTAssertEqual(fields.count, 1, "one field")
                let f = try XCTUnwrap(fields.first)
                return (f, try XCTUnwrap(f.currentEditor() as? NSTextView, "the field has the keys"))
            }
            @MainActor func resize(_ width: CGFloat) {
                win.setContentSize(NSSize(width: width, height: 600))
                host.frame = CGRect(x: 0, y: 0, width: width, height: 600)
            }
            m.ask(.rename, a)
            let (f1, e1) = try field()
            XCTAssertEqual(f1.stringValue, "Alpha")
            e1.selectAll(nil)
            e1.insertText("Typed mid-edit", replacementRange: e1.selectedRange())
            XCTAssertEqual(m.renameEdit?.text, "Typed mid-edit", "the model holds the draft")
            resize(420)
            let (f2, e2) = try field()
            XCTAssertFalse(f2 === f1, "the narrow variant built its own field (the swap happened)")
            XCTAssertEqual(m.renaming, a.key, "the edit survived the swap")
            XCTAssertEqual(f2.stringValue, "Typed mid-edit", "with the typed text")
            XCTAssertTrue(win.firstResponder === e2, "and the keys")
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(m.renaming, a.key, "the replaced field's late end changed nothing")
            XCTAssertTrue(renamed.isEmpty)
            e2.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertEqual(renamed, ["Typed mid-edit"])
            XCTAssertNil(m.renaming)
            // Wider again mid-edit, then Esc: nothing runs.
            m.ask(.rename, a)
            let (f3, e3) = try field()
            e3.selectAll(nil)
            e3.insertText("Second", replacementRange: e3.selectedRange())
            resize(1000)
            let (f4, e4) = try field()
            XCTAssertFalse(f4 === f3, "the wide variant's own field")
            XCTAssertEqual(f4.stringValue, "Second")
            XCTAssertEqual(m.renaming, a.key)
            e4.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            XCTAssertNil(m.renaming)
            XCTAssertEqual(renamed, ["Typed mid-edit"], "Esc ran nothing")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// #853: Rename asked again on the row while its field is open (the "⋯" menu) starts a fresh edit;
    /// the field it replaces goes away, and its end (same session key) closes nothing: the model matches
    /// the edit itself, not its key (r2).
    @MainActor
    func testAgentWindowRenameAskedAgainKeepsTheNewField() throws {
        try withModePref {
            let a = session("a", .idle, alias: "Alpha")
            let st = store([a])
            st.controlDch = bin([1, 38, 0])
            let m = windowModel(st)
            Calls().wire(m)
            showTranscript(m)
            m.setVisible(true)
            defer { m.close() }
            m.ask(.rename, a)
            let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                                     backing: .buffered, defer: true)
            win.model = m
            let (_, host) = hostedWindow(AgentDetailView(model: m, transcript: m.transcript, scrolls: false),
                                         CGSize(width: 900, height: 600), window: win)
            defer { win.close() }
            let e1 = try XCTUnwrap(m.renameEdit)
            let f1 = try XCTUnwrap(subviews(host, AgentRenameTextField.self).first)
            let c1 = try XCTUnwrap(f1.delegate as? AgentRenameField.Coordinator)
            m.ask(.rename, a)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(m.renaming, a.key, "the new edit stays open")
            let e2 = try XCTUnwrap(m.renameEdit)
            XCTAssertFalse(e1 === e2, "a fresh edit")
            let f2 = try XCTUnwrap(subviews(host, AgentRenameTextField.self).first)
            XCTAssertFalse(f1 === f2, "a fresh field")
            XCTAssertTrue(win.firstResponder === f2.currentEditor(), "with the keys")
            // #853 r2: the old field's late end (its focus loss, held one turn) is the old edit's: it ends nothing.
            c1.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: f1))
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            XCTAssertTrue(m.renameEdit === e2, "the old field's end left the new edit")
            XCTAssertTrue(win.firstResponder === f2.currentEditor())
            // The model: an end from the replaced edit (same row, same key) changes nothing.
            XCTAssertFalse(m.endRename(e1, nil))
            XCTAssertFalse(m.endRename(e1, "Typed in the old field"))
            XCTAssertTrue(m.renameEdit === e2)
            XCTAssertEqual(m.renaming, a.key)
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// INFO-1, the safety net: a field that leaves the window with none built in its place ends the edit
    /// on the next turn (no edit left open with the shortcuts standing down and no field).
    @MainActor
    func testAgentRenameFieldLeavingWithNoReplacementEndsTheEdit() throws {
        final class Log { var ends: [String?] = [] }
        let log = Log()
        let edit = AgentRenameEdit(key: AgentSessionKey(dir: "/tmp/dch-test", name: "a"), text: "Alpha")
        let (win, host) = hostedWindow(AgentRenameField(name: "a", edit: edit, end: { log.ends.append($1); return false })
            .frame(width: 300, height: 24), CGSize(width: 300, height: 24))
        defer { win.close() }
        let f = try XCTUnwrap(subviews(host, AgentRenameTextField.self).first)
        XCTAssertTrue(win.firstResponder === f.currentEditor())
        f.removeFromSuperview()
        XCTAssertEqual(log.ends.count, 0, "not at once: a field built in its place may come")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(log.ends, [nil], "none came: the edit ends")
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// INFO-4: Return while a Restart or Stop runs on the row: the controller refuses and its running text stays
    /// the row's line (the input lock reads it), so the field stays open with the text and the row says why.
    /// Return again once the job ended renames. Model, then the hosted field (it takes a second Return).
    @MainActor
    func testAgentWindowRenameReturnWhileAJobRunsKeepsTheFieldAndSaysWhy() throws {
        try withModePref {
            let a = session("a", .idle, alias: "Alpha")
            let st = store([a, session("b", .idle)])
            st.controlDch = bin([1, 38, 0])
            let m = windowModel(st)
            Calls().wire(m)
            var started = false
            var renamed: [String] = []
            m.renameSession = { _, text in
                renamed.append(text)
                return started
            }
            showTranscript(m)
            m.setVisible(true)
            defer { m.close() }
            st.actions[a.key] = AgentIsland.restartingText
            m.ask(.rename, a)
            XCTAssertTrue(m.endRename(try XCTUnwrap(m.renameEdit), "Busy"), "refused: the edit goes on")
            XCTAssertEqual(m.renaming, a.key)
            XCTAssertEqual(m.renameEdit?.text, "Busy", "the text is kept")
            XCTAssertEqual(m.refusalText(.live(a.key)), "Rename not run: another job is running")
            XCTAssertEqual(st.actions[a.key], AgentIsland.restartingText, "the running text stays (the input lock)")
            // Esc: the line goes with the edit.
            XCTAssertFalse(m.endRename(try XCTUnwrap(m.renameEdit), nil))
            XCTAssertNil(m.renaming)
            XCTAssertNil(m.refusalText(.live(a.key)))
            // No control dch: not a busy row; the field closes (the menu item is off then anyway).
            st.controlDch = nil
            m.ask(.rename, a)
            XCTAssertFalse(m.endRename(try XCTUnwrap(m.renameEdit), "NoDch"))
            XCTAssertNil(m.renaming)
            XCTAssertNil(m.refusalText(.live(a.key)))
            st.controlDch = bin([1, 38, 0])
            // Hosted: Return refused, the same field stays with the keys; Return again after the job renames.
            m.ask(.rename, a)
            let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                                     backing: .buffered, defer: true)
            win.model = m
            let (_, host) = hostedWindow(AgentDetailView(model: m, transcript: m.transcript, scrolls: false),
                                         CGSize(width: 900, height: 600), window: win)
            defer { win.close() }
            let f = try XCTUnwrap(subviews(host, AgentRenameTextField.self).first)
            let e = try XCTUnwrap(f.currentEditor() as? NSTextView)
            e.string = "Later"
            e.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(m.renaming, a.key, "the field stays open")
            XCTAssertTrue(subviews(host, AgentRenameTextField.self).first === f, "the same field")
            XCTAssertTrue(win.firstResponder === e, "with the keys")
            XCTAssertEqual(e.string, "Later")
            XCTAssertEqual(m.refusalText(.live(a.key)), AgentIsland.renameBusyText)
            st.actions[a.key] = "Restarted"
            started = true
            e.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertEqual(renamed, ["Busy", "NoDch", "Later", "Later"], "the second Return ran")
            XCTAssertNil(m.renaming)
            XCTAssertNil(m.refusalText(.live(a.key)))
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// QA #699 F1: a busy Return's line goes with the job's running text, so the row's outcome shows:
    /// a Restart that worked or failed with the field still open, and a window Stop on the selected row.
    @MainActor
    func testAgentWindowRenameBusyLineGivesWayToTheJobsOutcome() throws {
        let a = session("a", .idle, alias: "Alpha"), b = session("b", .idle)
        let st = store([a, b])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        Calls().wire(m)
        m.renameSession = { _, _ in false }   // busy: the controller refuses every Return
        m.setVisible(true)
        defer { m.close() }
        func line() -> String? { m.refusalText(.live(a.key)) ?? AgentWindowControls.notice(st, a.key) }
        // Restart: "Restarting…", then a phase text, then the outcome, the field open throughout.
        for outcome in ["Restarted", "Couldn't restart a: no session: a"] {
            st.actions[a.key] = AgentIsland.restartingText
            m.ask(.rename, a)
            XCTAssertTrue(m.endRename(try XCTUnwrap(m.renameEdit), "Busy"))
            XCTAssertEqual(line(), AgentIsland.renameBusyText)
            st.actions[a.key] = "Pausing…"
            XCTAssertEqual(line(), AgentIsland.renameBusyText, "a running text still: the job runs")
            st.actions[a.key] = outcome
            XCTAssertEqual(m.renaming, a.key, "the field stays open")
            XCTAssertNil(m.refusalText(.live(a.key)))
            XCTAssertEqual(line(), outcome, "the job's outcome, not the stale busy line")
            XCTAssertFalse(m.endRename(try XCTUnwrap(m.renameEdit), nil))
        }
        // A window Stop on the selected row, then Rename (a manual pick: it drops the follow to History).
        for (outcome, leaves) in [("Couldn't stop a: no session: a", false), ("Stopped", true)] {
            st.sessions = [a, b]
            st.actions[a.key] = nil
            m.select(.live(a.key))
            m.ask(.stop, a)
            m.confirm(true)
            st.actions[a.key] = AgentIsland.stoppingText
            m.ask(.rename, a)
            XCTAssertTrue(m.endRename(try XCTUnwrap(m.renameEdit), "Busy"))
            XCTAssertEqual(line(), AgentIsland.renameBusyText)
            st.actions[a.key] = outcome
            if leaves { st.sessions = [b] }
            XCTAssertNil(m.refusalText(.live(a.key)))
            if leaves {
                // QA #699 F1's held case: the Rename dropped the follow, so the ended row is not held.
                XCTAssertNil(m.selection, "the session left: nothing selected, no field")
                XCTAssertNil(m.renaming)
            } else {
                XCTAssertEqual(m.selection, .live(a.key))
                XCTAssertEqual(m.renaming, a.key, "the field stays open")
                XCTAssertEqual(line(), outcome, "the Stop's failure, not the stale busy line")
                XCTAssertFalse(m.endRename(try XCTUnwrap(m.renameEdit), nil))
            }
        }
    }

    /// INFO-6: the "⋯" help names what the menu holds: a dash-named session's holds only Rename.
    @MainActor
    func testAgentSessionMenuHelpNamesWhatTheMenuHolds() {
        let st = store([session("a", .idle), session("-x", .idle)])
        st.controlDch = bin([1, 38, 0])
        let dash = session("-x", .idle), a = session("a", .idle)
        func verbs(_ s: AgentSession) -> [AgentWindowVerb] {
            AgentWindowControls.menu(s, store: st).compactMap { if case .item(_, _, let v) = $0 { v } else { nil } }
        }
        XCTAssertEqual(verbs(dash), [.rename])
        XCTAssertEqual(AgentSessionMenuButton.help(dash), "Open in terminal or rename this session")
        XCTAssertEqual(verbs(a), [.rename, .restart, .stop, .kill])
        XCTAssertEqual(AgentSessionMenuButton.help(a), "Open in terminal, rename, restart, stop or kill this session")
    }

    // QA #693 INFO-5 (#2): the title, the chip and the path out of the tree under the Rename field is read from the real
    // tree by testRenameHidesTheTitleChipAndPathUnderTheFieldInTheTree (AgentWindowHeaderTests.swift). #1120 removed the
    // view-value row that stood here: it reflected titleSlot for an accessibilityHidden the slot no longer carries.

    /// QA #693 INFO-5 (#3): the header passes `ended` to its Open in terminal, which #1103 moved into the "⋯": an
    /// ended session's "⋯" is off and its one item, Open in terminal, is off too (the other call sites have their own checks).
    @MainActor
    func testAgentSessionHeaderDimsOpenInTerminalForAnEndedSession() throws {
        let a = session("a", .idle, alias: "Alpha Title")
        let st = store([a])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(a.key))
        let row = try XCTUnwrap(m.selectedRow)
        func header(_ ended: Bool) -> AgentSessionHeader {
            AgentSessionHeader(row: row, session: a, cwd: nil, open: {}, store: st, ended: ended)
        }
        XCTAssertTrue(header(true).menuButton.ended, "ended: the \"⋯\" is off")
        XCTAssertEqual(header(true).menuButton.entries, [.open(enabled: false)], "ended: Open in terminal, off, alone")
        XCTAssertFalse(header(false).menuButton.ended)
        XCTAssertEqual(header(false).menuButton.entries.first, .open(enabled: true), "live: Open in terminal, on, first")
        XCTAssertEqual(header(false).menuButton.help, "Open in terminal, rename, restart, stop or kill this session")
        XCTAssertEqual(header(true).menuButton.help, AgentPaneModeToggle.endedReason, "ended: the \"⋯\" says why, as the button did")
    }

    // MARK: Offscreen renders: the field takes the title's slot and moves nothing

    @MainActor
    func testAgentWindowRenameFieldMovesNothingAtEveryScaleAndMode() throws {
        let savedScale = ThemeRuntime.scale
        defer { ThemeRuntime.scale = savedScale }
        try withModePref {
            let convo = Self.corpus.appendingPathComponent("2.1.318/b-compaction-agents-more-tools.jsonl")
            let (m, st) = demoModel(convo)
            _ = fakeTerminal(m)
            m.renameSession = { _, _ in XCTFail("a render renames nothing"); return false }
            st.controlDch = bin([1, 38, 0])
            defer { m.close() }
            // The whole matrix (24 cases, ~25 s) is a heavy row; a plain run keeps one case per mode at
            // scale 1.0, default size: the aliased session in Transcript, the unaliased one in Terminal.
            let heavy = (try? requireHeavyTests()) != nil
            var ran = 0
            // An aliased session (the field shows the alias) and one with none (the placeholder, its name).
            for name in ["prosper", "infra"] {
                let s = try XCTUnwrap(st.sessions.first { $0.name == name })
                for scale: CGFloat in [1.0, 0.85, 0.7] {
                    ThemeRuntime.scale = scale
                    for (label, size) in [("min", CGSize(width: 640 * scale, height: 420 * scale)),
                                          ("default", CGSize(width: 1000 * scale, height: 680 * scale))] {
                        for mode in [AgentPaneMode.transcript, .terminal] {
                            guard heavy || (scale == 1.0 && label == "default"
                                            && mode == (name == "prosper" ? .transcript : .terminal)) else { continue }
                            ran += 1
                            // One pool per case: its three renders (bitmap + hosting view) go before the next.
                            try autoreleasepool {
                                m.select(.live(s.key))
                                m.setMode(mode, for: s)
                                let tag = "\(name)-\(mode == .terminal ? "terminal" : "transcript")-\(label)-\(scale)"
                                let plain = try render(AgentWindowRootView(model: m, scrolls: false), size: size, dark: true)
                                m.ask(.rename, s)
                                XCTAssertEqual(m.renaming, s.key)
                                let editing = try render(AgentWindowRootView(model: m, scrolls: false), size: size, dark: true)
                                m.endRename(try XCTUnwrap(m.renameEdit), nil)
                                let back = try render(AgentWindowRootView(model: m, scrolls: false), size: size, dark: true)
                                try save(plain, "829p3-\(tag)-title")
                                try save(editing, "829p3-\(tag)-editing")
                                let canvas = CGSize(width: size.width + 24, height: size.height + 24)
                                XCTAssertEqual(overflow(editing, content: size, canvas: canvas), 0, tag)
                                let px = CGFloat(plain.pixelsWide) / canvas.width
                                let width = Int(size.width * px), height = Int(size.height * px)
                                let side = Int((sz(290) * px).rounded(.down))
                                let detail = side + Int(sz(4) * px)
                                let hb = try XCTUnwrap(headerBottom(plain, x: side + Int(sz(8) * px)))
                                XCTAssertEqual(headerBottom(editing, x: side + Int(sz(8) * px)), hb, "the header keeps its height (\(tag))")
                                XCTAssertEqual(differing(plain, editing, x: 0..<side, y: 0..<height), 0, "the sidebar (\(tag))")
                                if let below = span(hb, height, "under the header (\(tag))") {
                                    XCTAssertEqual(differing(plain, editing, x: 0..<width, y: below), 0, "nothing under the header moved (\(tag))")
                                }
                                // The "⋯" box: the header's right padding sz(16) (AgentsWindow.swift:780), the "⋯" frame
                                // sz(18) (AgentWindowControls.swift:263) and 2 of slack. Left of it, the line's spacing
                                // sz(8) (AgentsWindow.swift:903) is blank: its right sz(4) pins the box's edge.
                                let line = Int(AgentSessionHeader.padTop * px)..<Int((AgentSessionHeader.padTop + AgentSessionHeader.lineHeight) * px)
                                let menuLeft = width - Int(sz(16 + 18 + 2) * px)
                                XCTAssertTrue((menuLeft - Int(sz(4) * px)..<menuLeft).allSatisfy { blankColumn(plain, x: $0, line: line) },
                                              "nothing of the controls in the spacing before the \"⋯\" box (\(tag))")
                                XCTAssertTrue((menuLeft..<width - Int(sz(16) * px)).contains { !blankColumn(plain, x: $0, line: line) },
                                              "the \"⋯\" in its box (\(tag))")
                                // The controls' box: from the picker's left edge (Terminal mode: the toggle's) to the "⋯"
                                // box, read off the plain render. It ends at the first sz(16) blank run left of the "⋯" box:
                                // the slot keeps at least that much before the controls (the line's spacing sz(8) and
                                // slotLine's Spacer(minLength: sz(8)), :867); between two controls the blank is the line's
                                // spacing and the icons' insets, 14 at most (the menu tier at 1.0). #1103 r: the walk used
                                // to start at the padding and take sz(14): with Open in terminal gone, the toggle's icon and
                                // the "⋯" glyph stand 15 apart at 1.0, so it stopped at the "⋯" itself, right of menuLeft.
                                let left = try XCTUnwrap(controlsLeft(plain, line: line, from: menuLeft, to: detail, gap: Int(sz(16) * px)), tag)
                                if let controls = span(left, menuLeft, "the controls' box (\(tag))") {
                                    XCTAssertEqual(controlCount(plain, x: controls, line: line, gap: Int(sz(4) * px)), mode == .transcript ? 2 : 1,
                                                   "the box holds the picker and the toggle, Terminal mode the toggle (\(tag))")
                                    XCTAssertEqual(differing(plain, editing, x: controls, y: 0..<hb), 0, "picker and toggle unmoved (\(tag))")
                                }
                                XCTAssertEqual([-1, 0, 1].map { differing(plain, editing, x: menuLeft..<width, y: 0..<hb, dx: $0, tolerance: 0.06) }.min(), 0,
                                               "\"⋯\" unmoved (\(tag))")
                                // The field shows, and only in the title line's band.
                                if let slot = span(detail, left, "the title slot (\(tag))") {
                                    XCTAssertGreaterThan(differing(plain, editing, x: slot, y: line), 0, "the field shows (\(tag))")
                                }
                                XCTAssertEqual(differing(plain, editing, x: detail..<width, y: 0..<max(0, line.lowerBound - Int(sz(4) * px))), 0,
                                               "above the title line (\(tag))")
                                if let under = span(line.upperBound + Int(sz(4) * px), hb, "under the title line (\(tag))") {
                                    XCTAssertEqual(differing(plain, editing, x: detail..<width, y: under), 0, "the folder line (\(tag))")
                                }
                                // Leaving edit mode draws the title exactly as before.
                                XCTAssertEqual([-1, 0, 1].map { differing(plain, back, x: menuLeft..<width, y: 0..<height, dx: $0, tolerance: 0.06) }.min(), 0, tag)
                                XCTAssertEqual(differing(plain, back, x: 0..<menuLeft, y: 0..<height), 0, "back to the title (\(tag))")
                            }
                        }
                    }
                }
            }
            XCTAssertEqual(ran, heavy ? 24 : 2, "cases run: a gate that skips them all passes nothing")
        }
    }

    // MARK: The pixel compares' raw fast path (P3 r3)

    /// differing(), unlike() and controlsLeft() count exactly what their colorAt-only bodies counted
    /// (copied below as the reference): a rep against itself shifted 1 px either way, a pair drawn
    /// 1 pt apart, boxes inside and past the edges, and a pair of two colour spaces (no raw path).
    @MainActor
    func testPixelCompareFastPathCountsWhatColorAtCounted() throws {
        func slowDiffering(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, x: Range<Int>, y: Range<Int>, dx: Int = 0) -> Int {
            var n = 0
            for yy in y where yy < min(a.pixelsHigh, b.pixelsHigh) {
                autoreleasepool {
                    for xx in x where xx < min(a.pixelsWide, b.pixelsWide) && xx + dx >= 0 && xx + dx < b.pixelsWide {
                        if let p = a.colorAt(x: xx, y: yy), let q = b.colorAt(x: xx + dx, y: yy), !same(p, q) { n += 1 }
                    }
                }
            }
            return n
        }
        func slowUnlike(_ rep: NSBitmapImageRep, x: Range<Int>, y: Range<Int>) -> Int {
            guard let ref = rep.colorAt(x: x.lowerBound, y: y.lowerBound) else { return -1 }
            var n = 0
            for yy in y where yy < rep.pixelsHigh {
                for xx in x where xx < rep.pixelsWide {
                    if let p = rep.colorAt(x: xx, y: yy), !same(p, ref) { n += 1 }
                }
            }
            return n
        }
        func slowControlsLeft(_ rep: NSBitmapImageRep, line: Range<Int>, from: Int, to: Int, gap: Int) -> Int? {
            guard rep.colorAt(x: from + 2, y: 4) != nil else { return nil }
            var run = 0
            for x in stride(from: from, through: to, by: -1) {
                let bg = rep.colorAt(x: x, y: 4)
                let blank = line.allSatisfy { y in rep.colorAt(x: x, y: y).map { p in bg.map { same(p, $0, tolerance: 0.06) } ?? true } ?? true }
                run = blank ? run + 1 : 0
                if run >= gap { return x + gap }
            }
            return nil
        }
        func label(_ lead: CGFloat) -> some View {
            Text("Rename 829 · Alpha").font(Neon.font(15, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                .padding(.leading, lead).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Neon.card)
        }
        let size = CGSize(width: 160, height: 24)
        let a = try render(label(8), size: size, dark: true), b = try render(label(9), size: size, dark: true)
        XCTAssertNotNil(RawPixels.pair(a, b), "one layout: the raw path runs")
        let w = a.pixelsWide, h = a.pixelsHigh
        let boxes = [(0..<w, 0..<h), (5..<(w + 7), 3..<(h + 9)), ((w / 3)..<(w / 2), (h / 4)..<(h / 2))]
        for (x, y) in boxes {
            for dx in [-1, 0, 1] {
                XCTAssertEqual(differing(a, a, x: x, y: y, dx: dx), slowDiffering(a, a, x: x, y: y, dx: dx), "\(x) \(y) \(dx)")
                XCTAssertEqual(differing(a, b, x: x, y: y, dx: dx), slowDiffering(a, b, x: x, y: y, dx: dx), "\(x) \(y) \(dx)")
            }
            XCTAssertEqual(unlike(a, x: x, y: y), slowUnlike(a, x: x, y: y), "\(x) \(y)")
            XCTAssertEqual(unlike(b, x: x, y: y), slowUnlike(b, x: x, y: y), "\(x) \(y)")
        }
        XCTAssertEqual(differing(a, a, x: 0..<w, y: 0..<h), 0)
        XCTAssertGreaterThan(differing(a, a, x: 0..<w, y: 0..<h, dx: 1), 0, "a 1-px shift counts")
        XCTAssertGreaterThan(differing(a, b, x: 0..<w, y: 0..<h), 0, "drawn 1 pt apart")
        XCTAssertEqual(differing(a, b, x: 0..<w, y: 0..<h, dx: -2), slowDiffering(a, b, x: 0..<w, y: 0..<h, dx: -2))
        for rep in [a, b] {
            let left = controlsLeft(rep, line: 0..<(h / 2), from: w - 3, to: 0, gap: 4)
            XCTAssertNotNil(left)
            XCTAssertEqual(left, slowControlsLeft(rep, line: 0..<(h / 2), from: w - 3, to: 0, gap: 4))
        }
        // Two colour spaces: no raw path, colorAt alone, the same count as before.
        let other: NSColorSpace = a.colorSpace == .genericRGB ? .sRGB : .genericRGB
        let c = try XCTUnwrap(a.converting(to: other, renderingIntent: .default))
        XCTAssertNil(RawPixels.pair(a, c))
        XCTAssertEqual(differing(a, c, x: 0..<w, y: 0..<h), slowDiffering(a, c, x: 0..<w, y: 0..<h))
        XCTAssertEqual(differing(a, c, x: 0..<w, y: 0..<h, dx: 1), slowDiffering(a, c, x: 0..<w, y: 0..<h, dx: 1))
    }

    /// #1103 r: a box edge from measured values, or nil after a failure that names the bounds: Range traps when its
    /// bounds are out of order, and a trap ends every row after it in a full suite (the heavy suite of 2026-11-14).
    func span(_ lo: Int, _ hi: Int, _ what: String, file: StaticString = #filePath, line: UInt = #line) -> Range<Int>? {
        guard lo < hi else {
            XCTFail("\(what): \(lo)..<\(hi) is empty or reversed", file: file, line: line)
            return nil
        }
        return lo..<hi
    }

    /// A column of the title line that holds nothing but the header's backdrop: controlsLeft's own test, on one column.
    func blankColumn(_ rep: NSBitmapImageRep, x: Int, line: Range<Int>) -> Bool {
        controlsLeft(rep, line: line, from: x, to: x, gap: 1) == x + 1
    }

    /// The controls in a box of the title line: runs of ink parted by at least `gap` blank columns.
    func controlCount(_ rep: NSBitmapImageRep, x: Range<Int>, line: Range<Int>, gap: Int) -> Int {
        var n = 0, blank = gap
        for xx in x {
            if blankColumn(rep, x: xx, line: line) { blank += 1 } else { if blank >= gap { n += 1 }; blank = 0 }
        }
        return n
    }

    /// Scanning the title line leftwards from `from`: the x where a run of `gap` columns of the
    /// header's own colour starts (the spacer between the title slot and the controls), plus one run.
    /// #860: the header sits on the window's backdrop gradient, so a column is blank when it matches its
    /// own pixel at y 4 (above every control), not one colour read at the right edge, within 0.06
    /// (the gradient's dither and its 30-50 pt drift; a control's edge is far past that).
    func controlsLeft(_ rep: NSBitmapImageRep, line: Range<Int>, from: Int, to: Int, gap: Int) -> Int? {
        guard rep.colorAt(x: from + 2, y: 4) != nil else { return nil }
        let raw = RawPixels(rep)
        var run = 0
        for x in stride(from: from, through: to, by: -1) {
            let bg = rep.colorAt(x: x, y: 4)
            let blank = line.allSatisfy { (y: Int) -> Bool in
                if let raw, x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh, raw.equal(x, y, raw, x, 4) { return true }
                return rep.colorAt(x: x, y: y).map { p in bg.map { same(p, $0, tolerance: 0.06) } ?? true } ?? true
            }
            run = blank ? run + 1 : 0
            if run >= gap { return x + gap }
        }
        return nil
    }

    // MARK: QA #672 carry

    /// #1: the held (ended) session's detail pane: the header draws the Ended chip (AgentSessionHeader's
    /// stateChip) and the transcript gets `ended:` (its Open in terminal dims). Rendered against a live
    /// pane of the same session: the chip's columns differ, and the transcript's band differs.
    @MainActor
    func testAgentWindowHeldDetailPaneWiresEndedIntoTheChipAndTheTranscript() throws {
        let st = store([session("a", .idle), session("b", .idle)])
        st.controlDch = bin([1, 38, 0])
        let held = windowModel(st)
        Calls().wire(held)
        held.setVisible(true)
        defer { held.close() }
        let a = try XCTUnwrap(st.sessions.first { $0.name == "a" })
        held.ask(.stop, a)
        held.confirm(true)
        let liveStore = store([session("a", .idle), session("b", .idle)])
        liveStore.controlDch = bin([1, 38, 0])
        st.sessions = [session("b", .idle)]
        XCTAssertTrue(held.selectionIsHeld)
        try withModePref {
            let live = windowModel(liveStore)
            Calls().wire(live)
            showTranscript(live)
            live.setVisible(true)
            defer { live.close() }
            live.select(.live(a.key))
            XCTAssertEqual(live.paneMode, .transcript)
            XCTAssertEqual(held.paneMode, .transcript, "held: Transcript, as every row with nothing to attach")
            let size = CGSize(width: 900, height: 560)
            let h = try render(AgentDetailView(model: held, transcript: held.transcript, scrolls: false), size: size, dark: true)
            let l = try render(AgentDetailView(model: live, transcript: live.transcript, scrolls: false), size: size, dark: true)
            try save(h, "829p3-held-detail")
            try save(l, "829p3-live-detail")
            let px = CGFloat(h.pixelsWide) / (size.width + 24)
            let hb = try XCTUnwrap(headerBottom(l, x: Int(sz(8) * px)))
            XCTAssertEqual(headerBottom(h, x: Int(sz(8) * px)), hb)
            // The chip sits right after the title "a": its columns, in the title line.
            let titleW = NSHostingView(rootView: Text("a").font(Neon.font(15, weight: .semibold))).fittingSize.width
            let chipW = NSHostingView(rootView: AgentStateChip(state: .idle)).fittingSize.width
            let chipX = Int((sz(16) + titleW + sz(8)) * px)
            let line = Int(AgentSessionHeader.padTop * px)..<Int((AgentSessionHeader.padTop + AgentSessionHeader.lineHeight) * px)
            if let chip = span(chipX, chipX + Int(chipW * px), "the chip's columns") {
                XCTAssertGreaterThan(differing(h, l, x: chip, y: line), 0, "the header draws Ended")
            }
            if let title = span(0, chipX - 2, "the title's columns") {
                XCTAssertEqual(differing(h, l, x: title, y: line), 0, "the title itself is the same")
            }
            // The transcript's band (between the header and the input box): its Open in terminal dims.
            let input = Int((size.height - 130) * px)
            if let band = span(hb + 2, input, "the transcript's band") {
                XCTAssertGreaterThan(differing(h, l, x: 0..<Int(size.width * px), y: band), 0, "the transcript draws ended")
            }
        }
    }

    /// #2-#4: the ended composer's VoiceOver label, Ended's own glyph, and the off Open buttons' help.
    @MainActor
    func testAgentWindowEndedPaneSaysWhy() throws {
        XCTAssertEqual(AgentComposerField.label(editable: true), "Message Claude")
        XCTAssertEqual(AgentComposerField.label(editable: false), "Message Claude, session ended")
        let a = session("a", .idle)
        func composer(_ ended: Bool) throws -> AgentComposerTextView {
            let (win, host) = hostedWindow(AgentInteractionPane(model: AgentWindowInteraction(), session: a, open: {}, ended: ended)
                .frame(width: 600), CGSize(width: 600, height: 200))
            defer { win.close() }
            return try XCTUnwrap(subviews(host, AgentComposerTextView.self).first)
        }
        XCTAssertEqual(try composer(true).accessibilityLabel(), "Message Claude, session ended")
        XCTAssertEqual(try composer(false).accessibilityLabel(), "Message Claude")
        XCTAssertEqual(AgentStateChip.endedGlyph, "○")
        XCTAssertFalse(AgentState.allCases.map(\.glyph).contains(AgentStateChip.endedGlyph), "Ended is no live state's glyph")
        XCTAssertEqual(OpenInTerminalButton(action: {}).help, "Open this session in the terminal app")
        XCTAssertEqual(OpenInTerminalButton(action: {}, ended: true).help, "This session ended: there is no terminal to attach to")
        // Its two ended call sites: the terminal-first state and the header.
        let first = TerminalFirstView(reason: "r", openTerminal: {}, ended: true)
        XCTAssertFalse(first.openEnabled)
    }
}
