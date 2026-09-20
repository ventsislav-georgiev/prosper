import Carbon
import CoreGraphics
import XCTest
@testable import ProsperApp

/// Mouse module, entry A: the `com.prosper.mouse` extension shell and the shared
/// `EventTap` lifted out of MenuBarItemMover. No services yet — these cover the
/// two things the later entries build on: the manifest the Settings page reads,
/// and the `dispatch` return contract (the fix that makes pass/mutate possible).
@MainActor
final class MouseTests: XCTestCase {

    // MARK: - Extension shell

    private var extensionsDir: URL {
        URL(fileURLWithPath: #filePath)        // .../Tests/ProsperAppTests/MouseTests.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
    }

    /// Load the shipped extension.toml exactly as the host does. The mouse module
    /// has no Lua logic, so this manifest IS the feature's enable gate, permission
    /// row, and Settings page — a parse failure would silently drop all three.
    func testMouseManifestParses() throws {
        let loaded = try ExtensionLoader.load(directory: extensionsDir.appendingPathComponent("mouse", isDirectory: true),
                                              isSystem: true, hostVersion: "0.0.0")
        XCTAssertEqual(loaded.manifest.extension.id, "com.prosper.mouse")
        XCTAssertEqual(loaded.manifest.extension.isSystem, true)
        // Rewriting mouse input system-wide is opt-in, never on by default.
        XCTAssertEqual(loaded.manifest.extension.defaultDisabled, true)
        // Without this grant CGEvent.tapCreate returns nil silently — the row must
        // be declared so Settings can surface the prompt.
        XCTAssertEqual(loaded.manifest.extension.declaredPermissions, ["accessibility"])

        let section = (loaded.manifest.contributes?.allSettingsSections ?? []).first { $0.id == "mouse" }
        XCTAssertNotNil(section, "mouse settings section missing")
        XCTAssertEqual(section?.accent, "Mouse")
        XCTAssertTrue(section?.allControls.contains { $0.kind == .permission && $0.name == "accessibility" } ?? false,
                      "accessibility permission row missing from the Mouse page")
    }

    /// The bundled registry must discover it alongside the other system shells,
    /// which is what puts the enable/disable switch in Settings › Extensions.
    func testMouseExtensionIsDiscovered() throws {
        let dir = extensionsDir
        try XCTSkipIf(!FileManager.default.fileExists(atPath: dir.path), "no in-repo extensions dir")
        let registry = ExtensionRegistry(
            systemDir: dir,
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-mouse-\(UUID().uuidString)", isDirectory: true),
            hostVersion: "0.0.0")
        registry.discover()
        XCTAssertNotNil(registry.record(id: "com.prosper.mouse"),
                        "com.prosper.mouse must be discovered as a bundled system extension")
    }

    // MARK: - Shared EventTap dispatch contract

    /// A tap whose mach port never got created (no Accessibility grant in the test
    /// process) is still a valid object: `dispatch` calls the callback directly, so
    /// the return contract is testable without any permission.
    private func makeTap(_ callback: @MainActor @escaping (EventTap.Proxy, CGEventType, CGEvent) -> CGEvent?) -> EventTap {
        EventTap(label: "test", options: .listenOnly, location: .session,
                 types: [.scrollWheel], callback: callback)
    }

    /// Regression guard for the lift: `dispatch` used to discard the callback's
    /// return and always swallow. Mouse services need pass-through, so a returned
    /// event must come back out — as the SAME event, not a copy.
    func testDispatchPassesTheCallbackReturnThrough() throws {
        let event = try XCTUnwrap(CGEvent(source: nil))
        let tap = makeTap { _, _, e in e }
        let out = EventTap.dispatch(tap, .scrollWheel, event)
        XCTAssertTrue(out?.takeUnretainedValue() === event, "returned event must reach the system unchanged")
    }

    /// The other half of the contract, and the behaviour the two menu-bar scromble
    /// callbacks rely on: `nil` still swallows.
    func testDispatchSwallowsWhenCallbackReturnsNil() throws {
        let event = try XCTUnwrap(CGEvent(source: nil))
        var sawCallback = false
        let tap = makeTap { _, _, _ in sawCallback = true; return nil }
        XCTAssertNil(EventTap.dispatch(tap, .scrollWheel, event), "nil return must still swallow the event")
        XCTAssertTrue(sawCallback, "callback must run even when the event is swallowed")
    }

    // MARK: - Exception matching (entry C)

    /// A stand-in for `NSWorkspace.runningApplications`.
    private let running: [(pid: pid_t, bundleId: String?)] = [
        (101, "com.apple.Safari"),
        (102, "com.figma.Desktop"),
        (103, nil),                      // pidless-bundle app (an agent, a helper)
    ]

    /// Nothing configured must cost the event tap nothing: `allEmpty` is the flag
    /// the hot path checks before it ever looks up a window.
    func testEmptyListsShortCircuit() {
        let set = MouseExceptionSet(lists: [:], running: running)
        XCTAssertTrue(set.allEmpty)
        for scope in MouseScope.allCases { XCTAssertFalse(set.excludes(101, scope)) }

        // An explicitly-empty list is still empty — a scope key alone must not
        // switch the short-circuit off.
        XCTAssertTrue(MouseExceptionSet(lists: [.navigation: []], running: running).allEmpty)
    }

    /// The whole reason for per-scope lists: excepting an app from one feature
    /// must not except it from the other.
    func testScopesAreIndependent() {
        let set = MouseExceptionSet(lists: [.scrollInvert: ["com.apple.Safari"]], running: running)
        XCTAssertFalse(set.allEmpty)
        XCTAssertTrue(set.excludes(101, .scrollInvert))
        XCTAssertFalse(set.excludes(101, .navigation), "a scroll exception must not disable the side buttons")
    }

    /// Bundle-id matching table: only listed, running apps match — and the match
    /// is exact, never a prefix.
    func testBundleIdMatching() {
        let set = MouseExceptionSet(
            lists: [.navigation: ["com.figma.Desktop", "com.notrunning.app"]],
            running: running)
        let cases: [(pid_t?, Bool, String)] = [
            (102, true, "listed and running"),
            (101, false, "running but not listed"),
            (103, false, "no bundle id"),
            (999, false, "unknown pid"),
            (nil, false, "no window under the pointer / no frontmost app"),
        ]
        for (pid, expected, why) in cases {
            XCTAssertEqual(set.excludes(pid, .navigation), expected, why)
        }
        // "com.notrunning.app" owns no pid, so it can never match — and must not
        // make a bystander match either.
        XCTAssertFalse(set.excludes(0, .navigation))
    }

    /// Prefixes are not matches: `com.figma` must not except `com.figma.Desktop`.
    func testBundleIdMatchIsExact() {
        let set = MouseExceptionSet(lists: [.scrollInvert: ["com.figma"]], running: running)
        XCTAssertFalse(set.excludes(102, .scrollInvert))
    }

    /// Round-trips the per-scope defaults keys the footer writes and the live
    /// wrapper reads, so a key-name drift fails here rather than silently
    /// dropping every exception.
    // MARK: - Scroll inversion

    /// Wheel vs trackpad. `sinceGesture` is seconds since the last phased event.
    func testMouseWheelClassification() {
        let far = ScrollInvert.gestureWindow + 1
        let near = ScrollInvert.gestureWindow / 2
        let cases: [(ScrollFields, CFTimeInterval, Bool, String)] = [
            (ScrollFields(isContinuous: false), 0, true, "discrete tick is always a wheel"),
            (ScrollFields(isContinuous: false, scrollPhase: 1), 0, true,
             "a phased discrete event is still a wheel — discrete is decisive"),
            (ScrollFields(isContinuous: true), far, true, "continuous, unphased, no recent gesture ⇒ Magic Mouse"),
            (ScrollFields(isContinuous: true), near, false, "unphased frame inside a live gesture ⇒ trackpad"),
            (ScrollFields(isContinuous: true, scrollPhase: 2), far, false, "gesture phase ⇒ trackpad"),
            (ScrollFields(isContinuous: true, momentumPhase: 1), far, false, "momentum ⇒ trackpad"),
        ]
        for (f, since, expected, why) in cases {
            XCTAssertEqual(ScrollInvert.isMouseWheel(f, sinceGesture: since), expected, why)
        }
    }

    /// Discrete events must get the LINE deltas only — the window server re-derives
    /// point/fixed deltas from them, so writing both would flip twice.
    func testDiscreteEventWritesLineDeltasOnly() {
        let f = ScrollFields(isContinuous: false, line1: 3, line2: -2,
                             point1: 30, point2: -20, fixed1: 3.5, fixed2: -2.5)
        let w = ScrollInvert.write(f, vertical: true, horizontal: true)
        XCTAssertEqual(w.line1, -3)
        XCTAssertEqual(w.line2, 2)
        XCTAssertNil(w.point1, "writing a pixel delta on a discrete event corrupts it")
        XCTAssertNil(w.point2)
        XCTAssertNil(w.fixed1)
        XCTAssertNil(w.fixed2)
    }

    func testContinuousEventWritesAllThreeUnitFamilies() {
        let f = ScrollFields(isContinuous: true, line1: 1, line2: -1,
                             point1: 12, point2: -8, fixed1: 1.25, fixed2: -0.5)
        let w = ScrollInvert.write(f, vertical: true, horizontal: true)
        XCTAssertEqual(w.line1, -1)
        XCTAssertEqual(w.point1, -12)
        XCTAssertEqual(w.fixed1, -1.25)
        XCTAssertEqual(w.line2, 1)
        XCTAssertEqual(w.point2, 8)
        XCTAssertEqual(w.fixed2, 0.5)
    }

    func testAxesAreIndependent() {
        let f = ScrollFields(isContinuous: true, line1: 5, line2: 7, point1: 50, point2: 70)
        let v = ScrollInvert.write(f, vertical: true, horizontal: false)
        XCTAssertEqual(v.line1, -5)
        XCTAssertNil(v.line2, "horizontal off must leave the horizontal delta alone")
        XCTAssertNil(v.point2)

        let h = ScrollInvert.write(f, vertical: false, horizontal: true)
        XCTAssertNil(h.line1)
        XCTAssertEqual(h.line2, -7)

        let off = ScrollInvert.write(f, vertical: false, horizontal: false)
        XCTAssertTrue(off.isEmpty, "both axes off ⇒ no writes at all")
    }

    /// Double negation is identity, including at Int64.min where `-x` would trap.
    func testNegationIsInvolutiveAndDoesNotTrap() {
        for value: Int64 in [0, 1, -1, 120, Int64.max, Int64.min] {
            let once = ScrollInvert.write(ScrollFields(line1: value), vertical: true, horizontal: false)
            let twice = ScrollInvert.write(ScrollFields(line1: once.line1 ?? 0), vertical: true, horizontal: false)
            XCTAssertEqual(twice.line1, value, "inverting twice must return the original delta")
        }
    }

    /// Regression guard: the mouse module owns its own taps precisely so the
    /// typing-critical keystroke tap never grows a scroll/mouse type. A merge that
    /// widens this mask must fail here rather than in the user's typing latency.
    func testAutocompleteTapMaskIsUnchanged() {
        let expected: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << 14)
        XCTAssertEqual(AutocompleteEngine.tapMask, expected,
                       "the keystroke tap's mask changed — scroll/mouse types belong on the mouse module's own taps")
        XCTAssertEqual(AutocompleteEngine.tapMask & (1 << CGEventType.scrollWheel.rawValue), 0,
                       "scrollWheel must never be on the keystroke tap")
    }

