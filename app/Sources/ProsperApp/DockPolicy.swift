import AppKit

/// Temporarily shows a Dock icon (and a Cmd-Tab entry) while any Prosper window
/// is on screen.
///
/// Prosper runs as an `.accessory` agent (set at launch in main.swift) so it has no Dock tile and
/// its floating panels never appear in Cmd-Tab. The downside: once the user
/// clicks another app, an open Prosper window (command runner, clipboard history,
/// settings, …) is left behind in the background with no way to bring it forward —
/// no Dock icon to click, no Cmd-Tab entry to switch to.
///
/// This tracks how many tracked windows are currently visible. While at least one
/// is visible (and the user hasn't disabled the Dock icon in Settings) the app is
/// `.regular` — a Dock icon and Cmd-Tab entry appear; otherwise it's `.accessory`.
///
/// Ordering matters: the policy must become `.regular` *before* the app activates,
/// otherwise the app activates while still `.accessory` and macOS never records it
/// as a recently-active regular app — leaving it stuck at the bottom of the
/// Cmd-Tab stack. So `windowDidShow` both flips the policy and re-activates, and
/// callers must invoke it before their own `NSApp.activate` / `makeKeyAndOrderFront`.
@MainActor
enum DockPolicy {
    /// Identities of the windows currently counted as visible. A set makes the
    /// register/unregister calls idempotent (a double `windowDidHide` is a no-op)
    /// and naturally ref-counts when several windows are open at once. Membership
    /// is tracked regardless of the user's preference; `apply()` decides the policy.
    private static var visible = Set<ObjectIdentifier>()
    private static var pendingDemotion: DispatchWorkItem?
    private static var demotionGeneration = 0
    static let defaultDemotionDelay: TimeInterval = 0.2
    private static var demotionDelay = defaultDemotionDelay
    private static func liveSetPolicy(_ target: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        if target == .regular { NSApp.activate(ignoringOtherApps: true) }
    }
    private static var setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void = liveSetPolicy

