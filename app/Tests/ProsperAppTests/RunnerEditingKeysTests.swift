import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #702: every standard text-editing key reaches the runner input's field editor,
/// and the runner's own bindings stay consumed. In-process only: offscreen windows
/// that are never ordered front or made key, no monitor installed, no posted
/// event — `NSEvent.keyEvent` handed to the monitor's closure, then to the
/// window's key-equivalent pass, then to the window (the order NSApp uses).
/// ⌘A/⌘C/⌘V/⌘X/⌘Z/⇧⌘Z are AppKit-owned (the Edit menu, AppDelegate) and are only
/// checked to pass the monitor untouched — copy/paste would write the pasteboard.
@MainActor
final class RunnerEditingKeysTests: XCTestCase {

    // MARK: - Harness

    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        super.tearDown()
    }

    private func offscreenWindow(_ content: NSView) -> NSWindow {
        content.frame = CGRect(x: 0, y: 0, width: 600, height: 120)
        let w = NSWindow(contentRect: content.frame, styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = content
        windows.append(w)
        return w
    }

    private func flush(_ v: NSView) {
        v.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        v.layoutSubtreeIfNeeded()
    }

    /// A key as a hardware keyboard produces it: `ign` is what the key binding
    /// manager reads (⌃A is "\u{01}" / "a"), arrows carry numericPad+function.
    private struct Key {
        let name: String, code: UInt16, chars: String, ign: String
        let mods: NSEvent.ModifierFlags
        init(_ name: String, _ code: UInt16, _ chars: String, _ ign: String? = nil,
             _ mods: NSEvent.ModifierFlags) {
            self.name = name; self.code = code; self.chars = chars
            self.ign = ign ?? chars; self.mods = mods
        }
    }

    private func event(_ k: Key, window: NSWindow, repeating: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: k.mods,
                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                         characters: k.chars, charactersIgnoringModifiers: k.ign,
                         isARepeat: repeating, keyCode: k.code)!
    }

    private static func fn(_ scalar: Int) -> String { String(UnicodeScalar(scalar)!) }
    private static let up = fn(NSUpArrowFunctionKey), down = fn(NSDownArrowFunctionKey)
    private static let left = fn(NSLeftArrowFunctionKey), right = fn(NSRightArrowFunctionKey)
    private static let fwd = fn(NSDeleteFunctionKey)
    private static let A: NSEvent.ModifierFlags = [.numericPad, .function]
    private static let bs = "\u{7F}"   // what NSEvent carries for ⌫, any modifier

    private static func r(_ loc: Int, _ len: Int = 0) -> NSRange { NSRange(location: loc, length: len) }

    /// The audit list (entry #702) with each key's expected effect on
    /// "hello world" from a caret at `at`: (text after, selection after).
    private static let editing: [(Key, at: Int, text: String, sel: NSRange)] = [
        (Key("⌘⌫", 51, bs, nil, .command), 11, "", r(0)),
        (Key("⌥⌫", 51, bs, nil, .option), 11, "hello ", r(6)),
        (Key("⌫", 51, bs, nil, []), 11, "hello worl", r(10)),
        (Key("fn-⌫ / ⌦", 117, fwd, nil, .function), 0, "ello world", r(0)),
        (Key("⌥⌦", 117, fwd, nil, [.function, .option]), 0, " world", r(0)),
        (Key("⌃A", 0, "\u{01}", "a", .control), 11, "hello world", r(0)),
        (Key("⌃E", 14, "\u{05}", "e", .control), 0, "hello world", r(11)),
        (Key("⌃K", 40, "\u{0B}", "k", .control), 5, "hello", r(5)),
        (Key("⌃H", 4, "\u{08}", "h", .control), 11, "hello worl", r(10)),
        (Key("⌃D", 2, "\u{04}", "d", .control), 0, "ello world", r(0)),
        (Key("⌘←", 123, left, nil, A.union(.command)), 11, "hello world", r(0)),
        (Key("⌘→", 124, right, nil, A.union(.command)), 0, "hello world", r(11)),
        (Key("⌥←", 123, left, nil, A.union(.option)), 11, "hello world", r(6)),
        (Key("⌥→", 124, right, nil, A.union(.option)), 0, "hello world", r(5)),
        (Key("⌘↑", 126, up, nil, A.union(.command)), 11, "hello world", r(0)),
        (Key("⌘↓", 125, down, nil, A.union(.command)), 0, "hello world", r(11)),
        // Beyond the list, same guard: ⌥↑/⌥↓ paragraph moves, ⌃↑/⌃↓ (Mission
        // Control system-wide by default) must not move rows either.
        (Key("⌥↑", 126, up, nil, A.union(.option)), 11, "hello world", r(0)),
        (Key("⌥↓", 125, down, nil, A.union(.option)), 0, "hello world", r(11)),
        (Key("⌃↑", 126, up, nil, A.union(.control)), 5, "hello world", r(5)),
        (Key("⌃↓", 125, down, nil, A.union(.control)), 5, "hello world", r(5)),
        (Key("⇧⌘←", 123, left, nil, A.union([.shift, .command])), 11, "hello world", r(0, 11)),
        (Key("⇧⌘→", 124, right, nil, A.union([.shift, .command])), 0, "hello world", r(0, 11)),
        (Key("⇧⌥←", 123, left, nil, A.union([.shift, .option])), 11, "hello world", r(6, 5)),
        (Key("⇧⌥→", 124, right, nil, A.union([.shift, .option])), 0, "hello world", r(0, 5)),
        (Key("⇧⌘↑", 126, up, nil, A.union([.shift, .command])), 11, "hello world", r(0, 11)),
        (Key("⇧⌘↓", 125, down, nil, A.union([.shift, .command])), 0, "hello world", r(0, 11)),
        (Key("⇧←", 123, left, nil, A.union(.shift)), 11, "hello world", r(10, 1)),
        (Key("⇧→", 124, right, nil, A.union(.shift)), 0, "hello world", r(0, 1)),
        (Key("⇧↑", 126, up, nil, A.union(.shift)), 11, "hello world", r(0, 11)),
        (Key("⇧↓", 125, down, nil, A.union(.shift)), 0, "hello world", r(0, 11)),
        (Key("⌃⇧A", 0, "\u{01}", "A", [.control, .shift]), 11, "hello world", r(0, 11)),
        (Key("⌃⇧E", 14, "\u{05}", "E", [.control, .shift]), 0, "hello world", r(0, 11)),
    ]

    /// AppKit-owned through the Edit menu; the monitor must not touch them.
    private static let menuOwned: [Key] = [
        Key("⌘A", 0, "a", nil, .command), Key("⌘C", 8, "c", nil, .command),
        Key("⌘V", 9, "v", nil, .command), Key("⌘X", 7, "x", nil, .command),
        Key("⌘Z", 6, "z", nil, .command), Key("⇧⌘Z", 6, "z", "Z", [.shift, .command]),
    ]

    // MARK: - Monitor fixture

    private final class Calls { var log: [String] = [] }

    private func monitor(for w: NSWindow, emptyLockedField: Bool = false, calls: Calls)
        -> RunnerKeyHandling.Coordinator {
        let c = RunnerKeyHandling.Coordinator()
        c.handlers = .init(
            cancel: { calls.log.append("cancel") },
            commit: { calls.log.append("commit") },
            deleteWhenEmpty: { calls.log.append("deleteWhenEmpty"); return emptyLockedField },
            clear: { calls.log.append("clear") },
            secondary: { calls.log.append("secondary") },
            tertiary: { calls.log.append("tertiary") },
            quickLook: { calls.log.append("quickLook") },
            number: { calls.log.append("number\($0)") })
        c.window = w
        return c
    }

    // MARK: - The runner input, end to end

    /// The input field and the action bar, as the runner composes them.
    private struct InputHarness: View {
        @State var text = "hello world"
        @FocusState var focused: Bool
        let quicklink: QuicklinkHit?
        let log: (String) -> Void
        var body: some View {
            VStack {
                GatedField(placeholder: "", textValue: text, text: $text, focus: $focused,
                           onChange: {}, onSubmit: { log("submit") },
                           onUp: { log("up") }, onDown: { log("down") })
                ActionMenuButton(quicklink: quicklink, assignTarget: nil,
                                 onCopy: { log("copy") }, onEdit: { _ in log("edit") },
                                 onDelete: { _ in log("delete") },
                                 onAssignShortcut: { _ in log("assign") })
            }
            .onAppear { focused = true }
        }
    }

    private struct Input {
        let window: NSWindow, host: NSView, editor: NSTextView
        let monitor: RunnerKeyHandling.Coordinator, calls: Calls
    }

    private func input(quicklink: QuicklinkHit? = nil) throws -> Input {
        let calls = Calls()
        let host = NSHostingView(rootView: InputHarness(quicklink: quicklink,
                                                        log: { calls.log.append($0) }))
        let w = offscreenWindow(host)
        flush(host)
        let editor = try XCTUnwrap(w.firstResponder as? NSTextView,
                                   "the field editor is not first responder")
        return Input(window: w, host: host, editor: editor,
                     monitor: monitor(for: w, calls: calls), calls: calls)
    }

    /// NSApp's order for a keyDown: local monitor, key equivalents, the window.
    private func press(_ k: Key, in i: Input, repeating: Bool = false) {
        guard let e = i.monitor.monitorHandler(event(k, window: i.window, repeating: repeating))
        else { flush(i.host); return }
        if !i.window.performKeyEquivalent(with: e) { i.window.sendEvent(e) }
        flush(i.host)
    }

    private func reset(_ i: Input, caret: Int) {
        i.editor.string = "hello world"
        i.editor.setSelectedRange(NSRange(location: caret, length: 0))
        i.calls.log = []
    }

    /// Every audit key does in the runner input what it does in any NSTextField,
    /// and fires no runner action. Fails at 4d4fd13 on ⌘↑/⌘↓ and the ⇧ arrow
    /// variants (eaten as row moves by `.onKeyPress`).
    func testEveryEditingKeyEditsTheRunnerInput() throws {
        for hit in [nil, QuicklinkHit(name: "gh", target: "https://github.com", description: "")] {
            let i = try input(quicklink: hit)
            for (k, at, text, sel) in Self.editing {
                reset(i, caret: at)
                press(k, in: i)
                let ctx = "\(k.name) (quicklink row: \(hit != nil))"
                XCTAssertEqual(i.editor.string, text, ctx)
                XCTAssertEqual(i.editor.selectedRange(), sel, ctx)
                // ⌫ variants ask deleteWhenEmpty (false: the field has text); that
                // query is not an action.
                XCTAssertEqual(i.calls.log.filter { $0 != "deleteWhenEmpty" }, [],
                               "\(ctx) fired a runner action")
            }
        }
    }

    /// ⌘⌫ is the field's, never a key equivalent — in the form NSEvent delivers
    /// (U+007F) and in the layout's own U+0008 (what the keyboard layout and
    /// `characters(byApplyingModifiers:)` report for the Delete key). At 4d4fd13
    /// the hidden "Delete Quicklink" button claimed U+0008: silently with no
    /// quicklink row, deleting with one. ⌘E proves the bar's accelerators are
    /// live in this host, so the ⌘⌫ asserts are not vacuous.
    func testCommandBackspaceIsNeverAnActionBarKeyEquivalent() throws {
        for hit in [nil, QuicklinkHit(name: "gh", target: "https://github.com", description: "")] {
            let i = try input(quicklink: hit)
            for chars in ["\u{7F}", "\u{08}"] {
                i.calls.log = []
                let e = event(Key("⌘⌫", 51, chars, nil, .command), window: i.window)
                let hex = String(chars.unicodeScalars.first!.value, radix: 16)
                XCTAssertFalse(i.window.performKeyEquivalent(with: e),
                               "⌘⌫ U+\(hex) claimed (quicklink row: \(hit != nil))")
                XCTAssertEqual(i.calls.log, [])
            }
            if hit != nil {
                XCTAssertTrue(i.window.performKeyEquivalent(
                    with: event(Key("⌘E", 14, "e", nil, .command), window: i.window)))
                XCTAssertEqual(i.calls.log, ["edit"], "positive control")
            }
        }
    }

    /// Plain ↑/↓ (and their key repeats) stay the runner's row moves and never
    /// move the caret.
    func testPlainVerticalArrowsStillMoveRowsOnly() throws {
        let i = try input()
        reset(i, caret: 5)
        press(Key("↑", 126, Self.up, nil, Self.A), in: i)
        press(Key("↓", 125, Self.down, nil, Self.A), in: i)
        press(Key("↓", 125, Self.down, nil, Self.A), in: i, repeating: true)
        XCTAssertEqual(i.calls.log, ["up", "down", "down"])
        XCTAssertEqual(i.editor.selectedRange(), NSRange(location: 5, length: 0))
    }

    // MARK: - The monitor alone

    /// Each editing key leaves the monitor as the same event object, no handler
    /// fired (the field is non-empty, so ⌫ variants only ask deleteWhenEmpty).
    func testMonitorPassesEditingKeysThrough() {
        let calls = Calls()
        let w = offscreenWindow(NSView())
        let c = monitor(for: w, calls: calls)
        for k in Self.editing.map(\.0) + Self.menuOwned {
            calls.log = []
            let e = event(k, window: w)
            XCTAssertTrue(c.monitorHandler(e) === e, "\(k.name) was consumed by the monitor")
            XCTAssertTrue(calls.log.allSatisfy { $0 == "deleteWhenEmpty" }, "\(k.name): \(calls.log)")
        }
    }

    /// The runner's own bindings are consumed by the monitor's real closure —
    /// at 4d4fd13 `self?.handle(e) ?? e` handed every one of them back.
    func testMonitorConsumesRunnerBindings() {
        let calls = Calls()
        let w = offscreenWindow(NSView())
        let c = monitor(for: w, emptyLockedField: true, calls: calls)
        let quick: NSEvent.ModifierFlags =
            Preferences.quickSelectModifier == .command ? .command : .control
        let bindings: [(Key, String)] = [
            (Key("Esc", 53, "\u{1B}", nil, []), "cancel"),
            (Key("Return", 36, "\r", nil, []), "commit"),
            (Key("keypad Enter", 76, "\u{03}", nil, .numericPad), "commit"),
            (Key("⌘⏎", 36, "\r", nil, .command), "secondary"),
            (Key("⌥⏎", 36, "\r", nil, .option), "tertiary"),
            (Key("⌘Y", 16, "y", nil, .command), "quickLook"),
            (Key("⌃C", 8, "\u{03}", "c", .control), "clear"),
            (Key("quick-select 1", 18, "1", nil, quick), "number0"),
            (Key("quick-select 0", 29, "0", nil, quick), "number9"),
            (Key("⌫ on an empty locked field", 51, Self.bs, nil, []), "deleteWhenEmpty"),
        ]
        for (k, expected) in bindings {
            calls.log = []
            XCTAssertNil(c.monitorHandler(event(k, window: w)), "\(k.name) passed through")
            XCTAssertEqual(calls.log, [expected], k.name)
        }
    }

    /// Events for another window, or while an input method is composing, are
    /// never touched.
    func testMonitorLeavesOtherWindowsAndMarkedTextAlone() throws {
        let i = try input()
        let other = offscreenWindow(NSView())
        let esc = Key("Esc", 53, "\u{1B}", nil, [])
        let elsewhere = event(esc, window: other)
        XCTAssertTrue(i.monitor.monitorHandler(elsewhere) === elsewhere)

        i.editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(i.editor.hasMarkedText())
        for k in [esc, Key("Return", 36, "\r", nil, [])] {
            let e = event(k, window: i.window)
            XCTAssertTrue(i.monitor.monitorHandler(e) === e, "\(k.name) taken from the IME")
        }
        XCTAssertEqual(i.calls.log, [])
        i.editor.unmarkText()
    }
}
