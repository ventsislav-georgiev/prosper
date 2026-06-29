import XCTest
import CoreGraphics
@testable import ProsperApp

/// Menu-bar manager math. All load-bearing logic (section assignment, spacing key
/// mapping, reorder destination/apply) lives in the AX-free `MenuBarLogic` /
/// `MenuBarStore` so it can be proven here without touching CGS/AppKit. The hot
/// path itself (a single `NSStatusItem.length` write on reveal/hide) is not
/// modelled here — it has no branching to test — but the classification that feeds
/// the Settings list runs over every item and gets a perf budget below.
final class MenuBarTests: XCTestCase {

    // MARK: - Section assignment (positional, the core of hide/reveal)

    // Items lay out right→left from the screen's right edge: visible band sits at
    // the HIGHEST x, always-hidden at the lowest. Dividers split the bands.
    func testSectionRightOfHiddenIsVisible() {
        XCTAssertEqual(
            MenuBarLogic.section(forItemX: 1400, hiddenDividerX: 1000, alwaysHiddenDividerX: 500),
            .visible)
    }

    func testSectionBetweenDividersIsHidden() {
        XCTAssertEqual(
            MenuBarLogic.section(forItemX: 750, hiddenDividerX: 1000, alwaysHiddenDividerX: 500),
            .hidden)
    }

    func testSectionLeftOfAlwaysHiddenIsAlwaysHidden() {
        XCTAssertEqual(
            MenuBarLogic.section(forItemX: 300, hiddenDividerX: 1000, alwaysHiddenDividerX: 500),
            .alwaysHidden)
    }

    func testSectionWithoutAlwaysHiddenDividerCollapsesToTwoBands() {
        // Two-tier disabled: everything left of the hidden divider is just .hidden.
        XCTAssertEqual(
            MenuBarLogic.section(forItemX: 300, hiddenDividerX: 1000, alwaysHiddenDividerX: nil),
            .hidden)
        XCTAssertEqual(
            MenuBarLogic.section(forItemX: 1400, hiddenDividerX: 1000, alwaysHiddenDividerX: nil),
            .visible)
    }

    func testSectionBoundaryIsExclusiveOnTheDivider() {
        // Exactly on the divider x → not strictly greater → falls into hidden band.
        XCTAssertEqual(
            MenuBarLogic.section(forItemX: 1000, hiddenDividerX: 1000, alwaysHiddenDividerX: nil),
            .hidden)
    }

    // MARK: - Divider length state machine (the show/hide hot path's source of truth)

    // Sentinel widths so the mapping is unambiguous (real code passes
    // NSStatusItem.variableLength for standard and a screen-derived expanded width).
    private let std: CGFloat = -1     // variableLength sentinel
    private let exp: CGFloat = 2120   // screen-derived "push off-screen" width

    func testDividerLengthsHiddenState() {
        // Nothing revealed: both dividers expanded (everything left of them pushed off).
        let l = MenuBarLogic.dividerLengths(revealed: false, revealedAlwaysHidden: false,
                                            standard: std, expanded: exp)
        XCTAssertEqual(l.hidden, exp)
        XCTAssertEqual(l.alwaysHidden, exp)
    }

    func testDividerLengthsHiddenRevealed() {
        // Hidden section revealed, always-hidden still tucked away.
        let l = MenuBarLogic.dividerLengths(revealed: true, revealedAlwaysHidden: false,
                                            standard: std, expanded: exp)
        XCTAssertEqual(l.hidden, std)
        XCTAssertEqual(l.alwaysHidden, exp)
    }

    func testDividerLengthsBothRevealed() {
        // Revealing always-hidden implies the hidden section is shown too → both collapse.
        let l = MenuBarLogic.dividerLengths(revealed: true, revealedAlwaysHidden: true,
                                            standard: std, expanded: exp)
        XCTAssertEqual(l.hidden, std)
        XCTAssertEqual(l.alwaysHidden, std)
    }

