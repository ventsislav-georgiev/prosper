import XCTest
import SwiftUI
@testable import ProsperApp

final class SettingsFocusRouterTests: XCTestCase {

    @MainActor
    private func freshRouter() -> SettingsFocusRouter {
        // Singleton shared with the rest of the suite — drain whatever is pending.
        let router = SettingsFocusRouter.shared
        router.request(SettingsAnchor(pane: "__drain", section: "__drain"))
        _ = router.take(pane: "__drain")
        return router
    }

    @MainActor
    func testRequestIsHeldUntilTheMatchingPaneAsksForIt() {
        let router = freshRouter()
        let anchor = SettingsAnchor(pane: "audio-mixer", section: "Output")
        router.request(anchor)

        // The pane that is on screen when the request lands is NOT the target — its
        // NeonScroll must leave the request alone (this is the "window is open on
        // General, user picks a mixer result" path).
        XCTAssertNil(router.take(pane: "general"))
        XCTAssertEqual(router.pending, anchor)

        // ...and the pane mounting later still gets it. This is the first-click fix:
        // the request outlives the pane switch.
        XCTAssertEqual(router.take(pane: "audio-mixer")?.anchor, anchor)
        XCTAssertNil(router.pending)
        // Consumed exactly once — a second NeonScroll appearing must not re-scroll.
        XCTAssertNil(router.take(pane: "audio-mixer"))
    }

    /// #078 round 4: `request` defaults to `.top` (unchanged jump-to-section
    /// behavior — always land at the top, even if the target was visible), but
    /// a caller doing minimal-movement navigation (arrow-key theme select) can
    /// override it to `nil`, and `take` hands that choice back alongside the
    /// anchor so `NeonScroll.consume` can pass it straight to `scrollTo`.
    @MainActor
    func testScrollAnchorDefaultsToTopButIsOverridable() throws {
        let router = freshRouter()
        let anchor = SettingsAnchor(pane: "appearance", section: "theme-row:t.amber")

        router.request(anchor)
        let defaulted = try XCTUnwrap(router.take(pane: "appearance"))
        XCTAssertEqual(defaulted.scrollAnchor, .top)

        router.request(anchor, scrollAnchor: nil)
        let overridden = try XCTUnwrap(router.take(pane: "appearance"))
        XCTAssertNil(overridden.scrollAnchor, "minimal-movement requests must not force a `.top` alignment")
    }

    @MainActor
    func testAnchorlessPaneIDsNeverMatch() {
        let router = freshRouter()
        router.request(SettingsAnchor(pane: "general", section: "Clipboard"))
        // Outside the settings window `settingsPaneID` is "" — must not swallow it.
        XCTAssertNil(router.take(pane: ""))
        XCTAssertNotNil(router.pending)
        _ = router.take(pane: "general")
    }

    @MainActor
    func testHighlightIsClearedByTheNextRequest() {
        let router = freshRouter()
        let first = SettingsAnchor(pane: "general", section: "Clipboard")
        _ = router.take(pane: "general")
        router.highlight(first)
        XCTAssertEqual(router.focused, first)

        router.request(SettingsAnchor(pane: "shortcuts", section: "Hotkeys"))
        XCTAssertNil(router.focused, "a new jump must not leave the old section glowing")
        _ = router.take(pane: "shortcuts")
    }

    @MainActor
    func testHighlightFadesOut() async throws {
        let router = freshRouter()
        let anchor = SettingsAnchor(pane: "general", section: "Clipboard")
        router.highlight(anchor, seconds: 0.05)
        XCTAssertEqual(router.focused, anchor)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(router.focused)
    }

    /// `host.settings.open(sectionID, anchor)` must select the pane AND post the
    /// section, so the deep link lands on the row instead of the top of the pane.
    @MainActor
    func testHostSettingsOpenPostsTheAnchor() {
        let router = freshRouter()
        let services = LiveExtensionHostServices.shared
        let previous = services.settingsOpener
        defer { services.settingsOpener = previous }

        var opened: String?
        services.settingsOpener = { opened = $0 }
        services.openSettings(extensionID: "com.test.ext", sectionID: "main", anchor: "Sounds")

        XCTAssertEqual(opened, "ext:com.test.ext|main")
        XCTAssertEqual(router.pending,
                       SettingsAnchor(pane: "ext:com.test.ext|main", section: "Sounds"))
        _ = router.take(pane: "ext:com.test.ext|main")
    }

    @MainActor
    func testHostSettingsOpenWithoutAnchorPostsNothing() {
        let router = freshRouter()
        let services = LiveExtensionHostServices.shared
        let previous = services.settingsOpener
        defer { services.settingsOpener = previous }

        var opened: String?
        services.settingsOpener = { opened = $0 }
        services.openSettings(extensionID: "com.test.ext", sectionID: "main", anchor: nil)

        XCTAssertEqual(opened, "ext:com.test.ext|main")
        XCTAssertNil(router.pending)
    }
}
