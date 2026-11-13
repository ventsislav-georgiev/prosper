import AppKit
import XCTest
@testable import ProsperApp

/// #1113: the rest of the window shortcut rule (#1102): the calendar popup hotkey, custom runner
/// shortcuts, the paste target a hotkey's refocus picks, and which toggle each hotkey is registered
/// with. Offscreen only, as #1102's rows: no status item, no popover or panel shown, no window ordered
/// front or made key; the shown/focused read is WindowToggle.state and every effect is a recorder.
@MainActor
final class WindowShortcutToggleMoreTests: XCTestCase {

    /// Windows the stubbed state read calls shown / focused.
    private var shown = Set<ObjectIdentifier>()
    private var focused = Set<ObjectIdentifier>()

    /// Swaps the state read for the sets above until teardown.
    private func stubState() {
        nonisolated(unsafe) let live = WindowToggle.state
        WindowToggle.state = { [unowned self] w in
            (shown: self.shown.contains(ObjectIdentifier(w)), focused: self.focused.contains(ObjectIdentifier(w)))
        }
        addTeardownBlock { @MainActor in WindowToggle.state = live }
    }

    private func set(_ w: NSWindow, shown s: Bool, focused f: Bool) {
        if s { shown.insert(ObjectIdentifier(w)) } else { shown.remove(ObjectIdentifier(w)) }
        if f { focused.insert(ObjectIdentifier(w)) } else { focused.remove(ObjectIdentifier(w)) }
    }

    /// The calendar controller's hotkey seams, recorded; restored at teardown. `popup` is returned by
    /// the read while `isShown` says so.
    @MainActor
    private final class CalendarFake {
        let popup = ToggleWindowFake.window()
        var isShown = false
        var ran: [WindowToggle.Effect] = []
    }

    private func fakeCalendar() -> CalendarFake {
        let cal = CalendarBarController.shared
        let f = CalendarFake()
        nonisolated(unsafe) let live = (cal.popupWindow, cal.shortcutEffect)
        cal.popupWindow = { f.isShown ? f.popup : nil }
        cal.shortcutEffect = { effect, win in
            f.ran.append(effect)
            XCTAssertTrue(win === (f.isShown ? f.popup : nil), "the effect gets the window the read returned")
        }
        addTeardownBlock { @MainActor in (cal.popupWindow, cal.shortcutEffect) = live }
        return f
    }

    /// Never activated or asked anything but its pid: an app the user went to.
    private final class OtherApp: NSRunningApplication, @unchecked Sendable {
        override var processIdentifier: pid_t { 4242 }
        override var isTerminated: Bool { false }   // #1121: a kept target that quit is dropped
    }

    /// Fakes the frontmost app and the key window (#1121: nothing key unless a row says so) and starts with
    /// no remembered target; all three are restored at teardown.
    private func fakeFrontmost() {
        nonisolated(unsafe) let live = (WindowToggle.frontmost, WindowToggle.keyWindow, WindowToggle.openedOver)
        addTeardownBlock { @MainActor in
            (WindowToggle.frontmost, WindowToggle.keyWindow, WindowToggle.openedOver) = live
        }
        WindowToggle.keyWindow = { nil }
        WindowToggle.openedOver = nil
    }

    /// #1121: an app with a fake bundle id that a row can quit. Never activated or asked anything else.
    private final class FakeApp: NSRunningApplication, @unchecked Sendable {
        let id: String
        var quit = false
        init(_ id: String) { self.id = id; super.init() }
        override var bundleIdentifier: String? { id }
        override var processIdentifier: pid_t { 4243 }
        override var isTerminated: Bool { quit }
    }

    /// The paste target as a row names it: a fake bundle id, "Prosper window" or "none".
    private func named(_ app: NSRunningApplication?) -> String {
        guard let app else { return "none" }
        return app.processIdentifier == getpid() ? "Prosper window" : app.bundleIdentifier ?? "?"
    }

    /// A Clipboard History whose on and off screen are recorders; never on screen.
    private func quietClipboard() -> ClipboardPanel {
        let cp = ClipboardPanel(store: ClipboardStore(dir: tempDir()))
        let p = cp.panel
        addTeardownBlock { MainActor.assumeIsolated { p.contentView = NSView() } }
        cp.onScreen = { _ in }
        cp.offScreen = { _ in }
        return cp
    }

