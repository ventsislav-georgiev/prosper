import AppKit

/// Mosaic-style "snap palette": a strip of layout-template thumbnails shown near the
/// top of the screen while dragging a window in `.palette` snap mode. Each thumbnail
/// is a miniature of one layout; its sub-cells are individual drop targets. Hovering
/// a cell highlights it and names it; releasing the window over a cell snaps the
/// window into that cell's real frame on the palette's screen.
///
/// Unlike `LayoutOverlayWindow` (which paints ONE layout's zones at their real screen
/// positions), this paints MANY layouts as small templates by the menu bar — so the
/// cells are NOT at the window's drop location. The drop frame comes from the cell's
/// (layout, zone), not from where the cursor is.
///
/// ponytail: copies LayoutOverlayWindow's ~12-line panel config rather than sharing a
/// base — third copy would be the trigger to extract one, not the second.
@MainActor
final class LayoutPaletteWindow {

    /// A targetable cell: which (layout, zone) it maps to, its hit rect in the AX
    /// top-left global space (so the controller tests the cursor with no coordinate
    /// juggling on the hot path), and a human label for the hover readout.
    struct Cell { var layout: Int; var zone: Int; var axRect: CGRect; var label: String }

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    private let panel: NSPanel
    private let container: FlippedView
    private let background = NSView()
    private let label = NSTextField(labelWithString: "")
    private var cellViews: [NSView] = []          // parallel to `cells`
    private(set) var cells: [Cell] = []
    private var signature: String = ""
    private var accent: NSColor = .controlAccentColor
    private var highlighted: Int?

    // Geometry (points).
    private static let thumb = CGSize(width: 78, height: 50)
    private static let thumbGap: CGFloat = 10
    private static let pad: CGFloat = 14
    private static let cellGap: CGFloat = 2
    private static let labelH: CGFloat = 20
    private static let thumbInset: CGFloat = 3
    private static let corner: CGFloat = 8

