import Foundation

/// Pure, dependency-free safety gate for privileged fan control. No threading, no
/// XPC, no SMC: the daemon serializes every call on its private queue and injects
/// `reset` (the actual `SMCFanController.resetAll()`, true = every fan reset) and
/// `maxCelsius` (its hottest-sensor read). Pulled out of the executable
/// target — exactly like `LidHelperCore` — so the one safety-critical invariant is
/// unit-testable without root or hardware:
///
///   A fan forced to manual must be returned to OS thermal control the moment the
///   last client drops (clean quit OR crash), and on daemon cold start. A fan is
///   NEVER left wedged at a manually-pinned speed when nothing is supervising it.
///
/// Not thread-safe by design; the caller owns serialization.
public final class FanControlCore {
    private let reset: () -> Bool
    private let maxCelsius: () -> Double?

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

    public init(reset: @escaping () -> Bool, maxCelsius: @escaping () -> Double?) {
        self.reset = reset
        self.maxCelsius = maxCelsius
    }

    /// The connection whose manual pin is held, and the RPM it pinned per fan. A drop
    /// of any other connection leaves the pin alone; the supervision tick re-asserts
    /// these targets when the OS reclaims a fan.
    public private(set) var holder: ObjectIdentifier?
    public private(set) var heldTargets: [Int: Double] = [:]
    private var reassertBudget = 0

    /// `setFanManualRPM`. False = refused by the trip latch: the daemon replies false
    /// and writes nothing. True = recorded; the daemon arms supervision and writes.
    /// Crash-safety, holder and target are recorded BEFORE the write on purpose: if
    /// the write half-succeeds and its own fail-closed cleanup also fails, the fan is
    /// left manual, and a drop must still find something to reset. Over-arming on a
    /// clean failure is harmless (reset is idempotent); under-arming strands the fan.
    public func manualRequest(index: Int, rpm: Double, holder: ObjectIdentifier,
                              maxCelsius: @autoclosure () -> Double?) -> Bool {
        guard mayEngageManual(maxCelsius: maxCelsius()) else { return false }
        didSetManual()
        self.holder = holder
        heldTargets[index] = rpm
        reassertBudget = 1
        return true
    }

    /// `setFanAuto` succeeded on `index`. Returns true when the daemon must arm
    /// supervision: the last pinned fan went to auto with the controller unlock kept.
    /// `hasFtst` is only read on that path (it is an SMC read).
    public func autoApplied(index: Int, holdUnlock: Bool, hasFtst: @autoclosure () -> Bool) -> Bool {
        heldTargets[index] = nil
        guard heldTargets.isEmpty, holdUnlock, hasFtst() else { return false }
        didAutoWithHold()
        return true
    }

    /// A connection closed. Only the holder's drop resets the fans.
    public func connectionClosed(_ cid: ObjectIdentifier) {
        guard holder == cid else { return }
        lastClientGone()
        holder = nil
        heldTargets = [:]
    }

    /// What one 30 s supervision tick must do.
    public enum Step: Equatable {
        /// Nothing held: cancel the timer.
        case stop
        /// Kill-switch reset every fan: log, cancel the timer.
        case fired
        /// Nothing to do this tick.
        case keep
        /// The OS reclaimed these fans: write `heldTargets[i]` back to each.
        case reassert([Int])
        /// The reclaim on these fans survived a re-assert: the daemon calls
        /// `releaseAll` and cancels the timer only when it returns true. A failed
        /// reset keeps holder + targets, so the next tick releases again.
        case release([Int])
    }

    /// The supervision tick: kill-switch first, then reclaim detection with one
    /// re-assert before giving the fans up to the OS.
    public func supervise(maxCelsius: @autoclosure () -> Double?,
                          isManualEngaged: (Int) -> Bool) -> Step {
        guard needsSupervision else { return .stop }
        if temperatureTick(maxCelsius: maxCelsius()) { return .fired }
        guard manualHeld, !heldTargets.isEmpty else { return .keep }
        let reclaimed = heldTargets.keys.filter { !isManualEngaged($0) }.sorted()
        if reclaimed.isEmpty { reassertBudget = 1; return .keep }
        if reassertBudget > 0 { reassertBudget -= 1; return .reassert(reclaimed) }
        return .release(reclaimed)
    }

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

