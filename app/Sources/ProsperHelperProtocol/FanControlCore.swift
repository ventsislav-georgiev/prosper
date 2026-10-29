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
    /// Clock seam for the trip time and the settle window. Monotonic and counting
    /// through sleep, so a wall-clock change can neither stretch nor skip the window.
    private let now: () -> ContinuousClock.Instant

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

    public init(reset: @escaping () -> Bool, maxCelsius: @escaping () -> Double?,
                now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.reset = reset
        self.maxCelsius = maxCelsius
        self.now = now
    }

    /// The connection whose manual pin is held, and the RPM it pinned per fan. A drop
    /// of any other connection leaves the pin alone; the supervision tick re-asserts
    /// these targets when the OS reclaims a fan.
    public private(set) var holder: ObjectIdentifier?
    public private(set) var heldTargets: [Int: Double] = [:]
    private var reassertBudget = 0

    /// `setFanManualRPM`. False = refused by the trip latch (`lastRefusal` says why):
    /// the daemon replies false and writes nothing. `currentRPM` is fan `index`'s
    /// speed now, read only while latched (see `mayEngageManual`). True = recorded;
    /// the daemon arms supervision and writes.
    /// Crash-safety, holder and target are recorded BEFORE the write on purpose: if
    /// the write half-succeeds and its own fail-closed cleanup also fails, the fan is
    /// left manual, and a drop must still find something to reset. Over-arming on a
    /// clean failure is harmless (reset is idempotent); under-arming strands the fan.
    public func manualRequest(index: Int, rpm: Double, holder: ObjectIdentifier,
                              maxCelsius: @autoclosure () -> Double?,
                              currentRPM: @autoclosure () -> Double?) -> Bool {
        guard mayEngageManual(rpm: rpm, maxCelsius: maxCelsius(), currentRPM: currentRPM()) else { return false }
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
    /// engage below macOS's own fan speed is refused until the hottest sensor is back
    /// below this (one at or above it may take the fans back, see `reTakeSettleSeconds`).
    /// Helper-wide, not per connection: an app relaunch (Sparkle update, crash)
    /// re-applies its saved pin over a fresh connection with no temperature check.
    /// Without the band the app re-applied the pin ~1 s after every trip, straight back
    /// into a chassis still above the cut-off, and the switch fired again at its next
    /// tick (563 trips in 3 days on an M4 Pro).
    public static let reArmCelsius: Double = 80

    /// After a trip, how long macOS keeps the fans before a pin at or above its own
    /// speed may take them back. The handback is the probe of what macOS wants: a fan
    /// spinning down from the pin needs a few seconds before F<i>Ac shows macOS's
    /// choice. It also bounds the trip → handback → re-pin cycle: before #209 the app
    /// re-pinned ~1 s after every trip (563 trips in 3 days on an M4 Pro).
    public static let reTakeSettleSeconds: Double = 10

    /// The kill-switch reset a manual pin and the chassis has not re-armed yet.
    public private(set) var tripLatched = false
    /// When the latch was last set; a new trip restarts the settle window.
    private var trippedAt: ContinuousClock.Instant?

    /// Why a latched engage was refused.
    public enum Refusal: String, Sendable {
        /// Inside the settle window after the trip.
        case settling
        /// The target is below the speed macOS runs the fan at now.
        case belowMacOS
        /// The hottest sensor or the fan's speed did not read (fail closed).
        case unreadable
    }
    /// The last refusal of this latched episode; nil after a trip, a re-arm or an
    /// unlatched engage. The daemon logs only when it changes, not per attempt.
    public private(set) var lastRefusal: Refusal?

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
        if manualHeld { latch() }
        _ = reset()
        manualHeld = false
        unlockHeld = false
        holder = nil
        heldTargets = [:]
        return true
    }

    private func latch() {
        tripLatched = true
        trippedAt = now()
        lastRefusal = nil
    }

    /// Gate for a manual engage of one fan at `rpm` from any client after a trip.
    /// While latched it is allowed when EITHER the hottest sensor is back below
    /// `reArmCelsius` (which clears the latch), OR the settle window has passed and
    /// `rpm` is at or above the fan's current speed (the latch stays: every later
    /// engage is judged again). Unreadable temperature or speed refuses. Nothing else
    /// but a daemon cold start clears the latch — not a reconnect, not choosing
    /// Automatic, not `resetAllFans`. The reads only happen while latched, so the
    /// common path costs no SMC reads.
    public func mayEngageManual(rpm: Double, maxCelsius: @autoclosure () -> Double?,
                                currentRPM: @autoclosure () -> Double?) -> Bool {
        guard tripLatched else { return true }
        guard let t = maxCelsius(), t.isFinite else { return refuse(.unreadable) }
        if t < Self.reArmCelsius {
            tripLatched = false
            lastRefusal = nil
            return true
        }
        // The rule at the cut-off: never hold a fan below macOS's own speed. Once macOS
        // has had the fans for the settle window, a pin at or above what it runs them
        // at now only cools harder, so it may take them back; slower waits for re-arm.
        guard let trippedAt, now() - trippedAt >= .seconds(Self.reTakeSettleSeconds) else {
            return refuse(.settling)
        }
        guard let current = currentRPM(), current.isFinite else { return refuse(.unreadable) }
        return rpm >= current ? true : refuse(.belowMacOS)
    }

    private func refuse(_ why: Refusal) -> Bool {
        lastRefusal = why
        return false
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
    /// so a relaunched app can't re-pin into it below macOS's speed, and waits out the
    /// settle window from the start. Unreadable (nil) starts unlatched.
    public func reclaimAtStartup() { reclaimAtStartup(maxCelsius: maxCelsius()) }

    func reclaimAtStartup(maxCelsius: Double?) {
        _ = reset()
        manualHeld = false
        unlockHeld = false
        tripLatched = false
        lastRefusal = nil
        if maxCelsius.map({ $0 >= Self.killSwitchCelsius }) ?? false { latch() }   // NaN compares false
    }
}
