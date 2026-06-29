import AppKit
import CoreGraphics

// On-Demand arranger for the ordering engine (Phases 2–3). Snapshots the live
// left→right order into stable identities, and replays a saved order by driving
// `MenuBarItemMover` one neighbor at a time. The desired order is captured by the
// user ("Save current order") until the drag editor lands (P5).
//
// Identity = bundle id + the strongest discriminator: the OS window title pre-Tahoe,
// or a perceptual image hash on macOS 26 where every third-party title reads
// "Menu Item" (P3, `MenuBarItemIndexer`). Items we still can't resolve stay
// unresolved and are left in place rather than mis-ordered. Cross-relaunch matching
// tolerates AA jitter via Hamming-distance fallback when an exact hash key misses.

@MainActor
enum MenuBarArranger {
    /// Max Hamming distance between two 64-bit dHashes still considered the same
    /// item across relaunch. Identical assets normally hash bit-for-bit; this only
    /// absorbs sub-pixel anti-aliasing drift. Kept tight so distinct glyphs (Stats
    /// CPU vs RAM) never collapse.
    nonisolated static let hashMatchTolerance = 5

    /// Result of an apply pass, for surfacing in Settings.
    struct ApplyResult: Equatable {
        var moved: Int
        var skippedUnresolved: Int
        var failed: Int
    }

    /// Identity for a live item. Falls back to "unknown" bundle so a nil never
    /// collides everything onto one key. `hash` (when supplied by the indexer)
    /// becomes the discriminator on Tahoe where the title is the "Menu Item"
    /// placeholder.
    static func identity(for item: MenuBarItem, hash: UInt64? = nil) -> MenuBarIdentity {
        MenuBarIdentity(bundleID: item.bundleID ?? "unknown",
                        title: item.title,
                        imageHash: hash.map(MenuBarPerceptualHash.hex))
    }

    /// Primary-display items, left→right (already sorted by MenuBarBridge).
    static func currentItems() -> [MenuBarItem] {
        MenuBarBridge.items(onDisplay: CGMainDisplayID())
    }

    /// Reveal the bar and index the visible items into perceptual hashes. Off-screen
    /// items can't be captured, so we collapse the divider first. Returns the live
    /// items and their hashes (empty hash map when title-based identity suffices or
    /// Screen Recording isn't granted).
    /// ponytail: no circuit breaker here — indexing only runs on explicit user
    /// action (Save / Apply / Re-index), never a loop, so it can't melt the CPU; the
    /// live enforcement loop (P4) is the one that wires `MenuBarCircuitBreaker`.
    private static func revealAndIndex(reveal: Bool) async -> (items: [MenuBarItem], hashes: [CGWindowID: UInt64]) {
        if reveal {
            MenuBarManager.shared.setRevealed(true)
            try? await Task.sleep(for: .milliseconds(120))
        }
        let items = currentItems()
        let hashes = await MenuBarItemIndexer.hashes(for: items)
        lastIndexedHashes = hashes   // share with the live enforcer's cheap drift check
        return (items, hashes)
    }

    /// Most recent windowID→hash map, reused by `MenuBarOrderEnforcer` so its live
    /// drift check stays capture-free between apply passes.
    private(set) static var lastIndexedHashes: [CGWindowID: UInt64] = [:]

