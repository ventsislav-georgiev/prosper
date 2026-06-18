#if canImport(WebKit)
import AppKit
import ApplicationServices
import CoreGraphics
import XCTest

/// Launches and drives the external `E2EHost` dummy GUI app — a real frontmost
/// process presenting one input-field kind. Reusable across e2e suites (snippet
/// expansion, inline autocomplete, …): synthesize keystrokes with `KeySynth`,
/// read the focused field back with `focusedValue` (system-wide AX).
///
/// Deliberately `nonisolated` — it touches only `Process` / `FileManager` /
/// `NSWorkspace` / `FocusedAX`, none of them MainActor-bound — so suites can drive
/// it from `tearDown` (a nonisolated override) without "sending self".
final class E2EHost {
    /// Input-field kinds the host can present, each modelling real apps' insertion sites.
    enum Kind: String, CaseIterable {
        case nsTextField = "nstextfield"        // native single-line — most native macOS inputs
        case nsTextView = "nstextview"          // native rich — TextEdit, Notes, native Telegram
        case webInput = "webinput"              // <input>    — Safari / Chrome form field
        case webTextArea = "webtextarea"        // <textarea> — web compose box
        case contentEditable = "contenteditable" // Chromium contenteditable — Slack / Telegram / Discord
    }

    let kind: Kind
    private var runningApp: NSRunningApplication?

    init(_ kind: Kind) { self.kind = kind }

    /// `.build/<config>/E2EHost`, the sibling of the running xctest bundle.
    static func binaryURL() -> URL {
        Bundle(for: E2EHost.self).bundleURL        // …/debug/ProsperPackageTests.xctest
            .deletingLastPathComponent()           // …/debug
            .appendingPathComponent("E2EHost")
    }

