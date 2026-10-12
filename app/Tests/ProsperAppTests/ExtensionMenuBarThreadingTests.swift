import XCTest
import AppKit
@testable import ProsperApp

/// #199: extension menubar calls arrive on the Lua runtime thread. The host
/// services boundary must hop to main before touching NSStatusItem / NSMenu.
/// `ExtensionMenuBar.set/remove` assert `Thread.isMainThread` in debug builds,
/// so an item that shows up (or goes away) here was mutated on main.
final class ExtensionMenuBarThreadingTests: XCTestCase {

    @MainActor
    func testMenubarCallsFromBackgroundThreadLandOnMain() async throws {
        let extID = "test.threading.\(UUID().uuidString)"
        // QA OQ-6: a private bar, restored after removeAll (defers run in reverse).
        let savedBar = ExtensionMenuBar.shared.statusBar
        ExtensionMenuBar.shared.statusBar = NSStatusBar()
        defer { ExtensionMenuBar.shared.statusBar = savedBar }
        defer { ExtensionMenuBar.shared.removeAll(extensionID: extID) }
        let services = LiveExtensionHostServices.shared
        let json = #"{"title":"T","menu":[{"title":"A","handler":"h"},{"separator":true}]}"#

        await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            services.menubarSet(extensionID: extID, id: "x", json: json)
        }.value
        let added = await waitFor { self.ownsItem(extID) }
        XCTAssertTrue(added, "menubarSet from a background thread never reached main")
        let item = try XCTUnwrap(ExtensionMenuBar.shared.items.first { $0.key.hasPrefix(extID) }?.value)
        XCTAssertEqual(item.menu?.items.count, 2)
        XCTAssertFalse(item.statusBar === NSStatusBar.system, "extension item landed on the system bar")
        XCTAssertEqual(item.autosaveName, ExtensionMenuBar.autosaveName(extensionID: extID, id: "x"))

        await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            services.menubarRemove(extensionID: extID, id: "x")
        }.value
        let removed = await waitFor { !self.ownsItem(extID) }
        XCTAssertTrue(removed, "menubarRemove from a background thread never reached main")
    }

    /// #364: the separator sits outside the cleaned charset, so dotted parts cannot collide.
    func testAutosaveNameSeparatorIsUnambiguousAndCleans() {
        XCTAssertNotEqual(ExtensionMenuBar.autosaveName(extensionID: "com.x", id: "ext.main"),
                          ExtensionMenuBar.autosaveName(extensionID: "com.x.ext", id: "main"))
        XCTAssertEqual(ExtensionMenuBar.autosaveName(extensionID: "com.x", id: "a b/c"), "ProsperExt:com.x:a_b_c")
    }

    /// #295: a scalar payload passes isValidJSONObject([value]) and must serialize as a
    /// JSON fragment, not raise NSInvalidArgumentException.
    @MainActor
    func testEncodeScalarPayloadReturnsJSONFragment() {
        XCTAssertEqual(ExtensionMenuBar.encode("hi"), #""hi""#)
        XCTAssertEqual(ExtensionMenuBar.encode(42), "42")
        XCTAssertEqual(ExtensionMenuBar.encode(nil), "{}")
    }

    @MainActor
    private func ownsItem(_ extID: String) -> Bool {
        ExtensionMenuBar.shared.items.keys.contains { $0.hasPrefix(extID) }
    }

    @MainActor
    private func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
