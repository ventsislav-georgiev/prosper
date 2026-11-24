import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1925 (operator 2026-11-24, "just a smidge"): the Agent Sessions window is never narrower than the sidebar column, its
/// 1 pt line and a small strip of the panes (AgentSidebarWidth.strip, #1923's sliver too), and the SwiftUI content cannot
/// lower that. Offscreen only: windows are built and never shown, the mode and drag go through the model's seams, the
/// store is the XCTest scratch defaults (put back by AgentSidebarModeTests.withModeRow and AgentSidebarWidthTests).
@MainActor
final class AgentWindowMinWidthTests: XCTestCase {
    private let d1 = AgentWindowD1Tests()
    private let widths = AgentSidebarWidthTests()
    static let scales: [CGFloat] = [0.7, 0.85, 1.0]

    func model() -> AgentWindowModel { d1.windowModel(d1.store([d1.session("api", .idle)])) }
    func content(_ win: NSWindow) -> CGSize { win.contentRect(forFrameRect: win.frame).size }
    /// Literal widths, not the helper under test: Full's least width (TIP's 290 plus #1470's chip growth) and Mini's rail.
    func full(_ s: CGFloat) -> CGFloat { 290 * s + AgentWindowModel.digitColumnExtra(at: s) }
    /// #1932: with no column the strip, but never under the title buttons' width (a literal frame-to-content conversion).
    func least(_ win: NSWindow, _ s: CGFloat) -> CGFloat {
        guard win.styleMask.contains(.titled) else { return 40 * s }
        return max(40 * s, win.contentRect(forFrameRect: NSRect(x: 0, y: 0, width: NSWindow.minFrameWidth(withTitle: "", styleMask: win.styleMask), height: 100)).width)
    }

    /// Red when the minimum is not sidebar + line + strip per mode (today's 640·s, or the strip forgotten), when a mode
    /// switch or ⌃⌘S does not reach the open window, or when a window under a new minimum is not grown to it.
    func testMinimumIsTheSidebarColumnItsLineAndTheStripInEveryMode() {
        widths.withClearedWidth {
            for s in Self.scales {
                ThemeRuntime.scale = s
                let m = model()
                defer { m.close() }
                let win = AgentWindowStyleTests.makeStandardWindow(m)
                defer { win.contentViewController = nil }
                XCTAssertFalse(win.isVisible, "never on screen")
                XCTAssertEqual(AgentSidebarWidth.strip, 40, "one constant: the window's strip and #1923's sliver")
                XCTAssertEqual(win.contentMinSize.width, full(s) + 1 + 40 * s, accuracy: 0.001, "Full at \(s)")
                XCTAssertEqual(win.contentMinSize.height, 420 * s, accuracy: 0.001, "the height is as before at \(s)")
                XCTAssertLessThan(win.contentMinSize.width, 640 * s, "narrower than before #1925 at \(s)")
                m.setSidebarMode(.mini)
                XCTAssertEqual(win.contentMinSize.width, AgentWindowModel.miniSidebarWidth(at: s) + 1 + 40 * s, accuracy: 0.001, "Mini at \(s)")
                m.setSidebarMode(.slide)
                XCTAssertEqual(win.contentMinSize.width, least(win, s), accuracy: 0.001, "Slide: no column, no line, the title buttons at \(s)")
                m.toggleSidebar()   // Slide pinned in: an overlay over the panes, the minimum stays
                XCTAssertEqual(win.contentMinSize.width, least(win, s), accuracy: 0.001, "Slide pinned at \(s)")
                win.setContentSize(NSSize(width: 60 * s, height: 500 * s))   // narrow, as the person may leave it in Slide
                m.setSidebarMode(.full)
                XCTAssertEqual(content(win).width, full(s) + 1 + 40 * s, accuracy: 0.5, "a new, larger minimum grows the window at \(s)")
                XCTAssertEqual(content(win).height, 500 * s, accuracy: 0.5, "the height is kept at \(s)")
                AgentPaneLayout.splitsEnabled = true
                m.toggleSidebar()   // ⌃⌘S hides Full's column
                XCTAssertFalse(m.sidebarShown)
                XCTAssertEqual(win.contentMinSize.width, least(win, s), accuracy: 0.001, "hidden: no column at \(s)")
                m.toggleSidebar()
                XCTAssertEqual(win.contentMinSize.width, full(s) + 1 + 40 * s, accuracy: 0.001, "shown again at \(s)")
                AgentPaneLayout.splitsEnabled = false
            }
        }
    }

