import Foundation
import AppKit
import ProsperHelperProtocol
import SMCKit
import os

/// One fan's identity + range, read UNPRIVILEGED (SMC reads need no root — only
/// writes do). Drives the settings sliders. `current` is the live RPM at read time; nil = no usable
/// reading (#1223: `FanInfo.current`), never non-finite.
struct FanReading: Identifiable, Equatable {
    let id: Int          // SMC fan index
    let min: Double
    let max: Double
    let current: Double?
    /// Whether the fan is manually engaged on the HARDWARE right now (mode key +
    /// Ftst, unprivileged reads). Lets the UI detect an OS reclaim: user thinks
    /// manual, hardware says auto → flip the toggle honestly.
    let manual: Bool
}

enum FanReclaimRecovery {
    static let minimumManualFraction = 0.2

    /// Pause after a reclaim re-apply failed before the timer tries again. After a
    /// kill-switch trip the helper refuses every engage for its settle window, then
    /// lets a pin at or above macOS's own speed take the fans back (#586). A refusal
    /// lands at or after the trip, so one window later the retry is past it: the
    /// user's speed comes back ~10-14 s after a trip instead of a whole minute. A pin
    /// below macOS's speed stays refused until the re-arm, asked once per window
    /// (each failed attempt costs a resetAllFans).
    static let retryCooldown: TimeInterval = FanControlCore.reTakeSettleSeconds

    enum Disposition: Equatable {
        case abandonManualIntent
        case restored
        case retry
    }

    /// `pending` = the saved targets have not landed since they were saved (#737: a preset made
    /// while the helper's latch refused it, or saved intent at launch). The floor guards against
    /// re-pinning a low speed macOS took back; a preset that never ran is held instead, and the
    /// helper's own gate keeps it off a hot Mac (nothing below macOS's speed until it re-arms).
    static func disposition(manualFraction: Double, reengaged: Bool, pending: Bool = false) -> Disposition {
        guard manualFraction.isFinite, manualFraction >= minimumManualFraction || pending else {
            return .abandonManualIntent
        }
        return reengaged ? .restored : .retry
    }

    /// #737: the popup's pending line. Manual intent is on and macOS still has every adjustable
    /// fan, so the saved preset is waiting for recovery; nil once the helper takes the fans.
    static func pendingText(manualIntent: Bool, readings: [FanReading], targets: [Int: Double]) -> String? {
        guard manualIntent, reclaimDetected(readings),
              let fraction = manualFraction(targets: targets, readings: readings) else { return nil }
        return pendingSentence(StatsFormat.percent(Swift.min(1, Swift.max(0, fraction))))   // #1223: clamped, percent() does Int()
    }

    /// Entry 1041: the one sentence for a preset the helper's latch refused (refused, settling, settlingReported), on the
    /// popup's pending line and in the phone's "Manual pending" answer. The recovery applies it, not the person.
    static func pendingSentence(_ percent: String) -> String {
        "Waiting for macOS to hand back the fans. Prosper sets \(percent) as soon as it can."
    }

    /// `userAdjusting` = a slider drag / quick-button commit is in flight. The saved
    /// targets are stale for those few hundred ms (the commit is debounced), so a
    /// recovery started now would push the PREVIOUS speed to the hardware and fight
    /// the user. Suspended only while the gesture is live; the very next tick resumes.
    static func canStartRecovery(manualIntent: Bool, sleeping: Bool, recoveryInFlight: Bool,
                                 userAdjusting: Bool = false) -> Bool {
        manualIntent && !sleeping && !recoveryInFlight && !userAdjusting
    }

    static func reclaimDetected(_ readings: [FanReading]) -> Bool {
        let adjustable = readings.filter { $0.max > $0.min }
        return !adjustable.isEmpty && adjustable.allSatisfy { !$0.manual }
    }

    /// The recovery acts once macOS has every fan, or (R1223-3) when the saved targets read none
    /// (damaged from outside) while the helper still holds pins: nothing to re-apply, so manual goes
    /// off and every fan back. Not with an engage in flight: it is about to save new targets.
    static func shouldRecover(_ readings: [FanReading], targetsEmpty: Bool, inFlight: Int) -> Bool {
        reclaimDetected(readings) || (targetsEmpty && inFlight == 0)
    }

    static func manualFraction(targets: [Int: Double], readings: [FanReading]) -> Double? {
        let fractions = readings.compactMap { fan -> Double? in
            guard fan.max > fan.min, let target = targets[fan.id] else { return nil }
            return (target - fan.min) / (fan.max - fan.min)
        }
        guard !fractions.isEmpty else { return nil }
        return fractions.reduce(0, +) / Double(fractions.count)
    }
}

/// Who owns the fan targets the popup shows: the user while an adjustment is in
/// flight, the persisted store the rest of the time.
///
/// The popup re-seeds its `fanTargets` from `Preferences.fanTargets` on every fan
/// poll tick (~1 s while manual). The slider's commit is debounced 0.4 s and the
/// debounce keeps being cancelled while the user keeps dragging — so mid-drag the
/// store still holds the PREVIOUS speed, and that re-seed snapped the slider back,
/// over and over, for the whole gesture. Ownership makes the in-flight value
/// authoritative until the commit it scheduled is actually visible in the store.
/// Outcome of one `setFanManualRPM`, split by WHO said no: the helper itself replying
/// false (#209: its kill-switch latch holds after a 95 °C trip) vs. never reaching it
/// (not registered/approved, XPC error, timeout).
enum FanManualReply: Equatable {
    case engaged
    case refused       // live helper replied false; the target is below macOS's speed
    case settling      // live helper replied false; the target is at or above it (#586)
    case unavailable   // no reply from the helper
    case needsApproval // the helper's Login Items switch is off (#728); the popup words it as unavailable
    case writeFailed   // live helper replied false where its heat gate was open (#1033, see `afterAnAccept`)
    /// Entry 1234: the helper's OWN reason said settling (FanEngageCode 1). `.settling` is the app's guess from a
    /// Bool false (an older helper, or the identity answer not in yet), which `afterAnAccept` still renames.
    case settlingReported

    /// #737: a live helper's refusal (its latch) makes the user's speed a pending preset;
    /// no reply (.unavailable / .needsApproval) stays a failure.
    var isLatchRefusal: Bool { self == .refused || self == .settling || self == .settlingReported }

    /// Entry 1234: a `setFanManualRPMWithReason` code. Outside data from the helper: compared only, never an
    /// index or a conversion. Unreadable, inert and every value outside 0...5 read as a write failure: the
    /// reply that hands back the most (a Manual click saves nothing; a commit keeps the previous targets).
    static func reason(_ code: Int) -> FanManualReply {
        switch code {
        case FanEngageCode.engaged.rawValue: return .engaged
        case FanEngageCode.settling.rawValue: return .settlingReported
        case FanEngageCode.belowMacOS.rawValue: return .refused
        case FanEngageCode.unreadable.rawValue: return .writeFailed
        case FanEngageCode.writeFailed.rawValue: return .writeFailed
        case FanEngageCode.inert.rawValue: return .writeFailed
        default: return .writeFailed
        }
    }

