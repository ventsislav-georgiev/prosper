import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #713: the borderless runner and clipboard-history panels move by their bars.
///
/// `isMovableByWindowBackground` alone moved nothing: NSHostingView marks every
/// hit-testable SwiftUI shape as blocking a background drag, and the neon surface's
/// gradient spans the whole panel. A WindowDragHandle behind each bar takes the press
/// and starts the drag itself.
///
/// Offscreen and in-process only: the real panels are built but never ordered front,
/// no event is posted, and AppKit's performDrag never runs (the one press test uses a
/// window whose performDrag only records the call).
@MainActor
final class PanelDragAreaTests: XCTestCase {

    // MARK: - Probes

    /// The view a left press at `p` (window coordinates) lands on.
    private func hit(_ w: NSWindow, _ p: NSPoint) -> NSView? {
        w.contentView?.superview?.hitTest(p)
    }

    private func assertGrabs(_ w: NSWindow, _ p: NSPoint, _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let v = hit(w, p)
        XCTAssertTrue(v is WindowDragHandleView,
                      "\(what) @\(p): a press lands on \(v.map { "\(type(of: $0))" } ?? "nil"), not the drag handle",
                      file: file, line: line)
    }

    private func assertDoesNotGrab(_ w: NSWindow, _ p: NSPoint, _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let v = hit(w, p)
        XCTAssertNotNil(v, "\(what) @\(p): nothing under it", file: file, line: line)
        XCTAssertFalse(v is WindowDragHandleView, "\(what) @\(p): a press would drag the window", file: file, line: line)
    }

    // MARK: - The handle

    /// Records the drag request instead of running AppKit's drag loop.
    private final class RecordingWindow: NSWindow {
        var dragEvents: [NSEvent] = []
        override func performDrag(with event: NSEvent) { dragEvents.append(event) }
    }

