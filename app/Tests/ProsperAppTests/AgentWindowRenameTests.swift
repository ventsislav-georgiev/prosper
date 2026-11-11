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
        let long = String(repeating: "👍🏽", count: 130)
        XCTAssertEqual(AgentIsland.renameArgs("a", long, current: "")?.last?.count, 120, "capped at 120 characters")
        XCTAssertEqual(AgentIsland.renameArgs("a", "b" + String(repeating: " ", count: 119) + "c", current: ""), ["-m", "a", "b"],
                       "the cut's trailing spaces go too")
        XCTAssertNil(AgentIsland.renameArgs("a", "  cur \n", current: "cur"), "unchanged: nothing runs")
        XCTAssertNil(AgentIsland.renameArgs("a", "   ", current: ""), "no alias, none typed: nothing runs")
        XCTAssertEqual(AgentIsland.renameArgs("a", "", current: "cur"), ["-m", "a", ""], "empty clears the alias")
        XCTAssertEqual(AgentIsland.renameArgs("-x", "y", current: ""), ["-m", "-x", "y"], "any name, its own argv element")
        XCTAssertEqual(AgentIsland.renameHelp("a"), "Display name only; the dch session name stays a")
        XCTAssertNil(AgentIsland.renameFailure(DchActionResult(status: 0), name: "a"))
        XCTAssertEqual(AgentIsland.renameFailure(DchActionResult(status: 1, text: ["dch: no session: a", "more"]), name: "a"),
                       "Couldn't rename a: dch: no session: a")
        XCTAssertEqual(AgentIsland.renameFailure(DchActionResult(status: 2), name: "a"), "Couldn't rename a: dch exited 2")
        XCTAssertEqual(AgentIsland.renameFailure(DchActionResult(status: -1), name: "a"), "Couldn't rename a: dch could not be run")
        XCTAssertNotNil(AgentIsland.renameFailure(DchActionResult(status: 0, stopped: true), name: "a"), "cut off: not renamed")
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
        m.endRename(a.key, nil)
        XCTAssertNil(m.renaming)
        XCTAssertTrue(renamed.isEmpty, "Esc / focus loss: nothing runs")
        m.ask(.rename, a)
        m.endRename(a.key, "  Alpha ")
        XCTAssertTrue(renamed.isEmpty, "unchanged: nothing runs")
        m.ask(.rename, a)
        m.endRename(a.key, "Beta")
        XCTAssertEqual(renamed.map(\.0), [a.key])
        XCTAssertEqual(renamed.map(\.1), ["Beta"])
        m.endRename(a.key, "again")
        XCTAssertEqual(renamed.count, 1, "an end with no field runs nothing")
        m.ask(.rename, a)
        m.endRename(a.key, "")
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
        m.ask(.rename, b)
        XCTAssertEqual(m.renaming, b.key)
        XCTAssertEqual(m.selection, .live(b.key))
        m.endRename(a.key, nil)
        XCTAssertEqual(m.renaming, b.key, "a's late focus loss leaves b's field open")
        m.endRename(a.key, "Typed for a")
        XCTAssertEqual(m.renaming, b.key, "a's late Return neither")
        XCTAssertTrue(renamed.isEmpty, "and runs nothing")
        m.endRename(b.key, "Bee")
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
        m.endRename(a.key, "x")
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
        st.sessions = []
        XCTAssertNil(m.renaming, "it ended while the field was open: no field")
        m.endRename(b.key, "y")
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
            let (win, host) = hostedWindow(AgentRenameField(name: "prosper", alias: alias, end: { log.ends.append($0) })
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
                                m.endRename(s.key, nil)
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
                                XCTAssertEqual(differing(plain, editing, x: 0..<width, y: hb..<height), 0,
                                               "nothing under the header moved (\(tag))")
                                // The right-hand controls: from the picker's left edge (the first gap of the
                                // slot's spacer, read off the plain render) to the "⋯", untouched.
                                let line = (Int(sz(30) * px))..<(Int(sz(30) * px) + Int(sz(20) * px))
                                let left = try XCTUnwrap(controlsLeft(plain, line: line, from: width - Int(sz(16) * px), to: detail,
                                                                      gap: Int(sz(14) * px)), tag)
                                let menuLeft = width - Int(sz(16 + 18 + 2) * px)
                                XCTAssertEqual(differing(plain, editing, x: left..<menuLeft, y: 0..<hb), 0,
                                               "picker, toggle and Open in terminal unmoved (\(tag))")
                                XCTAssertEqual([-1, 0, 1].map { differing(plain, editing, x: menuLeft..<width, y: 0..<hb, dx: $0) }.min(), 0,
                                               "\"⋯\" unmoved (\(tag))")
                                // The field shows, and only in the title line's band.
                                XCTAssertGreaterThan(differing(plain, editing, x: detail..<left, y: line), 0, "the field shows (\(tag))")
                                XCTAssertEqual(differing(plain, editing, x: detail..<width, y: 0..<max(0, line.lowerBound - Int(sz(4) * px))), 0,
                                               "above the title line (\(tag))")
                                XCTAssertEqual(differing(plain, editing, x: detail..<width, y: (line.upperBound + Int(sz(4) * px))..<hb), 0,
                                               "the folder line (\(tag))")
                                // Leaving edit mode draws the title exactly as before.
                                XCTAssertEqual([-1, 0, 1].map { differing(plain, back, x: menuLeft..<width, y: 0..<height, dx: $0) }.min(), 0, tag)
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
            guard let bg = rep.colorAt(x: from + 2, y: 4) else { return nil }
            var run = 0
            for x in stride(from: from, through: to, by: -1) {
                let blank = line.allSatisfy { y in rep.colorAt(x: x, y: y).map { same($0, bg) } ?? true }
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

    /// Scanning the title line leftwards from `from`: the x where a run of `gap` columns of the
    /// header's own colour starts (the spacer between the title slot and the controls), plus one run.
    func controlsLeft(_ rep: NSBitmapImageRep, line: Range<Int>, from: Int, to: Int, gap: Int) -> Int? {
        guard let bg = rep.colorAt(x: from + 2, y: 4) else { return nil }
        let raw = RawPixels(rep)
        var run = 0
        for x in stride(from: from, through: to, by: -1) {
            let blank = line.allSatisfy { (y: Int) -> Bool in
                if let raw, x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh, raw.equal(x, y, raw, from + 2, 4) { return true }
                return rep.colorAt(x: x, y: y).map { same($0, bg) } ?? true
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
            let line = Int(sz(28) * px)..<Int(sz(52) * px)
            XCTAssertGreaterThan(differing(h, l, x: chipX..<(chipX + Int(chipW * px)), y: line), 0, "the header draws Ended")
            XCTAssertEqual(differing(h, l, x: 0..<(chipX - 2), y: line), 0, "the title itself is the same")
            // The transcript's band (between the header and the input box): its Open in terminal dims.
            let input = Int((size.height - 130) * px)
            XCTAssertGreaterThan(differing(h, l, x: 0..<Int(size.width * px), y: (hb + 2)..<input), 0,
                                 "the transcript draws ended")
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
        XCTAssertEqual(OpenInTerminalButton(action: {}).help, "Open this session in the terminal (Return)")
        XCTAssertEqual(OpenInTerminalButton(action: {}, ended: true).help, "This session ended: there is no terminal to attach to")
        // Its two ended call sites: the terminal-first state and the header.
        let first = TerminalFirstView(reason: "r", openTerminal: {}, ended: true)
        XCTAssertFalse(first.openEnabled)
    }
}
