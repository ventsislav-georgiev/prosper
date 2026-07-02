import AppKit

/// Borderless, non-activating, click-through panel that draws a dimmed "ghost"
/// suggestion at the caret position.
@MainActor
final class SuggestionWindow {

    private let panel: NSPanel
    private let label: NSTextField
    /// Thin red line drawn over the user's mistyped letters in a spelling fix
    /// (see `showFix`). Hidden for ordinary ghost renders.
    private let strikeBar: NSView
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

        strikeBar = NSView(frame: .zero)
        strikeBar.wantsLayer = true
        strikeBar.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.75).cgColor
        strikeBar.layer?.cornerRadius = 0.75
        strikeBar.isHidden = true

        let container = NSView(frame: initialFrame)
        container.addSubview(strikeBar)
        container.addSubview(label)
        panel.contentView = container
    }

    /// Shows the ghost text positioned at the given caret screen rect. `fieldRect`
    /// (the focused field's bounds, when known) is used to keep the ghost from
    /// spilling past the right edge of the field/window — the text truncates with
    /// an ellipsis instead of overflowing into neighbouring UI or off-screen.
    ///
    /// This ANCHORS the ghost: the panel and every glyph in it are laid out once,
    /// here, and stay put. Type-through/deletes mutate visibility of a prefix
    /// (`consumeGhost`/`unconsumeGhost`) without touching the frame or re-laying
    /// out the text, so the remainder is pixel-identical between keystrokes —
    /// no shimmer, no drift, no left-right wiggle (Cotypist's observed model).
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
        strikeBar.isHidden = true // fix-only decoration (see showFix)
        ghostFull = text
        ghostConsumed = 0
        var display = text
        var leadingGap: CGFloat = 0
        if display.hasPrefix(" ") {
            display = String(display.drop(while: { $0 == " " }))
            leadingGap = (" " as NSString).size(withAttributes: [.font: label.font as Any]).width
        }
        ghostStrippedLeading = text.count - display.count
        applyGhostColors()
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
        // Whole-point origin so the glyph rasterization phase is stable.
        let origin = CGPoint(x: (startX).rounded(), y: (lineCenterY - height / 2).rounded())
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        panel.setFrame(frame, display: true)
        label.frame = NSRect(
            x: 0, y: baselineAlignedLabelY(panelHeight: height, labelHeight: size.height),
            width: width, height: min(size.height, height)
        )
        orderFrontFading()
    }

    // MARK: - Anchored ghost consumption (type-through / delete-regrow)

    /// Full anchored suggestion text, how many of its leading characters the user
    /// has typed through (they render CLEAR — the app's own text shows through in
    /// the gap), and how many leading spaces were stripped from display.
    private var ghostFull: String = ""
    private var ghostConsumed: Int = 0
    private var ghostStrippedLeading: Int = 0

    /// The user typed the next `n` predicted characters: make them transparent
    /// in place. NOTHING moves — the frame and the remaining glyphs keep their
    /// exact screen positions, so consumption is visually just the user's real
    /// text filling the gap the cleared glyphs leave behind.
    func consumeGhost(by n: Int) {
        guard panel.isVisible, !ghostFull.isEmpty else { return }
        ghostConsumed = min(ghostConsumed + n, ghostFull.count)
        applyGhostColors()
    }

    /// Reverse of `consumeGhost` for a single backspace. Returns false when
    /// there is nothing consumed to restore (the delete goes past the ghost's
    /// birth point — the engine then regrows by re-anchoring).
    @discardableResult
    func unconsumeGhost() -> Bool {
        guard panel.isVisible, ghostConsumed > 0 else { return false }
        ghostConsumed -= 1
        applyGhostColors()
        return true
    }

    /// Recolors the anchored ghost text: consumed prefix clear, remainder in the
    /// ghost color. Layout (string, font, frame) is untouched, so glyph positions
    /// and rasterization stay pixel-identical.
    private func applyGhostColors() {
        let display = String(ghostFull.dropFirst(ghostStrippedLeading))
        guard !display.isEmpty else { return }
        let clearLen = max(0, min(ghostConsumed - ghostStrippedLeading, display.count))
        let attr = NSMutableAttributedString(string: display, attributes: [
            .font: label.font ?? defaultFont,
            .foregroundColor: ghostColor,
        ])
        if clearLen > 0 {
            let head = NSRange(location: 0, length: (String(display.prefix(clearLen)) as NSString).length)
            attr.addAttribute(.foregroundColor, value: NSColor.clear, range: head)
        }
        label.attributedStringValue = attr
    }

    /// Brings the panel front. On the hidden→visible transition the ghost fades
    /// in fast (~90ms) instead of popping — the appear is what the eye catches;
    /// updates while already visible swap the label in place with no animation,
    /// and hide stays instant (a lingering wrong ghost is worse than a pop-out).
    private func orderFrontFading() {
        if panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.09
            panel.animator().alphaValue = 1
        }
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
        // Whole-point label y — same subpixel-rasterization stability as the
        // panel origin (a ≤0.5pt baseline offset is invisible; stroke breathing
        // between renders is not).
        return (max(0, min(y, panelHeight - labelHeight))).rounded()
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

    /// Renders a suggested spelling fix Cotypist-style, split at the first
    /// divergent character: a thin red line strikes through the user's OWN
    /// letters that the accept will retype (drawn over the field text, to the
    /// LEFT of the caret — no glyphs are redrawn, just the line), and the
    /// corrected letters render in green at the caret like a ghost. The panel
    /// spans both regions: a transparent strike zone (red bar only) followed by
    /// the green replacement label.
    func showFix(strike: String, replacement: String, at caretRect: CGRect, fieldRect: CGRect? = nil) {
        guard !replacement.isEmpty else { hide(); return }
        let font = label.font ?? defaultFont
        label.attributedStringValue = NSAttributedString(string: replacement, attributes: [
            .foregroundColor: NSColor.systemGreen.withAlphaComponent(0.85),
            .font: font,
        ])
        label.sizeToFit()
        let size = label.frame.size
        let height = max(size.height, caretRect.height)

        // Width of the struck letters, measured with the ghost font (mirrors the
        // field font). A small width error only moves a bar, never glyphs.
        let strikeWidth = strike.isEmpty
            ? 0 : (strike as NSString).size(withAttributes: [.font: font]).width
        var strikeStart = caretRect.maxX - strikeWidth
        if let fieldRect, fieldRect.width > 1 {
            strikeStart = min(max(strikeStart, fieldRect.minX), fieldRect.maxX - 8)
        }
        // Label sits where the caret is (same -2 cell-inset cancel as show()).
        let labelX = max(0, (caretRect.maxX - 2) - strikeStart)
        let width = clampedWidth(
            naturalWidth: labelX + size.width + 4, startX: strikeStart, fieldRect: fieldRect
        )
        guard width > 8 else { hide(); return }
        let lineCenterY = AutocompleteEngine.ghostLineCenterY(caret: caretRect, field: fieldRect)
        let origin = CGPoint(x: strikeStart.rounded(), y: (lineCenterY - height / 2).rounded())
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        let labelY = baselineAlignedLabelY(panelHeight: height, labelHeight: size.height)
        label.frame = NSRect(
            x: labelX, y: labelY,
            width: max(0, width - labelX), height: min(size.height, height)
        )
        // Red strike bar across the letters being replaced, at strikethrough
        // height (~half the x-height above the baseline).
        if strikeWidth > 0 {
            let baselineY = labelY + (size.height - label.firstBaselineOffsetFromTop)
            let barY = (baselineY + font.xHeight * 0.55).rounded()
            strikeBar.frame = NSRect(x: 0, y: barY, width: strikeWidth, height: 1.5)
            strikeBar.isHidden = false
        } else {
            strikeBar.isHidden = true
        }
        orderFrontFading()
    }

    /// Current ghost text color (adaptive — see `adaptColor`). Attributed renders
    /// (the anchored ghost) read this; plain-label renders use `label.textColor`.
    private var ghostColor: NSColor = NSColor.secondaryLabelColor.withAlphaComponent(0.6)

    /// Adapts the ghost text color to a sampled background luminance so it stays
    /// legible on dark or light surfaces.
    func adaptColor(toBackground bg: NSColor) {
        let rgb = bg.usingColorSpace(.deviceRGB) ?? bg
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        let base: NSColor = luminance < 0.5 ? .white : .black
        ghostColor = base.withAlphaComponent(0.55)
        label.textColor = ghostColor
    }

    func hide() {
        panel.orderOut(nil)
    }

    var isVisible: Bool {
        panel.isVisible
    }
}
