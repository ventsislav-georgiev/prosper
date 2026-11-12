import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #847 P1b: the New session form and the title row's [>_] New shell and [+] New session, wired into the Agent
/// Sessions window. Offscreen only: an AgentsNSWindow (or the real window from makeWindow) that is never shown,
/// ordered or made key; keys are built events handed to performKeyEquivalent; views render through NSHostingViews
/// into bitmaps at an explicit backing scale (1 is CI's runner, 2 is Retina). No dch runs: the spawn is
/// `spawnSession`'s recorder and the terminal is the fake one. No menu, panel, pasteboard or defaults write.
extension AgentWindowD1Tests {

    // MARK: Helpers

    @MainActor
    func wiringKey(_ win: NSWindow, _ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: win.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @MainActor func cmdN(_ win: NSWindow) -> NSEvent { wiringKey(win, 45, "n", .command) }
    @MainActor func shiftCmdN(_ win: NSWindow) -> NSEvent { wiringKey(win, 45, "N", [.command, .shift]) }
    @MainActor func esc(_ win: NSWindow) -> NSEvent { wiringKey(win, 53, "\u{1B}") }

    /// An auto-repeat keyDown of `e` (the key held).
    @MainActor
    func held(_ e: NSEvent, _ win: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: e.modifierFlags, timestamp: 0, windowNumber: win.windowNumber,
                         context: nil, characters: e.characters ?? "", charactersIgnoringModifiers: e.charactersIgnoringModifiers ?? "",
                         isARepeat: true, keyCode: e.keyCode)!
    }

    /// The form's text fields (Folder, Name, Command), top to bottom.
    @MainActor
    func formFields(_ host: NSView) -> [NSTextField] {
        focusViews(host, NSTextField.self).filter(\.isEditable)
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }

    /// `f` has the keys: its field editor is the window's first responder.
    @MainActor
    func hasKeys(_ f: NSTextField, _ win: NSWindow) -> Bool {
        f.currentEditor().map { win.firstResponder === $0 } ?? false
    }

    /// The prefs every test here starts from: a typed command (no inference), a last folder that exists.
    @MainActor
    func wiringModel(_ st: AgentIslandStore, _ spawns: SpawnCalls) -> AgentWindowModel {
        Preferences.agentIslandNewSessionCommand = "claude"
        Preferences.agentWindowNewSessionFolder = "/Users/example/api"
        return newSessionModel(st, spawns)
    }

