import XCTest
@testable import ProsperApp

final class ExtensionKeyRulesTests: XCTestCase {

    // MARK: KeyChord parsing

    func testChordParsesModifiersAndKey() {
        let c = KeyChord(spec: "cmd+shift+i")
        XCTAssertNotNil(c)
        XCTAssertTrue(c!.cmd); XCTAssertTrue(c!.shift)
        XCTAssertFalse(c!.alt); XCTAssertFalse(c!.ctrl)
        XCTAssertEqual(KeyChord(spec: "garblekey"), nil)
    }

    func testChordExactModifierMatch() {
        // cmd+i and cmd+shift+i are different chords — a rule for one must not fire
        // on the other.
        XCTAssertNotEqual(KeyChord(spec: "cmd+i"), KeyChord(spec: "cmd+shift+i"))
        XCTAssertEqual(KeyChord(spec: "cmd+i"), KeyChord(spec: "command+i"))
    }

    // MARK: decode

    func testDecodeAllActionShapes() {
        let json = """
        [
          { "from": "cmd+shift+i", "to": "cmd+alt+i", "apps": ["com.apple.Safari"] },
          { "from": "f8", "system": "play" },
          { "from": "f5", "swallow": true },
          { "from": "cmd+q", "double_tap": "cmd+q" },
          { "from": "boguskey", "to": "cmd+x" },
          { "from": "cmd+w", "swallow": true, "not_apps": ["com.foo.bar"] }
        ]
        """
        let rules = KeyRuleEngine.decode(json: json)
        // The bogus-key entry is skipped; the other five decode.
        XCTAssertEqual(rules.count, 5)
        XCTAssertEqual(rules[0].action, .remap(KeyChord(spec: "cmd+alt+i")!))
        XCTAssertEqual(rules[0].apps, ["com.apple.Safari"])
        XCTAssertEqual(rules[1].action, .system("PLAY")) // uppercased
        XCTAssertEqual(rules[2].action, .swallow)
        XCTAssertEqual(rules[3].action, .doubleTap(KeyChord(spec: "cmd+q")!))
        XCTAssertEqual(rules[4].notApps, ["com.foo.bar"])
    }

