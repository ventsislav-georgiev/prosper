import Foundation

// Shared contract between the app (client) and the privileged lid-sleep helper
// daemon. Lives in its own target so both the ProsperApp executable and the
// ProsperLidHelper executable compile the SAME protocol + identifiers — a
// mismatch would silently break the XPC interface.

/// launchd label / SMAppService plist name / Mach service name — all the same
/// string by convention. The plist ships at
/// `Contents/Library/LaunchDaemons/<this>.plist`.
public let lidHelperLabel = "eu.illegible.prosper.lidhelper"

/// Mach service the daemon vends and the app connects to. launchd advertises it
/// (see the `MachServices` key in the plist) and launches the daemon on demand
/// when the first message arrives.
public let lidHelperMachServiceName = "eu.illegible.prosper.lidhelper"

/// The one privileged operation the daemon performs: flip the system clamshell-
/// sleep override (`pmset -a disablesleep`). Runs as root inside the daemon, so
/// the app needs no sudoers entry. `reply(true)` on success.
@objc public protocol LidHelperProtocol {
    func setLidSleepDisabled(_ on: Bool, withReply reply: @escaping (Bool) -> Void)

    /// Push the remote-wake config (a sanitized `RemoteWakeConfig` JSON string).
    /// The daemon persists it to its root-owned file and arms/disarms the dark-wake
    /// poll loop. `reply(true)` when remote-wake is now resident (enabled). Strictly
    /// separate from the lid-sleep override above — different state machine, no
    /// shared assertion (protects the v2.114.3 lid FIFO).
    func setRemoteWake(_ json: String, withReply reply: @escaping (Bool) -> Void)

    /// Hold (or release) `disablesleep` while a remote dch session is live, so a Mac
    /// woken by remote-wake stays awake for the session instead of idle/clamshell
    /// sleeping mid-command. OR'd with the lid override at the pmset layer (either
    /// source keeps sleep disabled). Unlike the lid override this hold is NOT pinned
    /// to the XPC connection — the daemon is resident with zero clients while remote-
    /// wake is armed — so it auto-expires ~120s after the last `true` unless the app
    /// re-asserts it (the heartbeat). That timeout is the crash-safety: if the app
    /// dies the hold lapses and the Mac sleeps. `reply(true)` on a successful apply.
    func setRemoteSessionActive(_ on: Bool, withReply reply: @escaping (Bool) -> Void)

    /// Sleep the Mac now, as root. Clears BOTH `disablesleep` writers (lid override
    /// + remote-session hold) FIRST — synchronously, so the setting is committed —
    /// then `pmset sleepnow`. Doing it in the daemon is the whole point: a
    /// `pmset sleepnow` issued while `disablesleep` is still 1 only sleeps the
    /// display (the Mac stays awake + network-reachable), and the app can't reliably
    /// clear the daemon's remote hold over XPC when its connection has dropped. The
    /// daemon owns both writers and runs as root, so it can release-then-sleep
    /// atomically and the sleep actually sticks. `reply(true)` once the sleep is
    /// issued.
    func sleepNow(withReply reply: @escaping (Bool) -> Void)
}
