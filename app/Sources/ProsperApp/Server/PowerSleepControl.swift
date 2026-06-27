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
        // Release both daemon writers in issue order on the shared apply chain, THEN
        // sleep: pmset is refused / instantly re-woken while disablesleep is still
        // held, so the sleep must come after the releases land.
        LidSleepHelper.enqueueApply {
            _ = await LidSleepHelper.setRemoteSessionActive(false)
            _ = await LidSleepHelper.setDisabled(false)
            systemSleep()
        }
    }

    private static func systemSleep() {
        // `pmset sleepnow` needs no privilege for an on-demand sleep.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["sleepnow"]
        try? p.run()
    }
}
