import AppKit
import XCTest
@testable import ProsperApp

/// #901 B3 step 3 (spec 8.1, 12.1, 12.2, 15.0; OQ-128 default; R901-s2-q1): ⌃1…⌃9 and ⌃Tab switch layouts through
/// `AgentsNSWindow.layoutKey` (what sendEvent calls), gate on only; ⌘1…⌘9 stay #1110's row jump. Offscreen only: every
/// event is BUILT with NSEvent.keyEvent and handed to the pure function as a value (never posted, never sent to a window
/// or the application, no window made); modifiers are the built event's, never the live keyboard state. Every row uses
/// a private in-memory suite (`layoutSuite`, XCTestDefaults); the split gate is saved, set and restored through
/// `gate(_:)`. Sessions are fakes; the session verbs are recording fakes (`Calls`, the `opened` counter), never run.
/// Closures: the `opened` seam runs on the main actor (the model calls it from main-actor code).
extension AgentWindowD1Tests {
    @MainActor
    private func layoutKeyEvent(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    /// The top row's key codes for 1…9 and the keypad's.
    private static let topDigits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    private static let padDigits: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]

    private func keysSuite(_ layouts: [PaneLayout], active: UUID) throws -> (UserDefaults, Data?) {
        let d = layoutSuite()
        d.set(try PaneLayoutStore(layouts: layouts, active: active, mru: [active]).encode(), forKey: "agentWindowLayouts")
        return (d, d.data(forKey: "agentWindowLayouts"))
    }

    /// Item 2: ⌃ + digit (top row or keypad) is layout N and ⌃Tab the MRU pair, Control alone; ⌘ + digit is no pane key
    /// (the row jump's); ⌥⌃, ⇧⌃ and ⌃⌘ digits are nothing. GATE-OFF GUARD: with the gate off both are nil for every
    /// responder, key focus and pane count.
    @MainActor
    func testAgentWindowLayoutKeysMapControlDigitsAndControlTabGateOnOnly() {
        for on in [true, false] {
            for r: AgentsNSWindow.ResponderKind in [.text, .terminal, .other] {
                for f: PaneKeys.KeyFocus in [.sidebar, .pane] {
                    for panes in [1, 2] {
                        let c = PaneKeys.Context(responder: r, keyFocus: f, panes: panes, splitsEnabled: on)
                        let why = "gate \(on), \(r), \(f), \(panes)"
                        for (i, code) in (Self.topDigits + Self.padDigits).enumerated() {
                            let n = i % 9 + 1
                            let got = PaneKeys.action(for: layoutKeyEvent(code, [.control], "\(n)"), context: c)
                            XCTAssertTrue(got == (on ? PaneAction.layout(n) : nil), "⌃\(n) \(code) \(why)")
                            for m: NSEvent.ModifierFlags in [[.command], [.control, .option], [.control, .shift],
                                                             [.control, .command]] {
                                let other = PaneKeys.action(for: layoutKeyEvent(code, m, "\(n)"), context: c)
                                XCTAssertTrue(other == nil, "\(m.rawValue) \(n) \(why)")
                            }
                        }
                        let tab = PaneKeys.action(for: layoutKeyEvent(48, [.control], "\t"), context: c)
                        XCTAssertTrue(tab == (on ? PaneAction.previousLayout : nil), "⌃Tab \(why)")
                    }
                }
            }
        }
    }