    /// Hysteresis for the kill-switch. Once it has reset a manual pin, EVERY client's
    /// manual engages are refused until the hottest sensor is back below this.
    /// Helper-wide, not per connection: an app relaunch (Sparkle update, crash)
    /// re-applies its saved pin over a fresh connection with no temperature check.
    /// Without the band the app re-applied the pin ~1 s after every trip, straight back
    /// into a chassis still above the cut-off, and the switch fired again at its next
    /// tick (563 trips in 3 days on an M4 Pro).
    public static let reArmCelsius: Double = 80

    /// The kill-switch reset a manual pin and the chassis has not re-armed yet.
    public private(set) var tripLatched = false

    /// Periodic temperature check while a manual pin is held. `maxCelsius` is the
    /// hottest sensor the daemon could read (nil = unreadable → no decision; the
    /// 200 RPM floor + the SoC's own throttle remain the backstop). Fires the full
    /// reset and disarms when the threshold is crossed; returns whether it fired so
    /// the daemon can clear its holder and log. A fire on a manual pin latches (see
    /// `mayEngageManual`); a fire on a held unlock alone latches nothing, since no
    /// manual speed was running.
    @discardableResult
    public func temperatureTick(maxCelsius: Double?) -> Bool {
        guard needsSupervision, let t = maxCelsius, t.isFinite,
              t >= Self.killSwitchCelsius else { return false }
        if manualHeld { tripLatched = true }
        _ = reset()
        manualHeld = false
        unlockHeld = false
        holder = nil
        heldTargets = [:]
        return true
    }

    /// Gate for a manual engage from any client after a trip. Refused while latched
    /// and the hottest sensor is unreadable or not yet below `reArmCelsius`; the first
    /// engage below it clears the latch. Nothing else but a daemon cold start clears
    /// it — not a reconnect, not choosing Automatic, not `resetAllFans`. `maxCelsius`
    /// is only read while latched, so the common path costs no SMC reads.
    public func mayEngageManual(maxCelsius: @autoclosure () -> Double?) -> Bool {
        guard tripLatched else { return true }
        guard let t = maxCelsius(), t.isFinite, t < Self.reArmCelsius else { return false }
        tripLatched = false
        return true
    }

    /// An explicit full reset (app disabled fan control / pre-sleep) succeeded —
    /// nothing left wedged, so disarm. A single-fan auto does NOT call this: other
    /// fans may still be manual, and over-resetting on a later drop is harmless while
    /// under-resetting is the hazard.
    public func didResetAll() { manualHeld = false; unlockHeld = false; holder = nil; heldTargets = [:] }

    /// `.release`: reset every fan, and disarm only if that worked. A failed reset
    /// must leave everything held, or supervision stops while the fans are pinned.
    public func releaseAll() -> Bool {
        guard reset() else { return false }
        didResetAll()
        return true
    }

    /// Last client gone (clean OR crash). Reset every fan if a manual pin OR an
    /// unlock hold was outstanding (both are latent hazards nobody supervises once
    /// the client is gone). Idempotent: a second call with nothing held is a no-op.
    public func lastClientGone() {
        guard needsSupervision else { return }
        _ = reset()
        manualHeld = false
        unlockHeld = false
    }

    /// Daemon cold start: force every fan back to auto, self-healing a manual state
    /// left by an unclean kill. Safe by invariant — a valid manual hold always keeps
    /// a live client connection (which keeps the daemon resident), so a cold start
    /// can only find stale values, and a client that still wants manual re-asserts.
    /// The trip latch lives only in this process, and the daemon idle-exits 10 s after
    /// its last client: a start into a chassis at or above the cut-off latches again,
    /// so a relaunched app can't re-pin into it. Unreadable (nil) starts unlatched.
    public func reclaimAtStartup() { reclaimAtStartup(maxCelsius: maxCelsius()) }

    func reclaimAtStartup(maxCelsius: Double?) {
        _ = reset()
        manualHeld = false
        unlockHeld = false
        tripLatched = maxCelsius.map { $0 >= Self.killSwitchCelsius } ?? false   // NaN compares false
    }
}
