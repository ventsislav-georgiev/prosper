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
        p.delegate = popoverDelegate
        return p
    }()
    private lazy var popoverDelegate = PopoverDelegate { [weak self] open in
        // The all-pid scan only runs while the popover is open.
        self?.poller?.setProcSampling(open)
    }
    private var openModule: StatsModule?

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .systemStatsConfigChanged, object: nil)
    }

    /// Bring the feature to match current prefs/style. Idempotent — safe to call
    /// on launch and on every config change.
    @objc func reload() {
        store.style = SystemStatsStore.load()
        guard Preferences.systemStatsEnabled else { teardown(); return }

        let modules = store.style.enabledModules
        guard !modules.isEmpty else { teardown(); return }

        startPoller(for: Set(modules))
        syncItems(modules)
    }

    // MARK: - Poller

    private func startPoller(for modules: Set<StatsModule>) {
        // Re-create only when the enabled set changed (avoids churn on a pure
        // colour/label tweak).
        if let p = poller, p.enabledSet == modules { return }
        poller?.stop()
        let p = StatsPoller(modules: modules)
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

    private func syncItems(_ modules: [StatsModule]) {
        let wanted = Set(modules)
        // Remove items for modules no longer shown.
        for (m, pair) in items where !wanted.contains(m) {
            NSStatusBar.system.removeStatusItem(pair.item)
            buttonModule[ObjectIdentifier(pair.item.button!)] = nil
            items[m] = nil
        }
        // Add items for newly shown modules.
        for m in modules where items[m] == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "ProsperStats-\(m.rawValue)"
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

    /// Sync each item's width to its content. Only writes when it actually changed
    /// — every length write relayouts the whole menu bar.
    private func resizeItems() {
        for (_, pair) in items {
            pair.host.layoutSubtreeIfNeeded()
            let w = pair.host.fittingSize.width
            if w > 0, abs(pair.item.length - w) > 0.5 { pair.item.length = w }
        }
    }

    @objc private func itemClicked(_ sender: NSStatusBarButton) {
        guard let m = buttonModule[ObjectIdentifier(sender)] else { return }
        if popover.isShown, openModule == m { popover.performClose(sender); return }
        openModule = m
        popover.contentViewController = NSHostingController(rootView: StatsPopupView(module: m, store: store))
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
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
    let onChange: (Bool) -> Void
    init(_ onChange: @escaping (Bool) -> Void) { self.onChange = onChange }
    func popoverDidShow(_ n: Notification) { onChange(true) }
    func popoverDidClose(_ n: Notification) { onChange(false) }
}
