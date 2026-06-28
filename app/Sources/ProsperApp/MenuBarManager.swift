import AppKit
import ApplicationServices

/// Ice/Bartender-style menu-bar manager. Owns one (optionally two) divider
/// `NSStatusItem`s that act as section delimiters. Hiding works by expanding the
/// hidden divider's `length` so every item the user has ⌘-dragged to its LEFT is
/// pushed off the screen edge; revealing collapses it back. This is the only
/// mechanism macOS exposes — there is no API to hide a *chosen* foreign item in
/// place, so section membership is positional (the user assigns it by dragging).
///
/// Hot-path discipline:
///  - show/hide is a single `NSStatusItem.length` assignment (≤ 1 ms, instant).
///  - the CGS enumeration (`currentItems`) runs only on reveal / explicit refresh,
///    never on a per-event flood; the bundle-id cache keeps the warm path ≤ 2 ms.
///  - passive `NSEvent` monitors (mouse-leave / outside-click) arm ONLY while the
///    hidden section is revealed, so the idle cost is zero.
@MainActor
final class MenuBarManager: NSObject {
    static let shared = MenuBarManager()

    /// Divider button widths. `expanded` is large enough to push all left-of-it
    /// items past the screen's left edge on any display.
    private enum Lengths {
        static let standard = NSStatusItem.variableLength
    }

    /// Expanded divider width: wide enough to push everything left of it past the
    /// screen's left edge. Derived from the live primary-display width (not a fixed
    /// 10 000) so it stays correct on ultrawide / Retina-scaled displays.
    private var expandedLength: CGFloat { (NSScreen.main?.frame.width ?? 2000) + 200 }

    private var hiddenDivider: NSStatusItem?
    private var alwaysHiddenDivider: NSStatusItem?

    /// Transient: is the hidden section currently revealed (dividers collapsed)?
    private var revealed = false
    private var rehideTimer: Timer?
    private var outsideMonitor: Any?
    private var hoverMonitor: Any?

    /// Set by AppDelegate from the registry (boot + onEnabledChanged). Defaults
    /// true so a reconcile before the registry wires up doesn't suppress setup.
    var menubarExtLive = true

    var isActive: Bool { hiddenDivider != nil }

    // MARK: - Lifecycle

    /// Idempotent. Builds the dividers when the feature is live, tears them down
    /// otherwise. Enumeration/hide/spacing need NO Accessibility (CGS only); only
    /// the opt-in reorder does, and it prompts on its own toggle.
    func reconcile() {
        if menubarExtLive && MenuBarBridge.available {
            setup()
        } else {
            teardown()
            // Feature off: don't leave a global spacing override stranded system-wide
            // (it would persist with no owner to reset it). Restore the macOS default.
            MenuBarSpacing.apply(spacing: MenuBarSpacing.defaultSpacing)
        }
    }

    /// Rebuild the dividers from scratch — used when a structural setting changes
    /// (e.g. toggling the two-tier always-hidden section) so the second divider
    /// appears/disappears. Cheap: two status-item teardowns + setup.
    func reconcileDividers() {
        guard menubarExtLive && MenuBarBridge.available else { teardown(); return }
        teardown()
        setup()
    }