    /// Item 3 GATE-OFF GUARD: with the gate off (the product) the route consumes nothing: ⌃1…⌃9, ⌃Tab and ⌘1 travel on
    /// to today's handlers (the window's route gives what it gave on the base), nothing is switched or written.
    @MainActor
    func testAgentWindowLayoutKeysGateOffConsumeNothing() throws {
        gate(false)
        let a = paneLayout([paneTarget("a")]), b = paneLayout([paneTarget("b")])
        let (d, bytes) = try keysSuite([a, b], active: a.id)
        let m = windowModel(store([session("a", .idle), session("b", .idle)]), layouts: d)
        defer { m.close() }
        m.setVisible(true)
        let before = m.layout
        var keys = Self.topDigits.enumerated().map { layoutKeyEvent($1, [.control], "\($0 + 1)") }
        keys += [layoutKeyEvent(48, [.control], "\t"), layoutKeyEvent(18, [.command], "1")]
        for e in keys {
            for r: AgentsNSWindow.ResponderKind in [.text, .terminal, .other] {
                XCTAssertFalse(AgentsNSWindow.layoutKey(e, m, responder: r), "\(e.keyCode) \(r)")
            }
            let today = AgentsNSWindow.route(e, responder: .terminal, sidebarFocused: false, terminalMode: true)
            // #1111: ⌃Tab routes to the group's step (perform gives false outside a group, so the key still goes on)
            let expected: AgentsNSWindow.KeyRoute = e.modifierFlags.contains(.command) ? .jump(1) : e.keyCode == 48 ? .member(1) : .pass
            XCTAssertEqual(today, expected, "\(e.keyCode): today's route")
        }
        XCTAssertEqual(m.layout, before)
        XCTAssertEqual(m.layoutWrites, 0, "nothing written")
        XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), bytes)
    }

    /// Item 3 (8.1), gate on: ⌃2 switches (one write, the MRU updated), ⌃Tab goes back, a keypad digit switches, the
    /// active layout's own key and a number with no layout are consumed and do nothing (no write: a silent no-op), a
    /// lone MRU's ⌃Tab too. From the terminal and a text view as from the sidebar (item 4).
    @MainActor
    func testAgentWindowLayoutKeysSwitchAndRefuseSilently() throws {
        gate(true)
        let a = paneLayout([paneTarget("a")]), b = paneLayout([paneTarget("b")]), c = paneLayout([paneTarget("c")])
        let (d, bytes) = try keysSuite([a, b, c], active: a.id)
        let m = windowModel(store([session("a", .idle), session("b", .idle), session("c", .idle)]), layouts: d)
        defer { m.close() }
        m.setVisible(true)
        XCTAssertEqual(m.layoutWrites, 0)

        XCTAssertTrue(AgentsNSWindow.layoutKey(layoutKeyEvent(48, [.control], "\t"), m, responder: .terminal),
                      "a lone MRU: consumed")
        XCTAssertTrue(AgentsNSWindow.layoutKey(layoutKeyEvent(26, [.control], "7"), m, responder: .other),
                      "no layout 7: consumed")
        XCTAssertTrue(AgentsNSWindow.layoutKey(layoutKeyEvent(18, [.control], "1"), m, responder: .text),
                      "the active layout's key: consumed")
        XCTAssertEqual(m.layoutWrites, 0, "a refusal writes nothing")
        XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), bytes)
        XCTAssertEqual(m.layout.id, a.id)

        XCTAssertTrue(AgentsNSWindow.layoutKey(layoutKeyEvent(19, [.control], "2"), m, responder: .terminal))
        XCTAssertEqual(m.layout.id, b.id)
        XCTAssertEqual(m.layoutWrites, 1, "one write per switch")
        XCTAssertEqual(savedLayouts(d).mru, [b.id, a.id], "the MRU updated by a key switch")

        XCTAssertTrue(AgentsNSWindow.layoutKey(layoutKeyEvent(48, [.control], "\t"), m, responder: .terminal))
        XCTAssertEqual(m.layout.id, a.id, "⌃Tab: the MRU pair")
        XCTAssertEqual(m.layoutWrites, 2)

        XCTAssertTrue(AgentsNSWindow.layoutKey(layoutKeyEvent(85, [.control], "3"), m, responder: .other), "keypad 3")
        XCTAssertEqual(m.layout.id, c.id)
        XCTAssertEqual(savedLayouts(d).mru, [c.id, a.id, b.id])
        XCTAssertEqual(m.layoutWrites, 3)
    }

    /// Item 3: the other keys that share the window's key path keep their handlers with the gate on: layoutKey leaves
    /// them alone (false: sendEvent goes on as before) and the window's route gives each its own action.
    @MainActor
    func testAgentWindowLayoutKeysLeaveTheOtherChordsAlone() throws {
        gate(true)
        let a = paneLayout([paneTarget("a")]), b = paneLayout([paneTarget("b")])
        let (d, _) = try keysSuite([a, b], active: a.id)
        let m = windowModel(store([session("a", .idle), session("b", .idle)]), layouts: d)
        defer { m.close() }
        m.setVisible(true)
        typealias R = AgentsNSWindow.KeyRoute
        var rows: [(NSEvent, R)] = Self.topDigits.enumerated().map { (layoutKeyEvent($1, [.command], "\($0 + 1)"), R.jump($0 + 1)) }
        // #1470 a: Option-Command-1...9 jump to rows 10...18 in both modes (they were the detail-level keys, swallowed here).
        rows += Self.topDigits.enumerated().map { (layoutKeyEvent($1, [.command, .option], "\($0 + 1)"), R.jump($0 + 10)) }
        rows += [
            (layoutKeyEvent(83, [.command], "1"), .jump(1)),
            (layoutKeyEvent(24, [.command], "="), .font(1)),
            (layoutKeyEvent(27, [.command], "-"), .font(-1)),
            (layoutKeyEvent(29, [.command], "0"), .font(0)),
            (layoutKeyEvent(24, [.command, .shift], "+"), .font(1)),
            (layoutKeyEvent(13, [.command], "w"), .close),
            (layoutKeyEvent(17, [.command], "t"), .swallow),   // R1471a-s1: a terminal pane swallows it
            (layoutKeyEvent(3, [.command], "f"), .find),
            (layoutKeyEvent(5, [.command], "g"), .findNext(true)),
            (layoutKeyEvent(5, [.command, .shift], "G"), .findNext(false)),
            (layoutKeyEvent(45, [.command], "n"), .newSession),
            (layoutKeyEvent(45, [.command, .shift], "N"), .newShell),
            (layoutKeyEvent(1, [.control, .command], "\u{13}"), .pass),
            (layoutKeyEvent(8, [.command], "c"), .pass),
            (layoutKeyEvent(9, [.command], "v"), .pass),
            (layoutKeyEvent(7, [.command], "x"), .pass),
            (layoutKeyEvent(0, [.command], "a"), .pass),
            (layoutKeyEvent(6, [.command], "z"), .pass),
            (layoutKeyEvent(48, [], "\t"), .pass),
            (layoutKeyEvent(48, [.control, .shift], "\t"), .member(-1)),   // #1111: the group's previous member (layoutKey leaves it)
            (layoutKeyEvent(8, [.control], "\u{3}"), .pass),
        ]
        for (e, want) in rows {
            XCTAssertFalse(AgentsNSWindow.layoutKey(e, m, responder: .terminal), "\(e.keyCode) \(e.modifierFlags.rawValue)")
            XCTAssertEqual(AgentsNSWindow.route(e, responder: .terminal, sidebarFocused: false, terminalMode: true), want,
                           "\(e.keyCode) \(e.modifierFlags.rawValue)")
        }
        XCTAssertEqual(m.layout.id, a.id)
        XCTAssertEqual(m.layoutWrites, 0)
    }

    /// R3.4 through the keys: ten ⌃1 / ⌃Tab rounds start no session: no open, no session verb, no New session form.
    @MainActor
    func testAgentWindowLayoutKeysTenSwitchesSpawnNothing() throws {
        gate(true)
        var opened = 0
        let gone = paneLayout([paneTarget("a")]), live = paneLayout([paneTarget("b")])
        let (d, _) = try keysSuite([gone, live], active: live.id)
        let m = windowModel(store([session("b", .idle)]), opened: { _ in opened += 1 }, layouts: d)
        defer { m.close() }
        let calls = Calls()
        calls.wire(m)
        m.setVisible(true)
        for _ in 0..<10 {
            XCTAssertTrue(AgentsNSWindow.layoutKey(layoutKeyEvent(18, [.control], "1"), m, responder: .terminal))
            XCTAssertEqual(m.layout.id, gone.id)
            XCTAssertTrue(AgentsNSWindow.layoutKey(layoutKeyEvent(48, [.control], "\t"), m, responder: .terminal))
            XCTAssertEqual(m.layout.id, live.id)
        }
        XCTAssertEqual(opened, 0, "no open")
        XCTAssertTrue(calls.all.isEmpty && calls.records.isEmpty, "no restart, stop, kill, resume or History verb")
        XCTAssertTrue(m.newSession == nil, "no New session form")
        XCTAssertEqual(m.layoutWrites, 20, "one write per switch")
    }

    /// R901-s2-q1: one Character keeps at most Theme's per-Character scalar cap (ThemeVariant.labelCharScalarMax) before
    /// the 64-character cut; a cut chain ends on no joiner. A family emoji (skin tones too) and a flag stay whole; 64
    /// ordinary characters are unchanged.
    func testAgentWindowLayoutKeysNameCapsScalarsPerCharacter() throws {
        let cap = ThemeVariant.labelCharScalarMax
        let woman = "\u{1F469}", zwj = "\u{200D}"
        let chain = "\u{61}" + String(repeating: zwj + woman, count: 100)   // "a", then one 199-scalar Character
        let out = try XCTUnwrap(PaneLayoutStore.cleanName(chain))
        XCTAssertEqual(out.first, "\u{61}")
        XCTAssertTrue(out.allSatisfy { $0.unicodeScalars.count <= cap }, "every Character at most \(cap) scalars")
        XCTAssertLessThanOrEqual(out.unicodeScalars.count, 1 + cap)
        XCTAssertNotEqual(out.unicodeScalars.last, "\u{200D}", "no dangling joiner")
        let whole = woman + String(repeating: zwj + woman, count: 199)
        XCTAssertTrue((PaneLayoutStore.cleanName(whole) ?? "").allSatisfy { $0.unicodeScalars.count <= cap }, "one grapheme")
        let family = "\u{1F469}\u{1F3FD}\u{200D}\u{1F469}\u{1F3FD}\u{200D}\u{1F467}\u{1F3FD}\u{200D}\u{1F466}\u{1F3FD}"
        XCTAssertEqual(PaneLayoutStore.cleanName(family), family, "11 scalars: whole")
        XCTAssertEqual(PaneLayoutStore.cleanName("\u{1F1E7}\u{1F1EC}"), "\u{1F1E7}\u{1F1EC}", "a flag: whole")
        let plain = String(repeating: "ab", count: 32)
        XCTAssertEqual(PaneLayoutStore.cleanName(plain), plain)
    }

    // MARK: #901 B3 step 4a riders on the keys

    @MainActor
    private func repeatKey(_ code: UInt16, _ chars: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: true, keyCode: code)!
    }

    /// R901-s3-a: a HELD ⌃Tab repeats; each repeat is consumed and does nothing (no flip, no write), as the route does
    /// for a held ⌘N. A held ⌃digit repeats onto the layout its first press made active: a no-op, no write.
    @MainActor
    func testAgentWindowLayoutKeysRepeatIsConsumedAndDoesNothing() throws {
        gate(true)
        let a = paneLayout([paneTarget("a")]), b = paneLayout([paneTarget("b")])
        let (d, _) = try keysSuite([a, b], active: a.id)
        let m = windowModel(store([session("a", .idle), session("b", .idle)]), layouts: d)
        defer { m.close() }
        m.setVisible(true)
        XCTAssertTrue(AgentsNSWindow.layoutKey(layoutKeyEvent(48, [.control], "\t"), m, responder: .terminal), "a lone MRU")
        XCTAssertTrue(AgentsNSWindow.layoutKey(layoutKeyEvent(19, [.control], "2"), m, responder: .terminal))
        XCTAssertEqual(m.layout.id, b.id)
        XCTAssertEqual(m.layoutWrites, 1)
        for _ in 0..<3 {
            XCTAssertTrue(AgentsNSWindow.layoutKey(repeatKey(19, "2"), m, responder: .terminal), "a held ⌃2: consumed")
        }
        XCTAssertEqual(m.layout.id, b.id)
        XCTAssertEqual(m.layoutWrites, 1, "a held ⌃2 writes nothing")
        XCTAssertTrue(AgentsNSWindow.layoutKey(layoutKeyEvent(48, [.control], "\t"), m, responder: .terminal))
        XCTAssertEqual(m.layout.id, a.id, "the first ⌃Tab flips")
        XCTAssertEqual(m.layoutWrites, 2)
        for _ in 0..<3 {
            XCTAssertTrue(AgentsNSWindow.layoutKey(repeatKey(48, "\t"), m, responder: .terminal), "a held ⌃Tab: consumed")
        }
        XCTAssertEqual(m.layout.id, a.id, "a repeat flips nothing")
        XCTAssertEqual(m.layoutWrites, 2, "a repeat writes nothing")
    }

    /// R901-s3-b: the New session form keeps the layout keys (false: the key travels on to the form), nothing switched or
    /// written. The rename field's half is left out: renameEdit is set only inside the rename verb's path
    /// (AgentWindowModel.ask/rename), which a row may not run (report.txt item 1).
    @MainActor
    func testAgentWindowLayoutKeysStandDownForTheNewSessionForm() throws {
        gate(true)
        try withNewSessionPrefs {
            Preferences.agentIslandNewSessionCommand = "claude"   // typed: the form asks the island nothing
            let a = paneLayout([paneTarget("a")]), b = paneLayout([paneTarget("b")])
            let (d, bytes) = try keysSuite([a, b], active: a.id)
            let st = store([session("a", .idle), session("b", .idle)])
            st.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 46, 1])   // a value: the form's gate, never run
            let m = windowModel(st, layouts: d)
            defer { m.close() }
            m.home = "/Users/example"
            m.spawnSession = { _, _, _, _ in XCTFail("no spawn"); return nil }   // main actor (the model calls it)
            m.setVisible(true)
            m.openNewSession()
            XCTAssertTrue(m.newSession != nil, "the form is open")
            for e in [layoutKeyEvent(19, [.control], "2"), layoutKeyEvent(48, [.control], "\t")] {
                XCTAssertFalse(AgentsNSWindow.layoutKey(e, m, responder: .text), "\(e.keyCode): the form keeps it")
            }
            XCTAssertEqual(m.layout.id, a.id)
            XCTAssertEqual(m.layoutWrites, 0)
            XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), bytes)
        }
    }

    /// R901-s3-c: a built mouse-down (never posted) handed to layoutKey: false, nothing switched or written; nothing a
    /// mouse event lacks is read from it (a key-only property would raise here).
    @MainActor
    func testAgentWindowLayoutKeysIgnoreAMouseEvent() throws {
        gate(true)
        let a = paneLayout([paneTarget("a")]), b = paneLayout([paneTarget("b")])
        let (d, _) = try keysSuite([a, b], active: a.id)
        let m = windowModel(store([session("a", .idle), session("b", .idle)]), layouts: d)
        defer { m.close() }
        m.setVisible(true)
        for flags: NSEvent.ModifierFlags in [[], [.control]] {
            let e = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            for r: AgentsNSWindow.ResponderKind in [.text, .terminal, .other] {
                XCTAssertFalse(AgentsNSWindow.layoutKey(e, m, responder: r), "\(flags.rawValue) \(r)")
            }
        }
        XCTAssertEqual(m.layout.id, a.id)
        XCTAssertEqual(m.layoutWrites, 0)
    }

    /// R901-s3-q1: cleanName's SECOND pass. After the per-Character cut, 16 leading consonants re-join the next syllable
    /// into a 17-scalar Character; the second pass stops the name there, so every Character keeps at most the cap.
    func testAgentWindowLayoutKeysNameSecondCapHoldsAfterRejoin() {
        let cap = ThemeVariant.labelCharScalarMax
        let raw = String(repeating: "\u{1100}", count: 200) + "\u{1161}" + "\u{AC00}" + "x"
        let out = PaneLayoutStore.cleanName(raw) ?? ""   // the stop may leave nothing: automatic, still bounded
        XCTAssertTrue(out.allSatisfy { $0.unicodeScalars.count <= cap }, "every Character at most \(cap) scalars")
    }

    /// R901-s3-b, the rename half (#901 B3 step 4b): while the inline LAYOUT rename field is open, and while the SESSION
    /// rename field is open (its own state, set through the openRenameField seam: no ask, no select, no verb), layoutKey
    /// returns false and consumes nothing: nothing switched or written. With both closed the same key switches.
    /// GUARD layout-keys-ignore-the-rename-field.
    @MainActor
    func testAgentWindowLayoutKeysStandDownForTheRenameFields() throws {
        gate(true)
        let a = paneLayout([paneTarget("a")]), b = paneLayout([paneTarget("b")])
        let (d, bytes) = try keysSuite([a, b], active: a.id)
        let m = windowModel(store([session("a", .idle), session("b", .idle)]), layouts: d)
        defer { m.close() }
        m.setVisible(true)
        let keys = [layoutKeyEvent(19, [.control], "2"), layoutKeyEvent(48, [.control], "\t")]
        m.beginLayoutRename(a.id)
        XCTAssertEqual(m.layoutRenaming, a.id, "the layout field is open")
        for e in keys {
            for r: AgentsNSWindow.ResponderKind in [.text, .terminal, .other] {
                XCTAssertFalse(AgentsNSWindow.layoutKey(e, m, responder: r), "\(e.keyCode) \(r): the layout field keeps it")
            }
        }
        m.endLayoutRename(a.id, nil)
        m.openRenameField(AgentRenameEdit(key: AgentSessionKey(dir: "/tmp/dch-test", name: "a"), text: ""))
        XCTAssertTrue(m.renaming != nil, "the session field is open")
        for e in keys {
            XCTAssertFalse(AgentsNSWindow.layoutKey(e, m, responder: .text), "\(e.keyCode): the session field keeps it")
        }
        XCTAssertEqual(m.layout.id, a.id)
        XCTAssertEqual(m.layoutWrites, 0)
        XCTAssertEqual(d.data(forKey: "agentWindowLayouts"), bytes)
        let closed = windowModel(store([session("a", .idle), session("b", .idle)]), layouts: d)
        defer { closed.close() }
        closed.setVisible(true)
        XCTAssertTrue(AgentsNSWindow.layoutKey(try XCTUnwrap(keys.first), closed, responder: .text), "no field: the key switches")
        XCTAssertEqual(closed.layout.id, b.id)
    }
}
