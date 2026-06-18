import AppKit

/// Borderless, non-activating, click-through panel that draws the suggestion in a
/// compact bubble anchored ABOVE the focused text field — the fallback affordance
/// for apps that expose a field rect but no usable caret rect.
///
/// The inline `SuggestionWindow` pins the ghost to the exact caret position; that
/// only works when an app reports caret geometry. In surfaces that hide the caret
/// from Accessibility (some Electron/web fields), the caret resolves to nil and the
/// only thing we know is the field's bounding rect. Rather than fall back to the
/// bare `AccessoryButton`, this window mirrors the suggestion text into a small
/// labelled bubble floated just above the field, so the user still sees the
/// completion (the "text mirroring" technique Cotypist uses). It is OPT-IN per app
/// (`AppOverrideResolver.textMirroring == true`).
///
/// Construction mirrors `SuggestionWindow`: a `.statusBar`-level, clear,
/// shadowless, click-through `NSPanel` that joins all spaces and never activates.
/// Unlike the ghost it carries a faint rounded background so the bubble reads as a
/// distinct floating hint rather than inline continuation, and it adapts its text
/// color to a sampled background luminance the same way the ghost does.
@MainActor
final class MirrorOverlayWindow {

    private let panel: NSPanel
    private let label: NSTextField
    private let backgroundView: NSView

    /// Horizontal text inset inside the bubble, and the gap floated above the field.
    private static let hInset: CGFloat = 8
    private static let vInset: CGFloat = 4
    private static let fieldGap: CGFloat = 4

    init() {
        let initialFrame = NSRect(x: 0, y: 0, width: 1, height: 1)
        panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        backgroundView = NSView(frame: initialFrame)
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 6
        backgroundView.layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.92).cgColor

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = NSColor.labelColor
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail

        backgroundView.addSubview(label)
        panel.contentView = backgroundView
    }

    /// Shows the suggestion bubble centered horizontally on, and floated just above,
    /// the focused field's rect (AppKit screen coords). The bubble width is clamped
    /// to the field width (text truncates with an ellipsis), and the whole bubble is
    /// kept on the field's screen so it can't drift off-display.
    func show(text: String, fieldRect: CGRect) {
        guard !text.isEmpty, fieldRect.width > 1, fieldRect.height > 1 else {
            hide()
            return
        }
        label.stringValue = text
        label.sizeToFit()

        let textSize = label.frame.size
        let bubbleHeight = textSize.height + Self.vInset * 2
        // Clamp the bubble to the field width so it reads as belonging to the field.
        let maxWidth = max(0, fieldRect.width)
        let bubbleWidth = min(textSize.width + Self.hInset * 2, maxWidth)
        guard bubbleWidth > Self.hInset * 2 else { hide(); return } // no room to render

        // Center horizontally on the field, float just above its top edge.
        var originX = fieldRect.midX - bubbleWidth / 2
        let originY = fieldRect.maxY + Self.fieldGap

        // Keep the bubble fully on the field's screen.
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(fieldRect) })
            ?? NSScreen.main {
            let vf = screen.visibleFrame
            originX = min(max(originX, vf.minX + 1), vf.maxX - bubbleWidth - 1)
        }

        let frame = NSRect(x: originX, y: originY, width: bubbleWidth, height: bubbleHeight)
        panel.setFrame(frame, display: true)
        backgroundView.frame = NSRect(origin: .zero, size: frame.size)
        label.frame = NSRect(
            x: Self.hInset, y: Self.vInset,
            width: bubbleWidth - Self.hInset * 2, height: textSize.height
        )
        panel.orderFrontRegardless()
    }

    /// Adapts the bubble text color to a sampled background luminance so it stays
    /// legible on dark or light surfaces (mirrors `SuggestionWindow.adaptColor`).
    func adaptColor(toBackground bg: NSColor) {
        let rgb = bg.usingColorSpace(.deviceRGB) ?? bg
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        label.textColor = luminance < 0.5 ? .white : .black
    }

    func hide() {
        panel.orderOut(nil)
    }

    var isVisible: Bool {
        panel.isVisible
    }
}