    func testDecodeInvokeShape() {
        let rules = KeyRuleEngine.decode(json: """
        [
          { "from": "f1", "invoke": "hs_dispatch", "arg": "3" },
          { "from": "f2", "invoke": "hs_dispatch" }
        ]
        """)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].action, .invoke(handler: "hs_dispatch", arg: "3"))
        XCTAssertEqual(rules[1].action, .invoke(handler: "hs_dispatch", arg: "")) // arg defaults to ""
    }

    @MainActor
    func testInvokeResolutionStampsExtensionID() {
        let mgr = ExtensionKeyRules.shared
        mgr.removeRules(extensionID: "hs")
        mgr.setRules(extensionID: "hs", json: #"[{ "from": "f1", "invoke": "hs_dispatch", "arg": "7" }]"#)
        XCTAssertEqual(mgr.evaluate(chord: KeyChord(spec: "f1")!, bundleID: nil),
                       .invoke(extensionID: "hs", handler: "hs_dispatch", arg: "7"))
        mgr.removeRules(extensionID: "hs")
    }

    @MainActor
    func testReservedChordYieldsToNativeHotkey() {
        let mgr = ExtensionKeyRules.shared
        mgr.removeRules(extensionID: "hs")
        // openlid binds cmd+alt+ctrl+l natively; the user's init.lua also binds it.
        mgr.setRules(extensionID: "hs", json: #"[{ "from": "cmd+alt+ctrl+l", "invoke": "hs_dispatch", "arg": "1" }]"#)
        let chord = KeyChord(spec: "cmd+alt+ctrl+l")!

        // Unreserved: the shim invoke rule resolves (and would swallow the chord).
        mgr.setReservedChords([])
        XCTAssertEqual(mgr.evaluate(chord: chord, bundleID: nil),
                       .invoke(extensionID: "hs", handler: "hs_dispatch", arg: "1"))

        // Reserved by a native hotkey → pass through so the Carbon handler wins.
        mgr.setReservedChords([chord])
        XCTAssertEqual(mgr.evaluate(chord: chord, bundleID: nil), .passThrough)

        // A different (unreserved) chord still resolves normally.
        mgr.removeRules(extensionID: "hs")
        mgr.setRules(extensionID: "hs", json: #"[{ "from": "alt+t", "invoke": "hs_dispatch", "arg": "7" }]"#)
        XCTAssertEqual(mgr.evaluate(chord: KeyChord(spec: "alt+t")!, bundleID: nil),
                       .invoke(extensionID: "hs", handler: "hs_dispatch", arg: "7"))

        mgr.setReservedChords([])
        mgr.removeRules(extensionID: "hs")
    }

    @MainActor
    func testReservedChordCarbonInitMatchesSpec() {
        // KeyChord(carbonKeyCode:carbonModifiers:) (AppDelegate's reserved-set source)
        // must equal the spec/tap chord, or reservation silently never matches.
        let combo = KeyCombo.parse("cmd+alt+ctrl+l")!
        XCTAssertEqual(KeyChord(carbonKeyCode: combo.keyCode, carbonModifiers: combo.carbonModifiers),
                       KeyChord(spec: "cmd+alt+ctrl+l"))
    }

    func testDecodeRejectsMalformed() {
        XCTAssertTrue(KeyRuleEngine.decode(json: "not json").isEmpty)
        XCTAssertTrue(KeyRuleEngine.decode(json: "{}").isEmpty)        // not an array
        XCTAssertTrue(KeyRuleEngine.decode(json: "[{}]").isEmpty)      // no "from"
    }

    // MARK: match + app filters

    func testMatchExactChordAndAppFilter() {
        let rules = KeyRuleEngine.decode(json: """
        [{ "from": "cmd+shift+i", "to": "cmd+alt+i", "apps": ["com.apple.Safari"] }]
        """)
        let chord = KeyChord(spec: "cmd+shift+i")!
        // Right chord, right app → match.
        XCTAssertNotNil(KeyRuleEngine.match(rules: rules, chord: chord, bundleID: "com.apple.Safari"))
        // Right chord, wrong app → no match.
        XCTAssertNil(KeyRuleEngine.match(rules: rules, chord: chord, bundleID: "com.other"))
        // Wrong chord (missing shift) → no match.
        XCTAssertNil(KeyRuleEngine.match(rules: rules, chord: KeyChord(spec: "cmd+i")!, bundleID: "com.apple.Safari"))
        // Allow-list rule never applies when the frontmost app is unknown.
        XCTAssertNil(KeyRuleEngine.match(rules: rules, chord: chord, bundleID: nil))
    }

    func testNotAppsExcludes() {
        let rules = KeyRuleEngine.decode(json: """
        [{ "from": "cmd+w", "swallow": true, "not_apps": ["com.block.me"] }]
        """)
        let w = KeyChord(spec: "cmd+w")!
        XCTAssertNotNil(KeyRuleEngine.match(rules: rules, chord: w, bundleID: "com.allow.me"))
        XCTAssertNil(KeyRuleEngine.match(rules: rules, chord: w, bundleID: "com.block.me"))
    }

    // MARK: manager — resolution + double-tap timing + per-extension isolation

    @MainActor
    func testManagerResolvesActions() {
        let mgr = ExtensionKeyRules.shared
        mgr.removeRules(extensionID: "t") // clean slate
        mgr.setRules(extensionID: "t", json: """
        [
          { "from": "cmd+shift+i", "to": "cmd+alt+i" },
          { "from": "f8", "system": "PLAY" },
          { "from": "f5", "swallow": true }
        ]
        """)
        XCTAssertFalse(mgr.isEmpty)
        XCTAssertEqual(mgr.evaluate(chord: KeyChord(spec: "cmd+shift+i")!, bundleID: nil),
                       .inject(KeyChord(spec: "cmd+alt+i")!))
        XCTAssertEqual(mgr.evaluate(chord: KeyChord(spec: "f8")!, bundleID: nil), .system("PLAY"))
        XCTAssertEqual(mgr.evaluate(chord: KeyChord(spec: "f5")!, bundleID: nil), .swallow)
        XCTAssertEqual(mgr.evaluate(chord: KeyChord(spec: "cmd+z")!, bundleID: nil), .passThrough)
        mgr.removeRules(extensionID: "t")
        XCTAssertTrue(mgr.isEmpty)
    }

    @MainActor
    func testDoubleTapWindow() {
        let mgr = ExtensionKeyRules.shared
        mgr.removeRules(extensionID: "t")
        mgr.setRules(extensionID: "t", json: #"[{ "from": "cmd+q", "double_tap": "cmd+q" }]"#)
        let q = KeyChord(spec: "cmd+q")!
        let t0: UInt64 = 1_000_000_000
        // First press swallowed.
        XCTAssertEqual(mgr.evaluate(chord: q, bundleID: nil, nowNanos: t0), .swallow)
        // Second within window → for a same-chord double-tap, the real key passes
        // through (no synthetic re-inject) so the app's own ⌘Q actually quits.
        let within = t0 + UInt64(0.3 * 1_000_000_000)
        XCTAssertEqual(mgr.evaluate(chord: q, bundleID: nil, nowNanos: within), .passThrough)
        // A later lone press is swallowed again (timer reset).
        let later = within + UInt64(2.0 * 1_000_000_000)
        XCTAssertEqual(mgr.evaluate(chord: q, bundleID: nil, nowNanos: later), .swallow)
        // A second press AFTER the window is treated as a fresh first press (swallow).
        let tooLate = later + UInt64(1.0 * 1_000_000_000)
        XCTAssertEqual(mgr.evaluate(chord: q, bundleID: nil, nowNanos: tooLate), .swallow)
        mgr.removeRules(extensionID: "t")
    }

    /// A double-tap whose target differs from the pressed chord still injects the
    /// target on the second press (only same-chord taps pass through).
    @MainActor
    func testDoubleTapDistinctTargetInjects() {
        let mgr = ExtensionKeyRules.shared
        mgr.removeRules(extensionID: "t")
        mgr.setRules(extensionID: "t", json: #"[{ "from": "cmd+q", "double_tap": "cmd+w" }]"#)
        let q = KeyChord(spec: "cmd+q")!
        let w = KeyChord(spec: "cmd+w")!
        let t0: UInt64 = 1_000_000_000
        XCTAssertEqual(mgr.evaluate(chord: q, bundleID: nil, nowNanos: t0), .swallow)
        let within = t0 + UInt64(0.3 * 1_000_000_000)
        XCTAssertEqual(mgr.evaluate(chord: q, bundleID: nil, nowNanos: within), .inject(w))
        mgr.removeRules(extensionID: "t")
    }

    @MainActor
    func testPerExtensionIsolation() {
        let mgr = ExtensionKeyRules.shared
        mgr.removeRules(extensionID: "a"); mgr.removeRules(extensionID: "b")
        mgr.setRules(extensionID: "a", json: #"[{ "from": "f1", "swallow": true }]"#)
        mgr.setRules(extensionID: "b", json: #"[{ "from": "f2", "swallow": true }]"#)
        XCTAssertEqual(mgr.evaluate(chord: KeyChord(spec: "f1")!, bundleID: nil), .swallow)
        XCTAssertEqual(mgr.evaluate(chord: KeyChord(spec: "f2")!, bundleID: nil), .swallow)
        // Removing one leaves the other intact.
        mgr.removeRules(extensionID: "a")
        XCTAssertEqual(mgr.evaluate(chord: KeyChord(spec: "f1")!, bundleID: nil), .passThrough)
        XCTAssertEqual(mgr.evaluate(chord: KeyChord(spec: "f2")!, bundleID: nil), .swallow)
        mgr.removeRules(extensionID: "b")
    }

    // MARK: - Media keys (incoming, §D) + launchApp

    func testMediaChordSpecParsing() {
        XCTAssertEqual(KeyChord(spec: "media:PLAY")?.mediaCode, 16)
        XCTAssertEqual(KeyChord(spec: "MUTE")?.mediaCode, 7)        // bare name
        XCTAssertEqual(KeyChord(spec: "sound_up")?.mediaCode, 0)    // case-insensitive
        XCTAssertNil(KeyChord(spec: "cmd+q")?.mediaCode)            // regular key: not media
    }

    func testMediaCodeNamespaceDoesNotCollideWithKeyCodeZero() {
        // SOUND_UP=0 and key `a`=0 must NOT be the same chord.
        XCTAssertNotEqual(KeyChord(mediaCode: 0), KeyChord(keyCode: 0))
    }

    @MainActor
    func testIncomingMediaRemapToKeyboard() {
        let mgr = ExtensionKeyRules.shared
        mgr.removeRules(extensionID: "m")
        mgr.setRules(extensionID: "m", json: #"[{ "from": "media:PLAY", "to": "cmd+c" }]"#)
        XCTAssertTrue(mgr.hasMediaRules)
        XCTAssertEqual(mgr.evaluateMedia(code: 16, bundleID: nil), .inject(KeyChord(spec: "cmd+c")!))
        // An unmapped media key passes through (system HUD intact).
        XCTAssertEqual(mgr.evaluateMedia(code: 1, bundleID: nil), .passThrough)
        mgr.removeRules(extensionID: "m")
        XCTAssertFalse(mgr.hasMediaRules)
    }

    @MainActor
    func testIncomingMediaRemapToOtherMediaAndSwallow() {
        let mgr = ExtensionKeyRules.shared
        mgr.removeRules(extensionID: "m")
        mgr.setRules(extensionID: "m", json: #"[{ "from": "media:NEXT", "to": "media:FAST" }, { "from": "media:MUTE", "swallow": true }]"#)
        XCTAssertEqual(mgr.evaluateMedia(code: 17, bundleID: nil), .system("FAST"))
        XCTAssertEqual(mgr.evaluateMedia(code: 7, bundleID: nil), .swallow)
        mgr.removeRules(extensionID: "m")
    }

    @MainActor
    func testLaunchAppAction() {
        let mgr = ExtensionKeyRules.shared
        mgr.removeRules(extensionID: "l")
        mgr.setRules(extensionID: "l", json: #"[{ "from": "alt+1", "launch": "/Applications/Slack.app" }]"#)
        XCTAssertEqual(mgr.evaluate(chord: KeyChord(spec: "alt+1")!, bundleID: nil),
                       .launchApp("/Applications/Slack.app"))
        mgr.removeRules(extensionID: "l")
    }

    @MainActor
    func testMediaRulesDoNotAffectKeyboardPath() {
        let mgr = ExtensionKeyRules.shared
        mgr.removeRules(extensionID: "m")
        mgr.setRules(extensionID: "m", json: #"[{ "from": "media:PLAY", "swallow": true }]"#)
        // keyCode 0 (`a`) must pass through — media rules live in their own bucket.
        XCTAssertEqual(mgr.evaluate(chord: KeyChord(keyCode: 0), bundleID: nil), .passThrough)
        mgr.removeRules(extensionID: "m")
    }
}
