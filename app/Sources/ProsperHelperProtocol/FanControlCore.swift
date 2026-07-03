import Foundation

/// Pure, dependency-free safety gate for privileged fan control. No threading, no
/// XPC, no SMC: the daemon serializes every call on its private queue and injects
/// `reset` (the actual `SMCFanController.resetAll()`). Pulled out of the executable
/// target — exactly like `LidHelperCore` — so the one safety-critical invariant is
/// unit-testable without root or hardware:
///
///   A fan forced to manual must be returned to OS thermal control the moment the
///   last client drops (clean quit OR crash), and on daemon cold start. A fan is
///   NEVER left wedged at a manually-pinned speed when nothing is supervising it.
///
/// Not thread-safe by design; the caller owns serialization.
public final class FanControlCore {
    private let reset: () -> Void

    /// Whether ANY fan has been driven to manual since the last reset. Tracked so a
    /// last-client-drop only pays the (cheap, idempotent) reset when there's actually
    /// something to undo — and so the reset fires for a crash even though no clean
    /// `resetAllFans` ever arrived.
    public private(set) var manualHeld = false

    public init(reset: @escaping () -> Void) { self.reset = reset }

    /// A manual write succeeded — arm the crash-safety reset.
    public func didSetManual() { manualHeld = true }

    /// Temperature kill-switch threshold. Above this, a manual pin is presumed to be
    /// starving the chassis and the OS gets the fans back unconditionally. 95 °C is
    /// past any AS steady-state target (die temps throttle ~105 °C) but below damage
    /// territory — the switch fires before the SoC is forced into hard throttle.
    public static let killSwitchCelsius: Double = 95

    /// Periodic temperature check while a manual pin is held. `maxCelsius` is the
    /// hottest sensor the daemon could read (nil = unreadable → no decision; the
    /// 200 RPM floor + the SoC's own throttle remain the backstop). Fires the full
    /// reset and disarms when the threshold is crossed; returns whether it fired so
    /// the daemon can clear its holder and log.
    @discardableResult
    public func temperatureTick(maxCelsius: Double?) -> Bool {
        guard manualHeld, let t = maxCelsius, t.isFinite,
              t >= Self.killSwitchCelsius else { return false }
        reset()
        manualHeld = false
        return true
    }

    /// An explicit full reset (app disabled fan control / pre-sleep) succeeded —
    /// nothing left wedged, so disarm. A single-fan auto does NOT call this: other
    /// fans may still be manual, and over-resetting on a later drop is harmless while
    /// under-resetting is the hazard.
    public func didResetAll() { manualHeld = false }

    /// Last client gone (clean OR crash). Reset every fan if any manual was held.
    /// Idempotent: a second call with nothing held is a no-op.
    public func lastClientGone() {
        guard manualHeld else { return }
        reset()
        manualHeld = false
    }

    /// Daemon cold start: force every fan back to auto, self-healing a manual state
    /// left by an unclean kill. Safe by invariant — a valid manual hold always keeps
    /// a live client connection (which keeps the daemon resident), so a cold start
    /// can only find stale values, and a client that still wants manual re-asserts.
    public func reclaimAtStartup() {
        reset()
        manualHeld = false
    }
}