    func testDividerLengthsAlwaysHiddenRevealedAloneStillCollapsesIt() {
        // Degenerate combo (revealed=false but revealedAlwaysHidden=true) shouldn't
        // strand the always-hidden divider expanded — its band is driven by its own flag.
        let l = MenuBarLogic.dividerLengths(revealed: false, revealedAlwaysHidden: true,
                                            standard: std, expanded: exp)
        XCTAssertEqual(l.alwaysHidden, std)
    }

    // MARK: - Spacing key mapping

    func testSpacingDefaultClearsOverride() {
        // Writing the macOS default (16) must signal "delete the keys", not pin 16.
        XCTAssertNil(MenuBarLogic.spacingDefaultsValue(forSpacing: MenuBarSpacing.defaultSpacing))
    }

    func testSpacingNonDefaultReturnsValue() {
        XCTAssertEqual(MenuBarLogic.spacingDefaultsValue(forSpacing: 4), 4)
        XCTAssertEqual(MenuBarLogic.spacingDefaultsValue(forSpacing: 0), 0)
    }

    func testSpacingClampsToBounds() {
        XCTAssertEqual(MenuBarLogic.spacingDefaultsValue(forSpacing: -10), MenuBarSpacing.minSpacing)
        XCTAssertEqual(MenuBarLogic.spacingDefaultsValue(forSpacing: 999), MenuBarSpacing.maxSpacing)
    }

    // MARK: - Store: clamping + Codable round-trip + schema downgrade-safety

    func testStoreClamps() {
        var s = MenuBarStore.default
        s.spacing = 500
        s.autoRehideSeconds = 9000
        XCTAssertEqual(s.clampedSpacing, MenuBarSpacing.maxSpacing)
        XCTAssertEqual(s.clampedAutoRehide, 30)
        s.spacing = -5
        s.autoRehideSeconds = 0
        XCTAssertEqual(s.clampedSpacing, MenuBarSpacing.minSpacing)
        XCTAssertEqual(s.clampedAutoRehide, 1)
    }

    func testStoreRoundTrips() throws {
        var s = MenuBarStore.default
        s.spacing = 8
        s.alwaysHiddenEnabled = true
        s.autoRehideSeconds = 12
        s.chevronStyle = .circle
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(MenuBarStore.self, from: data)
        XCTAssertEqual(s, back)
    }

    func testStoreDecodesFromMinimalJSON() throws {
        // A future/old build that wrote only schemaVersion must decode with every
        // other field defaulted (downgrade-safe, mirrors layoutStore behavior).
        let json = #"{"schemaVersion":1}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(MenuBarStore.self, from: json)
        XCTAssertEqual(s.spacing, 3)   // model default (denser than macOS stock 16)
        XCTAssertFalse(s.alwaysHiddenEnabled)
        XCTAssertEqual(s.autoRehideSeconds, 5)
        XCTAssertEqual(s.chevronStyle, .ellipsis)
    }

    // A blob from the old build that still carries the removed reorder/order keys
    // must decode (ignoring them), not fail — the tolerant init drops unknown keys.
    func testStoreIgnoresRemovedReorderKeys() throws {
        let json = #"{"schemaVersion":1,"reorderEnabled":true,"observedOrder":[{"bundleID":"x","slot":0}],"chevronStyle":"arrow"}"#
            .data(using: .utf8)!
        let s = try JSONDecoder().decode(MenuBarStore.self, from: json)
        XCTAssertEqual(s.chevronStyle, .arrow)
    }

    // MARK: - Chevron style (cosmetic glyph mapping)

    func testChevronSymbolsDifferPerStyle() {
        // Every style maps to a distinct collapsed glyph (no two share one), so the
        // picker actually changes the bar.
        let collapsed = ChevronStyle.allCases.map(\.collapsedSymbol)
        XCTAssertEqual(Set(collapsed).count, ChevronStyle.allCases.count)
    }

    // MARK: - Preview-strip health probe (Tahoe-style CGS-shift detection)

    func testPreviewHealthyWhenEnumContainsOwnDivider() {
        // Enum still returns a window we know exists (divider 10) → trust the preview.
        XCTAssertTrue(MenuBarLogic.previewHealthy(dividerWindowIDs: [10, 11],
                                                  enumeratedWindowIDs: [5, 10, 99]))
    }

