import AppKit
import XCTest
@testable import ProsperApp

/// #1150: the runner and Clipboard History send Command-V only into a live target that was activated and is
/// the frontmost app when the key goes; otherwise nothing is sent, the text stays on the clipboard and the
/// fill-in's beep plays. Offscreen only: the activation, the key and the beep are WindowToggle seams that are
/// nil under XCTest, so a row records them; no panel is ordered front or made key, no app is activated, no key
/// event is posted, and the clipboard is Pasteboard.general (a private per-process pasteboard under XCTest).
@MainActor
final class PasteGuardTests: XCTestCase {

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

    /// What the paste did, in order: "activate <app>", "Cmd-V" or "beep".
    @MainActor private final class Recorder {
        var log: [String] = []
        var activates = true
        var ended: Bool { log.last == "Cmd-V" || log.last == "beep" }
    }

    private nonisolated static func named(_ app: NSRunningApplication?) -> String {
        guard let app else { return "none" }
        return app.processIdentifier == getpid() ? "Prosper" : app.bundleIdentifier ?? "?"
    }

    /// Fakes the frontmost app (nothing), the key window (none) and starts with no remembered target; all
    /// restored at teardown, the paste seams too (nil under XCTest).
    private func fakeWorld() {
        nonisolated(unsafe) let live = (WindowToggle.frontmost, WindowToggle.keyWindow, WindowToggle.openedOver)
        nonisolated(unsafe) let seams = (WindowToggle.activate, WindowToggle.sendCommandV, WindowToggle.beep)
        addTeardownBlock { @MainActor in
            (WindowToggle.frontmost, WindowToggle.keyWindow, WindowToggle.openedOver) = live
            (WindowToggle.activate, WindowToggle.sendCommandV, WindowToggle.beep) = seams
        }
        WindowToggle.frontmost = { nil }
        WindowToggle.keyWindow = { nil }
        WindowToggle.openedOver = nil
    }

    /// Installs recorders for the activation, the key and the beep.
    private func fakePaste() -> Recorder {
        let r = Recorder()
        WindowToggle.activate = { app in r.log.append("activate \(Self.named(app))"); return r.activates }
        WindowToggle.sendCommandV = { r.log.append("Cmd-V") }
        WindowToggle.beep = { r.log.append("beep") }
        return r
    }