    // MARK: - Calendar popup (point 1)

    func testCalendarShortcutToggles() {
        stubState()
        let f = fakeCalendar()
        let cal = CalendarBarController.shared

        cal.toggleFromShortcut()
        XCTAssertEqual(f.ran, [.open], "closed: the press opens")

        // The pinned popup the user clicked away from: shown, not key. The press used to close it.
        f.isShown = true
        set(f.popup, shown: true, focused: false)
        cal.toggleFromShortcut()
        XCTAssertEqual(f.ran, [.open, .focus], "shown, not focused: the press makes it key and does not close")

        set(f.popup, shown: true, focused: true)
        cal.toggleFromShortcut()
        XCTAssertEqual(f.ran, [.open, .focus, .close], "focused: the press closes")
        XCTAssertFalse(f.popup.isVisible, "never on screen")
    }

    // MARK: - Custom runner shortcuts (point 3)

    func testCustomShortcutPrefixToggles() throws {
        stubState()
        let rp = RunnerPanel()
        let p = rp.panel
        addTeardownBlock { MainActor.assumeIsolated { p.contentView = NSView() } }
        var on = 0, off = 0
        rp.onScreen = { _ in on += 1 }
        rp.offScreen = { _ in off += 1 }
        // "g " is the one built-in mode prefix (no registry needed); "" is the plain runner.
        let agent = try XCTUnwrap(ModeTrigger.resolve("g ")).mode

        rp.toggle(prefix: "")
        XCTAssertEqual(on, 1, "closed: the press opens")
        XCTAssertEqual(rp.model.mode, .universal)

        rp.model.input = "typed"
        set(p, shown: true, focused: false)
        rp.toggle(prefix: "")
        XCTAssertEqual(on, 2, "showing this prefix, not focused: the press focuses")
        XCTAssertEqual(rp.model.input, "typed", "the query survives a refocus")

        set(p, shown: true, focused: true)
        rp.toggle(prefix: "g ")
        XCTAssertEqual(off, 0, "focused on another prefix: the press does not close")
        XCTAssertEqual(on, 3, "it switches to this prefix")
        XCTAssertEqual(rp.model.mode, agent)
        XCTAssertEqual(rp.model.input, "")

        rp.toggle(prefix: "g ")
        XCTAssertEqual(off, 1, "focused on this prefix: the press closes")
        XCTAssertEqual(on, 3)

        set(p, shown: true, focused: false)
        rp.toggle(prefix: "")
        XCTAssertEqual(on, 4, "not focused, another prefix: it switches too")
        XCTAssertEqual(off, 1)
        XCTAssertEqual(rp.model.mode, .universal)

        set(p, shown: false, focused: false)
        rp.model.input = "stale"
        rp.toggle(prefix: "")
        XCTAssertEqual(on, 5, "closed on this prefix: the press opens")
        XCTAssertEqual(rp.model.input, "", "through present (a fresh query)")
        XCTAssertFalse(p.isVisible, "never on screen")
    }

    /// A fresh runner whose presses are counted; never on screen.
    private func countedRunner() -> (RunnerPanel, on: () -> Int, off: () -> Int) {
        let rp = RunnerPanel()
        let p = rp.panel
        addTeardownBlock { MainActor.assumeIsolated { rp.model.reset(); p.contentView = NSView() } }
        var on = 0, off = 0
        rp.onScreen = { _ in on += 1 }
        rp.offScreen = { _ in off += 1 }
        return (rp, { on }, { off })
    }