    func testPreviewUnhealthyWhenEnumOmitsAllDividers() {
        // Enum returns success but omits BOTH dividers that provably exist → the
        // CGS semantics shifted (as on Tahoe for Bartender); preview can't be trusted.
        XCTAssertFalse(MenuBarLogic.previewHealthy(dividerWindowIDs: [10, 11],
                                                   enumeratedWindowIDs: [5, 99]))
    }

    func testPreviewHealthyBeforeDividersExist() {
        // No dividers built yet (setup hasn't run) → nothing to probe → never false-alarm.
        XCTAssertTrue(MenuBarLogic.previewHealthy(dividerWindowIDs: [],
                                                  enumeratedWindowIDs: []))
    }

    // NOTE: self-identification of our own status windows moved from windowNumber
    // mapping to frame-match (MenuBarBridge.windowID(forItemMinX:)) — Tahoe put
    // windowNumber in a separate +2³² namespace unrelated to CGWindowID. The new path
    // needs live AppKit/CGS, so it's covered by the on-device self-probe, not a unit
    // test. The pure section/length/preview-health logic below is unaffected.

    // MARK: - Ordering engine: identity composition (multi-icon disambiguation)

    func testIdentityKeyPrefersTitleOverImageHash() {
        let id = MenuBarIdentity(bundleID: "eu.exelban.Stats", title: "CPU", imageHash: "ab12")
        XCTAssertEqual(id.key, "eu.exelban.Stats#CPU")
        XCTAssertTrue(id.isResolved)
    }

    func testIdentitySameAppDistinctTitlesDontCollide() {
        // The Stats problem: one bundle id, three items → three distinct keys.
        let cpu = MenuBarIdentity(bundleID: "eu.exelban.Stats", title: "CPU")
        let ram = MenuBarIdentity(bundleID: "eu.exelban.Stats", title: "RAM")
        XCTAssertNotEqual(cpu.key, ram.key)
    }

    func testIdentityTahoeMenuItemPlaceholderFallsBackToImageHash() {
        // Tahoe reports "Menu Item" as title → must be ignored so imageHash wins.
        let id = MenuBarIdentity(bundleID: "eu.exelban.Stats", title: "Menu Item", imageHash: "ff09")
        XCTAssertEqual(id.key, "eu.exelban.Stats#ff09")
        XCTAssertTrue(id.isResolved)
    }

    func testIdentityUnindexedTahoeDegradesToBundleAndIsUnresolved() {
        // No title (or placeholder) and nothing indexed yet → bundle-only key,
        // flagged unresolved so siblings can't be ordered apart prematurely.
        let id = MenuBarIdentity(bundleID: "eu.exelban.Stats", title: "Menu Item")
        XCTAssertEqual(id.key, "eu.exelban.Stats#")
        XCTAssertFalse(id.isResolved)
    }

    func testItemOrdinalPlaceholderTitleIsUnresolvedAndUnmanageable() {
        // Tahoe names items it can't identify "Item-0" / "Item 1" — those must be
        // treated as placeholders so unidentifiable foreign items drop out of the
        // managed set instead of appearing as "Item-0" in the saved order.
        for t in ["Item-0", "Item 1", "Item-42"] {
            let id = MenuBarIdentity(bundleID: "com.apple.controlcenter", title: t)
            XCTAssertFalse(id.isResolved, "\(t) should be unresolved")
            XCTAssertFalse(id.isManageable, "\(t) should be unmanageable")
        }
        // A real foreign title is kept; our own items are always manageable.
        XCTAssertTrue(MenuBarIdentity(bundleID: "com.apple.controlcenter", title: "WiFi").isManageable)
        XCTAssertTrue(MenuBarIdentity(bundleID: "com.prosper", title: "CPU").isManageable)
        // "Item" without a trailing number is a legitimate title, not a placeholder.
        XCTAssertFalse(MenuBarIdentity.isPlaceholderTitle("Item Shop"))
    }