    /// Only the pure decision path is measurable headless — a real tap cannot be
    /// created in a test process, so this bounds classification + negation, not the
    /// CGEvent field reads around them. Ceiling is the plan's 50µs; a pure-Swift
    /// decision landing anywhere near it means the logic grew something it shouldn't.
    func testScrollDecisionHotPathBudget() {
        let f = ScrollFields(isContinuous: true, line1: 1, line2: -1,
                             point1: 12, point2: -8, fixed1: 1.25, fixed2: -0.5)
        for _ in 0..<1_000 { _ = ScrollInvert.write(f, vertical: true, horizontal: true) }

        let n = 200_000
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<n {
            if ScrollInvert.isMouseWheel(f, sinceGesture: 2) {
                _ = ScrollInvert.write(f, vertical: true, horizontal: true)
            }
        }
        let perCall = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(n)
        print("scroll decision hot path: \(String(format: "%.0f", perCall)) ns/call over \(n) iters")
        XCTAssertLessThan(perCall, 50_000, "scroll decision exceeded the 50µs hot-path budget")
    }

    func testScrollInvertPreferencesRoundTrip() {
        let savedV = Preferences.mouseScrollInvertVertical
        let savedH = Preferences.mouseScrollInvertHorizontal
        defer {
            Preferences.mouseScrollInvertVertical = savedV
            Preferences.mouseScrollInvertHorizontal = savedH
        }
        Preferences.mouseScrollInvertVertical = false
        Preferences.mouseScrollInvertHorizontal = true
        XCTAssertFalse(Preferences.mouseScrollInvertVertical)
        XCTAssertTrue(Preferences.mouseScrollInvertHorizontal)
    }