    /// QA 844: one shortcut's prefix starting another's (a bound quickdir "qd Dev" on a runner a
    /// "qd Devices" shortcut opened; "g " on one "g x" opened) is another prefix: the press switches.
    func testAPrefixStartingAnotherSwitches() {
        stubState()
        XCTAssertNil(ModeTrigger.resolve("qd Dev"), "no registry: a universal prefill")
        XCTAssertNotNil(ModeTrigger.resolve("g x"), "the built-in agent mode")
        let (rp, on, off) = countedRunner()
        let p = rp.panel
        for (a, b) in [("qd Devices", "qd Dev"), ("qd Dev", "qd Devices"), ("g x", "g "), ("g ", "g x")] {
            set(p, shown: false, focused: false)
            rp.toggle(prefix: a)
            let (on0, off0) = (on(), off())
            XCTAssertEqual(rp.shortcutPrefix, a)

            set(p, shown: true, focused: true)
            rp.toggle(prefix: b)
            XCTAssertEqual(off(), off0, "\(b) on \(a), focused: no close")
            XCTAssertEqual(on(), on0 + 1, "\(b) on \(a), focused: it switches")
            XCTAssertEqual(rp.shortcutPrefix, b)

            set(p, shown: true, focused: false)
            rp.toggle(prefix: a)
            XCTAssertEqual(off(), off0, "\(a) on \(b), not focused: no close")
            XCTAssertEqual(on(), on0 + 2, "\(a) on \(b), not focused: it switches")

            set(p, shown: true, focused: true)
            rp.toggle(prefix: a)
            XCTAssertEqual(off(), off0 + 1, "\(a) on \(a), focused: it closes")
        }

        // The user left the prefix's mode (backspaced out of "g "): the press switches back, no close.
        set(p, shown: false, focused: false)
        rp.toggle(prefix: "g ")
        rp.model.mode = .universal
        set(p, shown: true, focused: true)
        let (on0, off0) = (on(), off())
        rp.toggle(prefix: "g ")
        XCTAssertEqual(off(), off0, "out of the mode: no close")
        XCTAssertEqual(on(), on0 + 1, "it switches")
        XCTAssertEqual(rp.model.mode, ModeTrigger.resolve("g ")?.mode)
        XCTAssertFalse(p.isVisible, "never on screen")
    }

    /// Typing after a prefix keeps it this shortcut's runner: ":" then ":abc", focused, closes.
    func testTypingAfterThePrefixStillCloses() {
        stubState()
        XCTAssertNil(ModeTrigger.resolve(":"), "\":\" has no mode")
        let (rp, on, off) = countedRunner()
        rp.toggle(prefix: ":")
        XCTAssertEqual(on(), 1, "closed: the press opens")
        XCTAssertEqual(rp.model.input, ":")
        rp.model.input = ":abc"
        set(rp.panel, shown: true, focused: true)
        rp.toggle(prefix: ":")
        XCTAssertEqual(off(), 1, "focused on \":abc\": the press closes")
        XCTAssertEqual(on(), 1)

        // Round 3: the prefix deleted and something else typed is no longer this shortcut's runner.
        set(rp.panel, shown: false, focused: false)
        rp.toggle(prefix: ":")
        XCTAssertEqual(on(), 2, "closed: the press opens")
        rp.model.input = "safari"
        set(rp.panel, shown: true, focused: true)
        rp.toggle(prefix: ":")
        XCTAssertEqual(off(), 1, "focused on \"safari\": no close")
        XCTAssertEqual(on(), 3, "it switches back to \":\"")
        XCTAssertEqual(rp.model.input, ":")
    }

    /// Presented any other way (the main hotkey, the status menu), the runner is on no shortcut's
    /// prefix: a prefix press switches, whatever the input.
    func testAnotherPresentPathThenAPrefixSwitches() {
        stubState()
        let (rp, on, off) = countedRunner()
        let p = rp.panel
        let paths: [(String, () -> Void)] = [
            ("the main hotkey", { rp.toggle(mode: .universal, closing: true) }),
            ("the status menu", { rp.toggle(closing: false) }),
        ]
        for (name, path) in paths {
            set(p, shown: false, focused: false)
            rp.toggle(prefix: ":")
            set(p, shown: false, focused: false)
            path()
            XCTAssertNil(rp.shortcutPrefix, "\(name) clears the shortcut's prefix")
            rp.model.input = ":"
            set(p, shown: true, focused: true)
            let (on0, off0) = (on(), off())
            rp.toggle(prefix: ":")
            XCTAssertEqual(off(), off0, "after \(name), focused on \":\": no close")
            XCTAssertEqual(on(), on0 + 1, "it switches")
        }
    }

    // MARK: - Paste target on a hotkey refocus (point 5)

