import AppKit

/// Borderless, non-activating, click-through panel that draws a dimmed "ghost"
/// suggestion at the caret position.
@MainActor
final class SuggestionWindow {

    private let panel: NSPanel
    private let label: NSTextField
    private let defaultFont: NSFont = .systemFont(ofSize: NSFont.systemFontSize)

    /// The font the ghost currently renders with. Used by the engine to measure
    /// typed-through text so the ghost advances by the exact rendered width.
    var currentFont: NSFont { label.font ?? defaultFont }

    /// Sets the ghost font to match the focused field's text (size + family), so
    /// the suggestion reads as an inline continuation. Pass nil to fall back to the
    /// system font. Clamped to a sane range to avoid absurd overlays.
    func applyFont(_ font: NSFont?) {
        guard let font else { label.font = defaultFont; return }
        let size = min(max(font.pointSize, 9), 48)
        label.font = NSFont(descriptor: font.fontDescriptor, size: size) ?? .systemFont(ofSize: size)
    }

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

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.6)
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail

        let container = NSView(frame: initialFrame)
        container.addSubview(label)
        panel.contentView = container
    }

    /// Shows the ghost text positioned at the given caret screen rect. `fieldRect`
    /// (the focused field's bounds, when known) is used to keep the ghost from
    /// spilling past the right edge of the field/window — the text truncates with
    /// an ellipsis instead of overflowing into neighbouring UI or off-screen.
    func show(text: String, at caretRect: CGRect, fieldRect: CGRect? = nil) {
        guard !text.isEmpty else {
            hide()
            return
        }
        // A boundary space (a completion that begins a NEW word after a finished
        // word the user typed without a trailing space) must read as a real gap.
        // A leading space glyph is too narrow and is largely cancelled by the cell
        // inset below, so strip it for display and instead offset the start by a
        // full space-width — the gap then matches a typed space exactly. The
        // inserted text keeps its space (handled upstream), so they stay in sync.
        var display = text
        var leadingGap: CGFloat = 0
        if display.hasPrefix(" ") {
            display = String(display.drop(while: { $0 == " " }))
            leadingGap = (" " as NSString).size(withAttributes: [.font: label.font as Any]).width
        }
        label.stringValue = display
        label.sizeToFit()

        let size = label.frame.size
        let height = max(size.height, caretRect.height)
        // Sit flush against the caret. `NSTextField` adds a ~2pt left cell inset,
        // so start 2pt before the caret's right edge to cancel it — without this
        // the ghost reads as having an extra leading space. Add the boundary gap
        // (zero in the common continuation case) on top of that.
        var startX = caretRect.maxX - 2 + leadingGap
        // Distrust a caret that sits horizontally outside the field (misreported
        // geometry on some web/Electron surfaces): keep the ghost inside it.
        if let fieldRect, fieldRect.width > 1 {
            startX = min(max(startX, fieldRect.minX), fieldRect.maxX - 8)
        }
        let width = clampedWidth(naturalWidth: size.width + 4, startX: startX, fieldRect: fieldRect)
        guard width > 8 else { hide(); return } // no room to render legibly
        // Render the ghost inline on the user's actual text line. The line-center
        // resolution is toolkit-aware (AppKit's caret box sits half a line above
        // the glyphs; Chromium/Electron report the true glyph box) and validated
        // against the field bounds — see `ghostLineCenterY`.
        let lineCenterY = AutocompleteEngine.ghostLineCenterY(caret: caretRect, field: fieldRect)
        let origin = CGPoint(x: startX, y: lineCenterY - height / 2)
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        panel.setFrame(frame, display: true)
        label.frame = NSRect(
            x: 0, y: baselineAlignedLabelY(panelHeight: height, labelHeight: size.height),
            width: width, height: min(size.height, height)
        )
        panel.orderFrontRegardless()
    }

    /// The label's panel-local y that puts the ghost glyphs' BASELINE where the
    /// field's text baseline sits, instead of merely centering the label frame.
    /// Frame-centering left the ghost a couple of px high everywhere: `sizeToFit`
    /// adds asymmetric cell insets, and the estimated ghost font rarely matches the
    /// field's font size exactly, so equal frame-centers ≠ equal baselines.
    ///
    /// The panel is positioned with its center on the text line's center. Within a
    /// line fragment, the baseline sits `defaultBaselineOffset` below the fragment's
    /// top, so `offset - lineHeight/2` below its center — the layout-system figure,
    /// not the raw `(ascender + descender) / 2` font metric, which lands up to ~1px
    /// high for non-system fonts (Helvetica in TextEdit) because line heights are
    /// rounded up while font metrics aren't. The ghost font approximates the field
    /// font (exact in AppKit fields), so its metrics stand in for the field's. The
    /// label's baseline sits `firstBaselineOffsetFromTop` below the label frame's
    /// top — AppKit's exact figure, insets included.
    private func baselineAlignedLabelY(panelHeight: CGFloat, labelHeight: CGFloat) -> CGFloat {
        let font = label.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let layout = NSLayoutManager()
        let baselineBelowCenter =
            layout.defaultBaselineOffset(for: font) - layout.defaultLineHeight(for: font) / 2
        // Panel-local: center = panelHeight/2; target baseline below it; label's
        // baseline is (labelHeight - firstBaselineOffsetFromTop) above the label's
        // bottom edge.
        let targetBaselineY = panelHeight / 2 - baselineBelowCenter
        let y = targetBaselineY - (labelHeight - label.firstBaselineOffsetFromTop)
        return max(0, min(y, panelHeight - labelHeight))
    }

    /// Clamps the ghost width so its right edge stays within the focused field
    /// (when known) and, as a hard backstop, the screen the caret sits on. The
    /// label's `.byTruncatingTail` mode renders an ellipsis when clipped.
    private func clampedWidth(naturalWidth: CGFloat, startX: CGFloat, fieldRect: CGRect?) -> CGFloat {
        var maxRight = NSScreen.screens
            .first(where: { $0.frame.contains(CGPoint(x: startX, y: $0.frame.midY)) })?
            .visibleFrame.maxX
            ?? NSScreen.main?.visibleFrame.maxX
            ?? (startX + naturalWidth)
        if let fieldRect, fieldRect.width > 1 {
            maxRight = min(maxRight, fieldRect.maxX)
        }
        let available = maxRight - startX - 2
        return min(naturalWidth, max(0, available))
    }

    /// Renders a suggested spelling fix: the misspelled word struck through,
    /// followed by the proposed correction.
    func showFix(strikethrough original: String, fix: String, at caretRect: CGRect, fieldRect: CGRect? = nil) {
        let attr = NSMutableAttributedString()
        let struck = NSAttributedString(string: original, attributes: [
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: NSColor.systemRed.withAlphaComponent(0.7),
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
        let arrow = NSAttributedString(string: "  ", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
        let corrected = NSAttributedString(string: fix, attributes: [
            .foregroundColor: NSColor.systemGreen,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
        attr.append(struck)
        attr.append(arrow)
        attr.append(corrected)

        label.attributedStringValue = attr
        label.sizeToFit()
        let size = label.frame.size
        let height = max(size.height, caretRect.height)
        // Sit flush against the caret. `NSTextField` adds a ~2pt left cell inset,
        // so start 2pt before the caret's right edge to cancel it — without this
        // the ghost reads as having an extra leading space.
        var startX = caretRect.maxX - 2
        if let fieldRect, fieldRect.width > 1 {
            startX = min(max(startX, fieldRect.minX), fieldRect.maxX - 8)
        }
        let width = clampedWidth(naturalWidth: size.width + 4, startX: startX, fieldRect: fieldRect)
        guard width > 8 else { hide(); return }
        let lineCenterY = AutocompleteEngine.ghostLineCenterY(caret: caretRect, field: fieldRect)
        let origin = CGPoint(x: startX, y: lineCenterY - height / 2)
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        panel.setFrame(frame, display: true)
        // Baseline-aligned label — see show().
        label.frame = NSRect(
            x: 0, y: baselineAlignedLabelY(panelHeight: height, labelHeight: size.height),
            width: width, height: min(size.height, height)
        )
        panel.orderFrontRegardless()
    }

    /// Adapts the ghost text color to a sampled background luminance so it stays
    /// legible on dark or light surfaces.
    func adaptColor(toBackground bg: NSColor) {
        let rgb = bg.usingColorSpace(.deviceRGB) ?? bg
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        let base: NSColor = luminance < 0.5 ? .white : .black
        label.textColor = base.withAlphaComponent(0.55)
    }

    func hide() {
        panel.orderOut(nil)
    }

    var isVisible: Bool {
        panel.isVisible
    }
}
