import AppKit
import Carbon
import SwiftUI

/// SwiftUI wrapper around an AppKit shortcut recorder. Click to record, then
/// press the desired combo (at least one modifier required). Reports the new
/// `KeyCombo` via `onChange`.
struct ShortcutRecorder: NSViewRepresentable {
    let combo: KeyCombo
    /// #1093: what the shortcut is for, spoken before the combination ("Open Runner, Command R"). nil: the combination alone.
    var actionName: String? = nil
    let onChange: (KeyCombo) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onChange = onChange
        view.combo = combo
        view.actionName = actionName
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.combo = combo
        nsView.onChange = onChange
        nsView.actionName = actionName
        nsView.refreshTitle()
    }

    /// #859: take the size the caller's `.frame` proposes. Left to the fixed 110x24
    /// `intrinsicContentSize`, the field kept 24 pt below UI scale 1.0 where its slot
    /// is `sz(24)`, overflowed the row by half the difference on each side, and the
    /// first row's top border was cut by the bounded list's scroll view.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecorderView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: nsView.intrinsicContentSize)
    }
}

/// A focusable button-like NSView that captures the next key combination.
final class RecorderView: NSView {
    var combo: KeyCombo = ShortcutAction.runner.defaultCombo
    var onChange: ((KeyCombo) -> Void)?
    /// #1093: see ShortcutRecorder.actionName.
    var actionName: String?
    /// #1093: how VoiceOver is told; rows swap it for a recorder. The default posts a high-priority announcement,
    /// heard wherever the VoiceOver cursor is (a value change is re-read only on the focused element, and the
    /// combination lives in the label, which no notification re-reads).
    static var announce: @MainActor (String) -> Void = { text in
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private let label = NSTextField(labelWithString: "")
    /// Today's label size, fixed at init like the font always was.
    private let fullFontSize = 12 * ThemeRuntime.scale
    /// Internal, not private, only so a row can arm beginRecording without installing a monitor (a non-nil one
    /// stops the install); the row puts it back to nil before anything removes it.
    var monitor: Any?
    /// Internal, not private, only so KeyMappingRowLayoutTests can show "Press keys…"
    /// without arming the event monitor; set it through beginRecording / stopRecording.
    var recording = false {
        didSet { refreshTitle(); needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.alignment = .center
        label.font = .systemFont(ofSize: fullFontSize, weight: .medium)
        // #1093: the element under a labelWithString field is its cell, not the field; marked off, the recorder has no
        // AX child and VoiceOver cannot stop on the glyph text under the button that already speaks it in words.
        label.cell?.setAccessibilityElement(false)
        addSubview(label)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // No deinit monitor teardown: `monitor` is MainActor-isolated and deinit is
    // nonisolated. The monitor is always removed via `stopRecording()` — called
    // on capture, on Escape, and from `resignFirstResponder` when focus leaves —
    // so it never outlives the recording session.

    override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 24) }

    /// #868: centred by frame, not by constraints. SwiftUI hosts this view with
    /// translatesAutoresizingMaskIntoConstraints off, so centring constraints solved
    /// against the 110 pt intrinsic width, not the narrower frame #859 gives it: the
    /// label's centre sat at x = 55 and it ran off the right edge below UI scale 1.0.
    ///
    /// #876: a label wider than the field (a four-modifier "Key<n>" fallback in the 96 pt
    /// key-rule slot) steps its font down until it fits; one that fits keeps the full size.
    override func layout() {
        super.layout()
        // No inset: the label's fitting width already carries the cell's side padding.
        var pt = fullFontSize
        label.font = .systemFont(ofSize: pt, weight: .medium)
        while label.fittingSize.width > bounds.width, pt > 1 {
            pt -= 0.25
            label.font = .systemFont(ofSize: pt, weight: .medium)
        }
        let size = label.fittingSize
        label.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                             y: ((bounds.height - size.height) / 2).rounded(),
                             width: size.width, height: size.height)
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Accessibility (#890)

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    /// The combo in words ("Shift Command K"), not the glyph string "⇧⌘K".
    override func accessibilityLabel() -> String? { actionName.map { "\($0), \(combo.spokenLabel)" } ?? combo.spokenLabel }
    override func accessibilityValue() -> Any? { recording ? "Waiting for keys" : nil }
    /// VoiceOver's press is the click: arms the field like `mouseDown`.
    override func accessibilityPerformPress() -> Bool {
        beginRecording()
        return true
    }

    func refreshTitle() {
        label.stringValue = recording ? "Press keys…" : combo.label
        needsLayout = true
        label.textColor = recording ? .secondaryLabelColor : .labelColor
        layer?.borderColor = (recording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        beginRecording()
    }

    /// Arms the field to capture the next combo. Exposed (rather than only firing on
    /// click) so a host that exists purely to record — the runner's "Assign
    /// Shortcut…" dialog — can arm it up front: that dialog tells the user to press
    /// keys, so requiring a click first would make it look broken. The Settings rows
    /// stay click-to-record, since there the field also displays the current binding.
    func beginRecording() {
        window?.makeFirstResponder(self)
        recording = true
        Self.announce("Waiting for keys")
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    /// The key monitor's body: a row hands it a built event as a value, never a posted one.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard recording else { return event }
        // Escape cancels recording without changing the binding, then goes on to
        // the host: in the runner's "Assign Shortcut…" alert the whole point of
        // Escape is to dismiss it, and swallowing the key left the dialog up with
        // a disarmed field — looking hung. Settings has no Escape handler, so
        // passing it through there is a no-op.
        if event.type == .keyDown && event.keyCode == UInt16(kVK_Escape) {
            self.stopRecording()
            return event
        }
        // Only act on keyDown with an actual (non-modifier) key.
        if event.type == .keyDown {
            let carbon = Self.carbonModifiers(from: event.modifierFlags)
            // Require at least one non-shift modifier so combos don't collide
            // with ordinary typing.
            guard carbon != 0, carbon != UInt32(shiftKey) else {
                NSSound.beep()
                return nil
            }
            let newCombo = KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbon, display: "")
            self.combo = newCombo
            self.stopRecording()
            Self.announce(newCombo.spokenLabel)
            self.onChange?(newCombo)
            return nil  // swallow so it doesn't type
        }
        return nil  // swallow flagsChanged while recording
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        recording = false
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    /// A view torn out of its window while still armed keeps a process-wide event
    /// monitor alive forever (closing the runner's alert never routes through
    /// `resignFirstResponder`), and every leftover monitor swallows keystrokes for
    /// a recorder that no longer exists.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
    }

    // MARK: - Conversion

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}
