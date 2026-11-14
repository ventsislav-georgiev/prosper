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

    /// Regression: OS key-autorepeats of a HELD key (which arrive ~0.5s after the
    /// press, inside the double-tap window) must NOT consume/reset the pending
    /// first press, else the real second tap looks like a fresh first and the user
    /// has to mash the key. Repeats are swallowed without touching `pending`.
    @MainActor
    func testDoubleTapIgnoresKeyRepeats() {
        let mgr = ExtensionKeyRules.shared
        mgr.removeRules(extensionID: "t")
        mgr.setRules(extensionID: "t", json: #"[{ "from": "cmd+q", "double_tap": "cmd+q" }]"#)
        let q = KeyChord(spec: "cmd+q")!
        let t0: UInt64 = 1_000_000_000
        // Real first press swallowed, pending set.
        XCTAssertEqual(mgr.evaluate(chord: q, bundleID: nil, nowNanos: t0), .swallow)
        // Autorepeats while holding ⌘Q — each swallowed, pending untouched.
        let r1 = t0 + UInt64(0.45 * 1_000_000_000)
        XCTAssertEqual(mgr.evaluate(chord: q, bundleID: nil, isRepeat: true, nowNanos: r1), .swallow)
        let r2 = t0 + UInt64(0.48 * 1_000_000_000)
        XCTAssertEqual(mgr.evaluate(chord: q, bundleID: nil, isRepeat: true, nowNanos: r2), .swallow)
        // Real second press still within window of the ORIGINAL first → passThrough.
        let within = t0 + UInt64(0.49 * 1_000_000_000)
        XCTAssertEqual(mgr.evaluate(chord: q, bundleID: nil, nowNanos: within), .passThrough)
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

    // MARK: #1189 — the chords an extension's key rules hold, and the re-run they drive

    /// A fresh engine (never `shared`): Compat rules passed as values, no tap, no file.
    @MainActor
    func testExtensionKeyboardChordsSkipNativeOwnerAndMediaKeys() {
        let rules = ExtensionKeyRules()
        let s = KeyCombo.parse("shift+alt+s")!.chord
        let j = KeyCombo.parse("cmd+ctrl+j")!.chord
        XCTAssertEqual(rules.extensionKeyboardChords, [])
        rules.setRules(extensionID: "com.example.compat", json: """
        [ { "from": "shift+alt+s", "launch": "com.example.fake" },
          { "from": "media:PLAY", "swallow": true },
          { "from": "f8", "system": "PLAY" } ]
        """)
        rules.setRules(extensionID: ShortcutRulesStore.ownerID, json: #"[ { "from": "cmd+ctrl+j", "swallow": true } ]"#)
        let f8 = KeyCombo.parse("f8")!.chord
        // ⇧⌥S as a Carbon chord; the bare f8 is in (heldChords drops it by its modifier filter); media and the native owner are not.
        XCTAssertEqual(rules.extensionKeyboardChords, [s, f8])
        XCTAssertFalse(rules.extensionKeyboardChords.contains(j), "native rules are read from ShortcutRulesStore, not here")
        XCTAssertEqual(ShortcutStore.keyRuleChords(ruleTriggers: [], extensionRuleChords: rules.extensionKeyboardChords), [s])
        rules.removeRules(extensionID: "com.example.compat")
        XCTAssertEqual(rules.extensionKeyboardChords, [])
    }

    /// The re-run trigger, counted (no wait): `onExtensionChordsChanged` fires once per change of an extension's
    /// keyboard chords, never for the native owner or the reserved chords, the only two things registerHotKeys
    /// writes into the engine. The recorder does those writes, so a trigger that fired on them would count
    /// past 1 at once (capped at 10 so a looping build fails instead of overflowing the stack).
    @MainActor
    func testExtensionChordChangeRerunsOnceAndNeverLoops() {
        let rules = ExtensionKeyRules()
        var reruns = 0
        rules.onExtensionChordsChanged = { [unowned rules] in
            reruns += 1
            guard reruns < 10 else { return }
            // What registerHotKeys does to the engine: reserve its chords, re-apply the native rules.
            rules.setReservedChords([KeyChord(keyCode: 49, cmd: true)])
            rules.setRules(extensionID: ShortcutRulesStore.ownerID, json: #"[ { "from": "cmd+ctrl+j", "swallow": true } ]"#)
        }
        defer { rules.onExtensionChordsChanged = nil }
        let compat = "com.example.compat"

        rules.setRules(extensionID: compat, json: #"[ { "from": "shift+alt+s", "swallow": true } ]"#)
        XCTAssertEqual(reruns, 1, "a Compat rule on a new chord re-runs registration once")
        rules.setRules(extensionID: compat, json: #"[ { "from": "shift+alt+s", "launch": "com.example.fake" } ]"#)
        XCTAssertEqual(reruns, 1, "same chord, other action: nothing to re-register")
        rules.setRules(extensionID: ShortcutRulesStore.ownerID, json: #"[ { "from": "shift+alt+s", "swallow": true } ]"#)
        XCTAssertEqual(reruns, 1, "a native rule change goes through persistKeyMappings' hook, not this one")
        rules.setReservedChords([])
        XCTAssertEqual(reruns, 1)
        rules.setRules(extensionID: compat, json: #"[ { "from": "media:PLAY", "swallow": true } ]"#)
        XCTAssertEqual(reruns, 2, "⇧⌥S released (only a media key left)")
        rules.removeRules(extensionID: compat)
        XCTAssertEqual(reruns, 2, "a media key never held a hotkey chord")
        rules.setRules(extensionID: compat, json: #"[ { "from": "shift+alt+s", "swallow": true } ]"#)
        rules.removeRules(extensionID: compat)
        XCTAssertEqual(reruns, 4, "added then removed: two re-runs")
        rules.removeRules(extensionID: compat)
        XCTAssertEqual(reruns, 4, "removing nothing re-runs nothing")
    }

    /// #1204: a burst of chord changes queues ONE re-run. The scheduler is held by hand (no main-actor hop, no
    /// registerHotKeys): `held` collects what the coalescer queued, the re-run is a counter. Rows count, never time.
    @MainActor
    private func makeCoalesced(_ rules: ExtensionKeyRules, held: Held, onRun: @escaping @MainActor () -> Void = {}) -> CoalescedRerun {
        let c = CoalescedRerun(schedule: { held.queue.append($0) }, run: { held.runs += 1; onRun() })
        rules.onExtensionChordsChanged = { c.request() }
        return c
    }

    @MainActor
    final class Held {
        var queue: [@MainActor () -> Void] = []
        var runs = 0
        func release() { let q = queue; queue = []; for w in q { w() } }
    }

    @MainActor
    private func alternate(_ rules: ExtensionKeyRules, count: Int) {
        let a = #"[ { "from": "shift+alt+s", "swallow": true } ]"#
        let b = #"[ { "from": "shift+alt+d", "swallow": true } ]"#
        for i in 0..<count { rules.setRules(extensionID: "com.example.compat", json: i % 2 == 0 ? a : b) }
    }

    @MainActor
    func testChordBurstQueuesOneRerunAndAnotherBurstQueuesOneMore() {
        let rules = ExtensionKeyRules()
        let held = Held()
        let c = makeCoalesced(rules, held: held)
        defer { rules.onExtensionChordsChanged = nil; _ = c }

        alternate(rules, count: 50)
        XCTAssertEqual(held.queue.count, 1, "50 alternating changes queue exactly one re-run")
        XCTAssertEqual(held.runs, 0, "nothing ran while the scheduler is held")
        held.release()
        XCTAssertEqual(held.runs, 1, "the queued re-run ran once")
        XCTAssertEqual(held.queue.count, 0)

        alternate(rules, count: 50)
        XCTAssertEqual(held.queue.count, 1, "a second burst queues exactly one more (the flag was cleared)")
        held.release()
        XCTAssertEqual(held.runs, 2)
    }

    @MainActor
    func testEqualChordSetQueuesNoRerun() {
        let rules = ExtensionKeyRules()
        let held = Held()
        let c = makeCoalesced(rules, held: held)
        defer { rules.onExtensionChordsChanged = nil; _ = c }
        let json = #"[ { "from": "shift+alt+s", "swallow": true } ]"#
        rules.setRules(extensionID: "com.example.compat", json: json)
        held.release()
        XCTAssertEqual(held.runs, 1)
        rules.setRules(extensionID: "com.example.compat", json: json)
        rules.setRules(extensionID: "com.example.compat", json: #"[ { "from": "shift+alt+s", "launch": "com.example.fake" } ]"#)
        XCTAssertEqual(held.queue.count, 0, "an equal chord set queues nothing")
    }

    @MainActor
    func testChangeDuringRerunQueuesExactlyOneMore() {
        let rules = ExtensionKeyRules()
        let held = Held()
        var changed = false
        let c = makeCoalesced(rules, held: held, onRun: {
            // A change made from inside the re-run (the flag must already be clear).
            guard !changed else { return }
            changed = true
            self.alternate(rules, count: 3)
        })
        defer { rules.onExtensionChordsChanged = nil; _ = c }
        alternate(rules, count: 2)
        XCTAssertEqual(held.queue.count, 1)
        held.release()
        XCTAssertEqual(held.runs, 1)
        XCTAssertEqual(held.queue.count, 1, "a change during the re-run queues exactly one more")
        held.release()
        XCTAssertEqual(held.runs, 2)
        XCTAssertEqual(held.queue.count, 0)
    }
}
