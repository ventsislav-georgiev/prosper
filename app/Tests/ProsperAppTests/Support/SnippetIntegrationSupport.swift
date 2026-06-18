#if canImport(WebKit)
import AppKit
import ApplicationServices
import CoreGraphics

// Shared primitives for Prosper's out-of-process e2e suites: synthesize real
// keystrokes (`KeySynth`) and read the focused field of ANOTHER process back
// through the system-wide Accessibility element (`FocusedAX`). The fields live in
// the external `E2EHost` app and expansion/autocomplete is driven by the REAL
// Prosper app (see ProsperAppRunner) — nothing here taps events in-process.
//
// Requires a logged-in GUI session with Accessibility trust for the test runner;
// cannot run headless. Suites gate on `PROSPER_E2E=1` + an Accessibility check.

// MARK: - Keystroke synthesis

/// Posts real key events so they flow through the system to the frontmost app's
/// focused field — mirroring a user typing.
enum KeySynth {
    /// US-ANSI keycodes for the characters our test keywords/bodies use. Lowercase
    /// letters, digits, ';', space — none need a shift modifier.
    static let keyCodes: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        ";": 41, " ": 49,
    ]

    /// Types `text` as discrete key-down/up pairs, spinning the run loop between
    /// keys so the (main-run-loop) event tap fires and the field updates in order.
    ///
    /// Each event carries the literal character via `keyboardSetUnicodeString` — NOT
    /// just a virtual keycode. A bare keycode is translated by the RECEIVER using the
    /// active keyboard layout, so on any non-US layout 't' (keycode 17) lands as a
    /// different glyph (we saw keycodes arrive but `chars=""`, and some map to \n/\t).
    /// Attaching the unicode string makes typing layout-independent — the same
    /// technique Prosper's own `typeString` uses. We still pass the mapped keycode
    /// (or 0) so apps that inspect keycodes for shortcuts still see something sane.
    static func type(_ text: String, perKey: TimeInterval = 0.03) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for ch in text {
            let code = keyCodes[ch] ?? 0
            var utf16 = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
                e.flags = []   // a `.combinedSessionState` source merges any physically-held modifier
                               // (e.g. a stuck ⌘) into synthesized events; zero it so plain typing
                               // isn't seen as a ⌘-chord (which the tap treats as non-text).
                e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                e.post(tap: .cgSessionEventTap)
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(perKey))
        }
    }

    /// Posts a single (unmodified) key down/up, spinning the run loop so the
    /// system delivers it and any tap fires. For non-printing keys (Tab, arrows).
    static func tap(_ code: CGKeyCode, perKey: TimeInterval = 0.03) {
        let source = CGEventSource(stateID: .combinedSessionState)
        post(source, code, down: true)
        post(source, code, down: false)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(perKey))
    }

    /// Posts a single key down/up with modifier `flags` held (e.g. Ctrl+` to
    /// force-activate autocomplete). Spins the run loop so the tap sees it.
    static func tap(_ code: CGKeyCode, flags: CGEventFlags, perKey: TimeInterval = 0.03) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cgSessionEventTap)
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(perKey))
    }

    private static func post(_ source: CGEventSource?, _ code: CGKeyCode, down: Bool) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = []   // clear any stray (combined-state) modifier so this reads as a bare key.
        e.post(tap: .cgSessionEventTap)
    }

    /// Clears the focused field before a check so leftover text from a prior case
    /// can't taint the read-back. ⌘A select-all proved unreliable across the field
    /// kinds (native single-line ignored it), so delete by length: read the focused
    /// AX value and press Delete once per character (plus a small margin). Spins the
    /// run loop between keys so they land — and so the app's tap sees each Delete and
    /// keeps its own trigger buffer in sync.
    static func clearFocusedField() {
        let count = (FocusedAX.value()?.count ?? 0) + 4   // margin for AX lag / trailing chars
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            post(source, 51, down: true); post(source, 51, down: false)   // delete
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.012))
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

// MARK: - Cross-process read-back

/// Reads the `AXValue` of the system-wide focused UI element — the way to read
/// back from another process (the `E2EHost` field). Returns nil when the element
/// exposes no string value.
enum FocusedAX {
    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    static func value() -> String? {
        guard let element = focusedElement() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}
#endif