    private func setup() {
        guard hiddenDivider == nil else { return }
        // Apply persisted spacing (no relaunch — takes effect as apps launch).
        MenuBarSpacing.apply(spacing: Preferences.menuBarStore.clampedSpacing)

        let div = makeDivider(symbol: "chevron.left.2", autosave: "ProsperMenuBarHiddenDivider",
                              action: #selector(toggleHidden))
        hiddenDivider = div
        MenuBarBridge.dividerWindowIDs = dividerWindowIDs()

        if Preferences.menuBarStore.alwaysHiddenEnabled {
            let alt = makeDivider(symbol: "chevron.left", autosave: "ProsperMenuBarAlwaysHiddenDivider",
                                  action: #selector(toggleAlwaysHidden))
            alwaysHiddenDivider = alt
            MenuBarBridge.dividerWindowIDs = dividerWindowIDs()
        }

        // Start in the hidden state (dividers expanded). A crash can't strand
        // third-party icons off-screen: our status items die with the process, so
        // the OS reflows the menu bar automatically — no persistent off-screen push.
        revealed = false
        revealedAlwaysHidden = false
        applyDividerLengths()
        observeTermination()
        observeScreenChanges()
    }

    private func teardown() {
        rehideTimer?.invalidate(); rehideTimer = nil
        stopRevealMonitors()
        if let d = hiddenDivider { NSStatusBar.system.removeStatusItem(d) }
        if let d = alwaysHiddenDivider { NSStatusBar.system.removeStatusItem(d) }
        hiddenDivider = nil
        alwaysHiddenDivider = nil
        MenuBarBridge.dividerWindowIDs = []
        revealed = false
        revealedAlwaysHidden = false
        if let o = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o); terminationObserver = nil
        }
        if let o = screenObserver {
            NotificationCenter.default.removeObserver(o); screenObserver = nil
        }
    }

