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

    /// Expanded divider width. Windows model (≤ macOS 26): wide enough to push everything
    /// left of it past the screen's left edge, derived from the live primary-display
    /// width (not a fixed 10 000) so it stays correct on ultrawide / Retina-scaled
    /// displays. Hosted model (macOS 27+): just under the room the host lays items out
    /// in, which makes it drop the divider and everything left of it (`MenuBarLogic.dropLength`).
    private var expandedLength: CGFloat {
        if MenuBarHost.isHosted {
            return MenuBarLogic.dropLength(room: MenuBarAX.roomWidth(on: hiddenSeparator?.button?.window?.screen))
        }
        return (NSScreen.main?.frame.width ?? 2000) + 200
    }

    /// The always-visible control item (rightmost of ours). Clicking it toggles the
    /// hidden section. It NEVER expands —
    /// that's the whole fix: a single divider that did double duty as chevron AND
    /// expander rode itself (and Prosper's own icon) off-screen when it expanded, so
    /// nothing was clickable. Splitting the control from the expander (the Ice /
    /// Bartender model) keeps the chevron on screen at all times.
    private var chevron: NSStatusItem?
    /// Empty expanding separator. Sits to the LEFT of the chevron; growing its
    /// `length` pushes every item left of it (the hidden section) off the screen edge.
    private var hiddenSeparator: NSStatusItem?
    /// Transient: is the hidden section currently revealed (separators collapsed)?
    private var revealed = false
    private var rehideTimer: Timer?

    /// Set by AppDelegate from the registry (boot + onEnabledChanged). Defaults
    /// true so a reconcile before the registry wires up doesn't suppress setup.
    var menubarExtLive = true

    var isActive: Bool { chevron != nil }

    // MARK: - Lifecycle

    /// Idempotent. Builds the dividers when the feature is live, tears them down
    /// otherwise. Hiding/spacing need NO Accessibility on a windowed menu bar
    /// (CGS only); a hosted bar (macOS 27+) is measured through AX, so `setup()`
    /// asks there.
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

    private func setup() {
        guard chevron == nil else { return }
        // Apply persisted spacing (no relaunch — takes effect as apps launch).
        MenuBarSpacing.apply(spacing: Preferences.menuBarStore.clampedSpacing)

        // Order matters: the FIRST-created status item is rightmost, later ones appear
        // to its left. We want screen order (left→right):
        //   [hiddenSeparator] [hidden items] [chevron] [visible items]
        // so the chevron (created first) stays right of the expander and is never
        // pushed off-screen when it grows.
        chevron = makeChevron()
        hiddenSeparator = makeSeparator(autosave: "ProsperMenuBarHiddenSeparator", id: "hidden")
        for item in [chevron, hiddenSeparator].compactMap({ $0 }) {
            ProsperStatusItems.register(item)
        }

        // Start in the hidden state (separators expanded). A crash can't strand
        // third-party icons off-screen: our status items die with the process, so
        // the OS reflows the menu bar automatically — no persistent off-screen push.
        revealed = false
        // Hosted bars are measured through Accessibility (no CGS windows to read), so
        // hiding itself needs the grant there — ask once when the feature comes up.
        if MenuBarHost.isHosted { PermissionsManager.ensureAccessibilityTrust(prompt: true) }
        applyDividerLengths()
        observeTermination()
        observeScreenChanges()
    }

    private func teardown() {
        rehideTimer?.invalidate(); rehideTimer = nil
        for item in [chevron, hiddenSeparator].compactMap({ $0 }) {
            NSStatusBar.system.removeStatusItem(item)
        }
        chevron = nil
        hiddenSeparator = nil
        revealed = false
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
            button.setAccessibilityIdentifier(MenuBarAX.identifierPrefix + "chevron")
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
    private func makeSeparator(autosave: String, id: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: Lengths.standard)
        item.autosaveName = autosave
        if let button = item.button {
            button.setAccessibilityIdentifier(MenuBarAX.identifierPrefix + id)   // how the hosted fit finds it
            button.attributedTitle = NSAttributedString(
                string: "￨", attributes: [.foregroundColor: NSColor.tertiaryLabelColor])
            // Not interactive: clicks fall through to do nothing rather than toggle.
            button.target = nil
            button.action = nil
        }
        return item
    }

    // MARK: - Show / hide (the hot path)

    /// Collapse/expand dividers to match `revealed`. A single length assignment per
    /// divider — visually instant, no enumeration.
    /// Single source of truth for the divider width. Every length change routes
    /// through here (derived from `revealed`) — no inline `length =` pokes elsewhere.
    private func applyDividerLengths() {
        defer { updateChevron() }
        let l = MenuBarLogic.dividerLengths(revealed: revealed, revealedAlwaysHidden: false,
                                            standard: Lengths.standard, expanded: expandedLength)
        hiddenSeparator?.length = l.hidden
    }

    /// Chevron click handler — toggles the hidden section.
    @objc private func chevronClicked() { toggleHidden() }

    @objc func toggleHidden() {
        guard chevron != nil else { return }
        if isActiveSpaceFullscreen { return }   // menu bar is auto-hidden anyway
        setRevealed(!revealed)
    }

    func setRevealed(_ value: Bool) {
        revealed = value
        applyDividerLengths()
        if revealed {
            scheduleRehide()
        } else {
            rehideTimer?.invalidate(); rehideTimer = nil
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

    /// Re-derive the rehide timer after the auto-rehide setting changes WHILE the
    /// section is revealed — turning it off must cancel the pending collapse
    /// (scheduleRehide self-gates on the store flag).
    func refreshRevealBehavior() {
        guard revealed else { return }
        scheduleRehide()
    }

    // MARK: - Auto-rehide

    private func scheduleRehide() {
        rehideTimer?.invalidate()
        // Auto-rehide off: the section stays revealed until the user collapses it
        // (chevron click / shortcut). No timer to arm.
        guard Preferences.menuBarStore.autoRehideEnabled else { rehideTimer = nil; return }
        let secs = TimeInterval(Preferences.menuBarStore.clampedAutoRehide)
        rehideTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.setRevealed(false) }
        }
    }

    private func dividerFrameX(_ item: NSStatusItem?) -> CGFloat? {
        item?.button?.window?.frame.minX
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
            MainActor.assumeIsolated {
                MenuBarManager.shared.applyDividerLengths()
            }
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
