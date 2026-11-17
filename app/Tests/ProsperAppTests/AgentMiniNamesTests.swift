import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1457 (operator 2026-11-17, "the mini mode is not useful"): a Mini row shows the session's name cut to eight characters
/// with its Command number as a superscript, the rail is measured to fit eight wide characters at every UI scale, and a
/// quick tooltip shows the whole name beside the row. Offscreen only: every window is built and never shown, ordered in or
/// made key; the hover goes through the row's own handler, no event is posted.
@MainActor
final class AgentMiniNamesTests: XCTestCase {
    private let d1 = AgentWindowD1Tests()
    private let modes = AgentSidebarModeTests()
    static let scales: [CGFloat] = [0.7, 0.85, 1.0]
    static let long = "api-session-tokens-review"
    static let wide = String(repeating: "W", count: 12)

    func atScales(_ body: (CGFloat) throws -> Void) rethrows {
        _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale in Self.scales {
            ThemeRuntime.scale = scale
            try body(scale)
        }
    }

    /// The first eight Characters plus an ellipsis, a name of eight or fewer whole; through OutsideText (a bidi control goes);
    /// a grapheme at character 8 (a flag, a skin-toned emoji, a ZWJ family, whose joiners OutsideText drops) whole or not at all.
    func testMiniNameIsCutToEightCharactersNeverInsideAGrapheme() {
        let dots = "\u{2026}"
        XCTAssertEqual(AgentSidebarRowView.miniName("api"), "api")
        XCTAssertEqual(AgentSidebarRowView.miniName("api-sess"), "api-sess", "eight: whole")
        XCTAssertEqual(AgentSidebarRowView.miniName("api-sessi"), "api-sess" + dots, "nine: cut")
        XCTAssertEqual(AgentSidebarRowView.miniName(Self.long), "api-sess" + dots)
        XCTAssertEqual(AgentSidebarRowView.miniName("api\u{202E}-session"), "api-sess" + dots, "the bidi override dropped first")
        let flag = "\u{1F1E7}\u{1F1EC}", thumb = "\u{1F44D}\u{1F3FD}"
        XCTAssertEqual(AgentSidebarRowView.miniName("api-tes" + flag + "xy"), "api-tes" + flag + dots, "the flag whole")
        XCTAssertEqual(AgentSidebarRowView.miniName("api-tes" + thumb + "xy"), "api-tes" + thumb + dots, "the toned thumb whole")
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let cut = AgentSidebarRowView.miniName("api-tes" + family + "x")
        XCTAssertEqual(cut, "api-tes\u{1F468}" + dots, "OutsideText drops the joiners: the man is character 8, whole")
        XCTAssertEqual(cut.count, 9)
        for c in cut { XCTAssertFalse(c.unicodeScalars.contains("\u{200D}"), "no joiner left half-joined: \(cut.unicodeScalars.map(\.value))") }
    }

