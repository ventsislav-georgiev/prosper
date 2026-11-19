import AppKit
import XCTest
@testable import ProsperApp

/// #1653: Esc, Command-C or the hotkey closing Clipboard History or the runner gives the keyboard back to the app
/// the panel opened over, not to Prosper's next window (Agent Sessions). Only while Prosper is still the frontmost
/// app, no Prosper window of its own is key and that app is another live one. Offscreen only: the frontmost app,
/// the key window, the on/off-screen calls and the activation are WindowToggle and panel seams a row records; no
/// panel is ordered front or made key and no app is activated.
@MainActor
final class EscapeHandBackTests: XCTestCase {

    /// An app with a fake bundle id and pid that a row can quit. Never activated or asked anything else.
    private final class FakeApp: NSRunningApplication, @unchecked Sendable {
        let id: String
        let pid: pid_t
        var quit = false
        init(_ id: String, pid: pid_t = 4243) { self.id = id; self.pid = pid; super.init() }
        override var bundleIdentifier: String? { id }
        override var processIdentifier: pid_t { pid }
        override var isTerminated: Bool { quit }
    }

    private let browser = FakeApp("com.example.browser")
    private let prosper = FakeApp("com.example.prosper", pid: getpid())
    /// One of Prosper's own titled windows (Agent Sessions) as the key-window seam returns it; never shown.
    private lazy var ownWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled],
                                     backing: .buffered, defer: true)

    /// What happened, in order: "orderOut", "activate <app>", "Cmd-V", "beep".
    private var log: [String] = []

    private nonisolated static func named(_ app: NSRunningApplication) -> String {
        app.processIdentifier == getpid() ? "Prosper" : app.bundleIdentifier ?? "?"
    }

    /// Fakes the world and records the activation (which brings its app to the front, so a paste goes), the
    /// key and the beep; all restored at teardown.
    private func fakeWorld() {
        nonisolated(unsafe) let live = (WindowToggle.frontmost, WindowToggle.keyWindow, WindowToggle.openedOver,
                                        WindowToggle.state)
        nonisolated(unsafe) let seams = (WindowToggle.activate, WindowToggle.sendCommandV, WindowToggle.beep)
        addTeardownBlock { @MainActor in
            (WindowToggle.frontmost, WindowToggle.keyWindow, WindowToggle.openedOver, WindowToggle.state) = live
            (WindowToggle.activate, WindowToggle.sendCommandV, WindowToggle.beep) = seams
        }
        WindowToggle.frontmost = { nil }
        WindowToggle.keyWindow = { nil }
        WindowToggle.openedOver = nil
        WindowToggle.activate = { [unowned self] app in
            log.append("activate \(Self.named(app))")
            WindowToggle.frontmost = { app }
            return true
        }
        WindowToggle.sendCommandV = { [unowned self] in log.append("Cmd-V") }
        WindowToggle.beep = { [unowned self] in log.append("beep") }
    }

    private func clipboard() throws -> (ClipboardPanel, ClipboardItem) {
        let store = ClipboardStore(dir: tempDir())
        store.addText("4")
        let item = try XCTUnwrap(store.items.first)
        let cp = ClipboardPanel(store: store)
        let p = cp.panel
        addTeardownBlock { MainActor.assumeIsolated { p.contentView = NSView() } }
        cp.onScreen = { _ in }
        cp.offScreen = { [unowned self] _ in log.append("orderOut") }
        cp.accessibilityTrusted = { true }
        return (cp, item)
    }

    private func runner() -> RunnerPanel {
        let rp = RunnerPanel()
        let p = rp.panel
        addTeardownBlock { MainActor.assumeIsolated { rp.model.reset(); p.contentView = NSView() } }
        rp.onScreen = { _ in }
        rp.offScreen = { [unowned self] _ in log.append("orderOut") }
        return rp
    }

    /// The panel opens over `front` (its key window `keyAtOpen`), then Prosper is in front with the panel key,
    /// as after the panel's own activation.
    private func open(over front: NSRunningApplication, keyAtOpen: NSWindow? = nil, panel: NSWindow,
                      present: () -> Void) {
        WindowToggle.frontmost = { front }
        WindowToggle.keyWindow = { keyAtOpen }
        present()
        WindowToggle.frontmost = { [prosper] in prosper }
        WindowToggle.keyWindow = { panel }
    }

    // MARK: - Clipboard History

    func testClipboardEscapeHandsBackToTheAppItOpenedOver() throws {
        fakeWorld()
        let (cp, _) = try clipboard()
        open(over: browser, panel: cp.panel) { cp.present() }
        cp.escape()
        XCTAssertEqual(log, ["orderOut", "activate com.example.browser"], "ordered out first, then the browser")
    }

    func testClipboardOpenedOverAProsperWindowActivatesNothing() throws {
        fakeWorld()
        let (cp, _) = try clipboard()
        open(over: prosper, keyAtOpen: ownWindow, panel: cp.panel) { cp.present() }
        XCTAssertEqual(cp.previousApp?.processIdentifier, getpid(), "opened over Agent Sessions: Prosper is the target")
        cp.escape()
        XCTAssertEqual(log, ["orderOut"], "Agent Sessions keeps the keyboard; Prosper is not activated again")
    }

    func testClipboardTargetQuitActivatesNothing() throws {
        fakeWorld()
        let (cp, _) = try clipboard()
        open(over: browser, panel: cp.panel) { cp.present() }
        browser.quit = true
        cp.escape()
        XCTAssertEqual(log, ["orderOut"], "a quit app is never activated")
    }

    func testClipboardProsperNoLongerFrontActivatesNothing() throws {
        fakeWorld()
        let (cp, _) = try clipboard()
        open(over: browser, panel: cp.panel) { cp.present() }
        let editor = FakeApp("com.example.editor", pid: 4244)
        WindowToggle.frontmost = { editor }   // the user went to another app; the non-activating panel stays key
        cp.escape()
        XCTAssertEqual(log, ["orderOut"], "the app the user went to keeps the keyboard")
    }

    func testClipboardOwnWindowMadeKeyActivatesNothing() throws {
        fakeWorld()
        let (cp, _) = try clipboard()
        open(over: browser, panel: cp.panel) { cp.present() }
        WindowToggle.keyWindow = { [ownWindow] in ownWindow }   // the user clicked Agent Sessions meanwhile
        cp.escape()
        XCTAssertEqual(log, ["orderOut"], "the Prosper window the user went to keeps the keyboard")
    }

    func testClipboardCopyOnlyHandsBack() throws {
        fakeWorld()
        let (cp, item) = try clipboard()
        open(over: browser, panel: cp.panel) { cp.present() }
        cp.copyOnly(item)
        XCTAssertEqual(log, ["orderOut", "activate com.example.browser"])
    }

    func testClipboardHotkeyCloseHandsBack() throws {
        fakeWorld()
        let (cp, _) = try clipboard()
        open(over: browser, panel: cp.panel) { cp.present() }
        WindowToggle.state = { _ in (shown: true, focused: true) }   // the hotkey on the key panel closes it
        cp.toggle()
        XCTAssertEqual(log, ["orderOut", "activate com.example.browser"])
    }

    func testClipboardEnterActivatesOnceByThePaste() throws {
        fakeWorld()
        let (cp, item) = try clipboard()
        open(over: browser, panel: cp.panel) { cp.present() }
        cp.commit(item)
        let deadline = Date().addingTimeInterval(5)
        while log.last != "Cmd-V" && log.last != "beep", Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(log, ["orderOut", "activate com.example.browser", "Cmd-V"], "one activation, the paste's")
    }

    // MARK: - The runner

    func testRunnerEscapeHandsBackToTheAppItOpenedOver() {
        fakeWorld()
        let rp = runner()
        open(over: browser, panel: rp.panel) { rp.present() }
        rp.dismissHandingBack()
        XCTAssertEqual(log, ["orderOut", "activate com.example.browser"])
    }

    func testRunnerHotkeyCloseHandsBack() {
        fakeWorld()
        let rp = runner()
        open(over: browser, panel: rp.panel) { rp.present() }
        WindowToggle.state = { _ in (shown: true, focused: true) }
        rp.toggle()
        XCTAssertEqual(log, ["orderOut", "activate com.example.browser"])
    }

    func testRunnerOpenedOverAProsperWindowActivatesNothing() {
        fakeWorld()
        let rp = runner()
        open(over: prosper, keyAtOpen: ownWindow, panel: rp.panel) { rp.present() }
        rp.dismissHandingBack()
        XCTAssertEqual(log, ["orderOut"])
    }

    func testRunnerProsperNoLongerFrontActivatesNothing() {
        fakeWorld()
        let rp = runner()
        open(over: browser, panel: rp.panel) { rp.present() }
        WindowToggle.frontmost = { [browser] in browser }
        rp.dismissHandingBack()
        XCTAssertEqual(log, ["orderOut"])
    }
}