    /// Red when the drag can leave the panes under the strip at the minimum: whatever the dragged width, at the window's
    /// minimum the 40% line draws the sidebar at its least width, so the minimum (unchanged by the drag's end) is the drawn
    /// sidebar + line + strip; a narrower content would leave the panes less than the strip.
    func testAfterADragTheMinimumIsTheDrawnSidebarPlusLineAndStrip() {
        widths.withClearedWidth {
            for s in Self.scales {
                ThemeRuntime.scale = s
                let m = model()
                defer { m.close() }
                let win = AgentWindowStyleTests.makeStandardWindow(m)
                defer { win.contentViewController = nil }
                let before = win.contentMinSize
                m.sidebarWidth.content = 2000 * s
                m.sidebarDragged(by: 10_000)
                m.sidebarDragEnded()
                XCTAssertGreaterThan(m.sidebarWidth.drawn, full(s) + 100, "dragged wide at \(s)")
                XCTAssertEqual(win.contentMinSize, before, "the drag's end leaves the minimum at \(s)")
                let least = win.contentMinSize.width
                m.sidebarWidth.content = least   // the window at its minimum
                XCTAssertEqual(m.sidebarWidth.drawn, full(s), accuracy: 0.001, "the sidebar drawn at the minimum at \(s)")
                XCTAssertEqual(least - m.sidebarWidth.drawn - 1, 40 * s, accuracy: 0.001, "the panes keep the strip at \(s)")
            }
        }
    }

    /// Red when a scale change keeps the old minimum or the default sizing (today's 640·s): the theme hook writes the
    /// minimum for the window's own sidebar at the new scale and grows a window under it.
    func testScaleChangeRewritesTheMinimumForTheSidebar() {
        widths.withClearedWidth {
            ThemeRuntime.scale = 0.7
            let m = model()
            defer { m.close() }
            m.setSidebarMode(.mini)
            let win = AgentWindowStyleTests.makeStandardWindow(m)
            defer { win.contentViewController = nil }
            win.setContentSize(NSSize(width: AgentWindowModel.miniSidebarWidth(at: 0.7) + 1 + 28, height: 600))
            ThemeRuntime.scale = 1
            AppDelegate.applyThemedWindowSizing([win], scale: 1)
            let want = AgentWindowModel.miniSidebarWidth(at: 1) + 1 + 40
            XCTAssertEqual(win.contentMinSize.width, want, accuracy: 0.001, "Mini at 1.0")
            XCTAssertEqual(win.contentMinSize.height, 420, accuracy: 0.001)
            XCTAssertEqual(content(win).width, want, accuracy: 0.5, "the window grew to the new minimum")
        }
    }

