import AppKit
import XCTest
@testable import ProsperApp

/// #1112: the open island also closes when the user turns to another Prosper window: a mouse down
/// in it (the local monitor) or it taking key. Not while an island menu tracks, not for the panel's
/// own clicks or key, and a key change never drops an unsent Message draft.
/// No monitor is installed (both monitor seams are fakes), no window is shown, ordered or made key
/// (the windows here are created deferred and never ordered in), no event is posted: the handlers
/// are called directly and the key and menu notifications go to a private center.
final class AgentIslandAutoCloseTests: XCTestCase {
    private let notched = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)

    /// What the fake monitor seams saw: installs and removals by token, and the local handler.
    private final class Monitors: @unchecked Sendable {
        var global = 0
        var local = 0
        var removed: [String] = []
        var onOwnClick: (@MainActor (NSWindow?, NSPoint?) -> Void)?
        var seen: [String] = []
    }

    @MainActor private func controller(_ m: Monitors) -> AgentIslandController {
        let c = AgentIslandController()
        c.showsPanel = false
        c.center = NotificationCenter()   // private: posting here reaches only this controller
        c.io = AgentPromptIO(read: { _ in "" }, status: { _ in "idle" }, send: { _, _ in })
        c.controlDch = { nil }
        c.historyDirs = { [] }
        c.seedDirs = { [] }
        c.listSessions = { _ in [] }
        c.readLiveRecords = { _ in [] }
        c.monitorClicks = { _ in m.global += 1; return "global-\(m.global)" }
        c.monitorOwnClicks = { h in m.local += 1; m.onOwnClick = h; return "local-\(m.local)" }
        c.removeMonitor = { m.removed.append($0 as? String ?? "?") }
        let store = AgentIslandStore(geometry: notched)
        store.sessions = [AgentSession(key: AgentSessionKey(dir: "/Users/example/d", name: "api"), alias: "",
                                       activity: 0, state: .idle, agents: 0)]
        c.store = store
        return c
    }

    /// Another Prosper window (Settings, Agent Sessions): created deferred, never ordered in.
    @MainActor private func otherWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    /// The island's panel, never shown or made key: set only after expanding, so makeKey never sees it.
    @MainActor private func islandPanel() -> AgentIslandPanel {
        AgentIslandPanel(contentRect: NSRect(x: 600, y: 900, width: 312, height: 82),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    }

    @MainActor private func post(_ c: AgentIslandController, _ name: Notification.Name, _ object: Any? = nil) {
        c.center.post(name: name, object: object)
        let hop = expectation(description: "main")
        DispatchQueue.main.async { hop.fulfill() }
        wait(for: [hop], timeout: 5)
    }

    // MARK: - The close causes

    @MainActor func testAMouseDownInAnotherProsperWindowCloses() throws {
        let m = Monitors(), c = controller(m)
        c.setExpanded(true)
        let click = try XCTUnwrap(m.onOwnClick)
        click(otherWindow(), NSPoint(x: 150, y: 150))
        XCTAssertEqual(c.store?.expanded, false)
    }

    @MainActor func testAnotherProsperWindowTakingKeyCloses() {
        let m = Monitors(), c = controller(m)
        c.setExpanded(true)
        post(c, NSWindow.didBecomeKeyNotification, otherWindow())
        XCTAssertEqual(c.store?.expanded, false)
    }

    @MainActor func testTheFormerKeyWindowResigningKeepsItOpen() {
        // Expanding makes the panel key: the window that had key resigns, and that is not a turn away.
        let m = Monitors(), c = controller(m)
        c.setExpanded(true)
        post(c, NSWindow.didResignKeyNotification, otherWindow())
        post(c, NSWindow.didBecomeKeyNotification, nil)   // no window named: nothing to turn to
        XCTAssertEqual(c.store?.expanded, true)
    }

    // MARK: - What never closes it

    @MainActor func testTheIslandsOwnClicksAndKeyKeepItOpen() throws {
        let m = Monitors(), c = controller(m)
        c.setExpanded(true)
        let panel = islandPanel()
        c.panel = panel
        let click = try XCTUnwrap(m.onOwnClick)
        click(panel, NSPoint(x: 700, y: 940))                   // a row, a card's answer, the composer
        click(otherWindow(), NSPoint(x: 610, y: 905))           // a see-through corner over the window below
        click(nil, NSPoint(x: 10, y: 10))                       // no window of ours under it
        post(c, NSWindow.didBecomeKeyNotification, panel)       // the panel taking key (its own makeKey)
        XCTAssertEqual(c.store?.expanded, true)
        click(otherWindow(), NSPoint(x: 150, y: 150))           // outside the frame, in another window
        XCTAssertEqual(c.store?.expanded, false)
    }

    @MainActor func testNothingNewClosesItWhileAMenuTracks() throws {
        let m = Monitors(), c = controller(m)
        c.setExpanded(true)
        let click = try XCTUnwrap(m.onOwnClick)
        post(c, NSMenu.didEndTrackingNotification)   // an end with no begin since expand: stays at 0
        XCTAssertEqual(c.menusTracking, 0)
        post(c, NSMenu.didBeginTrackingNotification)   // the "⋯" menu
        post(c, NSMenu.didBeginTrackingNotification)   // its New session submenu
        XCTAssertEqual(c.menusTracking, 2)
        click(otherWindow(), NSPoint(x: 150, y: 150))
        post(c, NSWindow.didBecomeKeyNotification, otherWindow())
        post(c, NSMenu.didEndTrackingNotification)
        click(otherWindow(), NSPoint(x: 150, y: 150))
        XCTAssertEqual(c.store?.expanded, true, "a menu still tracks")
        post(c, NSMenu.didEndTrackingNotification)
        XCTAssertEqual(c.menusTracking, 0)
        click(otherWindow(), NSPoint(x: 150, y: 150))
        XCTAssertEqual(c.store?.expanded, false)
    }

    @MainActor func testAMenuActionThatCollapsesLeavesNoCountForTheNextExpansion() throws {
        // The "⋯" menu's Agent Sessions or Choose folder, a row menu's Stop: the island collapses while the
        // menu still tracks, so its didEndTracking finds no observer.
        let m = Monitors(), c = controller(m)
        c.setExpanded(true)
        post(c, NSMenu.didBeginTrackingNotification)
        XCTAssertEqual(c.menusTracking, 1)
        c.setExpanded(false)
        c.setExpanded(true)
        XCTAssertEqual(c.menusTracking, 0)
        try XCTUnwrap(m.onOwnClick)(otherWindow(), NSPoint(x: 150, y: 150))
        XCTAssertEqual(c.store?.expanded, false)
    }

    @MainActor func testAKeyChangeKeepsAnUnsentDraftButAClickClosesAndDropsIt() throws {
        let m = Monitors(), c = controller(m)
        c.setExpanded(true)
        c.store?.messageDraft = "half a thought"
        post(c, NSWindow.didBecomeKeyNotification, otherWindow())
        XCTAssertEqual(c.store?.expanded, true)
        XCTAssertEqual(c.store?.messageDraft, "half a thought")
        try XCTUnwrap(m.onOwnClick)(otherWindow(), NSPoint(x: 150, y: 150))
        XCTAssertEqual(c.store?.expanded, false)
        XCTAssertTrue(c.store?.messageDraft == nil, "584: closing the island drops the draft")
    }

    @MainActor func testOnlyMouseDownsAreMonitored() {
        // A drag that started inside the panel sends dragged and up events, never a second down.
        XCTAssertEqual(AgentIslandController.clickMask, [.leftMouseDown, .rightMouseDown])
    }

    @MainActor func testTheLocalMonitorBlockHandsTheEventOnUnchanged() throws {
        let m = Monitors(), c = controller(m)
        c.setExpanded(true)
        let block = AgentIslandController.passThrough { w, p in
            m.seen.append("\(w == nil) \(p == nil)")
            c.turnedAway(to: w, at: p)
        }
        let e = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                                                 clickCount: 1, pressure: 1))
        XCTAssertTrue(block(e) === e, "the click goes on to the window it was meant for")
        XCTAssertEqual(m.seen, ["true true"])
        XCTAssertEqual(c.store?.expanded, true)
    }

    // MARK: - Teardown

    @MainActor func testEveryMonitorAndObserverIsRemovedOnCollapseAndTeardown() {
        let m = Monitors(), c = controller(m)
        addTeardownBlock { @MainActor in c.extLive = false; c.reload() }
        for round in 1...2 {
            c.setExpanded(true)
            XCTAssertEqual(c.focusObservers.count, 3)
            XCTAssertTrue(c.ownClick != nil)
            c.setExpanded(false)
            XCTAssertEqual(m.removed, (1...round).flatMap { ["global-\($0)", "local-\($0)"] })
            XCTAssertTrue(c.ownClick == nil && c.outsideClick == nil)
            XCTAssertEqual(c.focusObservers.count, 0)
        }
        XCTAssertEqual(m.global, 2)
        XCTAssertEqual(m.local, 2)
        post(c, NSMenu.didBeginTrackingNotification)   // no observer is left to count it
        XCTAssertEqual(c.menusTracking, 0)
        c.setExpanded(true)
        c.extLive = false
        c.reload()   // teardown removes what the open island holds
        XCTAssertEqual(m.removed.suffix(2), ["global-3", "local-3"])
        XCTAssertTrue(c.ownClick == nil && c.outsideClick == nil)
        XCTAssertEqual(c.focusObservers.count, 0)
        XCTAssertEqual(m.removed.count, 6)
    }
}
