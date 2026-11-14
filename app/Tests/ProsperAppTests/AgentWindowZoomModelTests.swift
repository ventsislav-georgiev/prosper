import AppKit
import XCTest
@testable import ProsperApp

/// #900 (#831 B2 step 2; spec 3.3, 3.4, 7.4, 11.2; R6.12, R1193-5): zoom and too-small in the window MODEL. Model
/// only: no view, no window shown (the Esc row hands built events to a never-shown window), nothing posted. Sessions
/// are fakes; transcripts are files under tempDir(); polls are counted on the transcript's offMain seam (one call per
/// read), starts and suspends on each pane's running / suspended flags; the task store seam reads nothing. Every row
/// that needs the split gate saves, sets and restores it (withTreeGate's defer); the UI scale likewise.
extension AgentWindowD1Tests {
    /// Reads per pane name. Mutated only from offMain, which poll() calls on the main actor (the model is @MainActor);
    /// the rows run the read inline, so everything here runs on main.
    final class ZoomModelLog { var polls: [String: Int] = [:] }

    struct ZoomPaneState: Equatable {
        var running: Bool, suspended: Bool, generation: Int, blocks: Int, polls: Int
    }

    /// A visible-ready model with one live pane per name (columns, the first focused) in the wide area; each pane's
    /// reads counted. Not yet visible: the row decides.
    @MainActor
    func zoomFixture(_ names: [String], layouts: UserDefaults? = nil)
        throws -> (m: AgentWindowModel, files: [String: URL], log: ZoomModelLog) {
        var files: [String: URL] = [:]
        for n in names { files[n] = try transcriptFile(n) }
        let st = store(names.map { session($0, .idle, path: files[$0]?.path) })
        let m = windowModel(st, layouts: layouts)
        m.paneArea = Self.wideArea
        m.adopt(paneLayout(names.map { paneTarget($0) }))
        let log = ZoomModelLog()
        for n in names {
            let t = try runtime(m, n).transcript
            // Runs where poll() calls it: on main; the read itself inline.
            t.offMain = { job in log.polls[n, default: 0] += 1; job() }
            t.taskStoreDirectory = { _ in nil }   // never a real task store
        }
        return (m, files, log)
    }

    @MainActor
    func zoomStates(_ m: AgentWindowModel, _ names: [String], _ log: ZoomModelLog) throws -> [String: ZoomPaneState] {
        var out: [String: ZoomPaneState] = [:]
        for n in names {
            let t = try runtime(m, n).transcript
            out[n] = ZoomPaneState(running: t.running, suspended: t.suspended, generation: t.generation,
                                   blocks: t.blocks.count, polls: log.polls[n] ?? 0)
        }
        return out
    }

    /// The panes that went running -> suspended, and not running -> running, between two states.
    func zoomMoves(_ a: [String: ZoomPaneState], _ b: [String: ZoomPaneState]) -> (suspended: [String], started: [String]) {
        let names = a.keys.sorted()
        return (names.filter { a[$0]?.running == true && b[$0]?.running == false && b[$0]?.suspended == true },
                names.filter { a[$0]?.running == false && b[$0]?.running == true })
    }

    /// Truth table (7.4, 3.4, 15.0): shown panes and drawn frames for 1, 2 and 3 panes, zoomed or not, too small or
    /// not, the gate on or off. Zoomed or too small: the focused pane alone is shown; the frames stay the tiling under
    /// a zoom (they change only for too small and the gate off).
    @MainActor
    func testZoomModelShownPanesTruthTable() throws {
        let small = CGRect(x: 0, y: 0, width: 300, height: 300)   // under two 300·s columns at every scale up to 1
        for gate in [false, true] {
            for count in [1, 2, 3] {
                for zoomed in [false, true] {
                    for tooSmall in [false, true] {
                        let why = "gate \(gate), \(count) panes, zoomed \(zoomed), too small \(tooSmall)"
                        try withTreeGate(gate) {
                            let names = ["p1", "p2", "p3"].prefix(count).map { $0 }
                            let st = store(names.map { session($0, .idle) })
                            let m = windowModel(st)
                            defer { m.close() }
                            m.paneArea = tooSmall ? small : Self.wideArea
                            m.adopt(paneLayout(names.map { paneTarget($0) }))
                            let last = try XCTUnwrap(m.layout.order.last)
                            m.adopt(try m.layout.focus(last).get())
                            if zoomed { m.adopt(m.layout.toggleZoom()) }
                            let alone = !gate || count == 1 || zoomed || tooSmall
                            XCTAssertEqual(m.shownPanes, alone ? [last] : Set(m.layout.order), why)
                            let tiled = gate && count > 1 && !tooSmall
                            XCTAssertEqual(m.paneFrames(in: m.paneArea).count, tiled ? count : 1, "frames: \(why)")
                            XCTAssertEqual(m.layout.zoomed, zoomed && count > 1 ? last : nil, "zoom state: \(why)")
                        }
                    }
                }
            }
        }
    }