    /// A short and a long title (and twelve W's, the widest Latin letter) at 0.7, 0.85 and 1.0, backed at 1x and 2x, at the
    /// measured rail's row width: the name drawn is the cut name at its whole ideal width (nothing clipped or squeezed), inside
    /// the row; the superscript sits right after the name and only for rows 1-9 with Shortcut on; the needs-you mark inside.
    func testMiniRowDrawsTheCutNameAndTheSuperscriptInsideTheRail() throws {
        let blocked = AgentSidebar.row(d1.session("api", .blocked), details: .all, now: AgentWindowD1Tests.now)
        var noShortcut = AgentIslandRowDetails.all
        noShortcut.shortcut = false
        try atScales { scale in
            let rail = AgentWindowModel.miniSidebarWidth
            let width = rail - 2 * sz(8)   // the list's padding
            for backing: CGFloat in [1, 2] {
                let pixel: CGFloat = 1 / backing
                for title in ["api", Self.long, Self.wide] {
                    let r = AgentSidebar.row(d1.session(title, .blocked), details: .all, now: AgentWindowD1Tests.now)
                    let tag = "\(title) at \(scale) \(backing)x"
                    let p = parts(AgentSidebarRowView(row: r, selected: false, number: 2, mini: true), width: width, backing: backing)
                    let name = try XCTUnwrap(p["miniName"], "the name drawn: \(p.keys.sorted()) \(tag)")
                    let ideal = Self.exact(Text(AgentSidebarRowView.miniName(title)).font(Neon.font(11, weight: .medium)))
                    XCTAssertEqual(name.width, ideal, accuracy: pixel, "the cut name whole, never squeezed: \(name) \(tag)")
                    XCTAssertGreaterThanOrEqual(name.minX, -pixel, tag)
                    XCTAssertLessThanOrEqual(name.maxX, width + pixel, "inside the row: \(tag)")
                    let sup = try XCTUnwrap(p["miniSup"], "row 2's superscript: \(p.keys.sorted()) \(tag)")
                    XCTAssertGreaterThanOrEqual(sup.minX, name.maxX - pixel, "after the name: \(tag)")
                    XCTAssertLessThanOrEqual(sup.minY, name.minY + pixel, "raised: \(sup) \(name) \(tag)")
                    XCTAssertLessThanOrEqual(sup.maxX, width + pixel, "inside the row: \(tag)")
                    let needs = try XCTUnwrap(p["miniNeeds"], tag)
                    XCTAssertGreaterThanOrEqual(needs.minX, sup.maxX - pixel, "the needs-you mark last: \(tag)")
                    XCTAssertLessThanOrEqual(needs.maxX, width + pixel, "inside the row: \(tag)")
                }
                for (n, show, drawn) in [(9, AgentIslandRowDetails.all, true), (10, .all, false), (18, .all, false),
                                         (2, noShortcut, false), (nil, .all, false)] as [(Int?, AgentIslandRowDetails, Bool)] {
                    let p = parts(AgentSidebarRowView(row: blocked, selected: false, number: n, mini: true, show: show),
                                  width: width, backing: backing)
                    XCTAssertEqual(p["miniSup"] != nil, drawn, "row \(String(describing: n)), shortcut \(show.shortcut) at \(scale) \(backing)x")
                    XCTAssertNotNil(p["miniName"], "the name always at \(scale)")
                }
            }
        }
    }

    /// The rail is measured, not a literal: it is the widest line's ideal (eight W's cut, the mark, superscript and needs-you
    /// slots) plus the list's padding, wider than those parts alone, and narrower than the full sidebar, which is unchanged.
    func testMiniRailIsMeasuredFromEightWideCharacters() {
        atScales { scale in
            let line = Self.exact(AgentSidebarRowView.miniWidestLine)
            let rail = AgentWindowModel.miniSidebarWidth
            XCTAssertEqual(rail, (line + 2 * sz(8)).rounded(.up), accuracy: 0.01, "at \(scale)")
            let eight = Self.exact(Text(String(repeating: "W", count: 8) + "\u{2026}").font(Neon.font(11, weight: .medium)))
            XCTAssertGreaterThan(rail, eight + sz(14) + sz(6) + 2 * sz(8), "eight W's, the mark and needs-you slots fit at \(scale)")
            XCTAssertLessThan(rail, AgentWindowModel.fullSidebarWidth, "a rail at \(scale)")
            XCTAssertEqual(AgentWindowModel.fullSidebarWidth, sz(290) + AgentWindowModel.digitColumnExtra, accuracy: 0.01, "Full unchanged")
        }
    }

