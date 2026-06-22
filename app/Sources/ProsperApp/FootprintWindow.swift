import AppKit

/// The translucent "footprint" shown while dragging a window into a snap zone — a
/// live preview of exactly where the window will land on drop. One reusable,
/// click-through, non-activating panel that joins all spaces and floats above the
/// dragged window.
///
/// Two looks (user pref, see `FootprintStyle`): the default **vibrancy** style is an
/// `NSVisualEffectView` blur tinted with the theme accent, an accent border and a
/// faint accent fill — it reads as a premium "ghost" of the window. The **flat**
/// style is a plain translucent fill + border (Rectangle-parity, lighter to draw,
/// and the automatic fallback when the system Reduce Transparency setting is on).
///
/// Construction mirrors `MirrorOverlayWindow`: borderless `.nonactivatingPanel`,
/// clear background, shadowless, `ignoresMouseEvents`, all-spaces, never activates.
@MainActor
final class FootprintWindow {

    enum Style {
        case vibrancy
        case flat
    }

    private let panel: NSPanel
    private let container: NSView          // layer-backed; carries border + corner radius
    private let effect: NSVisualEffectView // shown only in vibrancy style
    private let tint: NSView               // faint accent fill on top of the blur

    /// macOS window corner radius — matches the system so the footprint reads as a
    /// real window. 16 on macOS 26+ (Tahoe rounded everything), ~11 below.
    private static var cornerRadius: CGFloat {
        if #available(macOS 26.0, *) { return 16 }
        return 11
    }

    init() {
        let initial = NSRect(x: 0, y: 0, width: 1, height: 1)
        panel = NSPanel(
            contentRect: initial,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
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
        container.layer?.cornerRadius = Self.cornerRadius
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 2

        effect = NSVisualEffectView(frame: initial)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]

        tint = NSView(frame: initial)
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]

        container.addSubview(effect)
        container.addSubview(tint)
        panel.contentView = container
    }

    /// Whether the preview is on screen for a snap zone right now.
    private(set) var isShowing = false

    /// Show (or move) the footprint at `frameAppKit` (AppKit bottom-left global
    /// coords). `accent` tints the look; `zoneChanged` fires the alignment haptic
    /// and the grow-in/morph animation. Honors Reduce Motion (no animation) and
    /// Reduce Transparency (forces the flat look).
    func show(frameAppKit: CGRect, style: Style, accent: NSColor, zoneChanged: Bool) {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let effectiveStyle: Style = reduceTransparency ? .flat : style
        applyStyle(effectiveStyle, accent: accent)

        let firstShow = !isShowing
        isShowing = true

        if zoneChanged {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }

        // First appearance: optionally grow in from 92% scale + fade. Subsequent
        // zone changes: morph the frame. Both collapse to an instant set under
        // Reduce Motion.
        if firstShow {
            if reduceMotion {
                panel.setFrame(frameAppKit, display: true)
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            } else {
                let start = frameAppKit.insetBy(dx: frameAppKit.width * 0.04,
                                                dy: frameAppKit.height * 0.04)
                panel.setFrame(start, display: false)
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(frameAppKit, display: true)
                    panel.animator().alphaValue = 1
                }
            }
        } else {
            panel.orderFrontRegardless()
            if reduceMotion {
                panel.setFrame(frameAppKit, display: true)
                panel.alphaValue = 1
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.10
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(frameAppKit, display: true)
                    panel.animator().alphaValue = 1
                }
            }
        }
    }

    /// Fade out and order the window away. Instant under Reduce Motion.
    func hide() {
        guard isShowing else { return }
        isShowing = false
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Only order out if a new show() hasn't re-armed us in the meantime.
            guard let self, !self.isShowing else { return }
            self.panel.orderOut(nil)
        })
    }

    private func applyStyle(_ style: Style, accent: NSColor) {
        switch style {
        case .vibrancy:
            effect.isHidden = false
            tint.layer?.backgroundColor = accent.withAlphaComponent(0.18).cgColor
            container.layer?.backgroundColor = NSColor.clear.cgColor
            container.layer?.borderColor = accent.withAlphaComponent(0.9).cgColor
        case .flat:
            effect.isHidden = true
            tint.layer?.backgroundColor = NSColor.clear.cgColor
            container.layer?.backgroundColor = accent.withAlphaComponent(0.28).cgColor
            container.layer?.borderColor = accent.withAlphaComponent(0.85).cgColor
        }
    }
}
