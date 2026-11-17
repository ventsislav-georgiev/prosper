import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1458: Slide's hover area (half the open sidebar's width from the window's left edge) opens the sidebar after a short
/// dwell, keeps it open while the pointer is over the area or the sidebar, and hides it 1.5 s after the pointer left
/// both. Offscreen only: windows are built and never shown; enter, move and exit events are built and handed to the
/// trackers' own handlers, never posted. The dwell and the hide delay are shortened through their static seams.
@MainActor
final class AgentSlideHoverTests: XCTestCase {
    private let modes = AgentSidebarModeTests()
    private let d1 = AgentWindowD1Tests()

    /// A Slide model, slid out, never shown.
    func slideModel() -> AgentWindowModel {
        Preferences.agentSidebarMode = .slide
        let m = d1.windowModel(d1.store([d1.session("api", .idle)]))
        XCTAssertEqual(m.sidebarMode, .slide)
        return m
    }

    func moved() throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                         context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    }

    /// The operator's numbers: a 0.15 s dwell and a 1.5 s hide.
    func testTheDelaysAreTheOperatorsNumbers() {
        XCTAssertEqual(AgentWindowModel.slideOpenDelay, .milliseconds(150))
        XCTAssertEqual(AgentWindowModel.slideHideDelay, .milliseconds(1500))
    }

    /// A pass through the area that leaves before the dwell opens nothing; staying the dwell opens it.
    func testAShortPassOpensNothingAndADwellOpens() throws {
        try modes.withModeRow(open: .milliseconds(60)) {
            let m = slideModel()
            defer { m.close() }
            m.slideArea(true)
            m.slideArea(false)
            modes.pump(0.3)
            XCTAssertFalse(m.slideRevealed || m.sidebarShown, "a pass opens nothing")
            m.slideArea(true)
            m.slideArea(true)   // a move inside keeps the running dwell
            XCTAssertFalse(m.slideRevealed, "not before the dwell")
            XCTAssertTrue(modes.waitUntil { m.slideRevealed } && m.sidebarShown, "the dwell opens it")
        }
    }

    /// Revealed, it stays while the pointer is over the sidebar (the area left) or over the area (the sidebar's exit, as a
    /// spurious exit during the slide-in sends), past several hide delays.
    func testStaysOpenOverTheSidebarOrTheArea() throws {
        try modes.withModeRow {
            let m = slideModel()
            defer { m.close() }
            m.slideArea(true)
            XCTAssertTrue(modes.waitUntil { m.slideRevealed })
            m.slideArea(false)   // on to the sidebar's right part (its tracker assumes inside: no enter)
            modes.pump(0.4)
            XCTAssertTrue(m.slideRevealed, "over the sidebar: stays")
            m.slideArea(true)
            m.slide(false)
            modes.pump(0.4)
            XCTAssertTrue(m.slideRevealed, "over the area: stays")
        }
    }

    /// The hide lands the delay after the pointer left both, not sooner; coming back over the sidebar or the area first
    /// cancels it.
    func testHidesAfterTheDelayAndAReturnCancels() throws {
        try modes.withModeRow(hide: .milliseconds(200)) {
            let m = slideModel()
            defer { m.close() }
            m.slide(true)
            m.keyFocus = .sidebar
            let left = Date()
            m.slide(false)
            XCTAssertTrue(m.slideRevealed, "not at once")
            XCTAssertTrue(modes.waitUntil { !m.slideRevealed } && !m.sidebarShown, "hidden after the delay")
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(left), 0.2, "never before the delay")
            XCTAssertEqual(m.keyFocus, .pane, "a hidden sidebar never holds the keys")
            for back in ["sidebar", "area"] {
                m.slide(true)
                m.slide(false)
                if back == "sidebar" { m.slide(true) } else { m.slideArea(true) }
                modes.pump(0.5)
                XCTAssertTrue(m.slideRevealed, "back over the \(back): the hide is cancelled")
                if back == "area" { m.slideArea(false) } else { m.slide(false) }
                XCTAssertTrue(modes.waitUntil { !m.slideRevealed }, "left again (\(back)): hides")
            }
        }
    }

    /// The STEP 1 bug: a hide that lands with the pointer still in the area, or an area made under the pointer, sends no
    /// fresh enter; a move inside the area opens it again after the dwell. R1458a-s1: not after Control-Command-S, which
    /// holds the area closed (see testAChordCloseHoldsTheAreaUntilThePointerLeaves).
    func testReopensWithThePointerStillInTheArea() throws {
        try modes.withModeRow {
            try modes.built(.slide) { win, m in
                let edge = try XCTUnwrap(modes.trackers(win, edge: true).first)
                edge.updateTrackingAreas()
                XCTAssertTrue(edge.trackingAreas.first?.options.contains(.mouseMoved) == true, "the area tracks moves")
                edge.mouseMoved(with: try moved())   // no enter: the area was made under the pointer
                XCTAssertTrue(modes.waitUntil { m.slideRevealed }, "a move inside opens it")
                m.toggleSidebar()   // the chord closes it with the pointer still in the area
                XCTAssertFalse(m.slideOpen)
                modes.pump(0.2)
                XCTAssertFalse(m.slideOpen, "no move: stays closed")
                edge.mouseMoved(with: try moved())
                modes.pump(0.2)
                XCTAssertFalse(m.slideOpen, "a move inside after the chord: the area is held, stays closed")
                m.slide(true)   // the sidebar tracker's enter (a hover over its other part) is not held
                edge.mouseExited(with: try modes.pointer(.mouseExited))   // the pointer left the area: the hold ends
                m.slide(false)
                XCTAssertTrue(modes.waitUntil { !m.slideRevealed }, "an ordinary timed hide")
                edge.mouseMoved(with: try moved())
                XCTAssertTrue(modes.waitUntil { m.slideRevealed }, "after an ordinary hide a move inside opens it again")
            }
        }
    }

    /// R1458a-s1: a chord close with the pointer in the area holds it: moves keep it closed; the pointer leaving and a later
    /// enter (then the dwell) opens it as before. A chord close with the pointer outside holds nothing.
    func testAChordCloseHoldsTheAreaUntilThePointerLeaves() throws {
        try modes.withModeRow {
            try modes.built(.slide) { win, m in
                let edge = try XCTUnwrap(modes.trackers(win, edge: true).first)
                edge.mouseEntered(with: try modes.pointer(.mouseEntered))
                XCTAssertTrue(modes.waitUntil { m.slideRevealed }, "the dwell opens it")
                m.toggleSidebar()   // the chord, the pointer still in the area
                XCTAssertFalse(m.slideOpen)
                for _ in 0..<3 {
                    edge.mouseMoved(with: try moved())
                    modes.pump(0.1)
                }
                XCTAssertFalse(m.slideOpen, "moves in the area keep it closed")
                edge.mouseExited(with: try modes.pointer(.mouseExited))
                edge.mouseEntered(with: try modes.pointer(.mouseEntered))
                XCTAssertTrue(modes.waitUntil { m.slideRevealed }, "exit, enter and the dwell open it again")
                edge.mouseExited(with: try modes.pointer(.mouseExited))   // the pointer outside the area when the chord comes
                m.slide(false)
                XCTAssertTrue(modes.waitUntil { !m.slideRevealed })
                m.toggleSidebar()   // pins
                m.toggleSidebar()   // unpins
                edge.mouseEntered(with: try modes.pointer(.mouseEntered))
                XCTAssertTrue(modes.waitUntil { m.slideRevealed }, "a chord close with the pointer outside holds nothing")
            }
        }
    }

    /// R1458b-s1: a dwell already running when the chord unpins (pinned open, pointer entering the area) must not slide
    /// the sidebar back in; after the pointer leaves and enters again the dwell opens it as usual.
    func testAChordDuringARunningDwellKeepsItClosed() throws {
        try modes.withModeRow(open: .milliseconds(60)) {
            let m = slideModel()
            defer { m.close() }
            m.toggleSidebar()   // pins it open, nothing slid
            XCTAssertTrue(m.slideOpen && !m.slideRevealed)
            m.slideArea(true)   // the dwell starts
            m.toggleSidebar()   // the chord within the dwell: unpins and holds
            XCTAssertFalse(m.slideOpen)
            modes.pump(0.3)
            XCTAssertFalse(m.slideOpen, "the running dwell opens nothing after the chord")
            m.slideArea(false)
            m.slideArea(true)
            XCTAssertTrue(modes.waitUntil { m.slideRevealed }, "a new enter and its dwell open it")
        }
    }

    /// i1: band off under No title bar, the area starts below the window's buttons (the title bar's row), not at y 0.
    func testTheAreaClearsTheWindowButtonsWithTheBandOff() throws {
        let d = Preferences.defaults, saved = d.object(forKey: "agentWindowStyle")
        defer { if let saved { d.set(saved, forKey: "agentWindowStyle") } else { d.removeObject(forKey: "agentWindowStyle") } }
        try modes.withModeRow {
            Preferences.agentWindowStyle = .noTitleBar
            XCTAssertFalse(AgentWindowBand.shown)
            try modes.built(.slide) { win, _ in
                let edge = try XCTUnwrap(modes.trackers(win, edge: true).first)
                let area = edge.convert(edge.bounds, to: nil)
                let button = try XCTUnwrap(win.standardWindowButton(.closeButton))
                let buttons = button.convert(button.bounds, to: nil)
                XCTAssertGreaterThan(buttons.height, 0)
                XCTAssertLessThanOrEqual(area.maxY, buttons.minY, "the area's top is at or below the buttons' bottom (window coordinates, y up)")
            }
        }
    }

    /// The area is half the open sidebar at 0.7, 0.85 and 1.0, from the left edge; it never takes a click, so a click
    /// there reaches the pane's view under it.
    func testTheAreaIsHalfTheSidebarAndThePanesKeepTheirClicks() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x: never a literal 0.5
        try modes.withModeRow {
            for scale in AgentSidebarModeTests.scales {
                ThemeRuntime.scale = scale
                XCTAssertEqual(AgentSlideTracker.areaWidth, AgentWindowModel.fullSidebarWidth / 2, accuracy: 0.01, "at \(scale)")
                XCTAssertGreaterThan(AgentSlideTracker.areaWidth, 100 * scale, "far wider than the old 4 pt at \(scale)")
                try modes.built(.slide) { win, _ in
                    let edge = try XCTUnwrap(modes.trackers(win, edge: true).first, "at \(scale)")
                    let r = edge.convert(edge.bounds, to: nil)
                    XCTAssertEqual(r.minX, 0, accuracy: pixel, "from the left edge at \(scale)")
                    XCTAssertEqual(r.width, AgentWindowModel.fullSidebarWidth / 2, accuracy: pixel, "half the sidebar at \(scale)")
                    let cv = try XCTUnwrap(win.contentView), frame = try XCTUnwrap(cv.superview)
                    let p = frame.convert(NSPoint(x: r.midX, y: r.midY), from: nil)
                    let hit = cv.hitTest(p)
                    XCTAssertTrue(hit != nil && !(hit is AgentSlideTrackerView), "the pane under the area takes the click at \(scale)")
                    XCTAssertTrue(edge.hitTest(NSPoint(x: 1, y: 1)) == nil, "no hit at \(scale)")
                }
            }
        }
    }

    /// #1461's hold still holds: with a sidebar menu open, the sidebar's and the area's exits hide nothing, however long;
    /// the last close hides after the delay. A pinned sidebar stays through every exit.
    func testTheMenuHoldAndThePinStillHold() throws {
        try modes.withModeRow {
            let m = slideModel()
            defer { m.close() }
            m.slide(true)
            m.slideArea(true)
            m.slideMenu(true)
            m.slide(false)
            m.slideArea(false)
            modes.pump(0.4)
            XCTAssertTrue(m.slideRevealed, "a menu is open: held")
            m.slideMenu(false)
            XCTAssertTrue(modes.waitUntil { !m.slideRevealed }, "the last close hides it")
            m.toggleSidebar()
            XCTAssertTrue(m.slidePinned)
            m.slideArea(true)
            XCTAssertTrue(modes.waitUntil { m.slideRevealed })
            m.slideArea(false)
            m.slide(false)
            modes.pump(0.4)
            XCTAssertTrue(m.slidePinned && m.sidebarShown, "pinned: stays")
        }
    }
}
