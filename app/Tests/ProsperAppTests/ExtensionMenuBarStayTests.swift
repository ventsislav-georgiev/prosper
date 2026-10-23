import XCTest
import AppKit
import ObjectiveC
@testable import ProsperApp

/// #482: host.menubar rows honour `enabled`, rows with no handler are inert, and
/// `stay` rows run their handler without ending menu tracking while `set` refills
/// the open menu in place. In-process only: a private NSStatusBar, no real menu,
/// no tracking session, no posted events.
@MainActor
final class ExtensionMenuBarStayTests: XCTestCase {

    private let bar = ExtensionMenuBar.shared
    private var extID = ""
    private var savedBar: NSStatusBar?
    private var savedInvoke: ((String, String, String) -> Void)?
    private var calls: [String] = []
    private var shown: [String] = []
    private var routed: [String] = []
    /// L-3: set while a main-queue hop of this test may still land; tearDown then keeps
    /// the private bar installed, so a late job can never reach NSStatusBar.system.
    private var hopPending = false

    override func setUp() async throws {
        extID = "test.stay.\(UUID().uuidString)"
        savedBar = bar.statusBar
        savedInvoke = bar.invoke
        bar.statusBar = NSStatusBar()
        bar.invoke = { [weak self] _, handler, payload in self?.calls.append("\(handler) \(payload)") }
    }

    override func tearDown() async throws {
        bar.removeAll(extensionID: extID)
        if let savedBar, !hopPending { bar.statusBar = savedBar }
        bar.invoke = savedInvoke
    }

    private func set(_ menu: String) -> NSMenu? {
        bar.set(extensionID: extID, id: "main", json: #"{"title":"T","menu":\#(menu)}"#)
        return bar.items.first { $0.key.hasPrefix(extID) }?.value.menu
    }

    private func mouseUp() -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
    }

