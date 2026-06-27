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
    static func sleepNow() {
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
}
