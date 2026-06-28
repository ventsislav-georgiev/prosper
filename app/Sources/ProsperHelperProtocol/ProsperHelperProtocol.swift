import Foundation

// Shared contract between the app (client) and the privileged lid-sleep helper
// daemon. Lives in its own target so both the ProsperApp executable and the
// ProsperHelper executable compile the SAME protocol + identifiers — a
// mismatch would silently break the XPC interface.

/// launchd label / SMAppService plist name / Mach service name — all the same
/// string by convention. The plist ships at
/// `Contents/Library/LaunchDaemons/<this>.plist`.
///
/// Generic `.helper` (NOT `.lidhelper`): the daemon does lid-sleep, remote-wake AND
/// fan control now. The legacy `.lidhelper` label (v2.96–) is unregistered once on
/// launch — see `LidSleepHelper.migrateLegacyLabelOnLaunch`.
public let helperLabel = "eu.illegible.prosper.helper"

/// Mach service the daemon vends and the app connects to. launchd advertises it
/// (see the `MachServices` key in the plist) and launches the daemon on demand
/// when the first message arrives.
public let helperMachServiceName = "eu.illegible.prosper.helper"

/// Legacy label retired in favor of `helperLabel`. Kept ONLY so the one-time
/// migration can unregister the orphaned SMAppService item on upgrade.
public let legacyHelperLabel = "eu.illegible.prosper.lidhelper"

/// The one privileged operation the daemon performs: flip the system clamshell-
/// sleep override (`pmset -a disablesleep`). Runs as root inside the daemon, so
/// the app needs no sudoers entry. `reply(true)` on success.
@objc public protocol ProsperHelperProtocol {
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

    /// Force fan `index` to `rpm` (manual mode), as root. Writing fan state needs
    /// root, so it lives here alongside the other privileged ops. TYPED params (not
    /// JSON) so the XPC boundary can't be fed an arbitrary key/value — only an int
    /// index + a double RPM, both re-clamped fail-closed at SMCKit's lowest write
    /// primitive (whitelist + absolute floor/ceiling, independent of SMC-reported
    /// bounds). Manual fan control is pinned to the XPC connection exactly like the
    /// lid override: if the app crashes, the daemon resets EVERY fan to auto when
    /// the last client drops, so a fan is NEVER left wedged at an unsafe speed.
    /// `reply(true)` on a successful write.
    func setFanManualRPM(_ index: Int, rpm: Double, withReply reply: @escaping (Bool) -> Void)

    /// Hand fan `index` back to OS thermal control. `reply(true)` on success.
    func setFanAuto(_ index: Int, withReply reply: @escaping (Bool) -> Void)

    /// Reset EVERY fan to OS thermal control — the thermal-safety primitive. Called
    /// by the app on explicit disable and on system sleep, and by the daemon itself
    /// on cold start + on last-client-drop. Idempotent. `reply(true)` once issued.
    func resetAllFans(withReply reply: @escaping (Bool) -> Void)
}