    func testRunnerFocusMovesThePasteTargetToTheAppInFront() {
        fakeFrontmost()
        let rp = RunnerPanel()
        let p = rp.panel
        addTeardownBlock { MainActor.assumeIsolated { p.contentView = NSView() } }
        rp.onScreen = { _ in }
        let other = OtherApp()

        WindowToggle.frontmost = { other }
        rp.focus()
        XCTAssertTrue(rp.previousApp === other, "the app the user went to is the paste target")
        WindowToggle.frontmost = { NSRunningApplication.current }
        rp.focus()
        XCTAssertTrue(rp.previousApp === other, "Prosper itself in front: the target stays")
        WindowToggle.frontmost = { nil }
        rp.focus()
        XCTAssertTrue(rp.previousApp === other, "nothing in front: the target stays")
    }

    func testClipboardFocusMovesThePasteTargetToTheAppInFront() {
        fakeFrontmost()
        let cp = ClipboardPanel(store: ClipboardStore(dir: tempDir()))
        let p = cp.panel
        addTeardownBlock { MainActor.assumeIsolated { p.contentView = NSView() } }
        cp.onScreen = { _ in }
        let other = OtherApp()

        WindowToggle.frontmost = { other }
        cp.focus()
        XCTAssertTrue(cp.previousApp === other, "the app the user went to is the paste target")
        WindowToggle.frontmost = { NSRunningApplication.current }
        cp.focus()
        XCTAssertTrue(cp.previousApp === other, "Prosper itself in front: the target stays")
        WindowToggle.frontmost = { nil }
        cp.focus()
        XCTAssertTrue(cp.previousApp === other, "nothing in front: the target stays")
    }

    /// QA 844, round 3: only a switch press (a present on the key runner, Prosper frontmost because the
    /// runner activated it) keeps the target. Any other present takes the app in front, Prosper
    /// included: a paste from a runner opened over a Prosper window lands in that window, as on main.
    func testRunnerPresentKeepsTheTargetOnlyOnASwitch() {
        fakeFrontmost()
        stubState()
        let (rp, _, _) = countedRunner()
        let settings = ToggleWindowFake.window()
        WindowToggle.frontmost = { NSRunningApplication.current }
        WindowToggle.keyWindow = { settings }
        rp.present()
        XCTAssertEqual(rp.previousApp?.processIdentifier, getpid(), "closed, a Prosper window key: Prosper")
        let other = OtherApp()
        WindowToggle.frontmost = { other }
        rp.toggle(prefix: ":")
        XCTAssertTrue(rp.previousApp === other, "opened from another app: that app")
        WindowToggle.frontmost = { NSRunningApplication.current }
        set(rp.panel, shown: true, focused: true)
        rp.toggle(prefix: "g ")
        XCTAssertTrue(rp.previousApp === other, "a switch press on the key runner: the target stays")
    }

    func testClipboardPresentTakesTheAppInFrontProsperIncluded() {
        fakeFrontmost()
        let cp = ClipboardPanel(store: ClipboardStore(dir: tempDir()))
        let p = cp.panel
        addTeardownBlock { MainActor.assumeIsolated { p.contentView = NSView() } }
        cp.onScreen = { _ in }
        let other = OtherApp()
        WindowToggle.frontmost = { other }
        cp.present()
        XCTAssertTrue(cp.previousApp === other, "opened from another app: that app")
        let settings = ToggleWindowFake.window()
        WindowToggle.frontmost = { NSRunningApplication.current }
        WindowToggle.keyWindow = { settings }
        cp.present()
        XCTAssertEqual(cp.previousApp?.processIdentifier, getpid(), "a Prosper window key: Prosper")
    }

    // MARK: - #1121: which app a paste goes to when Prosper itself is in front

    func testPasteTargetOpenedFromAnotherApp() {
        fakeFrontmost()
        stubState()
        let (rp, _, _) = countedRunner()
        let cp = quietClipboard()
        let editor = FakeApp("com.example.editor")
        WindowToggle.frontmost = { editor }
        rp.toggle(mode: .universal, closing: true)
        XCTAssertEqual(named(rp.previousApp), "com.example.editor")
        cp.toggle(closing: true)
        XCTAssertEqual(named(cp.previousApp), "com.example.editor")
    }

