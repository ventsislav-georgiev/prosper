import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #900 (#831 B2 step 4, spec 7.1, 7.2, 9.1, 15.0; R900-2, riders 1197 (a) and (b)): ⌃⌘S hides and shows the sidebar,
/// behind the split gate. Offscreen only: events are built with NSEvent.keyEvent and handed to a never-shown window's
/// performKeyEquivalent or to pure functions; points are literals; views are hosted in windows never ordered in; the
/// accessibility flags are this process's only (AXTreeSupport). The preference lives in Preferences.defaults, which under
/// XCTest is the private in-memory XCTestDefaults suite; every row saves the key, the split gate and the scale and puts
/// them back in a defer. Sessions are fakes.
extension AgentWindowD1Tests {
    static let sidebarKey = "agentWindowSidebarHidden"

    /// Runs `body` with the gate `on`, the preference unset, the scale 1.0; everything put back after (main actor).
    @MainActor
    func withSidebarRow(gate on: Bool, _ body: () throws -> Void) rethrows {
        let d = Preferences.defaults, saved = d.object(forKey: Self.sidebarKey)
        let gate = AgentPaneLayout.splitsEnabled, scale = ThemeRuntime.scale
        defer {
            if let saved { d.set(saved, forKey: Self.sidebarKey) } else { d.removeObject(forKey: Self.sidebarKey) }
            AgentPaneLayout.splitsEnabled = gate
            ThemeRuntime.scale = scale
        }
        d.removeObject(forKey: Self.sidebarKey)
        AgentPaneLayout.splitsEnabled = on
        ThemeRuntime.scale = 1.0
        try body()
    }

    /// ⌃⌘S as a US layout gives it (the control character typed, "s" ignoring modifiers), or `ign` for another layout.
    @MainActor
    func sidebarChord(_ ign: String = "s") -> NSEvent {
        treeKey(1, [.control, .command], "\u{13}", ign)
    }

    var sidebarPref: Any? { Preferences.defaults.object(forKey: Self.sidebarKey) }

    // MARK: The chord

