import AppKit
import CoreGraphics

/// The scroll fields a `scrollWheel` event carries, read once per event.
/// Value type on the stack — the hot path must not allocate.
struct ScrollFields: Equatable {
    var isContinuous = false
    /// Non-zero while a trackpad/Magic-Mouse gesture is in flight.
    var scrollPhase: Int64 = 0
    var momentumPhase: Int64 = 0
    /// Axis 1 = vertical, axis 2 = horizontal, in all three unit families.
    var line1: Int64 = 0
    var line2: Int64 = 0
    var point1: Int64 = 0
    var point2: Int64 = 0
    var fixed1: Double = 0
    var fixed2: Double = 0
}

/// Exactly which fields the tap writes back; `nil` means "leave that field alone".
struct ScrollWrite: Equatable {
    var line1: Int64?
    var line2: Int64?
    var point1: Int64?
    var point2: Int64?
    var fixed1: Double?
    var fixed2: Double?

    var isEmpty: Bool { line1 == nil && line2 == nil }
}

/// Pure decision core of scroll inversion — no CGEvent, no state, testable.
enum ScrollInvert {
    /// How long after a gesture-phased event a phase-less continuous event is still
    /// assumed to belong to that same trackpad gesture.
    static let gestureWindow: CFTimeInterval = 1.0

    /// Wheel or trackpad? A discrete tick is always a wheel. A continuous stream is a
    /// wheel (Magic Mouse, high-res wheel) only when it carries no gesture phase and
    /// none was seen recently — a trackpad phases every frame of a gesture, but the
    /// stray frames between phases would otherwise read as wheel.
    static func isMouseWheel(_ f: ScrollFields, sinceGesture: CFTimeInterval) -> Bool {
        if !f.isContinuous { return true }
        return f.scrollPhase == 0 && f.momentumPhase == 0 && sinceGesture > gestureWindow
    }

    /// Negate the enabled axes. Discrete events get the LINE deltas only: the window
    /// server re-derives point/fixed-point deltas from them, so writing both flips twice.
    static func write(_ f: ScrollFields, vertical: Bool, horizontal: Bool) -> ScrollWrite {
        var w = ScrollWrite()
        if vertical {
            w.line1 = 0 &- f.line1
            if f.isContinuous { w.point1 = 0 &- f.point1; w.fixed1 = -f.fixed1 }
        }
        if horizontal {
            w.line2 = 0 &- f.line2
            if f.isContinuous { w.point2 = 0 &- f.point2; w.fixed2 = -f.fixed2 }
        }
        return w
    }
}

/// Per-app scroll inversion. Owns its own `scrollWheel` tap, tail-appended at the HID
/// level so anything head-inserted has already had its say, and created only while the
/// feature is on — feature-off means no tap exists, not a callback that returns early.
///
/// Budget: ≤ 50 µs per event. Field reads and a `Set<pid_t>.contains` only; no
/// allocation, no AX, no un-cached window lookups (see `MouseExceptions`).
@MainActor
final class ScrollInvertController {
    static let shared = ScrollInvertController()

    /// Whether `com.prosper.mouse` is enabled + trusted. Set by AppDelegate from the
    /// registry (boot + onEnabledChanged). Defaults FALSE — unlike drag-snap, this
    /// rewrites input system-wide, so an unknown gate state must fail closed.
    var mouseExtLive = false

    /// Marker stamped on scroll events Prosper itself synthesizes (none today; smooth
    /// scroll will). Ours must never be flipped a second time.
    static let syntheticMarker: Int64 = 0x50524F53   // 'PROS'

    private var tap: EventTap?
    private var invertV = false
    private var invertH = false
    private var lastGestureAt: CFTimeInterval = 0
    private let ownPid = Int64(getpid())

    /// Whether the tap currently exists — feature-off must mean no tap at all.
    var isTapped: Bool { tap != nil }

    private init() {}

    /// Reconcile the tap against the prefs + extension-live + Accessibility trust.
    /// Idempotent; call after any of the three changes.
    func reconcile() {
        invertV = Preferences.mouseScrollInvertVertical
        invertH = Preferences.mouseScrollInvertHorizontal
        if mouseExtLive, invertV || invertH, PermissionsManager.isAccessibilityTrusted() {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard tap == nil else { tap?.enable(); return }
        let t = EventTap(label: "scroll-invert", options: .defaultTap, location: .hid,
                         types: [.scrollWheel]) { proxy, type, event in
            ScrollInvertController.shared.handle(proxy, type, event)
        }
        t.enable()
        // tapCreate failed (grant revoked between the check and here) — `enable()` is a
        // no-op then. Leave `tap` nil so the next reconcile retries.
        guard t.isEnabled else { return }
        tap = t
    }

    private func stop() {
        tap?.disable()
        tap = nil
    }

    // MARK: - Hot path

    private func handle(_ proxy: EventTap.Proxy, _ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        // macOS disables a tap that stalls, and on secure input. Without the re-arm the
        // user's scroll silently flips back mid-session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            proxy.enable()
            return event
        }
        guard type == .scrollWheel, invertV || invertH else { return event }

        // Ours: already inverted, or deliberately posted the way we want it.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker
            || event.getIntegerValueField(.eventSourceUnixProcessID) == ownPid { return event }

        var f = ScrollFields()
        f.isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        f.scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        f.momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let now = CACurrentMediaTime()
        if f.scrollPhase != 0 || f.momentumPhase != 0 { lastGestureAt = now }
        guard ScrollInvert.isMouseWheel(f, sinceGesture: now - lastGestureAt) else { return event }
        guard !MouseExceptions.shared.excludesPointerTarget(.scrollInvert) else { return event }

        f.line1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        f.line2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        if f.isContinuous {
            f.point1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            f.point2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            f.fixed1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            f.fixed2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        }

        let w = ScrollInvert.write(f, vertical: invertV, horizontal: invertH)
        if let v = w.line1 { event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: v) }
        if let v = w.line2 { event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: v) }
        if let v = w.point1 { event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: v) }
        if let v = w.point2 { event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: v) }
        if let v = w.fixed1 { event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: v) }
        if let v = w.fixed2 { event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: v) }
        return event
    }
}