    private func makeDivider(symbol: String, autosave: String, action: Selector) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: Lengths.standard)
        item.autosaveName = autosave   // distinct per divider so positions don't collide
        if let button = item.button {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Menu Bar")
            button.image?.isTemplate = true
            button.target = self
            button.action = action
        }
        return item
    }

    private func dividerWindowIDs() -> Set<CGWindowID> {
        var ids = Set<CGWindowID>()
        for d in [hiddenDivider, alwaysHiddenDivider] {
            if let n = d?.button?.window?.windowNumber, n > 0 { ids.insert(CGWindowID(n)) }
        }
        return ids
    }

    // MARK: - Show / hide (the hot path)

    /// Collapse/expand dividers to match `revealed`. A single length assignment per
    /// divider — visually instant, no enumeration.
    /// Single source of truth for both divider widths. Every length change routes
    /// through here (derived from `revealed` + `revealedAlwaysHidden`) so the two
    /// dividers can never disagree — no inline `length =` pokes elsewhere.
    private func applyDividerLengths() {
        let l = MenuBarLogic.dividerLengths(revealed: revealed,
                                            revealedAlwaysHidden: revealedAlwaysHidden,
                                            standard: Lengths.standard, expanded: expandedLength)
        hiddenDivider?.length = l.hidden
        alwaysHiddenDivider?.length = l.alwaysHidden
        updateChevron()
    }

    private var revealedAlwaysHidden = false

    @objc func toggleHidden() {
        guard hiddenDivider != nil else { return }
        if isActiveSpaceFullscreen { return }   // menu bar is auto-hidden anyway
        setRevealed(!revealed)
    }

    @objc func toggleAlwaysHidden() {
        guard alwaysHiddenDivider != nil else { return }
        if isActiveSpaceFullscreen { return }
        revealedAlwaysHidden.toggle()
        if revealedAlwaysHidden {
            setRevealed(true)        // revealing always-hidden implies hidden shown (applies lengths + monitors + timer)
        } else {
            applyDividerLengths()    // collapse just the always-hidden band; keep hidden as-is
            scheduleRehide()
        }
    }

    func setRevealed(_ value: Bool) {
        revealed = value
        applyDividerLengths()
        if revealed {
            scheduleRehide()
            startRevealMonitors()
        } else {
            revealedAlwaysHidden = false
            rehideTimer?.invalidate(); rehideTimer = nil
            stopRevealMonitors()
        }
    }

    private func updateChevron() {
        let symbol = revealed ? "chevron.right.2" : "chevron.left.2"
        hiddenDivider?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Menu Bar")
        hiddenDivider?.button?.image?.isTemplate = true
    }

    // MARK: - Auto-rehide + reveal monitors

    private func scheduleRehide() {
        rehideTimer?.invalidate()
        let secs = TimeInterval(Preferences.menuBarStore.clampedAutoRehide)
        rehideTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.setRevealed(false) }
        }
    }

    /// Arm passive monitors only while revealed: rehide when the user clicks
    /// outside the menu bar, and (if enabled) keep the section open while the
    /// cursor stays in the menu-bar strip. Removed the instant we rehide → zero
    /// idle cost.
    private func startRevealMonitors() {
        stopRevealMonitors()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated {
                // A click below the menu-bar strip rehides; clicks ON the bar (to
                // use a revealed icon) keep it open and re-arm the timer. A GLOBAL
                // monitor has no associated window, so `event.locationInWindow` is
                // unreliable — read the real cursor via NSEvent.mouseLocation and
                // compare against the screen the cursor is actually on.
                let loc = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { $0.frame.contains(loc) } ?? NSScreen.main
                let top = screen?.frame.maxY ?? .infinity
                if loc.y < top - Self.menuBarHeight {
                    MenuBarManager.shared.setRevealed(false)
                } else {
                    MenuBarManager.shared.scheduleRehide()
                }
            }
        }
        guard Preferences.menuBarStore.hoverReveal else { return }
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in
            MainActor.assumeIsolated {
                let y = NSEvent.mouseLocation.y
                if y >= (NSScreen.main?.frame.maxY ?? 0) - Self.menuBarHeight {
                    MenuBarManager.shared.scheduleRehide()   // cursor in the bar: stay open
                }
            }
        }
    }

    private func stopRevealMonitors() {
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        if let m = hoverMonitor { NSEvent.removeMonitor(m); hoverMonitor = nil }
    }

    private static let menuBarHeight: CGFloat = 24

    // MARK: - Enumeration / sections (cold path: reveal + Settings only)

    /// Current managed items on the main display, sorted left→right. Warm path
    /// ≤ 2 ms (bundle-id cache hot); cold first call pays the uncached lookups.
    func currentItems() -> [MenuBarItem] {
        MenuBarBridge.items(onDisplay: CGMainDisplayID())
    }

    /// Section assignment for the live menu bar, for the Settings list. Compares
    /// each item's x against the divider window x-positions.
    func sectionedItems() -> [(item: MenuBarItem, section: MenuBarSection)] {
        let items = currentItems()
        guard let hiddenX = dividerFrameX(hiddenDivider) else {
            return items.map { ($0, .visible) }
        }
        let altX = dividerFrameX(alwaysHiddenDivider)
        return items.map { ($0, MenuBarLogic.section(forItemX: $0.frame.minX,
                                                      hiddenDividerX: hiddenX,
                                                      alwaysHiddenDividerX: altX)) }
    }

    private func dividerFrameX(_ item: NSStatusItem?) -> CGFloat? {
        guard let n = item?.button?.window?.frame.minX else { return nil }
        return n
    }

    // MARK: - Spacing

    /// Persist + apply a new spacing (no relaunch). Caller surfaces the relaunch
    /// UI separately.
    func setSpacing(_ spacing: Int) {
        var store = Preferences.menuBarStore
        store.spacing = spacing
        Preferences.menuBarStore = store
        MenuBarSpacing.apply(spacing: store.clampedSpacing)
    }

    // MARK: - Misc

    private var isActiveSpaceFullscreen: Bool {
        // The menu bar auto-hides in fullscreen; revealing the section is a no-op.
        // Cheap heuristic: the main screen's visibleFrame reaches the physical top.
        guard let screen = NSScreen.main else { return false }
        return screen.visibleFrame.height >= screen.frame.height - 1
    }

    private var terminationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    /// Re-apply divider widths when the display layout changes (resolution change,
    /// display attach/detach, sleep/wake). `expandedLength` is display-relative, so
    /// a stale width could under-push items off-screen otherwise.
    private func observeScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuBarManager.shared.applyDividerLengths() }
        }
    }

    private func observeTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { MenuBarBridge.appTerminated(pid: app.processIdentifier) }
        }
    }
}
