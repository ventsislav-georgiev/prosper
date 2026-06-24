import AppKit

/// The set of layout zones shown on top of the screen while dragging a window in
/// `.layouts` snap mode — the "boxes" the user drops a window into. One click-
/// through, non-activating panel covering the screen's visible frame, hosting one
/// faint tile per zone; the zone under the pointer is highlighted with the accent.
///
/// The single-rect drag preview (`FootprintWindow`) and this multi-tile overlay
/// are deliberately separate classes: their panel config is the same ~12 lines
/// (borderless non-activating click-through all-spaces modal panel), copied here
/// rather than shared.
/// ponytail: copy over a shared base — two call sites, no third coming; a base
/// class would be more lines than it saves.
@MainActor
final class LayoutOverlayWindow {

    private let panel: NSPanel
    private let container: NSView
    private var tiles: [NSView] = []
    private var signature: String = ""   // rebuild tiles only when the layout changes
    private var accent: NSColor = .controlAccentColor
    private var highlighted: Int?

    private static let cornerRadius: CGFloat = 10

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

        container = NSView(frame: initial)
        container.wantsLayer = true
        panel.contentView = container
    }

    private(set) var isShowing = false

    /// Show (or update) the overlay for `zones` on `screen`. `frames` are the AX
    /// target rects (from `WindowManager.targetFrames`), one per zone, in the same
    /// order. `highlight` is the index of the hovered zone (nil = none). Tiles are
    /// rebuilt only when the layout signature changes; a plain highlight change on
    /// the drag hot path just recolors existing tiles.
    func show(zones: [LayoutZone], framesAX: [CGRect], highlight: Int?,
              screen: NSScreen, accent: NSColor) {
        guard zones.count == framesAX.count, !zones.isEmpty else { hide(); return }

        let vis = screen.visibleFrame                     // AppKit global
        let firstShow = !isShowing
        isShowing = true

        self.accent = accent
        let sig = "\(WindowManager.displayID(of: screen)):\(zones.map { $0.id.uuidString }.joined(separator: ","))"
        if sig != signature || tiles.count != zones.count {
            signature = sig
            // display:true — this branch only runs on a layout/screen change (not
            // the 120 Hz hover flood), and repainting immediately avoids a one-frame
            // artifact at the old location when the panel moves to another display.
            panel.setFrame(vis, display: true)
            container.frame = NSRect(origin: .zero, size: vis.size)
            rebuildTiles(framesAX: framesAX, panelOriginAppKit: vis.origin)
        }
        recolor(highlight: highlight)

        if firstShow {
            panel.orderFrontRegardless()
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.alphaValue = 1
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    panel.animator().alphaValue = 1
                }
            }
        } else {
            panel.orderFrontRegardless()
            panel.alphaValue = 1
        }
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        signature = ""
        highlighted = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isShowing else { return }
            self.panel.orderOut(nil)
        })
    }

    private func rebuildTiles(framesAX: [CGRect], panelOriginAppKit: CGPoint) {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = framesAX.map { ax in
            let appkit = WindowManager.axToAppKit(ax)         // global AppKit
            let local = NSRect(x: appkit.minX - panelOriginAppKit.x,
                               y: appkit.minY - panelOriginAppKit.y,
                               width: appkit.width, height: appkit.height)
            let v = NSView(frame: local)
            v.wantsLayer = true
            v.layer?.cornerRadius = Self.cornerRadius
            v.layer?.borderWidth = 2
            container.addSubview(v)
            return v
        }
    }

    /// Hot-path highlight update: recolor existing tiles only, no rebuild, no
    /// frame recompute. Called per drag event when the hovered zone changes but
    /// the layout/screen (and thus tile geometry) does not. No-op if unchanged.
    func setHighlight(_ idx: Int?) {
        guard isShowing, idx != highlighted else { return }
        recolor(highlight: idx)
    }

    private func recolor(highlight: Int?) {
        highlighted = highlight
        for (i, tile) in tiles.enumerated() {
            let on = i == highlight
            tile.layer?.backgroundColor = accent.withAlphaComponent(on ? 0.30 : 0.10).cgColor
            tile.layer?.borderColor = accent.withAlphaComponent(on ? 0.95 : 0.45).cgColor
        }
    }
}
