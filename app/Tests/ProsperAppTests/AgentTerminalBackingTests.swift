import AppKit
import GhosttyTerminal
import XCTest
@testable import ProsperApp

/// #2065: the Agent Sessions window moved between a Retina (2x) and a non-Retina (1x) display. The terminal keeps its
/// point size and takes the new screen's scale, as a window opened there does; at 1x only, Ghostty thickens its glyphs.
/// Offscreen: the rig's window reports a fixed backing (ShownWindow.fixedBacking) and the switch calls the view's
/// viewDidChangeBackingProperties, as AppKit does on a move (a fixed backing posts nothing by itself).
final class AgentTerminalBackingTests: XCTestCase {
    @MainActor
    func wait(_ what: String, state: () -> String = { "" }, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(10)
        while !done() {
            if Date() > end { return XCTFail("timed out: \(what)\(state())") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// AgentTerminalTests' offscreen view rig at a fixed backing, attached, its (recorder) client started.
    @MainActor
    func startedView(backing: CGFloat) -> AgentTerminalTests.ViewRig {
        let v = AgentTerminalTests.ViewRig(backing: backing)
        v.start()
        wait("the surface reports its grid and the client starts at \(backing)x") { v.rig.child != nil }
        return v
    }

    /// The rule and the config line. Red on the parent: no thicken(_:) and no font-thicken line in the overlay.
    @MainActor
    func testThickeningIsOnAt1xAndOffAt2x() {
        let saved = AgentTerminalLook.backing
        defer { AgentTerminalLook.backing = saved }
        XCTAssertEqual([CGFloat(1), 1.5, 2, 3].map { AgentTerminalLook.thicken($0) }, [true, true, false, false])
        let c = AgentTerminalLook.make(colours: [])
        for (backing, on) in [(CGFloat(1), true), (2, false), (1, true)] {
            AgentTerminalLook.backing = backing
            AgentTerminalLook.refresh(c, colours: [])
            XCTAssertTrue(c.lastConfigurationIssue == nil, "libghostty accepted the overlay at \(backing)x")
            XCTAssertEqual(c.renderedConfig.contains("font-thicken = true"), on, "at \(backing)x")
        }
        // Under "My Ghostty theme" too: the user's colour lines and the thickening ride on the one overlay.
        AgentTerminalLook.refresh(c, colours: [("background", "#101010")])
        XCTAssertTrue(c.renderedConfig.contains("font-thicken = true"), "1x with the user's colours")
        XCTAssertTrue(c.renderedConfig.contains("background = #101010"))
        // #1873: and Prosper's theme (its palette, display-p3) is dropped at 1x as at 2x: refresh's overlay comparison holds.
        XCTAssertTrue(c.theme == TerminalTheme() && !c.renderedConfig.contains("display-p3"), "the user's colours at 1x")
    }

    /// 2x -> 1x and 1x -> 2x: the grid ends as a window created at the new scale has it (cell pixels, columns, rows),
    /// the layer draws at the new scale, the font keeps its point size, and the thickening follows. Red on the parent:
    /// the font-thicken asserts (no handler, no line); red with the handler removed: the same asserts after a switch.
    @MainActor
    func testABackingChangeMatchesAWindowCreatedAtTheNewScale() {
        let saved = AgentTerminalLook.backing
        defer { AgentTerminalLook.backing = saved }
        var fresh: [CGFloat: TerminalGridMetrics] = [:]
        for b: CGFloat in [1, 2] {
            let v = startedView(backing: b)
            wait("a grid at \(b)x") { v.host.gridMetrics != nil }
            fresh[b] = v.host.gridMetrics
            XCTAssertEqual(v.host.fontShown, AgentTerminalController.fontSize, "the font's point size at \(b)x")
            v.tearDown()
        }
        guard let one = fresh[1], let two = fresh[2] else { return XCTFail("no grid: \(fresh)") }
        print("#2065 cell at 2x: \(two.cellWidthPixels)x\(two.cellHeightPixels) px = \(CGFloat(two.cellWidthPixels) / 2)x"
              + "\(CGFloat(two.cellHeightPixels) / 2) pt; created at 1x: \(one.cellWidthPixels)x\(one.cellHeightPixels) px/pt")
        XCTAssertEqual(CGFloat(two.cellHeightPixels) / 2, CGFloat(one.cellHeightPixels), accuracy: 1,
                       "the same point size at 1x and 2x (a cell within a point)")
        XCTAssertEqual(CGFloat(two.cellWidthPixels) / 2, CGFloat(one.cellWidthPixels), accuracy: 1)

        for (from, to) in [(CGFloat(2), CGFloat(1)), (1, 2)] {
            AgentTerminalLook.backing = 3 - from   // the last terminal was on the other screen: show() takes its own
            let v = startedView(backing: from)
            wait("a grid at \(from)x") { v.host.gridMetrics != nil }
            XCTAssertEqual(v.app.renderedConfig.contains("font-thicken = true"), from < 2, "created at \(from)x")
            v.window.fixedBacking = to
            v.host.viewDidChangeBackingProperties()
            XCTAssertEqual(v.app.renderedConfig.contains("font-thicken = true"), to < 2, "\(from)x -> \(to)x: thickening")
            XCTAssertTrue(v.app.lastConfigurationIssue == nil, "\(from)x -> \(to)x: libghostty accepted the overlay")
            // The wrapper keeps the old scale while the window has no screen (a display going away); an offscreen
            // window normally has one. Without it only the thickening above is checked.
            if v.window.screen != nil {
                let want = to == 1 ? one : two
                wait("\(from)x -> \(to)x: the grid of a window created at \(to)x",
                              state: { " (now \(String(describing: v.host.gridMetrics)), want \(want))" }) {
                    v.host.gridMetrics.map { [$0.cellWidthPixels, $0.cellHeightPixels, UInt32($0.columns), UInt32($0.rows)] }
                        == [want.cellWidthPixels, want.cellHeightPixels, UInt32(want.columns), UInt32(want.rows)]
                }
                XCTAssertEqual(v.host.layer?.contentsScale, to, "\(from)x -> \(to)x: the layer draws at the new scale")
            } else {
                print("#2065: the offscreen window has no screen; the grid half of \(from)x -> \(to)x is not checked")
            }
            XCTAssertEqual(v.host.fontShown, AgentTerminalController.fontSize, "\(from)x -> \(to)x: the same point size")
            v.tearDown()
        }
    }
}
