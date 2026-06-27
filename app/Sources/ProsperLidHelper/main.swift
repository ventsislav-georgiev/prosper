import Foundation
import LidHelperProtocol

// ProsperLidHelper — the privileged daemon behind "keep awake with the lid
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
final class LidHelper: NSObject, LidHelperProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    // Single serial queue guards all mutable state — XPC delivers connection
    // events + method calls on arbitrary queues, and the idle timer runs here too,
    // so every `core` call is serialized without the core needing its own lock.
    private let q = DispatchQueue(label: "\(lidHelperLabel).state")
    private var idleTimer: DispatchSourceTimer?
    // Auto-expiry for the remote-session keep-awake hold (see remoteHoldTTLSeconds).
    private var remoteHoldTimer: DispatchSourceTimer?
    private let core = LidHelperCore(apply: LidHelper.applyPmset, onIdle: { exit(0) })
    // Remote-wake lives in its own observer with its own state machine — zero
    // shared mutable state with `core` (the only coupling is the idle-exit guard
    // below, which keeps the daemon resident while remote-wake is armed). Uses the
    // same serial queue `q` so a setRemoteWake never races a lid op.
    private lazy var remoteWake = RemoteWakeObserver(queue: q)

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        // The OS invalidates the connection automatically if the peer fails this
        // requirement, so an impostor never reaches setLidSleepDisabled.
        conn.setCodeSigningRequirement(clientRequirement)
        conn.exportedInterface = NSXPCInterface(with: LidHelperProtocol.self)
        conn.exportedObject = self
        conn.invalidationHandler = { [weak self] in self?.connectionClosed() }
        conn.interruptionHandler  = { [weak self] in self?.connectionClosed() }
        q.sync {
            core.connectionOpened()
            cancelIdleExit_locked()
        }
        conn.resume()
        return true
    }

    private func connectionClosed() {
        // App quit or crashed — core resets the override here so the lid is NEVER
        // left wedged awake; arm the idle exit once no client remains.
        q.async { if self.core.connectionClosed() { self.armIdleExit_locked() } }
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
            if !resident && self.core.connections == 0 { self.armIdleExit_locked() }
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

    /// Called on the wake-promote path (within `q`): a remote wake just fired, so
    /// hold sleep open for the bootstrap window even before any client connects,
    /// giving DchTerm time to dial back in. If nothing connects + heartbeats, the
    /// expiry releases it and the Mac re-sleeps next cadence.
    private func bootstrapRemoteHoldFromPromote() {
        let ok = core.setRemoteHold(true)
        dtrace("promote: bootstrap remoteHold pmset ok=\(ok) ttl=\(remoteHoldTTLSeconds)s (Mac held awake for client to reconnect)")
        armRemoteHoldExpiry_locked()
    }

    private func armRemoteHoldExpiry_locked() {
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
        q.sync { core.reclaimAtStartup() }
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

let delegate = LidHelper()
let listener = NSXPCListener(machServiceName: lidHelperMachServiceName)
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
