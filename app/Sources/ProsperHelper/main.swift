import Foundation
import ProsperHelperProtocol
import SMCKit

// ProsperHelper — the privileged daemon behind "keep awake with the lid
// closed". Installed via SMAppService.daemon, launched by launchd as root on the
// first XPC message. Its ONLY job is `pmset -a disablesleep 0/1`, which needs
// root — that root requirement is the whole reason the daemon exists (it removes
// the old sudoers hack). It holds no model, no UI, no timers beyond a short
// idle-exit; resident memory is a few hundred KB and it exits entirely when no
// client is connected.

// Code-signing requirement the connecting client MUST satisfy before this root
// daemon will touch a system power setting. Pins to Prosper's bundle id + Team
// (Developer ID anchor) so no other local process can ask root to disable sleep.
// A self-signed / ad-hoc dev build does NOT satisfy `anchor apple generic`, so
// the feature is simply inert there — acceptable: it is a release-only path.
private let clientRequirement =
    "identifier \"eu.illegible.prosper\" and anchor apple generic and "
    + "certificate leaf[subject.OU] = \"V5XV3994L8\""

// Idle window: launchd relaunches us on the next message, so exiting frees ALL
// memory at zero cost. 10s is long enough to coalesce a quick toggle-off/on.
private let idleExitSeconds = 10

// How long a remote-session keep-awake hold survives without a refresh. The app
// heartbeats every ~10s (the keep-awake tick) while a session is live — a 12×
// margin that absorbs an App-Nap-throttled timer; if the app crashes or the
// network drops, the hold lapses within this window and the Mac sleeps — the
// crash-safety for a hold that (unlike the lid override) has no client to drop.
// Also the bootstrap window after a remote-wake promote: long enough for DchTerm
// to dial back in over Tailscale and start its own heartbeat.
private let remoteHoldTTLSeconds = 120