    /// The tooltip: the row's own hover handler; nothing at once nor at 0.1 s, the whole (uncut) name after the delay, drawn
    /// in the window beside the rail and inside the window; gone at hover end. A leave before the delay shows nothing.
    func testMiniTipShowsTheFullNameAfterTheDelayAndGoesOnHoverEnd() throws {
        try modes.withModeRow {
            Preferences.agentSidebarMode = .mini
            let m = d1.windowModel(d1.store([d1.session(Self.long, .working), d1.session("api", .idle)]))
            defer { m.close() }
            m.setVisible(true)
            let win = AgentWindowStyleTests.makeStandardWindow(m)
            defer { win.contentViewController = nil }
            let box = AgentWindowD1Tests.PaneProbeBox()
            AgentSidebarRowView.probe = { kind, _, r in box.seen[kind] = r }
            defer { AgentSidebarRowView.probe = nil }
            modes.settle(win)
            XCTAssertFalse(win.isVisible, "built, never shown")
            let row = try XCTUnwrap(m.sections.flatMap(\.rows).first { $0.title == Self.long }, "\(m.sections.map(\.title))")
            let view = AgentSidebarRowView(row: row, selected: false, mini: true, tip: m.miniTip)
            func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

            view.hover(true)
            view.hover(false)
            spin(0.5)
            XCTAssertTrue(m.miniTip.shown == nil, "left before the delay: no tooltip")

            view.hover(true)
            XCTAssertTrue(m.miniTip.shown == nil, "not at once")
            spin(0.1)
            XCTAssertTrue(m.miniTip.shown == nil, "not before the delay")
            let deadline = Date().addingTimeInterval(3)
            while m.miniTip.shown == nil && Date() < deadline { spin(0.05) }
            XCTAssertEqual(m.miniTip.shown?.title, Self.long, "the whole name")
            modes.settle(win)
            let tip = try XCTUnwrap(box.seen["miniTip"], "drawn in the window: \(box.seen.keys.sorted())")
            let pixel = AXTreeSupport.devicePixel
            XCTAssertGreaterThanOrEqual(tip.minX, AgentWindowModel.miniSidebarWidth - sz(8) - pixel, "beside the row: \(tip)")
            XCTAssertLessThanOrEqual(tip.maxX, win.frame.width + pixel, "inside the window: \(tip)")
            XCTAssertGreaterThan(tip.height, 0)

            view.hover(false)
            XCTAssertTrue(m.miniTip.shown == nil, "gone at hover end")
            spin(0.5)
            XCTAssertTrue(m.miniTip.shown == nil, "and stays gone")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// i1: a shown tip (and a pending show) whose row leaves the drawn rows is cleared, and does not come back when the id is drawn again.
    func testMiniTipIsClearedWhenItsRowLeavesTheList() throws {
        try modes.withModeRow {
            Preferences.agentSidebarMode = .mini
            let m = d1.windowModel(d1.store([d1.session(Self.long, .working), d1.session("api", .idle)]))
            defer { m.close() }
            m.setVisible(true)
            let win = AgentWindowStyleTests.makeStandardWindow(m)
            defer { win.contentViewController = nil }
            modes.settle(win)
            let rows = m.sections.flatMap(\.rows)
            let row = try XCTUnwrap(rows.first { $0.title == Self.long })
            let all = Set(rows.map(\.id))
            let tip = m.miniTip
            func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
            tip.hover(row, true)
            let deadline = Date().addingTimeInterval(3)
            while tip.shown == nil && Date() < deadline { spin(0.05) }
            XCTAssertEqual(tip.shown?.title, Self.long)
            tip.prune(all)
            XCTAssertEqual(tip.shown?.title, Self.long, "row still drawn: kept")
            tip.prune(all.subtracting([row.id]))
            XCTAssertTrue(tip.shown == nil, "row gone: cleared")
            tip.prune(all)
            spin(0.5)
            XCTAssertTrue(tip.shown == nil, "row back: no tip until a new hover")
            tip.hover(row, true)
            tip.prune(all.subtracting([row.id]))
            tip.prune(all)
            spin(0.6)
            XCTAssertTrue(tip.shown == nil, "a pending show for a gone row is cancelled")
            tip.hover(row, true)
            let d2 = Date().addingTimeInterval(3)
            while tip.shown == nil && Date() < d2 { spin(0.05) }
            XCTAssertEqual(tip.shown?.title, Self.long, "a new hover shows it again")
            tip.hover(row, false)
        }
    }

    // MARK: Helpers

    static func exact<V: View>(_ v: V) -> CGFloat {
        AgentSidebarRowView.idealWidths(v, EmptyView()).first ?? -1
    }

    func parts(_ view: AgentSidebarRowView, width: CGFloat, backing: CGFloat) -> [String: CGRect] {
        let box = AgentWindowD1Tests.PaneProbeBox()
        AgentSidebarRowView.probe = { kind, _, r in box.seen[kind] = r }
        defer { AgentSidebarRowView.probe = nil }
        let size = CGSize(width: width.rounded(.up), height: 60)
        let win = MiniNamesBackingWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                                         backing: .buffered, defer: true)
        win.fixedBacking = backing
        win.isReleasedWhenClosed = false
        defer { win.contentView = nil; win.close() }
        let host = NSHostingView(rootView: view.frame(width: width).frame(width: size.width, height: size.height, alignment: .topLeading))
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        d1.settle(host)
        d1.settle(host)
        XCTAssertFalse(win.isVisible, "never on screen")
        return box.seen
    }
}

private final class MiniNamesBackingWindow: NSWindow {
    var fixedBacking: CGFloat = 1
    override var backingScaleFactor: CGFloat { fixedBacking }
}
