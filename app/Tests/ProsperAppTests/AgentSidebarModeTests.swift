import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1379: the Agent Sessions sidebar's modes (Full, Mini's rail, Slide's hidden sidebar that slides in at the window's left
/// edge or is pinned by Control-Command-S). Offscreen only: every window is built and never shown, ordered in or made key;
/// key and enter/exit events are built and handed to the window or the tracker's own handlers, never posted. The mode lives
/// in Preferences.defaults, the private in-memory test store; every row saves it, the split gate, the UI scale and the
/// Reduce Motion seam, and puts them back in a defer.
@MainActor
final class AgentSidebarModeTests: XCTestCase {
    private let d1 = AgentWindowD1Tests()
    static let modeKey = "agentSidebarMode"
    static let scales: [CGFloat] = [0.7, 0.85, 1.0]

    /// Runs `body` with the mode unset, the gate off, scale 1, Reduce Motion on (no animation in a row), #1458's Slide
    /// dwell and hide shortened to `open` and `hide`; all put back after.
    func withModeRow(open: Duration = .milliseconds(30), hide: Duration = .milliseconds(100), _ body: () throws -> Void) rethrows {
        let d = Preferences.defaults
        let saved = d.object(forKey: Self.modeKey), hidden = d.object(forKey: AgentWindowD1Tests.sidebarKey)
        let gate = AgentPaneLayout.splitsEnabled, scale = ThemeRuntime.scale, motion = AgentWindowModel.reduceMotion
        let delays = (AgentWindowModel.slideOpenDelay, AgentWindowModel.slideHideDelay)
        defer {
            (AgentWindowModel.slideOpenDelay, AgentWindowModel.slideHideDelay) = delays
            if let saved { d.set(saved, forKey: Self.modeKey) } else { d.removeObject(forKey: Self.modeKey) }
            if let hidden { d.set(hidden, forKey: AgentWindowD1Tests.sidebarKey) } else { d.removeObject(forKey: AgentWindowD1Tests.sidebarKey) }
            AgentPaneLayout.splitsEnabled = gate
            ThemeRuntime.scale = scale
            AgentWindowModel.reduceMotion = motion
        }
        XCTAssertFalse(d === UserDefaults.standard, "a private defaults store")
        d.removeObject(forKey: Self.modeKey)
        d.removeObject(forKey: AgentWindowD1Tests.sidebarKey)
        AgentPaneLayout.splitsEnabled = false
        ThemeRuntime.scale = 1
        AgentWindowModel.reduceMotion = { true }
        (AgentWindowModel.slideOpenDelay, AgentWindowModel.slideHideDelay) = (open, hide)
        try body()
    }

