import AppKit

// Migrate settings from the legacy `com.prosper.app` bundle id BEFORE anything
// reads UserDefaults.standard (the domain is keyed by bundle id).
DefaultsMigration.runIfNeeded()

// Relocate HF cache to ~/.config/prosper/hf and run one-time migration before anything else.
ModelPaths.bootstrap()

// CLI: `ProsperApp agent [--cwd <dir>] <prompt…>` queues a prompt for the running
// app (launching it if needed) and exits — must run before the single-instance
// guard or the guard would just activate the app and drop the arguments.
AgentCLI.runIfRequested()

// Single-instance guard. A second running copy of the SAME bundle cannot claim
// the Carbon global hotkeys (RegisterEventHotKey gives the combo to whoever
// registered first → eventHotKeyExistsErr), so a stale duplicate silently kills
// EVERY shortcut. If another instance of our bundle id is already running,
// surface it and exit instead of becoming a dead, hotkey-less zombie. Scoped to
// bundled runs (a bundle id is present); dev runs of the bare binary are exempt.
if let bundleId = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        .filter { $0 != NSRunningApplication.current && !$0.isTerminated }
    if let existing = others.first {
        NSLog("prosper: another instance (pid \(existing.processIdentifier)) is already running — activating it and exiting")
        existing.activate(options: [.activateAllWindows])
        exit(0)
    }
}

// Plain AppKit entry point (no @main SwiftUI App) so we keep full control over
// the status item, global hotkey, and the CGEvent tap.
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu-bar agent, no Dock icon (LSUIElement)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