    init() {
        let initial = NSRect(x: 0, y: 0, width: 1, height: 1)
        panel = NSPanel(contentRect: initial,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .modalPanel
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0

        container = FlippedView(frame: initial)
        container.wantsLayer = true
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        container.addSubview(background)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.isHidden = true
        container.addSubview(label)
        panel.contentView = container
    }

    private(set) var isShowing = false

    /// Show (or rebuild) the palette for `layouts` on `screen`. Rebuilds the thumbnails
    /// only when the (display, layout-set) signature changes; the per-event hover work
    /// is hit-test + recolor, both allocation-light.
    func show(layouts: [WindowLayout], screen: NSScreen, accent: NSColor) {
        guard !layouts.isEmpty else { hide(); return }
        let firstShow = !isShowing
        isShowing = true
        self.accent = accent

        let sig = "\(WindowManager.displayID(of: screen)):"
            + layouts.map { l in l.id.uuidString + "#" + l.zones.map { $0.id.uuidString }.joined(separator: ".") }
                     .joined(separator: ",")
        if sig != signature {
            signature = sig
            rebuild(layouts: layouts, screen: screen)
            recolor(highlight: nil)
        }

        panel.orderFrontRegardless()
        if firstShow, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        } else {
            panel.alphaValue = 1
        }
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        signature = ""
        highlighted = nil
        label.isHidden = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0; panel.orderOut(nil); return
        }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.10; self.panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            guard let self, !self.isShowing else { return }
            self.panel.orderOut(nil)
        })
    }

    /// Topmost cell under the cursor (AX top-left global), or nil. Reverse scan so a
    /// later overlapping zone wins (within one layout's thumbnail — different layouts'
    /// thumbnails never overlap), matching `LayoutStore.hitZone`'s last-wins rule.
    func hitTest(cursorAX p: CGPoint) -> Int? {
        for i in stride(from: cells.count - 1, through: 0, by: -1) where cells[i].axRect.contains(p) {
            return i
        }
        return nil
    }

    /// Hot-path highlight update: recolor existing cells + update the label only.
    func setHighlight(_ idx: Int?) {
        guard isShowing, idx != highlighted else { return }
        recolor(highlight: idx)
    }

    // MARK: - Build / draw

    private func rebuild(layouts: [WindowLayout], screen: NSScreen) {
        cellViews.forEach { $0.removeFromSuperview() }
        cellViews = []
        cells = []

        let vf = screen.visibleFrame                       // AppKit global
        let t = Self.thumb, gap = Self.thumbGap, pad = Self.pad
        // Wrap thumbnails into rows that fit the visible width (minus a margin).
        let maxRowW = max(t.width, vf.width - 80)
        let perRow = max(1, Int((maxRowW - 2 * pad + gap) / (t.width + gap)))
        let cols = min(layouts.count, perRow)
        let rows = (layouts.count + perRow - 1) / perRow
        let contentW = 2 * pad + CGFloat(cols) * t.width + CGFloat(cols - 1) * gap
        let contentH = 2 * pad + CGFloat(rows) * t.height + CGFloat(rows - 1) * gap + Self.labelH

        var px = vf.midX - contentW / 2
        px = min(max(vf.minX + 4, px), vf.maxX - contentW - 4)
        let pf = NSRect(x: px, y: vf.maxY - contentH - 8, width: contentW, height: contentH)
        panel.setFrame(pf, display: true)
        container.frame = NSRect(origin: .zero, size: pf.size)
        background.frame = container.bounds
        label.frame = NSRect(x: pad, y: contentH - Self.labelH, width: contentW - 2 * pad, height: Self.labelH)

        for (li, layout) in layouts.enumerated() {
            let row = li / perRow, col = li % perRow
            let tx = pad + CGFloat(col) * (t.width + gap)
            let ty = pad + CGFloat(row) * (t.height + gap)
            let thumb = NSView(frame: NSRect(x: tx, y: ty, width: t.width, height: t.height))
            thumb.wantsLayer = true
            thumb.layer?.cornerRadius = Self.corner
            thumb.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            thumb.layer?.borderWidth = 1
            thumb.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
            container.addSubview(thumb)

            let inner = thumb.frame.insetBy(dx: Self.thumbInset, dy: Self.thumbInset)
            for (zi, zone) in layout.zones.enumerated() {
                let g = Self.cellGap
                let local = NSRect(
                    x: inner.minX + zone.rect.minX * inner.width + g / 2,
                    y: inner.minY + zone.rect.minY * inner.height + g / 2,
                    width: max(1, zone.rect.width * inner.width - g),
                    height: max(1, zone.rect.height * inner.height - g))
                let cv = NSView(frame: local)
                cv.wantsLayer = true
                cv.layer?.cornerRadius = 2
                container.addSubview(cv)
                cellViews.append(cv)

                // Flipped-local → global AppKit → AX top-left, so the controller can
                // hit-test the raw cursor against `axRect` with no further conversion.
                let globalAppKit = CGRect(x: pf.minX + local.minX,
                                          y: pf.maxY - local.minY - local.height,
                                          width: local.width, height: local.height)
                cells.append(Cell(layout: li, zone: zi,
                                  axRect: WindowManager.toAX(globalAppKit),
                                  label: cellLabel(layout: layout, zone: zone, index: zi)))
            }
        }
    }

    private func cellLabel(layout: WindowLayout, zone: LayoutZone, index: Int) -> String {
        let z = zone.label ?? Self.positionName(zone.rect)
        return "\(layout.name) · \(z)"
    }

    /// Derive a Mosaic-style position name ("Bottom Right", "Left Half", "Full"…)
    /// from a normalized rect, used when a zone has no explicit label. Pure → tested.
    static func positionName(_ r: CGRect) -> String {
        let vBand = r.height <= 0.6, hBand = r.width <= 0.6
        let v = r.midY < 0.4 ? "Top" : (r.midY > 0.6 ? "Bottom" : "")
        let h = r.midX < 0.4 ? "Left" : (r.midX > 0.6 ? "Right" : "")
        let parts = [v, h].filter { !$0.isEmpty }
        if parts.isEmpty { return "Full" }
        if vBand && hBand { return parts.joined(separator: " ") }     // quarter
        return parts.joined(separator: " ") + (hBand || vBand ? " Half" : "")
    }

    private func recolor(highlight: Int?) {
        highlighted = highlight
        for (i, cv) in cellViews.enumerated() {
            let on = i == highlight
            cv.layer?.backgroundColor = accent.withAlphaComponent(on ? 0.95 : 0.30).cgColor
        }
        if let h = highlight, cells.indices.contains(h) {
            label.stringValue = cells[h].label
            label.isHidden = false
        } else {
            label.isHidden = true
        }
    }
}
