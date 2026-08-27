// Owns the System Stats menu-bar presence end to end: one NSStatusItem per
// enabled module (each with its own autosave name so macOS persists its menu-bar
// position independently — the Tahoe MenuBarOrdering caveat), the StatsPoller
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
        self.poller?.setPopupActive(self.popover.isShown)
        self.updateOutsideClickMonitor()
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
    /// Global left-mouse monitor that dismisses the popover on a click outside it.
    /// `.transient` covers clicks that activate another app, but as an accessory
    /// (LSUIElement) app we don't reliably receive the dismissing event for clicks on
    /// the desktop / a non-activating spot — so a global monitor closes it explicitly.
    /// Global monitors only fire for events delivered to OTHER apps, so a click INSIDE
    /// the popover (our own window) never triggers it.
    private var outsideClickMonitor: Any?
    /// Process-lifetime observer token. The controller is a `static let` singleton
    /// meant to live forever, so this is intentionally never removed.
    private var configObserver: NSObjectProtocol?

    private init() {
        // Block API with `queue: .main` guarantees `reload()` runs on the main
        // thread (it mutates NSStatusBar + a @Published store), regardless of which
        // thread posted the notification.
        configObserver = NotificationCenter.default.addObserver(
            forName: .systemStatsConfigChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
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
        for m in modules where items[m] == nil {
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
            button.target = self
            button.action = #selector(itemClicked(_:))
            buttonModule[ObjectIdentifier(button)] = m
            items[m] = (item, host)
        }
        resizeItems()
    }

    /// Width-probe memo: item width only moves when its width-driving TEXT moves
    /// (non-network widgets reserve a fixed hidden width-sample; network's two rate
    /// strings vary), or when the style/theme scale changes. Without this, every
    /// status item paid a forced `layoutSubtreeIfNeeded` every tick forever.
    private var lastWidthKeys: [StatsModule: String] = [:]
    private var lastWidthStyle: StatsWidgetStyle?
    private var lastWidthScale: CGFloat = 0

    /// Sync each item's width to its content. Only writes when it actually changed
    /// — every length write relayouts the whole menu bar.
    private func resizeItems() {
        if lastWidthStyle != store.style || lastWidthScale != ThemeRuntime.scale {
            lastWidthKeys = [:]                    // style/scale change → re-probe all once
            lastWidthStyle = store.style
            lastWidthScale = ThemeRuntime.scale
        }
        for (m, pair) in items {
            let key: String
            if m == .network {
                let n = store.snapshot.network
                key = StatsFormat.rateMenu(n?.uploadBytesPerSec ?? 0)
                    + StatsFormat.rateMenu(n?.downloadBytesPerSec ?? 0)
            } else {
                key = m.primaryText(store.snapshot, showUnit: store.style.config(m).showUnit)
            }
            guard lastWidthKeys[m] != key else { continue }
            lastWidthKeys[m] = key
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
        if popover.isShown, openModule == m { popover.performClose(sender); return }
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

    /// Arm the monitor while the popover is shown, drop it when closed (no idle
    /// event tap when nothing is open).
    private func updateOutsideClickMonitor() {
        if popover.isShown {
            guard outsideClickMonitor == nil else { return }
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.popover.performClose(nil)
            }
        } else if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
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
