import AppKit
import ServiceManagement
import ProsperHelperProtocol

/// User-facing guidance when a privileged-helper-backed feature can't run because
/// macOS hasn't approved the background login item. Every feature that needs the
/// daemon (lid-sleep, remote-wake, sleep-now, manual fan control) routes its
/// registration through `LidSleepHelper.ensureRegistered`, which calls this on the
/// `.requiresApproval` path instead of silently bouncing the user to Login Items.
///
/// ponytail: a plain NSAlert, not a bespoke SwiftUI modal — it's a two-button
/// "do this one thing in System Settings" prompt and AppKit already draws it.
@MainActor
enum HelperApproval {
    // De-dupe two ways: `presenting` (held across the nested runModal loop) suppresses
    // a second caller drained WHILE the modal is up — lid re-arm + fan re-apply both
    // hit needsApproval at launch. The 3s `lastShown` gate suppresses the burst AFTER
    // a modal closes (lastShown stamps on close), so the two launch features collapse
    // to ONE modal. Both guards are load-bearing — don't drop either.
    // ponytail: 3s window — a deliberate toggle seconds later still informs.
    private static var presenting = false
    private static var lastShown: Date = .distantPast

    /// Show the approval modal for `feature` (a human label like "Manual fan
    /// control"). "Open System Settings" jumps to the Login Items pane where the
    /// user flips Prosper on under "Allow in the Background"; "Later" dismisses.
    static func presentNeedsApproval(feature: String) {
        guard !presenting, Date().timeIntervalSince(lastShown) > 3 else { return }
        presenting = true
        defer { presenting = false; lastShown = Date() }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(feature) needs Prosper's background helper"
        alert.informativeText = """
        To do this without asking for your password every time, Prosper uses a small \
        privileged helper that macOS must approve once.

        Open System Settings ▸ General ▸ Login Items & Extensions and turn on \
        "Prosper" under "Allow in the Background", then try again.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        // LSUIElement app: bring it forward so the modal isn't buried behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