    func testSystemFixedExtrasAreUnmanageable() {
        // The clock and Control Center's BentoBox cluster are pinned by macOS and
        // can't be ⌘-dragged → must drop out of the orderable set entirely.
        XCTAssertFalse(MenuBarIdentity(bundleID: "com.apple.controlcenter", title: "Clock").isManageable)
        XCTAssertFalse(MenuBarIdentity(bundleID: "com.apple.controlcenter", title: "BentoBox-0").isManageable)
        // A normal app icon and our own items remain manageable.
        XCTAssertTrue(MenuBarIdentity(bundleID: "com.apple.controlcenter", title: "WiFi").isManageable)
        XCTAssertTrue(MenuBarIdentity(bundleID: "com.prosper", title: "CPU").isManageable)
    }

    // MARK: - Ordering engine: OS capability gate

    func testOrderingSupportedOnTahoe() {
        XCTAssertEqual(MenuBarOrderingCapability.osSupport(major: 26), .supported)
    }

    func testOrderingUnsupportedBelowTahoe() {
        guard case .unsupportedOS = MenuBarOrderingCapability.osSupport(major: 15) else {
            return XCTFail("macOS 15 must be gated off until the OS-title path ships")
        }
    }

    func testOrderingUnsupportedAboveTahoe() {
        guard case .unsupportedOS = MenuBarOrderingCapability.osSupport(major: 27) else {
            return XCTFail("future macOS must be gated off until verified")
        }
    }

    // MARK: - Ordering engine: order store (tolerant Codable, opt-in default off)