    /// #1033: this reply from a later fan of a request whose earlier fan the helper just accepted.
    /// That accept proved the heat gate open, and only a trip or a handback restarts its settle
    /// window (FanControlCore.latch / pinHandedBack), so a false at or above macOS's speed is not
    /// the window: the SMC write threw, or the helper could not read its sensors. The Bool reply
    /// cannot say which, nor split a false below macOS's speed. Entry 1234: a helper that gives its
    /// reason replies `.settlingReported`, never renamed here.
    var afterAnAccept: FanManualReply { self == .settling ? .writeFailed : self }

    /// Name a live helper's `false` by the helper's rule (#586): after a trip it lets a
    /// pin at or above macOS's speed for the fan (`FanControlCore.macOSSpeed`) take the
    /// fans back once its settle window passed, so a refusal of such a pin is the window.
    /// Below that speed, or with it unreadable, it holds until the Mac cools down.
    static func refusal(rpm: Double, macOSRPM: Double?) -> FanManualReply {
        guard let macOSRPM, macOSRPM.isFinite, rpm >= macOSRPM else { return .refused }
        return .settling
    }

    /// The single status line the fan popup shows for a failed engage/commit.
    // shortcut: from an older helper (the Bool reply) a first fan's false, or a later one below macOS's speed,
    // is still read as the latch though it also replies false when the SMC write throws; a reason splits it (1234).
    var errorText: String? {
        // Entry 1208: a helper from an older version gives no reason, so these two names are the app's guess.
        let old = FanControlHelper.oldHelperAnswers.withLock { $0 } ? " " + Self.oldHelperSentence : ""
        switch self {
        case .engaged: return nil
        case .refused:
            return "Fans are held automatic until the Mac cools down — the overheat "
                + "cut-off tripped, and macOS runs them faster than this. Try again in a few "
                + "minutes, or pick a faster speed." + old
        case .settling, .settlingReported:
            return "The overheat cut-off just handed the fans to macOS. "
                + "Try again in a few seconds." + old
        case .unavailable, .needsApproval:
            return "Couldn’t enable manual control — the Prosper helper isn’t "
                + "running or wasn’t approved. Turn on “Prosper” under System Settings ▸ "
                + "General ▸ Login Items ▸ Allow in the Background, then try again."
        case .writeFailed:
            return "A fan didn’t take the new speed, so macOS runs every fan again. Try again."
        }
    }

    /// Entry 1208: added to a refusal while `FanControlHelper.helperIdentity` is `.old`.
    static let oldHelperSentence = "The Prosper helper is from an older version, so Prosper can’t tell why."
}

/// R1218-1: a fan speed the app may send, save or seed from: finite, above 0, under SMCFanController's
/// 20 000 rpm sanity ceiling (its bounds read refuses a fan at or over it). Anything else: that fan stays
/// with macOS.
enum FanRPM {
    static func usable(_ rpm: Double) -> Bool { rpm.isFinite && rpm > 0 && rpm < 20_000 }
}

/// #1033, the one rule for a slider commit: afterwards either every fan runs the targets the slider and
/// the saved targets show, or every fan is handed back to macOS and the slider and the saved targets
/// show a pending preset (the popup's "Waiting for macOS…" line) - never a split. When in doubt, macOS.
enum FanCommit: Equatable {
    /// Every fan took `targets`.
    case landed
    /// The helper's heat latch refused: every fan to macOS, `targets` wait as the preset (#737).
    case keepNew(FanManualReply)
    /// No reply, or a write failure: every fan to macOS, the previous targets wait as the preset. "Previous"
    /// is the last ASKED targets (saved before this burst), not the last landed ones (R1215-2).
    case keepPrevious(FanManualReply)
    /// Manual went off while the commit was in flight (Automatic, here or from the phone): every fan
    /// to macOS, nothing saved.
    case release

    /// `replies` = engageAll's per-fan results in engage order; `fans` = how many fans the commit
    /// asked for. Anything short of one .engaged per fan is not landed.
    static func decide(_ replies: [FanManualReply], fans: Int, manualEnabled: Bool) -> FanCommit {
        guard manualEnabled else { return .release }
        guard let failed = replies.firstIndex(where: { $0 != .engaged }) else {
            return replies.count == fans ? .landed : .keepPrevious(.unavailable)
        }
        let reply = failed > 0 ? replies[failed].afterAnAccept : replies[failed]
        return reply.isLatchRefusal ? .keepNew(reply) : .keepPrevious(reply)
    }
}

struct FanTargetOwner: Equatable {
    /// The user's in-flight targets; nil = the store owns the value.
    private(set) var user: [Int: Double]?
    /// What the store held when the user took ownership — a change to anything else
    /// means someone else (auto-switch, reclaim recovery) wrote, and wins.
    private var storeAtClaim: [Int: Double] = [:]
    /// True between the slider's drag-begin and drag-end.
    var isDragging = false

    /// The user moved the slider or hit a quick button.
    mutating func userSet(_ targets: [Int: Double], store: [Int: Double]) {
        if user == nil { storeAtClaim = store }
        user = targets
    }

    /// A poll tick re-read the store. Returns the targets the UI should display, and
    /// hands ownership back once the store agrees with the user's value (the debounced
    /// commit landed) or a third party wrote something else.
    mutating func display(store: [Int: Double]) -> [Int: Double] {
        guard let user else { return store }
        if isDragging { return user }
        if store == user || store != storeAtClaim { self.user = nil; return store }
        return user
    }
}

/// Unprivileged fan enumeration for the UI. Opens a throwaway SMC connection,
/// reads count + bounds + current RPM, closes. Returns [] on any board with no SMC
/// or no readable fans (Apple Silicon laptops with no fan, VMs) → the UI hides the
/// whole section. ponytail: read on demand (settings open), not polled — fan specs
/// don't change at runtime; current RPM is a point-in-time hint, not a live gauge.
enum FanInfo {
    /// One fan's speed by the helper's rule (`FanControlCore.macOSSpeed` of F<i>Ac and
    /// F<i>Tg), nil when unreadable.
    static func macOSRPM(_ index: Int) -> Double? {
        guard let smc = try? SMC() else { return nil }
        let fc = SMCFanController(smc)
        return FanControlCore.macOSSpeed(current: fc.currentRPM(index), target: fc.targetRPM(index))
    }

    static func read() -> [FanReading] {
        guard let smc = try? SMC() else { return [] }
        let fc = SMCFanController(smc)
        let n = fc.fanCount()
        guard n > 0 else { return [] }
        return (0..<n).compactMap { i in
            guard let b = fc.bounds(i) else { return nil }   // degenerate bounds → skip (write would fail closed anyway)
            return FanReading(id: i, min: b.min, max: b.max, current: current(fc.currentRPM(i)),
                              manual: fc.isManualEngaged(i))
        }
    }