    /// Gate on: ⌃⌘S through the window's performKeyEquivalent is handled, hides the sidebar, writes true, and gives the
    /// panes the keys; again: shown, false written, the keys stay with the panes. A Cyrillic layout's chord (R900-1) too.
    @MainActor
    func testSidebarHiddenChordTogglesAndWritesTheChoiceWithTheGateOn() throws {
        try withSidebarRow(gate: true) {
            let (win, m, rec) = treeWindow()
            defer { win.close(); m.close() }
            m.keyFocus = .sidebar
            XCTAssertTrue(win.performKeyEquivalent(with: sidebarChord()), "handled")
            XCTAssertTrue(m.sidebarHidden && !m.sidebarShown, "hidden")
            XCTAssertEqual(sidebarPref as? Bool, true, "written")
            XCTAssertEqual(m.keyFocus, .pane, "a hidden sidebar never holds the keys")
            XCTAssertTrue(win.performKeyEquivalent(with: sidebarChord("ы")), "the Cyrillic chord, by the S key's code")
            XCTAssertTrue(!m.sidebarHidden && m.sidebarShown, "shown again")
            XCTAssertEqual(sidebarPref as? Bool, false, "written")
            XCTAssertEqual(m.keyFocus, .pane, "showing it takes no keys")
            XCTAssertEqual(rec.asks, 0, "the window never asked to close")
            XCTAssertEqual(m.layout.panes.count, 1, "the layout untouched")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// Gate off (the product): ⌃⌘S is not routed (the pure function is nil, the window passes it), nothing is written, the
    /// sidebar and the keys stay. A preference left true by hand still draws the sidebar: the parent's window.
    @MainActor
    func testSidebarHiddenGateOffRoutesNothingAndWritesNothing() throws {
        try withSidebarRow(gate: false) {
            let (win, m, _) = treeWindow()
            defer { win.close(); m.close() }
            m.keyFocus = .sidebar
            let ctx = PaneKeys.Context(responder: .other, keyFocus: .sidebar, panes: 1, splitsEnabled: false)
            XCTAssertTrue(PaneKeys.treeAction(for: sidebarChord(), context: ctx, renaming: false, form: false) == nil)
            XCTAssertFalse(win.performKeyEquivalent(with: sidebarChord()), "passed on, as before")
            XCTAssertFalse(win.performKeyEquivalent(with: sidebarChord("ы")))
            XCTAssertTrue(sidebarPref == nil, "nothing written")
            XCTAssertFalse(m.sidebarHidden)
            XCTAssertEqual(m.keyFocus, .sidebar, "the keys stay")
            Preferences.agentWindowSidebarHidden = true
            let off = windowModel(store([session("api", .idle)]))
            defer { off.close() }
            XCTAssertTrue(off.sidebarHidden && off.sidebarShown, "read, but the gate off draws the sidebar")
            XCTAssertEqual(off.keyFocus, .sidebar, "gate off: a new model's keys are the sidebar's, as before")
            let size = CGSize(width: 1600, height: 900)
            XCTAssertEqual(off.sidebarFrame(in: size), CGRect(x: 0, y: 0, width: 290, height: 900), "the parent's sidebar")
            XCTAssertEqual(off.paneAreaFrame(in: size), CGRect(x: 291, y: 0, width: 1309, height: 900), "the parent's area")
        }
    }

    /// R900-2: the preference is read when a window's model is made: set, the model starts hidden; unset, shown.
    /// A model made hidden (the restore of the saved choice) gives the panes the keys: a hidden sidebar never holds them.
    @MainActor
    func testSidebarHiddenPreferenceIsReadWhenAModelIsMade() throws {
        try withSidebarRow(gate: true) {
            let shown = windowModel(store([session("api", .idle)]))
            defer { shown.close() }
            XCTAssertTrue(shown.sidebarShown, "unset reads as shown")
            Preferences.agentWindowSidebarHidden = true
            let hidden = windowModel(store([session("api", .idle)]))
            defer { hidden.close() }
            XCTAssertTrue(hidden.sidebarHidden && !hidden.sidebarShown, "set: starts hidden")
            XCTAssertEqual(hidden.keyFocus, .pane, "made hidden: the panes have the keys")
            XCTAssertEqual(shown.keyFocus, .sidebar, "made shown: the sidebar has them, as before")
            XCTAssertTrue(hidden.perform(.toggleSidebar), "shown again")
            XCTAssertEqual(hidden.keyFocus, .pane, "showing it takes no keys")
            XCTAssertTrue(shown.sidebarShown, "an existing model keeps its own value")
        }
    }

    // MARK: Geometry, hit test and keys

    /// Hidden: no sidebar frame, the pane area from x = 0 under the band, a click where the sidebar was is the pane
    /// area's (the keys go to the panes, both through the model and the window's rule). Shown again: the frames as before.
    /// Pick Another while hidden shows the sidebar (it gives the sidebar the keys). Literal numbers at scale 1.0.
    @MainActor
    func testSidebarHiddenFramesHitTestAndKeyFocus() throws {
        try withSidebarRow(gate: true) {
            let m = windowModel(store([session("api", .idle)]))
            defer { m.close() }
            let size = CGSize(width: 1600, height: 900)
            let sidebar = m.sidebarFrame(in: size), area = m.paneAreaFrame(in: size)
            XCTAssertEqual(sidebar, CGRect(x: 0, y: 0, width: 290, height: 900))
            XCTAssertEqual(area, CGRect(x: 291, y: 30, width: 1309, height: 870))
            XCTAssertTrue(m.perform(.toggleSidebar))
            XCTAssertTrue(m.sidebarFrame(in: size) == nil, "hidden: no sidebar frame")
            XCTAssertEqual(m.paneAreaFrame(in: size), CGRect(x: 0, y: 30, width: 1600, height: 870), "from x = 0")
            m.keyFocus = .sidebar   // as if left there by hand: a click where the sidebar was moves it
            XCTAssertFalse(m.mouseDown(at: CGPoint(x: 100, y: 200), in: size), "one pane: the click passes")
            XCTAssertEqual(m.keyFocus, .pane, "a point where the sidebar was is the pane area's")
            m.keyFocus = .sidebar
            XCTAssertFalse(AgentsNSWindow.mouseDown(m, at: CGPoint(x: 100, y: 200), in: size))
            XCTAssertEqual(m.keyFocus, .pane, "the window's rule too")
            XCTAssertTrue(m.perform(.toggleSidebar))
            XCTAssertEqual(m.sidebarFrame(in: size), sidebar, "shown again: as before")
            XCTAssertEqual(m.paneAreaFrame(in: size), area, "shown again: as before")
            XCTAssertTrue(m.perform(.toggleSidebar))
            m.pickAnother(m.layout.focused)
            XCTAssertTrue(m.sidebarShown, "Pick Another shows the sidebar it hands the keys to")
            XCTAssertEqual(m.keyFocus, .sidebar)
            XCTAssertEqual(sidebarPref as? Bool, false)
        }
    }

    // MARK: The band and the root view

    final class SidebarProbeBox { var seen: [String: [CGRect]] = [:] }

    /// Fixed slots: at 0.7, 0.85 and 1.0 one hosted root view (never shown) is laid out with the sidebar shown, hidden by
    /// the model and shown again, at the minimum window and a wide one. Per toggle (one pass): the pane area the view
    /// writes changes exactly once; every band frame reported in that pass has the band's final width (no other width
    /// between); the fixed slots (the glyph, All, the layout control) keep their sizes in every frame reported; at the
    /// wide size every slot keeps its width and height. NOT pinned: the picker's tier width at the minimum window. There,
    /// hiding the sidebar widens the band and step 3's tier rule may pick a wider tier: that is the tier rule at a new
    /// width, exactly as on a window resize, not a flicker of this step (decided by the supervisor). A probe reports a
    /// slot only when its frame changes, so the last frame per slot is kept across passes and the per-pass rule applies
    /// only to the slots reported in that pass.
    @MainActor
    func testSidebarHiddenBandSlotsKeepTheirSizesAtEveryScale() throws {
        try withSidebarRow(gate: true) {
            let restoreModes = transcriptMode(["api"])
            defer { restoreModes(); AgentWindowBand.probe = nil }
            for scale: CGFloat in [0.7, 0.85, 1.0] {
                ThemeRuntime.scale = scale
                for (label, size) in [("min", AgentsWindow.contentMinSize(scale: scale)), ("wide", CGSize(width: 1600, height: 900))] {
                    let tag = "\(label) \(scale)"
                    let m = windowModel(store([session("api", .idle)]))
                    m.setVisible(true)
                    defer { m.close() }
                    m.select(.live(paneKey("api")))
                    let box = SidebarProbeBox()
                    AgentWindowBand.probe = { kind, r in box.seen[kind, default: []].append(r) }   // main actor (layout)
                    let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                                       backing: .buffered, defer: true)
                    win.isReleasedWhenClosed = false
                    let host = NSHostingView(rootView: AgentWindowRootView(model: m, scrolls: false))
                    host.frame = CGRect(origin: .zero, size: size)
                    win.contentView = host
                    defer { win.contentView = nil; win.close() }
                    var latest: [String: CGRect] = [:]   // the last frame per slot, across passes
                    /// One layout pass: what the probes reported in it, and the last frame of every slot so far.
                    @MainActor func pass() -> (seen: [String: [CGRect]], last: [String: CGRect]) {
                        settle(host)
                        let seen = box.seen
                        box.seen = [:]
                        for (k, rs) in seen { if let r = rs.last { latest[k] = r } }
                        return (seen, latest)
                    }
                    let shown = pass().last   // the first build: not a toggle
                    let fixed: [String: CGFloat] = ["sidebar": AgentWindowBand.sidebarWidth, "all": AgentWindowBand.allWidth,
                                                    "layout": AgentWindowBand.layoutWidth]
                    /// The one-pass rule for the frames reported in one toggle's pass (see the row's comment).
                    @MainActor func onePass(_ seen: [String: [CGRect]], _ last: [String: CGRect], _ step: String) {
                        XCTAssertTrue(seen["band"] != nil, "the band moved (\(step) \(tag))")
                        XCTAssertTrue(seen["sidebar"] != nil, "the glyph's slot is laid out and moves with the band (\(step) \(tag))")
                        for (k, rs) in seen {
                            for r in rs {
                                if k == "band", let b = last["band"] {
                                    XCTAssertEqual(r.width, b.width, accuracy: 0.5, "band: no other width between (\(step) \(tag))")
                                    XCTAssertEqual(r.height, b.height, accuracy: 0.5, "band: its height (\(step) \(tag))")
                                }
                                if let w = fixed[k] {
                                    XCTAssertEqual(r.width, w, accuracy: 0.5, "\(k): a fixed width (\(step) \(tag))")
                                    if let s = shown[k] { XCTAssertEqual(r.height, s.height, accuracy: 0.5, "\(k): its height (\(step) \(tag))") }
                                }
                                if label == "wide", k != "band", let s = shown[k] {
                                    XCTAssertEqual(r.width, s.width, accuracy: 0.5, "\(k): the same width (\(step) \(tag))")
                                    XCTAssertEqual(r.height, s.height, accuracy: 0.5, "\(k): the same height (\(step) \(tag))")
                                }
                            }
                        }
                    }
                    let column = size.width - sz(290) - 1
                    XCTAssertEqual(m.paneArea.width, column, accuracy: 0.5, "shown: the column (\(tag))")
                    let changes = m.paneAreaChanges
                    m.toggleSidebar()
                    let (hiddenSeen, hidden) = pass()
                    onePass(hiddenSeen, hidden, "hide")
                    XCTAssertEqual(m.paneAreaChanges, changes + 1, "one change, no size in between (\(tag))")
                    XCTAssertEqual(m.paneArea.width, size.width, accuracy: 0.5, "hidden: the whole width (\(tag))")
                    XCTAssertEqual(m.paneArea.height, size.height - AgentWindowBand.height, accuracy: 0.5, "(\(tag))")
                    m.toggleSidebar()
                    let (againSeen, again) = pass()
                    onePass(againSeen, again, "show")
                    XCTAssertEqual(m.paneAreaChanges, changes + 2, "one change again (\(tag))")
                    XCTAssertEqual(m.paneArea.width, column, accuracy: 0.5, "shown again (\(tag))")
                    let sb = try XCTUnwrap(shown["band"], tag), hb = try XCTUnwrap(hidden["band"], tag)
                    XCTAssertEqual(hb.width - sb.width, sz(290) + 1, accuracy: 0.5, "the band widens by the sidebar (\(tag))")
                    XCTAssertEqual(hb.height, sb.height, accuracy: 0.5, "(\(tag))")
                    for s in [shown, hidden, again] {
                        let g = try XCTUnwrap(s["sidebar"], "the glyph's slot is always laid out (\(tag))")
                        XCTAssertEqual(g.width, AgentWindowBand.sidebarWidth, accuracy: 0.5, "(\(tag))")
                        XCTAssertEqual(g.height, AgentWindowBand.sidebarWidth, accuracy: 0.5, "(\(tag))")
                        XCTAssertEqual(try XCTUnwrap(s["all"], tag).width, AgentWindowBand.allWidth, accuracy: 0.5, "(\(tag))")
                        if let l = s["layout"] { XCTAssertEqual(l.width, AgentWindowBand.layoutWidth, accuracy: 0.5, "(\(tag))") }
                    }
                    // A wider tier's slot (the layout control at the minimum) keeps its last frame here: a subset, not equal.
                    XCTAssertTrue(Set(shown.keys).isSubset(of: Set(again.keys)), "shown again: every slot (\(tag))")
                    for k in shown.keys { assertSame(again[k], shown[k], "\(k): shown again as before (\(tag))") }
                    if label == "wide" {
                        XCTAssertEqual(Set(hidden.keys), Set(shown.keys), "the same slots (\(tag))")
                        for k in shown.keys where k != "band" {
                            let a = try XCTUnwrap(shown[k]), b = try XCTUnwrap(hidden[k])
                            XCTAssertEqual(a.width, b.width, accuracy: 0.5, "\(k): the same width (\(tag))")
                            XCTAssertEqual(a.height, b.height, accuracy: 0.5, "\(k): the same height (\(tag))")
                        }
                    }
                    XCTAssertFalse(win.isVisible, "never shown")
                }
            }
        }
    }

    /// The sidebar title row's frame on the real accessibility tree (screen coordinates) of the root view at `size`.
    @MainActor
    func sidebarTitleFrame(_ m: AgentWindowModel, _ size: CGSize) throws -> CGRect {
        let tree = AXTreeSupport.tree(AgentWindowRootView(model: m, scrolls: false), size) { t in
            t.contains { $0.reads(AgentsWindow.title) }
        }
        return try XCTUnwrap(tree.first { $0.reads(AgentsWindow.title) }?.frame, "the sidebar's title is read")
    }

    /// Rider 1197 (a): with the band shown (gate on) the sidebar starts one band height lower than with the gate off, so
    /// its title sits on the session title's line; with the gate off it is where it was.
    @MainActor
    func testSidebarHiddenSidebarTopInsetEqualsTheBand() throws {
        try withSidebarRow(gate: false) {
            for scale: CGFloat in [0.7, 1.0] {
                ThemeRuntime.scale = scale
                let m = windowModel(store([session("api", .idle)]))
                m.setVisible(true)
                defer { m.close() }
                let size = CGSize(width: 1600, height: 900)
                AgentPaneLayout.splitsEnabled = false
                let off = try sidebarTitleFrame(m, size)
                AgentPaneLayout.splitsEnabled = true
                let on = try sidebarTitleFrame(m, size)
                // Screen coordinates, bottom-left origin: lower on screen is a smaller y.
                XCTAssertEqual(off.minY - on.minY, AgentWindowBand.height, accuracy: 0.5, "the band's height (\(scale))")
                XCTAssertEqual(off.height, on.height, accuracy: 0.5, "the row itself unchanged (\(scale))")
            }
        }
    }

    /// The glyph on the real accessibility tree: with the sidebar shown it is not read (the band reads the picker only);
    /// hidden, "Show sidebar" is read in the band; pressing it (the button's action through the model) shows the sidebar.
    @MainActor
    func testSidebarHiddenGlyphIsReadOnlyWhileHidden() throws {
        try withSidebarRow(gate: true) {
            let restoreModes = transcriptMode(["api"])
            defer { restoreModes() }
            let m = windowModel(store([session("api", .idle)]))
            m.setVisible(true)
            defer { m.close() }
            m.select(.live(paneKey("api")))
            let size = CGSize(width: 1600, height: 900)
            let shown = AXTreeSupport.tree(AgentWindowRootView(model: m, scrolls: false), size) { t in
                t.contains { $0.reads("Verbose view") }
            }
            XCTAssertTrue(shown.contains { $0.reads("Verbose view") }, "the band was read")
            XCTAssertFalse(shown.contains { $0.reads("Show sidebar") }, "shown: the glyph is not read")
            m.toggleSidebar()
            let hidden = AXTreeSupport.tree(AgentWindowRootView(model: m, scrolls: false), size) { t in
                t.contains { $0.reads("Show sidebar") }
            }
            let glyph = try XCTUnwrap(hidden.first { $0.reads("Show sidebar") }, "hidden: the glyph is read")
            XCTAssertFalse(hidden.contains { $0.reads(AgentsWindow.title) }, "hidden: the sidebar is not drawn")
            XCTAssertLessThanOrEqual(glyph.frame.height, AgentWindowBand.height + 0.5, "in the band's row")
        }
    }

    // MARK: The walk

    /// 7.1 (OQ-1) with the gate on and two panes: plain down and up skip the row shown in the other pane, and the end is
    /// a no-op (no wrap). One pane skips nothing; the gate off walks as today on the same two-pane tree.
    @MainActor
    func testSidebarHiddenWalkSkipsRowsShownInAnotherPane() throws {
        try withSidebarRow(gate: true) {
            let restoreModes = transcriptMode(["api", "api-qa", "web"])
            defer { restoreModes() }
            let m = windowModel(store([session("api", .idle), session("api-qa", .idle), session("web", .idle)]))
            m.setVisible(true)   // the sidebar fills once the window is visible, as in the other rows
            defer { m.close() }
            m.paneArea = CGRect(x: 0, y: 0, width: 1000, height: 600)
            let ids = m.navigableIDs
            XCTAssertEqual(ids.count, 3, "the rows walked are the rows built")
            guard ids.count == 3, let first = ids.first, let middle = ids.dropFirst().first, let last = ids.last else { return }
            m.select(first)
            m.move(1)
            XCTAssertEqual(m.selection, middle, "one pane: nothing skipped")
            m.move(-1)
            XCTAssertEqual(m.selection, first)
            // Two panes: the other shows the middle row, the focused one the first.
            m.select(middle)
            XCTAssertTrue(m.perform(.split(.columns)))
            m.select(first)
            XCTAssertEqual(m.layout.panes.count, 2)
            XCTAssertEqual(m.selection, first)
            m.move(1)
            XCTAssertEqual(m.selection, last, "down skips the row shown in the other pane")
            m.move(1)
            XCTAssertEqual(m.selection, last, "the end: a no-op, no wrap")
            m.move(-1)
            XCTAssertEqual(m.selection, first, "up skips it too")
            m.move(-1)
            XCTAssertEqual(m.selection, first, "the top: a no-op")
            AgentPaneLayout.splitsEnabled = false
            m.move(1)
            XCTAssertEqual(m.selection, middle, "gate off: today's walk, nothing skipped")
        }
    }

    // MARK: Rider 1197 (b)

    /// The split gate is never flipped by the product: in Sources its declaration is its only assignment, so it can only
    /// change before a window exists (a code change), never under an open one. Reads the source tree only.
    func testSidebarHiddenSplitGateHasNoWriterInSources() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let assign = try NSRegularExpression(pattern: #"splitsEnabled\s*=[^=]"#)
        var hits: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.components(separatedBy: "\n")
            where assign.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                hits.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(hits, ["AgentPaneLayout.swift: @MainActor static var splitsEnabled = false"], "the only writer")
    }
}
