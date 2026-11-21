import AppKit
import XCTest
@testable import ProsperApp

/// #1829: every DockPolicy-tracked show path goes through `DockPolicy.present` (registered before the order front, a refused
/// activation re-asserted). Never on screen: DockPolicy's fakes record the order front, nothing is activated.
@MainActor
final class TrackedWindowPresentTests: XCTestCase {
    private var orders: [Bool] = []

    private func fakeDock() {
        let showDockIcon = Preferences.showDockIcon
        Preferences.showDockIcon = true
        orders = []
        DockPolicy.resetForTesting(setPolicy: { _ in }, order: { [unowned self] in self.orders.append(DockPolicy.isShown($0)) },
                                   isActive: { true }, frontmostPid: { nil }, reactivate: {}, after: { _, _ in })
        addTeardownBlock { @MainActor in Preferences.showDockIcon = showDockIcon; DockPolicy.resetForTesting() }
    }

    func testSettingsDefaultPresentRegistersThenOrders() {
        fakeDock()
        let probe = NSWindow()
        SettingsWindow().present(probe)
        XCTAssertEqual(orders, [true])
        DockPolicy.windowDidHide(probe)
    }

    func testTextViewerDefaultPresentRegistersThenOrders() {
        fakeDock()
        let probe = NSWindow()
        TextViewerWindows().present(probe)
        XCTAssertEqual(orders, [true])
        DockPolicy.windowDidHide(probe)
    }

    func testExtensionViewDefaultOnScreenRegistersThenOrders() {
        fakeDock()
        let probe = NSWindow()
        ExtensionViewPanel().onScreen(probe)
        XCTAssertEqual(orders, [true])
        DockPolicy.windowDidHide(probe)
    }

    /// The paths a row cannot reach without ordering a real window or loading a model (Clipboard, Chat, Marketplace,
    /// ModelSetup) are held by the source: no tracked show path pairs windowDidShow with its own activate.
    func testNoTrackedShowPathActivatesInline() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp")
        for f in ["Clipboard/ClipboardPanel.swift", "SettingsWindow.swift", "ChatWindow.swift", "MarketplaceWindow.swift",
                  "TextViewer/TextViewerWindow.swift", "Extensions/ExtensionViewRenderer.swift", "ModelSetup.swift"] {
            let text = try String(contentsOf: src.appendingPathComponent(f), encoding: .utf8)
            XCTAssertTrue(text.contains("DockPolicy.present("), "\(f) shows through DockPolicy.present")
            XCTAssertFalse(text.contains("DockPolicy.windowDidShow("), "\(f) registers only inside present")
        }
    }
}

/// #1829 (QA R1821 INFO b): the self-open never starts a staged newer copy. The route only; the live open is never called.
@MainActor
final class DockPolicyReactivateRouteTests: XCTestCase {
    private func route(_ running: String?, _ disk: String?) -> String {
        var hit = ""
        DockPolicy.reactivateRoute(versions: { (running, disk) }, openSelf: { hit += "open" }, activateCurrent: { hit += "activate" })
        return hit
    }

    func testSameVersionOnDiskSelfOpens() { XCTAssertEqual(route("43", "43"), "open") }
    func testStagedVersionOnlyActivatesThisProcess() { XCTAssertEqual(route("43", "44"), "activate") }
    func testUnreadableDiskVersionOnlyActivatesThisProcess() {
        XCTAssertEqual(route("43", nil), "activate")
        XCTAssertEqual(route(nil, nil), "activate")
    }
}
