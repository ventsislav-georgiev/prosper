import AppKit
import XCTest
@testable import ProsperApp

/// #1821 (operator 2026-11-21, beta.43: typing stopped reaching every session after a quick open/close of the window):
/// every show path of the Agent Sessions window goes through `present`, and the default `present` registers the window
/// with DockPolicy before it is ordered front. Never on screen: the rig's recorders and DockPolicy's fakes.
extension AgentWindowD1Tests {
    @MainActor
    func testWindowEveryShowPathGoesThroughTheRegisteringPresent() throws {
        let r = HideRig(store([session("api", .working, ago: 30)]))
        let w = r.w
        addTeardownBlock { @MainActor in w.window?.close(); w.grace?.fire() }
        w.show()                                   // the fresh build
        let win = try XCTUnwrap(w.window)
        XCTAssertEqual(r.presented, 1)
        win.close()                                // the close hides it (#1784) and lets the Dock go
        XCTAssertEqual(r.dismissed, 1)
        w.show()                                   // the reopen inside the grace: the kept window
        XCTAssertEqual(r.presented, 2, "a kept window comes back through present too")
        // A window never put on screen gets no second willClose from AppKit: the close's notification, as #1784's row.
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: win)
        try XCTUnwrap(w.grace).fire()              // past the grace: the teardown
        XCTAssertTrue(w.window == nil)
        w.show()                                   // the rebuild after the teardown
        XCTAssertEqual(r.presented, 3)
        XCTAssertEqual(r.dismissed, 2)

        // The default present: DockPolicy registers the window, then orders it front.
        var orders: [Bool] = []
        let showDockIcon = Preferences.showDockIcon
        Preferences.showDockIcon = true
        DockPolicy.resetForTesting(setPolicy: { _ in }, order: { orders.append(DockPolicy.isShown($0)) },
                                   isActive: { true }, frontmostPid: { nil }, reactivate: {}, after: { _, _ in })
        defer { Preferences.showDockIcon = showDockIcon; DockPolicy.resetForTesting() }
        let probe = NSWindow()
        AgentsWindow().present(probe)
        XCTAssertEqual(orders, [true], "registered before the order front")
        DockPolicy.windowDidHide(probe)
    }
}
