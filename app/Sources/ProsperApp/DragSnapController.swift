import AppKit
import ApplicationServices

/// Optional modifier the user can require to be held during a drag before it snaps.
enum DragSnapModifier: String, CaseIterable, Sendable {
    case none, control, option, command

    var title: String {
        switch self {
        case .none: return "No modifier (snap on plain drag)"
        case .control: return "Hold ⌃ Control"
        case .option: return "Hold ⌥ Option"
        case .command: return "Hold ⌘ Command"
        }
    }

    func isSatisfied(by flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .none: return true
        case .control: return flags.contains(.control)
        case .option: return flags.contains(.option)
        case .command: return flags.contains(.command)
        }
    }
}

/// Which half/quarter/maximize a cursor position maps to, plus the geometry that
/// classifies a cursor in the AX top-left space against a screen's full frame.
/// Pure and self-contained so it can be unit-checked without any AX/AppKit state.
enum SnapZone: Equatable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    var action: WindowAction {
        switch self {
        case .left: return .leftHalf
        case .right: return .rightHalf
        case .top: return .maximize          // top edge → maximize (Rectangle parity)
        case .bottom: return .bottomHalf
        case .topLeft: return .topLeftQuarter
        case .topRight: return .topRightQuarter
        case .bottomLeft: return .bottomLeftQuarter
        case .bottomRight: return .bottomRightQuarter
        }
    }

    /// Classify a cursor (AX top-left coords; `minY` is the top edge) against a
    /// screen's full frame. `corner` squares win over `edge` bands. Returns nil for
    /// the screen interior (no snap).
    static func at(cursorAX p: CGPoint, screenAX s: CGRect,
                   edgeMargin m: CGFloat, cornerSize c: CGFloat) -> SnapZone? {
        let nearLeft = p.x <= s.minX + m
        let nearRight = p.x >= s.maxX - m
        let nearTop = p.y <= s.minY + m
        let nearBottom = p.y >= s.maxY - m
        guard nearLeft || nearRight || nearTop || nearBottom else { return nil }

        let inLeftCol = p.x <= s.minX + c
        let inRightCol = p.x >= s.maxX - c
        let inTopRow = p.y <= s.minY + c
        let inBotRow = p.y >= s.maxY - c

        if inTopRow && inLeftCol { return .topLeft }
        if inTopRow && inRightCol { return .topRight }
        if inBotRow && inLeftCol { return .bottomLeft }
        if inBotRow && inRightCol { return .bottomRight }
        if nearTop { return .top }
        if nearBottom { return .bottom }
        if nearLeft { return .left }
        return .right
    }
}

/// Rectangle-style drag-to-edge window snapping.
///
/// A passive pair of `NSEvent` monitors (global for other apps, local for Prosper's
/// own windows) watches left-mouse down/drag/up. It deliberately does NOT ride the
/// autocomplete CGEvent tap: that tap is the main-thread, swallow-capable, typing-
/// critical path, and a ~120 Hz drag flood has no business there. Passive monitors
/// observe only — they can never break typing or swallow an event.
///
/// Hot-path discipline, in three tiers:
///  - Drag start (once): the expensive window-under-cursor AX hit-test.
///  - Pre-confirm (bounded): one `axFrame` poll per event to detect the window
///    actually moving, capped at `maxPreConfirmPolls` so a non-window drag (text
///    selection, scrollbar) can't hammer AX at ~120 Hz for its whole duration.
///  - Confirmed steady state: pure geometry (`SnapZone.at` + `targetFrame`), no AX
///    IPC and no allocation — a footprint move happens only when the zone changes.
@MainActor
final class DragSnapController {
    static let shared = DragSnapController()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let footprint = FootprintWindow()

    // Drag state.
    private var mouseDownAX: CGPoint?
    private var dragging = false
    private var aborted = false
    private var win: AXUIElement?
    private var winInitialOrigin: CGPoint?
    private var moveConfirmed = false
    private var preConfirmPolls = 0
    private var currentZone: SnapZone?
    private var currentScreen: NSScreen?

    /// Cursor travel (px) before a press is treated as a drag — filters plain clicks.
    private static let dragThreshold: CGFloat = 6
    /// Pre-confirm AX polls (≈ drag events) allowed before a never-moving drag (text
    /// selection, scrollbar) is abandoned. ~10 events ≈ 80–160 ms at 60–120 Hz.
    private static let maxPreConfirmPolls = 10

    var isActive: Bool { globalMonitor != nil }

    // MARK: - Lifecycle

    /// Whether the window extension (com.prosper.window) is live. Drag-snap is now
    /// a feature of that extension, so disabling it disables drag-snap too. Set by
    /// AppDelegate from the registry (boot + onEnabledChanged). Defaults true so a
    /// reconcile before the registry wires up doesn't wrongly suppress the feature.
    var windowExtLive = true

