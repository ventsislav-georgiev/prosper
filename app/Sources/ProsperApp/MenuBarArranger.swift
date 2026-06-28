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
    private static func revealAndIndex() async -> (items: [MenuBarItem], hashes: [CGWindowID: UInt64]) {
        MenuBarManager.shared.setRevealed(true)
        try? await Task.sleep(for: .milliseconds(120))
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
    static func snapshotCurrentOrder() async -> [MenuBarIdentity] {
        let (items, hashes) = await revealAndIndex()
        return items.map { identity(for: $0, hash: hashes[$0.windowID]) }
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

    @discardableResult
    static func apply(desired: [MenuBarIdentity]) async -> ApplyResult {
        guard !desired.isEmpty else { return ApplyResult(moved: 0, skippedUnresolved: 0, failed: 0) }
        isApplying = true
        defer { isApplying = false }

        let (live, hashes) = await revealAndIndex()

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
            for i in 1..<placed.count {
                let anchor = placed[i - 1], item = placed[i]
                // Order-based skip (NOT pixel adjacency): if `item` already sits
                // immediately right of `anchor` among the placed items in the live
                // bar, it's correct — don't re-drag it. Inter-item spacing means
                // correctly ordered items are never pixel-touching, so a pixel check
                // would re-drag (and fail "didNotMove") every pass. Re-read live order
                // each step since prior moves reflow frames.
                let seq = currentItems().map { $0.windowID }.filter { placedIDs.contains($0) }
                if let ai = seq.firstIndex(of: anchor.windowID),
                   let ii = seq.firstIndex(of: item.windowID), ii == ai + 1 { continue }
                do {
                    try await MenuBarItemMover.move(windowID: item.windowID, pid: item.pid,
                                                    to: .rightOf(anchor.windowID))
                    // Confirm by landing position, not bare frame change: a neighbor's
                    // reflow also changes our frame, which would over-count moves.
                    let after = currentItems().map { $0.windowID }.filter { placedIDs.contains($0) }
                    if let ai = after.firstIndex(of: anchor.windowID),
                       let ii = after.firstIndex(of: item.windowID), ii == ai + 1 { moved += 1 }
                } catch {
                    failed += 1
                    NSLog("prosper: menu-bar arrange — move failed for \(item.bundleID ?? "?"): \(error)")
                }
            }
        }
        return ApplyResult(moved: moved, skippedUnresolved: skippedUnresolved, failed: failed)
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
