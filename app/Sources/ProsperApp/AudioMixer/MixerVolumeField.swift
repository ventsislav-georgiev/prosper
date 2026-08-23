// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (UI/MenuPanel/MixerSection.swift +
// MixerPercentNativeTextField.swift). Behaviour is unchanged — the only edits
// are Prosper's theme tokens for the editor chrome and `ThemeRuntime.scale` on
// the font/metrics so the field grows with the global UI size.

import AppKit
import SwiftUI

/// AppKit owns first-responder timing inside a menu-bar popover. SwiftUI can
/// request focus before its backing field has joined the popover window; this
/// hook waits for that attachment and lets the representable retry then.
final class MixerPercentNativeTextField: NSTextField {
    var didAttachToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { didAttachToWindow?() }
    }

    @discardableResult
    func focusAndSelectAll() -> Bool {
        guard let window else { return false }
        window.makeKey()
        guard window.makeFirstResponder(self) else { return false }
        selectText(nil)
        return true
    }
}

/// The percentage keeps its compact read-only appearance until clicked, then
/// becomes a selected text field so the next keystroke replaces the old value.
struct EditableVolumePercent<Label: View>: View {
    let currentPercent: Int
    let maximumPercent: Int
    let width: CGFloat
    let editorID: String
    @Binding var editingID: String?
    let accessibilityLabel: String
    @ViewBuilder let label: () -> Label
    let onCommit: (Double) -> Void

    @State private var draft = ""

    private var isEditing: Bool { editingID == editorID }

    var body: some View {
        ZStack {
            HStack(spacing: 1) {
                AutofocusingVolumeTextField(text: $draft,
                                            isActive: isEditing,
                                            accessibilityLabel: accessibilityLabel,
                                            onSubmit: commit,
                                            onCancel: cancel)
                Text("%")
                    .font(Neon.font(9.5, weight: .medium))
                    .foregroundStyle(Neon.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, sz(3))
            .frame(width: width, height: sz(18))
            .background(
                RoundedRectangle(cornerRadius: sz(4), style: .continuous)
                    .fill(Neon.cardHi)
            )
            .overlay(
                RoundedRectangle(cornerRadius: sz(4), style: .continuous)
                    .strokeBorder(Neon.blue.opacity(0.7), lineWidth: 1)
            )
            .opacity(isEditing ? 1 : 0)
            .allowsHitTesting(isEditing)
            .accessibilityHidden(!isEditing)

            Button(action: beginEditing) {
                label()
                    .frame(width: width, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isEditing ? 0 : 1)
            .allowsHitTesting(!isEditing)
            .accessibilityLabel("\(accessibilityLabel) \(currentPercent)%")
            .accessibilityHidden(isEditing)
        }
        .frame(width: width, alignment: .trailing)
    }

    private func beginEditing() {
        draft = String(currentPercent)
        editingID = editorID
    }

    @discardableResult
    private func commit() -> Bool {
        guard let volume = MixerRoutingSupport.volumeFraction(
            fromPercentageText: draft,
            maximumPercent: maximumPercent
        ) else {
            NSSound.beep()
            return false
        }
        onCommit(volume)
        editingID = nil
        return true
    }

    private func cancel() {
        if isEditing { editingID = nil }
    }
}

/// A native field is used because an NSPopover can attach its SwiftUI backing
/// view after a FocusState request has already fired. The field retries when it
/// joins the window, then owns Return, Escape and loss-of-focus behavior.
private struct AutofocusingVolumeTextField: NSViewRepresentable {
    @Binding var text: String
    let isActive: Bool
    let accessibilityLabel: String
    let onSubmit: () -> Bool
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text,
                    isActive: isActive,
                    onSubmit: onSubmit,
                    onCancel: onCancel)
    }

    func makeNSView(context: Context) -> MixerPercentNativeTextField {
        let field = MixerPercentNativeTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .right
        field.font = .systemFont(ofSize: sz(10.5), weight: .medium)
        field.textColor = NSColor(Neon.textPrimary)
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.isEnabled = isActive
        field.isHidden = !isActive
        field.setAccessibilityLabel(accessibilityLabel)
        field.didAttachToWindow = { [weak field, weak coordinator = context.coordinator] in
            guard let field else { return }
            coordinator?.focusIfNeeded(field)
        }
        return field
    }

    func updateNSView(_ field: MixerPercentNativeTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
        field.setAccessibilityLabel(accessibilityLabel)
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.setActive(isActive, field: field)
    }

    static func dismantleNSView(_ field: MixerPercentNativeTextField,
                                coordinator: Coordinator) {
        coordinator.stopMonitoringEscape()
        field.didAttachToWindow = nil
        field.delegate = nil
    }

    // @MainActor is Prosper's delta: AppKit's text-field callbacks and the
    // focus retry all touch main-actor state, which Swift 6 strict
    // concurrency will not let a nonisolated coordinator do.
    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        private var isActive: Bool
        var onSubmit: () -> Bool
        var onCancel: () -> Void
        private var didFocus = false
        private var isFinishing = false
        private var escapeMonitor: Any?

        init(text: Binding<String>,
             isActive: Bool,
             onSubmit: @escaping () -> Bool,
             onCancel: @escaping () -> Void) {
            self.text = text
            self.isActive = isActive
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            super.init()
            if isActive { startMonitoringEscape() }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard isActive, didFocus, !isFinishing,
                  let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
            isFinishing = true
            if !onSubmit() { onCancel() }
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                text.wrappedValue = (control as? NSTextField)?.stringValue ?? text.wrappedValue
                if onSubmit() { isFinishing = true }
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finish(onCancel)
                return true
            }
            return false
        }

        func focusIfNeeded(_ field: MixerPercentNativeTextField) {
            guard isActive, !didFocus else { return }
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, self.isActive, !self.didFocus else { return }
                if field.focusAndSelectAll() { self.didFocus = true }
            }
        }

        func setActive(_ active: Bool, field: MixerPercentNativeTextField) {
            if active != isActive {
                isActive = active
                didFocus = false
                isFinishing = false
                if active {
                    field.isHidden = false
                    field.isEnabled = true
                    startMonitoringEscape()
                } else {
                    stopMonitoringEscape()
                    field.isEnabled = false
                    field.isHidden = true
                }
            }
            if active { focusIfNeeded(field) }
        }

        private func startMonitoringEscape() {
            guard escapeMonitor == nil else { return }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isActive, event.keyCode == 53 else { return event }
                self.finish(self.onCancel)
                return nil
            }
        }

        func stopMonitoringEscape() {
            guard let escapeMonitor else { return }
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }

        private func finish(_ action: () -> Void) {
            guard !isFinishing else { return }
            isFinishing = true
            action()
        }
    }
}