    /// #1223: the raw F<i>Ac read as the app may use it. A real speed (finite, 0 for a stopped fan, under
    /// SMCFanController's 20 000 rpm ceiling) stays; unreadable, NaN, an infinity, negative or huge is nil
    /// ("no reading"), never 0: a stopped fan reads 0 and must stay a normal Manual click.
    static func current(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, raw >= 0, raw < 20_000 else { return nil }
        return raw
    }
}

/// App-side client for privileged fan control. Writing fan state needs root, so it
/// goes through the SAME daemon as the lid-sleep override (`ProsperHelper`) over a
/// SEPARATE XPC connection — the daemon counts every client, and a manual fan pin is
/// crash-safe exactly like the lid override: when the last client drops the daemon
/// resets every fan to auto.
///
/// Everything is LAZY and opt-in. Nothing touches the daemon until the user turns on
/// manual fan control in System Stats settings (default OFF). Registration is shared
/// with `LidSleepHelper` (same daemon, same SMAppService item).
///
/// THERMAL SAFETY — a manual fan pin is NEVER left supervising itself:
///   • daemon cold start  → resetAllFans (self-heal a stuck pin)
///   • last client drops  → resetAllFans (app crash)
///   • system sleep       → we push resetAllFans, then re-assert on wake
///   • user disables       → resetAllFans + connection torn down
@MainActor
enum FanControlHelper {
    nonisolated private static let log = Logger(subsystem: "eu.illegible.prosper", category: "fanhelper")
    private(set) static var connection: NSXPCConnection?
    /// Engages holding `connection` right now; a teardown waits for them (#263).
    private(set) static var engagesInFlight = 0
    /// Test seam: the teardown-guard test injects a fake connection and in-flight count.
    static func inject(connection c: NSXPCConnection?, engagesInFlight n: Int) { connection = c; engagesInFlight = n }
    static func inject(sleeping s: Bool) { sleeping = s }
    /// willSleep/didWake tokens; non-empty = installed. Kept so tests can remove them.
    private(set) static var sleepObserverTokens: [NSObjectProtocol] = []
    private static var observersInstalled: Bool { !sleepObserverTokens.isEmpty }
    private static var reclaimTimer: Timer?
    private static var reclaimReadInFlight = false
    private static var reclaimRecoveryInFlight = false
    private static var sleeping = false
    private static var wakeRecoveryPending = false
    /// Bumped ONLY by willSleep. The popup engage flow (firstEngageLanded/engageRest) treats
    /// any bump as "a sleep happened" and abandons, so a new bump site would turn Manual
    /// clicks into silent no-ops (#345; pinned by a source scan in FanReclaimRecoveryTests).
    private(set) static var reclaimGeneration = 0
    /// R1223-a: bumped by every Automatic the user chooses, all through `StatsPopupView.selectAuto` (the popup's,
    /// the phone's "Fans: Auto", a refusal ending in Automatic). An engage started before a bump saves nothing
    /// and hands its pins back: the last word "Automatic" wins over an older Manual click.
    /// N1234-d: a run of late pins ends at an Automatic (manual goes off there, nothing re-applies).
    static var automaticGeneration = 0 { didSet { lateLandings = 0 } }
    private static var reclaimRetryNotBefore = Date.distantPast

    /// Set by the popup while a slider drag / quick-button commit is in flight, so
    /// reclaim recovery can't reapply the stale saved target on top of the gesture.
    static var userAdjusting = false

    /// #737: the saved targets have not landed since they were saved (a preset the latch
    /// refused, or saved intent at launch). Exempts them from the 20 % floor until a re-apply
    /// lands; cleared by any engage of the saved targets.
    // ponytail: in-memory; a relaunch re-sets it through reapplyFromPreferences.
    static var presetPending = false

    /// The fan a live helper refused last (#926). `engageOrder` engages it first, so a request
    /// that stops at its first refused fan pins no sibling just to hand it back.
    // ponytail: in-memory and never cleared; it only orders the fans.
    static var lastRefusedFan: Int?

    // MARK: - Connection