    /// Capture the current left→right order as the desired layout (with hashes so
    /// Tahoe items become resolvable). Async because it may index images.
    static func snapshotCurrentOrder() async -> (order: [MenuBarIdentity], hiddenDividerIndex: Int?) {
        // Block the live enforcer from reordering mid-capture (it would shift frames
        // and the racing enumeration would record the same item twice).
        isApplying = true
        defer { isApplying = false }
        // Reveal BOTH bands, THEN classify + hash. Off-screen (collapsed) hidden items
        // aren't enumerated by `items(onDisplay:)` (they sit off the main display, so the
        // per-display filter drops them) AND hash to the same near-empty image ("0010").
        // Revealed, every item is on-screen: it hashes distinct, and `section(forItemX:)`
        // still classifies correctly — the separators collapse to their boundary x, so
        // hidden items keep the smallest x. Classifying pre-reveal missed every off-screen
        // hidden item, which pinned the divider to the top.
        let (sectioned, hashes) = await MenuBarManager.shared.withAllRevealed {
            () -> ([(item: MenuBarItem, section: MenuBarSection)], [CGWindowID: UInt64]) in
            let sectioned = MenuBarManager.shared.sectionedItems()
            let hashes = await MenuBarItemIndexer.hashes(for: sectioned.map(\.item))
            lastIndexedHashes = hashes
            return (sectioned, hashes)
        }
        let items = sectioned.map(\.item)
        var sectionByWindow: [CGWindowID: MenuBarSection] = [:]
        for entry in sectioned { sectionByWindow[entry.item.windowID] = entry.section }
        // Dedup by identity key: a transient reflow (or two CGS windows for one item)
        // can surface the same identity twice; keep first occurrence, preserve order.
        var seen = Set<String>()
        var order: [MenuBarIdentity] = []
        var hiddenCount = 0
        for item in items {
            let id = identity(for: item, hash: hashes[item.windowID])
            // Drop items the engine can't manage on Tahoe — placeholder/unresolvable
            // foreign items ("Item-0") that we can neither name nor reliably move.
            // Own items always carry com.prosper, so they survive even pre-index.
            guard id.isManageable, seen.insert(id.key).inserted else { continue }
            order.append(id)
            // Non-visible items sit leftmost (always-hidden < hidden < visible by x),
            // so they're the leading run — count them to place the divider where the
            // user already dragged things in the real bar.
            if (sectionByWindow[item.windowID] ?? .visible) != .visible { hiddenCount += 1 }
        }
        return (order, hiddenCount == 0 ? nil : hiddenCount)
    }

    /// Replay `desired` over the live bar. Reveals hidden items first (off-screen
    /// items can't be dragged), then for each adjacent desired pair forces the
    /// right one to sit immediately right of its left neighbor — self-correcting
    /// regardless of start order. Each `move` re-reads live frames and early-returns
    /// when already positioned, so settled items cost only a frame read.
    ///
    /// ponytail: O(n) move attempts, not move-count-minimal — the per-step
    /// early-return makes redundant attempts cheap, and minimizing real drags
    /// (LIS over `MenuBarOrderDiff`) is the P4 optimization where each drag costs a
    /// cursor hijack. Returns counts; never throws (per-item failures are tallied).
    /// True while an apply pass is in flight. The enforcer reads this so its own
    /// `setRevealed(true)`-triggered reveal hook (and a manual "Apply" press) can't
    /// kick off a concurrent second pass.
    private(set) static var isApplying = false

    /// `reveal: false` reorders only items already on-screen — used by LIVE mode so it
    /// never force-reveals (then re-collapses) the hidden section every tick, which
    /// looked like icons flickering in and out. Reveal-to-reorder (so hidden items can
    /// be dragged too) stays for explicit actions: "Apply saved order" and on-demand.
    @discardableResult
    static func apply(desired: [MenuBarIdentity],
                      hiddenKeys: [String] = [], alwaysHiddenKeys: [String] = [],
                      reveal: Bool = true) async -> ApplyResult {
        guard !desired.isEmpty else { return ApplyResult(moved: 0, skippedUnresolved: 0, failed: 0) }
        isApplying = true
        defer { isApplying = false }

        // Explicit applies (reveal:true) pin BOTH separators collapsed for the WHOLE
        // move batch via withAllRevealed — a STABLE reveal with no auto-rehide. The old
        // path (setRevealed(true)) armed a rehide timer + hover monitors; because the
        // cursor parks off-bar during synthetic drags, "not hovering" auto-collapsed the
        // hidden zone mid-batch, shifting the visible band left by ~the hidden-zone width
        // so items landed ~2 slots too far left — sometimes across the divider into hidden.
        //
        // Order AND band membership are restored under the SAME reveal so the whole layout
        // settles in one pass (no multi-click): first put the items in desired relative
        // order, then drop the divider(s) at their band boundaries. Live mode (reveal:false)
        // only maintains relative order of on-screen items; the divider is left alone.
        if reveal {
            return await MenuBarManager.shared.withAllRevealed {
                let r = await applyMoves(desired: desired)
                await placeDividers(desired: desired, hiddenKeys: hiddenKeys,
                                    alwaysHiddenKeys: alwaysHiddenKeys)
                return r
            }
        }
        return await applyMoves(desired: desired)
    }

