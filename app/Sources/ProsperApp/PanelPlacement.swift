import AppKit

/// Where the command runner and Clipboard History panels open on a multi-display
/// setup. Default `.cursorScreen` (Raycast/Ditto behavior — follow the pointer).
enum RunnerPlacement: String, CaseIterable, Sendable {
    case cursorScreen, lastPosition, mainScreen

    var title: String {
        switch self {
        case .cursorScreen: return "Screen under the cursor"
        case .lastPosition: return "Last position I moved it to"
        case .mainScreen: return "Main screen"
        }
    }
}

/// Pure panel-placement geometry over plain CGRects — no AppKit global state, so it
/// can be unit-checked without a real display arrangement, and so it's a tiny,
/// allocation-free hot path (runs once per ⌥Space / Clipboard open; budget < 5µs).
enum PanelGeometry {
    /// Inset kept between a panel and every screen edge.
    static let edgeInset: CGFloat = 8

    /// Index of the first frame containing `loc`, or nil if the point is off every
    /// display (e.g. in the dead space between mismatched screens).
    static func screenIndex(for loc: NSPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(loc) }
    }

    /// Clamps `value` to `[lo, hi]`. If the range is inverted (panel larger than the
    /// inset-adjusted frame, e.g. a 600px runner on a tiny sidecar display), centers
    /// on the midpoint instead of returning a nonsense edge.
    private static func clamp(_ value: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        guard hi >= lo else { return (lo + hi) / 2 }
        return min(max(value, lo), hi)
    }

    /// Origin that centers `size` in `visibleFrame`, raised by `raiseFraction` of the
    /// frame height above center (0 = dead center, positive = higher). Clamped to the
    /// `edgeInset` on every edge.
    static func centeredOrigin(size: NSSize, in visibleFrame: CGRect, raiseFraction: CGFloat = 0) -> NSPoint {
        let vf = visibleFrame
        let x = vf.midX - size.width / 2
        let y = vf.midY - size.height / 2 + vf.height * raiseFraction
        return clampedOrigin(NSPoint(x: x, y: y), size: size, in: vf)
    }

    /// Clipboard History's runner-relative origin (`.lastPosition` mode): centered on
    /// the runner column and raised above the runner's top edge, clamped to the
    /// screen the runner sits on (`screenVisible`).
    static func runnerRelativeOrigin(size: NSSize,
                                     runnerTopLeft: (x: CGFloat, top: CGFloat),
                                     runnerWidth: CGFloat,
                                     screenVisible: CGRect) -> NSPoint {
        let runnerCenterX = runnerTopLeft.x + runnerWidth / 2
        let origin = NSPoint(x: runnerCenterX - size.width / 2,
                             y: runnerTopLeft.top - size.height * 0.7)
        return clampedOrigin(origin, size: size, in: screenVisible)
    }

    /// Clamps an origin so the panel stays inside `vf` with the standard inset.
    static func clampedOrigin(_ origin: NSPoint, size: NSSize, in vf: CGRect) -> NSPoint {
        NSPoint(x: clamp(origin.x, vf.minX + edgeInset, vf.maxX - size.width - edgeInset),
                y: clamp(origin.y, vf.minY + edgeInset, vf.maxY - size.height - edgeInset))
    }
}

extension NSScreen {
    /// The screen containing the mouse pointer, falling back to main / first.
    static var underCursor: NSScreen {
        let loc = NSEvent.mouseLocation
        if let i = PanelGeometry.screenIndex(for: loc, frames: screens.map(\.frame)) {
            return screens[i]
        }
        return main ?? screens[0]
    }

    /// The screen the runner's saved top-left sits on (by its top-center probe),
    /// falling back to main / first.
    static func containing(runnerTopLeft tl: (x: CGFloat, top: CGFloat), runnerWidth: CGFloat) -> NSScreen {
        let probe = NSPoint(x: tl.x + runnerWidth / 2, y: tl.top - 1)
        if let i = PanelGeometry.screenIndex(for: probe, frames: screens.map(\.frame)) {
            return screens[i]
        }
        return main ?? screens[0]
    }

    /// Origin that centers `size` in this screen's visibleFrame (see `PanelGeometry`).
    static func centeredOrigin(size: NSSize, in screen: NSScreen, raiseFraction: CGFloat = 0) -> NSPoint {
        PanelGeometry.centeredOrigin(size: size, in: screen.visibleFrame, raiseFraction: raiseFraction)
    }
}