// @unchecked Sendable: every mutable member (`core`, `idleTimer`) is touched
// only inside a `q.sync`/`q.async` block, so the serial queue is the lock.
final class Helper: NSObject, ProsperHelperProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    // Single serial queue guards all mutable state — XPC delivers connection
    // events + method calls on arbitrary queues, and the idle timer runs here too,
    // so every `core` call is serialized without the core needing its own lock.
    private let q = DispatchQueue(label: "\(helperLabel).state")
    private var idleTimer: DispatchSourceTimer?
    // Auto-expiry for the remote-session keep-awake hold (see remoteHoldTTLSeconds).
    private var remoteHoldTimer: DispatchSourceTimer?
    private let core = LidHelperCore(apply: Helper.applyPmset, onIdle: { exit(0) })
    // Remote-wake lives in its own observer with its own state machine — zero
    // shared mutable state with `core` (the only coupling is the idle-exit guard
    // below, which keeps the daemon resident while remote-wake is armed). Uses the
    // same serial queue `q` so a setRemoteWake never races a lid op.
    private lazy var remoteWake = RemoteWakeObserver(queue: q)

    // Privileged fan control runs on its OWN serial queue, NOT `q`. The Apple-Silicon
    // manual unlock sleeps ~3s (thermalmonitord must yield) + retries the mode key
    // hundreds of times; on `q` that would stall the safety-critical lid-sleep FIFO
    // (and remote-wake / sleepNow) for seconds. `fanQ` isolates that latency. `fan`,
    // `fanCore`, and `fanHolderID` are touched ONLY on `fanQ`, so SMCFanController's
    // mode-key cache + the core need no extra lock.
    private let fanQ = DispatchQueue(label: "\(helperLabel).fan")
    private lazy var fan: SMCFanController? = {
        guard let smc = try? SMC() else { fanLog.error("fan: SMC open failed — fan control inert"); return nil }
        let c = SMCFanController(smc)
        c.onTrace = { fanLog.notice("fan-unlock: \($0, privacy: .public)") }
        return c
    }()
    private lazy var fanCore = FanControlCore(reset: { [weak self] in _ = self?.fan?.resetAll() })
    // Identity of the XPC connection currently holding a manual fan pin. Fan
    // crash-safety is tracked PER FAN-CLIENT, independent of the lid connection count
    // (the app opens SEPARATE connections for lid vs fans): the fan must reset when
    // ITS client drops, even while a lid-sleep connection is still held.
    private var fanHolderID: ObjectIdentifier?
    // Intended manual targets (fan index → RPM), fanQ-owned. The supervision tick
    // compares these against the hardware's actual mode: if thermalmonitord/firmware
    // reclaims a fan (thermal event; sleep clears Ftst), the daemon re-asserts the
    // target ONCE per incident, then gives up honestly (full reset) so the app's UI
    // flips to Automatic instead of silently lying. Budget refills on a healthy tick.
    private var fanHeldTargets: [Int: Double] = [:]
    private var fanReassertBudget = 0

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        // The OS invalidates the connection automatically if the peer fails this
        // requirement, so an impostor never reaches setLidSleepDisabled.
        conn.setCodeSigningRequirement(clientRequirement)
        conn.exportedInterface = NSXPCInterface(with: ProsperHelperProtocol.self)
        conn.exportedObject = self
        // Capture the connection IDENTITY (a value type — no retain cycle on conn's
        // own handler) so a drop can be matched against the fan holder.
        let cid = ObjectIdentifier(conn)
        conn.invalidationHandler = { [weak self] in self?.connectionClosed(cid) }
        conn.interruptionHandler  = { [weak self] in self?.connectionClosed(cid) }
        q.sync {
            core.connectionOpened(cid)
            cancelIdleExit_locked()
        }
        conn.resume()
        return true
    }

    private func connectionClosed(_ cid: ObjectIdentifier) {
        // App quit or crashed — core resets the lid override here so the lid is NEVER
        // left wedged awake; arm the idle exit once no client remains. The core
        // dedupes by identity (interruption + invalidation both fire for one drop).
        q.async {
            if self.core.connectionClosed(cid) { self.armIdleExit_locked() }
        }
        // Fan crash-safety is tracked independently on `fanQ`: if the FAN client that
        // set a manual pin is the one that just dropped, reset every fan to auto —
        // even if a lid-sleep connection is still open (so the fan pin never outlives
        // its own client). Matched by identity, so an unrelated lid drop is a no-op.
        fanQ.async {
            if self.fanHolderID == cid {
                self.fanCore.lastClientGone()
                self.fanHolderID = nil
                self.fanHeldTargets = [:]
            }
        }
    }

    func setLidSleepDisabled(_ on: Bool, withReply reply: @escaping (Bool) -> Void) {
        q.async { reply(self.core.setOverride(on)) }
    }

    func setRemoteWake(_ json: String, withReply reply: @escaping (Bool) -> Void) {
        // RemoteWakeObserver persists the config + arms/disarms its own loop. If it
        // just went disabled, arm the idle exit so the now-purposeless daemon shuts
        // down (unless a lid client still holds a connection).
        q.async {
            let resident = self.remoteWake.apply(json: json)
            if !resident {
                // Remote wake just disarmed. A sticky promote hold belongs to that
                // feature — demote it to a plain transient hold and (re)arm the TTL
                // so a live session's heartbeat keeps the Mac awake but an abandoned
                // hold lapses, instead of holding disablesleep forever while a lid
                // client keeps the daemon resident (where the orphan idle-exit
                // safety net never runs).
                if self.core.remoteHoldSticky {
                    self.core.demoteStickyHold()
                    self.armRemoteHoldExpiry_locked()
                    dtrace("setRemoteWake off: sticky hold demoted to TTL-governed")
                }
                if self.core.connections == 0 { self.armIdleExit_locked() }
            }
            reply(resident)
        }
    }

    func setRemoteSessionActive(_ on: Bool, withReply reply: @escaping (Bool) -> Void) {
        // Hold/release the remote-session source of `disablesleep` and (re)arm its
        // expiry. `true` refreshes the TTL — the app sends it as a heartbeat while a
        // session is live; `false` releases immediately. The expiry guarantees the
        // hold never outlives the app: no refresh → lapse → Mac sleeps.
        q.async {
            if on {
                let ok = self.core.setRemoteHold(true)
                dtrace("setRemoteSessionActive(true): heartbeat, pmset ok=\(ok), TTL re-armed")
                self.armRemoteHoldExpiry_locked()
                reply(ok)
            } else {
                self.cancelRemoteHoldExpiry_locked()
                let ok = self.core.setRemoteHold(false)
                dtrace("setRemoteSessionActive(false): released, pmset ok=\(ok)")
                reply(ok)
            }
        }
    }

    func clearRemoteSession(withReply reply: @escaping (Bool) -> Void) {
        // Lid opened → user is physically present; the clamshell keep-awake is
        // meaningless. Hard-release the hold (incl. a sticky promote hold, which
        // setRemoteSessionActive(false) deliberately ignores) and cancel the TTL.
        // Does NOT sleep — just lets normal power management resume.
        q.async {
            self.cancelRemoteHoldExpiry_locked()
            let ok = self.core.clearRemoteHold()
            dtrace("clearRemoteSession: lid open → remoteHold released, pmset ok=\(ok)")
            reply(ok)
        }
    }

    func setFanManualRPM(_ index: Int, rpm: Double, withReply reply: @escaping (Bool) -> Void) {
        // Force one fan to a manual RPM. SMCFanController re-clamps fail-closed to the
        // absolute floor/ceiling at its lowest write layer AND hands the fan back to
        // the OS if any step throws, so a bad index/rpm can't leave a fan wedged. On
        // real success, record THIS connection as the fan holder + arm the crash reset.
        // Refuse if there's no current connection: arming with a nil holder would make
        // connectionClosed's `fanHolderID == cid` never match this client → its drop
        // wouldn't trigger the crash reset (the fan would outlive its only client until
        // the next drop / cold start). A handler always has a current connection, so this
        // only rejects a genuinely connectionless call.
        guard let conn = NSXPCConnection.current() else { reply(false); return }
        let cid = ObjectIdentifier(conn)
        fanQ.async {
            guard let fan = self.fan else { fanLog.error("setFanManualRPM: no SMC fan controller — inert"); reply(false); return }
            // Arm crash-safety BEFORE the risky write, not after. If setManual
            // half-succeeds (mode flipped, target write throws) AND its own fail-closed
            // setAuto cleanup ALSO fails, the fan is left manual — with post-hoc arming
            // the daemon would then skip didSetManual and a client drop would find
            // nothing to reset. Over-arming on a clean failure is harmless (resetAll is
            // idempotent and cheap); under-arming is the strand hazard.
            self.fanCore.didSetManual()
            self.fanHolderID = cid
            // Record the intended target BEFORE the write too (same arm-early logic):
            // the supervision tick re-asserts from this map after an OS reclaim.
            self.fanHeldTargets[index] = rpm
            self.fanReassertBudget = 1
            self.armFanKillSwitch_fanQ()
            do {
                try fan.setManual(index, rpm: rpm)
                fanLog.notice("setFanManualRPM(\(index, privacy: .public), \(rpm, privacy: .public)) ok")
                reply(true)
            } catch {
                fanLog.error("setFanManualRPM(\(index, privacy: .public), \(rpm, privacy: .public)) FAILED: \(String(describing: error), privacy: .public)")
                reply(false)
            }
        }
    }

    // MARK: Fan temperature kill-switch

    /// Supervision timer, live only while a manual pin is held. Every 30 s it reads
    /// the hottest SMC temperature and, past FanControlCore.killSwitchCelsius, forces
    /// every fan back to auto — the active backstop for a fan pinned low under
    /// sustained load (the 200 RPM floor + SoC self-throttle are passive ones).
    /// Runs on `fanQ` like every other fan mutation; disarms itself the moment
    /// nothing manual is held, so an idle daemon has zero timer wakeups.
    private var fanKillTimer: DispatchSourceTimer?
    private func armFanKillSwitch_fanQ() {
        guard fanKillTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: fanQ)
        t.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.fanKillTick_fanQ() }
        fanKillTimer = t
        t.resume()
    }
    private func fanKillTick_fanQ() {
        guard fanCore.needsSupervision else {
            fanKillTimer?.cancel(); fanKillTimer = nil
            return
        }
        let mx = fan?.maxTemperature()
        if fanCore.temperatureTick(maxCelsius: mx) {
            fanHolderID = nil
            fanHeldTargets = [:]
            fanLog.fault("fan kill-switch FIRED: \(mx ?? .nan, privacy: .public)°C ≥ \(FanControlCore.killSwitchCelsius, privacy: .public)°C — all fans reset to auto")
            fanKillTimer?.cancel(); fanKillTimer = nil
            return
        }
        // Reclaim watch: while a manual pin is held, verify each pinned fan is still
        // actually manual on the hardware. thermalmonitord/firmware can take fans back
        // (thermal event; sleep clears Ftst) without telling anyone. Re-assert the
        // recorded target once per incident; if it keeps getting reclaimed, the OS
        // wants the fans — give up honestly with a full reset so the app's poll sees
        // auto everywhere and flips the UI, instead of fighting the thermal manager.
        guard fanCore.manualHeld, let fan = self.fan, !fanHeldTargets.isEmpty else { return }
        let reclaimed = fanHeldTargets.keys.filter { !fan.isManualEngaged($0) }
        if reclaimed.isEmpty {
            fanReassertBudget = 1
            return
        }
        if fanReassertBudget > 0 {
            fanReassertBudget -= 1
            fanLog.notice("fan reclaim detected on \(reclaimed.sorted(), privacy: .public) — re-asserting targets")
            for i in reclaimed.sorted() {
                guard let rpm = fanHeldTargets[i] else { continue }
                do { try fan.setManual(i, rpm: rpm) }
                catch {
                    fanLog.error("fan re-assert(\(i, privacy: .public)) FAILED: \(String(describing: error), privacy: .public)")
                }
            }
        } else {
            fanLog.fault("fan reclaim persists on \(reclaimed.sorted(), privacy: .public) — OS wants control, releasing all fans")
            if fan.resetAll() { fanCore.didResetAll() }
            fanHolderID = nil
            fanHeldTargets = [:]
            fanKillTimer?.cancel(); fanKillTimer = nil
        }
    }

    func setFanAuto(_ index: Int, holdUnlock: Bool, withReply reply: @escaping (Bool) -> Void) {
        // Hand one fan back to the OS. Does NOT clear the crash-reset arm or holder: a
        // sibling fan may still be manual, and over-resetting on a later drop is
        // harmless while under-resetting is the hazard. With `holdUnlock` (opt-in
        // fast-re-engage pref) the controller unlock is kept once NO fan remains
        // manual — a latent hazard the core then supervises exactly like a pin.
        fanQ.async {
            guard let fan = self.fan else { reply(false); return }
            do {
                try fan.setAuto(index, holdUnlock: holdUnlock)
                self.fanHeldTargets[index] = nil
                if self.fanHeldTargets.isEmpty, holdUnlock, fan.hasFtst() {
                    self.fanCore.didAutoWithHold()
                    self.armFanKillSwitch_fanQ()
                }
                fanLog.notice("setFanAuto(\(index, privacy: .public), hold=\(holdUnlock, privacy: .public)) ok")
                reply(true)
            } catch {
                fanLog.error("setFanAuto(\(index, privacy: .public)) FAILED: \(String(describing: error), privacy: .public)")
                reply(false)
            }
        }
    }

    func resetAllFans(withReply reply: @escaping (Bool) -> Void) {
        // Explicit full reset (app disabled / pre-sleep). Disarm the crash reset ONLY
        // if the critical clears actually succeeded — a silently-failed reset must
        // leave `manualHeld` armed so a later last-client-drop retries instead of
        // believing the fans were already handed back.
        fanQ.async {
            guard let fan = self.fan else { reply(false); return }
            let ok = fan.resetAll()
            if ok { self.fanCore.didResetAll(); self.fanHolderID = nil; self.fanHeldTargets = [:] }
            fanLog.notice("resetAllFans ok=\(ok, privacy: .public)")
            reply(ok)
        }
    }

    func sleepNow(withReply reply: @escaping (Bool) -> Void) {
        // Explicit user "sleep now". Force EVERY disablesleep writer off first
        // (reclaim = lid override + remote hold → pmset disablesleep 0, synchronous
        // waitUntilExit) so the sleep below actually sticks instead of dropping only
        // the display, THEN issue the immediate sleep. Both run as root on `q`, in
        // order — no app-side XPC race can leave a hold dangling.
        q.async {
            self.cancelRemoteHoldExpiry_locked()
            self.core.reclaimAtStartup()
            let ok = Helper.sleepNowPmset()
            dtrace("sleepNow: writers cleared, pmset sleepnow ok=\(ok)")
            reply(ok)
        }
    }

    private static func sleepNowPmset() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["sleepnow"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            dtrace("pmset sleepnow spawn FAILED: \(error.localizedDescription)")
            return false
        }
    }

    /// Called on the wake-promote path (within `q`): a remote wake just fired, so
    /// hold sleep open for the bootstrap window even before any client connects,
    /// giving DchTerm time to dial back in. If nothing connects + heartbeats, the
    /// expiry releases it and the Mac re-sleeps next cadence.
    private func bootstrapRemoteHoldFromPromote() {
        // A remote wake fired: hold sleep open STICKILY so the woken Mac stays up for
        // the whole remote session — until the user explicitly sleeps it
        // (prosper://sleep) or opens the lid (clearRemoteSession). Deliberately NO
        // lapsing TTL here (unlike the heartbeat path): the Mac must not drop back to
        // sleep a few seconds later if the app's heartbeat is delayed or its XPC
        // connection is still re-establishing across the wake — the reported "connect,
        // then lose it after a few seconds". The sticky flag also makes the heartbeat's
        // soft release (and any still-pending TTL) a no-op, so nothing but an explicit
        // sleep / lid-open can drop it.
        // ponytail: no expiry → a clamshell Mac woken and then abandoned (app gone,
        // never slept, lid never opened) stays awake until the next explicit sleep or a
        // daemon restart (reclaimAtStartup clears it). By design — the user owns this
        // trade. Backstops: the remote-wake battery floor gates whether a promote
        // happens at all, and opening the lid releases it.
        let ok = core.promoteRemoteHold()
        dtrace("promote: STICKY remoteHold pmset ok=\(ok) (held until explicit sleep / lid open)")
    }

    private func armRemoteHoldExpiry_locked() {
        // cancel+create per heartbeat ON PURPOSE (not reschedule-in-place): cancel()
        // guarantees a pending-but-undelivered fire is dropped, while schedule() on a
        // live timer does not retract one — a stale expiry sneaking in right after a
        // refresh would flap the hold. One timer alloc per ~10s beat is nothing.
        cancelRemoteHoldExpiry_locked()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + .seconds(remoteHoldTTLSeconds))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            _ = self.core.setRemoteHold(false)
            dtrace("remoteHold EXPIRED: \(remoteHoldTTLSeconds)s with no heartbeat → sleep re-enabled (app gone / network dropped?)")
            self.remoteHoldTimer = nil
        }
        t.resume()
        remoteHoldTimer = t
    }

    private func cancelRemoteHoldExpiry_locked() {
        remoteHoldTimer?.cancel()
        remoteHoldTimer = nil
    }

    /// Arm the idle exit immediately at startup so a daemon that launchd spins up
    /// for a connection that never completes the code-sign handshake still exits
    /// instead of lingering with zero clients.
    func armIdleAtStartup() {
        q.async { self.armIdleExit_locked() }
    }

    /// Clear any `disablesleep` left stuck by a prior unclean kill. Synchronous so
    /// it completes before we accept the first connection (no race with an
    /// incoming setOverride(true)). See LidHelperCore.reclaimAtStartup.
    func reclaimAtStartup() {
        // Clear a stuck lid override AND reset every fan to auto, both before the
        // first connection is accepted — a fan left manual by an unclean kill is a
        // thermal hazard, so cold start always hands fans back to the OS. fanCore is
        // owned by fanQ, so its reclaim runs there (also sync — done before resume).
        q.sync { core.reclaimAtStartup() }
        fanQ.sync { fanCore.reclaimAtStartup() }
    }

    // pmset is a one-shot toggle (not a hot path); shelling it matches openlid and
    // is trivially correct. Runs as root here, so no sudo. // ponytail: pmset over
    // raw IOKit IOPMSetSystemPowerSetting — switch only if spawn cost ever matters.
    private static func applyPmset(_ on: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-a", "disablesleep", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            dtrace("pmset -a disablesleep \(on ? 1 : 0) → exit \(p.terminationStatus)")
            return p.terminationStatus == 0
        } catch {
            dtrace("pmset spawn FAILED: \(error.localizedDescription)")
            return false
        }
    }

    // Only armed once no client is connected (and, by connectionClosed, the
    // override is already off). Must run on `q`.
    private func armIdleExit_locked() {
        cancelIdleExit_locked()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + .seconds(idleExitSeconds))
        t.setEventHandler { [weak self] in
            guard let self else { exit(0) }
            // Remote-wake keeps the daemon resident with zero clients; never exit
            // while it's armed. Otherwise defer to the lid core's idle rule.
            if self.remoteWake.isResident { return }
            self.core.idleFired()
        }
        t.resume()
        idleTimer = t
    }

    private func cancelIdleExit_locked() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    /// Cold launch (RunAtLoad): read the persisted remote-wake config. Enabled →
    /// register the powerd observer on THIS runloop + arm; the idle-exit guard then
    /// keeps us resident. Disabled → nothing happens and the idle timer exits us in
    /// 10s, preserving "costs nothing until used". Must run on the main thread
    /// before RunLoop.run so the IOPMConnection schedules on the right runloop.
    func startRemoteWakeAtStartup() {
        // Bootstrap a keep-awake hold the instant a wake promotes, so the Mac stays
        // up for the client to reconnect (runs inside the observer's `q.sync` wake
        // path, so it's already serialized on `q`).
        remoteWake.onPromote = { [weak self] in self?.bootstrapRemoteHoldFromPromote() }
        remoteWake.startFromDisk()
    }
}

let delegate = Helper()
let listener = NSXPCListener(machServiceName: helperMachServiceName)
listener.delegate = delegate
// Self-heal a `disablesleep` left stuck by an unclean kill, THEN arm the idle
// exit, both BEFORE accepting connections: a daemon launchd spun up for a
// handshake that never completes still exits instead of lingering, and the
// first valid connection's setOverride can't race the reclaim. The first valid
// connection cancels the idle timer.
delegate.reclaimAtStartup()
delegate.armIdleAtStartup()
// Read the persisted remote-wake config and, if enabled, go resident + arm the
// dark-wake poll. Disabled (the default) → the idle timer above exits us in 10s.
delegate.startRemoteWakeAtStartup()
listener.resume()
// Block on the run loop; launchd owns our lifecycle and the idle-exit above ends
// the process when no client remains.
RunLoop.current.run()
