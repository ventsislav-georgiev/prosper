import AppKit
import CoreGraphics
import IOKit.ps

// Live + on-demand enforcement loop for the ordering engine (Phase 4). Owns the
// runtime decision of WHEN to re-apply the saved order, gated by:
//   • the self-probe (never act on a Mac where moving doesn't work),
//   • `MenuBarEnforcementPolicy` (min interval, longer on battery, circuit breaker),
//   • a capture-free drift check (only pay for a synthetic ⌘-drag when order is
//     actually wrong).
//
// On-demand mode applies once when the bar is revealed. Live mode additionally
// polls for drift on a gentle timer and corrects it. Inert until enabled +
// probe-passed; tearing down on disable.

@MainActor
final class MenuBarOrderEnforcer {
    static let shared = MenuBarOrderEnforcer()
    private init() {}

    /// Live poll interval. Drift checks here are cheap (enumerate + cached hashes,
    /// no capture); the expensive apply only fires when the policy AND a real drift
    /// agree. Apply frequency is bounded by the policy cooldown, not this.
    private static let livePollInterval: TimeInterval = 2.0

    private var store = MenuBarOrderStore.default
    private var probeOK = false
    private var policy = MenuBarEnforcementPolicy()
    private var timer: Timer?
    /// True while the live drift timer is armed. Test seam: lets coverage assert the
    /// enforcer disarms when the extension is disabled (no orphan timer driving a
    /// torn-down bar) without exposing the timer itself.
    var isLiveRunning: Bool { timer != nil }
    private var working = false   // re-entrancy guard: one apply pass at a time
    /// Cheap windowID-order fingerprint from the last full drift check. While the
    /// live bar's foreign-item order is byte-identical to this, the order can't have
    /// drifted, so the 2s tick skips the expensive identity rebuild + system window
    /// enumeration. Reset to nil on any settings change (the desired order may now
    /// differ even though the live order is static).
    private var lastOrderFingerprint: [CGWindowID]?
    /// Baseline of menu-bar windowIDs for the "keep new icons visible" feature. nil
    /// until the first tick seeds it (so the user's EXISTING hidden icons are never
    /// mistaken for newcomers). A windowID present now but absent here = freshly
    /// launched → revealed if macOS buried it. Reset to nil on settings change so the
    /// baseline re-seeds rather than treating the post-change bar as new.
    private var knownWindowIDs: Set<CGWindowID>?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Reconfigure from settings. Call on enable/disable, mode change, probe result,
    /// and when the saved order changes. Starts/stops the live timer to match.
    func update(store: MenuBarOrderStore, probeOK: Bool) {
        self.store = store
        self.probeOK = probeOK
        lastOrderFingerprint = nil   // settings changed → re-check on next tick
        knownWindowIDs = nil         // re-seed; don't treat the current bar as newcomers
        // The timer drives BOTH the live order enforcer (live mode + a saved order) and
        // the "keep new icons visible" watcher (any mode). Arm if either wants it.
        let wantsLiveOrder = store.mode == .live && !store.desiredOrder.isEmpty
        let shouldRunLive = store.enabled && probeOK && (wantsLiveOrder || store.revealNewItems)
        shouldRunLive ? startLive() : stopLive()
    }

    /// On-demand hook: the bar was revealed. Apply once (drift-gated, throttled).
    func onReveal() {
        guard store.enabled, probeOK, store.mode == .onDemand, !store.desiredOrder.isEmpty else { return }
        enforceIfDrifted()
    }

    // MARK: - Live timer

    private func startLive() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.livePollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common so it keeps firing during menu tracking / scrolling.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopLive() {
        timer?.invalidate()
        timer = nil
    }

    /// One timer tick: keep new icons visible (any mode), then enforce order drift
    /// (live mode only — on-demand applies on reveal, not on a timer).
    private func tick() {
        revealNewItemsIfNeeded()
        if store.mode == .live { enforceIfDrifted() }
    }

    // MARK: - Keep new icons visible

    /// Move icons that newly appeared in the hidden band out to visible. "New" =
    /// windowID absent from the last-seen baseline (identity-free → Tahoe-robust).
    /// Attempt-once: the baseline adopts the current ids immediately, so a stuck item
    /// isn't re-dragged every tick (the membership pre-gate also skips quiet ticks).
    private func revealNewItemsIfNeeded() {
        guard store.revealNewItems, probeOK, store.enabled,
              !working, !MenuBarArranger.isApplying, MenuBarBridge.available else { return }
        let cur = Set(MenuBarArranger.currentItems().map(\.windowID))
        guard let known = knownWindowIDs else { knownWindowIDs = cur; return }  // seed, reveal nothing
        if cur == known { return }                 // membership unchanged → nothing launched/quit
        knownWindowIDs = cur                        // adopt now (attempt-once)
        let newcomers = cur.subtracting(known)
        guard !newcomers.isEmpty else { return }    // only items LEFT the bar → nothing to reveal
        working = true
        Task {
            await MenuBarArranger.revealNewItems(newcomerWindowIDs: newcomers)
            working = false
        }
    }