    /// After the order pass the desired items sit in their saved relative order
    /// (always-hidden, then hidden, then visible). Restore band MEMBERSHIP by dropping
    /// the separators at their right boundaries — the hidden separator just LEFT of the
    /// first visible item, the always-hidden separator just LEFT of the first merely-
    /// hidden item — so on re-collapse everything to a separator's left goes off-screen.
    /// Moving the (own) separators with `.leftOf` is reliable on Tahoe; pulling each item
    /// across with `.rightOf` is not. No-ops when there's no hidden band to restore.
    private static func placeDividers(desired: [MenuBarIdentity],
                                      hiddenKeys: [String], alwaysHiddenKeys: [String]) async {
        guard !hiddenKeys.isEmpty || !alwaysHiddenKeys.isEmpty else { return }
        let hidden = Set(hiddenKeys), always = Set(alwaysHiddenKeys)
        // Live key → window for the items we just ordered.
        let items = currentItems()
        let hashes = await MenuBarItemIndexer.hashes(for: items)
        var win: [String: MenuBarItem] = [:]
        for it in items {
            let k = identity(for: it, hash: hashes[it.windowID]).key
            if win[k] == nil { win[k] = it }
        }
        let firstVisible = desired.first { !hidden.contains($0.key) && !always.contains($0.key) }
        let firstHidden = desired.first { hidden.contains($0.key) }
        let pid = getpid()
        await MenuBarItemMover.withCursorParked {
            if let fv = firstVisible.flatMap({ win[$0.key] }),
               let sep = MenuBarManager.shared.hiddenAnchorWindowID() {
                try? await MenuBarItemMover.move(windowID: sep, pid: pid, to: .leftOf(fv.windowID))
            }
            if !always.isEmpty,
               let boundary = (firstHidden ?? firstVisible).flatMap({ win[$0.key] }),
               let altSep = MenuBarManager.shared.alwaysHiddenAnchorWindowID() {
                try? await MenuBarItemMover.move(windowID: altSep, pid: pid, to: .leftOf(boundary.windowID))
            }
        }
    }

