import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1923 (operator 2026-11-24): the Full sidebar's width is dragged at its line: never under TIP's width, never over 40% of
/// the window's content (the minimum wins), remembered per Mac in points at UI scale 1.0 (written at the drag's end only),
/// re-clamped when the window or the scale changes; Mini's rail is fixed; the panes keep their minimum. Offscreen only: the
/// drag goes through the model's seam (no event is built or posted), the window is never shown, the store is the XCTest
/// scratch defaults (the width and mode keys are cleared and put back by every row).
@MainActor
final class AgentSidebarWidthTests: XCTestCase {
    private let d1 = AgentWindowD1Tests()
    private let modes = AgentSidebarModeTests()
    static let key = "agentSidebarWidth"
    static let scales: [CGFloat] = [0.7, 0.85, 1.0]

    /// Runs `body` with the width key cleared (and Full, gate off, scale 1 by AgentSidebarModeTests.withModeRow), put back after.
    func withClearedWidth(_ body: () throws -> Void) rethrows {
        _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before a row sets the scale
        let d = Preferences.defaults
        XCTAssertFalse(d === UserDefaults.standard, "a private defaults store")
        let saved = d.object(forKey: Self.key)
        defer { if let saved { d.set(saved, forKey: Self.key) } else { d.removeObject(forKey: Self.key) } }
        d.removeObject(forKey: Self.key)
        try modes.withModeRow(body)
    }

    func model() -> AgentWindowModel { d1.windowModel(d1.store([d1.session("api", .idle)])) }

    /// Red at TIP (no AgentSidebarWidth; sidebarColumnWidth was fullSidebarWidth always): unset, the drawn width is TIP's;
    /// a drag narrower than it stops at it, at every scale.
    func testSidebarWidthMinimumIsTodaysWidth() {
        withClearedWidth {
            for scale in Self.scales {
                ThemeRuntime.scale = scale
                let least = AgentWindowModel.fullSidebarWidth
                XCTAssertEqual(AgentSidebarWidth.width(stored: nil, content: 2000 * scale), least, "unset at \(scale)")
                XCTAssertEqual(AgentSidebarWidth.width(stored: 10, content: 2000 * scale), least, "a tiny stored width at \(scale)")
                let m = model()
                defer { m.close() }
                m.sidebarWidth.content = 2000 * scale
                XCTAssertEqual(m.sidebarColumnWidth, least, "a new model at \(scale)")
                m.sidebarDragged(by: -500)
                XCTAssertEqual(m.sidebarWidth.drawn, least, accuracy: 0.001, "a drag left stops at the minimum at \(scale)")
                m.sidebarDragEnded()
            }
        }
    }

    /// Red when the 40% line is gone or not the window's: a drag right stops at 40% of the content; where 40% is under the
    /// minimum, the minimum wins.
    func testSidebarWidthMaximumIsFortyPercentOfTheWindow() {
        withClearedWidth {
            for scale in Self.scales {
                ThemeRuntime.scale = scale
                let least = AgentWindowModel.fullSidebarWidth
                XCTAssertEqual(AgentSidebarWidth.width(stored: 1e9, content: 2000 * scale), 800 * scale, accuracy: 0.001, "40% at \(scale)")
                let narrow = AgentsWindow.contentMinSize(scale: scale).width
                XCTAssertLessThan(narrow * 0.4, least, "the window's minimum: 40% is under the sidebar's minimum at \(scale)")
                XCTAssertEqual(AgentSidebarWidth.width(stored: 1e9, content: narrow), least, accuracy: 0.001, "the minimum wins at \(scale)")
                let m = model()
                defer { m.close() }
                m.sidebarWidth.content = 1500 * scale
                m.sidebarDragged(by: 10_000)
                XCTAssertEqual(m.sidebarColumnWidth, 600 * scale, accuracy: 0.001, "a drag right stops at 40% at \(scale)")
                m.sidebarDragEnded()
            }
        }
    }

    /// Red when the width is written on every tick or not at all: the ticks move only the in-memory width (the model itself
    /// publishes nothing: the column alone redraws), the up writes it once in points at scale 1.0 (dragged at 0.85), and
    /// a new model (the next launch) draws it at scale 1.0 times 1.0.
    func testSidebarWidthPersistsOnMouseUpOnly() throws {
        try withClearedWidth {
            ThemeRuntime.scale = 0.85
            let m = model()
            defer { m.close() }
            m.sidebarWidth.content = 2000
            let least = AgentWindowModel.fullSidebarWidth
            var modelSends = 0, widthSends = 0
            let a = m.objectWillChange.sink { _ in modelSends += 1 }, b = m.sidebarWidth.objectWillChange.sink { _ in widthSends += 1 }
            defer { a.cancel(); b.cancel() }
            m.sidebarDragged(by: 40)
            m.sidebarDragged(by: 100)
            XCTAssertTrue(m.sidebarWidth.dragging)
            XCTAssertTrue(Preferences.defaults.object(forKey: Self.key) == nil, "nothing written while dragging")
            XCTAssertEqual(m.sidebarColumnWidth, least + 100, accuracy: 0.001, "from the drag's start, not cumulative")
            m.sidebarDragged(by: 10_000)
            m.sidebarDragged(by: 20_000)
            XCTAssertEqual(widthSends, 3, "one publish per moved tick, none at the clamp")
            XCTAssertEqual(modelSends, 0, "the model's views are not redrawn by a drag")
            m.sidebarDragEnded()
            XCTAssertFalse(m.sidebarWidth.dragging)
            XCTAssertEqual(try XCTUnwrap(Preferences.agentSidebarWidth), 800 / 0.85, accuracy: 0.001, "written once at the up, at scale 1.0")
            m.sidebarDragEnded()   // a second up: nothing
            ThemeRuntime.scale = 1.0
            let next = model()
            defer { next.close() }
            next.sidebarWidth.content = 3000
            XCTAssertEqual(next.sidebarColumnWidth, 800 / 0.85, accuracy: 0.001, "the next launch, at another scale")
            XCTAssertEqual(next.sidebarFrame(in: CGSize(width: 3000, height: 700))?.width ?? 0, 800 / 0.85, accuracy: 0.001, "the click rule's frame")
            XCTAssertEqual(next.paneAreaFrame(in: CGSize(width: 3000, height: 700))?.minX ?? 0, 800 / 0.85 + 1, accuracy: 0.001, "the panes start after it")
        }
    }

