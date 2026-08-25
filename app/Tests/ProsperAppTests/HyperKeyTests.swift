import XCTest
@testable import ProsperApp

/// Caps-Lock hyper key (plan #016). Everything interesting is pure: the hold/tap
/// state machine takes injected nanos, and the `hidutil` table helpers are string
/// transforms. NOTHING here runs `hidutil` or touches the live machine's mapping.
final class HyperKeyTests: XCTestCase {

    // MARK: - 1. State machine, injected nanos

    private let s: UInt64 = 1_000_000_000

    func testShortLonePressIsATap() {
        var st = HyperKeyState()
        XCTAssertEqual(st.decide(.triggerDown(isRepeat: false, otherModifiers: false), nowNanos: 0), .swallow)
        XCTAssertEqual(st.decide(.triggerUp, nowNanos: s / 10),
                       .solo(isHold: false, repeated: false))
        XCTAssertFalse(st.isHeld, "the press must be cleared by its own release")
    }

    func testLongLonePressIsAHold() {
        var st = HyperKeyState()
        _ = st.decide(.triggerDown(isRepeat: false, otherModifiers: false), nowNanos: 0)
        XCTAssertEqual(st.decide(.triggerUp, nowNanos: HyperKeyState.holdThresholdNanos),
                       .solo(isHold: true, repeated: false),
                       "the threshold itself counts as a hold")
    }

    func testOtherKeyWhileHeldAddsModifiersAndKillsTheLoneAction() {
        var st = HyperKeyState()
        _ = st.decide(.triggerDown(isRepeat: false, otherModifiers: false), nowNanos: 0)
        XCTAssertEqual(st.decide(.otherKey, nowNanos: s / 100), .addModifiers)
        // Release after a real chord produces nothing — this is the whole point:
        // `hyper+H` must not also fire Escape.
        XCTAssertEqual(st.decide(.triggerUp, nowNanos: s / 50), .swallow)
    }

    func testOtherKeyWhileNotHeldIsUntouched() {
        var st = HyperKeyState()
        XCTAssertEqual(st.decide(.otherKey, nowNanos: 0), .pass,
                       "with the trigger up, ordinary typing must never be flagged")
    }

    func testTriggerDownWithModifiersAlreadyHeldIsNotAlone() {
        var st = HyperKeyState()
        _ = st.decide(.triggerDown(isRepeat: false, otherModifiers: true), nowNanos: 0)
        XCTAssertEqual(st.decide(.triggerUp, nowNanos: s / 10), .swallow,
                       "⌘+hyper is not a lone tap")
    }

    func testOtherModifierWhileHeldClearsAloneButPassesUntouched() {
        var st = HyperKeyState()
        _ = st.decide(.triggerDown(isRepeat: false, otherModifiers: false), nowNanos: 0)
        XCTAssertEqual(st.decide(.otherModifier, nowNanos: s / 100), .pass,
                       "a ⌘ edge is none of our business")
        XCTAssertEqual(st.decide(.triggerUp, nowNanos: s / 50), .swallow)
    }

    func testAutorepeatMarksThePressWithoutRestartingIt() {
        var st = HyperKeyState()
        _ = st.decide(.triggerDown(isRepeat: false, otherModifiers: false), nowNanos: 0)
        XCTAssertEqual(st.decide(.triggerDown(isRepeat: true, otherModifiers: false), nowNanos: s), .swallow)
        // Still measured from the ORIGINAL press (1.5s), not the repeat — a repeat
        // that restarted the clock would make a long hold look like a fresh tap.
        XCTAssertEqual(st.decide(.triggerUp, nowNanos: s + s / 2),
                       .solo(isHold: true, repeated: true))
    }

    func testResetLeavesNothingStuck() {
        var st = HyperKeyState()
        _ = st.decide(.triggerDown(isRepeat: false, otherModifiers: false), nowNanos: 0)
        XCTAssertTrue(st.isHeld)
        st.reset()
        XCTAssertFalse(st.isHeld)
        XCTAssertEqual(st.decide(.otherKey, nowNanos: s), .pass,
                       "after a reset the next key must NOT carry hyper flags")
    }

    func testStuckHoldWatchdogReleasesAMissedKeyUp() {
        var st = HyperKeyState()
        _ = st.decide(.triggerDown(isRepeat: false, otherModifiers: false), nowNanos: 0)
        // The keyUp never arrived (tap torn down mid-hold). Without the watchdog every
        // later keystroke would silently gain the hyper modifiers, forever.
        XCTAssertEqual(st.decide(.otherKey, nowNanos: HyperKeyState.stuckHoldNanos + 1), .pass)
        XCTAssertFalse(st.isHeld)
    }

    func testTriggerUpWithNoPressIsSwallowedNotCrashed() {
        var st = HyperKeyState()
        XCTAssertEqual(st.decide(.triggerUp, nowNanos: s), .swallow,
                       "the trigger key must never reach an app, press seen or not")
    }

