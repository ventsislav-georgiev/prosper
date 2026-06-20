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
}