    /// The match + move batch. Assumes the caller already established the desired reveal
    /// state (withAllRevealed for explicit applies; live mode reorders only on-screen
    /// items). Reads the current on-screen layout WITHOUT toggling separators, so frames
    /// stay stable for every endpoint computation in the loop.
    private static func applyMoves(desired: [MenuBarIdentity]) async -> ApplyResult {
        let (live, hashes) = await revealAndIndex(reveal: false)

        // Live identities (title or fresh hash). First item wins a key (dup
        // unresolved keys can't be ordered apart).
        var byKey: [String: MenuBarItem] = [:]
        // Same-bundle hash candidates for the Hamming fallback when an exact key misses.
        var hashCandidates: [String: [(key: String, hash: UInt64)]] = [:]
        for item in live {
            let id = identity(for: item, hash: hashes[item.windowID])
            if byKey[id.key] == nil { byKey[id.key] = item }
            if let h = hashes[item.windowID] {
                hashCandidates[item.bundleID ?? "unknown", default: []].append((id.key, h))
            }
        }

        // Assign each desired item to a DISTINCT live window (exclusive matching):
        // once a live window is claimed it leaves the pool, so two same-bundle
        // siblings can't both grab one window (which would drop the other and leave
        // the live order permanently "drifted"). Exact key first, hash fallback next.
        var placed: [MenuBarItem] = []
        var skippedUnresolved = 0
        var claimed = Set<CGWindowID>()
        for id in desired {
            guard id.isResolved else { skippedUnresolved += 1; continue }
            if let item = byKey[id.key], !claimed.contains(item.windowID) {
                placed.append(item); claimed.insert(item.windowID)
            } else if let item = fuzzyMatch(id, byKey: byKey, candidates: hashCandidates,
                                            excluding: claimed) {
                placed.append(item); claimed.insert(item.windowID)
            }
        }
        guard placed.count > 1 else {
            return ApplyResult(moved: 0, skippedUnresolved: skippedUnresolved, failed: 0)
        }

        let placedIDs = Set(placed.map { $0.windowID })
        var moved = 0, failed = 0
        // Park the cursor once around the whole batch (not per move).
        await MenuBarItemMover.withCursorParked {
            // Build the order RIGHT-TO-LEFT using ONLY `.leftOf`. `.rightOf` (drop at
            // anchor.maxX) is unreliable on Tahoe: the dragged item snaps its RIGHT edge
            // to the cursor, so dropping at the anchor's right edge lands the item ON the
            // anchor's slot and shoves it LEFT — when the anchor is the leftmost visible
            // item that pushes it across the divider into the hidden band. `.leftOf` is
            // the only direction the self-probe exercises (and proves works), so anchor
            // each item against the already-correct neighbor to its right.
            for i in stride(from: placed.count - 2, through: 0, by: -1) {
                let item = placed[i], anchor = placed[i + 1]
                // RELATIVE-order skip, NOT physical adjacency: skip when `item` already
                // appears anywhere BEFORE `anchor` among the placed items in the live
                // bar. Demanding adjacency (ii == ai-1) was the oscillation bug — managed
                // icons can be split into groups by UNMOVABLE system items (Control
                // Center, clock), so contiguity is unreachable and the live timer would
                // re-drag already-correctly-ordered icons forever chasing it. This
                // matches the enforcer's drift check (isRelativeOrderSatisfied), so a
                // pass that satisfies relative order also clears drift → it converges.
                // Cheap windowID-order read (no system window enum); re-read each step
                // since prior moves reflow frames.
                let seq = MenuBarBridge.menuBarWindowOrder(onDisplay: CGMainDisplayID())
                    .filter { placedIDs.contains($0) }
                if let ai = seq.firstIndex(of: anchor.windowID),
                   let ii = seq.firstIndex(of: item.windowID), ii < ai { continue }
                do {
                    try await MenuBarItemMover.move(windowID: item.windowID, pid: item.pid,
                                                    to: .leftOf(anchor.windowID))
                    // Confirm by relative landing position, not a bare frame change: a
                    // neighbor's reflow also changes our frame, which would over-count.
                    let after = MenuBarBridge.menuBarWindowOrder(onDisplay: CGMainDisplayID())
                        .filter { placedIDs.contains($0) }
                    if let ai = after.firstIndex(of: anchor.windowID),
                       let ii = after.firstIndex(of: item.windowID), ii < ai { moved += 1 }
                } catch {
                    failed += 1
                    NSLog("prosper: menu-bar arrange — move failed for \(item.bundleID ?? "?"): \(error)")
                }
            }
        }
        return ApplyResult(moved: moved, skippedUnresolved: skippedUnresolved, failed: failed)
    }

