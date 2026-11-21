import XCTest
@testable import ProsperApp

final class DockPolicyTests: XCTestCase {
    @MainActor
    func testRapidHideShowCancelsDemotionAndFinalHideDemotes() async throws {
        let originalShowDockIcon = Preferences.showDockIcon
        var policies: [NSApplication.ActivationPolicy] = []
        var currentPolicy: NSApplication.ActivationPolicy = .accessory
        Preferences.showDockIcon = true
        DockPolicy.resetForTesting(demotionDelay: 1.0, setPolicy: { target in
            guard currentPolicy != target else { return }
            currentPolicy = target
            policies.append(target)
        })
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

    // MARK: - #1821 (operator 2026-11-21, beta.43: typing stopped after quick open/close of Agent Sessions)

    /// A rig with every live effect faked: the policy, the order front, the activation probes, the re-assertion and
    /// the settle scheduler (its blocks are kept for the row to run). Nothing is activated or ordered front.
    @MainActor
    final class Rig {
        var policies: [NSApplication.ActivationPolicy] = []
        var current: NSApplication.ActivationPolicy = .accessory
        var orders: [(shown: Bool, policy: NSApplication.ActivationPolicy)] = []
        var active = false
        var front: pid_t? = 4242
        var reactivations = 0
        var settles: [(TimeInterval, @MainActor () -> Void)] = []
        let showDockIcon = Preferences.showDockIcon
        init(demotionDelay: TimeInterval = DockPolicy.defaultDemotionDelay) {
            Preferences.showDockIcon = true
            DockPolicy.resetForTesting(
                demotionDelay: demotionDelay,
                setPolicy: { [unowned self] t in
                    guard current != t else { return }
                    current = t
                    policies.append(t)
                },
                order: { [unowned self] w in orders.append((DockPolicy.isShown(w), current)) },
                isActive: { [unowned self] in active },
                frontmostPid: { [unowned self] in front },
                reactivate: { [unowned self] in reactivations += 1 },
                after: { [unowned self] d, f in settles.append((d, f)) })
        }
        func done() {
            Preferences.showDockIcon = showDockIcon
            DockPolicy.resetForTesting()
        }
    }

    /// The Dock's demotion (TransformProcessType => accessory, pickNew=1: front handed to another app) never lands
    /// when the window comes back inside the delay: the policy stays `.regular` while it is shown.
    @MainActor
    func testCloseThenReopenWithinTheDelayNeverFlipsToAccessory() async throws {
        let r = Rig(demotionDelay: 1.0)   // 1 s: the CI margin of the row above
        defer { r.done() }
        let w = NSWindow()
        DockPolicy.present(w)
        DockPolicy.windowDidHide(w)
        try await Task.sleep(for: .milliseconds(100))
        DockPolicy.present(w)
        try await Task.sleep(for: .milliseconds(1500))   // past the first hide's delay
        XCTAssertEqual(r.policies, [.regular], "no accessory flip, so nothing hands front away")
        XCTAssertEqual(r.current, .regular)
        XCTAssertTrue(DockPolicy.isShown(w))
    }

    /// Every show through `present` registers (and flips to `.regular`) before the window is activated and ordered front.
    @MainActor
    func testPresentRegistersBeforeOrderingFront() {
        let r = Rig()
        defer { r.done() }
        let w = NSWindow()
        DockPolicy.present(w)
        XCTAssertEqual(r.orders.count, 1)
        XCTAssertEqual(r.orders.first?.shown, true, "registered before the order front")
        XCTAssertEqual(r.orders.first?.policy, .regular, "the flip lands before the activation")
    }

    /// The beta.43 log: the reopen's activation refused (still inactive, the same other app in front after the settle,
    /// the window shown) is re-asserted exactly once; one settle check per show.
    @MainActor
    func testRefusedActivationIsReassertedOnceAfterTheSettle() throws {
        let r = Rig()
        defer { r.done() }
        let w = NSWindow()
        DockPolicy.present(w)
        XCTAssertEqual(r.reactivations, 0, "not before the settle")
        XCTAssertEqual(r.settles.count, 1, "one check per show")
        XCTAssertEqual(r.settles.first?.0, DockPolicy.activationSettle)
        try XCTUnwrap(r.settles.first).1()
        XCTAssertEqual(r.reactivations, 1)
    }

    /// No re-assertion when the activation landed, when the person went to a third app meanwhile, when the window was
    /// closed meanwhile, when there was no front app, or when Prosper itself was in front.
    @MainActor
    func testNoReassertWhenActiveMovedOnClosedOrSelfInFront() throws {
        let r = Rig()
        defer { r.done() }
        let w = NSWindow()
        func run(_ before: () -> Void, _ between: () -> Void) throws {
            before()
            DockPolicy.present(w)
            between()
            try XCTUnwrap(r.settles.last).1()
            DockPolicy.windowDidHide(w)
        }
        try run({ r.active = false; r.front = 4242 }, { r.active = true })
        try run({ r.active = false; r.front = 4242 }, { r.front = 5151 })
        try run({ r.active = false; r.front = 4242 }, { DockPolicy.windowDidHide(w) })
        try run({ r.active = false; r.front = nil }, {})
        try run({ r.active = false; r.front = getpid() }, {})
        XCTAssertEqual(r.settles.count, 5)
        XCTAssertEqual(r.reactivations, 0)
        try run({ r.active = false; r.front = 4242 }, {})
        XCTAssertEqual(r.reactivations, 1, "the same rig re-asserts a refused one")
    }
}
