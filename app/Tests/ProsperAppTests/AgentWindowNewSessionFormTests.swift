import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1370 (#847 P1d part 3): the New session form's Sidekick row, Prompt disclosure and editor, the New shell guard,
/// Command-Return on Start, and the unsent first message seeded at the failure. Offscreen only: an AgentsNSWindow that
/// is never shown, ordered or made key; the accessibility tree is read through AXTreeSupport (flags put back); keys
/// are built events handed to the editor's own keyDown, never posted. No dch runs: the spawn is `spawnSession`'s
/// recorder and the island's io is dch-lite. No pasteboard, menu or panel; Preferences are the XCTest store.
extension AgentWindowD1Tests {

    struct FormRows: Equatable {
        var start, cancel, shell, box: CGRect
    }

    /// The form alone (AgentDetailView, no ScrollView) in a never-shown AgentsNSWindow of `size`.
    @MainActor
    func formWindow(_ m: AgentWindowModel, _ size: CGSize) -> (AgentsNSWindow, NSView) {
        let win = AgentsNSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.model = m
        let host = NSHostingView(rootView: AgentDetailView(model: m, transcript: m.transcript, scrolls: false)
            .frame(width: size.width, height: size.height, alignment: .top).environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        return (win, host)
    }

    /// Start (or "Starting..."), Cancel, New shell and the Sidekick box, from the accessibility tree.
    @MainActor
    func formRows(_ host: NSView, starting: Bool = false) -> (rows: FormRows?, tree: [AXTreeNode]) {
        let startName = starting ? "Starting\u{2026}" : "Start"
        func pick(_ t: [AXTreeNode]) -> FormRows? {
            func button(_ n: String) -> CGRect? { t.last { $0.role == "AXButton" && $0.named(n) && $0.frame.width > 0 }?.frame }
            guard let s = button(startName), let c = button("Cancel"), let sh = button("New shell"),
                  let b = t.last(where: isBox)?.frame
            else { return nil }
            return FormRows(start: s, cancel: c, shell: sh, box: b)
        }
        settle(host)
        let tree = AXTreeSupport.poll(host) { pick($0) != nil }
        return (pick(tree), tree)
    }

    /// The Sidekick checkbox: not the field's "Sidekick" label text (SwiftUI may name it "Sidekick" or "Sidekick, ...").
    func isBox(_ n: AXTreeNode) -> Bool { n.role != "AXStaticText" && n.named(prefix: "Sidekick") && n.frame.width > 0 }

    @MainActor
    func assertRows(_ a: FormRows?, _ b: FormRows?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let a, let b else { return XCTFail("\(what): \(String(describing: a)) vs \(String(describing: b))", file: file, line: line) }
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        for (x, y, n) in [(a.start, b.start, "Start"), (a.cancel, b.cancel, "Cancel"), (a.shell, b.shell, "New shell"), (a.box, b.box, "Sidekick")] {
            assertRect(x, y, accuracy: pixel, "\(what): \(n)", file: file, line: line)
        }
    }

    // MARK: T29: fixed rows

    /// T29: at UI scale 1.0, 0.85 and 0.7, Start, Cancel, New shell and the Sidekick box keep their frames with the box
    /// on and no error, with a sidekick-only slot error (the name "api": its sidekick api-qa is taken), with both slots
    /// holding an error, and while "Starting..." shows.
    @MainActor
    func testAgentWindowNewSessionFormRowsHoldWithSlotErrorsAndStarting() {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        withNewSessionPrefs {
            for scale: CGFloat in [1.0, 0.85, 0.7] {
                ThemeRuntime.scale = scale
                let spawns = SpawnCalls(), m = wiringModel(store([mapped("a"), mapped("api-qa")]), spawns)
                defer { m.close() }
                let (win, host) = formWindow(m, CGSize(width: sz(560), height: sz(700)))
                defer { win.close() }
                m.openNewSession()
                m.setNewSessionSidekick(true)
                XCTAssertTrue(m.newSessionSidekickOn, "the box is on at \(scale)")
                let base = formRows(host)
                XCTAssertTrue(base.rows != nil, "every row is there at \(scale): \(base.tree.map(\.name))")
                m.setNewSessionName("api")
                XCTAssertTrue(m.newSessionErrors.name == nil && m.newSessionErrors.sidekick != nil, "the sidekick's slot only at \(scale)")
                assertRows(formRows(host).rows, base.rows, "sidekick slot error at \(scale)")
                m.setNewSessionName("a:b")
                XCTAssertTrue(m.newSessionErrors.name != nil && m.newSessionErrors.sidekick != nil, "both slots at \(scale)")
                assertRows(formRows(host).rows, base.rows, "both slot errors at \(scale)")
                m.setNewSessionName("")
                XCTAssertTrue(m.startNewSession())
                XCTAssertEqual(spawns.calls.count, 1)
                assertRows(formRows(host, starting: true).rows, base.rows, "Starting\u{2026} at \(scale)")
            }
        }
    }

    // MARK: T30: the one reflow

    /// T30: expanding the prompt grows the form by one delta, sz(96) + the column's sz(6); the form is centred (#1479), so
    /// Start, Cancel and New shell move down by half of it and the fields and the box up by half (was: down by all of it, nothing above moved); 12 typed lines keep the editor's frame; collapsing puts every row back.
    @MainActor
    func testAgentWindowNewSessionFormPromptOpensByOneFixedDeltaAndTypingKeepsTheEditor() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        try withNewSessionPrefs {
            for scale: CGFloat in [1.0, 0.85, 0.7] {
                ThemeRuntime.scale = scale
                let spawns = SpawnCalls(), m = wiringModel(store([mapped("a")]), spawns)
                defer { m.close() }
                let (win, host) = formWindow(m, CGSize(width: sz(560), height: sz(800)))
                defer { win.close() }
                m.openNewSession()
                XCTAssertEqual(m.newSession?.promptShown, false, "collapsed by default at \(scale)")
                let base = try XCTUnwrap(formRows(host).rows, "rows at \(scale)")
                let fields = formFields(host).map { host.convert($0.bounds, from: $0) }
                XCTAssertEqual(fields.count, 3, "\(scale)")
                XCTAssertTrue(focusViews(host, AgentComposerTextView.self).isEmpty, "no editor while collapsed at \(scale)")

                m.toggleNewSessionPrompt()
                let open = try XCTUnwrap(formRows(host).rows, "rows open at \(scale)")
                let editor = try XCTUnwrap(focusViews(host, AgentComposerTextView.self).first?.enclosingScrollView, "the editor at \(scale)")
                let frame = host.convert(editor.bounds, from: editor)
                XCTAssertEqual(frame.height, sz(96), accuracy: pixel, "a fixed sz(96) editor at \(scale)")
                let delta = base.start.minY - open.start.minY   // AX frames are y-up: down is a smaller minY
                XCTAssertEqual(delta, (sz(96) + sz(6)) / 2, accuracy: 1, "half the growth, centred, at \(scale)")
                for (a, b, n) in [(base.cancel, open.cancel, "Cancel"), (base.shell, open.shell, "New shell")] {
                    XCTAssertEqual(a.minY - b.minY, delta, accuracy: pixel, "\(n) by the same delta at \(scale)")
                    XCTAssertEqual(a.minX, b.minX, accuracy: pixel, "\(n) not sideways at \(scale)")
                    XCTAssertEqual(a.width, b.width, accuracy: pixel, "\(n) same size at \(scale)")
                    XCTAssertEqual(a.height, b.height, accuracy: pixel, "\(n) same size at \(scale)")
                }
                XCTAssertEqual(open.box.minY - base.box.minY, delta, accuracy: pixel, "the box above moves up by the same half at \(scale)")
                let moved = formFields(host).map { host.convert($0.bounds, from: $0) }
                XCTAssertEqual(moved.count, fields.count, "\(scale)")
                for (a, b) in zip(moved, fields) { XCTAssertEqual(abs(a.minY - b.minY), delta, accuracy: pixel, "each field moves by the half at \(scale)") }

                m.setNewSessionPrompt((1...12).map { "Example task line \($0)" }.joined(separator: "\n"))
                settle(host)
                assertRect(host.convert(editor.bounds, from: editor), frame, accuracy: pixel, "12 lines keep the editor at \(scale)")
                assertRows(formRows(host).rows, open, "typing moves nothing at \(scale)")

                m.toggleNewSessionPrompt()
                assertRows(formRows(host).rows, base, "collapsed again at \(scale)")
            }
        }
    }

    /// #1399 (R1392-s1): what VoiceOver gets, read from the drawn form's AX tree (never the statics): the editor is an
    /// AXTextArea labelled "First prompt for the new session"; the disclosure's label is "Prompt, optional" with the value
    /// "expanded" / "collapsed"; no label in the tree carries the triangle glyphs (U+25B8, U+25BE).
    @MainActor
    func testAgentWindowNewSessionFormPromptEditorAndDisclosureSpeakTheirNamesOnTheAXTree() throws {
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = wiringModel(store([mapped("a")]), spawns)
            defer { m.close() }
            let (win, host) = formWindow(m, CGSize(width: sz(560), height: sz(800)))
            defer { win.close() }
            m.openNewSession()
            func disclosure(_ t: [AXTreeNode]) -> AXTreeNode? { t.last { $0.label == "Prompt, optional" && !$0.ignored } }
            func glyphs(_ t: [AXTreeNode]) -> [String] {
                t.map(\.label).filter { $0.contains("\u{25B8}") || $0.contains("\u{25BE}") }
            }
            let closed = AXTreeSupport.poll(host) { disclosure($0)?.value == "collapsed" }
            XCTAssertEqual(disclosure(closed)?.value, "collapsed", "the disclosure's value while the prompt is hidden")
            XCTAssertTrue(glyphs(closed).isEmpty, "no glyph in a label while hidden: \(glyphs(closed))")

            m.toggleNewSessionPrompt()
            let open = AXTreeSupport.poll(host) { t in
                disclosure(t)?.value == "expanded" && t.contains { $0.role == "AXTextArea" && $0.label == "First prompt for the new session" }
            }
            XCTAssertEqual(disclosure(open)?.value, "expanded", "the disclosure's value while the prompt is shown")
            XCTAssertTrue(open.contains { $0.role == "AXTextArea" && $0.label == "First prompt for the new session" },
                          "the editor's AX label: \(open.filter { $0.role == "AXTextArea" }.map(\.label))")
            XCTAssertTrue(glyphs(open).isEmpty, "no glyph in a label while shown: \(glyphs(open))")
        }
    }

    // MARK: T31: Return and Command-Return in the editor

    /// T31 (D5.2): in the prompt editor Return and keypad Enter add a line and start nothing; Command-Return starts
    /// (one spawn, the prompt not in its argv). The editor's own keyDown, never a posted event.
    @MainActor
    func testAgentWindowNewSessionFormEditorReturnAddsALineCommandReturnStarts() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = wiringModel(store([mapped("a")]), spawns)
            defer { m.close() }
            let (win, host) = formWindow(m, CGSize(width: sz(560), height: sz(800)))
            defer { win.close() }
            m.openNewSessionNamed()
            m.toggleNewSessionPrompt()
            m.setNewSessionPrompt("Example task")
            settle(host)
            let tv = try XCTUnwrap(focusViews(host, AgentComposerTextView.self).first, "the editor")
            XCTAssertFalse(tv.returnSubmits, "the form's editor")
            XCTAssertEqual(tv.string, "Example task")
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            tv.keyDown(with: wiringKey(win, 36, "\r"))
            tv.keyDown(with: wiringKey(win, 76, "\u{3}"))
            XCTAssertEqual(tv.string, "Example task\n\n", "Return and Enter add lines")
            XCTAssertEqual(m.newSession?.prompt, "Example task\n\n", "into the form")
            XCTAssertTrue(spawns.calls.isEmpty, "Return starts nothing")
            tv.keyDown(with: wiringKey(win, 36, "\r", .command))
            XCTAssertEqual(spawns.calls.count, 1, "Command-Return is Start")
            XCTAssertFalse(spawns.calls.last.map { $0.argv.joined(separator: " ").contains("Example task") } ?? true,
                           "the prompt is not in the spawn's argv")
        }
    }

    // MARK: D6.2: New shell refused while the box or the prompt holds

    @MainActor
    func testAgentWindowNewSessionFormNewShellDimsWhileTheBoxOrThePromptHolds() throws {
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = wiringModel(store([mapped("a")]), spawns)
            defer { m.close() }
            let (win, host) = formWindow(m, CGSize(width: sz(560), height: sz(800)))
            defer { win.close() }
            m.openNewSessionNamed()
            @MainActor func shell() throws -> AXTreeNode {
                let tree = formRows(host).tree
                return try XCTUnwrap(tree.last { $0.role == "AXButton" && $0.named("New shell") }, "\(tree.map(\.name))")
            }
            XCTAssertTrue(try shell().enabled, "neither: New shell is there to press")
            m.setNewSessionSidekick(true)
            XCTAssertFalse(try shell().enabled, "the box on")
            XCTAssertEqual(try shell().help, AgentWindowModel.plainShellRefusal, "it says why")
            m.setNewSessionSidekick(false)
            m.setNewSessionPrompt("Example task")
            XCTAssertFalse(try shell().enabled, "text in the prompt")
            m.setNewSessionPrompt("")
            XCTAssertTrue(try shell().enabled, "both cleared")
            XCTAssertTrue(spawns.calls.isEmpty)
        }
    }

    // MARK: Not a Claude: the box and the prompt dimmed, the reason shown

    @MainActor
    func testAgentWindowNewSessionFormNonClaudeDimsTheBoxAndThePromptWithTheReason() throws {
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = wiringModel(store([mapped("a")]), spawns)
            defer { m.close() }
            let (win, host) = formWindow(m, CGSize(width: sz(560), height: sz(800)))
            defer { win.close() }
            m.openNewSession()
            for (command, why) in [("", "The login shell has no Claude to name, brief or prompt"),
                                   ("/bin/zsh -l", "Needs a claude command (claude, or a wrapper that runs claude)")] {
                m.setNewSessionCommand(command)
                XCTAssertFalse(m.newSessionClaude, command)
                XCTAssertEqual(AgentNewSessionView.notClaude(command: command, host: nil), why)
                let tree = formRows(host).tree
                let box = try XCTUnwrap(tree.last(where: isBox), "\(command): \(tree.map(\.name))")
                XCTAssertFalse(box.enabled, "the box dimmed: \(command)")
                XCTAssertTrue(tree.contains { $0.named(why) }, "the reason on the line: \(command)")
                let disclosure = try XCTUnwrap(tree.first { $0.role == "AXButton" && $0.named("Prompt, optional") }, command)
                XCTAssertFalse(disclosure.enabled, "the disclosure dimmed: \(command)")
            }
            m.setNewSessionCommand("claude")
            let tree = formRows(host).tree
            XCTAssertTrue(tree.last(where: isBox)?.enabled == true, "a Claude: the box is live")
            XCTAssertTrue(tree.contains { $0.named(prefix: "Also start a -qa sidekick, briefed by the sidekick prompt") }, "#1731: no name yet: \(tree.map(\.name))")
            m.setNewSessionName("api")
            settle(host)
            let named = formRows(host).tree
            XCTAssertTrue(named.contains { $0.named(prefix: "Also start api-qa") }, "the line names the sidekick: \(named.map(\.name))")
        }
    }

    // MARK: Rider (R1369): the unsent first message seeded at the failure

    /// The failure lands while the session is selected: the notice shows it with no reselect (#1471 b: a notice over
    /// the terminal, no draft); a session not selected keeps the text for its selection (follow()); a newer failure for
    /// the shown session replaces the text. The record stays until Send or Dismiss.
    @MainActor
    func testAgentWindowNewSessionUnsentFirstShowsForTheSelectedSessionAtTheFailure() {
        withNewSessionPrefs {
            let a = session("api", .idle), b = session("web", .idle)
            let spawns = SpawnCalls(), m = newSessionModel(store([a, b]), spawns)
            defer { m.close() }
            let island = m.island()
            m.interaction.controller = island
            m.select(.live(a.key))
            @MainActor func say(_ key: AgentSessionKey, _ text: String) {
                let done = expectation(description: "then \(key.name)")
                m.sayFirst(key, text) { done.fulfill() }
                wait(for: [done], timeout: 10)
            }
            say(a.key, "Example task for api")
            XCTAssertEqual(m.unsentFirst, AgentWindowModel.UnsentFirst(key: a.key, text: "Example task for api"), "shown at the failure, no reselect")
            XCTAssertEqual(m.interaction.draft(for: a.key), "", "no draft is seeded")
            XCTAssertEqual(island.unsentFirst[a.key], "Example task for api", "kept until Send or Dismiss")
            say(b.key, "Example task for web")
            XCTAssertEqual(m.unsentFirst?.key, a.key, "web is not selected: not yet")
            XCTAssertEqual(island.unsentFirst[b.key], "Example task for web", "kept for its selection")
            say(a.key, "Example task again")
            XCTAssertEqual(m.unsentFirst, AgentWindowModel.UnsentFirst(key: a.key, text: "Example task again"), "the newer failure shows")
            XCTAssertEqual(island.unsentFirst[a.key], "Example task again")
            XCTAssertTrue(spawns.calls.isEmpty)
        }
    }

    // MARK: #1479: centred when it fits, top-aligned when it scrolls

    /// The form in a never-shown window of `size`, with or without the pane's ScrollView.
    @MainActor
    func centredFormWindow(_ m: AgentWindowModel, _ size: CGSize, scrolls: Bool) -> (AgentsNSWindow, NSView) {
        let win = AgentsNSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.model = m
        let host = NSHostingView(rootView: AgentDetailView(model: m, transcript: m.transcript, scrolls: scrolls)
            .frame(width: size.width, height: size.height, alignment: .top).environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        return (win, host)
    }

    /// #1479: in a tall pane the form sits in the middle: growing the pane by 200 pt moves every field down by 100 (half;
    /// pinned to the top it would not move), the first field is well below the top, and opening the Prompt keeps the
    /// middle (the form grows by one delta, the first field moves up by half of it). In a short pane that scrolls the form
    /// starts at the top (the same field position at two short heights), its content is taller than the pane, and Start
    /// is on the tree to scroll to. Host coordinates are y-down.
    @MainActor
    func testAgentWindowNewSessionFormIsCentredInATallPaneAndTopAlignedWhenItScrolls() throws {
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        try withNewSessionPrefs {
            @MainActor func firstField(_ height: CGFloat, scrolls: Bool, promptOpen: Bool = false) throws -> (top: CGFloat, host: NSView, win: AgentsNSWindow, m: AgentWindowModel) {
                let m = wiringModel(store([mapped("a")]), SpawnCalls())
                let (win, host) = centredFormWindow(m, CGSize(width: 1600, height: height), scrolls: scrolls)
                m.openNewSession()
                if promptOpen { m.toggleNewSessionPrompt() }
                settle(host)
                _ = formRows(host)
                let fields = formFields(host).map { host.convert($0.bounds, from: $0) }
                XCTAssertEqual(fields.count, 3, "Folder, Name, Command at \(height)")
                return (try XCTUnwrap(fields.map(\.minY).min(), "fields at \(height)"), host, win, m)
            }
            let tall = try firstField(1200, scrolls: false), taller = try firstField(1400, scrolls: false)
            defer { tall.m.close(); taller.m.close(); tall.win.close(); taller.win.close() }
            XCTAssertEqual(taller.top - tall.top, 100, accuracy: pixel, "200 pt more pane: the form moves down by half")
            XCTAssertGreaterThan(tall.top, 200, "not pinned to the top of a 1200 pt pane")
            let open = try firstField(1200, scrolls: false, promptOpen: true)
            defer { open.m.close(); open.win.close() }
            XCTAssertEqual(tall.top - open.top, (sz(96) + sz(6)) / 2, accuracy: 1, "the Prompt opens and the form stays centred")

            let a = try firstField(260, scrolls: true), b = try firstField(300, scrolls: true)
            defer { a.m.close(); b.m.close(); a.win.close(); b.win.close() }
            XCTAssertEqual(a.top, b.top, accuracy: pixel, "a scrolling pane keeps the form at the top")
            XCTAssertLessThan(a.top, 200, "starts at the top of the short pane")
            let scroller = try XCTUnwrap(focusViews(a.host, NSScrollView.self).first, "the pane's ScrollView")
            XCTAssertGreaterThan(scroller.documentView?.frame.height ?? 0, scroller.contentView.bounds.height, "the form is taller than the pane: Start is reached by scrolling")
            XCTAssertTrue(formRows(a.host).rows != nil, "Start is on the tree")
        }
    }

    // MARK: #1731: centred in the real scrolling host; the name is required and empty

    /// #1731: through the real host (AgentDetailView, scrolls = true: the pane's ScrollView), not the bare form. The form's
    /// natural height F is the document's in a pane too short for it (it starts at the top there); in a tall pane its
    /// top gap is (H - F) / 2, so the bottom gap is the same, within one device pixel; 200 pt more pane moves it down by
    /// 100; opening the Prompt keeps the middle (the first field moves up by half of the added height); a short pane
    /// starts at the top and Start is on the tree to scroll to.
    @MainActor
    func testAgentWindowNewSessionFormIsCentredInTheRealScrollingHost() throws {
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let pixel = AXTreeSupport.devicePixel
        try withNewSessionPrefs {
            @MainActor func measure(_ height: CGFloat, promptOpen: Bool = false) throws -> (top: CGFloat, doc: CGFloat, scroller: NSScrollView, host: NSView, win: AgentsNSWindow, m: AgentWindowModel) {
                let m = wiringModel(store([mapped("a")]), SpawnCalls())
                let (win, host) = centredFormWindow(m, CGSize(width: 1600, height: height), scrolls: true)
                m.openNewSession()
                if promptOpen { m.toggleNewSessionPrompt() }
                settle(host)
                _ = formRows(host)
                let fields = formFields(host).map { host.convert($0.bounds, from: $0) }
                XCTAssertEqual(fields.count, 3, "Folder, Name, Command at \(height)")
                let scroller = try XCTUnwrap(focusViews(host, NSScrollView.self).first, "the pane's ScrollView at \(height)")
                return (try XCTUnwrap(fields.map(\.minY).min(), "fields at \(height)"), scroller.documentView?.frame.height ?? 0, scroller, host, win, m)
            }
            let short = try measure(260), tall = try measure(1200), taller = try measure(1400), open = try measure(1200, promptOpen: true)
            defer { for r in [short, tall, taller, open] { r.m.close(); r.win.close() } }
            let form = short.doc   // too short a pane: the document is the form's own height
            XCTAssertGreaterThan(form, 260, "the form does not fit 260 pt: it scrolls")
            XCTAssertLessThan(form, 1200 - 100, "and fits 1200 pt with room to centre")
            XCTAssertLessThan(short.top, 200, "a short pane starts at the top")
            XCTAssertGreaterThan(short.doc, short.scroller.contentView.bounds.height, "Start is reached by scrolling")
            XCTAssertTrue(formRows(short.host).rows != nil, "Start is on the tree of the short pane")
            XCTAssertEqual(tall.top - short.top, (1200 - form) / 2, accuracy: pixel, "top gap = bottom gap = (pane - form) / 2")
            XCTAssertEqual(taller.top - tall.top, 100, accuracy: pixel, "200 pt more pane: down by half")
            XCTAssertEqual(tall.doc, 1200, accuracy: pixel, "the content fills the viewport: nothing to scroll")
            XCTAssertEqual(tall.top - open.top, (sz(96) + sz(6)) / 2, accuracy: 1, "the Prompt opens and the form stays centred")
        }
    }

    /// #1731: the name is required and empty: no text, no placeholder, no generated name; Start is dimmed and every
    /// start path refuses (the recorder seam: nothing starts); a typed name starts with exactly that name.
    @MainActor
    func testAgentWindowNewSessionFormNameIsRequiredAndEmptyInTheRealHost() throws {
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = wiringModel(store([mapped("a")]), spawns)
            defer { m.close() }
            let (win, host) = centredFormWindow(m, CGSize(width: 900, height: 700), scrolls: true)
            defer { win.close() }
            m.openNewSession()
            settle(host)
            @MainActor func start() throws -> AXTreeNode {
                let tree = formRows(host).tree
                return try XCTUnwrap(tree.last { $0.role == "AXButton" && $0.named("Start") }, "\(tree.map(\.name))")
            }
            let name = try XCTUnwrap(formFields(host).dropFirst().first, "the Name field")
            XCTAssertEqual(name.stringValue, "", "no generated text")
            XCTAssertTrue((name.placeholderString ?? name.placeholderAttributedString?.string ?? "").isEmpty, "no placeholder")
            XCTAssertFalse(try start().enabled, "Start is dimmed while the name is empty")
            XCTAssertFalse(m.startNewSession(), "the submit path refuses")
            XCTAssertFalse(m.startShell(), "the form's New shell uses the name: refused")
            m.setNewSessionName("   ")
            XCTAssertFalse(m.startNewSession(), "spaces only")
            XCTAssertTrue(spawns.calls.isEmpty, "nothing started")
            m.setNewSessionName("api")
            settle(host)
            XCTAssertTrue(try start().enabled, "a typed name enables Start")
            XCTAssertTrue(m.startNewSession())
            XCTAssertEqual(spawns.calls.map(\.name), ["api"], "exactly the typed name")
        }
    }
}