    func testPasteTargetOpenedFromAProsperWindow() {
        fakeFrontmost()
        stubState()
        let (rp, _, _) = countedRunner()
        let cp = quietClipboard()
        WindowToggle.openedOver = FakeApp("com.example.editor")   // an earlier panel's app must not win
        let sessions = ToggleWindowFake.window()
        WindowToggle.frontmost = { NSRunningApplication.current }
        WindowToggle.keyWindow = { sessions }
        rp.toggle(mode: .universal, closing: true)
        XCTAssertEqual(named(rp.previousApp), "Prosper window", "the paste lands in the window the user was in")
        cp.toggle(closing: true)
        XCTAssertEqual(named(cp.previousApp), "Prosper window")
    }

    /// A switch press on the key runner keeps its target even with another app in front (1113 round 3).
    func testPasteTargetSwitchPressKeepsTheTarget() {
        fakeFrontmost()
        stubState()
        let (rp, _, _) = countedRunner()
        WindowToggle.frontmost = { FakeApp("com.example.editor") }
        rp.toggle(prefix: ":")
        XCTAssertEqual(named(rp.previousApp), "com.example.editor")
        set(rp.panel, shown: true, focused: true)
        WindowToggle.frontmost = { NSRunningApplication.current }
        WindowToggle.keyWindow = { rp.panel }
        rp.toggle(prefix: "g ")
        XCTAssertEqual(named(rp.previousApp), "com.example.editor", "Prosper in front because of the runner")
        WindowToggle.frontmost = { FakeApp("com.example.mail") }
        rp.toggle(prefix: ":")
        XCTAssertEqual(named(rp.previousApp), "com.example.editor", "a key runner over another app: kept too")
    }

    func testPasteTargetHotkeyBackAfterTheUserWentToAnotherApp() {
        fakeFrontmost()
        stubState()
        let (rp, on, _) = countedRunner()
        let cp = quietClipboard()
        WindowToggle.frontmost = { FakeApp("com.example.editor") }
        rp.toggle(mode: .universal, closing: true)
        cp.toggle(closing: true)
        WindowToggle.frontmost = { FakeApp("com.example.mail") }
        set(rp.panel, shown: true, focused: false)
        set(cp.panel, shown: true, focused: false)
        rp.toggle(mode: .universal, closing: true)
        XCTAssertEqual(on(), 2, "shown, not key: the hotkey focuses")
        XCTAssertEqual(named(rp.previousApp), "com.example.mail")
        cp.toggle(closing: true)
        XCTAssertEqual(named(cp.previousApp), "com.example.mail")
    }

    /// Point a: the runner left open, the user clicked into Agent Sessions, then the hotkey.
    func testPasteTargetHotkeyBackAfterTheUserWentToAProsperWindow() {
        fakeFrontmost()
        stubState()
        let (rp, on, _) = countedRunner()
        let cp = quietClipboard()
        WindowToggle.frontmost = { FakeApp("com.example.editor") }
        rp.toggle(mode: .universal, closing: true)
        cp.toggle(closing: true)
        let sessions = ToggleWindowFake.window()
        WindowToggle.frontmost = { NSRunningApplication.current }
        WindowToggle.keyWindow = { sessions }
        set(rp.panel, shown: true, focused: false)
        set(cp.panel, shown: true, focused: false)
        rp.toggle(mode: .universal, closing: true)
        XCTAssertEqual(on(), 2, "shown, not key: the hotkey focuses")
        XCTAssertEqual(named(rp.previousApp), "Prosper window")
        cp.toggle(closing: true)
        XCTAssertEqual(named(cp.previousApp), "Prosper window")
    }

    /// Point b: the clipboard hotkey pressed over the runner (no runner row opens Clipboard History).
    func testPasteTargetClipboardOpenedFromTheRunner() {
        fakeFrontmost()
        stubState()
        let (rp, _, _) = countedRunner()
        let cp = quietClipboard()
        WindowToggle.frontmost = { FakeApp("com.example.editor") }
        rp.toggle(mode: .universal, closing: true)
        WindowToggle.frontmost = { NSRunningApplication.current }
        WindowToggle.keyWindow = { rp.panel }
        cp.toggle(closing: true)
        XCTAssertEqual(named(cp.previousApp), "com.example.editor", "the runner key: where the runner would paste")
        // An empty runner closes when it resigns key: nothing key, still the runner's app.
        WindowToggle.keyWindow = { nil }
        cp.present()
        XCTAssertEqual(named(cp.previousApp), "com.example.editor", "the runner gone, nothing key")

        // A runner opened over a Prosper window hands that window over.
        let settings = ToggleWindowFake.window()
        WindowToggle.keyWindow = { settings }
        rp.present()
        XCTAssertEqual(named(rp.previousApp), "Prosper window")
        WindowToggle.keyWindow = { rp.panel }
        cp.present()
        XCTAssertEqual(named(cp.previousApp), "Prosper window")
    }

