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
    private let layoutOverlay = LayoutOverlayWindow()
    private let palette = LayoutPaletteWindow()

    // Drag state.
    private var mouseDownAX: CGPoint?
    private var dragging = false
    private var aborted = false
    private var win: AXUIElement?
    private var winID: CGWindowID?
    private var winInitialOrigin: CGPoint?
    private var winInitialServerOrigin: CGPoint?
    private var moveConfirmed = false
    private var preConfirmPolls = 0
    private var currentZone: SnapZone?
    private var currentScreen: NSScreen?
    // Layout-mode drag state (snapMode == .layouts). Mode + layout are snapshotted
    // at drag start so a mid-drag settings change can't swap them under the user.
    private var dragMode: SnapMode = .edges
    private var dragLayout: WindowLayout?
    private var dragGap: CGFloat = 8
    private var currentZoneIdx: Int?
    // Palette-mode drag state (snapMode == .palette). All layouts are snapshotted at
    // drag start (palette shows every template); the chosen cell decides the drop.
    private var dragLayouts: [WindowLayout] = []
    private var currentCell: Int?
    private var paletteDisplay: CGDirectDisplayID?
    // (display, layout) the overlay tiles are currently built for. A value-type
    // struct, not a String — comparing it on the ~120 Hz path must not allocate.
    // gap is intentionally omitted: it's snapshotted immutable at drag start, so a
    // given drag's tiles always match the gap they'll drop with.
    private struct LayoutSig: Equatable { var display: CGDirectDisplayID; var layout: UUID }
    private var layoutSig: LayoutSig?

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
        layoutOverlay.hide()
        palette.hide()
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
            // A gesture that BEGINS in the menu bar is a menu-bar-item rearrange (macOS
            // requires holding ⌘ to drag those) — never a window move. Without this the
            // ⌘-drag satisfies the .command/.none modifier and the hit-test finds a
            // window beneath the bar, popping the layout palette. A real window drag
            // starts in the title bar, below the menu bar, so this never false-aborts.
            if let downScreen = WindowManager.screenContaining(axPoint: down),
               down.y < WindowManager.visibleFrameAX(for: downScreen).minY { aborted = true; return }
            guard Preferences.dragSnapModifier.isSatisfied(by: ev.modifierFlags) else { aborted = true; return }
            guard let hit = WindowManager.draggableWindowUnderCursor(), hit.pid != getpid() else { aborted = true; return }
            let el = hit.element, pid = hit.pid
            if let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
               Preferences.dragSnapIgnoredBundleIds.contains(bid) { aborted = true; return }
            dragMode = Preferences.snapMode
            dragLayout = dragMode == .layouts ? Preferences.layoutStore.activeLayout : nil
            dragLayouts = dragMode == .palette ? Preferences.layoutStore.allLayouts.filter { !$0.zones.isEmpty } : []
            dragGap = Preferences.layoutGap
            // No usable layout(s) → fall back to classic edge snapping rather than
            // silently no-op'ing the whole drag.
            if dragMode == .layouts && (dragLayout?.zones.isEmpty ?? true) {
                dragMode = .edges; dragLayout = nil
            }
            if dragMode == .palette && dragLayouts.isEmpty { dragMode = .edges }
            // Fixed-size dialogs can't be resized into a zone — but a moveOnly (Quick
            // Positions) drop only repositions them, so allow those. Palette mode also
            // never aborts: the picked template decides resize-vs-move at drop, and a
            // resize against a fixed-size window simply no-ops (its position still
            // applies). Abort only in edges/layouts when the drop would surely resize.
            let willResize = dragMode == .edges
                || (dragMode == .layouts && !(dragLayout?.isMoveOnly ?? false))
            if willResize, !WindowManager.isResizable(el) { aborted = true; return }
            dragging = true
            win = el
            winID = hit.windowID
            winInitialOrigin = WindowManager.axFrame(el)?.origin
            winInitialServerOrigin = winID.flatMap { WindowManager.serverFrame(of: $0)?.origin }
        }

        // Only treat this as a window move once the window's origin has actually
        // changed — distinguishes dragging the window from a text/scrollbar/select
        // drag that merely sweeps the cursor toward an edge. These are the only AX/
        // window-server polls on the drag path, and they run ONLY pre-confirm: a
        // confirmed drag and a capped (non-window) drag both stop polling, so the
        // ~120 Hz steady state is pure geometry with zero IPC.
        if !moveConfirmed {
            // Confirm from EITHER the app's AX origin or the window server's origin.
            // Telegram (and other Qt apps) don't push AXPosition updates during a
            // live drag, so axFrame stays pinned at the start — but the window server
            // always knows the real on-screen position, so serverFrame catches the
            // move. A text/scrollbar drag moves neither, so it still never confirms.
            // Window server first: it tracks every app's live position, so on the
            // common path it confirms and `||` short-circuits past the AX poll. The AX
            // origin is the fallback for when no window id is available (winID nil).
            let moved = Self.didMove(from: winInitialServerOrigin, to: winID.flatMap { WindowManager.serverFrame(of: $0)?.origin })
                || Self.didMove(from: winInitialOrigin, to: win.flatMap { WindowManager.axFrame($0)?.origin })
            if moved {
                moveConfirmed = true
            } else if preConfirmPolls >= Self.maxPreConfirmPolls {
                // Capped: ~10 events (~80–160 ms) with no movement → not a window
                // drag (text selection, scrollbar). Abort for ALL modes — the
                // overlays are gated on moveConfirmed so none has shown yet, and
                // aborting stops the per-event polling for the rest of the gesture
                // (otherwise a never-moving drag would re-poll AX + the window server
                // every event at ~120 Hz). The drop is gated on moveConfirmed too, so
                // an aborted drag never snaps.
                aborted = true; return
            } else {
                preConfirmPolls += 1
            }
        }

        let screen = WindowManager.screenContaining(axPoint: cur)
        switch dragMode {
        case .edges:
            guard let screen else { setZone(nil, screen: nil); return }
            let zone = SnapZone.at(cursorAX: cur, screenAX: WindowManager.toAX(screen.frame),
                                   edgeMargin: Preferences.dragSnapEdgeMargin,
                                   cornerSize: Preferences.dragSnapCornerSize)
            setZone(zone, screen: screen)
        case .layouts:
            updateLayoutDrag(cur: cur, screen: screen)
        case .palette:
            updatePaletteDrag(cur: cur, screen: screen)
        }
    }

    /// Palette-mode hot path: keep the template strip on the screen the drag is over
    /// (top-center), hit-test the cursor against the template cells, and preview the
    /// real drop frame for the hovered cell. The window lands on the PALETTE's screen
    /// (where the cells live), not under the cursor — so `currentScreen` tracks it.
    private func updatePaletteDrag(cur: CGPoint, screen: NSScreen?) {
        // Gated on moveConfirmed (the window's origin has actually moved) so a drag
        // that never moves the window — e.g. selecting text in a terminal — doesn't
        // pop the palette. Reliability comes from NOT aborting these modes (see the
        // pre-confirm block): a real window drag keeps polling until it moves, then
        // the strip appears the instant the window starts moving.
        guard moveConfirmed, !dragLayouts.isEmpty else { return }
        if let screen {
            let disp = WindowManager.displayID(of: screen)
            if disp != paletteDisplay || !palette.isShowing {
                paletteDisplay = disp
                currentScreen = screen
                palette.show(layouts: dragLayouts, screen: screen,
                             accent: NSColor(ThemeRuntime.palette.blue))
            }
        }
        // Cursor in a dead gap between displays (screen nil): keep the last palette up.
        let cell = palette.hitTest(cursorAX: cur)
        guard cell != currentCell else { return }
        currentCell = cell
        palette.setHighlight(cell)
        previewPaletteCell(cell)
    }

    /// Ghost the actual frame the window will land in for the hovered palette cell, on
    /// the palette's screen — the cursor is up at the strip, so without this the user
    /// has no on-screen cue where the window goes.
    private func previewPaletteCell(_ cell: Int?) {
        guard let cell, let screen = currentScreen,
              palette.cells.indices.contains(cell) else { footprint.hide(); return }
        let c = palette.cells[cell]
        guard dragLayouts.indices.contains(c.layout),
              dragLayouts[c.layout].zones.indices.contains(c.zone) else { footprint.hide(); return }
        let layout = dragLayouts[c.layout]
        let v = WindowManager.visibleFrameAX(for: screen)
        var targetAX = WindowManager.targetFrame(zone: layout.zones[c.zone].rect,
                                                 visible: v, gap: dragGap)
        // moveOnly layouts keep the window's size and only reposition — preview that,
        // not the full zone, so the footprint matches where the window actually lands.
        if layout.isMoveOnly, let el = win, let cur = WindowManager.axFrame(el) {
            targetAX = CGRect(origin: WindowManager.moveOnlyOrigin(zoneOrigin: targetAX.origin,
                                                                   size: cur.size, visible: v),
                              size: cur.size)
        }
        footprint.show(frameAppKit: WindowManager.axToAppKit(targetAX),
                       style: Preferences.dragSnapStyle,
                       accent: NSColor(ThemeRuntime.palette.blue),
                       zoneChanged: true)
    }

    /// Layout-mode hot path: normalize the cursor over the screen's VISIBLE frame
    /// (NOT the full frame — zones are defined over the visible frame, so anything
    /// else makes the preview disagree with the drop), hit-test it against the
    /// snapshotted layout, and update the overlay highlight.
    private func updateLayoutDrag(cur: CGPoint, screen: NSScreen?) {
        guard let screen, let layout = dragLayout, !layout.zones.isEmpty else {
            setLayoutZone(nil, screen: nil); return
        }
        let v = WindowManager.visibleFrameAX(for: screen)
        guard v.width > 0, v.height > 0 else { setLayoutZone(nil, screen: screen); return }
        let p = CGPoint(x: (cur.x - v.minX) / v.width, y: (cur.y - v.minY) / v.height)
        setLayoutZone(LayoutStore.hitZone(layout.zones, normCursor: p), screen: screen)
    }

    private func setLayoutZone(_ idx: Int?, screen: NSScreen?) {
        currentScreen = screen
        let changed = idx != currentZoneIdx
        currentZoneIdx = idx

        // Gated on moveConfirmed (the window actually moved) so selecting text or
        // dragging a scrollbar doesn't pop the zone overlay. Reliability comes from
        // NOT aborting these modes (see the pre-confirm block): a real window drag
        // keeps polling until it moves, then the overlay appears immediately.
        guard moveConfirmed else { return }
        guard let layout = dragLayout, !layout.zones.isEmpty else {
            layoutOverlay.hide(); layoutSig = nil; return
        }
        guard let screen else {
            // Cursor in the dead gap between mismatched displays (screenContaining
            // → nil). Keep the preview on its last screen and just dim the highlight
            // — tearing the overlay down here fade-churns + rebuilds tiles on every
            // gap crossing mid-drag. currentZoneIdx is already nil, so a release in
            // the gap won't snap; real teardown happens in endDrag/resetDrag.
            layoutOverlay.setHighlight(nil)
            return
        }
        // Tile geometry depends only on (display, layout, gap) — not the hovered
        // zone. Recompute frames + rebuild the overlay ONLY when that signature
        // changes (or the overlay isn't up yet); a plain hover change on the
        // ~120 Hz flood takes the cheap recolor path with zero allocation.
        let sig = LayoutSig(display: WindowManager.displayID(of: screen), layout: layout.id)
        if sig != layoutSig || !layoutOverlay.isShowing {
            layoutSig = sig
            let v = WindowManager.visibleFrameAX(for: screen)
            let framesAX = WindowManager.targetFrames(layout: layout.zones, visible: v, gap: dragGap)
            layoutOverlay.show(zones: layout.zones, framesAX: framesAX, highlight: idx,
                               screen: screen, accent: NSColor(ThemeRuntime.palette.blue))
            return
        }
        guard changed else { return }
        layoutOverlay.setHighlight(idx)
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
        defer { resetDrag(); footprint.hide(); layoutOverlay.hide(); palette.hide() }
        guard dragging, !aborted, moveConfirmed,
              let el = win, let screen = currentScreen else { return }
        switch dragMode {
        case .edges:
            guard let zone = currentZone else { return }
            WindowManager.snap(el, to: zone.action, onScreen: screen)
        case .layouts:
            guard let layout = dragLayout, let idx = currentZoneIdx,
                  layout.zones.indices.contains(idx) else { return }
            WindowManager.snap(el, toZone: layout.zones[idx].rect, onScreen: screen,
                               gap: dragGap, moveOnly: layout.isMoveOnly)
        case .palette:
            guard let cell = currentCell, palette.cells.indices.contains(cell) else { return }
            let c = palette.cells[cell]
            guard dragLayouts.indices.contains(c.layout),
                  dragLayouts[c.layout].zones.indices.contains(c.zone) else { return }
            let layout = dragLayouts[c.layout]
            WindowManager.snap(el, toZone: layout.zones[c.zone].rect, onScreen: screen,
                               gap: dragGap, moveOnly: layout.isMoveOnly)
        }
    }

    private func resetDrag() {
        mouseDownAX = nil
        dragging = false
        aborted = false
        win = nil
        winID = nil
        winInitialOrigin = nil
        winInitialServerOrigin = nil
        moveConfirmed = false
        preConfirmPolls = 0
        currentZone = nil
        currentScreen = nil
        dragMode = .edges
        dragLayout = nil
        dragLayouts = []
        dragGap = 8
        currentZoneIdx = nil
        currentCell = nil
        paletteDisplay = nil
        layoutSig = nil
        layoutOverlay.hide()   // keep overlay visibility in lockstep with layoutSig
        palette.hide()
    }

    /// Px of origin travel (either axis) before a drag counts as a real window move.
    /// Small enough to confirm on the first moving event, large enough that AX/window-
    /// server rounding jitter on a stationary window doesn't false-positive.
    static let moveConfirmEpsilon: CGFloat = 2

    /// True when `now` exists and differs from the captured `start` by more than
    /// `moveConfirmEpsilon` on either axis. A nil `start` (origin unreadable at drag
    /// begin) or nil `now` → not moved yet. Pure → unit-tested; compares one source
    /// against its own initial sample, never crossing AX and window-server spaces.
    static func didMove(from start: CGPoint?, to now: CGPoint?) -> Bool {
        guard let start, let now else { return false }
        return abs(now.x - start.x) > moveConfirmEpsilon || abs(now.y - start.y) > moveConfirmEpsilon
    }

    /// Current cursor in the AX top-left global space (NSEvent is bottom-left).
    private static func cursorAX() -> CGPoint {
        let l = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: l.x, y: h - l.y)
    }
}