    private static func makeConnection() -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: ProsperHelperProtocol.self)
        // @Sendable: XPC calls it on its own queue, never inferred MainActor (#477).
        // c is only compared by identity, on main.
        nonisolated(unsafe) let conn = c
        // Entry 1208: a drop from the helper's side may be an update's old helper going: ask again.
        let clear: @Sendable () -> Void = { Task { @MainActor in fanConnectionDropped(conn) } }
        c.invalidationHandler = clear
        c.interruptionHandler = clear
        c.resume()
        return c
    }

    /// The fan connection dropped from the helper's side (its interruption or invalidation handler, on main):
    /// forget it and ask again at the next idle moment (entry 1208: it may be an update's old helper going).
    /// Entry 1234: an interruption on the reason call ends here too, so the next engage sends the Bool method.
    static func fanConnectionDropped(_ c: NSXPCConnection) {
        if connection === c { connection = nil; helperMayHaveChanged() }
    }

    /// Open (or reuse) the daemon connection, lazily registering the shared helper.
    /// Returns nil when registration isn't available (e.g. unsigned dev build) — the
    /// caller then leaves fans on auto. `presentModal: false` is the phone's (#728): an
    /// unapproved helper comes back as `.needsApproval`, never as a modal on an unattended Mac.
    private static func ensureConnection(presentModal: Bool = true) async -> (NSXPCConnection?, LidSleepHelper.RegisterOutcome) {
        let outcome = await LidSleepHelper.ensureRegisteredOutcome(feature: "Manual fan control", presentModal: presentModal)
        guard outcome == .enabled else { return (nil, outcome) }
        if connection == nil { fanConnectionMade() }   // entry 1208: a stale old verdict goes back to unknown
        let c = connection ?? makeConnection()
        connection = c
        return (c, outcome)
    }

    // MARK: - Public ops (called from the settings pane + wake/sleep)

    /// Force one fan to a manual RPM. Holds the connection open so the daemon keeps
    /// the manual pin alive; a drop (crash/disable) resets it. Returns success.
    @discardableResult
    static func setManual(_ index: Int, rpm: Double, timeout: TimeInterval = 12, presentModal: Bool = true) async -> Bool {
        await setManualReply(index, rpm: rpm, timeout: timeout, presentModal: presentModal) == .engaged
    }

    /// `setManual` keeping the helper's refusal apart from an unreachable helper.
    /// `macOSRPM` (the test seam) is read off-main, and only on a refusal. `arm` (R1234b-1, the test seam) arms the
    /// recovery lifecycle, on main before the call; a row passes a no-op so no real timer or observer is installed.
    static func setManualReply(_ index: Int, rpm: Double, timeout: TimeInterval = 12, presentModal: Bool = true,
                               macOSRPM: @escaping @Sendable (Int) -> Double? = { FanInfo.macOSRPM($0) },
                               arm: () -> Void = { armRecoveryLifecycle() }) async -> FanManualReply {
        // R1218-1: never send an unusable speed; a failure every caller hands back on (not the latch).
        guard FanRPM.usable(rpm) else { return .writeFailed }
        // In flight from before the registration await: a willSleep while this engage
        // waits there must still reset the fans an earlier engage pinned (#343).
        engagesInFlight += 1
        defer { engagesInFlight -= 1 }
        let (opened, outcome) = await ensureConnection(presentModal: presentModal)
        guard let c = opened else { return outcome == .needsApproval ? .needsApproval : .unavailable }
        // A manual write is manual intent, even before the popup saves the pref (it
        // saves it only after the first engage lands), so this arms unconditionally.
        arm()
        // Entry 1234: the method is chosen once, here on main, before the call: the reason method only while the
        // helper said it answers it. A verdict that changes while this engage is in flight does not re-send it.
        let reason: OSAllocatedUnfairLock<Int?>? = helperIdentity == .current ? OSAllocatedUnfairLock(initialState: nil) : nil
        let late: @Sendable (Bool) -> Void = { ok in Task { @MainActor in lateReplyLanded(ok) } }
        switch await callReply(c, timeout: timeout, late: late, { proxy, done in
            if let reason { proxy.setFanManualRPMWithReason(index, rpm: rpm) { code in reason.withLock { $0 = code }; done(code == 0) } }
            else { proxy.setFanManualRPM(index, rpm: rpm) { done($0) } }
        }) {
        case true?: lateLandings = 0; return .engaged   // R1230-2: landed in time
        case false?:
            lastRefusedFan = index
            // Entry 1234: the helper's own reason, with no speed read (no code kept reads -1)...
            if let reason {
                let said = FanManualReply.reason(reason.withLock { $0 } ?? -1)
                // ...except below macOS's speed, still named by the app's read as before: where the two reads differ
                // that names it settling, and a Manual click's later fan then saves nothing (a preset would re-apply).
                guard said == .refused else { return said }
            }
            return .refusal(rpm: rpm, macOSRPM: await Task.detached(priority: .utility) { macOSRPM(index) }.value)
        case nil: return .unavailable
        }
    }

    /// The popup's first engage replied; true = engaged. On failure `release` everything (with no
    /// saved manual intent nothing will ever recover, so also drop the 2 s reclaim timer that
    /// engage armed): an older engage that landed late while
    /// this one was in flight was held for it (#263). Fire-and-forget so the button
    /// resolves now; a retry racing it is covered by the teardown guard in `resetAll`.
    /// An engage that lands after a willSleep since `generation` (captured before the
    /// engage) is released and reported false: asleep, the pin would ride through sleep
    /// (#287); after a whole sleep+wake, willSleep already reset the fan, so saving the
    /// pref would claim a pin that is gone (#345). The generation covers a sleep after the
    /// capture; `sleeping` covers a capture taken while already asleep (a willSleep fired
    /// before the click, and the Mac has not slept yet or didWake has not cleared it, #347).
    static func firstEngageLanded(_ reply: FanManualReply, since generation: Int,
                                  current: Int = Self.reclaimGeneration, sleeping: Bool = Self.sleeping,
                                  release: @escaping @MainActor () async -> Void = { await sleepSafeRelease() }) -> Bool {
        guard reply != .engaged else {
            guard current == generation, !sleeping else { Task { await release() }; return false }
            return true
        }
        // R1215-1: with manual on too. A timed-out engage may still pin its fan at the new speed while the
        // others and the saved targets keep the old one; the release (no teardown with manual on) follows
        // that pin on the helper's one queue, and the recovery re-applies the saved targets, kept as they are.
        if !Preferences.fanManualEnabled { removeReclaimMonitor() }
        Task { await release() }
        return false
    }

    /// A later popup engage (a fan after the first) replied; false = stop, do not save
    /// the pref. A willSleep since `generation` (the loop's start; it bumps
    /// `reclaimGeneration`) releases every pin the popup made: asleep, a pin here would
    /// ride through sleep (#306); after a whole sleep+wake, willSleep reset the fans
    /// pinned so far, so saving the pref now would claim pins that are gone (#343).
    /// A failed engage is engageRest's to act on (#926), after this check.
    static func laterEngageLanded(since generation: Int, current: Int = Self.reclaimGeneration,
                                  release: @escaping @MainActor () async -> Void = { await sleepSafeRelease() }) -> Bool {
        guard current != generation else { return true }
        Task { await release() }
        return false
    }

    /// The popup's engage of every fan after the first, in `engageOrder`. `.engaged` = every fan
    /// landed; nil = a sleep stopped it (released, do not save the pref); any other reply is the
    /// first fan that did not engage, named as after an accept (#1215: a .settling is .writeFailed,
    /// as in the slider commit), and the request stops there (#926: one decision for every fan; the
    /// caller hands back what landed). `generation` is the popup's, captured before its first
    /// engage (#345). `engage`/`landed` are the test seams.
    static func engageRest(_ targets: [Int: Double], skipping first: Int, since generation: Int = Self.reclaimGeneration,
                           engage: (Int, Double) async -> FanManualReply = { await setManualReply($0, rpm: $1) },
                           landed: (Int) -> Bool = { laterEngageLanded(since: $0) }) async -> FanManualReply? {
        for (i, rpm) in engageOrder(targets) where i != first {
            let reply = await engage(i, rpm)
            guard landed(generation) else { return nil }
            // Entry 1234: the helper's own settling too: as a pending preset the recovery would re-apply it, where
            // today's write failure saves nothing (only more hand-back wins over the reason). N1234-a: the slider
            // commit (FanCommit.decide) keeps keepNew(.settlingReported) because there it replaces keepPrevious, which
            // saves and re-applies the previous targets just the same (equal hand-back); a click has no previous intent
            // to keep, so here the choice is a preset or nothing, and nothing hands back more.
            guard reply == .engaged else { return reply == .settlingReported ? .writeFailed : reply.afterAnAccept }
        }
        return .engaged
    }

    /// The order a request engages its fans (#926): the fan the helper refused last first, then
    /// by index. Every request stops at its first failed fan, so while one fan's speed is below
    /// macOS's and a sibling's is not, a retry is refused before it pins the sibling: no pin and
    /// handback every cooldown (each handback restarts the helper's settle window).
    static func engageOrder(_ targets: [Int: Double], refusedFirst: Int? = lastRefusedFan) -> [(key: Int, value: Double)] {
        targets.sorted { ($0.key == refusedFirst ? 0 : 1, $0.key) < ($1.key == refusedFirst ? 0 : 1, $1.key) }
    }

    /// The slider commit's burst (#926): every fan in `engageOrder`, stopping at the first that
    /// does not engage. Returns each fan's reply in that order, for `FanCommit.decide` (#1033).
    /// `engage` is the test seam.
    static func engageAll(_ targets: [Int: Double],
                          engage: (Int, Double) async -> FanManualReply = { await setManualReply($0, rpm: $1) }) async -> [FanManualReply] {
        var replies: [FanManualReply] = []
        for (i, rpm) in engageOrder(targets) {
            replies.append(await engage(i, rpm))
            guard replies.last == .engaged else { break }
        }
        return replies
    }

    /// The popup's Manual click, from the click to the saved pref; `saved` = every fan engaged
    /// and the pref is written. The generation AND the sleeping flag are captured at the click,
    /// before the first engage: a sleep after it moves the generation (#345); a click taken
    /// while asleep (willSleep fired, the Mac not yet asleep) is refused even when its reply
    /// lands after didWake cleared the flag (#390). No await between the last check and the save.
    /// `engageFirst` is the first engage; `firstLanded`/`engage`/`landed` are the test seams.
    /// #737: a live helper refusing the first engage (its overheat latch) saves the targets as a
    /// pending preset — `saved` with the refusal as `reply` — under the same sleep checks; the
    /// reclaim recovery applies it once the helper accepts. The refusal pinned nothing.
    static func popupEngage(_ targets: [Int: Double], first: Int,
                            engageFirst: () async -> FanManualReply,
                            firstLanded: (FanManualReply, Int, Bool) -> Bool = {
                                firstEngageLanded($0, since: $1, sleeping: $2 || Self.sleeping) },
                            engage: (Int, Double) async -> FanManualReply = { await setManualReply($0, rpm: $1) },
                            landed: (Int) -> Bool = { laterEngageLanded(since: $0) })
        async -> (saved: Bool, reply: FanManualReply) {
        let generation = reclaimGeneration, asleepAtClick = sleeping, automatic = automaticGeneration
        let reply = await engageFirst()
        // R1223-a: a refusal after an Automatic since the click goes on to firstLanded's failure release.
        if reply.isLatchRefusal, generation == reclaimGeneration, !asleepAtClick, !sleeping, automatic == automaticGeneration {
            savePreset(targets)
            return (true, reply)
        }
        guard firstLanded(reply, generation, asleepAtClick) else { return (false, reply) }
        guard let rest = await engageRest(targets, skipping: first, since: generation, engage: engage, landed: landed) else {
            return (false, reply)
        }
        // #926: a later fan's reply does what it does on the first fan, and this click's pins go back
        // to macOS. A live refusal makes the targets the pending preset (savePreset hands the fans
        // back); no reply (#737) or a write failure (#1215) stays a failure: nothing saved, released
        // like a failed first engage.
        // engageRest's last `landed` check ran after its last await: no await from there to here.
        // R1223-a: Automatic chosen on either surface since the click: save nothing; this click's pins go back
        // like a late pin (held only for a newer engage in flight, which owns the fans). A failure keeps its release.
        if automatic != automaticGeneration, rest == .engaged || rest.isLatchRefusal {
            lateEngageLanded(true)
            return (false, reply)
        }
        guard rest == .engaged else {
            if rest.isLatchRefusal { savePreset(targets) } else { Task { await sleepSafeRelease() } }
            return (rest.isLatchRefusal, rest)
        }
        Preferences.fanManualEnabled = true
        Preferences.fanTargets = targets
        presetPending = false
        return (true, reply)
    }

    /// #737: the helper's latch refused `targets`: keep them as manual intent and let the
    /// recovery lifecycle apply them when it can, the next attempt one settle window out
    /// (the refusal just happened). The refusal pinned nothing, but `reset` (no teardown) hands
    /// macOS any fan still pinned (a sibling that took the speed, an older pin): recovery and
    /// the pending line both need every fan back on auto. The helper gates every re-apply.
    static func savePreset(_ targets: [Int: Double], now: Date = Date(),
                           reset: @escaping @MainActor () async -> Void = { _ = await resetAll() }) {
        let targets = targets.filter { FanRPM.usable($0.value) }   // R1218-1: a dropped fan stays with macOS
        Preferences.fanManualEnabled = true
        Preferences.fanTargets = targets
        presetPending = true
        deferReclaimRetry(now: now)
        armRecoveryLifecycle()
        Task { await reset() }
    }

    /// An engage replied after `callReply` already gave up on it (timeout / XPC error):
    /// the helper pinned the fan anyway. With manual off nothing else will release it
    /// (the reclaim re-apply has no popup late-engage guard), so `release` here (#269).
    /// Also release while sleeping: willSleep already reset the fans and wake re-applies (#275).
    /// R1225-1: with manual on and awake too: the pin may have come after both timeouts and after the reset
    /// that followed them; the release is a reset without teardown and the recovery re-applies the saved targets.
    /// Held while another engage is in flight, like the popup late path: it owns the fans (#282).
    static func lateEngageLanded(_ engaged: Bool,
                                 inFlight: Int = Self.engagesInFlight,
                                 release: @escaping @MainActor () async -> Void = { await sleepSafeRelease() }) {
        if engaged, inFlight == 0 { Task { await release() } }
    }

    /// R1230-2: late pins of `setManualReply` released in a row, with no engage landing in time between.
    static var lateLandings = 0
    static let lateLandingLimit = 3

    /// R1230-2: `setManualReply`'s late hook. With manual on, a helper whose replies always come after the ceiling
    /// would pin, be handed back and be re-applied by the recovery every cooldown, for good: the third released
    /// late pin in a row also turns manual intent off (as the recovery's abandon), so the release tears down and
    /// nothing re-applies. A held pin (an engage in flight) does not count; an engage that lands in time clears it.
    static func lateReplyLanded(_ engaged: Bool, inFlight: Int = Self.engagesInFlight,
                                release: @escaping @MainActor () async -> Void = { await sleepSafeRelease() }) {
        if engaged, inFlight == 0 {
            lateLandings += 1
            if lateLandings >= lateLandingLimit { lateLandings = 0; Preferences.fanManualEnabled = false }
        }
        lateEngageLanded(engaged, inFlight: inFlight, release: release)
    }

    /// Reset every fan; tear down only with manual off. With manual on (a release while
    /// asleep) the reclaim timer and connection stay: wake's re-apply does not re-arm
    /// the timer when the helper is unreachable, so a teardown here could lose it (#287).
    static func sleepSafeRelease() async {
        await resetAll(teardown: !Preferences.fanManualEnabled)
    }

    /// willSleep resets the fans with saved manual intent, or with an engage in flight:
    /// that is manual intent too, the popup saves the pref only after it lands (#287).
    static func sleepResetNeeded(manualEnabled: Bool = Preferences.fanManualEnabled,
                                 inFlight: Int = Self.engagesInFlight) -> Bool {
        manualEnabled || inFlight > 0
    }

    /// Hand one fan back to OS thermal control (other fans unaffected). Honors the
    /// opt-in fast-re-engage pref: the daemon keeps the controller unlock held (and
    /// supervised) so the next manual engage skips the ~8 s thermalmonitord yield.
    @discardableResult
    static func setAuto(_ index: Int, presentModal: Bool = true) async -> Bool {
        let c: NSXPCConnection
        if let existing = connection { c = existing }
        else if let opened = await ensureConnection(presentModal: presentModal).0 { c = opened }
        else { return false }
        let hold = Preferences.fanHoldUnlock
        if !Preferences.fanManualEnabled { removeReclaimMonitor() }   // hold-unlock "Automatic" keeps the connection
        return await call(c) { proxy, done in proxy.setFanAuto(index, holdUnlock: hold) { done($0) } }
    }

    /// Reset every fan to auto. Used on explicit disable and before sleep. On disable
    /// (`teardown: true`) the connection is torn down so the daemon idle-exits —
    /// unless an engage picked it up meanwhile (#263): invalidating would fail that
    /// engage with a false "helper isn't running". The reset already went out ahead of
    /// it; a failed popup engage tears down through `firstEngageLanded`.
    // ponytail: any other skipped teardown only keeps the daemon resident until the next one.
    @discardableResult
    static func resetAll(teardown: Bool = false) async -> Bool {
        if teardown { removeReclaimMonitor() }
        // No connection → nothing to reset (daemon not running, fans already on auto).
        guard let c = connection else { return true }
        let ok = await call(c) { proxy, done in proxy.resetAllFans { done($0) } }
        if teardown, engagesInFlight == 0 {
            c.invalidate()
            if connection === c { connection = nil }
        }
        askHelperIdentityIfIdle()   // entry 1208: every fan just went to macOS; asks only with manual off
        return ok
    }

    // MARK: - Which helper answers (entry 1208)

    /// What the helper on the Mach service said about itself: `.current` replied to `helperInfo` with a
    /// version of 1 or more and capability bit 0; `.old` gave positive evidence of an older helper (a reply
    /// without them, or the interruption an older helper gives on two throwaways in a row); nil = not known
    /// (not asked yet, one interruption, silence until the ceiling, or any other error). Kept for the app
    /// run; only the refusal text reads it (`FanManualReply.errorText`, through `oldHelperAnswers`).
    enum HelperIdentity: Equatable { case current, old }
    private(set) static var helperIdentity: HelperIdentity? = nil {
        didSet { let old = helperIdentity == .old; oldHelperAnswers.withLock { $0 = old } }
    }
    /// `helperIdentity == .old`, readable off main for the nonisolated refusal text.
    nonisolated static let oldHelperAnswers = OSAllocatedUnfairLock(initialState: false)
    /// The open ask's throwaway connection; nil = no ask open.
    private(set) static var identityConnection: NSXPCConnection?
    /// Bumped by every ask and every `helperMayHaveChanged`: an answer to an older ask changes nothing.
    private static var identityAsk = 0
    /// Interruptions (4097) in a row, each on its own throwaway. A current helper gives one too when its
    /// process ends during the ask (idle exit, crash, restart, update); an older helper gives it every time.
    private(set) static var identityInterruptions = 0
    /// Seam: the throwaway connection. The live one is never made under XCTest; rows pass a fake.
    static var makeIdentityConnection: () -> NSXPCConnection? = { liveIdentityConnection() }
    /// Seam: the 6 s ceiling, which runs its argument once on main. Rows keep the argument and run it themselves.
    static var identityCeiling: (@escaping @Sendable @MainActor () -> Void) -> Void = { fire in
        Task { @MainActor in try? await Task.sleep(nanoseconds: 6_000_000_000); fire() }
    }
    /// Seam: the second ask after a first interruption, about 1 s later; runs its argument once on main. Rows
    /// keep the argument and run it themselves.
    static var identityRetry: (@escaping @Sendable @MainActor () -> Void) -> Void = { fire in
        Task { @MainActor in try? await Task.sleep(nanoseconds: 1_000_000_000); fire() }
    }

    /// A bare connection to the helper's Mach service, made here and never through `makeConnection` or the
    /// lid helper's: no `clear` handler, nothing held, so the helper closing it changes no app state (an
    /// older helper closes the connection an unknown call arrives on). Nil under XCTest: no row reaches the
    /// real Mach service.
    nonisolated static func liveIdentityConnection() -> NSXPCConnection? {
        guard NSClassFromString("XCTestCase") == nil else { return nil }
        let c = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: ProsperHelperProtocol.self)
        return c
    }

    /// Ask which helper answers, on the throwaway, only while no fan can be held: manual off and no engage
    /// in flight (an engage made before the answer uses the Bool method as before). Not again once
    /// answered, nor while an ask is open. True = an ask was made (N1208-h: the retry reads it).
    @discardableResult
    static func askHelperIdentityIfIdle() -> Bool {
        guard helperIdentity == nil, identityConnection == nil, !Preferences.fanManualEnabled, engagesInFlight == 0,
              let c = makeIdentityConnection() else { return false }
        identityAsk &+= 1
        let ask = identityAsk
        identityConnection = c
        let (answered, failed) = identityHandlers(ask)
        c.resume()
        guard let proxy = c.remoteObjectProxyWithErrorHandler(failed) as? ProsperHelperProtocol else {
            identityEnded(ask, .unknown)
            return true
        }
        identityCeiling { identityEnded(ask, .unknown) }
        proxy.helperInfo(withReply: answered)
        return true
    }

    /// The ask's reply and error handlers. XPC runs both on its own queue, so they are formed here,
    /// nonisolated and @Sendable, and each hops to main before touching the ask's state. The reply's values
    /// come from outside: only compared and masked with a constant. The error's domain and code are outside
    /// data too: only compared, on XPC's queue; only the verdict crosses to main.
    nonisolated private static func identityHandlers(_ ask: Int) -> (@Sendable (Int, Int) -> Void, @Sendable (Error) -> Void) {
        ({ version, caps in
            let current = version >= 1 && caps & helperCapabilityFanReason != 0
            Task { @MainActor in identityEnded(ask, current ? .current : .old) }
        }, { error in
            let end = identityEnd(error as NSError)
            Task { @MainActor in identityEnded(ask, end) }
        })
    }

    /// How an ask ended: a reply (current or old), the interruption, or nothing known.
    enum IdentityEnd: Sendable { case current, old, interrupted, unknown }

    /// The error handler's reading. Only the interruption an older helper gives for the unknown `helperInfo`
    /// (the probe: NSCocoaErrorDomain 4097, NSXPCConnectionInterrupted) counts; any other error (a helper not
    /// approved, not registered or not reachable: the connection invalid, 4099) is unknown, asked again.
    nonisolated static func identityEnd(_ e: NSError) -> IdentityEnd {
        e.domain == NSCocoaErrorDomain && e.code == CocoaError.Code.xpcConnectionInterrupted.rawValue ? .interrupted : .unknown
    }

    /// Every exit of an ask (reply, error handler, ceiling) ends here, on main. A reply decides at once and a
    /// current one wins even after the ceiling (it only changes a text). An interruption while the ask is open
    /// counts: the second in a row reads old; the first asks again through `identityRetry` (still only if
    /// idle then; otherwise the count is cleared, N1208-h, and the next idle moment asks). Silence or another error while open clears the count
    /// and records nothing; the next idle moment asks again. The throwaway is invalidated every time: left
    /// open on a new helper it would hold the helper's last-client lid release and its idle exit.
    private static func identityEnded(_ ask: Int, _ end: IdentityEnd) {
        guard ask == identityAsk else { return }
        let open = identityConnection != nil
        identityConnection?.invalidate()
        identityConnection = nil
        switch end {
        case .current: helperIdentity = .current; identityInterruptions = 0
        case .old: helperIdentity = .old; identityInterruptions = 0
        case .interrupted where open:
            identityInterruptions += 1
            if identityInterruptions >= 2 { helperIdentity = .old; identityInterruptions = 0 }
            // N1208-h: a retry that makes no ask (not idle) clears the count: "in a row" stays about 1 s apart.
            else { identityRetry { if !askHelperIdentityIfIdle() { identityInterruptions = 0 } } }
        case .interrupted: break
        case .unknown: if open { identityInterruptions = 0 }
        }
    }

    /// Ask again at the next idle moment: after the fan connection dropped from the helper's side, and the
    /// hook for a re-registration of the helper (an update's old helper process may have answered before).
    /// An open ask is closed and its answer dropped.
    static func helperMayHaveChanged() {
        identityAsk &+= 1
        identityConnection?.invalidate()
        identityConnection = nil
        helperIdentity = nil
        identityInterruptions = 0
    }

    /// A NEW fan connection was made: an old verdict may be stale (the helper approved or updated since), so
    /// it goes back to unknown and is asked again at the next idle moment, never in front of this engage. A
    /// current verdict stays (only a re-registration, which calls `helperMayHaveChanged`, can change it).
    static func fanConnectionMade() {
        if helperIdentity == .old { helperMayHaveChanged() }
    }

    /// Ceiling for a COLD first engage: the AS unlock is 0.5 s settle + 150 spaced
    /// mode-key retries (~15 s) + up to 100 spaced target retries (~5 s) ≈ 20.5 s
    /// worst case. The steady-commit default (12 s) times out mid-dance and reports
    /// a slow-but-succeeding engage as failure. Shared by every cold path (popup
    /// first engage, launch/wake reapply).
    static let firstEngageTimeout: TimeInterval = 35

    /// Re-apply the user's saved manual targets through the one shared lifecycle gate.
    /// Called at launch; wake and reclaim use the same path. With no saved manual
    /// intent it installs nothing: no observers, no 2 s timer (the timer used to run
    /// for the app's whole lifetime even for users who never touched fan control).
    /// `start` is the test seam for the arm + re-apply (real observers, timer and XPC).
    static func reapplyFromPreferences(start: () -> Void = { armRecoveryLifecycle(); startReapply() }) {
        guard Preferences.fanManualEnabled else { return }
        presetPending = true   // not landed this launch: a refused launch re-apply keeps a low preset (#737)
        start()
    }

    /// Kept ahead of helper registration: registration can fail transiently, but saved
    /// manual intent still needs the persistent lifecycle retry to recover on its own.
    static func armRecoveryLifecycle() {
        installSleepObservers()
        installReclaimMonitor()
    }

    static var recoveryLifecycleArmed: Bool {
        observersInstalled && reclaimTimer != nil
    }

    /// Applies targets after the lifecycle gate admitted this attempt. `engage` and `reset` are the test seams.
    static func applySavedTargets(reclaimGeneration: Int,
                                  engage: (Int, Double, TimeInterval) async -> Bool = { await setManual($0, rpm: $1, timeout: $2) },
                                  reset: (Bool) async -> Bool = { await resetAll(teardown: $0) }) async -> Bool {
        guard Preferences.fanManualEnabled else { return false }
        let targets = Preferences.fanTargets
        guard !targets.isEmpty else { return false }
        // Launch/wake IS a cold engage: sleep hardware-clears Ftst, so the daemon
        // re-runs the full unlock. First fan gets the cold ceiling; once it lands the
        // unlock is live and the siblings commit at the steady default.
        var first = true
        for (index, rpm) in engageOrder(targets) {
            guard !sleeping && reclaimGeneration == Self.reclaimGeneration && Preferences.fanManualEnabled else { return false }
            let ok = await engage(index, rpm, first ? firstEngageTimeout : 12)
            // Automatic (#277) or willSleep (#278) landed while this engage was suspended: its
            // reset can reach the daemon ahead of the pin, so release here — the caller sees false.
            // Even when this engage failed: an older engage that landed late while this one was
            // in flight was held for it (#282) and is still pinned. Nothing pinned → no-op.
            // Asleep with manual on, keep the timer and connection, like `sleepSafeRelease` (#287).
            if !Preferences.fanManualEnabled || sleeping { _ = await reset(!Preferences.fanManualEnabled); return false }
            // #926: one failed fan fails the attempt; the caller's reset hands back what landed.
            guard ok else { return false }
            first = false
        }
        presetPending = false
        return true
    }

    // MARK: - Reclaim recovery

    /// The popover is transient, so reclaim detection belongs beside the long-lived
    /// fan connection. Installed by a manual engage or a launch with saved manual
    /// intent, removed when the user goes back to Automatic; SMC reads stay off-main.
    private static func installReclaimMonitor() {
        guard reclaimTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in reclaimTick() }
        }
        timer.tolerance = 1
        reclaimTimer = timer
    }

    /// One 2 s reclaim tick: read the fans off-main (`read` is the test seam) and
    /// recover, unless `reclaimTickAllowed` says not now.
    static func reclaimTick(now: Date = Date(), read: @escaping @Sendable () -> [FanReading] = { FanInfo.read() }) {
        guard reclaimTickAllowed(now: now) else { return }
        reclaimReadInFlight = true
        Task.detached(priority: .utility) {
            let readings = read()
            await MainActor.run {
                reclaimReadInFlight = false
                recoverReclaimedFans(readings)
            }
        }
    }

    /// One 2 s reclaim tick may read the fans: recovery eligible, no read in flight,
    /// and past the cooldown a failed re-apply set (`deferReclaimRetry`).
    static func reclaimTickAllowed(now: Date = Date()) -> Bool {
        FanReclaimRecovery.canStartRecovery(manualIntent: Preferences.fanManualEnabled,
                                            sleeping: sleeping,
                                            recoveryInFlight: reclaimRecoveryInFlight,
                                            userAdjusting: userAdjusting)
            && !reclaimReadInFlight && now >= reclaimRetryNotBefore
    }

    /// A reclaim re-apply failed (typically the helper's trip latch): hold the next
    /// attempt for `retryCooldown`, one helper supervision tick.
    static func deferReclaimRetry(now: Date = Date()) {
        reclaimRetryNotBefore = now.addingTimeInterval(FanReclaimRecovery.retryCooldown)
    }

    private static func removeReclaimMonitor() {
        reclaimTimer?.invalidate()
        reclaimTimer = nil
    }

    private static func recoverReclaimedFans(_ readings: [FanReading]) {
        guard FanReclaimRecovery.canStartRecovery(manualIntent: Preferences.fanManualEnabled,
                                                   sleeping: sleeping,
                                                   recoveryInFlight: reclaimRecoveryInFlight,
                                                   userAdjusting: userAdjusting) else { return }
        let targets = Preferences.fanTargets
        guard FanReclaimRecovery.shouldRecover(readings, targetsEmpty: targets.isEmpty, inFlight: engagesInFlight) else { return }
        let fraction = FanReclaimRecovery.manualFraction(targets: targets, readings: readings)
        guard let fraction else {
            Preferences.fanManualEnabled = false
            Task { await resetAll(teardown: true) }
            return
        }
        if case .abandonManualIntent = FanReclaimRecovery.disposition(manualFraction: fraction, reengaged: true,
                                                                      pending: presetPending) {
            Preferences.fanManualEnabled = false
            Task { await resetAll(teardown: true) }
            return
        }
        startReapply(manualFraction: fraction)
    }

    private static func startReapply(manualFraction: Double? = nil) {
        guard FanReclaimRecovery.canStartRecovery(manualIntent: Preferences.fanManualEnabled,
                                                   sleeping: sleeping,
                                                   recoveryInFlight: reclaimRecoveryInFlight,
                                                   userAdjusting: userAdjusting) else { return }
        reclaimRecoveryInFlight = true
        let generation = reclaimGeneration, pending = presetPending   // before the apply clears it
        Task {
            let reengaged = await applySavedTargets(reclaimGeneration: generation)
            guard generation == reclaimGeneration, !sleeping else {
                if sleeping { await resetAll() }
                reclaimRecoveryInFlight = false
                startPendingWakeRecovery()
                return
            }
            if let manualFraction {
                await settleReclaim(FanReclaimRecovery.disposition(manualFraction: manualFraction, reengaged: reengaged,
                                                                   pending: pending))
            } else if !reengaged {
                await resetAll()
            }
            reclaimRecoveryInFlight = false
            startPendingWakeRecovery()
        }
    }

    /// Act on a reclaim re-apply's outcome. `.retry` holds the next attempt for the
    /// cooldown, so a latched helper is asked once per settle window, not every 2 s
    /// tick. A refusal keeps the manual pref and the saved targets: only `.abandon…`
    /// (a pin under the 20 % floor) drops intent.
    static func settleReclaim(_ disposition: FanReclaimRecovery.Disposition, now: Date = Date(),
                              reset: (Bool) async -> Bool = { await resetAll(teardown: $0) }) async {
        switch disposition {
        case .abandonManualIntent:
            Preferences.fanManualEnabled = false
            _ = await reset(true)
        case .retry:
            deferReclaimRetry(now: now)
            _ = await reset(false)
        case .restored:
            break
        }
    }

    private static func startPendingWakeRecovery() {
        guard wakeRecoveryPending, !sleeping else { return }
        wakeRecoveryPending = false
        startReapply()
    }

    // MARK: - Sleep / wake (thermal safety across the sleep transition)

    /// On sleep, drop fans to auto so a low manual pin can't ride into a high-load
    /// wake; on wake, re-assert the saved targets. Installed once, only after the
    /// feature is first used (so a never-fan user never registers observers).
    private static func installSleepObservers() {
        guard !observersInstalled else { return }
        let nc = NSWorkspace.shared.notificationCenter
        sleepObserverTokens.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { willSleep() }
        })
        sleepObserverTokens.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                sleeping = false
                wakeRecoveryPending = true
                startPendingWakeRecovery()
            }
        })
    }

    /// The willSleep observer's body; internal as the test seam.
    /// Reset SYNCHRONOUSLY (bounded) — a fire-and-forget Task may not complete
    /// before the machine sleeps, so a low manual pin could ride into a
    /// high-load wake. A sleep observer may block briefly; the XPC reply fires
    /// on the connection's own queue, so blocking main here can't deadlock it.
    /// Keep the connection (daemon stays resident) so wake can re-assert.
    // ponytail: 2s ceiling; the daemon also resets on its own cold start, so a
    // missed deadline self-heals on next launch.
    static func willSleep() {
        sleeping = true
        reclaimGeneration &+= 1
        guard sleepResetNeeded(), let c = connection else { return }
        let sem = DispatchSemaphore(value: 0)
        // @Sendable on both: XPC runs them on its own queue, and an inferred
        // MainActor closure traps there on its executor check (#479).
        let proxy = c.remoteObjectProxyWithErrorHandler { @Sendable _ in sem.signal() } as? ProsperHelperProtocol
        guard let proxy else { return }
        proxy.resetAllFans { @Sendable _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
    }

    /// Test-only teardown: a test that armed the lifecycle must not leave live
    /// sleep/wake observers driving real fan writes for the rest of the xctest process.
    /// The app never calls this (observers live for the app's lifetime once installed).
    static func removeSleepObservers() {
        sleepObserverTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        sleepObserverTokens = []
    }

    // MARK: - XPC call with hard timeout

    /// Run one fan selector with a hard ceiling: an idle-exited / mid-relaunch daemon
    /// can invoke neither reply nor error handler, and a bare `await` would hang. The
    /// ceiling MUST exceed the daemon's own worst case for a FIRST-time manual engage —
    /// the AS unlock writes Ftst, waits 3s for thermalmonitord to yield, then retries
    /// the mode key SPACED over many attempts (up to ~30s on a contended chassis). A
    /// 12s default fits steady commits (instant) but is shorter than that dance, so the
    /// caller passes a generous `timeout` for the first engage — otherwise a slow-but-
    /// successful engage gets reported as failure while the daemon is still grinding
    /// (and silently leaves the fan pinned, desyncing the UI).
    private static func call(_ c: NSXPCConnection,
                             timeout: TimeInterval = 12,
                             _ body: @escaping (ProsperHelperProtocol, @escaping @Sendable (Bool) -> Void) -> Void) async -> Bool {
        await callReply(c, timeout: timeout, body) ?? false
    }

    /// The helper's own reply, or nil when it never answered (XPC error / no proxy / timeout).
    static func callReply(_ c: NSXPCConnection,
                                  timeout: TimeInterval = 12,
                                  late: (@Sendable (Bool) -> Void)? = nil,
                                  _ body: @escaping (ProsperHelperProtocol, @escaping @Sendable (Bool) -> Void) -> Void) async -> Bool? {
        await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            let proxy = c.remoteObjectProxyWithErrorHandler { @Sendable err in
                Self.log.error("fan call failed: \(err.localizedDescription, privacy: .public)")
                once.resume(nil)
            } as? ProsperHelperProtocol
            guard let proxy else { once.resume(nil); return }
            once.armTimeout(timeout)
            body(proxy) { @Sendable ok in if !once.resume(ok) { late?(ok) } }
        }
    }

    final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var cont: CheckedContinuation<Bool?, Never>?
        init(_ c: CheckedContinuation<Bool?, Never>) { cont = c }
        /// False when an earlier resume (timeout / error) already won: `v` arrived late.
        @discardableResult
        func resume(_ v: Bool?) -> Bool {
            lock.lock(); let c = done ? nil : cont; done = true; cont = nil; lock.unlock()
            c?.resume(returning: v)
            return c != nil
        }
        func armTimeout(_ seconds: TimeInterval) {
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.resume(nil) }
        }
    }
}
