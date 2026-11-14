import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1110: in the Agent Sessions window ⌘1…⌘9 select the live row at that position of the sidebar and move the keyboard
/// into its pane, and each numbered row draws a ⌘<n> chip like Clipboard History's. Offscreen only: key events are built
/// and handed to the pure `route` or to a never-shown window's performKeyEquivalent (nothing is posted, no window is
/// ordered front or made key, no monitor or hotkey is installed); views are hosted in never-shown windows. No dch runs:
/// sessions are model values and the terminal's spawn is a recorder.
extension AgentWindowD1Tests {
    typealias DigitRoute = AgentsNSWindow.KeyRoute

    @MainActor
    func digitKey(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = .command, window: Int = 0,
                  type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    /// Runs `body` with the folded sections and the Transcript choices cleared, both put back after.
    @MainActor
    func withDigitPrefs(_ body: () throws -> Void) rethrows {
        let pref = "agentWindowCollapsedSections"
        let saved = Preferences.defaults.object(forKey: pref)
        defer { Preferences.defaults.set(saved, forKey: pref) }
        Preferences.defaults.removeObject(forKey: pref)
        try withModePref(body)
    }

    // MARK: The route, as a literal table

    /// Every row: key code, characters, modifiers, the responder, Terminal mode, renaming, the form, the route.
    @MainActor
    func testDigitJumpRouteIsALiteralTable() {
        let cmd: NSEvent.ModifierFlags = .command, pad: NSEvent.ModifierFlags = [.command, .numericPad]
        typealias Row = (UInt16, String, NSEvent.ModifierFlags, AgentsNSWindow.ResponderKind, Bool, Bool, Bool, DigitRoute, String)
        let table: [Row] = [
            // The top row, US characters, from every responder and both modes.
            (18, "1", cmd, .other, true, false, false, .jump(1), "⌘1"),
            (19, "2", cmd, .terminal, true, false, false, .jump(2), "⌘2 from the terminal"),
            (20, "3", cmd, .text, true, false, false, .jump(3), "⌘3 from a text view (unlike ⌘↑/⌘↓)"),
            (21, "4", cmd, .text, false, false, false, .jump(4), "⌘4 from the input box, Transcript"),
            (23, "5", cmd, .other, false, false, false, .jump(5), "⌘5"),
            (22, "6", cmd, .terminal, true, false, false, .jump(6), "⌘6"),
            (26, "7", cmd, .other, true, false, false, .jump(7), "⌘7"),
            (28, "8", cmd, .other, true, false, false, .jump(8), "⌘8"),
            (25, "9", cmd, .terminal, false, false, false, .jump(9), "⌘9"),
            // The keypad.
            (83, "1", pad, .terminal, true, false, false, .jump(1), "keypad ⌘1"),
            (84, "2", pad, .other, true, false, false, .jump(2), "keypad ⌘2"),
            (85, "3", pad, .text, false, false, false, .jump(3), "keypad ⌘3"),
            (86, "4", pad, .other, true, false, false, .jump(4), "keypad ⌘4"),
            (87, "5", pad, .other, true, false, false, .jump(5), "keypad ⌘5"),
            (88, "6", pad, .other, true, false, false, .jump(6), "keypad ⌘6"),
            (89, "7", pad, .other, true, false, false, .jump(7), "keypad ⌘7"),
            (91, "8", pad, .other, true, false, false, .jump(8), "keypad ⌘8"),
            (92, "9", pad, .terminal, true, false, false, .jump(9), "keypad ⌘9"),
            // A layout whose digit row needs Shift (French AZERTY: the unshifted keys type & é " ' ( § è ! ç): by key code.
            (18, "&", cmd, .terminal, true, false, false, .jump(1), "AZERTY ⌘&"),
            (19, "é", cmd, .other, true, false, false, .jump(2), "AZERTY ⌘é"),
            (25, "ç", cmd, .text, true, false, false, .jump(9), "AZERTY ⌘ç"),
            // A non-Latin layout whose digit row types its own characters (fake characters: the key code decides).
            (18, "ๅ", cmd, .terminal, true, false, false, .jump(1), "non-Latin digit row ⌘1"),
            (20, "ภ", cmd, .other, false, false, false, .jump(3), "non-Latin digit row ⌘3"),
            // Caps Lock and fn are not modifiers here.
            (18, "1", [.command, .capsLock], .other, true, false, false, .jump(1), "Caps Lock on"),
            // ⌘0 stays free (the terminal's font reset), on the top row and the keypad.
            (29, "0", cmd, .terminal, true, false, false, .pass, "⌘0 is not taken"),
            (82, "0", pad, .terminal, true, false, false, .pass, "keypad ⌘0 is not taken"),
            // Shift, Option or Control added: not this chord. ⌥⌘1/2/3 stay the verbosity chord (swallowed in Terminal mode).
            (18, "!", [.command, .shift], .other, true, false, false, .pass, "⇧⌘1"),
            (18, "1", [.command, .shift], .terminal, true, false, false, .pass, "AZERTY ⇧⌘1 (the shifted digit)"),
            (18, "¡", [.command, .option], .other, false, false, false, .verbosity(.focused), "⌥⌘1 Transcript"),
            (19, "™", [.command, .option], .terminal, false, false, false, .verbosity(.default), "⌥⌘2 Transcript"),
            (20, "£", [.command, .option], .text, false, false, false, .verbosity(.verbose), "⌥⌘3 Transcript"),
            (18, "¡", [.command, .option], .terminal, true, false, false, .swallow, "⌥⌘1 Terminal mode"),
            (23, "∞", [.command, .option], .other, false, false, false, .pass, "⌥⌘5 is nothing"),
            (18, "1", [.command, .control], .other, true, false, false, .pass, "⌃⌘1"),
            (83, "1", [.command, .shift, .numericPad], .other, true, false, false, .pass, "⇧⌘ keypad 1"),
            // No Command: the digit is typed.
            (18, "1", [], .terminal, true, false, false, .pass, "1 into the terminal"),
            (83, "1", .numericPad, .text, false, false, false, .pass, "keypad 1 into the input box"),
            (18, "1", .control, .terminal, true, false, false, .pass, "⌃1 into the terminal"),
            // The rename field: stands down, as ⌘↑/⌘↓; ⌘W still closes.
            (18, "1", cmd, .text, true, true, false, .pass, "rename field ⌘1"),
            (92, "9", pad, .text, false, true, false, .pass, "rename field keypad ⌘9"),
            (13, "w", cmd, .text, true, true, false, .close, "rename field ⌘W"),
            // The New session form: swallowed, as ⌘↑/⌘↓; ⌘N stays the window's.
            (18, "1", cmd, .text, true, false, true, .swallow, "form ⌘1"),
            (25, "9", cmd, .other, false, false, true, .swallow, "form ⌘9"),
            (126, "\u{F700}", [.command, .numericPad, .function], .other, true, false, true, .swallow, "form ⌘↑ (the same rule)"),
            (45, "n", cmd, .text, true, false, true, .newSession, "form ⌘N"),
        ]
        for (code, chars, flags, responder, terminal, renaming, form, want, tag) in table {
            XCTAssertEqual(AgentsNSWindow.route(digitKey(code, chars, flags), responder: responder, sidebarFocused: false,
                                                terminalMode: terminal, renaming: renaming, form: form), want, tag)
            XCTAssertEqual(AgentsNSWindow.route(digitKey(code, chars, flags), responder: responder, sidebarFocused: true,
                                                terminalMode: terminal, renaming: renaming, form: form), want, "\(tag), sidebar focused")
        }
        XCTAssertEqual(AgentsNSWindow.route(digitKey(18, "1", type: .keyUp), responder: .other, sidebarFocused: false,
                                            terminalMode: true), .pass, "a key up is nobody's chord")
    }

    // MARK: The selection and the focus, through the model

    /// ⌘<n> through a never-shown window's performKeyEquivalent: the n-th live row of the sidebar, selected, and the
    /// keys in its pane (the terminal in Terminal mode, the input box in Transcript), from the sidebar, the terminal and
    /// the input box (a text view).
    @MainActor
    func testDigitJumpSelectsTheRowAndMovesTheKeysIntoItsPane() throws {
        try withDigitPrefs {
            // b is done (Needs you): ⌘1. a and c follow in Sessions, newest first. c is in Transcript.
            let a = mapped("a", .idle, ago: 1), b = mapped("b", .done, ago: 5), c = mapped("c", .idle, ago: 9)
            let m = windowModel(store([c, a, b]))
            _ = fakeTerminal(m)
            m.setMode(.transcript, for: c)
            m.setVisible(true)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            XCTAssertEqual(m.numberedIDs, [live("b"), live("a"), live("c")])
            m.select(live("b"))
            settle(host)
            sidebarKeys(win)
            // From the sidebar: ⌘2 is a, and its terminal has the keys.
            XCTAssertTrue(win.performKeyEquivalent(with: digitKey(19, "2", window: win.windowNumber)))
            settle(host)
            XCTAssertEqual(m.selection, live("a"))
            XCTAssertEqual(m.terminal.key?.name, "a")
            let term = try XCTUnwrap(m.terminal.view)
            XCTAssertTrue(win.firstResponder === term, "⌘2 moved the keys into a's terminal")
            XCTAssertFalse(win.sidebarFocused)
            // From the terminal: keypad ⌘1 is b; the keys stay in the terminal, now b's.
            XCTAssertTrue(win.performKeyEquivalent(with: digitKey(83, "1", [.command, .numericPad], window: win.windowNumber)))
            settle(host)
            XCTAssertEqual(m.selection, live("b"))
            XCTAssertEqual(m.terminal.key?.name, "b")
            XCTAssertTrue(win.firstResponder === m.terminal.view, "the keys are in b's terminal")
            // ⌘3: c, in Transcript: its input box takes the keys.
            XCTAssertTrue(win.performKeyEquivalent(with: digitKey(20, "3", window: win.windowNumber)))
            settle(host)
            XCTAssertEqual(m.selection, live("c"))
            XCTAssertEqual(m.paneMode, .transcript)
            let tv = try XCTUnwrap(focusViews(host, AgentComposerTextView.self).first)
            XCTAssertTrue(win.firstResponder === tv, "the input box built for c took the keys")
            // From the input box (a text view): ⌘2 is still the window's; a's terminal takes the keys.
            XCTAssertTrue(win.performKeyEquivalent(with: digitKey(19, "2", window: win.windowNumber)))
            settle(host)
            settle(host)
            XCTAssertEqual(m.selection, live("a"))
            let back = try XCTUnwrap(m.terminal.view)
            XCTAssertTrue(win.firstResponder === back, "from the input box into a's terminal")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// A digit with no live row at that position: handled (true: no beep, nothing reaches the terminal or the menu) and
    /// nothing changes. History rows are not numbered; nor are a folded section's; no store, nothing.
    @MainActor
    func testDigitJumpWithNoRowThereIsSwallowedAndChangesNothing() {
        withDigitPrefs {
            let m = windowModel(store([session("api", .idle, ago: 1), session("web", .idle, ago: 2)], history: [record("old")]))
            _ = fakeTerminal(m)
            m.setVisible(true)
            defer { m.close() }
            let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                     backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            defer { win.close() }
            win.model = m
            m.select(live("web"))
            XCTAssertEqual(m.numberedIDs, [live("api"), live("web")], "History is not numbered")
            XCTAssertEqual(m.rows.count, 3, "the History row is listed third")
            // ⌘3 (History's place), ⌘9, keypad ⌘3 and ⌘9.
            let keys: [(UInt16, NSEvent.ModifierFlags)] = [(20, .command), (25, .command), (85, [.command, .numericPad]),
                                                           (92, [.command, .numericPad])]
            for (code, flags) in keys {
                XCTAssertTrue(win.performKeyEquivalent(with: digitKey(code, "", flags)), "handled (\(code))")
                XCTAssertEqual(m.selection, live("web"), "nothing selected (\(code))")
            }
            XCTAssertFalse(m.selectNumbered(0))
            XCTAssertFalse(m.selectNumbered(3))
            XCTAssertFalse(m.selectNumbered(-1))
            XCTAssertEqual(m.selection, live("web"))
            // Sessions folded: its rows are not shown, so not numbered; ⌘1 is nothing.
            m.setCollapsed("Sessions", true)
            XCTAssertEqual(m.numberedIDs, [])
            XCTAssertTrue(win.performKeyEquivalent(with: digitKey(18, "1")))
            XCTAssertEqual(m.selection, live("web"), "a folded row is never picked by number")
            m.setCollapsed("Sessions", false)
            XCTAssertTrue(win.performKeyEquivalent(with: digitKey(18, "1")))
            XCTAssertEqual(m.selection, live("api"))
            // The island off: nothing numbered, the key still handled.
            let none = windowModel(nil)
            defer { none.close() }
            win.model = none
            XCTAssertEqual(none.numberedIDs, [])
            XCTAssertTrue(win.performKeyEquivalent(with: digitKey(18, "1")))
            XCTAssertTrue(none.selection == nil)
        }
    }

    /// The sessions behind the order rows: 10 idle in Sessions (s1 newest), api-qa in Sidekicks, web-qa blocked in
    /// Needs you, one History record; handed to the store in another order than the sidebar's.
    @MainActor
    func digitModel() -> (AgentWindowModel, AgentIslandStore) {
        var sessions = (1...10).map { session("s\($0)", .idle, ago: Double($0) * 10) }
        sessions += [session("api-qa", .idle, ago: 3), session("web-qa", .blocked, ago: 7)]
        let st = store(Array(sessions.reversed()), history: [record("old")], pattern: "-qa")
        let m = windowModel(st)
        _ = fakeTerminal(m)
        m.setVisible(true)
        return (m, st)
    }

    /// The numbers are the sidebar's order (Needs you, Sessions, Sidekicks), the first nine live rows, and follow the
    /// rows when the order changes; a folded section is skipped.
    @MainActor
    func testDigitJumpNumbersFollowTheSidebarOrder() {
        withDigitPrefs {
            let (m, st) = digitModel()
            defer { m.close() }
            XCTAssertEqual(m.sections.map(\.title), ["Needs you", "Sessions", "Sidekicks", "History"])
            XCTAssertEqual(m.numberedIDs, ["web-qa", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8"].map(live))
            XCTAssertEqual(m.number(live("web-qa")), 1)
            XCTAssertEqual(m.number(live("s8")), 9)
            XCTAssertTrue(m.number(live("s9")) == nil, "the tenth live row has no number")
            XCTAssertTrue(m.number(live("api-qa")) == nil)
            XCTAssertTrue(m.number(.history(AgentSessionKey(dir: "/tmp/dch-test", name: "old"))) == nil, "History: none")
            XCTAssertTrue(m.selectNumbered(9))
            XCTAssertEqual(m.selection, live("s8"))
            // s5 turns blocked (newest): it moves into Needs you, above web-qa, and is ⌘1; the rest move down one.
            st.sessions = st.sessions.map { $0.key.name == "s5" ? session("s5", .blocked, ago: 1) : $0 }
            XCTAssertEqual(m.numberedIDs, ["s5", "web-qa", "s1", "s2", "s3", "s4", "s6", "s7", "s8"].map(live))
            XCTAssertTrue(m.selectNumbered(1))
            XCTAssertEqual(m.selection, live("s5"))
            // Sessions folded: its rows are not drawn, so the numbers run on into Sidekicks.
            m.setCollapsed("Sessions", true)
            XCTAssertEqual(m.numberedIDs, ["s5", "web-qa", "api-qa"].map(live))
            XCTAssertTrue(m.selectNumbered(3))
            XCTAssertEqual(m.selection, live("api-qa"))
        }
    }

    // MARK: The chip, from the row view

    struct DigitAX { let label: String, help: String, frame: CGRect, ignored: Bool }

    @MainActor
    func digitAXWalk(_ e: Any, _ out: inout [DigitAX], depth: Int = 0) {
        guard depth < 40, let o = e as? NSObject else { return }
        func text(_ key: String) -> String {
            guard o.responds(to: Selector(key)) else { return "" }
            let v = o.value(forKey: key)
            return (v as? String) ?? (v as? NSAttributedString)?.string ?? ""
        }
        let frame = o.responds(to: Selector(("accessibilityFrame")))
            ? (o.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero : .zero
        let ignored = !NSAccessibility.unignoredChildren(from: [o]).contains { ($0 as AnyObject) === o }
        out.append(DigitAX(label: text("accessibilityLabel"), help: text("accessibilityHelp"), frame: frame, ignored: ignored))
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { digitAXWalk(k, &out, depth: depth + 1) }
    }

    /// The real accessibility tree of `view` in a never-shown window (built once this process asks, as an AX client's
    /// attribute write would; both attributes are put back after), walked until `done` holds, with a ceiling.
    @MainActor
    func digitTree<V: View>(_ view: V, _ size: CGSize, until done: ([DigitAX]) -> Bool) -> [DigitAX] {
        let set = Selector(("accessibilitySetValue:forAttribute:")), attrs = ["AXEnhancedUserInterface", "AXManualAccessibility"]
        let app = NSApplication.shared
        XCTAssertTrue(app.responds(to: set))
        defer { for a in attrs { app.perform(set, with: NSNumber(value: false), with: a) } }
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        for a in attrs { app.perform(set, with: NSNumber(value: true), with: a) }
        var tree: [DigitAX] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            tree = []
            digitAXWalk(host, &tree)
        } while !done(tree) && Date() < deadline
        XCTAssertFalse(win.isVisible, "never shown")
        return tree
    }

    /// The model's rows drawn as the sidebar draws them (its row view, the model's numbers), at the sidebar's row width.
    @MainActor
    func digitRows(_ m: AgentWindowModel) -> some View {
        VStack(spacing: 0) {
            ForEach(m.rows) { r in
                AgentSidebarRowView(row: r, selected: m.selection == r.id, number: m.number(r.id)).frame(width: sz(274))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Rows 1 to 9 carry the chip, the tenth live row and History none; each chip has its name and help in the real
    /// accessibility tree and sits whole inside its own row, at its trailing end; at 0.7, 0.85 and 1.0.
    @MainActor
    func testDigitJumpChipOnRowsOneToNineOnlyInTheAccessibilityTree() {
        _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        withDigitPrefs {
            let (m, _) = digitModel()
            defer { m.close() }
            m.select(live("s2"))
            let titles = ["web-qa", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8"]
            for scale: CGFloat in [0.7, 0.85, 1.0] {
                ThemeRuntime.scale = scale
                let tree = digitTree(digitRows(m), CGSize(width: sz(274), height: 13 * 80 * scale)) { t in
                    t.filter { $0.label.hasPrefix("Command-") }.count >= 9 && t.contains { $0.label.hasPrefix("old,") }
                }
                let chips = tree.filter { $0.label.hasPrefix("Command-") && !$0.ignored }
                XCTAssertEqual(Set(chips.map(\.label)),
                               ["Command-1", "Command-2", "Command-3", "Command-4", "Command-5", "Command-6", "Command-7",
                                "Command-8", "Command-9"], "\(scale)")
                XCTAssertEqual(chips.count, 9, "one chip per numbered row (\(scale))")
                var rows: [DigitAX] = []   // one per row: a wrapper repeating a row's name and frame is not a second row
                for e in tree where !e.ignored && !e.label.hasPrefix("Command-") && e.frame.height > 0
                    && (titles + ["s9", "s10", "api-qa", "old"]).contains(where: { e.label.hasPrefix("\($0),") })
                    && !rows.contains(where: { $0.label == e.label && $0.frame == e.frame }) { rows.append(e) }
                XCTAssertEqual(rows.count, 13, "every row is read (\(scale))")
                for chip in chips {
                    let n = Int(chip.label.dropFirst("Command-".count)) ?? 0
                    XCTAssertEqual(chip.help, "Select this session (⌘\(n))", "\(scale)")
                    let center = CGPoint(x: chip.frame.midX, y: chip.frame.midY)
                    let owner = rows.filter { $0.frame.contains(center) }
                    XCTAssertEqual(owner.count, 1, "\(chip.label) sits on one row (\(scale))")
                    guard let row = owner.first, n >= 1, n <= titles.count else { continue }
                    XCTAssertTrue(row.label.hasPrefix("\(titles[n - 1]),"), "\(chip.label) on \(titles[n - 1]), not \(row.label) (\(scale))")
                    XCTAssertTrue(row.frame.contains(chip.frame), "\(chip.label) drawn whole inside its row (\(scale))")
                    XCTAssertGreaterThan(chip.frame.minX, row.frame.midX, "\(chip.label) at the trailing end (\(scale))")
                    XCTAssertGreaterThan(chip.frame.width, 0)
                }
            }
        }
    }

    /// The chip never changes a row's height or moves anything left of it (the glyph, the title, the state text), at
    /// 0.7, 0.85 and 1.0; too narrow a row draws none (whole or not at all), at the same height.
    @MainActor
    func testDigitJumpChipKeepsTheRowHeightAndTheTitleInPlace() throws {
        _ = ThemeStore.shared
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let rows = [AgentSidebar.row(session("api", .idle, ago: 300), details: .all, now: Self.now),
                    AgentSidebar.row(symbolsSession("web", .blocked, agents: 3, merged: 192, open: 8), details: .all, now: Self.now),
                    AgentSidebar.row(session("a-very-long-session-name-that-truncates-in-the-middle-of-the-row", .working, ago: 5),
                                     details: .all, now: Self.now)]
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            for row in rows {
                for width in [sz(274), sz(110)] {
                    let plain = NSHostingView(rootView: AgentSidebarRowView(row: row, selected: false).frame(width: width)).fittingSize
                    for selected in [false, true] {
                        let chip = NSHostingView(rootView: AgentSidebarRowView(row: row, selected: selected, number: 7)
                            .frame(width: width)).fittingSize
                        XCTAssertEqual(chip.height, plain.height, accuracy: 0.01, "\(row.title) \(width) \(scale) selected \(selected)")
                    }
                }
                // Left of the chip, every pixel is the same with and without it (no PR chips: the line keeps its text).
                guard row.prs.isEmpty else { continue }
                let size = CGSize(width: sz(274), height: NSHostingView(rootView: AgentSidebarRowView(row: row, selected: false)
                    .frame(width: sz(274))).fittingSize.height)
                let without = try render(AgentSidebarRowView(row: row, selected: false), size: size, dark: true)
                let with = try render(AgentSidebarRowView(row: row, selected: false, number: 7), size: size, dark: true)
                XCTAssertEqual(without.pixelsWide, with.pixelsWide)
                let sx = CGFloat(with.pixelsWide) / (size.width + 24)
                var diff = 0
                for y in 0..<min(with.pixelsHigh, without.pixelsHigh) {
                    for x in 0..<Int(size.width * 0.6 * sx) {
                        guard let a = with.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              let b = without.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                            + abs(a.blueComponent - b.blueComponent) > 0.02 { diff += 1 }
                    }
                }
                XCTAssertEqual(diff, 0, "\(row.title) at \(scale): nothing left of the chip moved")
                let drawn = try render(AgentSidebarRowView(row: row, selected: false, number: 7), size: size, dark: true)
                XCTAssertEqual(overflow(drawn, content: size, canvas: CGSize(width: size.width + 24, height: size.height + 24)), 0,
                               "the chip inside the row (\(row.title) \(scale))")
            }
            // Too narrow for the chip: none at all in the tree, never a cut one.
            let narrow = digitTree(AgentSidebarRowView(row: rows[1], selected: false, number: 4).frame(width: sz(110)),
                                   CGSize(width: sz(110), height: 80 * scale)) { t in t.contains { $0.label.hasPrefix("web,") } }
            XCTAssertTrue(narrow.contains { $0.label.hasPrefix("web,") }, "the row is read (\(scale))")
            XCTAssertFalse(narrow.contains { $0.label.hasPrefix("Command-") }, "no room: no chip (\(scale))")
            let wide = digitTree(AgentSidebarRowView(row: rows[1], selected: false, number: 4).frame(width: sz(274)),
                                 CGSize(width: sz(274), height: 80 * scale)) { t in t.contains { $0.label == "Command-4" } }
            XCTAssertTrue(wide.contains { $0.label == "Command-4" && $0.help == "Select this session (⌘4)" },
                          "the PR chips gave way, the chip is drawn (\(scale))")
        }
    }
}
