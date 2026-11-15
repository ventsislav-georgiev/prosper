import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1093 - what VoiceOver gets from the shortcut recorder: one button with no child under it, an announcement when
/// recording starts and when a new combination lands, and the action it records for spoken with the combination.
///
/// Offscreen: windows are never shown, ordered front or made key, and each is closed in tearDown. No real VoiceOver,
/// no key monitor (beginRecording runs with a sentinel monitor so it installs none), no posted event (a key event is
/// built and handed to `handle` as a value), and no accessibility notification is posted: `RecorderView.announce` is
/// swapped for a recorder in every row that reaches it.
@MainActor
final class ShortcutRecorderAccessibilityTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        super.tearDown()
    }

    private func all<T: NSView>(_ v: NSView, _ t: T.Type) -> [T] {
        var out: [T] = []
        if let x = v as? T { out.append(x) }
        for s in v.subviews { out += all(s, t) }
        return out
    }

    /// `view` hosted in a never-shown window, laid out; the recorders in it left to right.
    private func recorders<V: View>(in view: V, _ size: CGSize) -> [RecorderView] {
        let (win, host) = AXTreeSupport.hosted(view, size)
        windows.append(win)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(win.isVisible, "never shown")
        return all(host, RecorderView.self).filter { !$0.isHiddenOrHasHiddenAncestor }
            .sorted { $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX }
    }

    /// A class, not a captured var: the seam's closure is main-actor isolated, so it may outlive the call.
    @MainActor private final class Spoken { var texts: [String] = [] }

    /// What `body` announced through the seam; the seam is put back after.
    private func announced(_ body: () throws -> Void) rethrows -> [String] {
        let saved = RecorderView.announce
        defer { RecorderView.announce = saved }
        let spoken = Spoken()
        RecorderView.announce = { spoken.texts.append($0) }
        try body()
        return spoken.texts
    }

    private func combo(_ code: Int, _ mods: Int) -> KeyCombo {
        KeyCombo(keyCode: UInt32(code), carbonModifiers: UInt32(mods), display: "")
    }

    private func names(_ children: [Any]) -> String {
        children.map { c in
            "\(type(of: c)) element \((c as? NSCell)?.isAccessibilityElement() ?? (c as? NSView)?.isAccessibilityElement() ?? false)"
        }.joined(separator: ", ")
    }

    /// `v` as the content of a never-shown window, laid out, so its accessibility children are the ones a client gets.
    private func inWindow(_ v: NSView) {
        let win = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        windows.append(win)
        win.contentView = v
        v.layoutSubtreeIfNeeded()
        XCTAssertFalse(win.isVisible, "never shown")
    }

    // MARK: - Item 1: no child

    /// Fact row (the configuration before #1093): an element view whose only subview is a labelWithString field
    /// marked not an element still serves the field's cell as its child. Marking the field is what #890 did; it
    /// has no effect, because the field is not an element anyway.
    func testAFieldMarkedNotAnElementStillExposesItsCell() throws {
        final class ElementView: NSView {
            override func isAccessibilityElement() -> Bool { true }
            override func accessibilityRole() -> NSAccessibility.Role? { .button }
        }
        let b = ElementView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        let field = NSTextField(labelWithString: "\u{2318}A")
        field.setAccessibilityElement(false)
        b.addSubview(field)
        inWindow(b)
        let children = b.accessibilityChildren() ?? []
        print("#1093 fact: field element \(field.isAccessibilityElement()), cell element \(field.cell?.isAccessibilityElement() ?? false), children [\(names(children))]")
        let cell = try XCTUnwrap(field.cell)
        XCTAssertTrue(children.contains { ($0 as AnyObject) === cell }, "children: [\(names(children))]")
    }

    /// The recorder has no accessibility child: neither the glyph field nor its cell, read through the public API
    /// on the view and through an AX client's walk of a hosted ShortcutRecorder (flags on this process only).
    func testRecorderExposesNoChild() throws {
        let r = RecorderView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        r.combo = combo(kVK_ANSI_A, cmdKey)
        r.refreshTitle()
        inWindow(r)
        let field = try XCTUnwrap(all(r, NSTextField.self).first)
        XCTAssertEqual(field.stringValue, "\u{2318}A")
        let cell = try XCTUnwrap(field.cell)
        let children = r.accessibilityChildren() ?? []
        XCTAssertFalse(children.contains { ($0 as AnyObject) === field || ($0 as AnyObject) === cell },
                       "children: [\(names(children))]")
        XCTAssertFalse(cell.isAccessibilityElement())

        let tree = AXTreeSupport.tree(ShortcutRecorder(combo: combo(kVK_ANSI_A, cmdKey), onChange: { _ in }),
                                      CGSize(width: 160, height: 24)) { $0.contains { $0.label == "Command A" } }
        let button = tree.filter { $0.label == "Command A" }
        XCTAssertEqual(button.count, 1, "\(tree.map { "\($0.role) \($0.names)" })")
        XCTAssertEqual(button.first?.role, NSAccessibility.Role.button.rawValue)
        XCTAssertFalse(tree.contains { !$0.ignored && $0.role == NSAccessibility.Role.staticText.rawValue },
                       "glyph text reachable: \(tree.map { "\($0.role) \($0.names) ignored \($0.ignored)" })")
        XCTAssertFalse(tree.contains { $0.reads("\u{2318}A") }, "\(tree.map { "\($0.role) \($0.names)" })")
    }

    // MARK: - Item 2: announcements

    /// Arming announces "Waiting for keys" once. A sentinel monitor stops beginRecording installing a real one;
    /// it is put back to nil before anything could hand it to NSEvent.removeMonitor.
    func testBeginRecordingAnnouncesWaitingForKeys() {
        let r = RecorderView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        r.monitor = NSObject()
        let spoken = announced { r.beginRecording() }
        r.monitor = nil
        XCTAssertEqual(spoken, ["Waiting for keys"])
        XCTAssertTrue(r.recording)
        XCTAssertEqual(r.accessibilityValue() as? String, "Waiting for keys")
        r.recording = false
    }

    /// A new combination is announced in words once it is taken; Escape announces nothing and keeps the combo.
    func testNewCombinationIsAnnounced() throws {
        let r = RecorderView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        r.combo = unsetKeyCombo
        var got: [String] = []
        r.onChange = { got.append($0.spokenLabel) }  // the way RunnerPanel captures it
        func key(_ code: Int, _ flags: NSEvent.ModifierFlags, _ chars: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code)))
        }
        let k = try key(kVK_ANSI_K, [.command, .shift], "k")
        let esc = try key(kVK_Escape, [], "\u{1B}")

        r.recording = true
        let spoken = announced { XCTAssertTrue(r.handle(k) == nil, "a taken combo is swallowed") }
        XCTAssertEqual(spoken, ["Shift Command K"])
        XCTAssertEqual(got, ["Shift Command K"])
        XCTAssertEqual(r.accessibilityLabel(), "Shift Command K")
        XCTAssertFalse(r.recording)

        r.recording = true
        let none = announced { XCTAssertTrue(r.handle(esc) != nil, "Escape goes on to the host") }
        XCTAssertEqual(none, [])
        XCTAssertEqual(got, ["Shift Command K"])
        XCTAssertFalse(r.recording)
    }

    // MARK: - Item 3: the action name, per caller

    /// No name: the combination alone (today's label); a name: "<name>, <combination>".
    func testActionNameIsSpokenBeforeTheCombination() {
        let r = RecorderView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        r.combo = combo(kVK_ANSI_A, cmdKey)
        XCTAssertEqual(r.accessibilityLabel(), "Command A")
        r.actionName = "Open Runner"
        XCTAssertEqual(r.accessibilityLabel(), "Open Runner, Command A")
    }

    /// All Actions (ShortcutCatalogRow): the row's action title.
    func testAllActionsRowNamesItsAction() throws {
        let set = combo(kVK_ANSI_A, cmdKey)
        let action = BindableAction(kind: .prosper, key: "a11y.runner", title: "Open Runner", category: "Prosper",
                                    icon: "brain", combo: set, defaultCombo: set)
        let found = recorders(in: ShortcutCatalogRow(action: action, onRecord: { _ in }, onReset: {}, onClear: {})
            .frame(width: 660, height: 40), CGSize(width: 660, height: 40))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.last?.accessibilityLabel(), "Open Runner, Command A")
    }

    /// Key Remapping (KeyMappingRow, a remap rule): the trigger and the target recorder each say which they are.
    func testKeyMappingRowNamesTriggerAndTarget() throws {
        var rule = ShortcutRulesStore.Rule()
        rule.trigger = "cmd+a"
        rule.action = .remap
        rule.target = "cmd+shift+k"
        let found = recorders(in: KeyMappingRow(model: SettingsModel(), rule: rule).frame(width: 660, height: 60),
                              CGSize(width: 660, height: 60))
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.first?.accessibilityLabel(), "Key to remap, Command A")
        XCTAssertEqual(found.last?.accessibilityLabel(), "Remap to, Shift Command K")
    }

    /// The runner's Assign Shortcut alert builds its recorder inside the function that runs the modal, which no row
    /// may run, so its one line is pinned in the source: the recorder is named after the command it binds.
    func testAssignShortcutAlertNamesTheCommand() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/ProsperApp/RunnerPanel.swift").standardized
        let text = try String(contentsOf: src, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "recorder.actionName = binding.name\n").count, 2)
    }
}
