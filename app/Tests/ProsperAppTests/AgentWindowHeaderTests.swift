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

    /// One element of an AX client's walk: role, AXDescription, AXTitle, AXValue, AXHelp and the frame. A Menu's
    /// accessibilityLabel arrives as its AXTitle (#887's "Recent folders"; the "⋯" reads label "More", title "Session
    /// actions"), a Text's words as its AXValue: `names` is all three.
    struct HeaderAX {
        let role: String, label: String, title: String, value: String, help: String
        let frame: CGRect
        /// Ignored by AppKit (NSAccessibility.unignoredChildren drops it): an AX client never sees it.
        var ignored = false
        /// What an AX client is shown, by any of its names (not an ignored node).
        func reads(_ n: String) -> Bool { !ignored && names.contains { $0.caseInsensitiveCompare(n) == .orderedSame } }
        var names: [String] { [label, title, value].filter { !$0.isEmpty } }
        func named(_ n: String) -> Bool { names.contains(n) }
        func named(prefix: String) -> Bool { names.contains { $0.hasPrefix(prefix) } }
        var name: String { names.first { ["Terminal", "Transcript"].contains($0) || $0.hasPrefix("Showing: ") } ?? names.first ?? "" }
    }

    @MainActor
    private func headerAXWalk(_ e: Any, _ out: inout [HeaderAX], depth: Int = 0) {
        guard depth < 40, let o = e as? NSObject else { return }
        func text(_ key: String) -> String {
            guard o.responds(to: Selector(key)) else { return "" }
            let v = o.value(forKey: key)
            return (v as? String) ?? (v as? NSAttributedString)?.string ?? ""
        }
        let frame = o.responds(to: Selector(("accessibilityFrame"))) ? (o.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero : .zero
        // #1103 F4: AppKit's own verdict, the one served to an AX client: an ignored node is replaced by its
        // unignored descendants (the raw children below still list it).
        let ignored = !NSAccessibility.unignoredChildren(from: [o]).contains { ($0 as AnyObject) === o }
        out.append(HeaderAX(role: text("accessibilityRole"), label: text("accessibilityLabel"), title: text("accessibilityTitle"),
                            value: text("accessibilityValue"), help: text("accessibilityHelp"), frame: frame, ignored: ignored))
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { headerAXWalk(k, &out, depth: depth + 1) }
    }

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

    static let pickerLabels: Set<String> = ["Focused view", "Default view", "Verbose view"]

    /// The real accessibility tree of a never-shown window (#887's technique; both attributes are put back after), at
    /// widths across every tier, in both modes: the picker is absent in Terminal mode and present in Transcript mode;
    /// the toggle reads Terminal then Transcript; every control has a name and a help text; no header button reads
    /// "Open in terminal"; the toggle and the "⋯" sit at the same place in both modes, and Terminal mode's folder takes
    /// the picker's room (no gap kept for it).
    @MainActor
    func testAccessibilityTreeReadsTheHeaderAndHidesThePickerInTerminalMode() throws {
        let set = Selector(("accessibilitySetValue:forAttribute:")), attrs = ["AXEnhancedUserInterface", "AXManualAccessibility"]
        let app = NSApplication.shared
        XCTAssertTrue(app.responds(to: set))
        defer { for a in attrs { app.perform(set, with: NSNumber(value: false), with: a) } }
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
        for a in attrs { app.perform(set, with: NSNumber(value: true), with: a) }
        var tiers: Set<String> = [], gapChecked = 0
        let pathIdeal = NSHostingView(rootView: Text(Self.headerPath).font(Neon.font(11, design: .monospaced))).fittingSize.width
        for width: CGFloat in [300, 360, 420, 480, 560, 700, 900] {
            var toggleAt: [CGRect] = [], menuAt: [CGRect] = []
            for mode in [AgentPaneMode.terminal, .transcript] {
                let header = AgentSessionHeader(row: row, session: a, cwd: Self.headerPath, open: {}, store: st,
                                                mode: mode, setMode: { _ in })
                let size = CGSize(width: width, height: 80)
                let (win, host) = headerHosted(header.frame(width: width, height: 80, alignment: .top), size)
                defer { win.close() }
                var tree: [HeaderAX] = []
                let deadline = Date().addingTimeInterval(5)
                repeat {
                    host.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    tree = []
                    headerAXWalk(host, &tree)
                } while !tree.contains(where: { $0.named("Session actions") }) && Date() < deadline
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
                XCTAssertEqual(menu.first?.help, "Open in terminal, rename, restart, stop or kill this session")
                XCTAssertFalse(tree.contains { $0.named(AgentWindowControls.openLabel) },
                               "no Open in terminal button in the header (\(tag))")
                let t = toggle.reduce(CGRect.null) { $0.union($1.frame) }
                toggleAt.append(t)
                menuAt.append(menu.first?.frame ?? .null)
                // #1103 F4: the Transcript line only; Terminal's title line still reads the icon as "Move" (left open, own entry).
                if mode == .transcript {
                    XCTAssertFalse(tree.contains { $0.reads("Move") }, "the folder icon is decoration (\(tag)): \(tree.filter { $0.named("Move") })")
                }
                // F1: Terminal mode drops the folder where the line cannot hold its floors (the narrow widths here).
                let found = tree.first { $0.named(Self.headerPath) }
                if mode == .transcript {
                    let path = try XCTUnwrap(found, "the path is read (\(tag))").frame
                    XCTAssertGreaterThan(abs(path.midY - t.midY), sz(10), "Transcript mode: the folder on its own line (\(tag))")
                } else if let path = found?.frame {
                    XCTAssertEqual(path.midY, t.midY, accuracy: 2, "Terminal mode: one line, the folder on it (\(tag))")
                    // No gap kept for the picker: what sits left of the toggle on its line ends one spacer from it.
                    if path.width > 1, path.width < pathIdeal - 1 {
                        let left = tree.filter { $0.frame.width > 0 && $0.frame.maxX <= t.minX + 0.5 && abs($0.frame.midY - t.midY) < sz(8) }
                        let gap = t.minX - (left.map(\.frame.maxX).max() ?? -1000)
                        // path→extra slot 6, slot spacing 8, Spacer 8, line spacing 8, plus under one 11 pt glyph the
                        // middle cut leaves (ticket 3 read 32.5-37.5); a kept picker gap read 60-224 (mutant M5a).
                        XCTAssertLessThanOrEqual(gap, sz(6 + 8 + 8 + 8 + 11) + 1, "Terminal mode: the cut path runs up to the toggle (\(tag))")
                        gapChecked += 1
                    }
                }
                XCTAssertFalse(win.isVisible, "never on screen")
            }
            XCTAssertEqual(toggleAt.count, 2)
            XCTAssertEqual(toggleAt.first?.minX ?? -1, toggleAt.last?.minX ?? -2, accuracy: 0.5, "the toggle stays put at \(width)")
            XCTAssertEqual(toggleAt.first?.maxX ?? -1, toggleAt.last?.maxX ?? -2, accuracy: 0.5, "the toggle keeps its width at \(width)")
            XCTAssertEqual(menuAt.first?.minX ?? -1, menuAt.last?.minX ?? -2, accuracy: 0.5, "the \"⋯\" stays put at \(width)")
            XCTAssertEqual(menuAt.first?.minY ?? -1, menuAt.last?.minY ?? -2, accuracy: 0.5, "the \"⋯\" stays on its line at \(width)")
            print("#1103 \(width): toggle \(toggleAt.map(\.minX)) menu \(menuAt.map(\.minX))")
        }
        XCTAssertEqual(tiers, ["segments", "menu"], "the sweep crosses the tiers")
        XCTAssertGreaterThan(gapChecked, 0, "the no-gap check ran at a width where Terminal mode cuts the path")
    }

    /// A hosted, never-shown window's accessibility tree once `ready` holds (the app's AX attributes set by the caller).
    @MainActor
    private func headerAXTree<V: View>(_ view: V, _ size: CGSize, ready: (HeaderAX) -> Bool) -> (NSWindow, [HeaderAX]) {
        let (win, host) = headerHosted(view.frame(width: size.width, height: size.height, alignment: .top), size)
        var tree: [HeaderAX] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            tree = []
            headerAXWalk(host, &tree)
        } while !tree.contains(where: ready) && Date() < deadline
        return (win, tree)
    }

    /// #1103 F1: Terminal mode, a long title. The folder comes with its path at least at its floor (sz(110), or the
    /// whole path when shorter), the title keeping its own floor (sz(80)); where the line cannot hold both floors and
    /// the chip, no folder at all: never its icon alone (pixels: nothing drawn between the chip and the switch).
    /// Whether the folder shows at each width is written out, not derived from the code under test.
    @MainActor
    func testTerminalHeaderKeepsAReadablePathOrDropsTheFolder() throws {
        let set = Selector(("accessibilitySetValue:forAttribute:")), attrs = ["AXEnhancedUserInterface", "AXManualAccessibility"]
        let app = NSApplication.shared
        XCTAssertTrue(app.responds(to: set))
        defer { for a in attrs { app.perform(set, with: NSNumber(value: false), with: a) } }
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let a = session("prosper-ios", .working, ago: 40, alias: Self.headerTitle)
        let st = store([a])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(a.key))
        let row = try XCTUnwrap(m.selectedRow)
        XCTAssertEqual(row.title, Self.headerTitle)
        for a in attrs { app.perform(set, with: NSNumber(value: true), with: a) }
        let short = "/srv/api"
        func ideal(_ p: String) -> CGFloat {
            NSHostingView(rootView: Text(p).font(Neon.font(11, design: .monospaced))).fittingSize.width
        }
        let longIdeal = ideal(Self.headerPath), shortIdeal = ideal(short)
        XCTAssertGreaterThan(longIdeal, sz(300))
        XCTAssertLessThan(shortIdeal, sz(80))
        // window width: the folder drawn with the long path, with the short path
        let expected: [(CGFloat, Bool, Bool)] = [(300, false, false), (340, false, false), (400, false, true),
                                                 (480, true, true), (560, true, true), (700, true, true), (900, true, true)]
        var log: [String] = []
        for (width, longShown, shortShown) in expected {
            for (path, shown, full) in [(Self.headerPath, longShown, longIdeal), (short, shortShown, shortIdeal)] {
                let header = AgentSessionHeader(row: row, session: a, cwd: path, open: {}, store: st, mode: .terminal,
                                                setMode: { _ in })
                let size = CGSize(width: width, height: 80)
                let (win, tree) = headerAXTree(header, size) { $0.named("Session actions") }
                defer { win.close() }
                let tag = "\(width) \(path == short ? "short" : "long") path"
                let toggle = tree.filter { $0.named("Terminal") || $0.named("Transcript") || $0.named(prefix: "Showing: ") }
                let t = toggle.reduce(CGRect.null) { $0.union($1.frame) }
                XCTAssertFalse(toggle.isEmpty, "the switch (\(tag))")
                let title = try XCTUnwrap(tree.first { $0.named(Self.headerTitle) }, "the title (\(tag))").frame
                let chip = try XCTUnwrap(tree.first { $0.named("Working") }, "the chip (\(tag))").frame
                let p = tree.first { $0.named(path) }?.frame
                log.append("\(tag): title \(title.width) path \(p.map { "\($0.width)" } ?? "none") switch \(t.minX)")
                XCTAssertEqual(p != nil, shown, "the folder drawn (\(tag))")
                if let p {
                    XCTAssertEqual(p.midY, t.midY, accuracy: 2, "on the switch's line (\(tag))")
                    if full < sz(110) {
                        XCTAssertEqual(p.width, full, accuracy: 1, "a short path whole (\(tag))")
                    } else {
                        // The middle cut lands on a glyph: up to one 11 pt monospaced glyph under the floor.
                        XCTAssertGreaterThanOrEqual(p.width, sz(110) - sz(7), "a long path at its floor (\(tag))")
                    }
                    XCTAssertGreaterThanOrEqual(title.width, sz(80) - sz(10), "the title readable beside it (\(tag))")
                }
                // Never the icon alone: ink between the chip's capsule and the switch on the title line exactly when
                // the folder is drawn.
                let rep = try render(header, size: size, dark: true, margin: 0)
                let k = CGFloat(rep.pixelsWide) / size.width
                let bg = try XCTUnwrap(rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
                var ink = 0
                let xs = Int((chip.maxX + sz(7) + 1) * k)..<Int((t.minX - 1) * k)
                let ys = Int(AgentSessionHeader.padTop * k)..<Int((AgentSessionHeader.padTop + AgentSessionHeader.lineHeight) * k)
                for y in ys { for x in xs {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent)
                        + abs(c.blueComponent - bg.blueComponent) > 0.15 { ink += 1 }
                } }
                XCTAssertEqual(ink > 0, shown, "drawn between the chip and the switch: \(ink) px (\(tag))")
                XCTAssertFalse(win.isVisible, "never on screen")
            }
        }
        print("#1103 F1 floors\n" + log.joined(separator: "\n"))
    }

    /// #1103 F2: the sidebar's "Agent Sessions" and the session header's title share one centre line in the whole
    /// window, at 0.7, 0.85 and 1.0, in both modes (the real accessibility frames of a never-shown window).
    @MainActor
    func testSidebarTitleSharesTheHeaderTitleLine() throws {
        let set = Selector(("accessibilitySetValue:forAttribute:")), attrs = ["AXEnhancedUserInterface", "AXManualAccessibility"]
        let app = NSApplication.shared
        XCTAssertTrue(app.responds(to: set))
        defer { for a in attrs { app.perform(set, with: NSNumber(value: false), with: a) } }
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
            for a in attrs { app.perform(set, with: NSNumber(value: true), with: a) }
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
                XCTAssertEqual(hs.first ?? -1, hs.last ?? -2, accuracy: 0.5, "one height per mode, whatever the width (\(mode) \(scale))")
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
            XCTAssertGreaterThanOrEqual(field.frame.height + 0.5, field.intrinsicContentSize.height, "its text fits at \(scale)")
            XCTAssertLessThanOrEqual(field.intrinsicContentSize.height, AgentSessionHeader.lineHeight + 0.5, "the line holds it at \(scale)")
            XCTAssertGreaterThan(f.width, sz(60), "room to type at \(scale)")
            XCTAssertGreaterThanOrEqual(f.minX, sz(16) - 0.5, "inside the padding at \(scale)")
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
}