    /// Point c.
    func testPasteTargetKeptAppQuit() {
        fakeFrontmost()
        stubState()
        let (rp, _, _) = countedRunner()
        let cp = quietClipboard()
        let editor = FakeApp("com.example.editor")
        WindowToggle.frontmost = { editor }
        rp.present()
        XCTAssertEqual(named(rp.previousApp), "com.example.editor")
        editor.quit = true
        WindowToggle.frontmost = { NSRunningApplication.current }
        rp.focus()
        XCTAssertEqual(named(rp.previousApp), "none", "the kept app quit, Prosper in front because of a panel")
        cp.present()
        XCTAssertEqual(named(cp.previousApp), "none")
        WindowToggle.frontmost = { nil }
        rp.focus()
        XCTAssertEqual(named(rp.previousApp), "none", "nothing in front")
        WindowToggle.frontmost = { FakeApp("com.example.mail") }
        rp.focus()
        XCTAssertEqual(named(rp.previousApp), "com.example.mail", "another app in front: that app")
    }

    /// Point d: the hotkey closes the key runner, dismiss() only orders it out, so Prosper stays in front
    /// with nothing key until another app comes forward; a press then opens a fresh runner.
    func testPasteTargetRePressRightAfterAHotkeyClose() {
        fakeFrontmost()
        stubState()
        let (rp, on, off) = countedRunner()
        let cp = quietClipboard()
        WindowToggle.frontmost = { FakeApp("com.example.editor") }
        rp.toggle(mode: .universal, closing: true)
        XCTAssertEqual(on(), 1)
        WindowToggle.frontmost = { NSRunningApplication.current }
        WindowToggle.keyWindow = { rp.panel }
        set(rp.panel, shown: true, focused: true)
        rp.toggle(mode: .universal, closing: true)
        XCTAssertEqual(off(), 1, "key: the hotkey closes")
        WindowToggle.keyWindow = { nil }
        set(rp.panel, shown: false, focused: false)
        rp.toggle(mode: .universal, closing: true)
        XCTAssertEqual(on(), 2, "closed: the re-press opens")
        XCTAssertEqual(named(rp.previousApp), "com.example.editor")
        cp.toggle(closing: true)
        XCTAssertEqual(named(cp.previousApp), "com.example.editor", "Clipboard History in the same moment")
    }

    // MARK: - #1121 round 2: the remembered app holds only while Prosper stayed active

    /// Prosper resigned since the runner was opened over the editor: a Prosper window closed (nothing key),
    /// another non-activating Prosper panel key, or nothing in front all name no app.
    func testPasteTargetDroppedOnceProsperResigned() {
        fakeFrontmost()
        stubState()
        let (rp, _, _) = countedRunner()
        let cp = quietClipboard()
        WindowToggle.frontmost = { FakeApp("com.example.editor") }
        rp.toggle(mode: .universal, closing: true)
        XCTAssertEqual(named(rp.previousApp), "com.example.editor")
        WindowToggle.prosperResignedActive()

        set(rp.panel, shown: true, focused: false)
        WindowToggle.frontmost = { NSRunningApplication.current }
        rp.toggle(mode: .universal, closing: true)
        XCTAssertEqual(named(rp.previousApp), "none", "Prosper in front, nothing key")
        cp.toggle(closing: true)
        XCTAssertEqual(named(cp.previousApp), "none", "Clipboard History the same")

        let island = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        WindowToggle.keyWindow = { island }
        rp.focus()
        XCTAssertEqual(named(rp.previousApp), "none", "another non-activating Prosper panel key")

        WindowToggle.keyWindow = { nil }
        WindowToggle.frontmost = { nil }
        rp.focus()
        XCTAssertEqual(named(rp.previousApp), "none", "nothing in front")

        // A new answer over another app names it, and holds while Prosper stays active.
        WindowToggle.frontmost = { FakeApp("com.example.mail") }
        rp.focus()
        XCTAssertEqual(named(rp.previousApp), "com.example.mail")
        WindowToggle.frontmost = { NSRunningApplication.current }
        cp.focus()
        XCTAssertEqual(named(cp.previousApp), "com.example.mail", "no resign since: still the mail app")
    }

