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

    override func setUp() async throws {
        extID = "test.stay.\(UUID().uuidString)"
        savedBar = bar.statusBar
        savedInvoke = bar.invoke
        bar.statusBar = NSStatusBar()
        bar.invoke = { [weak self] _, handler, payload in self?.calls.append("\(handler) \(payload)") }
    }

    override func tearDown() async throws {
        bar.removeAll(extensionID: extID)
        if let savedBar { bar.statusBar = savedBar }
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
        DispatchQueue.global().async {
            services.menubarSet(extensionID: id, id: "main", json: #"{"title":"T","menu":[{"title":"New","handler":"h"}]}"#)
        }
        let deadline = Date().addingTimeInterval(2)
        while bar.items.first(where: { $0.key.hasPrefix(extID) })?.value.menu?.items.first?.title != "New",
              Date() < deadline {
            RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(bar.items.first { $0.key.hasPrefix(extID) }?.value.menu?.items.first?.title, "New")
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
