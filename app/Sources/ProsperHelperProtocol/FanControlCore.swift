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

    /// Fast-re-engage hold: the client switched fans back to auto but asked to keep
    /// the controller unlocked (`Ftst=1` stays set) so the next manual engage skips
    /// the ~8 s thermalmonitord yield. An unlock hold is a latent hazard exactly like
    /// a manual pin (reclaim is suppressed), so it gets the SAME supervision: the
    /// kill-switch watches it and any client drop / reset / cold start clears it.
    public private(set) var unlockHeld = false

    /// True while anything latent needs the supervision timer.
    public var needsSupervision: Bool { manualHeld || unlockHeld }

    public init(reset: @escaping () -> Void) { self.reset = reset }

    /// A manual write succeeded — arm the crash-safety reset. Manual supersedes a
    /// standing unlock hold (it's strictly more held).
    public func didSetManual() { manualHeld = true; unlockHeld = false }

    /// Fans went back to auto but the controller unlock was kept (fast re-engage
    /// pref). Coarse like `manualHeld`: the UI drives all fans together.
    public func didAutoWithHold() { manualHeld = false; unlockHeld = true }

    /// Temperature kill-switch threshold. Above this, a manual pin is presumed to be
    /// starving the chassis and the OS gets the fans back unconditionally. 95 °C is
    /// past any AS steady-state target (die temps throttle ~105 °C) but below damage
    /// territory — the switch fires before the SoC is forced into hard throttle.
    public static let killSwitchCelsius: Double = 95

    /// Hysteresis for the kill-switch. Once it has reset a client's manual pin, that
    /// client's manual engages are refused until the hottest sensor is back below this.
    /// Without the band the app re-applied the pin ~1 s after every trip, straight back
    /// into a chassis still above the cut-off, and the switch fired again at its next
    /// tick (563 trips in 3 days on an M4 Pro).
    public static let reArmCelsius: Double = 80

    /// The client whose manual pin the kill-switch reset; nil when nothing is latched.
    public private(set) var tripLatchedClient: ObjectIdentifier?

    /// Periodic temperature check while a manual pin is held. `maxCelsius` is the
    /// hottest sensor the daemon could read (nil = unreadable → no decision; the
    /// 200 RPM floor + the SoC's own throttle remain the backstop). Fires the full
    /// reset and disarms when the threshold is crossed; returns whether it fired so
    /// the daemon can clear its holder and log. A fire on a manual pin latches
    /// `holder` (see `mayEngageManual`); a fire on a held unlock alone latches nothing,
    /// since no manual speed was running.
    @discardableResult
    public func temperatureTick(maxCelsius: Double?, holder: ObjectIdentifier? = nil) -> Bool {
        guard needsSupervision, let t = maxCelsius, t.isFinite,
              t >= Self.killSwitchCelsius else { return false }
        if manualHeld { tripLatchedClient = holder }
        reset()
        manualHeld = false
        unlockHeld = false
        return true
    }

    /// Gate for a manual engage from `client` after a trip. Refused while `client` is
    /// latched and the hottest sensor is unreadable or not yet below `reArmCelsius`;
    /// the first engage below it clears the latch. `maxCelsius` is only read while
    /// latched, so the common path costs no SMC reads.
    public func mayEngageManual(client: ObjectIdentifier, maxCelsius: @autoclosure () -> Double?) -> Bool {
        guard tripLatchedClient == client else { return true }
        guard let t = maxCelsius(), t.isFinite, t < Self.reArmCelsius else { return false }
        tripLatchedClient = nil
        return true
    }

    /// The latched client handed the fans back itself (chose Automatic, or its
    /// connection closed). Its next manual engage is the user's explicit re-enable.
    /// Not called for `resetAllFans`: the app's own reclaim retry sends that too.
    public func clientReleased(_ client: ObjectIdentifier) {
        if tripLatchedClient == client { tripLatchedClient = nil }
    }

    /// An explicit full reset (app disabled fan control / pre-sleep) succeeded —
    /// nothing left wedged, so disarm. A single-fan auto does NOT call this: other
    /// fans may still be manual, and over-resetting on a later drop is harmless while
    /// under-resetting is the hazard.
    public func didResetAll() { manualHeld = false; unlockHeld = false }

    /// Last client gone (clean OR crash). Reset every fan if a manual pin OR an
    /// unlock hold was outstanding (both are latent hazards nobody supervises once
    /// the client is gone). Idempotent: a second call with nothing held is a no-op.
    public func lastClientGone() {
        guard needsSupervision else { return }
        reset()
        manualHeld = false
        unlockHeld = false
    }

    /// Daemon cold start: force every fan back to auto, self-healing a manual state
    /// left by an unclean kill. Safe by invariant — a valid manual hold always keeps
    /// a live client connection (which keeps the daemon resident), so a cold start
    /// can only find stale values, and a client that still wants manual re-asserts.
    public func reclaimAtStartup() {
        reset()
        manualHeld = false
        unlockHeld = false
        tripLatchedClient = nil
    }
}