    /// The real observer: a decision installs it; the resign notification drops the remembered app. Posted with
    /// no object, so only observers of every sender see it; nothing is activated or ordered.
    func testPasteTargetResignNotificationDropsTheRememberedApp() {
        fakeFrontmost()
        stubState()
        let (rp, _, _) = countedRunner()
        WindowToggle.frontmost = { FakeApp("com.example.editor") }
        rp.present()
        XCTAssertEqual(named(WindowToggle.openedOver), "com.example.editor")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        // The block runs on the main queue; posted on main it has normally run already. Poll, never a fixed wait.
        let deadline = Date().addingTimeInterval(5)
        while WindowToggle.openedOver != nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(named(WindowToggle.openedOver), "none", "the resign notification drops it")
        WindowToggle.frontmost = { NSRunningApplication.current }
        rp.focus()
        XCTAssertEqual(named(rp.previousApp), "none")
    }

    // MARK: - #1121 rider: a mode reached by typing its prefix (QA 847 INFO-1)

    /// "g " is the built-in stand-in for Translate's "l " (no registry in a test): the user typed it into a
    /// runner the main hotkey opened, so no shortcut presented it.
    func testTypedModePrefixCountsAsTheShortcutsOwn() throws {
        stubState()
        let (rp, on, off) = countedRunner()
        let agent = try XCTUnwrap(ModeTrigger.resolve("g ")).mode
        rp.toggle(mode: .universal, closing: true)
        XCTAssertEqual(on(), 1)
        rp.model.input = "g "
        rp.model.inputChanged()
        XCTAssertEqual(rp.model.mode, agent, "typing the prefix enters its mode")
        XCTAssertTrue(rp.shortcutPrefix == nil, "no shortcut presented it")
        rp.model.input = "fix the build"

        set(rp.panel, shown: true, focused: false)
        rp.toggle(prefix: "g ")
        XCTAssertEqual(on(), 2, "behind another app: the press brings it back")
        XCTAssertEqual(rp.model.input, "fix the build", "with the typed text")
        XCTAssertEqual(rp.model.mode, agent)

        set(rp.panel, shown: true, focused: true)
        rp.toggle(prefix: "g ")
        XCTAssertEqual(off(), 1, "in front: the press closes")
        XCTAssertEqual(on(), 2)
    }

    /// A prefix that leaves text stays another shortcut's (QA 844 F2): typed "g xyz", then "g x" switches.
    func testTypedModeWithAPrefixThatLeavesTextSwitches() {
        stubState()
        let (rp, on, off) = countedRunner()
        rp.toggle(mode: .universal, closing: true)
        rp.model.input = "g xyz"
        rp.model.inputChanged()
        XCTAssertEqual(rp.model.input, "xyz")
        set(rp.panel, shown: true, focused: true)
        rp.toggle(prefix: "g x")
        XCTAssertEqual(off(), 0, "no close")
        XCTAssertEqual(on(), 2, "it switches")
        XCTAssertEqual(rp.model.input, "x", "fresh, on the shortcut's prefill")
    }

    // MARK: - The hotkey hookups (point 5)