    /// Wraps the built `E2EHost` binary in a minimal `.app` next to it and returns
    /// the bundle URL. macOS gives processes NOT launched through LaunchServices a
    /// degraded text-input (TSM) session — `NSTextView`/`NSTextField` silently refuse
    /// to insert `keyboardSetUnicodeString` CGEvents (exactly what Prosper's accept/
    /// expand `typeString` posts). Launching the `.app` via `NSWorkspace` registers it
    /// with LaunchServices, restoring the standard text-input path so synthesized
    /// insertions actually land. Rebuilt each launch so it tracks the fresh binary.
    static func bundleURL() throws -> URL {
        let bin = binaryURL()
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: bin.path),
                          "E2EHost not built at \(bin.path); run `swift build` first.")
        let fm = FileManager.default
        let app = bin.deletingLastPathComponent().appendingPathComponent("E2EHost.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        let exe = macos.appendingPathComponent("E2EHost")
        try? fm.removeItem(at: app)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.copyItem(at: bin, to: exe)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>E2EHost</string>
        <key>CFBundleIdentifier</key><string>com.prosper.e2ehost</string>
        <key>CFBundleName</key><string>E2EHost</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
        <key>CFBundleShortVersionString</key><string>1.0</string>
        <key>LSMinimumSystemVersion</key><string>14.0</string>
        </dict></plist>
        """
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        return app
    }

    /// Launches the host `.app` via LaunchServices (`NSWorkspace.openApplication`) so
    /// it gets a proper TSM session — without it the host silently drops synthesized
    /// unicode insertions. The earlier AX-read-back-returns-nil problem with this path
    /// was really the focus problem (no focused element until frontmost); we now win
    /// and pin focus with a synthetic click (`clickToFocus`) + the host's pin-on-resign,
    /// so AX read-back works. Activates on launch; we still click to win the race vs
    /// the launching `ghostty -e` window.
    func launch() throws {
        let app = try Self.bundleURL()
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.createsNewApplicationInstance = true
        cfg.arguments = [kind.rawValue]
        if let hostLog = ProcessInfo.processInfo.environment["PROSPER_E2E_HOST_LOG"] {
            cfg.environment = ["PROSPER_E2E_HOST_LOG": hostLog]
        }
        let sem = DispatchSemaphore(value: 0)
        var launched: NSRunningApplication?
        var failure: Error?
        NSWorkspace.shared.openApplication(at: app, configuration: cfg) { running, error in
            launched = running; failure = error; sem.signal()
        }
        // Pump the run loop while LaunchServices spins the app up (the completion
        // fires on a background queue).
        let deadline = Date().addingTimeInterval(10)
        while sem.wait(timeout: .now()) == .timedOut, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if let failure { throw failure }
        runningApp = launched
    }

    /// Synthesizes a real mouse click at the center of the host's FOCUSED FIELD. A
    /// click is treated as genuine user interaction, so it raises + focuses the host
    /// window regardless of focus-stealing prevention — the deterministic way to win
    /// focus when a fresh `ghostty -e` window was just activated and `NSApp.activate()`
    /// loses the race. We click the focused element (the field), not the window
    /// center: clicking elsewhere in the window would make the window key but resign
    /// the field's first-responder, so keystrokes wouldn't reach the text. Falls back
    /// to the window center if the focused element isn't exposed yet. Returns false
    /// if neither rect can be read via AX.
    @discardableResult
    func clickToFocus() -> Bool {
        guard let pid = runningApp?.processIdentifier else { return false }
        guard let rect = Self.focusedElementRect(pid: pid) ?? Self.windowRect(pid: pid) else { return false }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            CGEvent(mouseEventSource: source,
                    mouseType: down ? .leftMouseDown : .leftMouseUp,
                    mouseCursorPosition: center, mouseButton: .left)?
                .post(tap: .cgSessionEventTap)
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        return true
    }

    /// Screen rect (Quartz top-left origin) of `el`'s position+size, or nil.
    private static func rect(of el: AXUIElement) -> CGRect? {
        var posVal: CFTypeRef?, sizeVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeVal) == .success
        else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    /// Rect of the host app's focused UI element (the field the host made first
    /// responder), or nil if none is exposed yet.
    private static func focusedElementRect(pid: pid_t) -> CGRect? {
        guard let el = focusedElement(pid: pid) else { return nil }
        return rect(of: el)
    }

    /// The host app's focused UI element via `AXUIElementCreateApplication(pid)` —
    /// the field the host made first responder. Unlike the system-wide focused
    /// element this resolves reliably as soon as the field is first responder, WITHOUT
    /// depending on system frontmost-ness winning a timing race. Used to seed/read the
    /// field deterministically. (Prosper itself still reads via the system-wide element
    /// at trigger time — that works once the host is pinned frontmost, which the host's
    /// pin-on-resign guarantees.)
    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        return (el as! AXUIElement)
    }

    /// Seeds the host field's value + parks the caret at the end, addressing the host
    /// by pid (not the racy system-wide focused element). Returns the value that stuck.
    @discardableResult
    func seed(_ text: String) -> String {
        guard let pid = runningApp?.processIdentifier, let el = Self.focusedElement(pid: pid) else { return "" }
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef)
        var range = CFRange(location: text.utf16.count, length: 0)
        if let axRange = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axRange)
        }
        return readValue() ?? ""
    }

    /// Reads the host field's value by pid (stable read-back, independent of which app
    /// the system considers frontmost at the moment of reading).
    func readValue() -> String? {
        guard let pid = runningApp?.processIdentifier, let el = Self.focusedElement(pid: pid) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// First window's screen rect for `pid`, via the app's AX tree, or nil if no
    /// window is exposed yet.
    private static func windowRect(pid: pid_t) -> CGRect? {
        let appEl = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windows) == .success,
              let arr = windows as? [AXUIElement], let win = arr.first else { return nil }
        return rect(of: win)
    }

    /// True once OUR host is frontmost with a field ready to receive keystrokes.
    /// Clicks the focused field each tick to win focus deterministically, then keys
    /// off `NSWorkspace.frontmostApplication` — the system-wide
    /// `kAXFocusedApplicationAttribute` proved unreliable (returns nil even when the
    /// host is unambiguously frontmost), whereas `frontmostApplication` reports
    /// correctly even from this non-GUI xctest process.
    func waitUntilFocused(timeout: TimeInterval = 6) -> Bool {
        guard let pid = runningApp?.processIdentifier else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            clickToFocus()      // raise + focus the field; no-op until the window exists
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        return false
    }

    /// Current text of the host's focused field, read by pid (stable; see `readValue`).
    var focusedValue: String? { readValue() }

    func stop() {
        guard let app = runningApp else { return }
        runningApp = nil
        if !app.isTerminated { app.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while !app.isTerminated, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if !app.isTerminated { app.forceTerminate() }
    }
}
#endif