    /// The tap must not exist while the extension is off, whatever the prefs say.
    func testControllerStaysDownWhileExtensionIsOff() {
        let c = ScrollInvertController.shared
        let saved = c.mouseExtLive
        defer { c.mouseExtLive = saved; c.reconcile() }
        c.mouseExtLive = false
        c.reconcile()
        XCTAssertFalse(c.isTapped, "no tap may exist while com.prosper.mouse is disabled")
    }

    func testSideButtonMappingTable() {
        let cases: [(Int64, KeyChord?, String)] = [
            (3, KeyChord(keyCode: Int64(kVK_ANSI_LeftBracket), cmd: true), "button 3 ⇒ ⌘[ Back"),
            (4, KeyChord(keyCode: Int64(kVK_ANSI_RightBracket), cmd: true), "button 4 ⇒ ⌘] Forward"),
            (0, nil, "left button is never remapped"),
            (1, nil, "right button is never remapped"),
            (2, nil, "middle click stays middle click"),
            (5, nil, "extra thumb buttons are left to the app"),
            (31, nil, "high button numbers are left to the app"),
            (-1, nil, "a nonsense button number must not map"),
        ]
        for (button, expected, why) in cases {
            XCTAssertEqual(MouseNavigation.chord(forButton: button), expected, why)
        }
    }