    func testOrderStoreDefaultsInert() {
        let s = MenuBarOrderStore.default
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.mode, .onDemand)
        XCTAssertTrue(s.desiredOrder.isEmpty)
    }

    func testOrderStoreRoundTrips() throws {
        var s = MenuBarOrderStore.default
        s.enabled = true
        s.mode = .live
        s.desiredOrder = [MenuBarIdentity(bundleID: "a", title: "CPU"),
                          MenuBarIdentity(bundleID: "a", title: "RAM")]
        s.alwaysHidden = ["a#RAM"]
        s.hiddenDividerIndex = 1
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(MenuBarOrderStore.self, from: data)
        XCTAssertEqual(back, s)
        XCTAssertTrue(back.isAlwaysHidden("a#RAM"))
        XCTAssertFalse(back.isAlwaysHidden("a#CPU"))
        XCTAssertEqual(back.hiddenDividerIndex, 1)
    }

    func testHiddenKeysAreDividerPrefixMinusAlwaysHidden() {
        var s = MenuBarOrderStore.default
        s.desiredOrder = [MenuBarIdentity(bundleID: "x", title: "A"),   // x#A — hidden
                          MenuBarIdentity(bundleID: "x", title: "B"),   // x#B — always-hidden
                          MenuBarIdentity(bundleID: "x", title: "C")]   // x#C — visible (after divider)
        s.alwaysHidden = ["x#B"]
        // No divider → nothing hidden.
        XCTAssertTrue(s.hiddenKeys.isEmpty)
        // Divider after the first two → prefix {x#A, x#B}, minus always-hidden x#B.
        s.hiddenDividerIndex = 2
        XCTAssertEqual(s.hiddenKeys, ["x#A"])
    }

    func testOrderStoreDecodesFromMinimalJSON() throws {
        let json = #"{"schemaVersion":1}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(MenuBarOrderStore.self, from: json)
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.mode, .onDemand)
        XCTAssertTrue(s.desiredOrder.isEmpty)
    }

    // MARK: - Ordering engine: reorder diff (must converge current → desired)

    /// Apply a full move list and assert the common items land in desired order.
    private func assertConverges(current: [String], desired: [String],
                                 line: UInt = #line) {
        let moves = MenuBarOrderDiff.reorderMoves(current: current, desired: desired)
        var seq = current
        for m in moves { seq = MenuBarOrderDiff.apply(m, to: seq) }
        let want = desired.filter(Set(current).contains)
        let got = seq.filter(Set(desired).contains)
        XCTAssertEqual(got, want, "did not converge", line: line)
    }

    func testReorderAlreadyOrderedEmitsNoMoves() {
        XCTAssertTrue(MenuBarOrderDiff.reorderMoves(current: ["a", "b", "c"],
                                                    desired: ["a", "b", "c"]).isEmpty)
    }

    func testReorderReversalConverges() {
        assertConverges(current: ["a", "b", "c", "d"], desired: ["d", "c", "b", "a"])
    }

    func testReorderPartialAndExtraneousItemsConverge() {
        // Desired references only some items; current has extras not in desired.
        assertConverges(current: ["x", "a", "y", "b", "z"], desired: ["b", "a"])
    }

    func testReorderIgnoresDesiredItemsNotPresent() {
        // "q" isn't in the bar → must be skipped, not crash.
        assertConverges(current: ["a", "b"], desired: ["q", "b", "a"])
    }

    // MARK: - Ordering engine: arranger identity mapping

    @MainActor
    func testArrangerIdentityUsesBundleAndTitle() {
        let item = MenuBarItem(windowID: 1, pid: 9, frame: .zero, bundleID: "eu.exelban.Stats",
                               displayID: 0, title: "CPU")
        XCTAssertEqual(MenuBarArranger.identity(for: item).key, "eu.exelban.Stats#CPU")
    }

    @MainActor
    func testArrangerIdentityFallsBackToUnknownBundle() {
        // A nil bundle id mustn't collapse every such item onto key "#" — it gets a
        // stable "unknown" bundle so they don't all alias together.
        let item = MenuBarItem(windowID: 2, pid: 9, frame: .zero, bundleID: nil,
                               displayID: 0, title: "X")
        XCTAssertEqual(MenuBarArranger.identity(for: item).key, "unknown#X")
    }

    // MARK: - Ordering engine: circuit breaker (CPU/battery protection)

    func testCircuitBreakerTripsAtThreshold() {
        var cb = MenuBarCircuitBreaker(failureThreshold: 3, cooldown: 60)
        cb.recordFailure(now: 0); cb.recordFailure(now: 1)
        XCTAssertFalse(cb.isTripped(now: 1))
        cb.recordFailure(now: 2)
        XCTAssertTrue(cb.isTripped(now: 2))
        XCTAssertTrue(cb.isTripped(now: 61))
        XCTAssertFalse(cb.isTripped(now: 62), "cooldown elapsed at now+60")
    }

    func testCircuitBreakerSuccessResets() {
        var cb = MenuBarCircuitBreaker(failureThreshold: 2, cooldown: 60)
        cb.recordFailure(now: 0)
        cb.recordSuccess()
        cb.recordFailure(now: 1)
        XCTAssertFalse(cb.isTripped(now: 1), "success cleared the failure count")
    }

    func testCircuitBreakerResetsAfterCooldown() {
        var cb = MenuBarCircuitBreaker(failureThreshold: 1, cooldown: 60)
        cb.recordFailure(now: 0)
        XCTAssertTrue(cb.isTripped(now: 10))
        cb.resetIfCooledDown(now: 70)
        XCTAssertFalse(cb.isTripped(now: 70))
        XCTAssertEqual(cb.failures, 0)
    }

    // MARK: - Ordering engine: perceptual hash (Tahoe identity rebuild)

    func testDHashStableForIdenticalBuffers() {
        let buf = (0..<72).map { UInt8(($0 * 7) % 256) }
        XCTAssertEqual(MenuBarPerceptualHash.dHash(gray9x8: buf),
                       MenuBarPerceptualHash.dHash(gray9x8: buf))
    }

    func testDHashDistinguishesDifferentImages() {
        let a = [UInt8](repeating: 0, count: 72)
        var b = a; for i in stride(from: 0, to: 72, by: 2) { b[i] = 255 }  // alternating bright
        XCTAssertNotEqual(MenuBarPerceptualHash.dHash(gray9x8: a),
                          MenuBarPerceptualHash.dHash(gray9x8: b))
    }

    func testDHashGradientEncodesDirection() {
        // Each row strictly increasing left→right ⇒ every "left > right" is false ⇒ 0.
        var asc = [UInt8](repeating: 0, count: 72)
        for r in 0..<8 { for c in 0..<9 { asc[r*9 + c] = UInt8(c * 28) } }
        XCTAssertEqual(MenuBarPerceptualHash.dHash(gray9x8: asc), 0)
    }

    func testHexRoundTrips() {
        let h: UInt64 = 0xDEAD_BEEF_0000_1234
        XCTAssertEqual(MenuBarPerceptualHash.value(fromHex: MenuBarPerceptualHash.hex(h)), h)
        XCTAssertEqual(MenuBarPerceptualHash.hex(0), "0000000000000000")
    }

    func testBestMatchPicksNearestWithinThreshold() {
        let target: UInt64 = 0b1111
        let cands = [("a", UInt64(0b1110)),   // dist 1
                     ("b", UInt64(0b1000)),   // dist 3
                     ("c", UInt64(0))]        // dist 4
        XCTAssertEqual(MenuBarPerceptualHash.bestMatch(target: target, candidates: cands, maxDistance: 2), "a")
    }

    func testBestMatchRejectsBeyondThreshold() {
        let cands = [("a", UInt64(0xFFFF_FFFF_FFFF_FFFF))]   // far from 0
        XCTAssertNil(MenuBarPerceptualHash.bestMatch(target: 0, candidates: cands, maxDistance: 5))
        XCTAssertNil(MenuBarPerceptualHash.bestMatch(target: 0, candidates: [], maxDistance: 5))
    }

    // MARK: - Ordering engine: live drift + enforcement policy (P4)

    func testRelativeOrderSatisfiedWhenSubsequence() {
        // Desired A,B,C present in correct relative order with foreign X,Y wedged in.
        XCTAssertTrue(MenuBarOrderDiff.isRelativeOrderSatisfied(
            current: ["A", "X", "B", "Y", "C"], desired: ["A", "B", "C"]))
    }

    func testRelativeOrderViolatedWhenSwapped() {
        XCTAssertFalse(MenuBarOrderDiff.isRelativeOrderSatisfied(
            current: ["A", "C", "B"], desired: ["A", "B", "C"]))
    }

    func testRelativeOrderIgnoresAbsentDesired() {
        // C not live ⇒ only A,B constrain, and they're ordered.
        XCTAssertTrue(MenuBarOrderDiff.isRelativeOrderSatisfied(
            current: ["A", "B"], desired: ["A", "C", "B"]))
        // Single present desired ⇒ trivially satisfied.
        XCTAssertTrue(MenuBarOrderDiff.isRelativeOrderSatisfied(
            current: ["Z", "A"], desired: ["A", "B", "C"]))
    }

    func testPolicyBlocksWithinCooldownAndStretchesOnBattery() {
        var p = MenuBarEnforcementPolicy(baseCooldown: 2, batteryMultiplier: 4)
        XCTAssertTrue(p.canApply(now: 0, onBattery: false))
        p.recordApply(now: 0, success: true)
        XCTAssertFalse(p.canApply(now: 1, onBattery: false), "within 2s AC cooldown")
        XCTAssertTrue(p.canApply(now: 3, onBattery: false), "past 2s AC cooldown")
        XCTAssertFalse(p.canApply(now: 3, onBattery: true), "battery cooldown is 8s")
        XCTAssertTrue(p.canApply(now: 9, onBattery: true), "past 8s battery cooldown")
    }

    func testPolicyBreakerTripBlocksApply() {
        var p = MenuBarEnforcementPolicy(baseCooldown: 0,
                                         breaker: MenuBarCircuitBreaker(failureThreshold: 2, cooldown: 60))
        p.recordApply(now: 0, success: false)
        p.recordApply(now: 0, success: false)   // trips
        XCTAssertFalse(p.canApply(now: 1, onBattery: false), "tripped breaker blocks")
        XCTAssertTrue(p.canApply(now: 61, onBattery: false), "unblocks after cooldown")
    }

    func testNoOpPassDoesNotResetBreaker() {
        // Regression: a no-op pass must NOT call recordSuccess (which would reset the
        // failure count every tick and permanently disarm the breaker on a stuck loop).
        var p = MenuBarEnforcementPolicy(baseCooldown: 0,
                                         breaker: MenuBarCircuitBreaker(failureThreshold: 2, cooldown: 60))
        p.recordApply(now: 0, success: false)   // failure 1
        p.stampThrottleOnly(now: 0)             // no-op tick — must preserve failure count
        p.recordApply(now: 0, success: false)   // failure 2 → trips
        XCTAssertFalse(p.canApply(now: 1, onBattery: false), "breaker should have tripped despite the no-op tick")
    }

    func testStampThrottleOnlyStillBlocksWithinCooldown() {
        var p = MenuBarEnforcementPolicy(baseCooldown: 5, batteryMultiplier: 2)
        p.stampThrottleOnly(now: 10)
        XCTAssertFalse(p.canApply(now: 12, onBattery: false), "no-op still throttles the next attempt")
        XCTAssertTrue(p.canApply(now: 16, onBattery: false))
    }

    // MARK: - Manifest wiring (the declarative section + reveal shortcut)

    /// Load the shipped extension.toml exactly as the host does. Proves the
    /// manifest parses, identifies as a system extension, and contributes the
    /// "menubar" section with the rebindable reveal shortcut — the part of the
    /// wiring PROSPER_VERIFY can only check inside a packaged .app (where the
    /// bundled-resources dir classifies the folder as system).
    func testManifestParsesWithSectionAndShortcut() throws {
        let dir = URL(fileURLWithPath: #filePath)        // .../Tests/ProsperAppTests/MenuBarTests.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions/menubar")
        let loaded = try ExtensionLoader.load(directory: dir, isSystem: true, hostVersion: "0.0.0")
        XCTAssertEqual(loaded.manifest.extension.id, "com.prosper.menubar")
        XCTAssertEqual(loaded.manifest.extension.isSystem, true)

        let sections = loaded.manifest.contributes?.allSettingsSections ?? []
        let section = sections.first { $0.id == "menubar" }
        XCTAssertNotNil(section, "menubar settings section missing")
        XCTAssertEqual(section?.accent, "Menu Bar")

        let shortcut = section?.allControls.first { $0.kind == .shortcut }
        XCTAssertEqual(shortcut?.name, "menuBarToggleHidden",
                       "reveal shortcut must bind to the menuBarToggleHidden action")
    }

    /// The manifest's shortcut `name` must resolve to a real ShortcutAction owned
    /// by this extension — otherwise the recorder renders but binds nothing.
    func testRevealShortcutActionBinding() {
        let action = ShortcutAction(rawValue: "menuBarToggleHidden")
        XCTAssertNotNil(action, "menuBarToggleHidden is not a ShortcutAction rawValue")
        XCTAssertEqual(action?.owningExtensionID, "com.prosper.menubar")
    }

    // MARK: - Perf budget (cold path: reveal + Settings render)

    /// Section classification feeds the Settings list and runs once per reveal over
    /// every menu-bar item. Even an absurd 200-item bar must classify in well under
    /// the ≤ 2 ms warm-enumeration budget, leaving headroom for the CGS calls.
    func testSectionClassificationIsCheap() {
        let xs = (0..<200).map { CGFloat($0 * 7) }
        measure {
            for _ in 0..<1000 {
                for x in xs {
                    _ = MenuBarLogic.section(forItemX: x, hiddenDividerX: 700, alwaysHiddenDividerX: 350)
                }
            }
        }
    }

    // MARK: - Ordering engine: hot-path budgets
    //
    // HOT PATH (ordering): the live drift check runs every 2 s while live mode is on,
    // so it must be effectively free. dHash + match run per item per index pass
    // (on-demand, ≤ tens of items) but still need to stay sub-millisecond so an
    // index of a full bar is imperceptible. Budgets below are deliberately loose
    // (CI headroom) yet would catch an accidental O(n²)/allocation blow-up.

    /// Live drift check: 1000 passes over a realistic 30-item bar must be ≤ 20 ms
    /// (≤ 20 µs/pass). Runs every live tick, so any regression here is idle CPU.
    func testDriftCheckIsCheap() {
        let current = (0..<30).map { "com.app\($0)#i" }
        let desired = stride(from: 0, to: 30, by: 2).map { "com.app\($0)#i" }   // every other item
        let start = Date()
        for _ in 0..<1000 {
            _ = MenuBarOrderDiff.isRelativeOrderSatisfied(current: current, desired: desired)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.020, "drift check too slow: \(elapsed * 1000) ms / 1000 passes")
    }

    /// Reorder planning over a 30-item bar (worst case: full reversal). Budget is a
    /// DEBUG-build ceiling chosen to catch an accidental O(n³)+ blow-up of the splice,
    /// NOT to assert release latency. The O(n²) baseline measures ~215 ms/1000 plans
    /// at idle on an M-series debug build and 300+ ms under load, so the old 200 ms
    /// ceiling flaked red with no real regression. 500 ms keeps a real blow-up caught
    /// (an O(n³) reversal would be 20×+ slower → multiple seconds) while absorbing
    /// debug + machine-load variance. Release is ~20 µs/plan — irrelevant at bar scale.
    func testReorderPlanningIsCheap() {
        let current = (0..<30).map { "k\($0)" }
        let desired = current.reversed().map { $0 }
        let start = Date()
        for _ in 0..<1000 { _ = MenuBarOrderDiff.reorderMoves(current: current, desired: desired) }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.500, "reorder planning too slow: \(elapsed * 1000) ms / 1000 plans")
    }

    /// dHash + nearest-match over a 72-byte buffer + 30 candidates. DEBUG-build
    /// ceiling: ≤ 200 ms / 10 000 iters (≈20 µs/iter debug, ≈2 µs release). Catches
    /// a regression to a non-bitwise hash or a quadratic match.
    func testHashAndMatchAreCheap() {
        let buf = (0..<72).map { UInt8(($0 * 37 + 11) % 256) }
        let cands = (0..<30).map { ("k\($0)", UInt64($0) &* 0x9E37_79B9_7F4A_7C15) }
        let start = Date()
        for _ in 0..<10_000 {
            let h = MenuBarPerceptualHash.dHash(gray9x8: buf)
            _ = MenuBarPerceptualHash.bestMatch(target: h, candidates: cands, maxDistance: 8)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.200, "hash+match too slow: \(elapsed * 1000) ms / 10k iters")
    }

    /// dHash distance between distinct synthetic glyphs must comfortably exceed the
    /// match tolerance — guards against a loose tolerance collapsing sibling items
    /// (Stats CPU vs RAM) onto one identity.
    func testDistinctGlyphsExceedMatchTolerance() {
        var a = [UInt8](repeating: 0, count: 72)
        var b = [UInt8](repeating: 0, count: 72)
        for r in 0..<8 { for c in 0..<9 {
            a[r*9 + c] = UInt8((c * 30) % 256)              // left→right ramp
            b[r*9 + c] = UInt8(((8 - c) * 30) % 256)        // mirrored ramp
        } }
        let d = MenuBarPerceptualHash.hamming(MenuBarPerceptualHash.dHash(gray9x8: a),
                                              MenuBarPerceptualHash.dHash(gray9x8: b))
        XCTAssertGreaterThan(d, MenuBarArranger.hashMatchTolerance,
                             "mirrored glyphs only \(d) apart — tolerance \(MenuBarArranger.hashMatchTolerance) too loose")
    }

    /// The enforcer must disarm its live timer when handed a disabled store — this is
    /// what stops the 2s loop (and its synthetic drags) the instant the menu-bar
    /// extension is toggled off at runtime. Arm it first, then confirm disarm.
    @MainActor
    func testEnforcerDisarmsOnDisabledStore() {
        var live = MenuBarOrderStore()
        live.enabled = true
        live.mode = .live
        live.desiredOrder = [MenuBarIdentity(bundleID: "a", title: "A"),
                             MenuBarIdentity(bundleID: "b", title: "B")]

        let enforcer = MenuBarOrderEnforcer.shared
        enforcer.update(store: live, probeOK: true)
        XCTAssertTrue(enforcer.isLiveRunning, "live store + probe ⇒ timer armed")

        enforcer.update(store: .default, probeOK: false)   // extension disabled
        XCTAssertFalse(enforcer.isLiveRunning, "disabled store must stop the live loop")

        // Also: even an enabled store with probe failed must NOT run (self-probe gate).
        enforcer.update(store: live, probeOK: false)
        XCTAssertFalse(enforcer.isLiveRunning, "probe-failed must not arm the loop")
    }
}
