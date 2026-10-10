// Owns the System Stats menu-bar presence end to end: one NSStatusItem per
// enabled module (each with its own autosave name so macOS persists its menu-bar
// position independently — the Tahoe menu-bar identity caveat), the StatsPoller
// that feeds them, and the shared popover. Disabled by default; `reload()` brings
// the whole feature up or tears it fully down off a single pref + style read.

import AppKit
import SwiftUI
import StatsCore

extension Notification.Name {
    /// Posted by the settings pane when the enable flag or widget style changes.
    static let systemStatsConfigChanged = Notification.Name("systemStatsConfigChanged")
}

@MainActor
final class StatsController {
    static let shared = StatsController()

    private var store = StatsStore(style: SystemStatsStore.load())
    private var poller: StatsPoller?
    private var items: [StatsModule: (item: NSStatusItem, host: NSHostingView<StatsMenuWidget>)] = [:]
    private var buttonModule: [ObjectIdentifier: StatsModule] = [:]
    private lazy var popover: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = false   // instant show/hide; the default tween read as a ~0.2s lag on switch
        p.delegate = popoverDelegate
        return p
    }()
    private lazy var popoverDelegate = PopoverDelegate { [weak self] in
        // Reconcile against actual visibility, not the firing event: clicking item
        // B while A is open fires didClose(A)+didShow(B) in an unguaranteed order, so
        // a literal true/false could leave sampling off with a popover still shown.
        guard let self else { return }
        // #217: an open popover proves the user is looking, so a pause left by a
        // missed wake/unlock notification is stale — clear it before the popup
        // toggle (which no-ops on a paused poller).
        self.screen.reconcile(popoverShown: self.popover.isShown); self.applyPause()
        self.poller?.setPopupActive(self.popover.isShown)
        self.updateOutsideClickMonitor()
        // #197: we closed → end the open item's session (not B's, mid A → B switch).
        if !self.popover.isShown, let m = self.openModule, let item = self.items[m]?.item {
            self.expanded.cancelSessions(only: item)
        }
        // Drop the hosting controller once truly closed so the SwiftUI view
        // deallocs — otherwise its per-tick subscriptions (charts, the sensor
        // fan read) keep firing against a hidden popover. Deferred + re-guarded
        // on isShown to survive the didClose(A)+didShow(B) switch race above.
        if !self.popover.isShown {
            DispatchQueue.main.async {
                if !self.popover.isShown { self.popover.contentViewController = nil }
            }
        }
    }
    private var openModule: StatsModule?
    /// #149: closes the popover on a click on another app's window — `.transient`
    /// misses desktop / non-activating clicks for an accessory app; the shared
    /// dismisser decides by the owner of the window under the click.
    private lazy var outsideClick = PopoverOutsideClickDismisser(
        popover: popover, systemOwnedFrames: { [weak self] in self?.expanded.itemFrames ?? [] })
    /// #197: macOS 27 opens/closes through each item's session. Switching A → B
    /// may begin B before ending A, so didEnd only hides A's own popover.
    private lazy var expanded = ExpandedInterfaceBridge(
        begin: { [weak self] item in if let b = item.button { self?.toggle(b) } },
        end: { [weak self] item in
            guard let self, let b = item.button,
                  ExpandedInterfacePolicy.hidesOnEnd(
                    pinned: false,
                    showingThisItem: popover.isShown && openModule == buttonModule[ObjectIdentifier(b)])
            else { return }
            popover.performClose(nil)
        })
    /// Process-lifetime observer token. The controller is a `static let` singleton
    /// meant to live forever, so this is intentionally never removed.
    private var configObserver: NSObjectProtocol?
    /// #186: display asleep or screen locked → nobody can see the widgets, so the
    /// poller (tick timer + ping thread) pauses until both clear. Same lifetime
    /// rule as `configObserver`: never removed.
    private var sleepObservers: [NSObjectProtocol] = []
    private var screen = ScreenGate()
    private var screenHidden: Bool { screen.hidden }

    private init() {
        // Block API with `queue: .main` guarantees `reload()` runs on the main
        // thread (it mutates NSStatusBar + a @Published store), regardless of which
        // thread posted the notification.
        configObserver = NotificationCenter.default.addObserver(
            forName: .systemStatsConfigChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        // Screen lock exists only as a distributed notification (same pair
        // ExtensionSystemServices listens to); display sleep/wake is NSWorkspace's.
        for (name, event) in ScreenGate.notifications {
            let center = ScreenGate.center(for: event) == .distributed
                ? DistributedNotificationCenter.default() : NSWorkspace.shared.notificationCenter
            sleepObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screen.apply(event); self?.applyPause() }
            })
        }
    }

    /// Pause while the screen is hidden; resuming polls at once so the widgets are
    /// fresh on wake (histories keep a gap for the hidden period).
    private func applyPause() {
        poller?.setPaused(screenHidden)
    }

    /// Bring the feature to match current prefs/style. Idempotent — safe to call
    /// on launch and on every config change.
    func reload() {
        store.style = SystemStatsStore.load()
        guard Preferences.systemStatsEnabled else { teardown(); return }

        let modules = store.style.enabledModules
        guard !modules.isEmpty else { teardown(); return }

        startPoller(for: Set(modules))
        syncItems(modules)
    }

    // MARK: - Poller

    private var pollerInterval: TimeInterval = 0
    private var pollerSensorsInterval: TimeInterval = 0

    private func startPoller(for modules: Set<StatsModule>) {
        let interval = Preferences.statsRefreshInterval
        let sensorsInterval = Preferences.statsSensorsInterval
        // Re-create only when the enabled set OR a sampling period changed (avoids
        // churn on a pure colour/label tweak).
        if let p = poller, p.enabledSet == modules, pollerInterval == interval,
           pollerSensorsInterval == sensorsInterval { return }
        poller?.stop()
        var cfg = StatsPoller.Config()
        cfg.baseInterval = interval
        // Divider grid: temps/power fire every Nth tick, nearest to the requested
        // period, never faster than the base interval.
        cfg.slowDivider = max(1, Int((sensorsInterval / interval).rounded()))
        pollerInterval = interval
        pollerSensorsInterval = sensorsInterval
        let p = StatsPoller(modules: modules, config: cfg)
        p.onSnapshot = { [weak self] snap in
            // The poller delivers on the main queue (its default deliverQueue), so
            // assert the isolation rather than pay a Task hop (which would also let
            // snapshots reorder). Touches UI/store directly.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.snapshot = snap
                self.resizeItems()
            }
        }
        p.start()
        p.setPaused(screenHidden)   // config change while the screen is off
        poller = p
    }

    // MARK: - Status items

    /// Human label for the menu-bar manager's order/preview lists.
    private static func moduleName(_ m: StatsModule) -> String {
        switch m {
        case .cpu: "CPU"; case .memory: "RAM"; case .disk: "Disk"
        case .network: "Network"; case .gpu: "GPU"
        case .power: "Power"; case .sensors: "Sensors"; case .battery: "Battery"
        }
    }

    private func syncItems(_ modules: [StatsModule]) {
        let wanted = Set(modules)
        // Remove items for modules no longer shown.
        for (m, pair) in items where !wanted.contains(m) {
            NSStatusBar.system.removeStatusItem(pair.item)
            if let b = pair.item.button { buttonModule[ObjectIdentifier(b)] = nil }
            items[m] = nil
        }
        // Add items for newly shown modules.
        for m in widthGate.admit(modules, live: items.keys) {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "ProsperStats-\(m.rawValue)"
            // .content (not .control): Stats icons stay in the managed set so the user
            // can order/preview them — the whole point of multi-icon ordering.
            ProsperStatusItems.register(item, role: .content, name: Self.moduleName(m))
            guard let button = item.button else { continue }
            let host = NSHostingView(rootView: StatsMenuWidget(module: m, store: store))
            host.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                host.topAnchor.constraint(equalTo: button.topAnchor),
                host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            if !expanded.install(on: item) {
                button.target = self
                button.action = #selector(itemClicked(_:))
            }
            buttonModule[ObjectIdentifier(button)] = m
            items[m] = (item, host)
        }
        resizeItems()
    }

    /// Width-probe memo (#189: keyed on what moves the width, not on the value).
    /// Without it every status item paid a forced `layoutSubtreeIfNeeded` +
    /// `fittingSize` every tick forever.
    private var widthGate = StatsWidthGate()

    /// Sync each item's width to its content. Only writes when it actually changed
    /// — every length write relayouts the whole menu bar.
    private func resizeItems() {
        for (m, pair) in items {
            let key = StatsWidthGate.key(m, store.snapshot, showUnit: store.style.config(m).showUnit)
            guard widthGate.needsResize(m, key: key, style: store.style, scale: ThemeRuntime.scale)
            else { continue }
            // Resolve any pending SwiftUI invalidation so fittingSize reflects the
            // string just published (else the item lags a tick when a digit-count
            // boundary changes the width). The cost that matters — the `length`
            // write that relayouts the whole menu bar — stays guarded below.
            pair.host.layoutSubtreeIfNeeded()
            let w = pair.host.fittingSize.width
            if w > 0, abs(pair.item.length - w) > 0.5 { pair.item.length = w }
        }
    }

    @objc private func itemClicked(_ sender: NSStatusBarButton) {
        guard let m = buttonModule[ObjectIdentifier(sender)] else { return }
        // #149: the outside-click monitor already closed us on this very click
        // (the menu bar is WindowServer's, not ours) — clicking the open module's
        // icon means "close", so don't reopen. A different module's icon still opens.
        if Self.skipsReopen(dismissedByClick: outsideClick.dismissed(by: NSApp.currentEvent),
                            open: openModule, clicked: m) { return }
        toggle(sender)
    }

    /// The click's toggle — target/action below 27, the session's didBegin on 27.
    private func toggle(_ sender: NSStatusBarButton) {
        guard let m = buttonModule[ObjectIdentifier(sender)] else { return }
        if popover.isShown, openModule == m { popover.performClose(sender); return }
        // #195: click → popover transaction committed.
        let signpost = Perf.signposter.beginInterval("popover.show", id: Perf.signposter.makeSignpostID(), "stats")
        CATransaction.setCompletionBlock { Perf.signposter.endInterval("popover.show", signpost) }
        openModule = m
        let host = NSHostingController(rootView: StatsPopupView(module: m, store: store))
        // Let the popover learn the view's real size BEFORE it positions itself.
        // Without this the hosting controller reports a zero content size on first
        // show, so AppKit anchors a 0×0 popover and then it grows — landing it
        // offscreen above the bar or with a stray gap below. `.preferredContentSize`
        // sizes the popover to the SwiftUI content up front so .minY (below the
        // menu-bar item) lands flush every time.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        // Accessory-app popover: without key status the first click inside only
        // activates the window and SwiftUI never sees it — the process row's
        // `.onTapGesture` needs a key window to recognize a first click, so it
        // silently swallows one and the second click (now key) succeeds. Same
        // fix as CalendarBarController's day-picker popover: make it key on open.
        host.view.window?.makeKey()
    }

    /// Pure: skip the reopen only when the monitor closed on this click AND it was
    /// the open module's own icon. Takes the Bool so `dismissed(by:)` always runs
    /// (it consumes the stamp).
    nonisolated static func skipsReopen(dismissedByClick: Bool, open: StatsModule?,
                                        clicked: StatsModule) -> Bool {
        dismissedByClick && open == clicked
    }

    /// Arm the monitor while the popover is shown, drop it when closed (no idle
    /// event tap when nothing is open).
    private func updateOutsideClickMonitor() {
        outsideClick.setArmed(popover.isShown)
    }

    private func teardown() {
        poller?.stop(); poller = nil
        for (_, pair) in items { NSStatusBar.system.removeStatusItem(pair.item) }
        items.removeAll(); buttonModule.removeAll()
        if popover.isShown { popover.performClose(nil) }
    }
}

