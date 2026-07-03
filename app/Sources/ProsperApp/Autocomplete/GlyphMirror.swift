import AppKit

/// Tier-3 caret geometry (A1): an off-screen `NSTextStorage`+`NSLayoutManager`
/// seeded with the host line's text and font, read back for the caret glyph's
/// bounding rect. This yields a true *inline* caret origin for apps whose AX
/// bounds are degenerate or wrong (Telegram/Qt, some Electron composers) — the
/// technique Cotypist calls `TextMirrorView`.
///
/// Prosper's `MirrorOverlayWindow` is a *bubble above the field*, not a glyph
/// measurer; this is the missing inline tier. It runs only when AX tiers 1–2
/// (`AXCaret.caretRect` / `markerCaretRect`) fail AND the app opts into text
/// mirroring, so it never perturbs apps that report real caret geometry.
///
/// The horizontal offset is the real win — the reported breakage is the ghost
/// landing at the field's leading edge because AX bounds lie about x. Vertical
/// placement is derived from the measured line fragment but falls back through
/// the pipeline's existing `ghostLineCenterY` field-centering when it lands
/// outside the field, so a top-vs-center layout mismatch degrades gracefully.
@MainActor
enum GlyphMirror {

    /// A caret rect (AppKit screen coords, bottom-left origin) for the caret sitting
    /// at the END of `lineBefore`, laid out at `font` inside a container the width of
    /// `fieldRect`. Returns nil when there's nothing usable to measure.
    ///
    /// The returned rect follows the pipeline's **AppKit caret-box convention** (the
    /// box sits one line-height above the glyph line, so `minY - height/2` is the
    /// glyph line's vertical center — see `ghostLineCenterY` / `markerCaretRect`).
    static func caretRect(lineBefore: String, font: NSFont, fieldRect: CGRect) -> CGRect? {
        guard fieldRect.width > 1, fieldRect.height > 1 else { return nil }

        let lineHeight = max(font.boundingRectForFont.height, font.pointSize)

        // Empty line: caret at the field's leading edge, vertically centered.
        guard !lineBefore.isEmpty else {
            return CGRect(x: fieldRect.minX, y: fieldRect.midY + lineHeight / 2,
                          width: 0, height: lineHeight)
        }

        // Lay out the line in a container as wide as the field so wrapping matches
        // what the user sees; the caret then lands on the correct visual line.
        let storage = NSTextStorage(string: lineBefore, attributes: [.font: font])
        let container = NSTextContainer(
            size: CGSize(width: fieldRect.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)

        let glyphCount = layout.numberOfGlyphs
        guard glyphCount > 0 else { return nil }

        // Bounds of the last glyph (its trailing edge is where the caret sits) and
        // the line fragment it lives on (for the visual-line vertical offset).
        let lastGlyph = glyphCount - 1
        var effRange = NSRange()
        let fragRect = layout.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: &effRange)
        let glyphRect = layout.boundingRect(
            forGlyphRange: NSRange(location: lastGlyph, length: 1), in: container)

        // Horizontal: field origin + trailing edge of the last glyph, clamped so a
        // measurement error can't push the ghost off the field's right edge.
        let caretX = min(fieldRect.minX + glyphRect.maxX, fieldRect.maxX)

        // Vertical: `fragRect.minY` is the distance from the text top (== field top)
        // down to this line's top. In AppKit screen coords (y up) the field top is
        // `fieldRect.maxY`, so `minY` below places the box one height above the glyph
        // line, making `minY - height/2` the glyph line's center.
        let h = fragRect.height > 1 ? fragRect.height : lineHeight
        let caretMinY = fieldRect.maxY - fragRect.minY

        return CGRect(x: caretX, y: caretMinY, width: 0, height: h)
    }

    /// The current visual line to seed the mirror with: the text after the last hard
    /// newline in `before`, capped so a huge buffer never costs a large layout on the
    /// keystroke path. Wrapping inside the field width is handled by `caretRect`.
    static func currentLine(of before: String, maxChars: Int = 2000) -> String {
        let line = before.reversed().prefix { $0 != "\n" }.reversed()
        let s = String(line)
        return s.count > maxChars ? String(s.suffix(maxChars)) : s
    }
}