    /// Each window hotkey is registered with that surface's toggle: run on a focused window it closes
    /// (a `show` or a `closing: false` would focus instead). The literal list pins which actions open
    /// a window.
    func testEachWindowHotkeyRunsItsToggle() throws {
        stubState()
        let rp = RunnerPanel()
        let cp = ClipboardPanel(store: ClipboardStore(dir: tempDir()))
        let (rpPanel, cpPanel) = (rp.panel, cp.panel)
        addTeardownBlock { MainActor.assumeIsolated { rpPanel.contentView = NSView(); cpPanel.contentView = NSView() } }
        var runnerOn = 0, runnerOff = 0, clipOff = 0
        rp.onScreen = { _ in runnerOn += 1 }
        rp.offScreen = { _ in runnerOff += 1 }
        cp.onScreen = { _ in }
        cp.offScreen = { _ in clipOff += 1 }
        let s = SettingsWindow()
        var settingsBuilt: [NSWindow] = []
        var settingsClosed = 0
        s.build = { let w = ToggleWindowFake.window(); settingsBuilt.append(w); return w }
        s.present = { _ in }
        s.dismissed = { _ in settingsClosed += 1 }
        let chat = fakeChatForToggle()
        let (agents, _) = fakeAgentsForToggle()
        let cal = fakeCalendar()

        func hotkey(_ a: ShortcutAction) -> (() -> Void)? {
            AppDelegate.windowHotkey(a, runner: { rp }, clipboard: { cp }, settings: { s })
        }
        let windowActions: Set<ShortcutAction> = [.runner, .runnerSpace, .runnerBackslash, .translate, .clipboard,
                                                  .settings, .agent, .agentSessions, .calendarTogglePopup]
        XCTAssertEqual(Set(ShortcutAction.allCases.filter { hotkey($0) != nil }), windowActions,
                       "the hotkeys that open a window, and only those")

        set(rpPanel, shown: true, focused: true)
        for a in [ShortcutAction.runner, .runnerSpace, .runnerBackslash] {
            try XCTUnwrap(hotkey(a))()
        }
        XCTAssertEqual(runnerOff, 3, "every runner trigger closes a focused runner")
        XCTAssertEqual(runnerOn, 0)
        // Translate is the "l " prefix's custom shortcut: on a focused plain runner it switches.
        try XCTUnwrap(hotkey(.translate))()
        XCTAssertEqual(runnerOff, 3, "Translate on a focused plain runner does not close it")
        XCTAssertEqual(runnerOn, 1, "it switches to Translate")
        XCTAssertEqual(rp.shortcutPrefix, "l ", "on Translate's prefix")
        try XCTUnwrap(hotkey(.translate))()
        XCTAssertEqual(runnerOff, 4, "focused in Translate: Translate closes")
        try XCTUnwrap(hotkey(.runner))()
        XCTAssertEqual(runnerOff, 5, "the runner trigger closes a focused runner in Translate too")
        set(rpPanel, shown: false, focused: false)
        try XCTUnwrap(hotkey(.translate))()
        XCTAssertEqual(runnerOn, 2, "Translate on a closed runner opens it")
        XCTAssertEqual(rp.shortcutPrefix, "l ", "on Translate's prefix")
        rp.model.reset()   // no debounced query outlives the row

        set(cpPanel, shown: true, focused: true)
        try XCTUnwrap(hotkey(.clipboard))()
        XCTAssertEqual(clipOff, 1, "Clipboard History closes when focused")

        try XCTUnwrap(hotkey(.settings))()
        let settingsWin = try XCTUnwrap(settingsBuilt.last, "Settings closed: the press opens")
        set(settingsWin, shown: true, focused: true)
        try XCTUnwrap(hotkey(.settings))()
        XCTAssertEqual(settingsClosed, 1, "Settings closes when focused")

        try XCTUnwrap(hotkey(.agent))()
        let chatWin = try XCTUnwrap(chat.built.last, "Coding Agent closed: the press opens")
        set(chatWin, shown: true, focused: true)
        try XCTUnwrap(hotkey(.agent))()
        XCTAssertEqual(chat.closes, 1, "Coding Agent closes when focused")

        try XCTUnwrap(hotkey(.agentSessions))()
        let agentsWin = try XCTUnwrap(agents.built.last, "Agent Sessions closed: the press opens")
        set(agentsWin, shown: true, focused: true)
        try XCTUnwrap(hotkey(.agentSessions))()
        XCTAssertEqual(agents.closes, 1, "Agent Sessions closes when focused")

        cal.isShown = true
        set(cal.popup, shown: true, focused: true)
        try XCTUnwrap(hotkey(.calendarTogglePopup))()
        XCTAssertEqual(cal.ran, [.close], "the calendar popup closes when focused, through its own toggle")
    }
}
