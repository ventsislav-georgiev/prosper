import AppKit

/// "Move to Applications" helper (LetsMove-style). On first launch from outside
/// `/Applications` (e.g. the Downloads folder or a mounted DMG), offers to move
/// the app into `/Applications` and relaunch, so updates + permissions behave.
///
/// Conservative by design: only prompts once, never moves without consent, and
/// silently no-ops when already installed, when running a dev build from the
/// SwiftPM build dir, or when the destination is not writable.
@MainActor
enum AppRelocator {

    private static let didOfferKey = "didOfferMoveToApplications"

    /// Offers the move if appropriate. Call once at launch.
    static func offerIfNeeded() {
        guard shouldOffer() else { return }
        UserDefaults.standard.set(true, forKey: didOfferKey)

        let alert = NSAlert()
        alert.messageText = "Move Prosper to the Applications folder?"
        alert.informativeText = """
        Prosper works best from the Applications folder — it keeps permissions \
        stable and lets auto-update replace it cleanly. Move it now?
        """
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Don't Move")
        alert.alertStyle = .informational

        // Show a Dock icon + Cmd-Tab entry while the (otherwise iconless accessory)
        // app's modal alert is on screen, so the user can switch back to it. Flip
        // the policy before activating (so the alert lands on top of the Cmd-Tab
        // stack); runModal blocks, so bracket the policy with a defer that restores
        // on every exit.
        DockPolicy.windowDidShow(alert.window)
        defer { DockPolicy.windowDidHide(alert.window) }
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        moveToApplicationsAndRelaunch()
    }

    /// Whether the app should offer to relocate itself.
    private static func shouldOffer() -> Bool {
        if UserDefaults.standard.bool(forKey: didOfferKey) { return false }
        let path = Bundle.main.bundlePath
        // Only meaningful for a packaged .app bundle.
        guard path.hasSuffix(".app") else { return false }
        // Already in a system/user Applications dir → nothing to do.
        if path.hasPrefix("/Applications/") { return false }
        if path.contains("/Applications/") { return false }
        // Dev build run straight from the SwiftPM build dir → skip.
        if path.contains("/.build/") || path.contains("/DerivedData/") { return false }
        return true
    }

    private static func moveToApplicationsAndRelaunch() {
        let fm = FileManager.default
        let src = Bundle.main.bundleURL
        let dest = URL(fileURLWithPath: "/Applications").appendingPathComponent(src.lastPathComponent)

        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: src, to: dest)
        } catch {
            let err = NSAlert()
            err.messageText = "Couldn't move Prosper"
            err.informativeText = error.localizedDescription
            DockPolicy.windowDidShow(err.window)
            err.runModal()
            DockPolicy.windowDidHide(err.window)
            return
        }

        // Relaunch the moved copy, then quit this instance.
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