    /// R6.12 (7.4, OQ-2): a focus key while zoomed moves the zoom: exactly one pane suspends and one starts (with ONE
    /// catch-up poll from its kept offset, no re-read), every frame stays put, and the moved zoom is autosaved.
    @MainActor
    func testZoomModelAZoomMoveSuspendsOneAndStartsOne() throws {
        try withTreeGate(true) {
            let d = layoutSuite()
            let names = ["a", "b", "c"]
            let (m, files, log) = try zoomFixture(names, layouts: d)
            defer { m.close() }
            m.setVisible(true)
            let s0 = try zoomStates(m, names, log)
            XCTAssertTrue(names.allSatisfy { s0[$0]?.running == true && s0[$0]?.polls == 1 && s0[$0]?.blocks == 1 })
            XCTAssertTrue(m.perform(.zoom))
            let a = try paneID(m, "a"), b = try paneID(m, "b"), c = try paneID(m, "c")
            XCTAssertEqual(m.layout.zoomed, a)
            XCTAssertEqual(m.shownPanes, [a], "zoomed: the zoomed pane alone is shown")
            let s1 = try zoomStates(m, names, log)
            XCTAssertEqual(zoomMoves(s0, s1).suspended, ["b", "c"], "the others suspend at once (no grace)")
            XCTAssertEqual(zoomMoves(s0, s1).started, [])
            XCTAssertTrue(names.allSatisfy { s1[$0]?.polls == 1 && s1[$0]?.blocks == 1 }, "no read; blocks kept")
            let frames = m.paneFrames(in: m.paneArea)
            XCTAssertEqual(frames.count, 3, "the tiling stays the geometry")
            for f in [files["b"], files["c"]] { try append(try XCTUnwrap(f), line(say("while zoomed away"))) }

            // ⌘] while zoomed: the zoom moves to b.
            let writes = m.layoutWrites
            XCTAssertTrue(m.perform(.cycle(1)))
            XCTAssertEqual(m.layout.focused, b)
            XCTAssertEqual(m.layout.zoomed, b, "the zoom moved, not unzoomed")
            XCTAssertEqual(m.shownPanes, [b])
            XCTAssertEqual(m.paneFrames(in: m.paneArea), frames, "every frame stays put")
            let s2 = try zoomStates(m, names, log)
            XCTAssertEqual(zoomMoves(s1, s2).suspended, ["a"], "exactly one suspend")
            XCTAssertEqual(zoomMoves(s1, s2).started, ["b"], "exactly one start")
            XCTAssertEqual(s2["b"]?.polls, 2, "one catch-up poll")
            XCTAssertEqual(s2["b"]?.generation, s1["b"]?.generation, "from the kept offset, not a re-read")
            XCTAssertEqual(s2["b"]?.blocks, 2, "caught up the line written while suspended")
            XCTAssertEqual(s2["a"]?.blocks, 1, "the suspended pane keeps its blocks")
            XCTAssertEqual(s2["c"], s1["c"], "the third pane untouched")
            XCTAssertEqual(m.layoutWrites, writes + 1, "autosaved once")
            let saved = Preferences.agentWindowLayouts(in: d).layouts.first { $0.id == m.layout.id }
            XCTAssertEqual(saved?.zoomed, b, "the blob carries the moved zoom")

            // ⌥⌘→ while zoomed: the zoom moves to c by direction, the same counts.
            XCTAssertTrue(m.perform(.focus(.right)))
            XCTAssertEqual(m.layout.zoomed, c)
            XCTAssertEqual(m.paneFrames(in: m.paneArea), frames, "every frame stays put")
            let s3 = try zoomStates(m, names, log)
            XCTAssertEqual(zoomMoves(s2, s3).suspended, ["b"])
            XCTAssertEqual(zoomMoves(s2, s3).started, ["c"])
            XCTAssertEqual(s3["c"]?.polls, 2, "one catch-up poll")
            XCTAssertEqual(s3["c"]?.generation, s2["c"]?.generation)
            XCTAssertEqual(s3["c"]?.blocks, 2)
            XCTAssertEqual(s3["a"], s2["a"], "the first pane untouched")
            XCTAssertEqual(Preferences.agentWindowLayouts(in: d).layouts.first { $0.id == m.layout.id }?.zoomed, c)
        }
    }

