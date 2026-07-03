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
    /// A new icon merged at its placeholder but the apply pass hasn't run yet (mode
    /// guard or cooldown blocked it). Sticky across ticks — the bar is static after
    /// the merge, so the fingerprint gate alone would never re-trigger placement.
    private var pendingNewIconPlacement = false

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Reconfigure from settings. Call on enable/disable, mode change, probe result,
    /// and when the saved order changes. Starts/stops the poll timer to match.
    /// The timer runs in BOTH modes now: on-demand still never auto-applies, but the
    /// cheap tick is how manual ⌘-drags and new icons get auto-saved.
    func update(store: MenuBarOrderStore, probeOK: Bool) {
        self.store = store
        self.probeOK = probeOK
        lastOrderFingerprint = nil   // settings changed → re-check on next tick
        let shouldRun = store.enabled && probeOK && !store.desiredOrder.isEmpty
        shouldRun ? startLive() : stopLive()
    }

    /// On-demand hook: the bar was revealed. Apply once (drift-gated, throttled).
    func onReveal() {
        guard store.enabled, probeOK, store.mode == .onDemand, !store.desiredOrder.isEmpty else { return }
        enforceIfDrifted(userInitiated: true)
    }

    // MARK: - Live timer

    private func startLive() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.livePollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Let macOS coalesce the fire with other wakeups (battery).
        t.tolerance = Self.livePollInterval / 4
        // .common so it keeps firing during menu tracking / scrolling.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopLive() {
        timer?.invalidate()
        timer = nil
    }

    /// One timer tick: auto-save user changes (both modes), then enforce order
    /// drift (live mode only — on-demand applies on reveal, not on a timer).
    private func tick() {
        enforceIfDrifted()
    }

    /// True while the user is actively mousing (button held, or a move/drag/scroll
    /// within the last second). The tick defers entirely while this holds: a
    /// synthetic ⌘-drag pass parks/warps the REAL cursor, so running one mid-gesture
    /// visibly hijacks the pointer (and could eat a click on our own chevron). Our
    /// own synthetic events are leftMouseDown/Up only — they never touch the
    /// mouseMoved/dragged/scroll counters, so this can't self-trigger.
    /// Cheap: three counter reads + a button-state read, no event tap.
    nonisolated static func userMouseActive(within seconds: Double = 1.0) -> Bool {
        if CGEventSource.buttonState(.combinedSessionState, button: .left) { return true }
        // Modifier held (⌘-shortcut, ⌘-drag about to start): the mover refuses to
        // drag against held modifiers anyway (modifiersHeld error → breaker food), so
        // defer the whole tick instead of burning a doomed apply pass.
        if !CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty {
            return true
        }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .scrollWheel]
        return types.contains {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < seconds
        }
    }

    // MARK: - Drift → adopt or apply

    /// Cheap drift check, then: adopt user-made changes into the saved order
    /// (auto-save), or a throttled apply if (and only if) the order is wrong.
    /// `userInitiated` marks the on-demand reveal path: the user just clicked the
    /// chevron, so their own click/move must not defer the pass, and the apply runs
    /// regardless of mode.
    private func enforceIfDrifted(userInitiated: Bool = false) {
        guard !working, !MenuBarArranger.isApplying,
              probeOK, store.enabled, !store.desiredOrder.isEmpty else { return }
        // The move pipeline can degrade mid-session (CGS bridge down). Stop rather
        // than feed the breaker forever.
        guard MenuBarBridge.available else { stopLive(); return }
        // Display asleep (lid closed, idle sleep): the bar can't drift and nobody can
        // see it — skip the whole tick so an overnight Mac pays one syscall per 2s,
        // not CGS reads. One boolean_t read, no notification plumbing needed.
        if !userInitiated, CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return }
        // Never look at (or act on) the bar mid-gesture: a user ⌘-drag in flight
        // reads as a half-done permutation, and an apply pass would fight the mouse.
        // The fingerprint is left alone, so the change is classified on the first
        // quiet tick after the gesture ends.
        if !userInitiated, Self.userMouseActive() { return }

        // Cheap pre-gate: the foreign-item windowID order, read via CGS only (no
        // system-wide CGWindowListCopyWindowInfo). Identical to the last full check ⇒
        // no POSITIONAL or MEMBERSHIP drift (no reorder, relaunch, quit, or launch) ⇒
        // skip the expensive identity rebuild below, keeping the 2s main-thread tick
        // off the heavy window-enumeration path in steady state (typing-latency
        // sensitive). Main-display only, matching `desiredOrder` capture and
        // `currentItems`; secondary-display items aren't managed.
        let order = MenuBarBridge.menuBarWindowOrder(onDisplay: CGMainDisplayID())
        // Bar unchanged (incl. empty) → skip. A user-initiated reveal bypasses this:
        // the background tick stamps the fingerprint on every change WITHOUT applying
        // in on-demand mode, so "unchanged since last tick" does not mean "in order".
        if !userInitiated, lastOrderFingerprint == order { return }
        let previous = lastOrderFingerprint
        lastOrderFingerprint = order

        // Capture-free drift signal: build live keys from titles + the last index's
        // cached hashes. Items we can't yet identify are excluded from the order check.
        let hashes = MenuBarArranger.lastIndexedHashes
        let cur = MenuBarArranger.currentItems()
        let curIdentities = cur.map { MenuBarArranger.identity(for: $0, hash: hashes[$0.windowID]) }
        let curKeys = curIdentities.map(\.key)
        let curKeySet = Set(curKeys)
        let liveBundles = Set(cur.map { $0.bundleID ?? "unknown" })

        // Physical band per live item — an x-vs-separator comparison that works
        // COLLAPSED too: off-screen items keep enumerating (displayID(for:) falls
        // back to the main display for off-screen frames) with minX left of the
        // expanded separator, so hidden/visible membership reads correctly whether
        // the bar is revealed or not. nil until the separator lays out (then
        // "everything visible" would be a lie, not a signal). Shared by both
        // auto-save paths below.
        // Ceiling: with a second display arranged to the LEFT, off-screen frames
        // resolve to that display instead and drop from `cur`; those items are
        // then classified by their old side of the divider until the next reveal.
        let liveHidden: Set<String>? = MenuBarManager.shared.hiddenSeparatorLaidOut
            ? Set(MenuBarManager.shared.sectionedItems(cur)
                .filter { $0.section != .visible }
                .map { MenuBarArranger.identity(for: $0.item, hash: hashes[$0.item.windowID]).key })
            : nil

        // AUTO-SAVE, part 1 — user reorder: the same windowIDs in a different order
        // can only come from a user ⌘-drag (apps don't permute themselves, a relaunch
        // mints a new windowID, and our own apply resets the fingerprint to nil so
        // `previous` can't be a mid-apply frame). Adopt the live order into the saved
        // one and do NOT enforce — the user just told us what they want.
        if let previous, previous != order, Set(previous) == Set(order) {
            let adopted = MenuBarOrderDiff.adoptLiveOrder(desired: store.desiredOrder,
                                                          liveKeys: curKeys,
                                                          liveHiddenKeys: liveHidden ?? [],
                                                          hiddenDividerIndex: store.hiddenDividerIndex)
            store.desiredOrder = adopted.order
            store.hiddenDividerIndex = adopted.hiddenDividerIndex
            persistStore()
            return
        }

        // AUTO-SAVE, part 2 — new icons: merge freshly-appeared identities into the
        // saved order at their observed position, so the engine KNOWS them instead of
        // treating every later tick as unexplained drift (the back-and-forth the
        // membership confusion caused). No moves here; pure bookkeeping.
        // Placeholder slot for new icons: the user's saved position, defaulting to
        // just RIGHT of the divider (top of the visible band) — macOS spawns new
        // status items at the far left, physically inside the hidden band, and
        // "new icon silently vanishes behind the chevron" is never what anyone wants.
        let placeholder = store.newItemsIndex ?? store.hiddenDividerIndex ?? 0
        let (merged, dividerIdx) = MenuBarOrderDiff.mergingNewItems(
            desired: store.desiredOrder, live: curIdentities,
            hiddenDividerIndex: store.hiddenDividerIndex,
            liveHiddenKeys: liveHidden,
            newItemsIndex: placeholder)
        if merged.count != store.desiredOrder.count {
            pendingNewIconPlacement = true
            // Cursor semantics: every insertion lands at the placeholder and pushes
            // it right, so a SAVED placeholder keeps sitting after the icons it
            // just adopted (the default one re-derives from the divider each tick).
            if let idx = store.newItemsIndex {
                store.newItemsIndex = min(idx + (merged.count - store.desiredOrder.count), merged.count)
            }
            store.desiredOrder = merged
            store.hiddenDividerIndex = dividerIdx
            persistStore()
        }

        // ENFORCE — live mode, or the user-initiated on-demand reveal. The plain
        // background tick in on-demand mode stops here: it only auto-saves.
        guard store.mode == .live || userInitiated else { return }
        let n = now
        if !policy.canApply(now: n, onBattery: Self.onBattery()) {
            // Deferred while a placement is pending: the bar is static now, so force
            // the next tick past the fingerprint gate to retry once the cooldown ends.
            if pendingNewIconPlacement { lastOrderFingerprint = nil }
            return
        }

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
        // A just-merged icon can already satisfy RELATIVE order (it spawned adjacent
        // to its slot) while sitting on the wrong side of the divider — the reveal
        // pass's placeDividers re-seats the boundary around it, so run it anyway.
        guard orderWrong || needsReindex || pendingNewIconPlacement else { return }

        working = true
        let desired = store.desiredOrder
        let hiddenKeys = store.hiddenKeys
        let alwaysHidden = store.alwaysHidden
        let mode = store.mode
        let placeNewIcon = pendingNewIconPlacement
        pendingNewIconPlacement = false
        Task {
            // Live mode never force-reveals — only reorders on-screen items (Stats are
            // visible; that's the use case). On-demand reveals via onReveal/Apply, and
            // restores band membership in the same pass (live leaves the divider alone).
            // ONE exception: a new icon just merged at its placeholder. It spawned at
            // macOS's far-left default — physically OFF-SCREEN in the collapsed hidden
            // band — and an off-screen icon can't be synthetic-dragged without a brief
            // reveal. A just-appeared icon is the one moment a flash of the hidden band
            // is justified, and it's a rare event (not the steady-state tick).
            let result = await MenuBarArranger.apply(desired: desired,
                                                     hiddenKeys: hiddenKeys,
                                                     alwaysHiddenKeys: alwaysHidden,
                                                     reveal: mode != .live || placeNewIcon)
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
            // Fingerprint after an apply: an ACTIONABLE pass invalidates it — apply()
            // re-ran the indexer (refreshing `lastIndexedHashes`), which can make a
            // previously-unresolvable item resolvable WITHOUT changing the windowID
            // order, invisible to the order-only pre-gate. A NO-OP pass instead stamps
            // the CURRENT order: nothing changed and nothing was placeable, so
            // re-checking every tick until the bar actually changes only burns CPU
            // (each wasted pass re-captures for hashes) — the old unconditional nil
            // here was that loop.
            lastOrderFingerprint = actionable ? nil
                : MenuBarBridge.menuBarWindowOrder(onDisplay: CGMainDisplayID())
            working = false
        }
    }

    /// Posted after an auto-save (adopt / merge) writes the order store, so an open
    /// Settings pane can re-read instead of showing a stale list.
    static let orderAutoSaved = Notification.Name("ProsperMenuBarOrderAutoSaved")

    /// Persist an auto-saved store mutation (adopt / merge). Writes Preferences so
    /// it survives relaunch; notifies any open Settings pane.
    private func persistStore() {
        Preferences.menuBarOrderStore = store
        NotificationCenter.default.post(name: Self.orderAutoSaved, object: nil)
    }

    /// True when running on battery (gentler cadence). Fail-open to AC on error.
    private static func onBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }
}
