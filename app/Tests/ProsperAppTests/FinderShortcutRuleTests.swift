import XCTest
@testable import ProsperApp

@MainActor
final class FinderShortcutRuleTests: XCTestCase {
    func testCompilerAddsExactlyOneFinderRuleWhenEnabled() {
        let off = KeyRuleEngine.decode(
            json: ShortcutRulesStore.compileJSON([], doubleTapQuit: false, finderF2Rename: false))
        XCTAssertTrue(off.isEmpty)

        let on = KeyRuleEngine.decode(
            json: ShortcutRulesStore.compileJSON([], doubleTapQuit: false, finderF2Rename: true))
        XCTAssertEqual(on.count, 1)
        XCTAssertEqual(on[0].chord, KeyChord(spec: "f2"))
        XCTAssertEqual(on[0].action, .remap(KeyChord(spec: "return")!))
    }

    func testRuleOnlyAppliesToFinder() {
        let rules = KeyRuleEngine.decode(
            json: ShortcutRulesStore.compileJSON([], doubleTapQuit: false, finderF2Rename: true))
        let f2 = KeyChord(spec: "f2")!
        XCTAssertNotNil(KeyRuleEngine.match(rules: rules, chord: f2, bundleID: "com.apple.finder"))
        XCTAssertNil(KeyRuleEngine.match(rules: rules, chord: f2, bundleID: "com.apple.Safari"))
        XCTAssertNil(KeyRuleEngine.match(rules: rules, chord: f2, bundleID: nil))
    }

    func testBuiltInRuleIsLastSoUserMappingWins() {
        var user = ShortcutRulesStore.Rule()
        user.trigger = "f2"
        user.action = .swallow
        let rules = KeyRuleEngine.decode(
            json: ShortcutRulesStore.compileJSON([user], doubleTapQuit: false, finderF2Rename: true))
        XCTAssertEqual(rules.count, 2)
        let hit = KeyRuleEngine.match(rules: rules, chord: KeyChord(spec: "f2")!, bundleID: "com.apple.finder")
        XCTAssertEqual(hit?.action, .swallow)
    }

    func testBothBuiltInsCoexist() {
        let rules = KeyRuleEngine.decode(
            json: ShortcutRulesStore.compileJSON([], doubleTapQuit: true, finderF2Rename: true))
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].chord, KeyChord(spec: "cmd+q"))
        XCTAssertEqual(rules[1].chord, KeyChord(spec: "f2"))
    }

    func testEngineRemapsF2InFinderOnly() {
        let mgr = ExtensionKeyRules.shared
        mgr.setRules(extensionID: "finder-f2-test",
                     json: ShortcutRulesStore.compileJSON([], doubleTapQuit: false, finderF2Rename: true))
        defer { mgr.setRules(extensionID: "finder-f2-test", json: "[]") }
        let f2 = KeyChord(spec: "f2")!
        XCTAssertEqual(mgr.evaluate(chord: f2, bundleID: "com.apple.finder"),
                       .inject(KeyChord(spec: "return")!))
        XCTAssertEqual(mgr.evaluate(chord: f2, bundleID: "com.apple.Safari"), .passThrough)
    }
}