    /// 7.4 unzoom: every suspended pane resumes with exactly one catch-up poll from its kept offset; the zoomed pane
    /// reads nothing.
    @MainActor
    func testZoomModelUnzoomResumesEachSuspendedPaneWithOneCatchUpPoll() throws {
        try withTreeGate(true) {
            let names = ["a", "b", "c"]
            let (m, files, log) = try zoomFixture(names)
            defer { m.close() }
            m.setVisible(true)
            XCTAssertTrue(m.perform(.zoom))
            for f in [files["b"], files["c"]] { try append(try XCTUnwrap(f), line(say("while zoomed away"))) }
            let s1 = try zoomStates(m, names, log)
            XCTAssertTrue(m.perform(.zoom))
            XCTAssertTrue(m.layout.zoomed == nil)
            XCTAssertEqual(m.shownPanes, Set(m.layout.order))
            let s2 = try zoomStates(m, names, log)
            XCTAssertEqual(zoomMoves(s1, s2).started, ["b", "c"])
            XCTAssertEqual(zoomMoves(s1, s2).suspended, [])
            for n in ["b", "c"] {
                XCTAssertEqual(s2[n]?.polls, (s1[n]?.polls ?? 0) + 1, "\(n): one catch-up poll")
                XCTAssertEqual(s2[n]?.generation, s1[n]?.generation, "\(n): no re-read")
                XCTAssertEqual(s2[n]?.blocks, 2, "\(n): caught up")
            }
            XCTAssertEqual(s2["a"], s1["a"], "the zoomed pane reads nothing")
        }
    }

    /// 3.4 / R1193-5: too small, the focused pane alone runs and the others suspend (blocks kept); grown back, each
    /// resumes with one catch-up poll. A hidden window still stops every pane (11.2: blocks freed).
    @MainActor
    func testZoomModelTooSmallSuspendsAndAHiddenWindowStops() throws {
        try withTreeGate(true) {
            let names = ["a", "b"]
            let (m, files, log) = try zoomFixture(names)
            defer { m.close() }
            m.setVisible(true)
            let s0 = try zoomStates(m, names, log)
            m.paneArea = CGRect(x: 0, y: 0, width: 300, height: 300)
            XCTAssertEqual(m.shownPanes, [try paneID(m, "a")])
            let s1 = try zoomStates(m, names, log)
            XCTAssertEqual(zoomMoves(s0, s1).suspended, ["b"])
            XCTAssertEqual(s1["b"]?.blocks, 1, "kept")
            XCTAssertEqual(s1["a"], s0["a"], "the focused pane runs on")
            try append(try XCTUnwrap(files["b"]), line(say("while too small")))
            m.paneArea = Self.wideArea
            let s2 = try zoomStates(m, names, log)
            XCTAssertEqual(zoomMoves(s1, s2).started, ["b"])
            XCTAssertEqual(s2["b"]?.polls, (s1["b"]?.polls ?? 0) + 1, "one catch-up poll")
            XCTAssertEqual(s2["b"]?.generation, s1["b"]?.generation)
            XCTAssertEqual(s2["b"]?.blocks, 2)

            m.paneArea = CGRect(x: 0, y: 0, width: 300, height: 300)
            XCTAssertTrue(try runtime(m, "b").transcript.suspended)
            m.setVisible(false)
            for n in names {
                let t = try runtime(m, n).transcript
                XCTAssertTrue(!t.running && !t.suspended && t.blocks.isEmpty, "\(n): hidden: stopped, blocks freed")
            }
        }
    }

