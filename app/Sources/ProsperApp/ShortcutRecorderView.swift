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
        label.stringValue = recording ? "Press keys…" : combo.display
        label.textColor = recording ? .secondaryLabelColor : .labelColor
        layer?.borderColor = (recording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.recording else { return event }
            // Escape cancels recording without changing the binding.
            if event.type == .keyDown && event.keyCode == UInt16(kVK_Escape) {
                self.stopRecording()
                return nil
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
                let display = Self.display(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                           chars: event.charactersIgnoringModifiers)
                let newCombo = KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbon, display: display)
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

    /// Human-readable combo string, e.g. "⇧⌥A", "⌃Space".
    static func display(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, chars: String?) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += keyName(keyCode: keyCode, chars: chars)
        return s
    }

    private static func keyName(keyCode: UInt16, chars: String?) -> String {
        if let special = specialKeys[Int(keyCode)] { return special }
        if let chars, let first = chars.first, !first.isWhitespace {
            return String(first).uppercased()
        }
        return "Key\(keyCode)"
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_Delete: "⌫",
        kVK_Escape: "⎋",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_ANSI_Period: ".",
        kVK_ANSI_Comma: ",",
        kVK_ANSI_Slash: "/",
        kVK_ANSI_Backslash: "\\",
    ]
}