    /// Red when the window's width does not reach the sidebar (the root view's geometry) or the stored width is clamped
    /// for good: a narrower window draws 40% of it, a wider one the stored width again; under the line a resize
    /// publishes nothing; the pane area is the rest, in a hosted root view that is never shown.
    func testSidebarWidthIsReclampedWhenTheWindowResizes() throws {
        try withClearedWidth {
            Preferences.agentSidebarWidth = 600
            let m = model()
            m.setVisible(true)
            defer { m.close() }
            let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 2000, height: 700), styleMask: [.borderless], backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            defer { win.contentView = nil; win.close() }
            let host = NSHostingView(rootView: AgentWindowRootView(model: m, scrolls: false))
            host.frame = CGRect(x: 0, y: 0, width: 2000, height: 700)
            win.contentView = host
            let focus = d1   // its settle(_:) (AgentWindowFocusTests.swift)
            focus.settle(host)
            XCTAssertEqual(m.sidebarWidth.content, 2000, accuracy: 0.5, "the root view's width reached it")
            XCTAssertEqual(m.sidebarColumnWidth, 600, accuracy: 0.5, "the stored width")
            XCTAssertEqual(m.paneArea.width, 2000 - 600 - 1, accuracy: 0.5, "the panes take the rest")
            host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
            focus.settle(host)
            XCTAssertEqual(m.sidebarColumnWidth, 400, accuracy: 0.5, "re-clamped to 40%")
            XCTAssertEqual(m.paneArea.width, 1000 - 400 - 1, accuracy: 0.5, "the panes follow")
            XCTAssertEqual(try XCTUnwrap(Preferences.agentSidebarWidth), 600, "the stored width is kept")
            host.frame = CGRect(x: 0, y: 0, width: 2000, height: 700)
            focus.settle(host)
            XCTAssertEqual(m.sidebarColumnWidth, 600, accuracy: 0.5, "a wider window: the stored width again")
            XCTAssertFalse(win.isVisible, "never on screen")
            Preferences.agentSidebarWidth = nil
            let unset = model()
            defer { unset.close() }
            var sends = 0
            let sink = unset.sidebarWidth.objectWillChange.sink { _ in sends += 1 }
            defer { sink.cancel() }
            for w: CGFloat in [1000, 1200, 1600, 2400] { unset.sidebarWidth.content = w }
            XCTAssertEqual(sends, 0, "a resize that leaves the drawn width alone publishes nothing")
        }
    }

    /// Red when Mini reads the dragged width: its rail stays measured and fixed whatever Full's stored width; Slide's
    /// overlay (sidebarFrame) is Full's width and takes nothing from the panes.
    func testSidebarWidthLeavesMiniFixedAndSlideAtFullWidth() {
        withClearedWidth {
            Preferences.agentSidebarWidth = 600
            Preferences.agentSidebarMode = .mini
            let m = model()
            defer { m.close() }
            m.sidebarWidth.content = 2000
            XCTAssertEqual(m.sidebarColumnWidth, AgentWindowModel.miniSidebarWidth, "Mini's rail")
            XCTAssertEqual(m.sidebarFrame(in: CGSize(width: 2000, height: 700))?.width ?? 0, AgentWindowModel.miniSidebarWidth, "Mini's frame")
            m.setSidebarMode(.slide)
            m.toggleSidebar()   // Control-Command-S pins Slide's overlay in
            XCTAssertTrue(m.sidebarShown)
            XCTAssertEqual(m.sidebarFrame(in: CGSize(width: 2000, height: 700))?.width ?? 0, 600, accuracy: 0.001, "Slide's overlay: Full's width")
            XCTAssertEqual(m.paneAreaFrame(in: CGSize(width: 2000, height: 700))?.minX ?? -1, 0, "Slide's panes keep the whole width")
        }
    }

    /// Red when the 40% line or the sliver goes: at every width from the window's minimum up, at every scale, with the
    /// widest stored width, the panes keep their minimum (300·s); a window under its minimum still leaves the panes a sliver.
    func testSidebarWidthLeavesThePanesTheirMinimum() {
        withClearedWidth {
            for scale in Self.scales {
                ThemeRuntime.scale = scale
                let least = AgentsWindow.contentMinSize(scale: scale).width
                for content in stride(from: least, through: 3000 * scale, by: 37) {
                    let side = AgentSidebarWidth.width(stored: 1e9, content: content)
                    XCTAssertGreaterThanOrEqual(content - side - 1, sz(PaneLayout.minimumPane.width) - 0.001, "\(content) at \(scale)")
                }
                for content in stride(from: 50 * scale, to: least, by: 23) {
                    let side = AgentSidebarWidth.width(stored: 1e9, content: content)
                    XCTAssertGreaterThanOrEqual(content - side - 1, min(content - 1, sz(AgentSidebarWidth.sliver)) - 0.001, "under the minimum: \(content) at \(scale)")
                    XCTAssertGreaterThanOrEqual(side, 0)
                }
            }
        }
    }
}