    /// 11.2 "closing a pane stops its transcript": a pane closed while zoomed is stopped (freed), not suspended; the
    /// close unzooms (7.3), so the others resume with one catch-up poll each.
    @MainActor
    func testZoomModelAPaneClosedWhileZoomedIsStopped() throws {
        try withTreeGate(true) {
            let names = ["a", "b", "c"]
            let (m, _, log) = try zoomFixture(names)
            defer { m.close() }
            m.setVisible(true)
            XCTAssertTrue(m.perform(.zoom))
            let c = try paneID(m, "c"), tc = try runtime(m, "c").transcript
            XCTAssertTrue(tc.suspended)
            let s1 = try zoomStates(m, ["a", "b"], log)
            m.closePane(c)   // an unfocused, suspended pane
            XCTAssertTrue(m.runtimes[c] == nil, "its runtime is gone")
            XCTAssertTrue(!tc.running && !tc.suspended && tc.blocks.isEmpty, "stopped, not suspended")
            XCTAssertTrue(m.layout.zoomed == nil, "a close unzooms (7.3)")
            let s2 = try zoomStates(m, ["a", "b"], log)
            XCTAssertEqual(s2["b"]?.polls, (s1["b"]?.polls ?? 0) + 1, "b resumes with one catch-up poll")
            XCTAssertEqual(s2["a"], s1["a"])

            XCTAssertTrue(m.perform(.zoom))
            let ta = try runtime(m, "a").transcript
            XCTAssertTrue(m.perform(.closePane))   // the focused, zoomed pane
            XCTAssertTrue(!ta.running && !ta.suspended && ta.blocks.isEmpty, "the zoomed pane closed: stopped")
            let tb = try runtime(m, "b").transcript
            XCTAssertTrue(tb.running && !tb.suspended, "the last pane runs")
        }
    }

    /// 15.0: with the gate off follow() stops and starts exactly as before this step: a two-pane layout shows its
    /// focused pane alone, and the pane a focus change leaves is STOPPED (blocks freed), its next start a re-read.
    @MainActor
    func testZoomModelGateOffStopsAndStartsAsBefore() throws {
        try withTreeGate(false) {
            let names = ["a", "b"]
            let (m, _, log) = try zoomFixture(names)
            defer { m.close() }
            m.setVisible(true)
            let s0 = try zoomStates(m, names, log)
            XCTAssertEqual(s0["a"]?.running, true)
            XCTAssertTrue(s0["b"]?.running == false && s0["b"]?.suspended == false && s0["b"]?.polls == 0)
            m.focusPane(try paneID(m, "b"))
            let s1 = try zoomStates(m, names, log)
            XCTAssertTrue(s1["a"]?.running == false && s1["a"]?.suspended == false && s1["a"]?.blocks == 0,
                          "the pane left behind is stopped, blocks freed")
            XCTAssertTrue(s1["b"]?.running == true && s1["b"]?.polls == 1)
            m.focusPane(try paneID(m, "a"))
            let s2 = try zoomStates(m, names, log)
            XCTAssertEqual(s2["a"]?.polls, (s1["a"]?.polls ?? 0) + 1)
            XCTAssertNotEqual(s2["a"]?.generation, s1["a"]?.generation, "a re-read, not a catch-up")
            XCTAssertTrue(s2["b"]?.running == false && s2["b"]?.suspended == false && s2["b"]?.blocks == 0)
            // A zoomed blob with the gate off changes nothing: the focused pane alone, the other stopped.
            m.adopt(m.layout.toggleZoom())
            XCTAssertEqual(m.shownPanes, [try paneID(m, "a")])
            let s3 = try zoomStates(m, names, log)
            XCTAssertTrue(s3["b"]?.suspended == false && s3["b"]?.running == false)
        }
    }

