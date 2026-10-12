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

    /// #389: a real Caps Lock press is always swallowed and triggers the mapping repair at most
    /// once per repairIntervalNanos; this is what heals a failed install.
    func testRealCapsLockRepairsAtMostOncePerInterval() {
        var st = HyperKeyState()
        XCTAssertEqual(st.decide(.realCapsLock, nowNanos: 0), .repairMapping)
        XCTAssertEqual(st.decide(.realCapsLock, nowNanos: HyperKeyState.repairIntervalNanos - 1), .swallow)
        XCTAssertEqual(st.decide(.realCapsLock, nowNanos: HyperKeyState.repairIntervalNanos), .repairMapping)
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

/// #362: the hidutil runner's wait is bounded. The seam points at /bin/sleep and
/// /bin/echo — the real hidutil never runs here.
final class HyperKeyHidutilRunnerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        HyperKey.hidutilBackoffUntil = nil
    }

    override func tearDown() {
        HyperKey.hidutilURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        HyperKey.lastHidutilPID = 0
        HyperKey.hidutilBackoffUntil = nil   // every timeout row arms it
        super.tearDown()
    }

    private func sh(_ script: String, timeout: TimeInterval) -> (out: String?, pid: pid_t, elapsed: TimeInterval) {
        HyperKey.hidutilURL = URL(fileURLWithPath: "/bin/sh")
        HyperKey.lastHidutilPID = 0
        let start = Date()
        let out = HyperKey.hidutil(["-c", script], timeout: timeout)
        return (out, HyperKey.lastHidutilPID, Date().timeIntervalSince(start))
    }

    func testHungChildIsKilledAndRunnerReturnsNilWithinDeadline() {
        HyperKey.hidutilURL = URL(fileURLWithPath: "/bin/sleep")
        HyperKey.lastHidutilPID = 0
        let returned = expectation(description: "runner returned")
        nonisolated(unsafe) var out: String? = "unset"
        let start = Date()
        DispatchQueue.global().async {
            out = HyperKey.hidutil(["612"], timeout: 1)
            returned.fulfill()
        }
        // A hang must fail here, never stall the run.
        wait(for: [returned], timeout: 8)
        XCTAssertNil(out)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        let pid = HyperKey.lastHidutilPID
        XCTAssertGreaterThan(pid, 0)
        let rc = kill(pid, 0), err = errno
        XCTAssertEqual(rc, -1, "the hung child must be gone")
        XCTAssertEqual(err, ESRCH)
    }

    func testHappyPathReturnsStdout() {
        HyperKey.hidutilURL = URL(fileURLWithPath: "/bin/echo")
        XCTAssertEqual(HyperKey.hidutil(["ok"]), "ok\n")
    }

    /// #369 D: a TERM-ignoring child is SIGKILLed through its process group and reaped
    /// before the runner returns. The sleep is a deliberate grandchild: /bin/sh is bash, and
    /// bash does not exec the last command while a trap is set, so sleep runs as a child of
    /// the sh leader. That is what catches a leader-only kill: the leader is gone but the
    /// sleep survives, so killpg(r.pid, 0) still answers 0. Do not change the script to
    /// `exec /bin/sleep` — that removes the grandchild and a leader-only kill would pass.
    /// The earlier shape (#369 D) had an explicitly backgrounded grandchild plus an exec'd
    /// one and caught the broken kill path only 5 of 10 runs (QA #187); #382's shape, 10 of 10.
    func testTermIgnoringGroupIsKilledAndReaped() {
        let r = sh(#"trap "" TERM; /bin/sleep 612"#, timeout: 0.3)
        XCTAssertGreaterThan(r.pid, 1)
        defer { killIfReal(r.pid) }   // only our own group, if an assert fails
        XCTAssertNil(r.out)
        XCTAssertLessThan(r.elapsed, 2.3)
        let rc = kill(r.pid, 0), err = errno
        XCTAssertEqual(rc, -1, "child must be killed and reaped")
        XCTAssertEqual(err, ESRCH)
        XCTAssertEqual(killpg(r.pid, 0), -1, "no member of the child's group may survive")
        // killpg probe: errno is not asserted — Darwin answers EPERM, not ESRCH, for a zombie-only group.
    }

    /// #369 D: SIGTERM goes first — a cooperative child gets to run its TERM trap.
    func testTermIsSentBeforeKill() {
        let marker = tempDir().appendingPathComponent("term")
        let r = sh("trap \"echo T > '\(marker.path)'; exit 0\" TERM; while :; do /bin/sleep 0.05; done", timeout: 0.3)
        defer { killIfReal(r.pid) }
        XCTAssertNil(r.out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the child never saw SIGTERM")
    }

    /// #369 B: after a timeout the runner answers nil without launching until the backoff ends.
    func testTimeoutArmsBackoffThatSkipsLaunches() {
        HyperKey.hidutilURL = URL(fileURLWithPath: "/bin/sleep")
        var pids: [pid_t] = []
        defer { for p in pids where p > 1 && kill(p, 0) == 0 { killIfReal(p, group: false) } }
        XCTAssertNil(HyperKey.hidutil(["613"], timeout: 0.3))
        let first = HyperKey.lastHidutilPID
        pids.append(first)
        XCTAssertGreaterThan(first, 1)
        XCTAssertNotNil(HyperKey.hidutilBackoffUntil)
        let start = Date()
        XCTAssertNil(HyperKey.hidutil(["613"], timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05)
        XCTAssertEqual(HyperKey.lastHidutilPID, first, "nothing may launch during the backoff")
        HyperKey.hidutilBackoffUntil = nil
        XCTAssertNil(HyperKey.hidutil(["613"], timeout: 0.3))
        pids.append(HyperKey.lastHidutilPID)
        XCTAssertNotEqual(HyperKey.lastHidutilPID, first, "a cleared backoff launches again")
    }

    /// #369 A — a SOURCE SCAN, not behaviour: activate/deactivate/wake/tap repair run on
    /// the main actor against Preferences and the live tap, so no pure seam reaches them.
    /// A nil --get must not become an empty table: every read goes through currentTable().
    func testEveryGetSiteSkipsTheSetOnNil() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Extensions/HyperKey.swift"), encoding: .utf8)
        XCTAssertNil(src.range(of: #""--get"[^\n]*\?\? """#, options: .regularExpression),
                     "a nil --get must not fall back to an empty table")
        // Counts --get invocations; hidutil()'s own empty-stdout check names "--get" too (#382).
        XCTAssertEqual(src.components(separatedBy: "\"property\", \"--get\"").count - 1, 1,
                       "--get only inside currentTable()")
        XCTAssertEqual(src.components(separatedBy: "guard let table = Self.currentTable() else").count - 1, 4,
                       "activate, wake, deactivate and tap repair each guard on currentTable()")
    }

    /// #369 C: once the child exits, a grandchild holding stdout costs 0.5 s, not the timeout.
    func testExitedChildWithStdoutHeldReturnsPromptly() {
        let r = sh("/bin/sleep 2 & exit 0", timeout: 5)
        XCTAssertNil(r.out)
        XCTAssertLessThan(r.elapsed, 1.5)
    }

    /// `/bin/sh -c <script> sh property --get UserKeyMapping` — the --get argv reaches hidutil().
    private func get(_ script: String) -> String? {
        HyperKey.hidutilURL = URL(fileURLWithPath: "/bin/sh")
        return HyperKey.hidutil(["-c", script, "sh", "property", "--get", "UserKeyMapping"])
    }

    private let table = "( { HIDKeyboardModifierMappingSrc = 30064771129; HIDKeyboardModifierMappingDst = 30064771181; } )"

    /// #382 L1: a --get that exits non-zero is unreadable even with a valid table on stdout.
    func testNonZeroExitReturnsNil() {
        XCTAssertNotNil(get("echo '\(table)'; exit 0"), "control: the same table with exit 0 reads")
        XCTAssertNil(get("echo '\(table)'; exit 1"))
    }

    /// #382 L1: a --get that exits 0 with nothing on stdout is unreadable, not an empty table.
    func testEmptyGetReturnsNil() {
        XCTAssertNil(get("echo '  '; exit 0"))
    }

    /// #382 L2: quit inside the backoff still makes one attempt — the --get and then the --set.
    @MainActor
    func testClearMappingBypassesBackoff() throws {
        let dir = tempDir()
        let log = dir.appendingPathComponent("calls")
        let stub = dir.appendingPathComponent("hidutil")
        try """
        #!/bin/sh
        echo "$2" >> '\(log.path)'
        [ "$2" = --get ] && echo '\(table)'
        exit 0
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        HyperKey.hidutilURL = stub
        Preferences.defaults.set(true, forKey: HyperKey.markerKey)
        defer { Preferences.defaults.removeObject(forKey: HyperKey.markerKey) }
        HyperKey.hidutilBackoffUntil = Date().addingTimeInterval(60)

        HyperKey.shared.clearMapping()

        let calls = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertEqual(calls.split(separator: "\n"), ["--get", "--set"], "one --get, exactly one --set")
        XCTAssertFalse(Preferences.defaults.bool(forKey: HyperKey.markerKey), "a cleared mapping drops the marker")
    }

    /// #384: a recording stub — the --get answers our table, the --set exits `setExit`.
    /// Rewritable mid-test so cleanup can always succeed.
    private func installSetStub(setExit: Int32, in dir: URL) throws -> URL {
        let log = dir.appendingPathComponent("calls")
        let stub = dir.appendingPathComponent("hidutil")
        try """
        #!/bin/sh
        echo "$2" >> '\(log.path)'
        [ "$2" = --get ] && echo '\(table)' && exit 0
        exit \(setExit)
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        HyperKey.hidutilURL = stub
        return log
    }

    /// Leaves the shared instance off and the marker cleared, whatever the row did.
    @MainActor
    private func resetHyperKey(_ dir: URL, enabled: Bool) {
        _ = try? installSetStub(setExit: 0, in: dir)
        HyperKey.shared.reconcile(tapRunning: false)
        Preferences.hyperKeyEnabled = enabled
        Preferences.defaults.removeObject(forKey: HyperKey.markerKey)
    }

    /// #384: a removal --set that fails keeps the marker, so the next launch recovers.
    @MainActor
    func testFailedRemovalSetKeepsTheMarker() throws {
        let dir = tempDir()
        let log = try installSetStub(setExit: 1, in: dir)
        let enabled = Preferences.hyperKeyEnabled
        defer { resetHyperKey(dir, enabled: enabled) }
        Preferences.defaults.set(true, forKey: HyperKey.markerKey)

        HyperKey.shared.clearMapping()

        let calls = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertEqual(calls.split(separator: "\n"), ["--get", "--set"])
        XCTAssertTrue(Preferences.defaults.bool(forKey: HyperKey.markerKey), "a failed removal keeps the marker")
        XCTAssertFalse(HyperKey.shared.isActive)
    }

    /// #389: an install --set that fails keeps the feature armed (press-driven repair), marker set.
    @MainActor
    func testFailedInstallKeepsTheFeatureArmed() throws {
        let dir = tempDir()
        let log = try installSetStub(setExit: 1, in: dir)
        let enabled = Preferences.hyperKeyEnabled
        defer { resetHyperKey(dir, enabled: enabled) }
        XCTAssertFalse(HyperKey.shared.isActive, "precondition")
        Preferences.hyperKeyEnabled = true

        HyperKey.shared.reconcile(tapRunning: true)

        let calls = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertEqual(calls.split(separator: "\n"), ["--get", "--set"])
        XCTAssertTrue(HyperKey.shared.isActive, "a failed install stays armed so a Caps Lock press repairs it")
        XCTAssertTrue(Preferences.defaults.bool(forKey: HyperKey.markerKey), "write-ahead marker stays")

        HyperKey.shared.reconcile(tapRunning: true)   // already active: activate returns early
        let again = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertEqual(again.split(separator: "\n"), ["--get", "--set"], "reconcile is not the healer")
    }

    /// #384 control: both --set calls succeed — active on install, marker cleared on removal.
    @MainActor
    func testSucceedingSetsActivateThenClearTheMarker() throws {
        let dir = tempDir()
        _ = try installSetStub(setExit: 0, in: dir)
        let enabled = Preferences.hyperKeyEnabled
        defer { resetHyperKey(dir, enabled: enabled) }
        XCTAssertFalse(HyperKey.shared.isActive, "precondition")
        Preferences.hyperKeyEnabled = true

        HyperKey.shared.reconcile(tapRunning: true)
        XCTAssertTrue(HyperKey.shared.isActive)
        XCTAssertTrue(Preferences.defaults.bool(forKey: HyperKey.markerKey))

        HyperKey.shared.reconcile(tapRunning: false)
        XCTAssertFalse(HyperKey.shared.isActive)
        XCTAssertFalse(Preferences.defaults.bool(forKey: HyperKey.markerKey), "a succeeded removal drops the marker")
    }
}
