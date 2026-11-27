import AppKit
import SwiftUI

/// #1250: a one-line settings text field hosted as our own NSTextField. A plain SwiftUI TextField in a NEW pane built
/// right after a UI scale change could keep the PREVIOUS scale's height in the platform field's own frame (a process-wide
/// stale placement, not the AX tree), while its font and intrinsic size were this scale's. Here SwiftUI's size comes from
/// sizeThatFits, measured from the field's cell at the font it holds now (set on every update, the size invalidated on a change).
/// It matches the stock field it replaced (#1250 step f: AgentIslandDefaultModelTests' parity row): an NSTextField(string:)
/// already has the stock's bezel, background, colours, focus ring, alignment, control size, no wrap and scrolling; the one
/// line and no action on the end of editing are set below.
struct ScaledTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    /// #1450: nil is the monospaced body (the settings fields); else Neon.font(fontSize, weight:) as an NSFont.
    var fontSize: CGFloat?
    var weight: NSFont.Weight = .regular
    /// #1450: textFieldStyle(.plain): no bezel, border or background, Neon.textPrimary text (the Layouts and Find fields).
    var plain = false
    /// #1450: takes the keyboard focus once it is in a window (SwiftUI's focused + onAppear); Escape and the focus leaving.
    var focusOnAppear = false
    var onCancel: (() -> Void)?
    var onEndEditing: (() -> Void)?
    /// #2062 r3: focusOnAppear took the keys; given who had them before (the caller hands them back on its close).
    var onFocus: ((NSResponder?) -> Void)?

    /// Neon.font(.body, design: .monospaced) as an NSFont: the 13 pt body times the UI scale.
    static var monospacedBody: NSFont { .monospacedSystemFont(ofSize: 13 * ThemeRuntime.scale, weight: .regular) }

    private var font: NSFont {
        fontSize.map { NSFont.systemFont(ofSize: $0 * ThemeRuntime.scale, weight: weight) } ?? Self.monospacedBody
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.cell?.sendsActionOnEndEditing = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        if plain {
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = false
        }
        if focusOnAppear {
            let c = context.coordinator
            DispatchQueue.main.async {
                let prior = field.window?.firstResponder
                if field.window?.makeFirstResponder(field) == true { c.parent.onFocus?(prior) }
            }
        }
        update(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        update(field)
    }

    private func update(_ field: NSTextField) {
        if plain { field.textColor = NSColor(Neon.textPrimary) }
        let font = self.font
        if field.font != font {
            field.font = font
            field.invalidateIntrinsicContentSize()   // tells SwiftUI to measure again (sizeThatFits) in a live field
        }
    }

    /// The proposed width (the pane pins it), the stock field's one-line height at the field's current font.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        Self.size(of: field, width: proposal.width)
    }

    static func size(of field: NSTextField, width: CGFloat?) -> CGSize {
        let cell = field.cell?.cellSize ?? field.intrinsicContentSize
        // The stock field is the font's default line height plus the cell's insets around its text; the cell's own size
        // rounds the line up from the ascender and descender instead: 1 pt taller at 0.85 and 1.15 (22 vs 21, 26 vs 25).
        let text = field.cell?.titleRect(forBounds: CGRect(origin: .zero, size: cell)).height ?? cell.height
        let line = field.font.map { NSLayoutManager().defaultLineHeight(for: $0) } ?? text
        return CGSize(width: width ?? ceil(cell.width), height: ceil(cell.height - text + line))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ScaledTextField
        init(_ parent: ScaledTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// Return in the field (an NSTextField sends its action on Return only), as SwiftUI's onSubmit.
        @objc func submit() { parent.onSubmit() }

        /// Escape, where the field has an onCancel (SwiftUI's onExitCommand).
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), let cancel = parent.onCancel else { return false }
            cancel()
            return true
        }

        /// The focus leaving. Return ends the editing too and then sends the action: that is a submit, not a leave.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let end = parent.onEndEditing,
                  (notification.userInfo?["NSTextMovement"] as? Int) != NSTextMovement.return.rawValue else { return }
            end()
        }
    }
}