/// Bridges NSPopover open/close to the proc-sampling toggle without the
/// controller having to conform to the delegate protocol itself.
private final class PopoverDelegate: NSObject, NSPopoverDelegate {
    let reconcile: () -> Void
    init(_ reconcile: @escaping () -> Void) { self.reconcile = reconcile }
    func popoverDidShow(_ n: Notification) { reconcile() }
    func popoverDidClose(_ n: Notification) { reconcile() }
}

/// #189: decides which stats status items need a width re-measure on a tick.
struct StatsWidthGate {
    private var keys: [StatsModule: String] = [:]
    private var style: StatsWidgetStyle?
    private var scale: CGFloat = 0

    /// What a widget's width depends on besides style/scale. Non-network widgets
    /// reserve `primaryWidthSample()` (monospaced digits), so a value no longer than
    /// the sample cannot move the width; only one that overflows it (power ≥ 100 W)
    /// keys on its text. Network has no sample: its width follows the rate strings.
    static func key(_ m: StatsModule, _ snap: StatsSnapshot, showUnit: Bool) -> String {
        if m == .network {
            let n = snap.network
            return StatsFormat.rateMenu(n?.uploadBytesPerSec ?? 0)
                + StatsFormat.rateMenu(n?.downloadBytesPerSec ?? 0)
        }
        let text = m.primaryText(snap, showUnit: showUnit)
        return text.count > m.primaryWidthSample().count ? text : ""
    }

    /// True when `m` must be measured: its key moved, it is new/forgotten, or the
    /// style or theme scale changed (which re-probes every module once).
    mutating func needsResize(_ m: StatsModule, key: String, style: StatsWidgetStyle, scale: CGFloat) -> Bool {
        if style != self.style || scale != self.scale {
            keys = [:]
            self.style = style
            self.scale = scale
        }
        guard keys[m] != key else { return false }
        keys[m] = key
        return true
    }

    mutating func forget(_ m: StatsModule) { keys[m] = nil }

    /// Modules in `wanted` with no live item, i.e. the items to (re-)create. Each is
    /// forgotten so a fresh item (re-enable after teardown) is measured once.
    /// #237: a module repeated in `wanted` (a persisted order can carry duplicates)
    /// is admitted once — its first occurrence — else syncItems would create two
    /// items and leak the first.
    mutating func admit(_ wanted: [StatsModule], live: some Collection<StatsModule>) -> [StatsModule] {
        var seen = Set(live)
        let fresh = wanted.filter { seen.insert($0).inserted }
        for m in fresh { forget(m) }
        return fresh
    }
}
