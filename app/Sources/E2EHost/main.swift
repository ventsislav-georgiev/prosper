import AppKit
import WebKit

// E2EHost — a tiny standalone dummy GUI app for Prosper's end-to-end tests.
//
// Why it exists: a terminal-launched xctest process cannot become the frontmost
// app on macOS 14+, so synthesized keystrokes never reach its own window. This
// app, launched as a REAL external process, becomes frontmost legitimately and
// presents ONE input field of the kind named by argv[1], focused and ready. It
// models the insertion sites of the apps we care about WITHOUT running them, and
// is reused across e2e suites (snippet expansion, inline autocomplete, …):
//
//   nstextfield     native single-line NSTextField   (most native macOS inputs)
//   nstextview      native rich NSTextView           (TextEdit, Notes, native Telegram)
//   webinput        <input type=text>                (Safari / Chrome form field)
//   webtextarea     <textarea>                       (web compose box)
//   contenteditable Chromium contenteditable div     (Slack / Telegram / Discord Electron)
//
// It has NO IPC: tests drive it with synthesized CGEvents and read back through
// the system-wide AX focused element. For easy debugging it logs a timestamped,
// prefixed transcript to stderr — including a live line for every value change in
// the focused field, so you can watch exactly what landed (and inspect with
// Console.app, `log stream`, or just the test output).

let kind = CommandLine.arguments.dropFirst().first ?? "nstextfield"

/// Timestamped, greppable log. Prefix `[e2e-host <kind> pid=<n>]`. Writes to
/// stderr AND, when `PROSPER_E2E_HOST_LOG` is set, appends to that file — needed
/// because `NSWorkspace.openApplication` detaches the host's stderr from the test
/// runner's pipe, so file logging is the only way to see the transcript.
func hlog(_ message: String) {
    let t = ISO8601DateFormatter().string(from: Date())
    let line = "\(t) [e2e-host \(kind) pid=\(getpid())] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
    if let path = ProcessInfo.processInfo.environment["PROSPER_E2E_HOST_LOG"] {
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// NSTextView that logs the decisive text-input hooks, so e2e can tell whether a
/// synthesized keystroke reaches `keyDown(with:)` and is turned into `insertText`.
final class LoggingTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        hlog("tv.keyDown code=\(event.keyCode) chars=\(AppDelegate.quote(event.characters ?? ""))")
        super.keyDown(with: event)
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        hlog("tv.insertText \(AppDelegate.quote("\(string)"))")
        super.insertText(string, replacementRange: replacementRange)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let kind: String
    var window: NSWindow!
    private var activationTries = 0
    private var firstResponder: NSResponder?
    init(kind: String) { self.kind = kind }

    func applicationDidFinishLaunching(_ note: Notification) {
        hlog("launching (argv=\(CommandLine.arguments))")
        // A standard Edit menu so ⌘V/⌘A/etc. resolve to the focused field — Prosper's
        // compatibility insertion path posts ⌘V, and a menuless app has nothing to
        // dispatch that key-equivalent to (real apps always have an Edit menu).
        installEditMenu()
        window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 420, height: 160),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "e2e-host:\(kind)"

        switch kind {
        case "nstextview":
            let tv = LoggingTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
            tv.isRichText = true; tv.isEditable = true
            window.contentView = tv
            observe(name: NSText.didChangeNotification, object: tv) { [weak tv] in tv?.string ?? "" }
            present(firstResponder: tv)

        case "webinput", "webtextarea", "contenteditable":
            let cfg = WKWebViewConfiguration()
            cfg.userContentController.add(self, name: "changed")
            let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 160), configuration: cfg)
            wv.navigationDelegate = self
            window.contentView = wv
            wv.loadHTMLString(Self.html(kind), baseURL: nil)
            present(firstResponder: nil)   // focus the element after the page loads

        default: // nstextfield
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
            let field = NSTextField(string: "")
            field.frame = NSRect(x: 10, y: 66, width: 400, height: 24)
            container.addSubview(field)
            window.contentView = container
            observe(name: NSControl.textDidChangeNotification, object: field) { [weak field] in field?.stringValue ?? "" }
            present(firstResponder: field)
        }
    }

    /// Install a minimal standard Edit menu so the system can dispatch ⌘X/⌘C/⌘V/⌘A
    /// key-equivalents to the focused field's responder (paste: etc.).
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = mainMenu
    }

    /// Make this a real, frontmost app with `responder` focused.
    private func present(firstResponder responder: NSResponder?) {
        NSApp.setActivationPolicy(.regular)
        // Float above the launching terminal (a fresh `ghostty -e` window is frontmost
        // and would otherwise occlude us — synthetic clicks meant to focus our field
        // would hit the terminal instead) and follow whatever Space the test drives.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        window.makeKeyAndOrderFront(nil)
        if let responder { window.makeFirstResponder(responder) }
        NSApp.activate(ignoringOtherApps: true)
        // Focus-stealing prevention can reject the first activate() when the
        // launching terminal was just frontmost (e.g. `ghostty -e` opening a fresh
        // window). Retry until we actually win key focus, then stop.
        activationTries = 0
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.activationTries += 1
            if NSApp.isActive && self.window.isKeyWindow || self.activationTries > 40 { t.invalidate(); return }
            NSApp.activate(ignoringOtherApps: true)
            self.window.makeKeyAndOrderFront(nil)
            if let responder { self.window.makeFirstResponder(responder) }
        }
        // Pin frontmost for the whole test: Prosper injects accepted completions as
        // keystrokes to whatever app is frontmost, so if we lose focus during the
        // model's think time the injection lands elsewhere and the field never grows.
        // Re-activate the instant we resign active.
        self.firstResponder = responder
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.window.makeKeyAndOrderFront(nil)
            if let r = self.firstResponder { self.window.makeFirstResponder(r) }
        }
        hlog("frontmost; focused=\(responder.map { "\(type(of: $0))" } ?? "web-element") ready")
    }

    /// Log a live transcript line whenever the native field's value changes.
    private func observe(name: Notification.Name, object: Any?, value: @escaping () -> String) {
        NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
            hlog("value=\(Self.quote(value()))")
        }
    }

    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        let id = kind == "contenteditable" ? "ce" : kind
        let prop = kind == "contenteditable" ? "innerText" : "value"
        wv.window?.makeKeyAndOrderFront(nil)
        wv.window?.makeFirstResponder(wv)
        NSApp.activate(ignoringOtherApps: true)
        // Focus the field and post every input event back to us for the transcript.
        wv.evaluateJavaScript("""
            var el = document.getElementById('\(id)');
            el.focus();
            el.addEventListener('input', function () {
                window.webkit.messageHandlers.changed.postMessage(String(el.\(prop)));
            });
            ''
            """)
        hlog("page loaded; focused #\(id) (\(prop))")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "changed" { hlog("value=\(Self.quote("\(message.body)"))") }
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static func html(_ kind: String) -> String {
        let body: String
        switch kind {
        case "webtextarea":
            body = "<textarea id=webtextarea rows=4 style='width:390px'></textarea>"
        case "contenteditable":
            body = "<div id=ce contenteditable=true style='min-height:90px;border:1px solid #888;padding:4px'></div>"
        default:
            body = "<input id=webinput type=text style='width:390px'>"
        }
        return "<!doctype html><html><head><meta charset=utf-8></head>" +
               "<body style='font:14px -apple-system;margin:8px'>\(body)</body></html>"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate(kind: kind)
app.delegate = delegate
hlog("starting run loop")
app.run()