    // MARK: - 2. soloEffect mapping

    func testSoloEffectTable() {
        typealias S = HyperKeyState
        // nothing → never anything, either edge.
        XCTAssertNil(S.soloEffect(action: .nothing, isHold: false, repeated: false))
        XCTAssertNil(S.soloEffect(action: .nothing, isHold: true, repeated: false))
        // escape on a tap; the HOLD edge falls back to the capitals toggle (this is
        // the fallback a later `inputSource` action inherits for free).
        XCTAssertEqual(S.soloEffect(action: .escape, isHold: false, repeated: false), .escape)
        XCTAssertEqual(S.soloEffect(action: .escape, isHold: true, repeated: false), .toggleCapitals)
        // toggleCapitals is edge-independent.
        XCTAssertEqual(S.soloEffect(action: .toggleCapitals, isHold: false, repeated: false), .toggleCapitals)
        XCTAssertEqual(S.soloEffect(action: .toggleCapitals, isHold: true, repeated: false), .toggleCapitals)
        XCTAssertEqual(S.soloEffect(action: .inputSource, isHold: false, repeated: false), .switchInputSource)
        XCTAssertEqual(S.soloEffect(action: .inputSource, isHold: true, repeated: false), .toggleCapitals,
                       "holding an input-source binding still has to be able to lock capitals")
    }

    func testNextInputSourceIDCyclesAndWraps() {
        let ids = ["ABC", "Bulgarian", "Greek"]
        XCTAssertEqual(HyperKeyState.nextInputSourceID(in: ids, current: "ABC"), "Bulgarian")
        XCTAssertEqual(HyperKeyState.nextInputSourceID(in: ids, current: "Greek"), "ABC",
                       "the last source wraps back to the first")
    }

    func testNextInputSourceIDEdges() {
        typealias S = HyperKeyState
        XCTAssertNil(S.nextInputSourceID(in: [], current: nil))
        XCTAssertNil(S.nextInputSourceID(in: ["ABC"], current: "ABC"),
                     "one enabled source: nothing to switch to")
        XCTAssertNil(S.nextInputSourceID(in: ["ABC"], current: nil))
        XCTAssertEqual(S.nextInputSourceID(in: ["ABC", "Greek"], current: nil), "ABC",
                       "unknown current source (an input mode, or a failed read) starts the cycle")
        XCTAssertEqual(S.nextInputSourceID(in: ["ABC", "Greek"], current: ""), "ABC")
    }

    func testRepeatedSuppressesEveryAction() {
        for action in HyperSoloAction.allCases {
            for isHold in [true, false] {
                XCTAssertNil(HyperKeyState.soloEffect(action: action, isHold: isHold, repeated: true),
                             "\(action)/\(isHold): an autorepeating press was held, not tapped")
            }
        }
    }

    // MARK: - 3. Mapping table merge (pure string in → table out)

    /// What `hidutil property --get UserKeyMapping` actually prints: an old-style
    /// plist, repeated once per attached device.
    private let readback = """
    (
        {
            HIDKeyboardModifierMappingDst = 30064771181;
            HIDKeyboardModifierMappingSrc = 30064771129;
        },
        {
            HIDKeyboardModifierMappingDst = 30064771181;
            HIDKeyboardModifierMappingSrc = 30064771129;
        }
    )
    """

    func testDuplicatedPerDeviceReadbackCollapsesToOneEntry() {
        XCTAssertEqual(HyperKeyMapping.parse(readback), [HyperKeyMapping.ours])
    }

    func testParsesHexAndJSONForms() {
        let json = HyperKeyMapping.setJSON([HyperKeyMapping.ours])
        XCTAssertEqual(HyperKeyMapping.parse(json), [HyperKeyMapping.ours])
        let hex = """
        ({HIDKeyboardModifierMappingSrc = 0x700000039; HIDKeyboardModifierMappingDst = 0x70000006D;})
        """
        XCTAssertEqual(HyperKeyMapping.parse(hex), [HyperKeyMapping.ours])
    }

    func testForeignEntrySurvivesEnableAndDisable() {
        // Somebody's own right-⌘ → F13 remap, nothing to do with Caps Lock.
        let foreign = HyperKeyMapping.Entry(src: 0x7000000E7, dst: 0x700000068)
        let enabled = HyperKeyMapping.merged(into: [foreign])
        XCTAssertEqual(enabled, [foreign, HyperKeyMapping.ours])
        XCTAssertEqual(HyperKeyMapping.removed(from: enabled), [foreign],
                       "disabling must remove ONLY our entry")
    }

    func testOurEntryIsAddedOnceAndRemovedOnce() {
        let once = HyperKeyMapping.merged(into: [])
        XCTAssertEqual(HyperKeyMapping.merged(into: once), once, "merge is idempotent")
        XCTAssertEqual(HyperKeyMapping.removed(from: once), [])
        XCTAssertEqual(HyperKeyMapping.removed(from: []), [], "removal is idempotent")
    }

