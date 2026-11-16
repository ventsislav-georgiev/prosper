import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1103: the Agent Sessions header drawn for Terminal mode first: one line, no verbosity picker in Terminal mode,
/// Open in terminal as the "⋯" menu's first item, the mode switch reading Terminal | Transcript. Offscreen only:
/// views are hosted in windows never put on screen, no menu is opened and no event is posted.
extension AgentWindowD1Tests {
    static let headerPath = "/Users/example/projects/prosper/app/Sources/ProsperApp/AgentWindow/Header/Long/Path"
    static let headerTitle = "prosper-ios release with a very long session name that truncates at the tail"

    /// One element of an AX client's walk (AXTreeSupport's): role, label, title, value, help, frame, ignored, enabled.
    typealias HeaderAX = AXTreeNode

    @MainActor
    private func headerHosted<V: View>(_ view: V, _ size: CGSize) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return (win, host)
    }

    @MainActor
    private func headerViews<T: NSView>(_ v: NSView, _ t: T.Type) -> [T] {
        ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { headerViews($0, t) }
    }

    /// #1120: an image an AX client is shown on the switch's line, left of it (the title line's decoration).
    @MainActor
    private func imagesLeft(of t: CGRect, _ tree: [HeaderAX]) -> [HeaderAX] {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        return tree.filter { $0.role == "AXImage" && !$0.ignored && $0.frame.maxX <= t.minX + pixel && abs($0.frame.midY - t.midY) < sz(8) }
    }

    static let pickerLabels: Set<String> = ["Focused view", "Default view", "Verbose view"]

    /// The real accessibility tree of a never-shown window (#887's technique; both attributes are put back after), at
    /// widths across every tier, in both modes: the picker is absent in Terminal mode and present in Transcript mode;
    /// the toggle reads Terminal then Transcript; every control has a name and a help text; no header button reads
    /// "Open in terminal"; the toggle and the "⋯" sit at the same place in both modes, and Terminal mode's folder takes
    /// the picker's room (no gap kept for it).
    @MainActor
    func testAccessibilityTreeReadsTheHeaderAndHidesThePickerInTerminalMode() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let a = session("api", .working, ago: 40)
        let st = store([a])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(a.key))
        let row = try XCTUnwrap(m.selectedRow)
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        var tiers: Set<String> = []
        for width: CGFloat in [300, 360, 420, 480, 560, 700, 900] {
            var toggleAt: [CGRect] = [], menuAt: [CGRect] = []
            for mode in [AgentPaneMode.terminal, .transcript] {
                let header = AgentSessionHeader(row: row, session: a, cwd: Self.headerPath, open: {}, store: st,
                                                mode: mode, setMode: { _ in })
                let size = CGSize(width: width, height: 80)
                let (win, host) = headerHosted(header.frame(width: width, height: 80, alignment: .top), size)
                defer { win.close() }
                let tree = AXTreeSupport.poll(host) { $0.contains(where: { $0.named("Session actions") }) }
                let tag = "\(width) \(mode)"
                if width == 700 {
                    print("#1103 a11y tree \(tag):\n" + tree.map { "  \($0.role) label=\($0.label) title=\($0.title) value=\($0.value) help=\($0.help) frame=\($0.frame)\($0.ignored ? " IGNORED" : "")" }
                        .joined(separator: "\n"))
                }
                let picker = tree.filter { e in Self.pickerLabels.contains { e.named($0) } || e.named(prefix: "View: ") }
                XCTAssertEqual(picker.isEmpty, mode == .terminal, "the picker only in Transcript mode (\(tag))")
                let toggle = tree.filter { $0.named("Terminal") || $0.named("Transcript") || $0.named(prefix: "Showing: ") }
                tiers.insert(toggle.count == 2 ? "segments" : "menu")
                if toggle.count == 2 { XCTAssertEqual(toggle.map(\.name), ["Terminal", "Transcript"], "the default on the left (\(tag))") }
                XCTAssertFalse(toggle.isEmpty, "the toggle (\(tag))")
                let menu = tree.filter { $0.named("Session actions") }
                XCTAssertEqual(menu.count, 1, "one \"⋯\" (\(tag))")
                for c in picker + toggle + menu { XCTAssertFalse(c.help.isEmpty, "\(c.name) has a help text (\(tag))") }
                XCTAssertEqual(menu.first?.help, "Open in terminal, rename, restart, stop or end this session")
                XCTAssertFalse(tree.contains { $0.named(AgentWindowControls.openLabel) },
                               "no Open in terminal button in the header (\(tag))")
                let t = toggle.reduce(CGRect.null) { $0.union($1.frame) }
                toggleAt.append(t)
                menuAt.append(menu.first?.frame ?? .null)
                // #1103 F4, #1120: the folder icon is decoration in both modes (AppKit names the symbol "Move").
                XCTAssertFalse(tree.contains { $0.reads("Move") }, "no folder icon at all (\(tag)): \(tree.filter { $0.named("Move") })")
                if mode == .terminal {
                    XCTAssertEqual(imagesLeft(of: t, tree).count, 0, "no image read left of the switch (\(tag)): \(imagesLeft(of: t, tree))")
                }
                // #1191: no path line in either mode: the one element that reads it is the title, on the switch's line.
                let readers = tree.filter { $0.reads(Self.headerPath) }
                XCTAssertEqual(readers.count, 1, "only the title carries the path (\(tag)): \(readers)")
                if let r = readers.first {
                    XCTAssertTrue(r.named(Self.headerTitle) || r.named("api"), "the reader is the title (\(tag))")
                    XCTAssertEqual(r.frame.midY, t.midY, accuracy: 2, "the title is on the title line in both modes (\(tag))")
                }
                XCTAssertFalse(win.isVisible, "never on screen")
            }
            XCTAssertEqual(toggleAt.count, 2)
            XCTAssertEqual(toggleAt.first?.minX ?? -1, toggleAt.last?.minX ?? -2, accuracy: pixel, "the toggle stays put at \(width)")
            XCTAssertEqual(toggleAt.first?.maxX ?? -1, toggleAt.last?.maxX ?? -2, accuracy: pixel, "the toggle keeps its width at \(width)")
            XCTAssertEqual(menuAt.first?.minX ?? -1, menuAt.last?.minX ?? -2, accuracy: pixel, "the \"⋯\" stays put at \(width)")
            XCTAssertEqual(menuAt.first?.minY ?? -1, menuAt.last?.minY ?? -2, accuracy: pixel, "the \"⋯\" stays on its line at \(width)")
            print("#1103 \(width): toggle \(toggleAt.map(\.minX)) menu \(menuAt.map(\.minX))")
        }
        XCTAssertEqual(tiers, ["segments", "menu"], "the sweep crosses the tiers")
    }

    /// A hosted, never-shown window's accessibility tree once `ready` holds (the app's AX attributes set by the caller).
    @MainActor
    private func headerAXTree<V: View>(_ view: V, _ size: CGSize, ready: (HeaderAX) -> Bool) -> (NSWindow, [HeaderAX]) {
        let (win, host) = headerHosted(view.frame(width: size.width, height: size.height, alignment: .top), size)
        return (win, AXTreeSupport.poll(host) { $0.contains(where: ready) })
    }

    /// #1191: the header draws no folder glyph and no path in either mode; the path is the title's tooltip (AXHelp) and
    /// its accessibility value (the words stay its label), the fallback text for a session with no cwd the same way,
    /// nothing when there is none. Real accessibility tree of a never-shown window. Fixed slots: the header's height and
    /// the count and age slots' frames are equal with and without a path, at 0.7, 0.85 and 1.0, in both modes.
    @MainActor
    func testHeaderShowsNoPathAndCarriesItInTheTitleTooltipAndValue() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let a = session("api", .working, ago: 40, agents: 3)
        let st = store([a])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(a.key))
        let row = try XCTUnwrap(m.selectedRow)
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        let home = NSHomeDirectory()
        // cwd, then the text the title must carry (nil: none at all); an empty cwd is no text; the test store's socket dir is not the default, so the fallback names it.
        let cases: [(String?, String?)] = [(Self.headerPath, Self.headerPath), (home + "/project", "~/project"),
                                           (nil, "dch api in /tmp/dch-test"), ("", nil)]
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            var heights: [CGFloat] = []
            for mode in [AgentPaneMode.terminal, .transcript] {
                var slots: [[CGRect]] = []
                for (cwd, text) in cases {
                    let header = AgentSessionHeader(row: row, session: a, cwd: cwd, open: {}, store: st, mode: mode, setMode: { _ in })
                    XCTAssertEqual(header.project, text, "the text (\(cwd ?? "nil"))")
                    let width = 900 * scale
                    heights.append(NSHostingView(rootView: header.frame(width: width)).fittingSize.height)
                    let (win, tree) = headerAXTree(header, CGSize(width: width, height: 80 * scale)) { $0.named("Session actions") }
                    defer { win.close() }
                    let tag = "\(mode) \(scale) cwd \(cwd ?? "nil")"
                    // R1191-1: with no folder the title's words are its value (ticket 2: no node had the label then).
                    let title = try XCTUnwrap(tree.first { !$0.ignored && $0.named("api") }, "the title (\(tag))")
                    XCTAssertEqual(title.help, text ?? "", "the tooltip carries the path (\(tag))")
                    // R1191-1: no folder text, no value set: the title keeps its own words as value.
                    XCTAssertEqual(title.value, text ?? "api", "the accessibility value carries the path (\(tag))")
                    // Drawn nowhere else: no other element reads it, and no folder glyph.
                    if let text { XCTAssertEqual(tree.filter { $0.reads(text) }.count, 1, "only the title reads it (\(tag))") }
                    XCTAssertFalse(tree.contains { $0.reads("Move") }, "no folder glyph (\(tag))")
                    XCTAssertFalse(tree.contains { !$0.ignored && $0.role == "AXImage" && $0.frame.width > 0 && $0.frame.maxX < title.frame.minX },
                                   "nothing drawn left of the title (\(tag))")
                    // Every slot (title, chip, counts, age, controls): the frames of what an AX client is shown.
                    slots.append(tree.filter { !$0.ignored && $0.frame.width > 0 }.map(\.frame))
                    XCTAssertFalse(win.isVisible, "never on screen")
                }
                for s in slots.dropFirst() {
                    XCTAssertEqual(s.count, slots.first?.count, "as many slots with and without a path (\(mode) \(scale))")
                    for (a, b) in zip(s, slots.first ?? []) {
                        assertRect(a, b, accuracy: pixel, "every slot (the count and age too) stays put with and without a path (\(mode) \(scale))")
                    }
                }
                XCTAssertTrue(slots.first?.count ?? 0 >= 5, "the slots were found (\(mode) \(scale)): \(slots.first ?? [])")
            }
            // One height per mode, whatever the path: terminal rows first, transcript after (four cases each).
            for half in [heights.prefix(cases.count), heights.suffix(cases.count)] {
                XCTAssertEqual(half.min() ?? -1, half.max() ?? -2, accuracy: pixel, "the header's height with and without a path (\(scale))")
            }
        }
    }

    /// #1191: a fixed slot: Transcript mode's header is as high with no counts and no age as with them, at 0.7, 0.85
    /// and 1.0, and as high as the row with counts measured before the slot existed (the slot did not grow).
    @MainActor
    func testTranscriptHeaderHeightIsTheSameWithAndWithoutCountsAndAge() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let a = session("api", .working, ago: 40, agents: 3)
        let st = store([a])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(a.key))
        let base = try XCTUnwrap(m.selectedRow)
        func variant(_ age: String, agents: Int, merged: Int) -> AgentSidebar.Row {
            AgentSidebar.Row(id: base.id, title: base.title, state: base.state, detail: base.detail, age: age, prs: [],
                             agents: agents, merged: merged, session: base.session)
        }
        let rows = [("counts and age", variant("4m", agents: 3, merged: 1)), ("age only", variant("4m", agents: 0, merged: 0)),
                    ("neither", variant("", agents: 0, merged: 0))]
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            var h: [String: CGFloat] = [:]
            for (name, r) in rows {
                let header = AgentSessionHeader(row: r, session: a, cwd: "/Users/example/project", open: {}, store: st,
                                                mode: .transcript, setMode: { _ in })
                h[name] = NSHostingView(rootView: header.frame(width: 900 * scale)).fittingSize.height
            }
            let full = h["counts and age"] ?? -1
            XCTAssertGreaterThan(full, AgentSessionHeader.height + sz(10), "two lines (\(scale))")
            for (name, v) in h { XCTAssertEqual(v, full, accuracy: pixel, "\(name) is as high as counts and age (\(scale))") }
            print("#1191 transcript heights \(scale): \(h)")
        }
    }

    /// #1191 round 3: Transcript mode's counts start under the title's leading edge (the slot's placeholder takes no
    /// part in the line's spacing), at 0.7, 0.85 and 1.0. Real accessibility frames of a never-shown window.
    @MainActor
    func testTranscriptCountsAlignWithTheTitleLeadingEdge() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let a = session("api", .working, ago: 40, agents: 3)
        let st = store([a])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(a.key))
        let row = try XCTUnwrap(m.selectedRow)
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            let header = AgentSessionHeader(row: row, session: a, cwd: "/Users/example/project", open: {}, store: st,
                                            mode: .transcript, setMode: { _ in })
            let (win, tree) = headerAXTree(header, CGSize(width: 900 * scale, height: 90 * scale)) { $0.named("Session actions") }
            defer { win.close() }
            let title = try XCTUnwrap(tree.first { !$0.ignored && $0.label == "api" }, "the title (\(scale))").frame
            let count = try XCTUnwrap(tree.first { $0.reads("3 agents") }, "the first count group (\(scale))").frame
            print("#1191 r3 \(scale): title minX \(title.minX) count minX \(count.minX)")
            XCTAssertGreaterThan(abs(count.midY - title.midY), sz(10), "the counts are on the second line (\(scale))")
            // Ticket 4 read the group's frame 1 pt (at 1.0) right of the title's: the group's own inset, not spacing. The
            // indent this guards against is the line's spacing, sz(6): over sz(4).
            XCTAssertEqual(count.minX, title.minX, accuracy: sz(2), "the counts start under the title (\(scale))")
            XCTAssertFalse(win.isVisible, "never on screen")
        }
    }

    /// #1103 F2: the sidebar's "Agent Sessions" and the session header's title share one centre line in the whole
    /// window, at 0.7, 0.85 and 1.0, in both modes (the real accessibility frames of a never-shown window).
    @MainActor
    func testSidebarTitleSharesTheHeaderTitleLine() throws {
        // The window's backdrop builds ThemeStore.shared, whose init sets ThemeRuntime.scale from the prefs: built
        // first, or the first pass (0.7) is laid out partly at 1.0 (ticket 6, a filtered run).
        _ = ThemeStore.shared
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        try withModePref {
            let (wm, wst) = demoModel(Self.corpus.appendingPathComponent("2.1.318/b-compaction-agents-more-tools.jsonl"))
            _ = fakeTerminal(wm)
            defer { wm.close() }
            let s = try XCTUnwrap(wst.sessions.first { $0.name == "prosper" })
            let restoreAX = AXTreeSupport.axOn()
            defer { restoreAX() }
            var checked = 0
            for scale: CGFloat in [0.7, 0.85, 1.0] {
                ThemeRuntime.scale = scale
                for mode in [AgentPaneMode.terminal, .transcript] {
                    wm.setMode(mode, for: s)
                    let title = try XCTUnwrap(wm.selectedRow?.title)
                    let tag = "\(scale) \(mode)"
                    let size = CGSize(width: 1000 * scale, height: 680 * scale)
                    let edge = sz(290)
                    let (win, tree) = headerAXTree(AgentWindowRootView(model: wm, scrolls: false), size) { e in
                        e.named(title) && e.frame.minX > edge
                    }
                    defer { win.close() }
                    let side = try XCTUnwrap(tree.first { $0.named(AgentsWindow.title) }, "the sidebar title (\(tag))").frame
                    let head = try XCTUnwrap(tree.filter { $0.named(title) }.max { $0.frame.minX < $1.frame.minX },
                                             "the header title (\(tag))").frame
                    XCTAssertGreaterThan(head.minX, edge, "the header's, not the sidebar row's (\(tag))")
                    XCTAssertEqual(side.midY, head.midY, accuracy: 1, "one centre line (\(tag)): \(side) \(head)")
                    XCTAssertFalse(win.isVisible, "never on screen")
                    checked += 1
                }
            }
            XCTAssertEqual(checked, 6)
        }
    }

    /// The list the "⋯" and a live row's context menu are built from: Open in terminal first (above Rename), on for
    /// a live session, off and alone for an ended one; the item's action through its seams (the header's `open`, the
    /// row's AgentSidebarView.open). No menu is opened.
    @MainActor
    func testAgentSessionMenuPutsOpenInTerminalFirst() throws {
        let a = session("a", .idle), dash = session("-x", .idle), b = session("b", .working)
        let st = store([a, dash, b])
        st.controlDch = bin([1, 38, 0])
        XCTAssertEqual(AgentWindowControls.openLabel, "Open in terminal")
        let live = AgentWindowControls.sessionMenu(a, store: st, ended: false)
        XCTAssertEqual(live.first, .open(enabled: true))
        XCTAssertEqual(live.count, AgentWindowControls.menu(a, store: st).count + 2)
        XCTAssertEqual(Array(live.dropFirst(2)), AgentWindowControls.menu(a, store: st), "then the island's items, as before")
        XCTAssertEqual(live.dropFirst().first, .divider)
        XCTAssertEqual(live.dropFirst(2).first, .item(AgentIsland.renameLabel, enabled: true, verb: .rename), "Open in terminal above Rename")
        XCTAssertEqual(AgentWindowControls.sessionMenu(dash, store: st, ended: false),
                       [.open(enabled: true), .divider] + AgentWindowControls.menu(dash, store: st))
        XCTAssertEqual(AgentWindowControls.sessionMenu(a, store: st, ended: true), [.open(enabled: false)], "ended: off, alone")
        XCTAssertEqual(AgentWindowControls.sessionMenu(a, store: nil, ended: true), [.open(enabled: false)])
        XCTAssertEqual(AgentWindowControls.sessionMenu(a, store: nil, ended: false), [.open(enabled: true)])
        // Open in terminal is no verb: a gate check (notRun) never reads it.
        XCTAssertNil(AgentWindowControls.notRun(live, .rename))

        // The header's "⋯" carries the header's own action and end.
        var opened: [AgentSessionKey] = []
        let m = windowModel(st, opened: { opened.append($0.key) })
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(a.key))
        let row = try XCTUnwrap(m.selectedRow)
        var calls = 0
        let header = AgentSessionHeader(row: row, session: a, cwd: nil, open: { calls += 1 }, store: st)
        XCTAssertEqual(header.menuButton.entries, live)
        header.menuButton.open()
        XCTAssertEqual(calls, 1, "the item runs the header's open")
        XCTAssertEqual(AgentSessionHeader(row: row, session: a, cwd: nil, open: {}, store: st, ended: true).menuButton.entries,
                       [.open(enabled: false)])

        // A row's context menu: the same list; its Open in terminal selects that row, then opens it.
        AgentSidebarView(model: m).open(b)
        XCTAssertEqual(m.selection, .live(b.key))
        XCTAssertEqual(opened, [b.key])
        AgentSidebarView(model: m).open(a)
        XCTAssertEqual(opened, [b.key, a.key])
    }

    /// Point 6: Terminal | Transcript, the default on the left, in every style; ⌘T still toggles (by value, not index).
    @MainActor
    func testAgentPaneModeToggleReadsTerminalThenTranscript() {
        XCTAssertEqual(AgentPaneModeToggle.modes.map(\.mode), [.terminal, .transcript])
        XCTAssertEqual(AgentPaneModeToggle.modes.map(\.title), ["Terminal", "Transcript"])
        XCTAssertEqual(AgentPaneModeToggle.modes.map(\.icon), ["terminal", "text.bubble"])
        withModePref {
            let a = session("a", .idle)
            let m = windowModel(store([a]))
            m.setVisible(true)
            defer { m.close() }
            m.select(.live(a.key))
            XCTAssertEqual(m.paneMode, .terminal, "Terminal is the default")
            XCTAssertTrue(m.toggleMode())
            XCTAssertEqual(m.paneMode, .transcript)
            XCTAssertTrue(m.toggleMode())
            XCTAssertEqual(m.paneMode, .terminal)
        }
    }

    /// Point 3: Terminal mode one line, Transcript mode the title line and the folder line; one height per mode at
    /// 0.7, 0.85 and 1.0 (a long title, a long path, the todo chip), lower than before; nothing drawn past the header
    /// at the narrowest pane; the Rename field fits the slot of the one-line form.
    @MainActor
    func testAgentSessionHeaderIsOneLineInTerminalModeAtEveryScale() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let a = session("prosper-ios", .blocked, ago: 200, alias: Self.headerTitle)
        let st = store([a])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(a.key))
        let row = try XCTUnwrap(m.selectedRow)
        let todos = AgentTodos(items: (0..<7).map { .init(text: "task \($0)", status: $0 < 3 ? "completed" : "pending") })
        var log: [String] = []
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            var heights: [AgentPaneMode: [CGFloat]] = [:]
            for w: CGFloat in [640, 1000] {
                let room = w * scale - sz(290) - 1
                for mode in [AgentPaneMode.terminal, .transcript] {
                    let h = AgentSessionHeader(row: row, session: a, cwd: Self.headerPath, open: {}, level: .constant(.default),
                                               todos: todos, store: st, mode: mode, setMode: { _ in })
                    let fit = NSHostingView(rootView: h.frame(width: room)).fittingSize.height
                    heights[mode, default: []].append(fit)
                    log.append(String(format: "%@ %.2f w%.0f h=%.1f", mode == .terminal ? "terminal" : "transcript", scale, w, fit))
                    if mode == .terminal {
                        // One line: the padding and the line's own height, no more.
                        XCTAssertEqual(fit, AgentSessionHeader.height, accuracy: 1, "one line (fittingSize rounds up) (\(scale) \(w))")
                    } else {
                        // The title line and the folder line.
                        XCTAssertGreaterThan(fit, AgentSessionHeader.height + sz(10), "Transcript: two lines (\(scale) \(w))")
                    }
                    XCTAssertLessThan(fit, sz(80), "lower than before (base: 86 pt at 1.0) (\(mode) \(scale) \(w))")
                    guard w == 640 else { continue }   // the narrowest pane: where a cut line would spill
                    let size = CGSize(width: room, height: fit)
                    let spill = try autoreleasepool {
                        overflow(try render(h, size: size, dark: true), content: size,
                                 canvas: CGSize(width: size.width + 24, height: size.height + 24))
                    }
                    XCTAssertEqual(spill, 0, "nothing past the header (\(mode) \(scale))")
                }
            }
            for (mode, hs) in heights {
                XCTAssertEqual(hs.count, 2)
                XCTAssertEqual(hs.first ?? -1, hs.last ?? -2, accuracy: pixel, "one height per mode, whatever the width (\(mode) \(scale))")
            }
            // Rename: the field lies over the one-line slot at the narrowest pane, in its line, tall enough for its text.
            let room = 640 * scale - sz(290) - 1
            let edit = AgentRenameEdit(key: a.key, text: Self.headerTitle)
            let h = AgentSessionHeader(row: row, session: a, cwd: Self.headerPath, open: {}, store: st, rename: edit,
                                       mode: .terminal, setMode: { _ in })
            let height = NSHostingView(rootView: h.frame(width: room)).fittingSize.height
            let (win, host) = headerHosted(h.frame(width: room, height: height), CGSize(width: room, height: height))
            defer { win.close() }
            let field = try XCTUnwrap(headerViews(host, AgentRenameTextField.self).first, "the field is built at \(scale)")
            // The field's alignment rect: an NSTextField's frame runs about 2 pt past it on each side (its insets).
            let f = field.superview?.convert(field.alignmentRect(forFrame: field.frame), to: host) ?? .null
            XCTAssertGreaterThanOrEqual(field.frame.height + pixel, field.intrinsicContentSize.height, "its text fits at \(scale)")
            XCTAssertLessThanOrEqual(field.intrinsicContentSize.height, AgentSessionHeader.lineHeight + pixel, "the line holds it at \(scale)")
            XCTAssertGreaterThan(f.width, sz(60), "room to type at \(scale)")
            XCTAssertGreaterThanOrEqual(f.minX, sz(16) - pixel, "inside the padding at \(scale)")
            XCTAssertLessThanOrEqual(f.maxX, room - sz(16), "left of the controls at \(scale)")
            XCTAssertFalse(win.isVisible, "never on screen")
        }
        print("#1103 header heights\n" + log.joined(separator: "\n"))
    }

    /// The refusal texts that tell the user to "Open in terminal": the window's own show beside a button
    /// (AgentActionNotice); the island's Message refusals reach the pane's notice line, which draws the button now
    /// that the header has none. Every one carries the menu item's words.
    @MainActor
    func testNoticeLineDrawsOpenInTerminalBesideATextThatNamesIt() throws {
        let texts = [AgentWindowText.changed, AgentWindowText.unconfirmed, AgentWindowText.noStatus, AgentWindowText.draft,
                     AgentWindowText.noScreen, AgentWindowText.noScreenInterrupt, AgentWindowText.notClaude,
                     AgentWindowText.notSubmitted, AgentWindowText.draftLeft, AgentWindowText.promptShown,
                     AgentWindowText.unreadable, AgentWindowText.mismatch, AgentWindowText.unchecked,
                     AgentWindowText.planUnchecked, AgentWindowText.planLayout, AgentWindowText.planUnsafe,
                     AgentWindowText.planRow, AgentWindowText.planMismatch, AgentWindowText.planFile,
                     AgentWindowText.planCut, AgentWindowText.planCaret]
        XCTAssertEqual(texts.count, 21)
        for t in texts { XCTAssertTrue(AgentNoticeLine.offersOpen(t), t) }
        for t in ["Attach command copied", "Restarted", "Not run: Stop (restart this session first)", AgentWindowText.working] {
            XCTAssertFalse(AgentNoticeLine.offersOpen(t), t)
        }
        let a = session("a", .idle)
        let st = store([a])
        st.actions[a.key] = AgentWindowText.promptShown
        let size = CGSize(width: 600, height: 40)
        let with = try render(AgentNoticeLine(store: st, key: a.key, open: {}), size: size, dark: true)
        let without = try render(AgentNoticeLine(store: st, key: a.key), size: size, dark: true)
        let all = 0..<with.pixelsWide, rows = 0..<with.pixelsHigh
        XCTAssertGreaterThan(differing(with, without, x: all, y: rows), 0, "the button beside the text")
        st.actions[a.key] = "Attach command copied"
        let plain = try render(AgentNoticeLine(store: st, key: a.key, open: {}), size: size, dark: true)
        let plainNone = try render(AgentNoticeLine(store: st, key: a.key), size: size, dark: true)
        XCTAssertEqual(differing(plain, plainNone, x: all, y: rows), 0, "no button beside a line that names none")
    }

    // MARK: #1120

    /// #1120 (QA #693 INFO-5): while the Rename field lies over the slot, the title, the state chip and (Terminal mode)
    /// the folder's path and extras are out of the tree under it (the slot's opacity 0 drops them); the field is read.
    /// Transcript mode's second line is not under the field and stays read. Not renaming, all of them are read. Real
    /// tree, never-shown window.
    @MainActor
    func testRenameHidesTheTitleChipAndPathUnderTheFieldInTheTree() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let a = session("prosper-ios", .working, ago: 40, alias: "api title", agents: 3)
        let st = store([a])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(a.key))
        let row = try XCTUnwrap(m.selectedRow)
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        let path = "/srv/api"
        for mode in [AgentPaneMode.terminal, .transcript] {
            for renaming in [false, true] {
                let edit = renaming ? AgentRenameEdit(key: a.key, text: "api-qa") : nil
                let header = AgentSessionHeader(row: row, session: a, cwd: path, open: {}, store: st, rename: edit, mode: mode,
                                                setMode: { _ in })
                let (win, tree) = headerAXTree(header, CGSize(width: 900, height: 80)) { e in
                    renaming ? e.role == "AXTextField" : e.named("Session actions")
                }
                defer { win.close() }
                let tag = "\(mode) renaming \(renaming)"
                let toggle = tree.filter { $0.named("Terminal") || $0.named("Transcript") }
                let t = toggle.reduce(CGRect.null) { $0.union($1.frame) }
                XCTAssertFalse(toggle.isEmpty, "the switch (\(tag))")
                // The slot: left of the line's first control (Transcript mode: the picker; ticket 1 read its three buttons).
                let controls = tree.filter { e in e.named("Terminal") || e.named("Transcript") || Self.pickerLabels.contains { e.named($0) } }
                let edge = controls.map(\.frame.minX).min() ?? t.minX
                let line = tree.filter { !$0.ignored && !$0.names.isEmpty && $0.frame.width > 0
                    && $0.frame.maxX <= edge + pixel && abs($0.frame.midY - t.midY) < sz(8) }
                let field = line.filter { $0.role == "AXTextField" }
                print("#1120 rename tree \(tag): " + line.map { "\($0.role) \($0.names)" }.joined(separator: ", "))
                XCTAssertEqual(field.count, renaming ? 1 : 0, "the field is read while renaming (\(tag))")
                for n in ["api title", "Working"] {
                    XCTAssertEqual(line.contains { $0.role != "AXTextField" && $0.reads(n) }, !renaming, "\(n) (\(tag))")
                }
                if renaming {
                    XCTAssertEqual(line.filter { $0.role != "AXTextField" }.map(\.names), [], "nothing but the field under it (\(tag))")
                }
                // #1191: the path rides on the title (value and tooltip): read exactly when the title is, in both modes.
                XCTAssertEqual(tree.contains { $0.reads(path) }, !renaming, "the path follows the title (\(tag))")
                XCTAssertFalse(win.isVisible, "never on screen")
            }
        }
    }

    /// QA 845 INFO-1, guard 1 (AgentWindowControls.swift, AgentSessionMenuButton's `.disabled(ended)`): an ended
    /// session's "⋯" is off as an AX client reads it (AXEnabled), a live one's on.
    @MainActor
    func testEndedHeaderMenuIsOffInTheAccessibilityTree() throws {
        let a = session("api", .idle)
        let st = store([a])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(a.key))
        let row = try XCTUnwrap(m.selectedRow)
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        for ended in [false, true] {
            let header = AgentSessionHeader(row: row, session: a, cwd: "/srv/api", open: {}, store: st, ended: ended, mode: .terminal,
                                            setMode: { _ in })
            let (win, tree) = headerAXTree(header, CGSize(width: 700, height: 80)) { $0.named("Session actions") }
            defer { win.close() }
            let menu = tree.filter { $0.named("Session actions") }
            print("#1120 AXEnabled \"⋯\" ended \(ended): \(menu.map(\.enabledFacts))")
            XCTAssertEqual(menu.count, 1, "one \"⋯\" (ended \(ended))")
            XCTAssertEqual(menu.first?.enabled, !ended, "the \"⋯\" is \(ended ? "off" : "on") (ended \(ended))")
            XCTAssertFalse(win.isVisible, "never on screen")
        }
    }

    /// QA 845 INFO-1, guard 2 (AgentMenuEntries' `.disabled(!enabled)` on Open in terminal): the items the "⋯" builds,
    /// drawn as buttons outside a menu (no menu is opened): an ended session's Open in terminal is off, a live one's on.
    @MainActor
    func testEndedMenuOpenItemIsOffInTheAccessibilityTree() throws {
        let a = session("api", .idle)
        let st = store([a])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(a.key))
        let row = try XCTUnwrap(m.selectedRow)
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        for ended in [false, true] {
            let entries = AgentSessionHeader(row: row, session: a, cwd: nil, open: {}, store: st, ended: ended).menuButton.entries
            XCTAssertEqual(entries.first, .open(enabled: !ended))
            let items = VStack(alignment: .leading) { AgentMenuEntries(entries: entries, act: { _ in }, open: {}) }
            let (win, tree) = headerAXTree(items, CGSize(width: 300, height: 260)) { $0.named(AgentWindowControls.openLabel) }
            defer { win.close() }
            let open = tree.filter { $0.role == "AXButton" && $0.named(AgentWindowControls.openLabel) }
            print("#1120 AXEnabled menu item ended \(ended): \(open.map(\.enabledFacts))")
            XCTAssertEqual(open.count, 1, "Open in terminal (ended \(ended))")
            XCTAssertEqual(open.first?.enabled, !ended, "Open in terminal is \(ended ? "off" : "on") (ended \(ended))")
            XCTAssertFalse(win.isVisible, "never on screen")
        }
    }

    /// QA 845 INFO-1, guard 3 (AgentDetailView.overTop passes `ended: model.focusedEnded` to the notice line): a
    /// held (ended) session's notice that names Open in terminal draws its button off; a live session's on. The pane's
    /// own overTop, hosted alone; the Stop is a recorder (nothing reaches dch).
    @MainActor
    func testHeldPaneNoticeOpenButtonIsOffInTheAccessibilityTree() throws {
        try withModePref {
            let st = store([session("a", .idle), session("b", .idle)])
            st.controlDch = bin([1, 38, 0])
            let held = windowModel(st)
            Calls().wire(held)
            held.setVisible(true)
            defer { held.close() }
            let a = try XCTUnwrap(st.sessions.first { $0.name == "a" })
            held.ask(.stop, a)
            held.confirm(true)
            st.sessions = [session("b", .idle)]
            XCTAssertTrue(held.focusedEnded)   // #831 B1, rewrite 6: the Ended state, by resolve (rewrites-B1)
            let liveStore = store([session("a", .idle), session("b", .idle)])
            liveStore.controlDch = bin([1, 38, 0])
            let live = windowModel(liveStore)
            Calls().wire(live)
            live.setVisible(true)
            defer { live.close() }
            live.select(.live(a.key))
            XCTAssertFalse(live.focusedEnded)
            let restoreAX = AXTreeSupport.axOn()
            defer { restoreAX() }
            for (m, s, ended) in [(live, liveStore, false), (held, st, true)] {
                s.notices[a.key] = nil
                s.actions[a.key] = AgentWindowText.promptShown
                let row = try XCTUnwrap(m.selectedRow), sel = try XCTUnwrap(row.session)
                let top = AgentDetailView(model: m, transcript: m.transcript, scrolls: false).overTop(row, sel)
                let (win, tree) = headerAXTree(top, CGSize(width: 700, height: 80)) { $0.named(AgentWindowControls.openLabel) }
                defer { win.close() }
                let open = tree.filter { $0.role == "AXButton" && $0.named(AgentWindowControls.openLabel) }
                print("#1120 AXEnabled notice ended \(ended): \(open.map(\.enabledFacts))")
                XCTAssertEqual(open.count, 1, "the notice's Open in terminal (ended \(ended))")
                XCTAssertEqual(open.first?.enabled, !ended, "it is \(ended ? "off" : "on") (ended \(ended))")
                XCTAssertFalse(win.isVisible, "never on screen")
            }
        }
    }

    /// R1.5 (14.2), 9.2: the compact header (a pane among several) at 300·s, in every state, at 0.7, 0.85 and 1.0: one
    /// line of 26·s, nothing past its edge (the title gives way first; the chip, the toggle and the "⋯" keep their
    /// size), the "⋯" read once. Real accessibility tree of a never-shown window.
    @MainActor
    func testCompactHeaderFitsThreeHundredPointsInEveryState() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            let width = sz(300)
            var menus: [CGRect] = []
            for (state, ended) in [(AgentState.working, false), (.blocked, false), (.idle, false), (.done, true)] {
                let s = session("api", state, alias: Self.headerTitle)
                let m = windowModel(store([s]))
                m.setVisible(true)   // the rows are built on show
                defer { m.close() }
                let row = try XCTUnwrap(m.row(.live(s.key)))
                let header = AgentCompactHeader.of(row, s, cwd: Self.headerPath, ended: ended, store: nil, ask: { _ in },
                                                   open: {}, mode: .transcript, setMode: { _ in })
                XCTAssertEqual(NSHostingView(rootView: header.frame(width: width)).fittingSize.height, (AgentCompactHeader.height - 0.001).rounded(.up),
                               accuracy: 0.01, "one line of 26·s, fittingSize rounds up to a whole point (\(state) \(scale))")
                let (win, tree) = headerAXTree(header, CGSize(width: width, height: AgentCompactHeader.height)) { $0.named("Session actions") }
                defer { win.close() }
                let tag = "\(state) ended \(ended) \(scale)"
                let menu = tree.filter { $0.named("Session actions") }
                XCTAssertEqual(menu.count, 1, "one \"⋯\" (\(tag))")
                let edge = tree.first?.frame.maxX ?? 0
                for e in tree where !e.ignored && e.frame.width > 0 {
                    XCTAssertLessThanOrEqual(e.frame.maxX, edge + pixel, "\(e.name) inside the header (\(tag))")
                }
                XCTAssertTrue(tree.contains { $0.named(row.title) }, "the title is read whole (\(tag))")
                menus.append(menu.first?.frame ?? .null)
                XCTAssertFalse(win.isVisible, "never on screen")
            }
            XCTAssertEqual(Set(menus.map { ($0.minX * 2).rounded() }).count, 1, "the \"⋯\" never moves with the state (\(scale))")
        }
    }

    /// 4.2 (QA 956 R1217-a): the window opens on a saved target whose session is gone: the pane says so by name ("gone
    /// isn't running", Pick Another; no Close Pane with one pane), never the empty pane's "Select a session"; the empty
    /// pane keeps that state. Both fill the same pane frame. The list still picks a session into the same pane.
    @MainActor
    func testAPaneWhoseSessionIsGoneSaysSoByNameAndDiffersFromTheEmptyPane() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let d = paneDefaults()
        let gone = PaneLayout.single(.session(dir: "/tmp/dch-test", name: "gone"))
        Preferences.setAgentWindowLayouts(try PaneLayoutStore.makeDefault().adding(gone).get().activate(gone.id).get(), in: d)
        let st = store([session("web", .idle)])
        let m = windowModel(st, layouts: d)
        m.setVisible(true)
        defer { m.close() }
        XCTAssertEqual(m.layout.id, gone.id, "the saved layout")
        XCTAssertEqual(m.content, .notRunning(paneKey("gone")))
        XCTAssertTrue(m.selection == nil)
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        let size = CGSize(width: 1000, height: 680)
        let words = "gone isn't running"
        let (win, tree) = headerAXTree(AgentWindowRootView(model: m, scrolls: false), size) { $0.reads(words) }
        defer { win.close() }
        XCTAssertTrue(tree.contains { $0.reads(words) }, "the pane names the session: \(tree.map(\.names))")
        XCTAssertTrue(tree.contains { $0.reads("Pick Another") }, "the way out")
        XCTAssertFalse(tree.contains { $0.reads("Close Pane") }, "one pane: nothing to close")
        XCTAssertFalse(tree.contains { $0.reads("Select a session") }, "not the empty pane")
        let held = paneSnapshot(m, size)["pane 0"]

        m.select(nil)
        let (win2, empty) = headerAXTree(AgentWindowRootView(model: m, scrolls: false), size) { $0.reads("Select a session") }
        defer { win2.close() }
        XCTAssertTrue(empty.contains { $0.reads("Select a session") }, "no target: the empty pane")
        XCTAssertFalse(empty.contains { $0.reads(words) })
        assertSame(paneSnapshot(m, size)["pane 0"], held, "the same pane frame")

        let pane = m.layout.focused
        m.select(.live(paneKey("web")))
        XCTAssertEqual(m.selection, .live(paneKey("web")), "the list picks into the pane")
        XCTAssertEqual(m.layout.focused, pane)
        XCTAssertFalse(win.isVisible || win2.isVisible, "never on screen")
    }
}