    /// Runs the main run loop until the paste sent its key or beeped, 5 s at most (the slowest path is
    /// 0.05 s + frontTries x 0.05 s). Never a fixed wait.
    private func waitForTheEnd(_ r: Recorder) {
        let deadline = Date().addingTimeInterval(5)
        while !r.ended, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// One panel as a row drives it: open (the paste target decision), Enter on "4", the target it kept.
    private struct Side {
        let present: () -> Void
        let commit: () -> Void
        let target: () -> NSRunningApplication?
    }

    private func runner() -> Side {
        let rp = RunnerPanel()
        let p = rp.panel
        addTeardownBlock { MainActor.assumeIsolated { rp.model.reset(); p.contentView = NSView() } }
        rp.onScreen = { _ in }
        rp.offScreen = { _ in }
        return Side(present: { rp.present() }, commit: { rp.commit("4") }, target: { rp.previousApp })
    }

    private func clipboard() throws -> Side {
        let store = ClipboardStore(dir: tempDir())
        store.addText("4")
        let item = try XCTUnwrap(store.items.first)
        let cp = ClipboardPanel(store: store)
        let p = cp.panel
        addTeardownBlock { MainActor.assumeIsolated { p.contentView = NSView() } }
        cp.onScreen = { _ in }
        cp.offScreen = { _ in }
        cp.accessibilityTrusted = { true }
        return Side(present: { cp.present() }, commit: { cp.commit(item) }, target: { cp.previousApp })
    }

    /// Opens `side` with `front` in front, then runs `before` (what changes between the open and Enter), Enter,
    /// and waits for the end. Returns the log; the clipboard must hold "4" whatever happened.
    private func paste(_ side: Side, openedOver front: NSRunningApplication?, expectTarget: String,
                       keyAtOpen: NSWindow? = nil, before: () -> Void = {}, activates: Bool = true) -> [String] {
        fakeWorld()
        let r = fakePaste()
        r.activates = activates
        WindowToggle.frontmost = { front }
        WindowToggle.keyWindow = { keyAtOpen }
        side.present()
        XCTAssertEqual(Self.named(side.target()), expectTarget)
        Pasteboard.general.clearContents()
        before()
        side.commit()
        waitForTheEnd(r)
        XCTAssertEqual(Pasteboard.general.string(forType: .string), "4", "the text is on the clipboard either way")
        return r.log
    }

    // MARK: - No target: nothing in front when the panel opened, nothing remembered

    func testRunnerNilTargetSendsNoKey() {
        let editor = FakeApp("com.example.editor")
        let log = paste(runner(), openedOver: nil, expectTarget: "none", before: { WindowToggle.frontmost = { editor } })
        XCTAssertEqual(log, ["beep"], "no target: no activation, no key, even with another app in front by Enter")
    }

    func testClipboardNilTargetSendsNoKey() throws {
        let editor = FakeApp("com.example.editor")
        let log = paste(try clipboard(), openedOver: nil, expectTarget: "none",
                        before: { WindowToggle.frontmost = { editor } })
        XCTAssertEqual(log, ["beep"], "no target: no activation, no key, even with another app in front by Enter")
    }

    // MARK: - The target quit between the open and Enter

    func testRunnerQuitTargetSendsNoKey() {
        let editor = FakeApp("com.example.editor")
        let log = paste(runner(), openedOver: editor, expectTarget: "com.example.editor", before: { editor.quit = true })
        XCTAssertEqual(log, ["beep"], "a quit target is not even activated")
    }

    func testClipboardQuitTargetSendsNoKey() throws {
        let editor = FakeApp("com.example.editor")
        let log = paste(try clipboard(), openedOver: editor, expectTarget: "com.example.editor",
                        before: { editor.quit = true })
        XCTAssertEqual(log, ["beep"], "a quit target is not even activated")
    }

    // MARK: - The activation answers false (r2: the answer is not trusted; the frontmost polls decide)

    func testRunnerFalseAnswerTargetInFrontGetsTheKey() {
        let editor = FakeApp("com.example.editor")
        let log = paste(runner(), openedOver: editor, expectTarget: "com.example.editor", activates: false)
        XCTAssertEqual(log, ["activate com.example.editor", "Cmd-V"])
    }

    func testClipboardFalseAnswerTargetInFrontGetsTheKey() throws {
        let editor = FakeApp("com.example.editor")
        let log = paste(try clipboard(), openedOver: editor, expectTarget: "com.example.editor", activates: false)
        XCTAssertEqual(log, ["activate com.example.editor", "Cmd-V"])
    }

    func testRunnerFalseAnswerAnotherAppInFrontSendsNoKey() {
        let editor = FakeApp("com.example.editor")
        let mail = FakeApp("com.example.mail", pid: 4244)
        let log = paste(runner(), openedOver: editor, expectTarget: "com.example.editor",
                        before: { WindowToggle.frontmost = { mail } }, activates: false)
        XCTAssertEqual(log, ["activate com.example.editor", "beep"])
    }

    func testClipboardFalseAnswerAnotherAppInFrontSendsNoKey() throws {
        let editor = FakeApp("com.example.editor")
        let mail = FakeApp("com.example.mail", pid: 4244)
        let log = paste(try clipboard(), openedOver: editor, expectTarget: "com.example.editor",
                        before: { WindowToggle.frontmost = { mail } }, activates: false)
        XCTAssertEqual(log, ["activate com.example.editor", "beep"])
    }

    func testRunnerFalseAnswerProsperWithItsOwnWindowKeyGetsTheKey() {
        let settings = ToggleWindowFake.window()
        let log = paste(runner(), openedOver: NSRunningApplication.current, expectTarget: "Prosper",
                        keyAtOpen: settings, activates: false)
        XCTAssertEqual(log, ["activate Prosper", "Cmd-V"])
    }

    func testClipboardFalseAnswerProsperWithItsOwnWindowKeyGetsTheKey() throws {
        let settings = ToggleWindowFake.window()
        let log = paste(try clipboard(), openedOver: NSRunningApplication.current, expectTarget: "Prosper",
                        keyAtOpen: settings, activates: false)
        XCTAssertEqual(log, ["activate Prosper", "Cmd-V"])
    }

    // MARK: - Activated, but another app is frontmost when the key would go

    func testRunnerTargetNotFrontmostSendsNoKey() {
        let editor = FakeApp("com.example.editor")
        let mail = FakeApp("com.example.mail", pid: 4244)
        let log = paste(runner(), openedOver: editor, expectTarget: "com.example.editor",
                        before: { WindowToggle.frontmost = { mail } })
        XCTAssertEqual(log, ["activate com.example.editor", "beep"])
    }

    func testClipboardTargetNotFrontmostSendsNoKey() throws {
        let editor = FakeApp("com.example.editor")
        let mail = FakeApp("com.example.mail", pid: 4244)
        let log = paste(try clipboard(), openedOver: editor, expectTarget: "com.example.editor",
                        before: { WindowToggle.frontmost = { mail } })
        XCTAssertEqual(log, ["activate com.example.editor", "beep"])
    }

    // MARK: - A live target: one key, after the activation

    func testRunnerLiveTargetGetsOneKeyAfterTheActivation() {
        let editor = FakeApp("com.example.editor")
        let log = paste(runner(), openedOver: editor, expectTarget: "com.example.editor")
        XCTAssertEqual(log, ["activate com.example.editor", "Cmd-V"])
    }

    func testClipboardLiveTargetGetsOneKeyAfterTheActivation() throws {
        let editor = FakeApp("com.example.editor")
        let log = paste(try clipboard(), openedOver: editor, expectTarget: "com.example.editor")
        XCTAssertEqual(log, ["activate com.example.editor", "Cmd-V"])
    }

    // MARK: - Prosper itself (#1121: one of its own windows was key): one of them must be key again

    private func prosperTarget(_ make: () throws -> Side) rethrows -> [String] {
        let settings = ToggleWindowFake.window()
        let runnerPanel = RunnerPanel().panel   // a non-activating panel, never shown
        addTeardownBlock { MainActor.assumeIsolated { runnerPanel.contentView = NSView() } }
        var logs: [String] = []
        for key in [nil, runnerPanel, settings] as [NSWindow?] {
            let log = paste(try make(), openedOver: NSRunningApplication.current, expectTarget: "Prosper",
                            keyAtOpen: settings, before: { WindowToggle.keyWindow = { key } })
            logs.append(log.joined(separator: ", "))
        }
        return logs
    }

    func testRunnerProsperTargetNeedsItsOwnWindowKey() {
        XCTAssertEqual(prosperTarget { runner() }, [
            "activate Prosper, beep",     // nothing key after the runner hid: the key would land nowhere
            "activate Prosper, beep",     // a non-activating panel key: not the window the user was in
            "activate Prosper, Cmd-V",    // a Prosper window key again
        ])
    }

    func testClipboardProsperTargetNeedsItsOwnWindowKey() throws {
        XCTAssertEqual(try prosperTarget { try clipboard() }, [
            "activate Prosper, beep",
            "activate Prosper, beep",
            "activate Prosper, Cmd-V",
        ])
    }

    // MARK: - No fake installed: the real activation and key sender do not exist under XCTest

    /// Only the beep is recorded (it is how a row sees the end). The activation and the key are left as the
    /// app built them: nil under XCTest, so the paste has nothing to activate or send with whatever it decides;
    /// a nil activation seam ends the paste in the beep.
    func testWithNoFakeNothingIsActivatedOrSent() {
        fakeWorld()
        XCTAssertTrue(WindowToggle.activate == nil, "the real activation is not installed under XCTest")
        XCTAssertTrue(WindowToggle.sendCommandV == nil, "the real Command-V is not installed under XCTest")
        let r = Recorder()
        WindowToggle.beep = { r.log.append("beep") }
        let editor = FakeApp("com.example.editor")
        WindowToggle.frontmost = { editor }
        let side = runner()
        side.present()
        XCTAssertEqual(Self.named(side.target()), "com.example.editor")
        side.commit()
        waitForTheEnd(r)
        XCTAssertEqual(r.log, ["beep"], "no activation seam: the paste ends without a key")
        XCTAssertTrue(WindowToggle.activate == nil && WindowToggle.sendCommandV == nil, "still nothing installed")
    }

    // MARK: - R1150-1: Prosper becoming active by anything but a panel drops the remembered app

    func testBecomingActiveDropsTheRememberedAppUnlessAPanelIsKey() {
        fakeWorld()
        let side = runner()
        let runnerPanel = RunnerPanel().panel
        addTeardownBlock { MainActor.assumeIsolated { runnerPanel.contentView = NSView() } }
        let settings = ToggleWindowFake.window()
        var seen: [String] = []
        for key in [runnerPanel, nil, settings] as [NSWindow?] {
            WindowToggle.keyWindow = { nil }
            WindowToggle.frontmost = { FakeApp("com.example.editor") }
            side.present()
            WindowToggle.keyWindow = { key }
            WindowToggle.prosperBecameActive()
            WindowToggle.frontmost = { NSRunningApplication.current }
            WindowToggle.keyWindow = { nil }
            side.present()   // Prosper in front, nothing key: the remembered app or none
            seen.append(Self.named(side.target()))
        }
        XCTAssertEqual(seen, [
            "com.example.editor",   // a panel's own activation (the runner key): kept
            "none",                 // the Dock icon, nothing key: dropped
            "none",                 // a Settings window key: dropped
        ])
    }

    /// The real observer: a decision installs it; the became-active notification with a Prosper window key drops
    /// the remembered app. Posted with no object; nothing is activated or ordered.
    func testBecameActiveNotificationDropsTheRememberedApp() {
        fakeWorld()
        let side = runner()
        WindowToggle.frontmost = { FakeApp("com.example.editor") }
        side.present()
        XCTAssertEqual(Self.named(WindowToggle.openedOver), "com.example.editor")
        let settings = ToggleWindowFake.window()
        WindowToggle.keyWindow = { settings }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let deadline = Date().addingTimeInterval(5)
        while WindowToggle.openedOver != nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(Self.named(WindowToggle.openedOver), "none")
    }
}
