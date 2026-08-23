import XCTest
@testable import ProsperApp

/// The built-in "double-tap ⌘Q to quit" rule (Settings → Shortcuts → Quit Guard)
/// is injected by ShortcutRulesStore's compiler — no new key-handling path.
@MainActor
final class DoubleTapQuitRuleTests: XCTestCase {
    func testCompilerAddsExactlyOneDoubleTapQuitRuleWhenEnabled() {
        let off = KeyRuleEngine.decode(json: ShortcutRulesStore.compileJSON([], doubleTapQuit: false))
        XCTAssertTrue(off.isEmpty)

        let on = KeyRuleEngine.decode(json: ShortcutRulesStore.compileJSON([], doubleTapQuit: true))
        XCTAssertEqual(on.count, 1)
        XCTAssertEqual(on[0].chord, KeyChord(spec: "cmd+q"))
        XCTAssertEqual(on[0].action, .doubleTap(KeyChord(spec: "cmd+q")!))
    }

    func testBuiltInRuleIsLastSoUserMappingWins() {
        var user = ShortcutRulesStore.Rule()
        user.trigger = "cmd+q"
        user.action = .swallow
        let rules = KeyRuleEngine.decode(json: ShortcutRulesStore.compileJSON([user], doubleTapQuit: true))
        XCTAssertEqual(rules.count, 2)
        // match() returns the first rule for the chord → the user's own mapping.
        let hit = KeyRuleEngine.match(rules: rules, chord: KeyChord(spec: "cmd+q")!, bundleID: nil)
        XCTAssertEqual(hit?.action, .swallow)
    }

    func testFirstTapSwallowsSecondPassesThrough() {
        let mgr = ExtensionKeyRules.shared
        mgr.setRules(extensionID: "quit-guard-test",
                     json: ShortcutRulesStore.compileJSON([], doubleTapQuit: true))
        defer { mgr.setRules(extensionID: "quit-guard-test", json: "[]") }
        let q = KeyChord(spec: "cmd+q")!
        let t0: UInt64 = 1_000_000_000
        XCTAssertEqual(mgr.evaluate(chord: q, bundleID: nil, nowNanos: t0), .swallow)
        XCTAssertEqual(mgr.evaluate(chord: q, bundleID: nil, nowNanos: t0 + 100_000_000), .passThrough)
        // Past the 0.5s window it is a fresh first tap.
        XCTAssertEqual(mgr.evaluate(chord: q, bundleID: nil, nowNanos: t0 + 5_000_000_000), .swallow)
    }
}