    /// Esc, every modifier set (7.4): never a tree action, never the window's close, on the pure routes.
    @MainActor
    func testZoomModelEscIsNeverATreeActionOnThePureRoute() {
        let mods: [NSEvent.ModifierFlags] = [[], [.shift], [.option], [.control], [.command], [.command, .shift]]
        for gate in [false, true] {
            for focus in [PaneKeys.KeyFocus.sidebar, .pane] {
                for panes in [1, 2, 3] {
                    for responder in [AgentsNSWindow.ResponderKind.text, .terminal, .other] {
                        for f in mods {
                            let e = treeKey(53, f, "\u{1b}")
                            let c = PaneKeys.Context(responder: responder, keyFocus: focus, panes: panes, splitsEnabled: gate)
                            let why = "gate \(gate), \(focus), \(panes) panes, \(responder), \(f.rawValue)"
                            XCTAssertTrue(PaneKeys.treeAction(for: e, context: c, renaming: false, form: false) == nil, why)
                            let a = PaneKeys.action(for: e, context: c)
                            XCTAssertTrue(a != PaneAction.zoom && a != PaneAction.closePane, why)
                            XCTAssertNotEqual(AgentsNSWindow.route(e, responder: responder, sidebarFocused: focus == .sidebar,
                                                                   terminalMode: false), .close, why)
                        }
                    }
                }
            }
        }
    }

    /// Esc on a zoomed model through a never-shown window's performKeyEquivalent: the layout (and its zoom) unchanged,
    /// the window never asked to close.
    @MainActor
    func testZoomModelEscNeverUnzoomsNorClosesOnTheModel() throws {
        try withTreeGate(true) {
            let (win, m, rec) = treeWindow(area: CGSize(width: 2000, height: 600))
            defer { win.close(); m.close() }
            XCTAssertTrue(press(win, "⌘D"))
            XCTAssertTrue(press(win, "⇧⌘Return"))
            let zoomed = m.layout
            XCTAssertTrue(zoomed.zoomed != nil)
            for f in [[], [.shift], [.option], [.control], [.command], [.command, .shift]] as [NSEvent.ModifierFlags] {
                _ = win.performKeyEquivalent(with: treeKey(53, f, "\u{1b}"))
                XCTAssertEqual(m.layout, zoomed, "Esc \(f.rawValue): still zoomed, the same panes")
                XCTAssertEqual(m.shownPanes, [m.layout.focused])
            }
            XCTAssertEqual(rec.asks, 0, "Esc never closes")
        }
    }

    /// 3.3: the minimum is 300x200·s, one value for perform's split and paneFrames: at scale 0.7, 0.85 and 1.0 a
    /// split passes exactly where the same two panes tile, and is refused (no room) exactly where they fall back.
    @MainActor
    func testZoomModelTheScaledMinimumIsOneForTheSplitAndTheTiling() throws {
        let savedScale = ThemeRuntime.scale
        defer { ThemeRuntime.scale = savedScale }
        try withTreeGate(true) {
            for s in [0.7, 0.85, 1.0] as [CGFloat] {
                ThemeRuntime.scale = s
                let w = 300 * s, h = 200 * s
                for axis in [PaneNode.Axis.columns, .rows] {
                    for short in [false, true] {
                        let cut: CGFloat = short ? 1 : 0
                        let size = axis == .columns ? CGSize(width: 2 * w - cut, height: h) : CGSize(width: w, height: 2 * h - cut)
                        let why = "scale \(s), \(axis), short \(short)"
                        let m = windowModel(store([session("api", .idle)]))
                        defer { m.close() }
                        m.paneArea = CGRect(origin: .zero, size: size)
                        XCTAssertEqual(m.paneMinimum.width, w, accuracy: 0.001, why)
                        XCTAssertEqual(m.paneMinimum.height, h, accuracy: 0.001, why)
                        // The two panes that split would make, built with no minimum, then tiled by the model.
                        let pair = try m.layout.split(axis: axis, minimum: .zero, in: .zero).get()
                        XCTAssertTrue(m.perform(.split(axis)), "acted (split or refusal shown): \(why)")
                        XCTAssertEqual(m.layout.panes.count, short ? 1 : 2, why)
                        XCTAssertEqual(m.paneRefusal, short ? PaneRefusal.noRoom : nil, why)
                        m.adopt(pair)
                        XCTAssertEqual(m.paneFrames(in: m.paneArea).count, short ? 1 : 2, "the tiling agrees: \(why)")
                    }
                }
            }
        }
    }
}
