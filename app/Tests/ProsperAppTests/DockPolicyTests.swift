import XCTest
@testable import ProsperApp

final class DockPolicyTests: XCTestCase {
    @MainActor
    func testRapidHideShowCancelsDemotionAndFinalHideDemotes() async throws {
        let originalShowDockIcon = Preferences.showDockIcon
        var policies: [NSApplication.ActivationPolicy] = []
        var currentPolicy: NSApplication.ActivationPolicy = .accessory
        Preferences.showDockIcon = true
        DockPolicy.resetForTesting(demotionDelay: 1.0) { target in
            guard currentPolicy != target else { return }
            currentPolicy = target
            policies.append(target)
        }
        defer {
            Preferences.showDockIcon = originalShowDockIcon
            DockPolicy.resetForTesting()
        }

        let window = NSWindow()
        DockPolicy.windowDidShow(window)
        DockPolicy.windowDidHide(window)
        try await Task.sleep(for: .milliseconds(100))
        DockPolicy.windowDidShow(window)
        DockPolicy.windowDidHide(window)
        // 3-vCPU CI runner flaked with 0.2 s delay; 1 s delay keeps 500 ms margins on both asserts.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(policies, [.regular])

        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(policies, [.regular, .accessory])
    }
}