    /// `view` over a black canvas, drawn into a bitmap at `backing` (never in a window).
    @MainActor
    func wiringRender<V: View>(_ view: V, _ size: CGSize, backing: CGFloat) throws -> NSBitmapImageRep {
        let h = NSHostingView(rootView: ZStack(alignment: .topLeading) {
            Color.black
            view
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark))
        h.frame = CGRect(origin: .zero, size: size)
        h.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        h.layoutSubtreeIfNeeded()
        h.displayIfNeeded()
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((size.width * backing).rounded()), pixelsHigh: Int((size.height * backing).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        h.cacheDisplay(in: h.bounds, to: rep)
        return rep
    }

    /// The backing-pixel rect of `r` (points, top-left origin), clamped to the bitmap.
    func pixels(_ rep: NSBitmapImageRep, _ r: CGRect) -> (x: Range<Int>, y: Range<Int>) {
        let s = CGFloat(rep.pixelsWide) / rep.size.width
        let x0 = max(0, Int((r.minX * s).rounded())), x1 = min(rep.pixelsWide, Int((r.maxX * s).rounded()))
        let y0 = max(0, Int((r.minY * s).rounded())), y1 = min(rep.pixelsHigh, Int((r.maxY * s).rounded()))
        return (x0..<max(x0, x1), y0..<max(y0, y1))
    }

    /// The raw RGBA bytes of `r`, row by row (two renders compare byte for byte).
    func regionBytes(_ rep: NSBitmapImageRep, _ r: CGRect) -> [UInt8] {
        let (xs, ys) = pixels(rep, r)
        guard let data = rep.bitmapData else { return [] }
        var out: [UInt8] = []
        for y in ys { for x in xs { for c in 0..<4 { out.append(data[y * rep.bytesPerRow + x * 4 + c]) } } }
        return out
    }

    /// The bounding box (points) of every pixel in `r` brighter than `above` (the black canvas is 0); nil: none.
    func ink(_ rep: NSBitmapImageRep, _ r: CGRect, above: UInt8 = 15) -> CGRect? {
        let (xs, ys) = pixels(rep, r)
        guard let data = rep.bitmapData else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in ys {
            for x in xs {
                let i = y * rep.bytesPerRow + x * 4
                if max(data[i], data[i + 1], data[i + 2]) > above {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        let s = CGFloat(rep.pixelsWide) / rep.size.width
        return CGRect(x: CGFloat(minX) / s, y: CGFloat(minY) / s, width: CGFloat(maxX - minX + 1) / s, height: CGFloat(maxY - minY + 1) / s)
    }

    /// R2 F6b: the ink of a dimmed render (`dim`) at the lit threshold scaled by the dimming (the regions' peaks):
    /// the same pixels as `ink(lit, r)`.
    func dimmedInk(_ dim: NSBitmapImageRep, lit: NSBitmapImageRep, _ r: CGRect) -> CGRect? {
        func peak(_ rep: NSBitmapImageRep) -> Int {
            let (xs, ys) = pixels(rep, r)
            guard let d = rep.bitmapData else { return 0 }
            var m = 0
            for y in ys { for x in xs { let i = y * rep.bytesPerRow + x * 4; m = max(m, Int(max(d[i], d[i + 1], d[i + 2]))) } }
            return m
        }
        let l = peak(lit)
        return ink(dim, r, above: UInt8(l == 0 ? 15 : 15 * peak(dim) / l))
    }

    func assertRect(_ a: CGRect?, _ b: CGRect?, accuracy: CGFloat, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let a, let b else { return XCTFail("\(what): \(String(describing: a)) vs \(String(describing: b))", file: file, line: line) }
        for (x, y) in [(a.minX, b.minX), (a.minY, b.minY), (a.width, b.width), (a.height, b.height)] {
            XCTAssertEqual(x, y, accuracy: accuracy, "\(what): \(a) vs \(b)", file: file, line: line)
        }
    }

    // MARK: Keys

    /// M9, w3, r1: ⌘N and ⇧⌘N are the window's from every responder (a text field, the form's own fields among them, the
    /// terminal, the sidebar), in both modes; a rename field keeps them (.pass), as it keeps every key but ⌘W.
    @MainActor
    func testAgentWindowNewSessionKeysRouteFromEveryResponderButNotWhileRenaming() {
        let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        for r: AgentsNSWindow.ResponderKind in [.text, .terminal, .other] {
            for terminal in [true, false] {
                for sidebar in [true, false] {
                    let tag = "\(r) terminal \(terminal) sidebar \(sidebar)"
                    XCTAssertEqual(AgentsNSWindow.route(cmdN(win), responder: r, sidebarFocused: sidebar, terminalMode: terminal),
                                   .newSession, tag)
                    XCTAssertEqual(AgentsNSWindow.route(shiftCmdN(win), responder: r, sidebarFocused: sidebar, terminalMode: terminal),
                                   .newShell, tag)
                    XCTAssertEqual(AgentsNSWindow.route(cmdN(win), responder: r, sidebarFocused: sidebar, terminalMode: terminal,
                                                        renaming: true), .pass, "renaming: the field's \(tag)")
                    XCTAssertEqual(AgentsNSWindow.route(shiftCmdN(win), responder: r, sidebarFocused: sidebar, terminalMode: terminal,
                                                        renaming: true), .pass, "renaming: the field's \(tag)")
                    // R2 F1: a held chord's auto-repeats are the window's and do nothing; renaming, the field's.
                    for e in [cmdN(win), shiftCmdN(win)].map({ held($0, win) }) {
                        XCTAssertTrue(e.isARepeat)
                        XCTAssertEqual(AgentsNSWindow.route(e, responder: r, sidebarFocused: sidebar, terminalMode: terminal),
                                       .swallow, "repeat \(e.modifierFlags) \(tag)")
                        XCTAssertEqual(AgentsNSWindow.route(e, responder: r, sidebarFocused: sidebar, terminalMode: terminal,
                                                            renaming: true), .pass, "repeat renaming \(tag)")
                    }
                    // Other modifiers on N stay the responder's.
                    for flags: NSEvent.ModifierFlags in [[.command, .option], [.command, .control], [], [.shift]] {
                        XCTAssertEqual(AgentsNSWindow.route(wiringKey(win, 45, "n", flags), responder: r, sidebarFocused: false,
                                                            terminalMode: terminal), .pass, "\(flags) \(tag)")
                    }
                }
            }
        }
    }

    /// ⌘N opens the form (performKeyEquivalent, handled); the Name field has the keys; a second ⌘N with the keys in
    /// Command brings them back to Name and opens nothing new.
    @MainActor
    func testAgentWindowNewSessionCmdNOpensTheFormAndAgainFocusesName() throws {
        try withNewSessionPrefs {
            let a = mapped("a"), spawns = SpawnCalls(), m = wiringModel(store([a]), spawns)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            m.select(.live(a.key))
            settle(host)
            XCTAssertTrue(formFields(host).isEmpty, "no form yet")
            XCTAssertTrue(win.performKeyEquivalent(with: cmdN(win)))
            settle(host)
            let form = try XCTUnwrap(m.newSession)
            XCTAssertEqual(form.folder, "~/api")
            let fields = formFields(host)
            XCTAssertEqual(fields.count, 3, "Folder, Name, Command in the detail pane")
            guard fields.count == 3 else { return }
            XCTAssertEqual(fields[1].stringValue, "api", "the free name")
            XCTAssertTrue(hasKeys(fields[1], win), "Name has the keys on open")
            XCTAssertTrue(win.makeFirstResponder(fields[2]))
            settle(host)
            XCTAssertTrue(hasKeys(fields[2], win))
            XCTAssertEqual(win.responderKind, .text)
            XCTAssertTrue(win.performKeyEquivalent(with: cmdN(win)), "⌘N from the form's own field")
            settle(host)
            XCTAssertEqual(m.newSession?.folder, form.folder, "the same form")
            XCTAssertTrue(hasKeys(formFields(host)[1], win), "⌘N again: Name has the keys")
            XCTAssertEqual(spawns.calls.count, 0)
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// Esc is the form's Cancel (.cancelAction), through the window's key path; Return in Name starts through the
    /// spawn seam; ⇧⌘N with no form starts the quick shell through the same seam and shows no form.
    @MainActor
    func testAgentWindowNewSessionEscCancelsReturnStartsAndShiftCmdNStartsAShell() throws {
        try withNewSessionPrefs {
            let a = mapped("a"), spawns = SpawnCalls(), m = wiringModel(store([a]), spawns)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            m.select(.live(a.key))
            settle(host)
            XCTAssertTrue(win.performKeyEquivalent(with: cmdN(win)))
            settle(host)
            XCTAssertNotNil(m.newSession)
            XCTAssertTrue(win.performKeyEquivalent(with: esc(win)), "Esc is the Cancel button's")
            settle(host)
            XCTAssertNil(m.newSession, "Esc cancelled")
            XCTAssertTrue(formFields(host).isEmpty, "the pane is back")
            XCTAssertEqual(spawns.calls.count, 0)
            // Return in Name.
            XCTAssertTrue(win.performKeyEquivalent(with: cmdN(win)))
            settle(host)
            let name = try XCTUnwrap(formFields(host).dropFirst().first)
            if !hasKeys(name, win) { XCTAssertTrue(win.makeFirstResponder(name)) }
            let editor = try XCTUnwrap(name.currentEditor() as? NSTextView)
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertEqual(spawns.calls.count, 1, "Return started")
            XCTAssertEqual(spawns.calls.first?.folder, "/Users/example/api")
            XCTAssertEqual(spawns.calls.first?.argv, ["claude"])
            XCTAssertEqual(spawns.calls.first?.name, "api")
            XCTAssertNotNil(m.newSession?.starting, "Starting…")
            spawns.done[0](nil, "New session failed: test")
            m.cancelNewSession()
            settle(host)
            // ⇧⌘N: no form, the login shell at once.
            XCTAssertTrue(win.performKeyEquivalent(with: shiftCmdN(win)))
            settle(host)
            XCTAssertNil(m.newSession, "no form")
            XCTAssertTrue(formFields(host).isEmpty)
            XCTAssertEqual(spawns.calls.count, 2)
            XCTAssertEqual(spawns.calls.last?.argv, ["/bin/fish", "-l"])
            XCTAssertEqual(spawns.calls.last?.folder, "/Users/example/api")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// w4: the gate refusing. ⌘N and ⇧⌘N are still handled (true: no beep, nothing passed on) and do nothing; the
    /// buttons stay in their slots, dimmed, with the reason as their tooltip.
    @MainActor
    func testAgentWindowNewSessionGateRefusedKeysDoNothingAndButtonsDimInPlace() throws {
        try withNewSessionPrefs {
            let st = store([mapped("a")]), spawns = SpawnCalls(), m = wiringModel(st, spawns)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            let size = CGSize(width: sz(290), height: sz(80))
            let open = try wiringRender(AgentSidebarTitleRow(model: m), size, backing: 2)
            st.controlDch = nil
            let why = try XCTUnwrap(st.resumeGate.refusal)
            settle(host)
            XCTAssertTrue(win.performKeyEquivalent(with: cmdN(win)), "handled: no beep")
            XCTAssertTrue(win.performKeyEquivalent(with: shiftCmdN(win)), "handled: no beep")
            settle(host)
            XCTAssertNil(m.newSession, "⌘N opened nothing")
            XCTAssertEqual(spawns.calls.count, 0, "⇧⌘N started nothing")
            XCTAssertEqual(AgentNewSessionButtons.help("New session… (⌘N)", refusal: why), "Controls \(why)")
            XCTAssertEqual(AgentNewSessionButtons.help("New shell (⇧⌘N)", refusal: why), "Controls \(why)")
            XCTAssertEqual(AgentNewSessionButtons.help("New shell (⇧⌘N)", refusal: nil), "New shell (⇧⌘N)")
            let shut = try wiringRender(AgentSidebarTitleRow(model: m), size, backing: 2)
            let slot = CGRect(x: sz(290 - 14 - 40) - 2, y: 0, width: sz(40) + 4, height: size.height)
            // R2 F6b: dimmed over black, the lit threshold scales with the dimming: the same pixels, one backing pixel.
            assertRect(dimmedInk(shut, lit: open, slot), ink(open, slot), accuracy: 0.5, "dimmed in the same place")
            XCTAssertNotEqual(regionBytes(shut, slot), regionBytes(open, slot), "dimmed")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    // MARK: The title row

    /// w1, r7: at UI scale 1.0, 0.85 and 0.7 and backing 1 and 2, with 0, 1 and 999 sessions, the two buttons are sz(18)
    /// squares in the same pixels at the row's trailing edge, and the row keeps its height. The count gives way first:
    /// in a narrow sidebar it is cut while the buttons stay pixel-identical and the title keeps its ink box.
    @MainActor
    func testAgentWindowNewSessionTitleRowButtonsKeepTheirSlots() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        try withNewSessionPrefs {
            for scale: CGFloat in [1.0, 0.85, 0.7] {
                ThemeRuntime.scale = scale
                let models = [0, 1, 999].map { n in
                    wiringModel(store((0..<n).map { session("s\($0)", .idle, ago: TimeInterval(60 + $0)) }), SpawnCalls())
                }
                defer { models.forEach { $0.close() } }
                XCTAssertEqual(models.map { $0.sections.flatMap(\.rows).count }, [0, 1, 999])
                let st0 = try XCTUnwrap(models[0].store)
                let pair = NSHostingView(rootView: AgentNewSessionButtons(model: models[0], store: st0)).fittingSize
                XCTAssertEqual(pair.width, 2 * sz(18) + sz(4), accuracy: 0.5, "two sz(18) slots at \(scale)")
                // fittingSize comes back rounded to whole points (a hosting view outside a window lays out at backing 1).
                XCTAssertEqual(pair.height, sz(18), accuracy: 1, "at \(scale)")
                let heights = models.map { NSHostingView(rootView: AgentSidebarTitleRow(model: $0).frame(width: sz(290))).fittingSize.height }
                XCTAssertEqual(Set(heights).count, 1, "one row height for 0, 1 and 999 at \(scale): \(heights)")
                for h in heights { XCTAssertEqual(h, sz(30) + sz(18) + sz(8), accuracy: 1, "row height at \(scale): \(heights)") }
                for backing: CGFloat in [1, 2] {
                    let tol = 1 / backing
                    let tag = "scale \(scale) backing \(backing)"
                    let full = CGSize(width: sz(290), height: sz(70))
                    let reps = try models.map { try wiringRender(AgentSidebarTitleRow(model: $0), full, backing: backing) }
                    let slot = CGRect(x: full.width - sz(14) - sz(40), y: sz(30), width: sz(40), height: sz(18))
                    let wide = slot.insetBy(dx: -sz(3), dy: -sz(3))
                    for (i, r) in reps.enumerated() {
                        XCTAssertEqual(regionBytes(r, wide), regionBytes(reps[0], wide), "the buttons' pixels with \([0, 1, 999][i]) \(tag)")
                        let left = try XCTUnwrap(ink(r, CGRect(x: slot.minX, y: slot.minY, width: sz(18), height: sz(18))), ">_ \(tag)")
                        let right = try XCTUnwrap(ink(r, CGRect(x: slot.maxX - sz(18), y: slot.minY, width: sz(18), height: sz(18))), "+ \(tag)")
                        XCTAssertGreaterThan(left.width, tol, tag)
                        XCTAssertGreaterThan(right.width, tol, tag)
                        XCTAssertNil(ink(r, CGRect(x: full.width - sz(14) + tol, y: 0, width: sz(14), height: full.height)),
                                     "nothing in the trailing padding \(tag)")
                    }
                    // The count's ink: none with 0 sessions, then wider for 999 than for 1.
                    let gap = CGRect(x: sz(130), y: sz(26), width: slot.minX - sz(2) - sz(130), height: sz(26))
                    XCTAssertNil(ink(reps[0], gap), "no count with 0 sessions \(tag)")
                    let c1 = try XCTUnwrap(ink(reps[1], gap), tag), c999 = try XCTUnwrap(ink(reps[2], gap), tag)
                    XCTAssertGreaterThan(c999.width, c1.width, tag)
                    // A narrow sidebar: the title and the buttons as they were, the count cut.
                    let narrow = CGSize(width: sz(205), height: sz(70))
                    let n0 = try wiringRender(AgentSidebarTitleRow(model: models[0]), narrow, backing: backing)
                    let n999 = try wiringRender(AgentSidebarTitleRow(model: models[2]), narrow, backing: backing)
                    let nslot = CGRect(x: narrow.width - sz(14) - sz(40), y: sz(30), width: sz(40), height: sz(18)).insetBy(dx: -sz(3), dy: -sz(3))
                    // R2 F6a (r7): the overlay's frame is the width offered, whatever the cut count: the same pixels.
                    XCTAssertEqual(regionBytes(n999, nslot), regionBytes(n0, nslot), "the buttons stay \(tag)")
                    XCTAssertNotNil(ink(n0, nslot), "the buttons drawn \(tag)")
                    let title = try XCTUnwrap(ink(n0, CGRect(x: 0, y: 0, width: nslot.minX, height: narrow.height)), "title \(tag)")
                    let titleBox = CGRect(x: 0, y: 0, width: title.maxX + tol, height: narrow.height)
                    assertRect(ink(n999, titleBox), title, accuracy: tol, "the title stays whole \(tag)")
                    assertRect(ink(reps[0], titleBox), title, accuracy: tol, "and as wide as in the full row \(tag)")
                    let cut = try XCTUnwrap(ink(n999, CGRect(x: titleBox.maxX + tol, y: 0, width: nslot.minX - titleBox.maxX - tol,
                                                             height: narrow.height)), "a cut count shows \(tag)")
                    XCTAssertLessThan(cut.width, c999.width - sz(6), "the count gave way \(tag)")
                }
            }
        }
    }

    /// Item 1 (#860's chrome kept): in the real window (built, never shown) the title row sits in the content area
    /// under the title bar band, the window does not move by its background, and a point on each button hits the
    /// SwiftUI host, not a drag handle: a click there is the button's, never a window drag. (A built mouse event never
    /// reaches a SwiftUI button in a window that was never shown, so the action itself is not driven here.)
    @MainActor
    func testAgentWindowNewSessionButtonsSitOutsideTheDragRegion() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        try withNewSessionPrefs {
            for scale: CGFloat in [1.0, 0.7] {
                ThemeRuntime.scale = scale
                let m = wiringModel(store([mapped("a")]), SpawnCalls())
                defer { m.close() }
                let win = AgentsWindow.makeWindow(m, autosave: nil)
                defer { win.contentViewController = nil }
                let cv = try XCTUnwrap(win.contentView)
                cv.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                cv.layoutSubtreeIfNeeded()
                XCTAssertFalse(win.isMovableByWindowBackground, "the body never drags the window")
                XCTAssertFalse(win.styleMask.contains(.fullSizeContentView), "the content starts under the title bar")
                let content = win.contentLayoutRect
                XCTAssertGreaterThan(win.frame.height - content.maxY, 0, "a title bar band above the content")
                for (i, x) in [sz(290 - 14 - 40), sz(290 - 14 - 18)].enumerated() {
                    let button = CGRect(x: x, y: content.maxY - sz(30) - sz(18), width: sz(18), height: sz(18))
                    XCTAssertTrue(content.contains(button), "button \(i) in the content at \(scale): \(button) in \(content)")
                    let hit = try XCTUnwrap(cv.hitTest(try XCTUnwrap(cv.superview).convert(NSPoint(x: button.midX, y: button.midY), from: nil)),
                                            "button \(i) hits a view at \(scale)")
                    XCTAssertTrue(hit.isDescendant(of: cv), "the content's, not the frame's")
                    XCTAssertFalse(hit is WindowDragHandleView)
                    XCTAssertFalse(sequence(first: hit, next: \.superview).contains { $0 is WindowDragHandleView }, "no drag handle under it")
                }
                XCTAssertFalse(win.isVisible, "never shown")
            }
        }
    }

    // MARK: The form

    /// Item 7, M10: the form at the window's minimum content size at UI scale 1.0, 0.85 and 0.7: every field whole in
    /// the detail pane, nothing drawn into the pane's side padding (backing 1 and 2), and the same frames with no
    /// error, with a name error and while "Starting…" (every slot is there with or without text).
    @MainActor
    func testAgentWindowNewSessionFormFitsTheMinimumWindowWithFixedSlots() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        try withNewSessionPrefs {
            for scale: CGFloat in [1.0, 0.85, 0.7] {
                ThemeRuntime.scale = scale
                let spawns = SpawnCalls(), m = wiringModel(store([mapped("a")]), spawns)
                defer { m.close() }
                let size = AgentsWindow.contentMinSize(scale: scale)
                let win = AgentsNSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                win.isReleasedWhenClosed = false
                defer { win.close() }
                win.model = m
                let host = NSHostingView(rootView: AgentWindowRootView(model: m, scrolls: false))
                host.frame = CGRect(origin: .zero, size: size)
                win.contentView = host
                m.openNewSession()
                settle(host)
                let pane = CGRect(x: sz(290) + 1, y: 0, width: size.width - sz(290) - 1, height: size.height)
                @MainActor func frames(_ tag: String) -> [CGRect] {
                    let f = formFields(host).map { host.convert($0.bounds, from: $0) }
                    XCTAssertEqual(f.count, 3, tag)
                    for r in f {
                        XCTAssertGreaterThanOrEqual(r.minX, pane.minX + sz(20) + sz(64), "\(tag): right of the labels \(r)")
                        XCTAssertLessThanOrEqual(r.maxX, pane.maxX - sz(20) + 0.5, "\(tag): inside the padding \(r)")
                        XCTAssertGreaterThanOrEqual(r.width, sz(80), "\(tag): room to type \(r)")
                        XCTAssertTrue(host.bounds.contains(r), "\(tag): inside the window \(r)")
                    }
                    return f
                }
                @MainActor func height() -> CGFloat {
                    NSHostingView(rootView: AgentNewSessionView(model: m, form: m.newSession!).frame(width: pane.width)).fittingSize.height
                }
                let base = frames("no error \(scale)"), h = height()
                XCTAssertLessThanOrEqual(h, size.height, "the whole form fits the minimum height at \(scale)")
                for backing: CGFloat in [1, 2] {
                    let rep = try wiringRender(AgentNewSessionView(model: m, form: m.newSession!), pane.size, backing: backing)
                    let tol = 1 / backing
                    XCTAssertNil(ink(rep, CGRect(x: 0, y: 0, width: sz(20) - sz(4), height: pane.height)),
                                 "nothing in the leading padding at \(scale) backing \(backing)")
                    XCTAssertNil(ink(rep, CGRect(x: pane.width - sz(20) + sz(4) + tol, y: 0, width: sz(16), height: pane.height)),
                                 "nothing cut at the trailing edge at \(scale) backing \(backing)")
                }
                m.setNewSessionName("a:b")
                XCTAssertNotNil(m.newSessionErrors.name)
                settle(host)
                XCTAssertEqual(frames("name error \(scale)"), base, "a name error moves nothing at \(scale)")
                XCTAssertEqual(height(), h, accuracy: 0.01, "name error at \(scale)")
                m.setNewSessionName("")
                XCTAssertTrue(m.startNewSession())
                XCTAssertEqual(m.newSessionStatus, "Starting api…")
                settle(host)
                XCTAssertEqual(frames("starting \(scale)"), base, "Starting… moves nothing at \(scale)")
                XCTAssertEqual(height(), h, accuracy: 0.01, "the status slot is there with or without text at \(scale)")
            }
        }
    }

    // MARK: The terminal under the form

    /// Item 6, w5: the form opened over a selected live session in Terminal mode detaches its terminal (the view leaves
    /// the window); closing it re-attaches a fresh client and the keys land in it again: Cancel, Esc, and a Start
    /// that lands on another row. Opened from the sidebar (the keys not in the session), Cancel leaves them there.
    @MainActor
    func testAgentWindowNewSessionTerminalReattachesAndTakesTheKeysWhenTheFormCloses() throws {
        try withNewSessionPrefs {
            let a = mapped("a"), st = store([a]), spawns = SpawnCalls(), m = wiringModel(st, spawns)
            defer { m.close() }
            let t = fakeTerminal(m)   // a new log: a is attached already (0 here), each re-attach adds one
            let (win, host) = focusWindow(m)
            defer { win.close() }
            m.select(.live(a.key))
            settle(host)
            sidebarKeys(win)
            clickRow("a", m, win, host)
            XCTAssertEqual(m.terminal.phase, .live)
            XCTAssertTrue(win.firstResponder === m.terminal.view, "the keys in a's terminal")
            @MainActor func formOver(_ tag: String) {
                settle(host)
                XCTAssertEqual(formFields(host).count, 3, tag)
                XCTAssertNil(m.terminal.key, "\(tag): detached under the form")
                XCTAssertTrue(focusViews(host, AgentTerminalHostView.self).isEmpty, "\(tag): the terminal view left the window")
            }
            @MainActor func back(_ name: String, attaches: Int, keys: Bool, _ tag: String) {
                settle(host)
                XCTAssertTrue(formFields(host).isEmpty, tag)
                XCTAssertEqual(m.terminal.key?.name, name, "\(tag): attached")
                XCTAssertEqual(m.terminal.phase, .live, tag)
                XCTAssertEqual(t.spawned().count, attaches, "\(tag): a fresh client")
                let view = m.terminal.view
                XCTAssertNotNil(view?.window, "\(tag): the terminal view is back in the window")
                XCTAssertEqual(keys, view.map { win.firstResponder === $0 } ?? false, "\(tag): the keys")
                XCTAssertFalse(m.terminal.focusPending, "\(tag): nothing left pending")
            }
            // Cancel.
            m.openNewSession()
            formOver("cancel")
            m.cancelNewSession()
            back("a", attaches: 1, keys: true, "cancel")
            // Esc.
            XCTAssertTrue(win.performKeyEquivalent(with: cmdN(win)))
            formOver("esc")
            XCTAssertTrue(win.performKeyEquivalent(with: esc(win)))
            back("a", attaches: 2, keys: true, "esc")
            // Opened with the keys in the sidebar: Cancel re-attaches and leaves them there.
            sidebarKeys(win)
            m.openNewSession()
            formOver("sidebar")
            m.cancelNewSession()
            back("a", attaches: 3, keys: false, "sidebar")
            XCTAssertTrue(win.sidebarFocused)
            // Start lands on another row: its terminal, with the keys.
            clickRow("a", m, win, host)
            XCTAssertTrue(win.firstResponder === m.terminal.view)
            m.openNewSession(folder: "/Users/example/web")
            formOver("start")
            XCTAssertTrue(m.startNewSession())
            spawns.done[0](AgentSessionKey(dir: "/tmp/dch-test", name: "web"), nil)
            formOver("answered: the form waits for the row (R2 F5)")
            XCTAssertEqual(m.newSessionStatus, "Starting web…")
            XCTAssertEqual(t.spawned().count, 3, "no client for a while the row is not listed")
            st.sessions = [a, mapped("web")]
            XCTAssertEqual(m.selection, live("web"))
            back("web", attaches: 4, keys: true, "start")   // one new client: web's
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    // MARK: QA #736: the window's name claims

    /// (1) A spawn's name is claimed at once and stays claimed while the runner has not answered, however long that
    /// takes; (2) the answer re-stamps the claim at `now`: still taken at exactly spawnSlack, free just past it.
    @MainActor
    func testAgentWindowNewSessionClaimHoldsUntilTheAnswerThenExpiresAfterTheSlack() throws {
        try withNewSessionPrefs {
            final class Clock { var t: TimeInterval = 0 }
            let clock = Clock(), spawns = SpawnCalls(), m = wiringModel(store([]), spawns)
            defer { m.close() }
            clock.t = Self.now
            m.now = { clock.t }
            XCTAssertFalse(m.spawnTaken.contains("api"))
            XCTAssertTrue(m.startShell())
            XCTAssertEqual(spawns.calls.first?.name, "api")
            XCTAssertTrue(m.spawnTaken.contains("api"), "claimed at once")
            clock.t += 10 * AgentWindowModel.spawnSlack
            XCTAssertTrue(m.spawnTaken.contains("api"), "no answer yet: still claimed, past any slack")
            let answered = clock.t
            spawns.done[0](AgentSessionKey(dir: "/tmp/dch-test", name: "api"), nil)
            XCTAssertTrue(m.spawnTaken.contains("api"), "answered: claimed until the poll lists it")
            clock.t = answered + AgentWindowModel.spawnSlack
            XCTAssertTrue(m.spawnTaken.contains("api"), "re-stamped at the answer: still claimed at the slack")
            clock.t = answered + AgentWindowModel.spawnSlack + 1
            XCTAssertFalse(m.spawnTaken.contains("api"), "past the slack: free again")
        }
    }

    /// (3) The island turning off (bind(nil)) drops every claim: back on, the names are free.
    @MainActor
    func testAgentWindowNewSessionStoreGoneClearsEveryClaim() throws {
        try withNewSessionPrefs {
            let st = store([]), spawns = SpawnCalls(), m = wiringModel(st, spawns)
            defer { m.close() }
            XCTAssertTrue(m.startShell())
            Preferences.agentWindowNewSessionFolder = "/Users/example/web"
            XCTAssertTrue(m.startShell())
            spawns.done[1](AgentSessionKey(dir: "/tmp/dch-test", name: "web"), nil)
            XCTAssertTrue(m.spawnTaken.isSuperset(of: ["api", "web"]), "one in flight, one answered")
            m.bind(nil)
            m.bind(st)
            XCTAssertFalse(m.spawnTaken.contains("api"), "the in-flight claim went with the store")
            XCTAssertFalse(m.spawnTaken.contains("web"), "the answered claim too")
        }
    }

    // MARK: Round 2

    /// R2 F1 (r1): a held ⇧⌘N or ⌘N: the auto-repeats are handled (no beep) and start or open nothing more.
    @MainActor
    func testAgentWindowNewSessionHeldChordStartsOneShellAndOpensNoForm() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = wiringModel(store([mapped("a")]), spawns)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            settle(host)
            for _ in 0..<5 { XCTAssertTrue(win.performKeyEquivalent(with: held(shiftCmdN(win), win)), "handled: no beep") }
            XCTAssertEqual(spawns.calls.count, 0, "a repeat starts no shell")
            for _ in 0..<5 { XCTAssertTrue(win.performKeyEquivalent(with: held(cmdN(win), win)), "handled: no beep") }
            XCTAssertNil(m.newSession, "a repeat opens no form")
            XCTAssertTrue(win.performKeyEquivalent(with: shiftCmdN(win)))
            for _ in 0..<5 { XCTAssertTrue(win.performKeyEquivalent(with: held(shiftCmdN(win), win))) }
            XCTAssertEqual(spawns.calls.count, 1, "the chord held: one shell")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// R2 F2: the gate closes over an open form: it stays (Start and New shell refuse, the status says why), and
    /// ⌘N from Command still puts the keys in Name.
    @MainActor
    func testAgentWindowNewSessionGateClosingOverAnOpenFormKeepsItAndCmdNFocusesName() throws {
        try withNewSessionPrefs {
            let st = store([mapped("a")]), spawns = SpawnCalls(), m = wiringModel(st, spawns)
            defer { m.close() }
            let (win, host) = focusWindow(m)
            defer { win.close() }
            XCTAssertTrue(win.performKeyEquivalent(with: cmdN(win)))
            settle(host)
            guard formFields(host).count == 3 else { return XCTFail("the form") }
            XCTAssertTrue(win.makeFirstResponder(formFields(host)[2]))
            st.controlDch = nil
            let why = try XCTUnwrap(st.resumeGate.refusal)
            settle(host)
            XCTAssertTrue(win.performKeyEquivalent(with: cmdN(win)))
            settle(host)
            XCTAssertNotNil(m.newSession, "the form stays")
            let fields = formFields(host)
            XCTAssertEqual(fields.count, 3)
            XCTAssertTrue(fields.count == 3 && hasKeys(fields[1], win), "⌘N: Name has the keys")
            XCTAssertEqual(m.newSessionStatus, "Controls \(why)")
            XCTAssertFalse(m.canStartNewSession)
            XCTAssertFalse(m.startShell())
            XCTAssertEqual(spawns.calls.count, 0)
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// R2 F3a (r3), QA #736 INFO-3: the quick shell starts in a folder whose name dch refuses (id-shaped) and in a
    /// spawn dir with room for one character, under the stem "shell" (cut to the room), through the same claims.
    @MainActor
    func testAgentWindowNewSessionQuickShellFallsBackToTheShellStem() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = wiringModel(store([]), spawns)
            defer { m.close() }
            let dir = m.island().spawnDir(), idFolder = "/Users/example/m0123456789abcdef"
            XCTAssertEqual(AgentNewSession.nameError(AgentNewSession.autoName(folder: idFolder, taken: [], dir: dir), taken: [], dir: dir),
                           "Looks like a dch session id", "the folder's own name is refused")
            Preferences.agentWindowNewSessionFolder = idFolder
            XCTAssertTrue(m.startShell())
            XCTAssertTrue(m.startShell())
            XCTAssertEqual(spawns.calls.map(\.name), ["shell", "shell-2"])
            XCTAssertEqual(spawns.calls.map(\.folder), [idFolder, idFolder], "in that folder")
            // Room for one character: "a" first, then "a-2" does not fit: "s".
            let tiny = "/" + String(repeating: "d", count: 95)
            XCTAssertEqual(AgentNewSession.nameLimit(dir: tiny), 1)
            m.island().historyDirs = { [tiny] }
            Preferences.agentWindowNewSessionFolder = "/Users/example/api"
            XCTAssertTrue(m.startShell())
            XCTAssertTrue(m.startShell())
            XCTAssertEqual(spawns.calls.dropFirst(2).map(\.name), ["a", "s"])
            for n in spawns.calls.compactMap(\.name) {
                XCTAssertNil(AgentNewSession.nameError(n, taken: [], dir: n.count == 1 ? tiny : dir), n)
            }
        }
    }

    /// R2 F3b (r4): a nil spawn says why, re-checked in the island's order: the gate (the tooltip's words), the name
    /// (nameError's text), then the runner ("busy"). On the dir line with no form, in the status slot with one.
    @MainActor
    func testAgentWindowNewSessionRefusalNamesItsCause() throws {
        try withNewSessionPrefs {
            let st = store([]), spawns = SpawnCalls(), m = wiringModel(st, spawns)
            defer { m.close() }
            final class Effect { var run: @MainActor () -> Void = {} }
            let effect = Effect()
            m.spawnSession = { _, _, _, _ in MainActor.assumeIsolated { effect.run() }; return nil }
            let tiny = "/" + String(repeating: "d", count: 95)
            @MainActor func dirLine() -> String? { st.actions[AgentSessionKey(dir: m.island().spawnDir(), name: "")] }
            // The runner: busy.
            XCTAssertFalse(m.startShell())
            XCTAssertEqual(dirLine(), "api is busy: try again")
            m.openNewSession()
            XCTAssertFalse(m.startNewSession())
            XCTAssertEqual(m.newSessionStatus, "api is busy: try again")
            // The name: the spawn dir moved under the island between the window's check and its own.
            effect.run = { m.island().historyDirs = { [tiny] } }
            XCTAssertFalse(m.startNewSession())
            XCTAssertEqual(m.newSessionStatus, "1 character at most")
            m.island().historyDirs = { ["/tmp/dch-test"] }
            m.cancelNewSession()
            XCTAssertFalse(m.startShell())
            XCTAssertEqual(dirLine(), "1 character at most")
            // The gate: it closed between the window's check and the island's.
            m.island().historyDirs = { ["/tmp/dch-test"] }
            effect.run = { st.controlDch = nil }
            XCTAssertFalse(m.startShell())
            let why = try XCTUnwrap(st.resumeGate.refusal)
            XCTAssertEqual(dirLine(), "Controls \(why)")
            XCTAssertEqual(dirLine(), AgentNewSessionButtons.help("New shell (⇧⌘N)", refusal: why), "the tooltip's words")
            st.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 46, 1])
            m.openNewSession()
            XCTAssertFalse(m.startNewSession())
            XCTAssertEqual(m.newSession?.status, "Controls \(why)")
        }
    }

    /// R2 F3c (r8): the form's New shell dims in place exactly when Start does (a name error), nothing moves.
    @MainActor
    func testAgentWindowNewSessionFormNewShellDimsWithStart() throws {
        try withNewSessionPrefs {
            let st = store([]), spawns = SpawnCalls(), m = wiringModel(st, spawns)
            defer { m.close() }
            m.openNewSession()
            m.setNewSessionName("web")
            let size = CGSize(width: sz(560), height: sz(420))
            for backing: CGFloat in [1, 2] {
                st.sessions = []
                XCTAssertTrue(m.canStartNewSession)
                let ok = try wiringRender(AgentNewSessionView(model: m, form: m.newSession!), size, backing: backing)
                st.sessions = [session("web", .idle)]
                XCTAssertEqual(m.newSessionErrors.name, "web is taken")
                XCTAssertFalse(m.canStartNewSession)
                let bad = try wiringRender(AgentNewSessionView(model: m, form: m.newSession!), size, backing: backing)
                // Left of the fields only labels and the New shell pill are drawn; the labels are the same in both.
                let left = CGRect(x: 0, y: 0, width: sz(20) + sz(64), height: size.height)
                let ys = pixels(ok, left).y
                var rows: [Int] = []
                for y in ys {
                    let a = regionBytes(ok, CGRect(x: 0, y: CGFloat(y) / backing, width: left.width, height: 1 / backing))
                    if a != regionBytes(bad, CGRect(x: 0, y: CGFloat(y) / backing, width: left.width, height: 1 / backing)) { rows.append(y) }
                }
                let tag = "backing \(backing)"
                let first = try XCTUnwrap(rows.first, "New shell dimmed \(tag)"), last = rows.last ?? first
                let band = CGRect(x: 0, y: CGFloat(first) / backing, width: size.width, height: CGFloat(last - first + 1) / backing)
                XCTAssertGreaterThan(band.minY, sz(150), "the change is the pill row, under the fields \(tag)")
                XCTAssertLessThan(band.height, sz(30), "one row \(tag)")
                XCTAssertNotEqual(regionBytes(ok, CGRect(x: size.width / 2, y: band.minY, width: size.width / 2, height: band.height)),
                                  regionBytes(bad, CGRect(x: size.width / 2, y: band.minY, width: size.width / 2, height: band.height)),
                                  "Start dims in the same row \(tag)")
                let pill = CGRect(x: 0, y: band.minY - sz(4), width: left.width, height: band.height + sz(8))
                assertRect(dimmedInk(bad, lit: ok, pill), ink(ok, pill), accuracy: 1 / backing, "dimmed in place \(tag)")
            }
        }
    }

    /// R2 F4 (r5), QA #736 INFO-5: room for one character reads "1 character at most".
    func testAgentWindowNewSessionNameLimitOfOneIsSingular() {
        let one = "/" + String(repeating: "d", count: 95), two = "/" + String(repeating: "d", count: 94)
        XCTAssertEqual(AgentNewSession.nameLimit(dir: one), 1)
        XCTAssertEqual(AgentNewSession.nameError("ab", taken: [], dir: one), "1 character at most")
        XCTAssertNil(AgentNewSession.nameError("a", taken: [], dir: one))
        XCTAssertEqual(AgentNewSession.nameError("abc", taken: [], dir: two), "2 characters at most")
    }

    /// R2 F5 (r6): a Start whose row never lists: the form waits over the pane (no client for the old session),
    /// and after spawnSlack it goes as Cancel does: the old terminal attached again, the keys where they were.
    @MainActor
    func testAgentWindowNewSessionStartWhoseRowNeverListsClosesAfterTheSlack() throws {
        try withNewSessionPrefs {
            final class Clock { var t = AgentWindowD1Tests.now }
            let clock = Clock()
            let a = mapped("a"), st = store([a]), spawns = SpawnCalls(), m = wiringModel(st, spawns)
            defer { m.close() }
            m.now = { clock.t }
            let t = fakeTerminal(m)
            let (win, host) = focusWindow(m)
            defer { win.close() }
            m.select(.live(a.key))
            settle(host)
            sidebarKeys(win)
            clickRow("a", m, win, host)
            XCTAssertTrue(win.firstResponder === m.terminal.view, "the keys in a's terminal")
            m.openNewSession(folder: "/Users/example/web")
            XCTAssertTrue(m.startNewSession())
            spawns.done[0](AgentSessionKey(dir: "/tmp/dch-test", name: "web"), nil)
            settle(host)
            XCTAssertNil(m.terminal.key, "answered: nothing attached")
            XCTAssertEqual(formFields(host).count, 3, "the form waits over the pane")
            clock.t += AgentWindowModel.spawnSlack
            m.refresh()
            XCTAssertEqual(m.newSessionStatus, "Starting web…", "at the slack: still waiting")
            XCTAssertNil(m.terminal.key)
            XCTAssertEqual(t.spawned().count, 0, "no client while it waits")
            clock.t += 1
            m.refresh()
            settle(host)
            XCTAssertNil(m.newSession, "past the slack: the form goes")
            XCTAssertNil(m.pendingSpawn)
            XCTAssertEqual(m.terminal.key?.name, "a", "a's terminal again")
            XCTAssertEqual(t.spawned().count, 1, "one fresh client: a's")
            XCTAssertTrue(win.firstResponder === m.terminal.view, "the keys where they were")
            st.sessions = [a, mapped("web")]
            XCTAssertEqual(m.selection, .live(a.key), "a late row selects nothing")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// R2 F5: Cancel while the form waits for its row drops the pending pick; the island going off closes a form
    /// whose session started (nothing left to wait for).
    @MainActor
    func testAgentWindowNewSessionCancelOrStoreGoneWhileWaitingForTheRow() throws {
        try withNewSessionPrefs {
            let a = mapped("a"), st = store([a]), spawns = SpawnCalls(), m = wiringModel(st, spawns)
            defer { m.close() }
            m.select(.live(a.key))
            m.openNewSession(folder: "/Users/example/web")
            XCTAssertTrue(m.startNewSession())
            spawns.done[0](AgentSessionKey(dir: "/tmp/dch-test", name: "web"), nil)
            XCTAssertNotNil(m.pendingSpawn)
            m.cancelNewSession()
            XCTAssertNil(m.pendingSpawn, "Cancel drops the pending pick")
            st.sessions = [a, mapped("web")]
            XCTAssertEqual(m.selection, .live(a.key), "the row shows: nothing moves")
            m.openNewSession(folder: "/Users/example/api")
            XCTAssertTrue(m.startNewSession())
            spawns.done[1](AgentSessionKey(dir: "/tmp/dch-test", name: "api"), nil)
            XCTAssertNotNil(m.newSession)
            m.bind(nil)
            XCTAssertNil(m.newSession, "it started: the form goes, no failure text")
        }
    }
}