    /// Reconcile monitors against the enable pref + extension-live + Accessibility
    /// trust. Idempotent.
    func reconcile() {
        if Preferences.dragSnapEnabled && windowExtLive && PermissionsManager.isAccessibilityTrusted() {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { ev in
            MainActor.assumeIsolated { DragSnapController.shared.handle(ev) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { ev in
            MainActor.assumeIsolated { DragSnapController.shared.handle(ev) }
            return ev
        }
        NSLog("prosper: drag-snap monitors started")
    }

    private func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        resetDrag()
        footprint.hide()
    }

    // MARK: - Event handling

    private func handle(_ ev: NSEvent) {
        switch ev.type {
        case .leftMouseDown: beginPending()
        case .leftMouseDragged: updateDrag(ev)
        case .leftMouseUp: endDrag()
        default: break
        }
    }

    private func beginPending() {
        resetDrag()
        mouseDownAX = Self.cursorAX()
    }

    private func updateDrag(_ ev: NSEvent) {
        guard let down = mouseDownAX, !aborted else { return }
        let cur = Self.cursorAX()

        if !dragging {
            let dx = cur.x - down.x, dy = cur.y - down.y
            guard (dx * dx + dy * dy) >= Self.dragThreshold * Self.dragThreshold else { return }
            // A drag is starting — decide once whether it's eligible to snap.
            guard Preferences.dragSnapModifier.isSatisfied(by: ev.modifierFlags) else { aborted = true; return }
            guard let (el, pid) = WindowManager.windowUnderCursor(), pid != getpid() else { aborted = true; return }
            guard WindowManager.isResizable(el) else { aborted = true; return }  // skip fixed-size dialogs
            if let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
               Preferences.dragSnapIgnoredBundleIds.contains(bid) { aborted = true; return }
            dragging = true
            win = el
            winInitialOrigin = WindowManager.axFrame(el)?.origin
        }

        // Only treat this as a window move once the window's origin has actually
        // changed — distinguishes dragging the window from a text/scrollbar/select
        // drag that merely sweeps the cursor toward an edge. This is the one AX poll
        // per event, and it runs ONLY pre-confirm. A non-window drag never confirms,
        // so cap the polls: after maxPreConfirmPolls events with no origin change we
        // give up and abort, rather than hammering AX at ~120 Hz for the whole drag.
        if !moveConfirmed, let el = win, let o0 = winInitialOrigin {
            if let now = WindowManager.axFrame(el)?.origin,
               abs(now.x - o0.x) > 2 || abs(now.y - o0.y) > 2 {
                moveConfirmed = true
            } else if preConfirmPolls >= Self.maxPreConfirmPolls {
                aborted = true
                return
            } else {
                preConfirmPolls += 1
            }
        }

        guard let screen = WindowManager.screenContaining(axPoint: cur) else {
            setZone(nil, screen: nil); return
        }
        let zone = SnapZone.at(cursorAX: cur, screenAX: WindowManager.toAX(screen.frame),
                               edgeMargin: Preferences.dragSnapEdgeMargin,
                               cornerSize: Preferences.dragSnapCornerSize)
        setZone(zone, screen: screen)
    }

    private func setZone(_ zone: SnapZone?, screen: NSScreen?) {
        currentScreen = screen
        let changed = zone != currentZone
        currentZone = zone

        guard moveConfirmed else { return }  // don't preview until it's truly a window drag
        guard let zone, let screen else {
            if changed { footprint.hide() }
            return
        }
        // Steady state (same zone, still on screen): nothing to redraw. Critical —
        // this runs ~120 Hz during a drag, and re-issuing show() would restart the
        // footprint animation every event. Also note NO AX IPC here: drag zones
        // never use the window's `current` frame (only .center does, which isn't a
        // drag zone), so pass .zero instead of polling axFrame on the hot path.
        guard changed || !footprint.isShowing else { return }
        let v = WindowManager.visibleFrameAX(for: screen)
        let targetAX = WindowManager.targetFrame(for: zone.action, visible: v, current: .zero)
        footprint.show(frameAppKit: WindowManager.axToAppKit(targetAX),
                       style: Preferences.dragSnapStyle,
                       accent: NSColor(ThemeRuntime.palette.blue),
                       zoneChanged: changed)
    }

    private func endDrag() {
        defer { resetDrag(); footprint.hide() }
        guard dragging, !aborted, moveConfirmed,
              let zone = currentZone, let el = win, let screen = currentScreen else { return }
        WindowManager.snap(el, to: zone.action, onScreen: screen)
    }

    private func resetDrag() {
        mouseDownAX = nil
        dragging = false
        aborted = false
        win = nil
        winInitialOrigin = nil
        moveConfirmed = false
        preConfirmPolls = 0
        currentZone = nil
        currentScreen = nil
    }

    /// Current cursor in the AX top-left global space (NSEvent is bottom-left).
    private static func cursorAX() -> CGPoint {
        let l = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: l.x, y: h - l.y)
    }
}