    func testEnabledFalseAndMissingHandlerAreDisabled() throws {
        let menu = try XCTUnwrap(set(#"""
            [{"title":"Status","handler":"h","enabled":false},{"title":"Info"},
             {"title":"Go","handler":"h"},{"title":"Empty","handler":""}]
            """#))
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(menu.items.map(\.isEnabled), [false, false, true, false])
        menu.update() // an autoenabling menu would re-enable every row here
        XCTAssertEqual(menu.items.map(\.isEnabled), [false, false, true, false])
    }

    /// G4: unflagged and stay:false rows stay plain items, their click goes through
    /// AppKit's action path (which ends tracking) and runs the handler as before.
    func testUnflaggedRowIsPlainItem() throws {
        let menu = try XCTUnwrap(set(#"[{"title":"A","handler":"a","payload":{"n":1}},{"title":"B","handler":"b","stay":false}]"#))
        XCTAssertTrue(menu.items.allSatisfy { $0.view == nil })
        menu.performActionForItem(at: 0)
        menu.performActionForItem(at: 1)
        XCTAssertEqual(calls, [#"a {"n":1}"#, "b {}"])
    }

    /// G4/G5: a stay row runs its handler on click, on VoiceOver press, and on Return
    /// (AppKit's action path), and only the action path may end tracking.
    func testStayRowRunsHandlerWithoutEndingTracking() throws {
        let menu = try XCTUnwrap(set(#"[{"title":"Keep awake","handler":"on","payload":{"secs":60},"stay":true}]"#))
        let item = try XCTUnwrap(menu.items.first)
        let view = try XCTUnwrap(item.view)
        XCTAssertEqual(view.frame.height, 24, "native row height (NSMenu.size: 24 pt per row)")
        XCTAssertEqual(view.accessibilityRole(), .menuItem)
        XCTAssertEqual(view.accessibilityTitle(), "Keep awake")
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertTrue(view.isAccessibilityEnabled())

        CancelTrackingSpy.install()
        defer { CancelTrackingSpy.uninstall() }
        view.mouseUp(with: mouseUp())
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(CancelTrackingSpy.count, 0, "a stay row ended menu tracking")
        menu.performActionForItem(at: 0) // Return on the highlighted row
        XCTAssertEqual(calls, Array(repeating: #"on {"secs":60}"#, count: 3))
    }

    func testDisabledStayRowIgnoresClick() throws {
        let menu = try XCTUnwrap(set(#"[{"title":"X","handler":"h","stay":true,"enabled":false}]"#))
        let view = try XCTUnwrap(menu.items.first?.view)
        view.mouseUp(with: mouseUp())
        XCTAssertFalse(view.isAccessibilityEnabled())
        XCTAssertFalse(view.accessibilityPerformPress(), "VoiceOver press reported success on a dimmed row")
        XCTAssertTrue(calls.isEmpty)
    }

    /// The open menu is the instance AppKit tracks, so a re-render must refill it.
    func testSetRefillsTheSameMenuInPlace() throws {
        let first = try XCTUnwrap(set(#"[{"title":"Off"},{"title":"Turn on","handler":"on","stay":true},{"title":"For 1 hour","handler":"on","stay":true}]"#))
        let second = try XCTUnwrap(set(#"[{"title":"On"},{"title":"Turn off","handler":"off","stay":true},{"separator":true},{"title":"Settings","handler":"s"}]"#))
        XCTAssertTrue(first === second, "set replaced the NSMenu")
        XCTAssertEqual(second.items.map(\.title), ["On", "Turn off", "", "Settings"])
        XCTAssertNotNil(second.items[1].view)
        XCTAssertNil(second.items[3].view)
        XCTAssertNil(set("[]"), "an empty menu still clears it")
    }

    /// G3: the re-render hops to main as a MainActor job. It must land while the run
    /// loop sits in .eventTracking (an open menu), not wait for the default mode.
    /// Synchronous, so the spin below is not itself nested inside a main-queue job.
    func testRerenderLandsWhileRunLoopTracksMenu() {
        _ = set(#"[{"title":"Old","handler":"h"}]"#)
        let services = LiveExtensionHostServices.shared
        let id = extID
        hopPending = true
        DispatchQueue.global().async {
            services.menubarSet(extensionID: id, id: "main", json: #"{"title":"T","menu":[{"title":"New","handler":"h"}]}"#)
        }
        let deadline = Date().addingTimeInterval(2)
        while bar.items.first(where: { $0.key.hasPrefix(extID) })?.value.menu?.items.first?.title != "New",
              Date() < deadline {
            RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(bar.items.first { $0.key.hasPrefix(extID) }?.value.menu?.items.first?.title, "New")
        hopPending = bar.items.first { $0.key.hasPrefix(extID) }?.value.menu?.items.first?.title != "New"
    }

    // MARK: - Round 2 (QA #306)

    /// L-1: after a re-render the old view still reaches its detached item (menu nil);
    /// a press on it (a cached VoiceOver element) must not run the old handler.
    func testStaleStayViewAfterRerenderIsInert() throws {
        let menu = try XCTUnwrap(set(#"[{"title":"Turn on","handler":"on","stay":true}]"#))
        let stale = try XCTUnwrap(menu.items.first?.view)
        _ = set(#"[{"title":"Turn off","handler":"off","stay":true}]"#)
        XCTAssertNotNil(stale.enclosingMenuItem, "precondition: the detached item is still reachable")
        stale.mouseUp(with: mouseUp())
        XCTAssertFalse(stale.accessibilityPerformPress())
        XCTAssertTrue(calls.isEmpty, "a stale stay view ran a handler")
    }

    /// INFO: only JSON booleans count; Lua's 1 and 0 (both truthy there) change nothing.
    func testOnlyBooleansSetStayAndEnabled() throws {
        let menu = try XCTUnwrap(set(#"[{"title":"A","handler":"h","stay":1,"enabled":0},{"title":"B","handler":"h","stay":true,"enabled":true}]"#))
        XCTAssertEqual(menu.items.map(\.isEnabled), [true, true])
        XCTAssertEqual(menu.items.map { $0.view != nil }, [false, true])
    }

    /// MEDIUM-1: a stay row (OpenLid "Keep Mac awake") can reach the helper-approval
    /// modal with its menu open. The menu is asked to close and the modal waits for a
    /// default-mode turn: tracking runs in .eventTracking and unwinds only after the
    /// calling job returns, so a modal run in that job would nest inside the menu.
    func testApprovalModalWaitsUntilTheOpenMenuHasClosed() throws {
        let menu = try XCTUnwrap(set(#"[{"title":"Keep Mac awake","handler":"on","stay":true}]"#))
        XCTAssertTrue(menu.delegate === bar)
        let saved = HelperApproval.present
        HelperApproval.lastShown = .distantPast
        HelperApproval.present = { [weak self] in self?.shown.append($0) }
        defer { HelperApproval.present = saved; HelperApproval.lastShown = .distantPast; bar.menuDidClose(menu) }
        bar.menuWillOpen(menu) // what AppKit calls as the status menu opens; no real tracking
        CancelTrackingSpy.install()
        defer { CancelTrackingSpy.uninstall() }

        HelperApproval.presentNeedsApproval(feature: "Lid")
        HelperApproval.presentNeedsApproval(feature: "Fan") // a second caller while the hop is pending
        XCTAssertEqual(CancelTrackingSpy.count, 1, "the open menu was not asked to close")
        pump(.eventTracking, for: 0.3)
        XCTAssertEqual(shown, [], "the modal ran inside the menu's tracking loop")
        pump(.default) { !self.shown.isEmpty }
        XCTAssertEqual(shown, ["Lid"])
        pump(.default, for: 0.1) // room for a second hop, if "Fan" had scheduled one
        XCTAssertEqual(shown, ["Lid"], "two callers, one modal")
    }

    /// With no extension menu open (closed again, or never opened) the modal shows at once.
    func testApprovalModalPresentsAtOnceWithNoMenuOpen() throws {
        let menu = try XCTUnwrap(set(#"[{"title":"Keep Mac awake","handler":"on","stay":true}]"#))
        let saved = HelperApproval.present
        HelperApproval.lastShown = .distantPast
        HelperApproval.present = { [weak self] in self?.shown.append($0) }
        defer { HelperApproval.present = saved; HelperApproval.lastShown = .distantPast }
        bar.menuWillOpen(menu)
        bar.menuDidClose(menu)
        CancelTrackingSpy.install()
        defer { CancelTrackingSpy.uninstall() }
        HelperApproval.presentNeedsApproval(feature: "Fan")
        XCTAssertEqual(shown, ["Fan"])
        XCTAssertEqual(CancelTrackingSpy.count, 0)
    }

    /// L-4: the app wires clicks through `route` (AppDelegate); the hop to the
    /// extension runtime must land while the run loop tracks the menu.
    func testRoutedClickLandsWhileRunLoopTracksMenu() throws {
        bar.route { [weak self] _, handler, payload in self?.routed.append("\(handler) \(payload)") }
        let menu = try XCTUnwrap(set(#"[{"title":"Keep awake","handler":"on","payload":{"secs":60},"stay":true}]"#))
        try XCTUnwrap(menu.items.first?.view).mouseUp(with: mouseUp())
        XCTAssertEqual(routed, [], "route delivered synchronously, not as a hop")
        pump(.eventTracking) { !self.routed.isEmpty }
        XCTAssertEqual(routed, [#"on {"secs":60}"#])
    }

    private func pump(_ mode: RunLoop.Mode, for seconds: TimeInterval = 2, until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.current.run(mode: mode, before: Date().addingTimeInterval(0.02))
        }
    }
}

/// Counts NSMenu.cancelTracking / cancelTrackingWithoutAnimation calls while installed.
@MainActor
private enum CancelTrackingSpy {
    static var count = 0
    private static let pairs: [(Selector, Selector)] = [
        (#selector(NSMenu.cancelTracking), #selector(NSMenu.spy_cancelTracking)),
        (#selector(NSMenu.cancelTrackingWithoutAnimation), #selector(NSMenu.spy_cancelTrackingWithoutAnimation)),
    ]
    static func install() { count = 0; swap() }
    static func uninstall() { swap() }
    private static func swap() {
        for (a, b) in pairs {
            method_exchangeImplementations(class_getInstanceMethod(NSMenu.self, a)!,
                                           class_getInstanceMethod(NSMenu.self, b)!)
        }
    }
}

private extension NSMenu {
    @objc func spy_cancelTracking() { MainActor.assumeIsolated { CancelTrackingSpy.count += 1 } }
    @objc func spy_cancelTrackingWithoutAnimation() { MainActor.assumeIsolated { CancelTrackingSpy.count += 1 } }
}