    /// #1458: turns the main run loop (the dwell's and the hide's tasks run on it) until `done` or 5 s; true when done.
    @discardableResult
    func waitUntil(_ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(5)
        while !done(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return done()
    }

    /// #1458: turns the main run loop for `seconds` (a wait that must change nothing).
    func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// The real window for `mode`, never shown, with one session selected and laid out.
    func built(_ mode: AgentSidebarMode, _ body: (AgentsNSWindow, AgentWindowModel) throws -> Void) throws {
        Preferences.agentSidebarMode = mode
        let m = d1.windowModel(d1.store([d1.session("api", .working), d1.session("api-qa", .blocked)]))
        defer { m.close() }
        XCTAssertEqual(m.sidebarMode, mode, "read when the model is made")
        m.setVisible(true)   // the model builds its sections only while visible
        m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "api")))
        let win = AgentWindowStyleTests.makeStandardWindow(m)
        defer { win.contentViewController = nil }
        settle(win)
        XCTAssertFalse(win.isVisible, "built, never shown")
        try body(win, m)
        XCTAssertFalse(win.isVisible, "never shown")
    }

    func settle(_ win: NSWindow) {
        for _ in 0..<3 {
            win.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    func views<T: NSView>(_ v: NSView, _ t: T.Type) -> [T] {
        ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { views($0, t) }
    }

    /// Window-space frames of the drag views (the sidebar title row's and the session header's), leftmost first.
    func dragFrames(_ win: NSWindow) -> [CGRect] {
        guard let cv = win.contentView else { return [] }
        return views(cv, AgentWindowDragView.self).map { $0.convert($0.bounds, to: nil) }.sorted { $0.minX < $1.minX }
    }

    func trackers(_ win: NSWindow, edge: Bool) -> [AgentSlideTrackerView] {
        guard let cv = win.contentView else { return [] }
        return views(cv, AgentSlideTrackerView.self).filter { $0.edge == edge }
    }

    func pointer(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                             context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    // MARK: Widths

    /// Full keeps TIP's sz(290), Mini is a narrow rail, Slide takes no width while slid out; at 0.7, 0.85 and 1.0, in the
    /// model's frames and in the drawn window (the title row's drag view is the column; the header's starts after it).
    func testTheSidebarWidthPerModeAtEveryScale() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        try withModeRow {
            for scale in Self.scales {
                ThemeRuntime.scale = scale
                let size = CGSize(width: 1000 * scale, height: 680 * scale)
                for mode in AgentSidebarMode.allCases {
                    try built(mode) { win, m in
                        let want: CGFloat = mode == .full ? AgentWindowModel.fullSidebarWidth : mode == .mini ? AgentWindowModel.miniSidebarWidth : 0
                        XCTAssertEqual(m.sidebarColumnWidth, want, accuracy: 0.01, "\(mode) at \(scale)")
                        XCTAssertEqual(m.paneAreaFrame(in: size)?.minX ?? -1, mode == .slide ? 0 : want + 1, accuracy: 0.01,
                                       "the panes start after the column, \(mode) at \(scale)")
                        XCTAssertEqual(m.sidebarFrame(in: size)?.width ?? 0, want, accuracy: 0.01, "\(mode) at \(scale)")
                        XCTAssertEqual(m.sidebarShown, mode != .slide, "\(mode) at \(scale)")
                        let drags = dragFrames(win)
                        XCTAssertGreaterThanOrEqual(drags.count, 1, "\(mode) at \(scale)")
                        if mode == .slide {
                            XCTAssertEqual(drags.first?.minX ?? -1, 0, accuracy: pixel, "Slide: the panes reach the left edge at \(scale)")
                            XCTAssertFalse(drags.contains { abs($0.width - AgentWindowModel.fullSidebarWidth) < 1 }, "no sidebar drawn at \(scale)")
                        } else {
                            XCTAssertEqual(drags.first?.minX ?? -1, 0, accuracy: pixel, "\(mode) at \(scale)")
                            XCTAssertEqual(drags.first?.width ?? 0, want, accuracy: 1, "the title row spans the column, \(mode) at \(scale)")
                        }
                    }
                }
            }
        }
    }

    // MARK: Mini

    /// A Mini row: its VoiceOver label is the full row's (the session's words), its tooltip the same words; the Command-<n>
    /// superscript (#1457, was the chip) and the needs-you mark are drawn for a numbered blocked row; an idle row without a
    /// number has neither. The row's width is the measured rail's less the list's padding (#1457, was sz(68)).
    func testMiniRowKeepsTheWordsAndDrawsTheNumberAndTheNeedsYouMark() throws {
        try withModeRow {
            let blocked = AgentSidebar.row(d1.session("api", .blocked), details: .all, now: AgentWindowD1Tests.now)
            let idle = AgentSidebar.row(d1.session("api-qa", .idle), details: .all, now: AgentWindowD1Tests.now)
            let full = AgentSidebarRowView(row: blocked, selected: false, number: 2).accessibilityWords
            XCTAssertTrue(full.hasPrefix("api, "), full)
            let row = AgentWindowModel.miniSidebarWidth - 2 * sz(8)
            let tree = AXTreeSupport.tree(AgentSidebarRowView(row: blocked, selected: false, number: 2, mini: true)
                .frame(width: row), CGSize(width: row, height: 60)) { t in t.contains { $0.label.hasPrefix("api") } }
            let node = try XCTUnwrap(tree.first { $0.label.hasPrefix("api") }, "\(tree.map(\.label))")
            XCTAssertEqual(node.label, full, "VoiceOver reads the full row's words")
            XCTAssertEqual(node.help, full, "the tooltip holds the full row's words")
            let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
            for scale in Self.scales {
                ThemeRuntime.scale = scale
                let width = AgentWindowModel.miniSidebarWidth - 2 * sz(8)
                let on = rowParts(AgentSidebarRowView(row: blocked, selected: false, number: 2, mini: true), width: width)
                XCTAssertNotNil(on["miniSup"], "the Command-2 superscript is drawn at \(scale): \(on.keys.sorted())")
                XCTAssertNotNil(on["miniNeeds"], "the needs-you mark is drawn at \(scale)")
                XCTAssertLessThanOrEqual(on["miniNeeds"]?.maxX ?? .infinity, width + pixel, "inside the rail at \(scale)")
                let off = rowParts(AgentSidebarRowView(row: idle, selected: false, mini: true), width: width)
                XCTAssertTrue(off["miniSup"] == nil && off["miniNeeds"] == nil, "no number, no need at \(scale): \(off.keys.sorted())")
                XCTAssertNotNil(off["miniSlot"], "the mark's slot is kept at \(scale)")
                // #1470: Mini marks the nine Command rows only; rows 10-18 (Option-Command) draw none there.
                for (n, chip) in [(9, true), (10, false), (18, false)] {
                    let p = rowParts(AgentSidebarRowView(row: blocked, selected: false, number: n, mini: true), width: width)
                    XCTAssertEqual(p["miniSup"] != nil, chip, "row \(n)'s chip at \(scale): \(p.keys.sorted())")
                    XCTAssertLessThanOrEqual(p["miniNeeds"]?.maxX ?? .infinity, width + pixel, "row \(n) inside the rail at \(scale)")
                }
            }
        }
    }

    /// Round 2: Mini's title row keeps the list-wide "..." (every session-list action) beside >_ and +, each at its
    /// sz(18) hit size, the three together inside the rail, at 0.7, 0.85 and 1.0.
    func testMiniTitleRowKeepsTheMenuAndItsButtonsInsideTheRail() throws {
        try withModeRow {
            Preferences.agentSidebarMode = .mini
            let m = d1.windowModel(d1.store([d1.session("api", .working)]))
            defer { m.close() }
            XCTAssertEqual(m.sidebarMode, .mini)
            let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
            for scale in Self.scales {
                ThemeRuntime.scale = scale
                let rail = AgentWindowModel.miniSidebarWidth
                XCTAssertLessThanOrEqual(AgentSidebarTitleRow.buttonsWidth, rail, "the three slots fit at \(scale)")
                func ours(_ t: [AXTreeNode]) -> [AXTreeNode] {
                    t.filter { ["Session list actions", "New shell", "New session"].contains($0.title.isEmpty ? $0.label : $0.title) }
                }
                let tree = AXTreeSupport.tree(AgentSidebarTitleRow(model: m).frame(width: rail),
                                              CGSize(width: rail, height: sz(60))) { ours($0).count >= 3 }
                let found = ours(tree)
                XCTAssertTrue(tree.contains { $0.role == "AXMenuButton" && $0.title == "Session list actions" },
                              "the ... menu at \(scale): \(tree.map { "\($0.role) \($0.title) \($0.label)" })")
                XCTAssertEqual(found.count, 3, "..., >_ and + at \(scale)")
                for n in found { XCTAssertGreaterThanOrEqual(n.frame.width, sz(18) - pixel, "\(n.title)\(n.label) hit size at \(scale)") }
                let span = (found.map(\.frame.maxX).max() ?? .infinity) - (found.map(\.frame.minX).min() ?? 0)
                XCTAssertLessThanOrEqual(span, rail + pixel, "inside the rail at \(scale)")
            }
        }
    }

    func rowParts(_ view: AgentSidebarRowView, width: CGFloat) -> [String: CGRect] {
        let box = AgentWindowD1Tests.PaneProbeBox()
        AgentSidebarRowView.probe = { kind, _, r in box.seen[kind] = r }
        defer { AgentSidebarRowView.probe = nil }
        let (win, host) = AXTreeSupport.hosted(view.frame(width: width), CGSize(width: width, height: 80))
        d1.settle(host)
        XCTAssertFalse(win.isVisible, "never on screen")
        win.contentView = nil
        win.close()
        return box.seen
    }

    // MARK: Slide

    /// The edge tracker sits at the window's left edge, half the sidebar wide (#1458), over the whole height below the band;
    /// its enter reveals the sidebar as an overlay after the dwell (the panes keep x = 0 and their width), the overlay's exit
    /// hides it again after the hide delay.
    func testSlideEdgeRevealsAnOverlayAndLeavingHidesIt() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        try withModeRow {
            for scale in Self.scales {
                ThemeRuntime.scale = scale
                try built(.slide) { win, m in
                    let edge = try XCTUnwrap(trackers(win, edge: true).first, "the edge tracker at \(scale)")
                    let r = edge.convert(edge.bounds, to: nil), content = try XCTUnwrap(win.contentView).bounds
                    XCTAssertEqual(r.minX, 0, accuracy: pixel, "at the left edge at \(scale)")
                    XCTAssertEqual(r.width, AgentWindowModel.fullSidebarWidth / 2, accuracy: pixel, "half the sidebar at \(scale): \(r)")
                    XCTAssertEqual(r.height, content.height - (AgentWindowBand.shown ? AgentWindowBand.height : 0), accuracy: 1,
                                   "the whole height below the band at \(scale)")
                    edge.updateTrackingAreas()
                    XCTAssertEqual(edge.trackingAreas.count, 1)
                    XCTAssertTrue(edge.trackingAreas.first?.options.contains([.mouseEnteredAndExited, .mouseMoved, .inVisibleRect]) == true)
                    XCTAssertNil(edge.hitTest(NSPoint(x: 1, y: 1)), "the strip never takes a click")
                    XCTAssertTrue(trackers(win, edge: false).isEmpty, "slid out: no overlay")
                    edge.mouseExited(with: try pointer(.mouseExited))
                    pump(0.1)
                    XCTAssertFalse(m.slideOpen, "the edge's exit does nothing")
                    edge.mouseEntered(with: try pointer(.mouseEntered))
                    XCTAssertFalse(m.slideRevealed, "#1458: not before the dwell at \(scale)")
                    XCTAssertTrue(waitUntil { m.slideRevealed } && m.sidebarShown, "entering the edge reveals at \(scale)")
                    settle(win)
                    let size = content.size
                    XCTAssertEqual(m.paneAreaFrame(in: size)?.minX ?? -1, 0, "the overlay does not move the panes")
                    XCTAssertEqual(m.paneAreaFrame(in: size)?.width ?? 0, size.width, accuracy: 0.01, "nor shrink them")
                    XCTAssertEqual(m.sidebarFrame(in: size)?.width ?? 0, AgentWindowModel.fullSidebarWidth, accuracy: 0.01, "the full sidebar over them")
                    let drags = dragFrames(win)
                    XCTAssertTrue(drags.contains { abs($0.minX) < 0.5 && abs($0.width - AgentWindowModel.fullSidebarWidth) < 1 }, "the overlay's title row at \(scale): \(drags)")
                    XCTAssertTrue(drags.contains { abs($0.minX) < 0.5 && $0.width > AgentWindowModel.fullSidebarWidth + 2 }, "the header still from x 0 at \(scale): \(drags)")
                    let over = try XCTUnwrap(trackers(win, edge: false).first, "the overlay's tracker at \(scale)")
                    XCTAssertEqual(over.convert(over.bounds, to: nil).width, AgentWindowModel.fullSidebarWidth + 1, accuracy: 1, "the sidebar and its line")
                    over.mouseEntered(with: try pointer(.mouseEntered))
                    XCTAssertTrue(m.slideRevealed, "the overlay's enter does nothing")
                    over.mouseExited(with: try pointer(.mouseExited))
                    edge.mouseExited(with: try pointer(.mouseExited))
                    XCTAssertTrue(m.slideRevealed, "#1458: not before the hide delay at \(scale)")
                    XCTAssertTrue(waitUntil { !m.slideRevealed } && !m.sidebarShown, "leaving the sidebar hides it at \(scale)")
                    XCTAssertEqual(m.keyFocus, .pane, "a hidden sidebar never holds the keys")
                    settle(win)
                    XCTAssertTrue(trackers(win, edge: false).isEmpty, "slid out again at \(scale)")
                }
            }
        }
    }

    /// Control-Command-S in Slide pins the sidebar open with the split gate OFF (and on), and again closes it; a pointer
    /// exit leaves a pinned sidebar. Nothing is written to the Full/Mini hidden choice. Full with the gate off: today's,
    /// the chord is not handled.
    func testSlideChordPinsWithSplitPanesOff() throws {
        try withModeRow {
            for gate in [false, true] {
                AgentPaneLayout.splitsEnabled = gate
                Preferences.agentSidebarMode = .slide
                let (win, m, rec) = d1.treeWindow()
                defer { win.close(); m.close() }
                XCTAssertEqual(m.sidebarMode, .slide)
                XCTAssertFalse(m.sidebarShown, "slid out")
                XCTAssertTrue(win.performKeyEquivalent(with: d1.sidebarChord()), "handled, gate \(gate)")
                XCTAssertTrue(m.slidePinned && m.sidebarShown, "pinned open, gate \(gate)")
                m.slide(false)
                XCTAssertTrue(m.sidebarShown, "a pointer exit leaves it pinned")
                XCTAssertTrue(win.performKeyEquivalent(with: d1.sidebarChord("\u{44B}")), "the Cyrillic chord, gate \(gate)")
                XCTAssertFalse(m.slidePinned || m.sidebarShown, "unpinned, gate \(gate)")
                XCTAssertEqual(m.keyFocus, .pane)
                XCTAssertNil(d1.sidebarPref, "the Full/Mini hidden choice untouched")
                XCTAssertEqual(rec.asks, 0)
                XCTAssertFalse(win.isVisible, "never shown")
            }
            AgentPaneLayout.splitsEnabled = false
            Preferences.agentSidebarMode = .full
            let (win, m, _) = d1.treeWindow()
            defer { win.close(); m.close() }
            XCTAssertFalse(win.performKeyEquivalent(with: d1.sidebarChord()), "Full, gate off: as today")
            XCTAssertTrue(m.sidebarShown)
        }
    }

    /// Reduce Motion on: the slide reads the seam and runs no animation; off: a short slide.
    func testReduceMotionMeansNoSlide() throws {
        try withModeRow {
            final class Reads { var n = 0 }
            let reads = Reads()
            AgentWindowModel.reduceMotion = { reads.n += 1; return true }
            Preferences.agentSidebarMode = .slide
            let m = d1.windowModel(d1.store([d1.session("api", .idle)]))
            defer { m.close() }
            XCTAssertNil(m.lastSlideAnimated)
            m.slide(true)
            XCTAssertEqual(reads.n, 1, "the seam is read")
            XCTAssertEqual(m.lastSlideAnimated, false, "Reduce Motion: shown at once")
            m.toggleSidebar()
            XCTAssertEqual(reads.n, 2)
            XCTAssertEqual(m.lastSlideAnimated, false)
            AgentWindowModel.reduceMotion = { reads.n += 1; return false }
            m.toggleSidebar()
            XCTAssertEqual(reads.n, 3)
            XCTAssertEqual(m.lastSlideAnimated, true, "Reduce Motion off: a short slide")
        }
    }

    // MARK: Menus (#1461)

    /// A Slide model, slid in with the sidebar holding the keys.
    func slidIn() -> AgentWindowModel {
        Preferences.agentSidebarMode = .slide
        let m = d1.windowModel(d1.store([d1.session("api", .idle)]))
        m.slide(true)
        m.keyFocus = .sidebar
        return m
    }

    /// #1461: the sidebar's menu opens (its window over the sidebar sends the exit): the sidebar stays and keeps the keys,
    /// through a submenu too; the last close with the pointer still out slides it out, as a plain exit does.
    func testSlideMenuHoldsTheExitUntilItClosesWithThePointerOutside() throws {
        try withModeRow {
            let m = slidIn()
            defer { m.close() }
            m.slideMenu(true)
            m.slide(false)
            XCTAssertTrue(m.slideRevealed && m.sidebarShown, "the menu is open: still revealed")
            XCTAssertEqual(m.keyFocus, .sidebar, "the menu is open: the keys stay")
            m.slideMenu(true)   // Row details' submenu
            m.slide(false)
            m.slideMenu(false)
            XCTAssertTrue(m.slideRevealed, "one menu still open")
            XCTAssertEqual(m.keyFocus, .sidebar)
            m.slideMenu(false)
            XCTAssertTrue(waitUntil { !m.slideRevealed } && !m.sidebarShown, "closed with the pointer outside: slid out")
            XCTAssertEqual(m.keyFocus, .pane)
            XCTAssertEqual(m.slideMenusOpen, 0)
            m.slideMenu(false)
            XCTAssertEqual(m.slideMenusOpen, 0, "an extra close never goes below zero")
            m.slide(true)
            m.slide(false)
            XCTAssertTrue(waitUntil { !m.slideRevealed }, "no menu: a plain exit hides (#1458: after the hide delay)")
        }
    }

    /// #1461: the pointer comes back over the sidebar before the menu closes: it stays revealed with the keys.
    func testSlideMenuCloseWithThePointerInsideKeepsTheSidebar() throws {
        try withModeRow {
            let m = slidIn()
            defer { m.close() }
            m.slideMenu(true)
            m.slide(false)
            m.slide(true)   // the sidebar's enter
            m.slideMenu(false)
            XCTAssertTrue(m.slideRevealed && m.sidebarShown, "the pointer is inside: stays")
            XCTAssertEqual(m.keyFocus, .sidebar)
            m.slide(false)
            XCTAssertTrue(waitUntil { !m.slideRevealed }, "the next exit hides it")
        }
    }

    /// #1461: a pinned Slide sidebar and the Full and Mini modes are as before around a menu.
    func testSlideMenuLeavesPinnedAndOtherModesAlone() throws {
        try withModeRow {
            let m = slidIn()
            defer { m.close() }
            m.slide(false)
            XCTAssertTrue(waitUntil { !m.slideRevealed }, "#1458: slid out after the hide delay")
            m.toggleSidebar()   // from slid out: pins open
            XCTAssertTrue(m.slidePinned && !m.slideRevealed)
            m.slideMenu(true)
            m.slide(false)
            m.slideMenu(false)
            XCTAssertTrue(m.slidePinned && m.sidebarShown, "pinned: stays")
            for mode in [AgentSidebarMode.full, .mini] {
                Preferences.agentSidebarMode = mode
                let o = d1.windowModel(d1.store([d1.session("api", .idle)]))
                defer { o.close() }
                o.keyFocus = .sidebar
                o.slideMenu(true)
                o.slide(false)
                XCTAssertFalse(o.slideExitHeld, "\(mode): nothing held")
                o.slideMenu(false)
                XCTAssertTrue(o.sidebarShown && !o.slideRevealed, "\(mode)")
                XCTAssertEqual(o.keyFocus, .sidebar, "\(mode): the keys stay")
            }
        }
    }

    // MARK: Keys and folds (#1383)

    private func keyEvent(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "") throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                       context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                                       keyCode: code))
    }

    /// R1379-s1: a Slide sidebar that slid out holds no keys even when keyFocus is written back to .sidebar (the chapter
    /// list does that when its card closes): Command-Backspace is not the row's remove and the arrows leave the selection.
    func testASlidOutSidebarNeverHoldsTheKeysEvenWhenKeyFocusIsWrittenBack() throws {
        try withModeRow {
            Preferences.agentSidebarMode = .slide
            let m = d1.windowModel(d1.store([d1.session("api", .idle), d1.session("web", .idle)]))
            defer { m.close() }
            m.setVisible(true)
            let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                                     backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            win.model = m
            defer { win.close() }
            let api = AgentSidebar.RowID.live(AgentSessionKey(dir: "/tmp/dch-test", name: "api"))
            m.select(api)
            @MainActor func route(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "") throws -> AgentsNSWindow.KeyRoute {
                let e = try keyEvent(code, flags, chars)   // built here: a parameter event cannot be sent to the static route
                return AgentsNSWindow.route(e, responder: .other, sidebarFocused: win.sidebarFocused, terminalMode: false)
            }
            let down = try keyEvent(125)
            m.slide(true)
            m.keyFocus = .sidebar
            XCTAssertTrue(win.sidebarFocused, "revealed: the sidebar holds the keys")
            XCTAssertEqual(try route(51, [.command], "\u{7F}"), .stopOrRemove, "revealed: Command-Backspace is the row's")
            m.slide(false)
            XCTAssertTrue(waitUntil { !m.slideRevealed }, "#1458: slid out after the hide delay")
            XCTAssertEqual(m.keyFocus, .pane)
            m.keyFocus = .sidebar   // what the chapter list's close writes back
            XCTAssertFalse(m.sidebarShown)
            XCTAssertFalse(win.sidebarFocused, "slid out: nothing is drawn, nothing holds the keys")
            XCTAssertEqual(try route(51, [.command], "\u{7F}"), .pass)
            XCTAssertEqual(try route(125), .pass)
            win.sendEvent(down)
            XCTAssertEqual(m.selection, api, "the arrows do not walk an unseen list")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// R1379-s2: Mini's rail draws every row, so the fold (Full's saved choice) does not apply there: the arrows reach the
    /// row, it has its Command-<n> number, no key in Mini writes the fold, and Full keeps it.
    func testMiniIgnoresTheFoldAndFullKeepsIt() throws {
        try withModeRow {
            let key = "agentWindowCollapsedSections"
            let saved = Preferences.defaults.object(forKey: key)
            defer { if let saved { Preferences.defaults.set(saved, forKey: key) } else { Preferences.defaults.removeObject(forKey: key) } }
            Preferences.defaults.removeObject(forKey: key)
            let m = d1.windowModel(d1.store([d1.session("api", .idle)]))
            defer { m.close() }
            m.setVisible(true)
            let row = AgentSidebar.RowID.live(AgentSessionKey(dir: "/tmp/dch-test", name: "api"))
            XCTAssertTrue(m.sections.contains { $0.title == "Sessions" && $0.rows.map(\.id) == [row] }, "\(m.sections.map(\.title))")
            m.select(nil)
            XCTAssertTrue(m.selection == nil, "nothing selected: the fold hides the whole list")
            m.setCollapsed("Sessions", true)
            XCTAssertTrue(m.navigableIDs.isEmpty && m.number(row) == nil, "Full: folded rows are skipped")
            m.setSidebarMode(.mini)
            XCTAssertEqual(m.navigableIDs, [row], "Mini: the arrows reach the drawn row")
            XCTAssertEqual(m.number(row), 1, "Mini: the row has its chip's number")
            m.collapseSelected(false)   // Right with nothing selected: the empty-list rule must not unfold, then selects
            XCTAssertEqual(m.selection, row)
            m.collapseSelected(true)    // Left: no fold in Mini
            m.setCollapsed("Sessions", false)
            XCTAssertEqual(Preferences.agentWindowCollapsedSections, ["Sessions"], "Mini wrote nothing to Full's fold")
            m.select(nil)
            m.setSidebarMode(.full)
            XCTAssertTrue(m.isCollapsed("Sessions"), "Full keeps its fold")
            XCTAssertTrue(m.navigableIDs.isEmpty && m.number(row) == nil, "and skips the row again")
        }
    }

    // MARK: The setting

    /// Unset and unknown read as Full; each mode round-trips; Settings' call and the Go menu's item (checked) apply it to
    /// an open window's model at once; Slide starts slid out.
    func testTheSettingRoundTripsAndAppliesAtOnce() throws {
        try withModeRow {
            XCTAssertEqual(Preferences.agentSidebarMode, .full, "unset")
            Preferences.defaults.set("sideways", forKey: Self.modeKey)
            XCTAssertEqual(Preferences.agentSidebarMode, .full, "unknown")
            for mode in AgentSidebarMode.allCases {
                Preferences.agentSidebarMode = mode
                XCTAssertEqual(Preferences.agentSidebarMode, mode)
                XCTAssertEqual(Preferences.defaults.string(forKey: Self.modeKey), mode.rawValue)
            }
            AgentsWindow.shared.setSidebarMode(.mini)   // Settings' call; no window open in a test: the setting alone
            XCTAssertEqual(Preferences.agentSidebarMode, .mini)
            let (win, m, _) = d1.treeWindow()
            defer { win.close(); m.close() }
            XCTAssertEqual(m.sidebarMode, .mini)
            let go = win.goMenu
            let menu = try XCTUnwrap(go.item.submenu)
            go.menuNeedsUpdate(menu)
            let items = menu.items.filter { !$0.isSeparatorItem }
            XCTAssertEqual(items.suffix(3).map(\.title), ["Full Sidebar", "Mini Sidebar", "Slide-In Sidebar"])
            XCTAssertEqual(items.suffix(3).map(\.state), [.off, .on, .off], "the open mode checked")
            let slide = try XCTUnwrap(items.last)
            XCTAssertTrue(go.validateMenuItem(slide))
            go.pick(slide)
            XCTAssertEqual(win.lastPerformed, .sidebarMode(.slide))
            XCTAssertEqual(m.sidebarMode, .slide, "applied at once")
            XCTAssertEqual(Preferences.agentSidebarMode, .slide, "saved")
            XCTAssertFalse(m.sidebarShown, "Slide starts slid out")
            XCTAssertEqual(m.keyFocus, .pane)
            go.menuNeedsUpdate(menu)
            XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.suffix(3).map(\.state), [.off, .off, .on])
            win.perform(mode: .full)
            XCTAssertTrue(m.sidebarMode == .full && m.sidebarShown, "back to Full")
            XCTAssertEqual(m.sidebarColumnWidth, AgentWindowModel.fullSidebarWidth)
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// #1461: the tracker holds an exit that arrives while the run loop is in its menu-tracking mode (a sidebar menu's
    /// window sends it), tells the model (onMenu true), and releases it in one default-mode turn (onMenu false). Offscreen:
    /// an unshown borderless window, events built and handed to mouseExited, never posted.
    func testTrackerHoldsAnExitArrivingInEventTrackingModeUntilTheDefaultTurn() throws {
        func make() -> (NSWindow, AgentSlideTrackerView, () -> [Bool], () -> [Bool]) {
            final class Rec { var action: [Bool] = [], menu: [Bool] = [] }
            let rec = Rec(), t = AgentSlideTrackerView(edge: false)
            t.action = { rec.action.append($0) }
            t.onMenu = { rec.menu.append($0) }
            let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 100, height: 100), styleMask: [.borderless],
                               backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            win.contentView = t
            return (win, t, { rec.action }, { rec.menu })
        }
        let (win, t, action, menu) = make()
        defer { win.close() }
        // Built inside each block: an NSEvent is not Sendable.
        @Sendable func exitEvent() -> NSEvent? {
            NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                   context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        }
        RunLoop.current.perform(inModes: [.eventTracking]) {
            MainActor.assumeIsolated { if let e = exitEvent() { t.mouseExited(with: e); t.mouseExited(with: e) } }
        }
        RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(1))
        XCTAssertEqual(menu(), [true], "held once: the second exit in the same tracking adds nothing")
        XCTAssertEqual(action(), [false, false], "every exit still reaches the model")
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1))
        XCTAssertEqual(menu(), [true, false], "released by one default-mode turn")
        XCTAssertEqual(action(), [false, false], "the pointer is outside: no re-enter")

        let (win2, t2, action2, menu2) = make()
        defer { win2.close() }
        RunLoop.current.perform(inModes: [.default]) { MainActor.assumeIsolated { if let e = exitEvent() { t2.mouseExited(with: e) } } }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1))
        XCTAssertEqual(menu2(), [], "a default-mode exit is not held")
        XCTAssertEqual(action2(), [false])
        XCTAssertFalse(win.isVisible || win2.isVisible, "never shown")
    }
}