    func testForeignCapsLockDestinationIsReportedAsAConflict() {
        // Caps Lock → Escape, installed by some other tool.
        let theirs = HyperKeyMapping.Entry(src: HyperKeyMapping.capsLockUsage, dst: 0x700000029)
        XCTAssertEqual(HyperKeyMapping.foreignCapsLockDestination([theirs]), 0x700000029)
        XCTAssertNil(HyperKeyMapping.foreignCapsLockDestination([HyperKeyMapping.ours]),
                     "our own mapping is not a conflict")
        XCTAssertNil(HyperKeyMapping.foreignCapsLockDestination([]))
    }

    func testSetJSONShape() {
        XCTAssertEqual(HyperKeyMapping.setJSON([]), "{\"UserKeyMapping\":[]}")
        XCTAssertEqual(
            HyperKeyMapping.setJSON([HyperKeyMapping.ours]),
            "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":30064771129,"
            + "\"HIDKeyboardModifierMappingDst\":30064771181}]}")
    }

    // MARK: - 4. Interaction with the quit guard (#010)

    /// Hyper ADDS flags, so `hyper+Q` builds ⌃⌥⌘⇧Q — a different chord from `cmd+q`.
    /// The quit guard must never see it, and plain ⌘Q must still be guarded.
    @MainActor
    func testHyperQIsNotTheQuitGuardChord() {
        let rules = KeyRuleEngine.decode(json: ShortcutRulesStore.compileJSON([], doubleTapQuit: true))
        let hyperQ = KeyChord(spec: "ctrl+alt+cmd+shift+q")!
        XCTAssertNil(KeyRuleEngine.match(rules: rules, chord: hyperQ, bundleID: nil),
                     "hyper+Q must fall straight through the quit guard")
        XCTAssertNotNil(KeyRuleEngine.match(rules: rules, chord: KeyChord(spec: "cmd+q")!, bundleID: nil),
                        "plain ⌘Q is still guarded")
    }

    // MARK: - 5. Rule engine sees a hyper chord as an ordinary chord

    /// The payoff of running the hyper layer as a pre-pass: `host.keys.set_rules`
    /// needed ZERO changes — a `"from": "ctrl+alt+cmd+shift+h"` rule just works.
    @MainActor
    func testHyperChordResolvesThroughTheExistingRuleEngine() {
        let mgr = ExtensionKeyRules.shared
        mgr.setRules(extensionID: "hyper-test",
                     json: "[{\"from\":\"ctrl+alt+cmd+shift+h\",\"launch\":\"Finder\"}]")
        defer { mgr.setRules(extensionID: "hyper-test", json: "[]") }
        let chord = KeyChord(spec: "ctrl+alt+cmd+shift+h")!
        XCTAssertEqual(mgr.evaluate(chord: chord, bundleID: nil, nowNanos: 1), .launchApp("Finder"))
        // Bare `h` must be untouched — the flags are what select the rule.
        XCTAssertEqual(mgr.evaluate(chord: KeyChord(spec: "h")!, bundleID: nil, nowNanos: 2),
                       .passThrough)
    }

    // MARK: - 6. needKeyTap gains a hyper term

    @MainActor
    func testNeedKeyTapHasAHyperTerm() {
        XCTAssertTrue(AppDelegate.needKeyTap(autocomplete: false, extRules: false, eventTaps: false,
                                             snippets: false, hyper: true, finderShortcuts: false),
                      "the hyper key alone must keep the shared tap up")
        XCTAssertFalse(AppDelegate.needKeyTap(autocomplete: false, extRules: false, eventTaps: false,
                                              snippets: false, hyper: false, finderShortcuts: false))
    }

    // MARK: - Modifier mask

    func testModifierMaskRefusesToClearTheLastModifier() {
        XCTAssertEqual(HyperMods.toggled(HyperMods.cmd, bit: HyperMods.cmd), HyperMods.cmd,
                       "a hyper key with no modifiers does nothing — refuse it")
        XCTAssertEqual(HyperMods.toggled(HyperMods.all, bit: HyperMods.cmd),
                       HyperMods.ctrl | HyperMods.alt | HyperMods.shift)
        XCTAssertEqual(HyperMods.toggled(HyperMods.ctrl, bit: HyperMods.cmd),
                       HyperMods.ctrl | HyperMods.cmd)
    }

    func testModifierMaskToCGEventFlags() {
        XCTAssertEqual(HyperMods.flags(HyperMods.all),
                       [.maskCommand, .maskAlternate, .maskControl, .maskShift])
        XCTAssertEqual(HyperMods.flags(HyperMods.ctrl), [.maskControl])
        XCTAssertEqual(HyperMods.flags(0), [])
        XCTAssertEqual(HyperMods.glyphs(HyperMods.all), "\u{2303}\u{2325}\u{21E7}\u{2318}")
    }
}