    /// Red when the hosting controller keeps its default sizing: on SwiftUI's update pass (a run loop turn) it writes its
    /// own minimum (the sidebar + line, the panes' is 0) over the window's.
    func testSwiftUIContentCannotLowerTheMinimum() throws {
        try widths.withClearedWidth {
            let m = model()
            defer { m.close() }
            let win = AgentWindowStyleTests.makeStandardWindow(m)
            defer { win.contentViewController = nil }
            let hosting = try XCTUnwrap(win.contentViewController as? NSHostingController<Themed<AgentWindowRootView>>)
            XCTAssertEqual(hosting.sizingOptions, [], "the window's minimum is set by AgentsWindow alone")
            let want = win.contentMinSize
            win.setContentSize(NSSize(width: 1000, height: 680))
            win.contentView?.layoutSubtreeIfNeeded()
            win.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))   // SwiftUI's own update pass
            win.contentView?.needsLayout = true
            win.layoutIfNeeded()
            XCTAssertEqual(win.contentMinSize, want, "SwiftUI's update pass and a layout leave the minimum")
            win.contentMinSize = NSSize(width: 0, height: 0)   // what the hosting controller writes with no sizing options
            XCTAssertEqual(win.contentMinSize, want, "a write from outside AgentsWindow is put back")
        }
    }

    /// Red when a style loses the minimum: built in each style and restyled to each (#1378 applyStyle re-sets the mask).
    func testEveryStyleKeepsTheMinimum() {
        widths.withClearedWidth {
            let d = Preferences.defaults, saved = d.object(forKey: "agentWindowStyle")
            defer { if let saved { d.set(saved, forKey: "agentWindowStyle") } else { d.removeObject(forKey: "agentWindowStyle") } }
            let want = NSSize(width: full(1) + 1 + 40, height: 420)
            for built in AgentWindowStyle.allCases {
                Preferences.agentWindowStyle = built
                let m = model()
                defer { m.close() }
                let win = AgentsWindow.makeWindow(m, autosave: nil)
                defer { win.contentViewController = nil }
                XCTAssertEqual(win.contentMinSize, want, "built \(built)")
                for style in AgentWindowStyle.allCases {
                    AgentsWindow.applyStyle(win, style: style, rounded: true)
                    XCTAssertEqual(win.contentMinSize, want, "built \(built), restyled \(style)")
                }
                XCTAssertFalse(win.isVisible, "never on screen")
            }
        }
    }

    /// #1932 (i1). Red when the narrowest window (Slide, or the sidebar hidden) is under its title buttons' width: Standard
    /// and No title bar are titled (the three buttons, hidden in No title bar but their band stays), Borderless has none.
    /// Built in each style and restyled to each, the minimum re-read each time; a window narrower is grown to it.
    func testTitleButtonsKeepTheirWidthInEveryStyle() {
        widths.withClearedWidth {
            let d = Preferences.defaults, saved = d.object(forKey: "agentWindowStyle")
            defer { if let saved { d.set(saved, forKey: "agentWindowStyle") } else { d.removeObject(forKey: "agentWindowStyle") } }
            ThemeRuntime.scale = 0.7   // 40·s is 28 pt: the strip alone is far under the buttons
            defer { ThemeRuntime.scale = 1 }
            Preferences.agentWindowStyle = .standard
            let m = model()
            defer { m.close() }
            m.setSidebarMode(.slide)
            let win = AgentsWindow.makeWindow(m, autosave: nil)
            defer { win.contentViewController = nil }
            let titled = NSWindow.minFrameWidth(withTitle: "", styleMask: [.titled, .closable, .miniaturizable, .resizable])
            XCTAssertGreaterThan(titled, 60, "a titled window's frame needs its traffic lights")
            for style in AgentWindowStyle.allCases {
                AgentsWindow.applyStyle(win, style: style, rounded: true)
                XCTAssertEqual(win.contentMinSize.width, least(win, 0.7), accuracy: 0.001, "\(style): the floor or the strip")
                if style == .borderless { XCTAssertEqual(win.contentMinSize.width, 28, accuracy: 0.001, "Borderless has no buttons: the strip") }
                if style != .borderless { XCTAssertGreaterThan(win.contentMinSize.width, 60, "\(style) keeps its title buttons") }
                win.setContentSize(NSSize(width: 10, height: 500))
                win.clampToContentMinSize()
                XCTAssertGreaterThanOrEqual(content(win).width, win.contentMinSize.width - 0.5, "\(style): a narrower window is grown")
            }
        }
    }

    /// #1932 (i3). Red when the scale hook only writes the minimum: a window under its new minimum is grown right away
    /// (the hook's own call, AgentsWindow.applyMinSize), and the new minimum keeps the title floor at the new scale.
    func testScaleHookClampsAndKeepsTheTitleFloor() {
        widths.withClearedWidth {
            ThemeRuntime.scale = 1
            let m = model()
            defer { m.close() }
            m.setSidebarMode(.slide)
            let win = AgentWindowStyleTests.makeStandardWindow(m)
            defer { win.contentViewController = nil }
            win.setContentSize(NSSize(width: 10, height: 500))
            ThemeRuntime.scale = 0.7
            AppDelegate.applyThemedWindowSizing([win], scale: 0.7)
            XCTAssertEqual(win.contentMinSize.width, least(win, 0.7), accuracy: 0.001, "the floor at the new scale")
            XCTAssertGreaterThan(win.contentMinSize.width, 28, "the floor, not the strip")
            XCTAssertGreaterThanOrEqual(content(win).width, win.contentMinSize.width - 0.5, "grown by the hook")
            ThemeRuntime.scale = 1
        }
    }

    /// Red when a restored frame narrower than the minimum is kept: a frame set under the minimum (a restore has come back
    /// unclamped before, #426; no defaults read or written here), then makeWindow's clamp grows it.
    func testRestoredNarrowFrameIsClampedToTheMinimum() {
        widths.withClearedWidth {
            let m = model()
            defer { m.close() }
            let win = AgentWindowStyleTests.makeStandardWindow(m)
            defer { win.contentViewController = nil }
            win.setFrame(NSRect(x: 100, y: 100, width: 120, height: 500), display: false)
            XCTAssertLessThan(content(win).width, win.contentMinSize.width, "the restore went under the minimum")
            win.clampToContentMinSize()
            XCTAssertEqual(content(win).width, full(1) + 1 + 40, accuracy: 0.5, "grown to sidebar + line + strip")
            XCTAssertFalse(win.isVisible, "never on screen")
        }
    }
}
