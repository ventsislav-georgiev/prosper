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

    /// The always-visible control item (rightmost of ours). Clicking it toggles the
    /// hidden section; ⌥-clicking toggles the always-hidden band. It NEVER expands —
    /// that's the whole fix: a single divider that did double duty as chevron AND
    /// expander rode itself (and Prosper's own icon) off-screen when it expanded, so
    /// nothing was clickable. Splitting the control from the expander (the Ice /
    /// Bartender model) keeps the chevron on screen at all times.
    private var chevron: NSStatusItem?
    /// Empty expanding separator. Sits to the LEFT of the chevron; growing its
    /// `length` pushes every item left of it (the hidden section) off the screen edge.
    private var hiddenSeparator: NSStatusItem?
    /// Second-tier expander for the always-hidden band (leftmost of ours).
    private var alwaysHiddenSeparator: NSStatusItem?

    /// Transient: is the hidden section currently revealed (separators collapsed)?
    private var revealed = false
    private var rehideTimer: Timer?
    private var outsideMonitor: Any?

    /// Set by AppDelegate from the registry (boot + onEnabledChanged). Defaults
    /// true so a reconcile before the registry wires up doesn't suppress setup.
    var menubarExtLive = true

    var isActive: Bool { chevron != nil }

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
        guard chevron == nil else { return }
        // Apply persisted spacing (no relaunch — takes effect as apps launch).
        MenuBarSpacing.apply(spacing: Preferences.menuBarStore.clampedSpacing)

        // Order matters: the FIRST-created status item is rightmost, later ones appear
        // to its left. We want screen order (left→right):
        //   [alwaysHiddenSeparator] [always-hidden items] [hiddenSeparator] [hidden items] [chevron] [visible items]
        // so the chevron (created first) stays right of the expanders and is never
        // pushed off-screen when they grow.
        chevron = makeChevron()
        hiddenSeparator = makeSeparator(autosave: "ProsperMenuBarHiddenSeparator")
        // Always-hidden band: created (leftmost) only when the user has marked at least
        // one icon always-hidden in Settings. The arranger moves those icons left of it
        // (the move engine) and it stays expanded, so they never show — even on reveal.
        if !Preferences.menuBarOrderStore.alwaysHidden.isEmpty {
            alwaysHiddenSeparator = makeSeparator(autosave: "ProsperMenuBarAlwaysHiddenSeparator")
        }
        for item in [chevron, hiddenSeparator, alwaysHiddenSeparator].compactMap({ $0 }) {
            ProsperStatusItems.register(item)
        }

        // Start in the hidden state (separators expanded). A crash can't strand
        // third-party icons off-screen: our status items die with the process, so
        // the OS reflows the menu bar automatically — no persistent off-screen push.
        revealed = false
        revealedAlwaysHidden = false
        applyDividerLengths()
        publishOwnWindowIDs()
        observeTermination()
        observeScreenChanges()
    }

    private func teardown() {
        rehideTimer?.invalidate(); rehideTimer = nil
        stopRevealMonitors()
        for item in [chevron, hiddenSeparator, alwaysHiddenSeparator].compactMap({ $0 }) {
            NSStatusBar.system.removeStatusItem(item)
        }
        chevron = nil
        hiddenSeparator = nil
        alwaysHiddenSeparator = nil
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

    /// The always-visible clickable control. Left-click toggles the hidden section;
    /// ⌥-left-click toggles the always-hidden band (when the two-tier mode is on).
    private func makeChevron() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: Lengths.standard)
        item.autosaveName = "ProsperMenuBarChevron"
        if let button = item.button {
            button.image = Self.chevronImage(Preferences.menuBarStore.chevronStyle.collapsedSymbol)
            button.target = self
            button.action = #selector(chevronClicked)
        }
        return item
    }

    /// Build the divider glyph at standard menu-bar icon metrics. A bare
    /// `NSImage(systemSymbolName:)` renders at the default text point size, so the
    /// `ellipsis`/chevron glyphs sit small and airy inside the item box and read as
    /// extra padding next to neighbouring icons. Pin the point size so the chevron
    /// matches the rest of the bar, then bake transparent padding onto BOTH edges:
    /// AppKit exposes no per-item margin, so without this the divider sits glued to its
    /// neighbour (the Prosper icon) with no breathing room. Padding is symmetric (not
    /// right-only) so the click highlight — which AppKit sizes to the button bounds —
    /// stays centered on the glyph instead of leaving an empty gap to the glyph's right.
    private static func chevronImage(_ symbol: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: "Menu Bar")?
            .withSymbolConfiguration(cfg) else { return nil }
        let pad: CGFloat = 6   // per-side
        let padded = NSImage(size: NSSize(width: glyph.size.width + pad * 2, height: glyph.size.height))
        padded.lockFocus()
        glyph.draw(at: NSPoint(x: pad, y: 0), from: .zero, operation: .sourceOver, fraction: 1)   // centered
        padded.unlockFocus()
        padded.isTemplate = true
        return padded
    }

    /// An empty, near-invisible expander. Shows a faint hairline boundary while
    /// REVEALED (so the user can see where to ⌘-drag icons), and rides off-screen
    /// when expanded to hide. It is never the click target — the chevron is.
    private func makeSeparator(autosave: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: Lengths.standard)
        item.autosaveName = autosave
        if let button = item.button {
            button.attributedTitle = NSAttributedString(
                string: "￨", attributes: [.foregroundColor: NSColor.tertiaryLabelColor])
            // Not interactive: clicks fall through to do nothing rather than toggle.
            button.target = nil
            button.action = nil
        }
        return item
    }

    /// Publish our own control windows' CGS ids for the preview-health probe. Frame
    /// match needs the windows laid out, so defer one runloop hop past creation
    /// (windowNumber is unusable on Tahoe — see MenuBarBridge.windowID(forItemMinX:)).
    private func publishOwnWindowIDs() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.chevron != nil else { return }
            var ids = Set<CGWindowID>()
            for item in [self.chevron, self.hiddenSeparator, self.alwaysHiddenSeparator].compactMap({ $0 }) {
                if let x = item.button?.window?.frame.minX,
                   let id = MenuBarBridge.windowID(forItemMinX: x) { ids.insert(id) }
            }
            MenuBarBridge.dividerWindowIDs = ids
        }
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
        hiddenSeparator?.length = l.hidden
        alwaysHiddenSeparator?.length = l.alwaysHidden
        updateChevron()
    }

    private var revealedAlwaysHidden = false

    /// Chevron click handler. Plain click toggles the hidden section; ⌥-click toggles
    /// the always-hidden band (when enabled).
    @objc private func chevronClicked() {
        let optionDown = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        if optionDown && alwaysHiddenSeparator != nil {
            toggleAlwaysHidden()
        } else {
            toggleHidden()
        }
    }

    @objc func toggleHidden() {
        guard chevron != nil else { return }
        if isActiveSpaceFullscreen { return }   // menu bar is auto-hidden anyway
        setRevealed(!revealed)
    }

    @objc func toggleAlwaysHidden() {
        guard alwaysHiddenSeparator != nil else { return }
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
            MenuBarOrderEnforcer.shared.onReveal()   // on-demand ordering: correct order while visible
        } else {
            revealedAlwaysHidden = false
            rehideTimer?.invalidate(); rehideTimer = nil
            stopRevealMonitors()
        }
    }

    private func updateChevron() {
        let style = Preferences.menuBarStore.chevronStyle
        guard let button = chevron?.button else { return }
        let symbol = revealed ? style.revealedSymbol : style.collapsedSymbol
        button.image = Self.chevronImage(symbol)
    }

    /// Re-skin the chevron after a chevron-style change (cheap: one image swap,
    /// no teardown). Called from Settings.
    func refreshChevronStyle() { updateChevron() }

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
    }

    private func stopRevealMonitors() {
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
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
        guard let hiddenX = dividerFrameX(hiddenSeparator) else {
            return items.map { ($0, .visible) }
        }
        let altX = dividerFrameX(alwaysHiddenSeparator)
        return items.map { ($0, MenuBarLogic.section(forItemX: $0.frame.minX,
                                                      hiddenDividerX: hiddenX,
                                                      alwaysHiddenDividerX: altX)) }
    }

    /// Whether the live preview can be trusted (CGS enumeration still sees our own
    /// dividers). Hide/show + spacing don't depend on this — only the Settings
    /// preview strip does, so it degrades to an "update macOS" note in isolation.
    func previewHealthy() -> Bool { MenuBarBridge.enumHealthy() }

    private func dividerFrameX(_ item: NSStatusItem?) -> CGFloat? {
        guard let n = item?.button?.window?.frame.minX else { return nil }
        return n
    }

    // MARK: - Always-hidden placement (used by the arranger)

    /// CGS window id of the always-hidden separator — the anchor the arranger moves
    /// marked icons to the LEFT of. nil if the band isn't active or hasn't laid out.
    func alwaysHiddenAnchorWindowID() -> CGWindowID? {
        guard let x = alwaysHiddenSeparator?.button?.window?.frame.minX else { return nil }
        return MenuBarBridge.windowID(forItemMinX: x)
    }

    /// CGS window id of the (always-present) hidden separator — the anchor the
    /// arranger moves list-marked "hidden" icons to the LEFT of so the chevron
    /// collapses them off-screen. nil only if it hasn't laid out yet.
    func hiddenAnchorWindowID() -> CGWindowID? {
        guard let x = hiddenSeparator?.button?.window?.frame.minX else { return nil }
        return MenuBarBridge.windowID(forItemMinX: x)
    }

    /// CGS window id of the chevron (the always-visible click target). The arranger
    /// re-seats it on the VISIBLE side of the hidden separator after an order pass so
    /// expanding the separator can never push the click target off-screen. nil only if
    /// it hasn't laid out yet.
    func chevronAnchorWindowID() -> CGWindowID? {
        guard let x = chevron?.button?.window?.frame.minX else { return nil }
        return MenuBarBridge.windowID(forItemMinX: x)
    }

    var hasAlwaysHiddenBand: Bool { alwaysHiddenSeparator != nil }

    /// Create (or remove) the always-hidden separator WITHOUT tearing down the
    /// chevron/hidden separator. `reconcileDividers()` did a full teardown+setup,
    /// which reflowed the bar and lost the positional relationship of the regular
    /// hidden section — so toggling an always-hidden mark made every hidden icon pop
    /// back on-screen. This touches only the one band's status item.
    func ensureAlwaysHiddenBand(_ needed: Bool) {
        guard menubarExtLive && MenuBarBridge.available, chevron != nil else { return }
        if needed, alwaysHiddenSeparator == nil {
            let s = makeSeparator(autosave: "ProsperMenuBarAlwaysHiddenSeparator")
            ProsperStatusItems.register(s)
            alwaysHiddenSeparator = s
            applyDividerLengths()
            publishOwnWindowIDs()
        } else if !needed, let s = alwaysHiddenSeparator {
            NSStatusBar.system.removeStatusItem(s)
            alwaysHiddenSeparator = nil
            applyDividerLengths()
            publishOwnWindowIDs()
        }
    }

    /// Reveal BOTH bands (collapse both separators) so every item — including the
    /// always-hidden ones — is on-screen, run `body` while they have real on-screen
    /// frames/pixels to capture or perceptually hash, then restore the steady hidden
    /// state. Used by Save-order (distinct hashes for off-screen items) and the
    /// preview Refresh (real icons for hidden items).
    func withAllRevealed<T>(_ body: () async -> T) async -> T {
        isPlacing = true
        defer { isPlacing = false }
        beginPlacement()
        try? await Task.sleep(for: .milliseconds(180))
        let result = await body()
        endPlacement()
        return result
    }

    /// True while a `withAllRevealed` placement is toggling the separators. The order
    /// self-probe waits this out: a synthetic ⌘-drag of throwaway items while the bar's
    /// geometry is mid-collapse/restore (e.g. the Settings preview refresh, which fires
    /// concurrently) reads stale frames and spuriously reports `.moveFailed`.
    private(set) var isPlacing = false

    /// Collapse both separators so every item is on-screen — the arranger needs a
    /// valid (on-screen) drop point to move an icon into/out of the always-hidden
    /// band. No rehide timer or monitors; the caller pairs this with `endPlacement()`.
    func beginPlacement() {
        hiddenSeparator?.length = Lengths.standard
        alwaysHiddenSeparator?.length = Lengths.standard
    }

    /// Restore the steady hidden state (both separators expanded) after a placement.
    func endPlacement() {
        revealed = false
        revealedAlwaysHidden = false
        applyDividerLengths()
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