    /// Apply the user's always-hidden marks: move each marked live item to the LEFT
    /// of the always-hidden separator (which stays expanded → off-screen), and pull
    /// any unmarked item that drifted left of it back to the right. Reveals both bands
    /// first so the drop points are on-screen, then restores the hidden state.
    ///
    /// macOS persists status-item positions across relaunch, so this only needs to run
    /// when the marks change (and as a correction on reveal) — not on a loop. Best-
    /// effort; per-item failures are logged, never thrown (it must not wedge Settings).
    static func applyBands(hidden hiddenKeys: [String], alwaysHidden alwaysHiddenKeys: [String]) async {
        guard MenuBarBridge.available else { return }
        isApplying = true
        defer { isApplying = false }

        MenuBarManager.shared.beginPlacement()
        defer { MenuBarManager.shared.endPlacement() }
        try? await Task.sleep(for: .milliseconds(150))   // let the collapsed bands lay out

        // The hidden separator is always present; the always-hidden one only when the
        // user has marked at least one icon. Place relative to whichever exist.
        let hiddenAnchor = MenuBarManager.shared.hiddenAnchorWindowID()
        let hiddenX = hiddenAnchor.flatMap(MenuBarBridge.frame(for:))?.minX
        let altAnchor = MenuBarManager.shared.alwaysHiddenAnchorWindowID()
        let altX = altAnchor.flatMap(MenuBarBridge.frame(for:))?.minX

        let hidden = Set(hiddenKeys), always = Set(alwaysHiddenKeys)
        let items = currentItems()
        let hashes = await MenuBarItemIndexer.hashes(for: items)
        await MenuBarItemMover.withCursorParked {
            for item in items {
                let key = identity(for: item, hash: hashes[item.windowID]).key
                let x = item.frame.minX
                // Target band → the single corrective move that lands it on the right
                // side of the relevant anchor. Items already correct emit no move.
                let dest: MenuBarItemMover.Destination?
                if always.contains(key) {
                    // Always-hidden: must sit LEFT of the always-hidden separator.
                    if let a = altAnchor, let ax = altX, x >= ax { dest = .leftOf(a) } else { dest = nil }
                } else if hidden.contains(key) {
                    // Hidden: left of the chevron's hidden separator, but right of the
                    // always-hidden one (don't over-hide). Fix whichever side is wrong.
                    if let h = hiddenAnchor, let hx = hiddenX, x >= hx { dest = .leftOf(h) }
                    else if let a = altAnchor, let ax = altX, x < ax { dest = .rightOf(a) }
                    else { dest = nil }
                } else {
                    // Visible: right of the hidden separator.
                    if let h = hiddenAnchor, let hx = hiddenX, x < hx { dest = .rightOf(h) } else { dest = nil }
                }
                guard let dest else { continue }
                do { try await MenuBarItemMover.move(windowID: item.windowID, pid: item.pid, to: dest) }
                catch { NSLog("prosper: band placement failed for \(item.bundleID ?? "?"): \(error)") }
            }
        }
    }

    /// Hash-only fallback when a desired item's exact key isn't live: among the same
    /// bundle's UNCLAIMED live hashes, pick the nearest within tolerance. Returns nil
    /// for title-resolved desired items (no hash to compare) or when nothing's close
    /// enough — caller then leaves the item unmoved rather than guessing.
    private static func fuzzyMatch(_ desired: MenuBarIdentity, byKey: [String: MenuBarItem],
                                   candidates: [String: [(key: String, hash: UInt64)]],
                                   excluding claimed: Set<CGWindowID>) -> MenuBarItem? {
        guard let hex = desired.imageHash,
              let target = MenuBarPerceptualHash.value(fromHex: hex),
              let pool = candidates[desired.bundleID] else { return nil }
        let free = pool.filter { c in byKey[c.key].map { !claimed.contains($0.windowID) } ?? false }
        guard let key = MenuBarPerceptualHash.bestMatch(target: target, candidates: free,
                                                        maxDistance: hashMatchTolerance) else { return nil }
        return byKey[key]
    }
}
