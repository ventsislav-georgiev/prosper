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
            return FanReading(id: i, min: b.min, max: b.max, current: fc.currentRPM(i) ?? 0)
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
    private static var connection: NSXPCConnection?
    private static var observersInstalled = false

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
        installSleepObservers()
        let c = connection ?? makeConnection()
        connection = c
        return c
    }

    // MARK: - Public ops (called from the settings pane + wake/sleep)

    /// Force one fan to a manual RPM. Holds the connection open so the daemon keeps
    /// the manual pin alive; a drop (crash/disable) resets it. Returns success.
    @discardableResult
    static func setManual(_ index: Int, rpm: Double, timeout: TimeInterval = 12) async -> Bool {
        guard let c = await ensureConnection() else { return false }
        return await call(c, timeout: timeout) { proxy, done in proxy.setFanManualRPM(index, rpm: rpm) { done($0) } }
    }

    /// Hand one fan back to OS thermal control (other fans unaffected).
    @discardableResult
    static func setAuto(_ index: Int) async -> Bool {
        let c: NSXPCConnection
        if let existing = connection { c = existing }
        else if let opened = await ensureConnection() { c = opened }
        else { return false }
        return await call(c) { proxy, done in proxy.setFanAuto(index) { done($0) } }
    }

    /// Reset every fan to auto. Used on explicit disable and before sleep. On disable
    /// (`teardown: true`) the connection is torn down so the daemon idle-exits.
    @discardableResult
    static func resetAll(teardown: Bool = false) async -> Bool {
        // No connection → nothing to reset (daemon not running, fans already on auto).
        guard let c = connection else { return true }
        let ok = await call(c) { proxy, done in proxy.resetAllFans { done($0) } }
        if teardown {
            c.invalidate()
            if connection === c { connection = nil }
        }
        return ok
    }

    /// Re-apply the user's saved manual targets — on app launch and after wake.
    /// No-op (and never spins up the daemon) when manual control is off.
    static func reapplyFromPreferences() async {
        guard Preferences.fanManualEnabled else { return }
        let targets = Preferences.fanTargets
        guard !targets.isEmpty else { return }
        for (index, rpm) in targets { _ = await setManual(index, rpm: rpm) }
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
                guard Preferences.fanManualEnabled, let c = connection else { return }
                let sem = DispatchSemaphore(value: 0)
                let proxy = c.remoteObjectProxyWithErrorHandler { _ in sem.signal() } as? ProsperHelperProtocol
                guard let proxy else { return }
                proxy.resetAllFans { _ in sem.signal() }
                _ = sem.wait(timeout: .now() + 2)
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await reapplyFromPreferences() }
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
        await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            let proxy = c.remoteObjectProxyWithErrorHandler { @Sendable err in
                Self.log.error("fan call failed: \(err.localizedDescription, privacy: .public)")
                once.resume(false)
            } as? ProsperHelperProtocol
            guard let proxy else { once.resume(false); return }
            once.armTimeout(timeout)
            body(proxy) { @Sendable ok in once.resume(ok) }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var cont: CheckedContinuation<Bool, Never>?
        init(_ c: CheckedContinuation<Bool, Never>) { cont = c }
        func resume(_ v: Bool) {
            lock.lock(); let c = done ? nil : cont; done = true; cont = nil; lock.unlock()
            c?.resume(returning: v)
        }
        func armTimeout(_ seconds: TimeInterval) {
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.resume(false) }
        }
    }
}