    func testHandlePressStartsAWindowDragEvenOnAPanelThatIsNotKey() throws {
        let w = RecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        let handle = WindowDragHandleView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        w.contentView?.addSubview(handle)
        addTeardownBlock { MainActor.assumeIsolated { handle.removeFromSuperview() } }
        let press = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 50, y: 20), modifierFlags: [], timestamp: 0,
            windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertTrue(handle.acceptsFirstMouse(for: press), "the first press on a panel that is not key is a drag too")
        XCTAssertTrue(handle.mouseDownCanMoveWindow)
        handle.mouseDown(with: press)
        XCTAssertEqual(w.dragEvents.count, 1, "a press on the handle asks the window to drag")
        XCTAssertTrue(w.dragEvents.first === press)
    }

    private func settle(_ w: NSWindow) {
        for _ in 0..<3 {
            w.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
    }

    /// Frames (window space) of every descendant whose class name contains `name`.
    private func frames(_ v: NSView, named name: String) -> [CGRect] {
        var out = String(describing: type(of: v)).contains(name) ? [v.convert(v.bounds, to: nil)] : []
        for s in v.subviews { out += frames(s, named: name) }
        return out
    }

    // MARK: - Clipboard history

    private func clipboardPanel() throws -> (ClipboardPanel, NSWindow) {
        let store = ClipboardStore(dir: tempDir())
        // Enough rows to fill the list, so its middle is a row, not blank list.
        for i in 0..<14 { store.addText("clip \(i) \(UUID())", encrypt: false) }
        let cp = ClipboardPanel(store: store)
        let w = cp.panel
        XCTAssertFalse(w.isVisible, "the test never shows the panel")
        XCTAssertTrue(w.isMovableByWindowBackground)
        addTeardownBlock { MainActor.assumeIsolated { w.contentView = NSView() } }
        settle(w)
        return (cp, w)
    }

    func testClipboardBarsGrabAndControlsDoNot() throws {
        let (_, w) = try clipboardPanel()
        let h = w.frame.height
        let root = try XCTUnwrap(w.contentView)
        // The two menus (type filter top right, Actions bottom right), by window y.
        let popups = frames(root, named: "PopupButton").sorted { $0.minY < $1.minY }
        let actions = try XCTUnwrap(popups.first, "no Actions menu")
        let filter = try XCTUnwrap(popups.last, "no type-filter menu")
        XCTAssertGreaterThan(filter.minY, h / 2)
        let field = try XCTUnwrap(frames(root, named: "TextField").max { $0.width < $1.width }, "no search field")

        // Bottom bar: label, icon, the empty gap, the corner padding.
        let barY = actions.midY
        assertGrabs(w, NSPoint(x: sz(14) + sz(16) + sz(6) + sz(12), y: barY), "Clipboard History label")
        assertGrabs(w, NSPoint(x: sz(14) + sz(8), y: barY), "bottom bar app icon")
        assertGrabs(w, NSPoint(x: w.frame.width / 2, y: barY), "bottom bar gap")
        assertGrabs(w, NSPoint(x: sz(4), y: sz(3)), "bottom bar corner padding")
        // Search bar: its padding, the magnifier, the gap between the field and the menu.
        let searchY = filter.midY
        assertGrabs(w, NSPoint(x: w.frame.width / 2, y: h - sz(3)), "search bar top padding")
        assertGrabs(w, NSPoint(x: sz(4), y: searchY), "search bar leading padding")
        assertGrabs(w, NSPoint(x: sz(14) + sz(7), y: searchY), "magnifier")
        assertGrabs(w, NSPoint(x: (field.maxX + filter.minX) / 2, y: searchY), "gap before the filter menu")

        // Never on a control or the content.
        assertDoesNotGrab(w, NSPoint(x: field.midX, y: searchY), "search field")
        assertDoesNotGrab(w, NSPoint(x: filter.midX, y: filter.midY), "type-filter menu")
        assertDoesNotGrab(w, NSPoint(x: actions.midX, y: actions.midY), "Actions menu")
        assertDoesNotGrab(w, NSPoint(x: actions.minX - sz(13) - sz(20), y: barY), "Paste button")
        assertDoesNotGrab(w, NSPoint(x: sz(120), y: h / 2), "history list row")
        assertDoesNotGrab(w, NSPoint(x: w.frame.width * 0.7, y: h / 2), "preview pane")
    }

    /// A filter matching nothing leaves the preview blank (no hit-testable SwiftUI there):
    /// still no drag, so the handle must sit behind the bars only, not the whole panel.
    func testBlankPreviewDoesNotGrab() throws {
        let (cp, w) = try clipboardPanel()
        cp.model.query = "no clip matches \(UUID())"
        settle(w)
        assertDoesNotGrab(w, NSPoint(x: w.frame.width * 0.7, y: w.frame.height / 2), "blank preview pane")
        assertGrabs(w, NSPoint(x: w.frame.width / 2, y: sz(3)), "bottom bar padding")
    }

    // MARK: - Runner

    private func runnerPanel() -> (RunnerPanel, NSWindow) {
        let rp = RunnerPanel()
        let w = rp.panel
        XCTAssertFalse(w.isVisible, "the test never shows the panel")
        XCTAssertTrue(w.isMovableByWindowBackground)
        addTeardownBlock { MainActor.assumeIsolated { w.contentView = NSView() } }
        settle(w)
        return (rp, w)
    }

    /// The single-line runner: only the input header, so its padding is the grab area.
    func testRunnerInputPaddingGrabsAndTheFieldDoesNot() throws {
        let (_, w) = runnerPanel()
        let h = w.frame.height
        let root = try XCTUnwrap(w.contentView)
        let field = try XCTUnwrap(frames(root, named: "TextField").max { $0.width < $1.width }, "no input field")
        XCTAssertGreaterThan(field.width, 300)
        assertGrabs(w, NSPoint(x: sz(4), y: h / 2), "input leading padding")
        assertGrabs(w, NSPoint(x: w.frame.width / 2, y: h - sz(4)), "input top padding")
        assertGrabs(w, NSPoint(x: w.frame.width / 2, y: sz(4)), "input bottom padding")
        assertGrabs(w, NSPoint(x: sz(16) + sz(12), y: h / 2), "search icon")
        assertDoesNotGrab(w, NSPoint(x: field.midX, y: field.midY), "input field")
    }

    /// With a result: the action bar's glyph, gap and Enter hint grab; the menu does not.
    func testRunnerActionBarGrabsAndItsMenuDoesNot() throws {
        let (rp, w) = runnerPanel()
        rp.model.outcome = .calc(expression: "2+2", value: "4")
        settle(w)
        let h = w.frame.height
        XCTAssertGreaterThan(h, sz(120), "the runner grew to show the result")
        let root = try XCTUnwrap(w.contentView)
        let actions = try XCTUnwrap(frames(root, named: "PopupButton").min { $0.minY < $1.minY }, "no Actions menu")
        let barY = actions.midY
        XCTAssertLessThan(barY, sz(40), "the Actions menu sits in the bottom bar")
        assertGrabs(w, NSPoint(x: sz(14) + sz(6), y: barY), "command glyph")
        assertGrabs(w, NSPoint(x: w.frame.width / 2, y: barY), "action bar gap")
        assertGrabs(w, NSPoint(x: actions.minX - sz(10) - sz(1) - sz(10) - sz(8), y: barY), "Enter hint keycap")
        assertGrabs(w, NSPoint(x: w.frame.width / 2, y: h - sz(4)), "input top padding")
        assertDoesNotGrab(w, NSPoint(x: actions.midX, y: actions.midY), "Actions menu")
        assertDoesNotGrab(w, NSPoint(x: w.frame.width / 2, y: h / 2), "calculator card")
    }
}
