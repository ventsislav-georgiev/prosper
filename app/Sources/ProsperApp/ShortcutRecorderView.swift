import AppKit
import Carbon
import SwiftUI

/// SwiftUI wrapper around an AppKit shortcut recorder. Click to record, then
/// press the desired combo (at least one modifier required). Reports the new
/// `KeyCombo` via `onChange`.
struct ShortcutRecorder: NSViewRepresentable {
    let combo: KeyCombo
    let onChange: (KeyCombo) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onChange = onChange
        view.combo = combo
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.combo = combo
        nsView.onChange = onChange
        nsView.refreshTitle()
    }
}

/// A focusable button-like NSView that captures the next key combination.
final class RecorderView: NSView {
    var combo: KeyCombo = ShortcutAction.runner.defaultCombo
    var onChange: ((KeyCombo) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var monitor: Any?
    private var recording = false {
        didSet { refreshTitle(); needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.alignment = .center
        label.font = .systemFont(ofSize: 12 * ThemeRuntime.scale, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // No deinit monitor teardown: `monitor` is MainActor-isolated and deinit is
    // nonisolated. The monitor is always removed via `stopRecording()` — called
    // on capture, on Escape, and from `resignFirstResponder` when focus leaves —
    // so it never outlives the recording session.

    override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 24) }
    override var acceptsFirstResponder: Bool { true }

    func refreshTitle() {
        label.stringValue = recording ? "Press keys…" : combo.label
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
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.recording else { return event }
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
                self.onChange?(newCombo)
                return nil  // swallow so it doesn't type
            }
            return nil  // swallow flagsChanged while recording
        }
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