    /// #1821: how long a show waits for its activation before re-asserting it (one check per show, no timer at idle).
    static let activationSettle: TimeInterval = 0.25
    // #1821 seams: the order front, the activation probes, the re-assertion and its scheduler (a row fakes them all).
    private static var order: @MainActor (NSWindow) -> Void = liveOrder
    private static var isActive: @MainActor () -> Bool = { NSApp.isActive }
    private static var frontmostPid: @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    private static var reactivate: @MainActor () -> Void = liveReactivate
    private static var after: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, f in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { f() } }
    }
    private static func liveOrder(_ win: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
    /// macOS 14+ cooperative activation can refuse NSApp.activate after the accessory flip (the demotion handed front to
    /// another app, TransformProcessType pickNew=1); a Launch Services open of the running app is not refused (the same
    /// bypass as AgentIslandController.activate). Never under XCTest, and never for a bare executable (no .app to open).
    private static func liveReactivate() {
        let url = Bundle.main.bundleURL
        guard NSClassFromString("XCTestCase") == nil, url.pathExtension == "app" else { return }
        reactivateRoute(versions: liveVersions, openSelf: {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        }, activateCurrent: { NSRunningApplication.current.activate(options: [.activateAllWindows]) })
    }
    /// (running, on disk) CFBundleVersion; the disk one is read from Contents/Info.plist directly (Bundle caches its dictionary).
    private static func liveVersions() -> (running: String?, disk: String?) {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        let disk = (try? Data(contentsOf: plist)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        return (Bundle.main.infoDictionary?["CFBundleVersion"] as? String, disk?["CFBundleVersion"] as? String)
    }
    /// The route of the re-assertion (a row fakes all three): a Launch Services open of the bundle on disk starts the NEW copy
    /// when an update is staged but not yet relaunched, so a different (or unreadable) on-disk version only re-activates this process.
    static func reactivateRoute(versions: () -> (running: String?, disk: String?), openSelf: () -> Void, activateCurrent: () -> Void) {
        let v = versions()
        if let running = v.running, running == v.disk { openSelf() } else { activateCurrent() }
    }

    /// #1821: the one way a tracked window comes up: registered (the `.regular` flip) BEFORE it is activated and ordered
    /// front, then, if the activation was refused (the app still inactive with the same other app in front after
    /// `activationSettle`, the window still shown), re-asserted once. Without it the window is front and key inside the
    /// app while the keys go to the other app, and a click does not bring them back (operator 2026-11-21, beta.43 log:
    /// "ordered front from a non-active application" after each reopen that followed a demotion).
    static func present(_ win: NSWindow) {
        windowDidShow(win)
        let front = frontmostPid()
        order(win)
        let id = ObjectIdentifier(win)
        after(activationSettle) {
            guard visible.contains(id), !isActive(), let front, front != getpid(), frontmostPid() == front else { return }
            reactivate()
        }
    }

    /// Marks `window` as visible and reconciles the activation policy. Call this
    /// BEFORE activating the window so the `.regular` flip lands before activation.
    static func windowDidShow(_ window: NSWindow) {
        visible.insert(ObjectIdentifier(window))
        cancelPendingDemotion()
        apply()
    }

    /// Marks `window` as hidden and reconciles the activation policy (drops the
    /// Dock icon once the last visible window is gone).
    static func windowDidHide(_ window: NSWindow) {
        visible.remove(ObjectIdentifier(window))
        apply()
    }

    /// Re-evaluates the policy after the "Show Dock icon" preference changes, so
    /// toggling it takes effect immediately on any currently-open window.
    static func preferenceChanged() {
        apply()
    }

    /// Sets `.regular` (Dock icon + Cmd-Tab) when the icon is enabled and a window
    /// is visible, else `.accessory`. On the transition into `.regular` it also
    /// activates the app so the freshly-shown window rises to the top of the
    /// Cmd-Tab stack rather than being appended at the bottom.
    private static func apply() {
        guard Preferences.showDockIcon, !visible.isEmpty else {
            guard Preferences.showDockIcon else {
                cancelPendingDemotion()
                setPolicy(.accessory)
                return
            }
            scheduleDemotion()
            return
        }
        setPolicy(.regular)
    }

    private static func scheduleDemotion() {
        guard pendingDemotion == nil else { return }
        let generation = demotionGeneration
        let task = DispatchWorkItem {
            guard generation == demotionGeneration else { return }
            pendingDemotion = nil
            guard Preferences.showDockIcon, visible.isEmpty else { return }
            setPolicy(.accessory)
        }
        pendingDemotion = task
        DispatchQueue.main.asyncAfter(deadline: .now() + demotionDelay, execute: task)
    }

    private static func cancelPendingDemotion() {
        demotionGeneration &+= 1
        pendingDemotion?.cancel()
        pendingDemotion = nil
    }

    /// #1821: whether `window` is counted as shown (rows check the registration came before the order front).
    static func isShown(_ window: NSWindow) -> Bool { visible.contains(ObjectIdentifier(window)) }

    static func resetForTesting(
        demotionDelay: TimeInterval = defaultDemotionDelay,
        setPolicy: (@MainActor (NSApplication.ActivationPolicy) -> Void)? = nil,
        order: (@MainActor (NSWindow) -> Void)? = nil,
        isActive: (@MainActor () -> Bool)? = nil,
        frontmostPid: (@MainActor () -> pid_t?)? = nil,
        reactivate: (@MainActor () -> Void)? = nil,
        after: (@MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil
    ) {
        cancelPendingDemotion()
        self.demotionDelay = demotionDelay
        visible.removeAll()
        self.setPolicy = setPolicy ?? liveSetPolicy
        self.order = order ?? liveOrder
        self.isActive = isActive ?? { NSApp.isActive }
        self.frontmostPid = frontmostPid ?? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        self.reactivate = reactivate ?? liveReactivate
        self.after = after ?? { delay, f in DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { f() } } }
    }
}
