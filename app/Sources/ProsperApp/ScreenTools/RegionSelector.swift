// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Close derivative of vorssaint-utils (github.com/vorssaint/vorssaint-utils, GPL-3.0):
// `Sources/Vorssaint/Services/Screenshot/ScreenshotSelectionController.swift`. The panel
// and view configuration, the hide-then-settle before capture, the one-session-on-screen
// guard and the inert-on-pending discipline are its design.
//
// Roughly 85% of upstream is deliberately NOT ported: freeze mode (photographing every
// display up front), the loupe/magnifier, the ghost "repeat last region" rect and the
// countdown timer. Prosper selects live and reports geometry only.

import AppKit
import SwiftUI

/// Borderless, non-activating overlay panel that still accepts key events, so Esc
/// works without stealing focus from the app being captured.
final class KeyableOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Drag-a-region overlay. Dims every screen, lets the user drag one rectangle, and
/// reports it as a global, top-left-origin CoreGraphics rect — exactly what
/// `VisionContext.capture` wants.
///
/// The selector captures nothing itself: no Vision, no ScreenCaptureKit, no pasteboard.
/// It does own the *timing* of the capture though — by the time the completion runs the
/// overlay is off screen and the window server has had a beat to composite it away, so
/// the caller can screenshot straight away without photographing the dim.
@MainActor
final class RegionSelector {

    /// Geometry only. `region` is global, top-left origin, in points.
    enum Outcome {
        case region(CGRect)
        case cancelled
    }

    /// True while an overlay is up. `nonisolated(unsafe)` so `deinit` (which is not
    /// main-actor isolated) can clear it; every other access is on the main actor.
    private nonisolated(unsafe) static var sessionOnScreen = false

    /// A second overlay on top of the first would fight for the same drag and leave
    /// one set of panels stranded. Callers check this, or just let `begin` no-op.
    static var isSessionOnScreen: Bool { sessionOnScreen }

    /// Keeps the live selector alive; nothing else retains it.
    private static var live: RegionSelector?

    private var panels: [KeyableOverlayPanel] = []
    private var monitors: [Any] = []
    private var completion: ((Outcome) -> Void)?
    private var finished = false

    /// Hide-to-capture settle. The panels are ordered out synchronously but the window
    /// server composites asynchronously; screenshotting immediately catches the dim.
    private static let settleSeconds = 0.060

    /// Puts the overlay on every screen and reports the dragged region. Returns false
    /// (and does nothing) when a session is already on screen.
    ///
    /// Permission is the caller's problem: check Screen Recording *before* calling, so
    /// a denied user never sees a dim screen that then does nothing.
    @discardableResult
    static func begin(_ completion: @escaping (Outcome) -> Void) -> Bool {
        guard !sessionOnScreen else { return false }
        sessionOnScreen = true
        let selector = RegionSelector()
        live = selector
        selector.present(completion)
        return true
    }

