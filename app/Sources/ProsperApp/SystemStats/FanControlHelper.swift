import Foundation
import AppKit
import ProsperHelperProtocol
import SMCKit
import os

/// One fan's identity + range, read UNPRIVILEGED (SMC reads need no root — only
/// writes do). Drives the settings sliders. `current` is the live RPM at read time.
struct FanReading: Identifiable, Equatable {
    let id: Int          // SMC fan index
    let min: Double
    let max: Double
    let current: Double
    /// Whether the fan is manually engaged on the HARDWARE right now (mode key +
    /// Ftst, unprivileged reads). Lets the UI detect an OS reclaim: user thinks
    /// manual, hardware says auto → flip the toggle honestly.
    let manual: Bool
}

enum FanReclaimRecovery {
    static let minimumManualFraction = 0.2

    /// Pause after a reclaim re-apply failed before the timer tries again. The helper
    /// refuses manual engages while its kill-switch is latched (chassis still above the
    /// re-arm temperature), and every failed attempt costs a resetAllFans; one attempt
    /// per helper supervision tick (30 s) is enough to notice the re-arm.
    static let retryCooldown: TimeInterval = 30

    enum Disposition: Equatable {
        case abandonManualIntent
        case restored
        case retry
    }

    static func disposition(manualFraction: Double, reengaged: Bool) -> Disposition {
        guard manualFraction.isFinite, manualFraction >= minimumManualFraction else {
            return .abandonManualIntent
        }
        return reengaged ? .restored : .retry
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
    case refused       // live helper replied false
    case unavailable   // no reply from the helper

    /// Collapse one burst of per-fan replies: any refusal wins (the latch is global),
    /// then any unreachable fan; all engaged → engaged.
    static func combine(_ replies: [FanManualReply]) -> FanManualReply {
        if replies.contains(.refused) { return .refused }
        return replies.allSatisfy { $0 == .engaged } ? .engaged : .unavailable
    }

    /// The single status line the fan popup shows for a failed engage/commit.
    // ponytail: a refusal is read as the latch; the helper also replies false when the
    // SMC write itself throws (rare). Grow the protocol a reason enum if that needs its own text.
    var errorText: String? {
        switch self {
        case .engaged: return nil
        case .refused:
            return "Fans are held automatic until the Mac cools down — the overheat "
                + "cut-off tripped. Try again in a few minutes."
        case .unavailable:
            return "Couldn’t enable manual control — the Prosper helper isn’t "
                + "running or wasn’t approved. Turn on “Prosper” under System Settings ▸ "
                + "General ▸ Login Items ▸ Allow in the Background, then try again."
        }
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
    static func read() -> [FanReading] {
        guard let smc = try? SMC() else { return [] }
        let fc = SMCFanController(smc)
        let n = fc.fanCount()
        guard n > 0 else { return [] }
        return (0..<n).compactMap { i in
            guard let b = fc.bounds(i) else { return nil }   // degenerate bounds → skip (write would fail closed anyway)
            return FanReading(id: i, min: b.min, max: b.max, current: fc.currentRPM(i) ?? 0,
                              manual: fc.isManualEngaged(i))
        }
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
    static var connection: NSXPCConnection?   // internal: the teardown-guard test injects one
    /// Engages holding `connection` right now; a teardown waits for them (#263).
    static var engagesInFlight = 0
    private static var observersInstalled = false
    private static var reclaimTimer: Timer?
    private static var reclaimReadInFlight = false
    private static var reclaimRecoveryInFlight = false
    private static var sleeping = false
    private static var wakeRecoveryPending = false
    private(set) static var reclaimGeneration = 0
    private static var reclaimRetryNotBefore = Date.distantPast

    /// Set by the popup while a slider drag / quick-button commit is in flight, so
    /// reclaim recovery can't reapply the stale saved target on top of the gesture.
    static var userAdjusting = false

    // MARK: - Connection

    private static func makeConnection() -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: ProsperHelperProtocol.self)
        let clear: () -> Void = { Task { @MainActor in if connection === c { connection = nil } } }
        c.invalidationHandler = clear
        c.interruptionHandler = clear
        c.resume()
        return c
    }

    /// Open (or reuse) the daemon connection, lazily registering the shared helper.
    /// Returns nil when registration isn't available (e.g. unsigned dev build) — the
    /// caller then leaves fans on auto.
    private static func ensureConnection() async -> NSXPCConnection? {
        guard await LidSleepHelper.ensureRegistered(feature: "Manual fan control") else { return nil }
        let c = connection ?? makeConnection()
        connection = c
        return c
    }

    // MARK: - Public ops (called from the settings pane + wake/sleep)

    /// Force one fan to a manual RPM. Holds the connection open so the daemon keeps
    /// the manual pin alive; a drop (crash/disable) resets it. Returns success.
    @discardableResult
    static func setManual(_ index: Int, rpm: Double, timeout: TimeInterval = 12) async -> Bool {
        await setManualReply(index, rpm: rpm, timeout: timeout) == .engaged
    }

    /// `setManual` keeping the helper's refusal apart from an unreachable helper.
    static func setManualReply(_ index: Int, rpm: Double, timeout: TimeInterval = 12) async -> FanManualReply {
        guard let c = await ensureConnection() else { return .unavailable }
        // A manual write is manual intent, even before the popup saves the pref (it
        // saves it only after the first engage lands), so this arms unconditionally.
        armRecoveryLifecycle()
        engagesInFlight += 1
        defer { engagesInFlight -= 1 }
        switch await callReply(c, timeout: timeout, { proxy, done in proxy.setFanManualRPM(index, rpm: rpm) { done($0) } }) {
        case true?: return .engaged
        case false?: return .refused
        case nil: return .unavailable
        }
    }

    /// The popup's first engage replied; true = engaged. On failure with no saved
    /// manual intent nothing will ever recover, so drop the 2 s reclaim timer that
    /// engage armed, and `release` everything: an older engage that landed late while
    /// this one was in flight was held for it (#263). Fire-and-forget so the button
    /// resolves now; a retry racing it is covered by the teardown guard in `resetAll`.
    static func firstEngageLanded(_ reply: FanManualReply,
                                  release: @escaping @MainActor () async -> Void = { await resetAll(teardown: true) }) -> Bool {
        guard reply != .engaged else { return true }
        if !Preferences.fanManualEnabled { removeReclaimMonitor(); Task { await release() } }
        return false
    }

    /// Hand one fan back to OS thermal control (other fans unaffected). Honors the
    /// opt-in fast-re-engage pref: the daemon keeps the controller unlock held (and
    /// supervised) so the next manual engage skips the ~8 s thermalmonitord yield.
    @discardableResult
    static func setAuto(_ index: Int) async -> Bool {
        let c: NSXPCConnection
        if let existing = connection { c = existing }
        else if let opened = await ensureConnection() { c = opened }
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
        return ok
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
    static func reapplyFromPreferences() {
        guard Preferences.fanManualEnabled else { return }
        armRecoveryLifecycle()
        startReapply()
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

    /// Applies targets after the lifecycle gate admitted this attempt. `engage` is the test seam.
    static func applySavedTargets(reclaimGeneration: Int,
                                  engage: (Int, Double, TimeInterval) async -> Bool = { await setManual($0, rpm: $1, timeout: $2) }) async -> Bool {
        guard Preferences.fanManualEnabled else { return false }
        let targets = Preferences.fanTargets
        guard !targets.isEmpty else { return false }
        // Launch/wake IS a cold engage: sleep hardware-clears Ftst, so the daemon
        // re-runs the full unlock. First fan gets the cold ceiling; once it lands the
        // unlock is live and the siblings commit at the steady default.
        var first = true
        var reengaged = true
        for (index, rpm) in targets {
            guard !sleeping && reclaimGeneration == Self.reclaimGeneration && Preferences.fanManualEnabled else { return false }
            let ok = await engage(index, rpm, first ? firstEngageTimeout : 12)
            reengaged = reengaged && ok
            first = false
        }
        return reengaged
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
                                                   userAdjusting: userAdjusting),
              FanReclaimRecovery.reclaimDetected(readings) else { return }
        let fraction = FanReclaimRecovery.manualFraction(targets: Preferences.fanTargets, readings: readings)
        guard let fraction else {
            Preferences.fanManualEnabled = false
            Task { await resetAll(teardown: true) }
            return
        }
        if case .abandonManualIntent = FanReclaimRecovery.disposition(manualFraction: fraction, reengaged: true) {
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
        let generation = reclaimGeneration
        Task {
            let reengaged = await applySavedTargets(reclaimGeneration: generation)
            guard generation == reclaimGeneration, !sleeping else {
                if sleeping { await resetAll() }
                reclaimRecoveryInFlight = false
                startPendingWakeRecovery()
                return
            }
            if let manualFraction {
                await settleReclaim(FanReclaimRecovery.disposition(manualFraction: manualFraction, reengaged: reengaged))
            } else if !reengaged {
                await resetAll()
            }
            reclaimRecoveryInFlight = false
            startPendingWakeRecovery()
        }
    }

    /// Act on a reclaim re-apply's outcome. `.retry` holds the next attempt for the
    /// cooldown, so a latched helper is asked once per 30 s, not every 2 s tick.
    static func settleReclaim(_ disposition: FanReclaimRecovery.Disposition, now: Date = Date()) async {
        switch disposition {
        case .abandonManualIntent:
            Preferences.fanManualEnabled = false
            await resetAll(teardown: true)
        case .retry:
            deferReclaimRetry(now: now)
            await resetAll()
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
        observersInstalled = true
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            // Reset SYNCHRONOUSLY (bounded) — a fire-and-forget Task may not complete
            // before the machine sleeps, so a low manual pin could ride into a
            // high-load wake. A sleep observer may block briefly; the XPC reply fires
            // on the connection's own queue, so blocking main here can't deadlock it.
            // Keep the connection (daemon stays resident) so wake can re-assert.
            // ponytail: 2s ceiling; the daemon also resets on its own cold start, so a
            // missed deadline self-heals on next launch.
            MainActor.assumeIsolated {
                sleeping = true
                reclaimGeneration &+= 1
                guard Preferences.fanManualEnabled, let c = connection else { return }
                let sem = DispatchSemaphore(value: 0)
                let proxy = c.remoteObjectProxyWithErrorHandler { _ in sem.signal() } as? ProsperHelperProtocol
                guard let proxy else { return }
                proxy.resetAllFans { _ in sem.signal() }
                _ = sem.wait(timeout: .now() + 2)
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                sleeping = false
                wakeRecoveryPending = true
                startPendingWakeRecovery()
            }
        }
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
    private static func callReply(_ c: NSXPCConnection,
                                  timeout: TimeInterval = 12,
                                  _ body: @escaping (ProsperHelperProtocol, @escaping @Sendable (Bool) -> Void) -> Void) async -> Bool? {
        await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            let proxy = c.remoteObjectProxyWithErrorHandler { @Sendable err in
                Self.log.error("fan call failed: \(err.localizedDescription, privacy: .public)")
                once.resume(nil)
            } as? ProsperHelperProtocol
            guard let proxy else { once.resume(nil); return }
            once.armTimeout(timeout)
            body(proxy) { @Sendable ok in once.resume(ok) }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var cont: CheckedContinuation<Bool?, Never>?
        init(_ c: CheckedContinuation<Bool?, Never>) { cont = c }
        func resume(_ v: Bool?) {
            lock.lock(); let c = done ? nil : cont; done = true; cont = nil; lock.unlock()
            c?.resume(returning: v)
        }
        func armTimeout(_ seconds: TimeInterval) {
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.resume(nil) }
        }
    }
}
