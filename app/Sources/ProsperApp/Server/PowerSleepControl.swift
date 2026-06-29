import AppKit
import Foundation

/// Single entry point to put the Mac to sleep on demand, releasing every Prosper
/// keep-awake hold first so `disablesleep` can't veto the sleep. Used by OpenLid's
/// "Sleep this Mac now" control and the `prosper://sleep` remote command (so a
/// user connected over DchTerm can sleep the Mac they just woke).
///
/// Why this is needed: `disablesleep` has multiple OR'd writers — OpenLid's lid
/// override AND the remote-session hold the DchSessionServer heartbeats while a dch
/// session is live. OpenLid's own off-switch only clears the lid override, so a
/// stuck remote-session hold had no off-switch at all. This releases both, in
/// order, then sleeps.
enum SleepControl {
    nonisolated(unsafe) private static var wakeToken: NSObjectProtocol?
    nonisolated private static let lock = NSLock()

    static func sleepNow() {
        // Latch sleep-suppression FIRST (synchronous), before anything can re-arm a
        // hold: while set, both disablesleep enablers — a DchTerm reconnect and
        // OpenLid's plugged-in rule — are dropped, so a brief wake can't promote to a
        // full wake and leave the Mac reachable. Remote wake is untouched (separate
        // XPC method), so the Mac stays remotely wakeable.
        LidSleepHelper.beginSleepSuppression()
        armWakeClear()
        // Stop the remote-terminal server from re-asserting its keep-awake hold
        // (sessions are NOT killed — they survive sleep and reconnect on wake).
        DchSessionServer.shared.releaseForSleep()
        // Hand the whole release-then-sleep to the root daemon: it clears BOTH
        // disablesleep writers synchronously (so the setting is committed) and only
        // then issues `pmset sleepnow`. Doing it app-side was the bug — pmset run
        // while disablesleep is still 1 only sleeps the display, and the app-side
        // release no-ops whenever its XPC connection has dropped, so the Mac stayed
        // awake + reachable. On the shared apply chain to keep order with any pending
        // lid op.
        LidSleepHelper.enqueueApply {
            _ = await LidSleepHelper.sleepNow()
        }
    }

    /// Clear the suppression on the next genuine FULL wake. Dark wakes for the
    /// remote-wake poll do NOT post `didWakeNotification`, so the latch survives them
    /// and the Mac keeps re-sleeping until the user (or a remote /wake → full wake)
    /// actually brings it up. One-shot: re-armed by the next sleepNow.
    /// ponytail: if a sleep command somehow neither sleeps nor wakes, the latch stays
    /// until the next real wake — fine, that path also means nothing re-triggered
    /// disablesleep, so the keep-awake feature isn't actually blocked in practice.
    private static func armWakeClear() {
        lock.lock(); defer { lock.unlock() }
        if wakeToken != nil { return }   // already armed for a prior sleep
        wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            LidSleepHelper.endSleepSuppression()
            lock.lock()
            if let t = wakeToken { NSWorkspace.shared.notificationCenter.removeObserver(t) }
            wakeToken = nil
            lock.unlock()
        }
    }
}