    // MARK: - Drift → apply

    /// Cheap drift check, then a throttled apply if (and only if) the order is wrong.
    private func enforceIfDrifted() {
        guard !working, !MenuBarArranger.isApplying,
              probeOK, store.enabled, !store.desiredOrder.isEmpty else { return }
        // The move pipeline can degrade mid-session (CGS bridge down). Stop rather
        // than feed the breaker forever.
        guard MenuBarBridge.available else { stopLive(); return }
        let n = now
        if !policy.canApply(now: n, onBattery: Self.onBattery()) { return }

        // Cheap pre-gate: the foreign-item windowID order, read via CGS only (no
        // system-wide CGWindowListCopyWindowInfo). Identical to the last full check ⇒
        // no POSITIONAL or MEMBERSHIP drift (no reorder, relaunch, quit, or launch) ⇒
        // skip the expensive identity rebuild below, keeping the 2s main-thread tick
        // off the heavy window-enumeration path in steady state (typing-latency
        // sensitive). The one drift it can't see — an item becoming resolvable in
        // place after a re-index — is covered by clearing the fingerprint after every
        // apply (see below). Main-display only, matching `desiredOrder` capture and
        // `currentItems`; secondary-display items aren't managed.
        let order = MenuBarBridge.menuBarWindowOrder(onDisplay: CGMainDisplayID())
        if lastOrderFingerprint == order { return }   // bar unchanged (incl. empty) → skip
        lastOrderFingerprint = order

        // Capture-free drift signal: build live keys from titles + the last index's
        // cached hashes. Items we can't yet identify are excluded from the order check.
        let hashes = MenuBarArranger.lastIndexedHashes
        let cur = MenuBarArranger.currentItems()
        let curKeys = cur.map { MenuBarArranger.identity(for: $0, hash: hashes[$0.windowID]).key }
        let curKeySet = Set(curKeys)
        let liveBundles = Set(cur.map { $0.bundleID ?? "unknown" })
        let resolvedDesired = store.desiredOrder.filter { $0.isResolved }
        let desiredKeys = resolvedDesired.map { $0.key }

        let orderWrong = !MenuBarOrderDiff.isRelativeOrderSatisfied(current: curKeys, desired: desiredKeys)
        // Stale-cache case (the multi-icon raison d'être): a relaunched app gets a
        // fresh windowID absent from the hash cache, so its desired hash-key can't be
        // confirmed live even though the app IS present. Treat that as drift so the
        // apply pass re-indexes (fresh capture) and the fuzzy matcher can re-place it.
        let needsReindex = resolvedDesired.contains {
            $0.imageHash != nil && liveBundles.contains($0.bundleID) && !curKeySet.contains($0.key)
        }
        guard orderWrong || needsReindex else { return }

        working = true
        let desired = store.desiredOrder
        let mode = store.mode
        Task {
            // Live mode never force-reveals — only reorders on-screen items (Stats are
            // visible; that's the use case). On-demand reveals via onReveal/Apply.
            let result = await MenuBarArranger.apply(desired: desired, reveal: mode != .live)
            let actionable = result.moved > 0 || result.failed > 0
            // Stamp the cooldown from the pass START (`n`), not `self.now` after the
            // await — apply() can run hundreds of ms (reveal + capture + drags) and
            // re-reading the clock here would stretch the cadence past the intended
            // baseCooldown.
            //
            // Breaker policy: an actionable pass feeds it normally. A no-op pass
            // (drift detected but nothing placeable — e.g. a relaunched item whose
            // fresh hash drifted past tolerance) must NOT call recordSuccess (that
            // would reset failures every tick and disarm runaway protection). In LIVE
            // mode the 2s timer would otherwise reveal+capture forever, so count the
            // wasted pass as a failure → the breaker eventually trips and parks it.
            // In on-demand mode there's no timer (each pass is an explicit reveal), so
            // just throttle without punishing the user's deliberate action.
            if actionable {
                policy.recordApply(now: n, success: result.failed == 0)
            } else if mode == .live {
                policy.recordApply(now: n, success: false)
            } else {
                policy.stampThrottleOnly(now: n)
            }
            // Invalidate the fingerprint: apply() re-ran the indexer (refreshing
            // `lastIndexedHashes`), which can make a previously-unresolvable item
            // resolvable WITHOUT changing the windowID order — invisible to the
            // order-only pre-gate. Forcing one full check next tick re-evaluates
            // identity. Costs nothing extra on the happy path (a real move already
            // changed the order, so the next tick wouldn't have skipped anyway).
            lastOrderFingerprint = nil
            working = false
        }
    }

    /// True when running on battery (gentler cadence). Fail-open to AC on error.
    private static func onBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }
}