    func testSideButtonChordsCarryCommandOnly() throws {
        for button: Int64 in [3, 4] {
            let chord = try XCTUnwrap(MouseNavigation.chord(forButton: button))
            XCTAssertTrue(chord.cmd)
            XCTAssertFalse(chord.alt || chord.ctrl || chord.shift, "⌘[ / ⌘] take no other modifier")
            XCTAssertNil(chord.mediaCode, "these are keyboard chords, not media keys")
        }
    }

    func testNavigationExceptionsAreFrontmostScoped() {
        // The keystroke goes to the frontmost app, so the frontmost app decides —
        // an app listed only under scrollInvert keeps its side buttons remapped.
        let set = MouseExceptionSet(lists: [.navigation: ["com.apple.Safari"]], running: running)
        XCTAssertTrue(set.excludes(101, .navigation), "listed app must pass its side buttons through")
        XCTAssertFalse(set.excludes(102, .navigation), "an unlisted app keeps the mapping")
        XCTAssertFalse(set.excludes(101, .scrollInvert), "a navigation exception must not touch scrolling")
    }

    func testSideButtonPreferenceRoundTrip() {
        let saved = Preferences.mouseSideButtonNavigation
        defer { Preferences.mouseSideButtonNavigation = saved }
        Preferences.mouseSideButtonNavigation = false
        XCTAssertFalse(Preferences.mouseSideButtonNavigation)
        Preferences.mouseSideButtonNavigation = true
        XCTAssertTrue(Preferences.mouseSideButtonNavigation)
    }

    func testNavigationControllerStaysDownWhileExtensionIsOff() {
        let c = MouseNavigationController.shared
        let saved = c.mouseExtLive
        defer { c.mouseExtLive = saved; c.reconcile() }
        c.mouseExtLive = false
        c.reconcile()
        XCTAssertFalse(c.isTapped, "no tap may exist while com.prosper.mouse is disabled")
    }

    func testPreferencesRoundTripPerScope() {
        let saved = MouseScope.allCases.map { Preferences.mouseExceptions($0) }
        defer {
            for (scope, ids) in zip(MouseScope.allCases, saved) {
                Preferences.setMouseExceptions(ids, for: scope)
            }
        }
        Preferences.setMouseExceptions(["com.apple.Safari"], for: .scrollInvert)
        Preferences.setMouseExceptions([], for: .navigation)
        XCTAssertEqual(Preferences.mouseExceptions(.scrollInvert), ["com.apple.Safari"])
        XCTAssertEqual(Preferences.mouseExceptions(.navigation), [])
    }
}