    private func present(_ completion: @escaping (Outcome) -> Void) {
        self.completion = completion

        // Read once: the flip reference must not change halfway through a session.
        let primaryTop = ScreenToolsSupport.primaryTop

        for screen in NSScreen.screens {
            let frame = screen.frame
            let panel = KeyableOverlayPanel(contentRect: frame,
                                            styleMask: [.borderless, .nonactivatingPanel],
                                            backing: .buffered,
                                            defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.acceptsMouseMovedEvents = true
            // Above full-screen apps, Stage Manager and notification banners.
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                        .stationary, .ignoresCycle]

            let view = RegionSelectionView(frame: NSRect(origin: .zero, size: frame.size))
            view.onFinish = { [weak self] viewRect in
                guard let self else { return }
                guard let viewRect else { self.finish(.cancelled); return }
                self.finish(.region(ScreenToolsSupport.globalCGRect(fromViewRect: viewRect,
                                                                    screenFrame: frame,
                                                                    primaryTop: primaryTop)))
            }
            panel.contentView = view
            // Not `NSApp.activate`: activating would yank focus off whatever the user
            // is capturing, which can change what is on screen underneath the overlay.
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        guard !panels.isEmpty else { finish(.cancelled); return }
        panels.first?.makeKey()
        NSCursor.crosshair.push()
        installEscapeMonitors()
    }

    private func installEscapeMonitors() {
        // Local: the overlay is key, so Esc lands here first — swallow it (return nil)
        // so it cannot also reach whatever is behind.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.window is KeyableOverlayPanel, event.keyCode == 53 else { return event }
            self?.finish(.cancelled)
            return nil
        }) {
            monitors.append(local)
        }
        // Global: a non-activating panel does not always win key focus, and then Esc
        // never reaches the local monitor at all — the overlay would be undismissable.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.finish(.cancelled) }
        }) {
            monitors.append(global)
        }
    }

    /// Idempotent: a mouse-up, both Esc monitors and a screen-less `present` can all
    /// race here, and tearing the panels down twice crashes on the second pass.
    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true

        // Inert before hidden: a trailing mouse event delivered while the panels are
        // still alive must not start a second selection over a capture in flight.
        for panel in panels {
            (panel.contentView as? RegionSelectionView)?.isCapturePending = true
        }
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        NSCursor.pop()
        for panel in panels { panel.orderOut(nil) }
        panels = []

        let completion = self.completion
        self.completion = nil
        RegionSelector.sessionOnScreen = false

        guard case .region = outcome else {
            RegionSelector.live = nil
            completion?(.cancelled)
            return
        }
        // Let the overlay actually leave the screen before the caller photographs
        // what was underneath it.
        DispatchQueue.main.asyncAfter(deadline: .now() + RegionSelector.settleSeconds) {
            RegionSelector.live = nil
            completion?(outcome)
        }
    }

    /// Safety net: if a selector is ever torn down without `finish` running, the flag
    /// must not stay stuck true — every later `begin` would silently no-op.
    deinit { RegionSelector.sessionOnScreen = false }
}

/// The dim + drag rectangle. Flipped so view coordinates are top-left origin and the
/// conversion to CoreGraphics global points is one subtraction
/// (`ScreenToolsSupport.globalCGRect`).
private final class RegionSelectionView: NSView {

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Set once the selection is handed off; every further event is ignored.
    var isCapturePending = false

    /// `nil` means cancelled. Rect is in this view's (flipped) coordinates.
    var onFinish: ((CGRect?) -> Void)?

    private var dragOrigin: CGPoint?
    private var selection: CGRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()

        guard selection.width >= 1, selection.height >= 1 else { return }

        // Punch the selection back to fully clear so the user sees true pixels.
        NSColor.clear.setFill()
        selection.fill(using: .copy)

        NSColor(Neon.blue).setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        drawSizeBadge()
    }

    private func drawSizeBadge() {
        let label = "\(Int(selection.width.rounded()))×\(Int(selection.height.rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 4
        var box = CGRect(x: selection.minX,
                         y: selection.maxY + padding,
                         width: size.width + padding * 2,
                         height: size.height + padding)
        // Flip the badge inside the selection when the drag runs off the bottom edge.
        if box.maxY > bounds.maxY { box.origin.y = selection.maxY - box.height - padding }
        box.origin.x = min(box.origin.x, bounds.maxX - box.width)

        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        (label as NSString).draw(at: CGPoint(x: box.minX + padding, y: box.minY + padding / 2),
                                 withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isCapturePending else { return }
        dragOrigin = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isCapturePending, let origin = dragOrigin else { return }
        let current = convert(event.locationInWindow, from: nil)
        // Shift squares the drag, Option grows it from the press point.
        let rect = ScreenToolsSupport.selectionRect(
            from: origin, to: current,
            square: event.modifierFlags.contains(.shift),
            fromCenter: event.modifierFlags.contains(.option))
        selection = ScreenToolsSupport.clamp(rect, to: bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !isCapturePending, let origin = dragOrigin else { return }
        dragOrigin = nil
        let end = convert(event.locationInWindow, from: nil)

        // A click that never travelled is "never mind", not a zero-size region. The
        // 2×2 floor catches a drag that travelled diagonally past the click threshold
        // but still encloses nothing capturable.
        if ScreenToolsSupport.isClick(from: origin, to: end)
            || selection.width < 2 || selection.height < 2 {
            onFinish?(nil)
            return
        }
        onFinish?(selection)
    }
}
