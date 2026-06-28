import AppKit
import CoreGraphics

// MARK: - Private CoreGraphics / SkyLight (CGS) bindings
//
// ponytail: this is the ONE unsupported-API surface in the menu-bar feature.
// These symbols are private (same ones Ice uses) and let us enumerate menu-bar
// status-item windows + read their frames WITHOUT Accessibility or Screen
// Recording. They are acceptable here because Prosper ships notarized-direct,
// not via the App Store. Every call is checked for `CGError == .success`; if a
// symbol is ever renamed/removed by Apple the wrapper returns empty and the
// manager disables the feature (fail-open) — it never crashes the app.

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

/// Fills `list` with the window IDs of the current process-visible menu-bar items.
/// `targetPID == 0` means "all processes". Returns the count actually written in
/// `outCount`.
@_silgen_name("CGSGetProcessMenuBarWindowList")
private func CGSGetProcessMenuBarWindowList(_ cid: Int32, _ targetPID: Int32,
                                            _ maxCount: Int32,
                                            _ list: UnsafeMutablePointer<UInt32>,
                                            _ outCount: UnsafeMutablePointer<Int32>) -> CGError

/// Screen-coordinate frame for a window id, without Accessibility.
@_silgen_name("CGSGetScreenRectForWindow")
private func CGSGetScreenRectForWindow(_ cid: Int32, _ wid: UInt32,
                                       _ outRect: UnsafeMutablePointer<CGRect>) -> CGError

// MARK: - Own-item registry (Tahoe self-filter source)

/// Whether an own status item is chrome we hide from the managed set, or content
/// the user wants to see and order.
enum MenuBarItemRole {
    /// Launcher icon, chevron, dividers — Prosper's own UI. Always self-filtered out.
    case control
    /// Stats modules, extension icons — our own data icons. KEPT in the managed list
    /// (named + previewed from this registry) so the user can order/preview them;
    /// ordering multi-icon apps like Stats is the whole point of the feature.
    case content
}

/// Every `NSStatusItem` Prosper creates registers here so the menu-bar bridge can
/// (a) filter our own CHROME out of the foreign-item enumeration and (b) name +
/// snapshot our own CONTENT icons, which Tahoe would otherwise reduce to "Item-0"
/// with no picture.
///
/// Why a registry instead of a pid check: on macOS 26 (Tahoe) the window server
/// attributes EVERY menu-bar window — ours, third-party, all of them — to Control
/// Center (pid 800) in `CGWindowListCopyWindowInfo`, and `CGSGetProcessMenuBarWindowList`
/// ignores its `targetPID` argument. So pid can no longer say "this window is mine."
/// The only reliable self-signal left is geometry: an item's on-screen `minX`
/// (read from `item.button.window.frame`, which is correct — `NSApp.windows`
/// reports a bogus (0,-33) frame for status windows) matches its CGS window's minX
/// exactly. The bridge frame-matches these minX values.
@MainActor
enum ProsperStatusItems {
    struct Live { let minX: CGFloat; let role: MenuBarItemRole; let name: String?; let item: NSStatusItem }
    private struct Entry { let provider: () -> NSStatusItem?; let role: MenuBarItemRole; let name: String? }
    private static var entries: [Entry] = []

    /// Register a Prosper-owned status item. `role` defaults to `.control` (chrome);
    /// pass `.content` + a human `name` for Stats/extension icons. Held weakly so
    /// removed items drop out on the next sweep.
    static func register(_ item: NSStatusItem, role: MenuBarItemRole = .control, name: String? = nil) {
        entries.append(Entry(provider: { [weak item] in item }, role: role, name: name))
    }

    /// Live snapshot of every own item with a resolvable on-screen minX. Compacts
    /// dead weak refs. Cheap (a handful of items).
    static func live() -> [Live] {
        entries.removeAll { $0.provider() == nil }
        return entries.compactMap { e in
            guard let it = e.provider(), let x = it.button?.window?.frame.minX else { return nil }
            return Live(minX: x, role: e.role, name: e.name, item: it)
        }
    }

    /// minX of own CONTROL items only — the set the bridge self-filters out. Content
    /// items stay in the managed list.
    static func controlMinX() -> [CGFloat] { live().filter { $0.role == .control }.map(\.minX) }

    /// Own CONTENT item whose on-screen minX matches `x` — supplies a real name + a
    /// button to snapshot.
    static func content(nearMinX x: CGFloat, tolerance: CGFloat = 2) -> Live? {
        live().first { $0.role == .content && abs($0.minX - x) < tolerance }
    }

    /// Direct button snapshot of the own content item at `x` — no Screen Recording
    /// needed (it's our own view). nil if no match or the button has no size yet.
    static func snapshot(nearMinX x: CGFloat, tolerance: CGFloat = 2) -> NSImage? {
        guard let hit = content(nearMinX: x, tolerance: tolerance),
              let b = hit.item.button, b.bounds.width > 1, b.bounds.height > 1,
              let rep = b.bitmapImageRepForCachingDisplay(in: b.bounds) else { return nil }
        b.cacheDisplay(in: b.bounds, to: rep)
        let img = NSImage(size: b.bounds.size)
        img.addRepresentation(rep)
        return img
    }
}

// MARK: - Safe Swift surface

/// One status-bar item measured from the window server.
struct MenuBarItem: Equatable, Sendable {
    var windowID: CGWindowID
    var pid: pid_t
    var frame: CGRect            // screen coords (top-left origin, like CGWindow)
    var bundleID: String?
    var displayID: CGDirectDisplayID
    /// OS window name (kCGWindowName). Per-item discriminator for the ordering
    /// engine pre-Tahoe; nil/"Menu Item" on Tahoe (the indexer fills identity then).
    var title: String?
    /// True for Prosper's own CONTENT icons (Stats modules, extension icons). They
    /// stay in the managed set but carry a real name/bundle from the registry instead
    /// of Tahoe's "controlcenter / Item-0" masking — and preview from a direct button
    /// snapshot rather than Screen Recording.
    var isOwn: Bool = false
}

/// Reads the live menu bar via the private CGS list. Fail-open: any CGS error or
/// a missing symbol surfaces as `available == false` + an empty item list; the
/// caller disables the feature rather than crashing.
@MainActor
enum MenuBarBridge {
    /// Flips false the first time a CGS call errors, so the manager can disable the
    /// feature and log once instead of hammering a broken API every reconcile.
    private(set) static var available = true

    /// pid → bundle id, long-lived (NOT per-reconcile). A cold first reveal would
    /// otherwise pay 40× `NSRunningApplication` lookups; the cache makes the warm
    /// path cheap. Invalidated per-pid on app termination (see `appTerminated`).
    private static var bundleIDCache: [pid_t: String] = [:]

    /// Window ids of our OWN divider items — excluded from the managed set even
    /// though they share our pid (we self-filter all of getpid()'s windows, but
    /// this lets the manager find the dividers' own frames when it needs them).
    static var dividerWindowIDs: Set<CGWindowID> = []

    /// Drop a terminated app from the bundle-id cache. Call from the manager's
    /// `NSWorkspace.didTerminateApplicationNotification` observer.
    static func appTerminated(pid: pid_t) { bundleIDCache.removeValue(forKey: pid) }

    /// All managed menu-bar items on `display`, sorted left→right by x-origin.
    /// Filters out Prosper's own windows (status item, extension items, dividers)
    /// and off-active-space items (empty title ⇒ not in the list anyway), then
    /// keeps only items whose frame falls on the requested display.
    static func items(onDisplay display: CGDirectDisplayID) -> [MenuBarItem] {
        guard available else { return [] }
        let cid = CGSMainConnectionID()

        // 1. CGS menu-bar window-id list (all processes).
        var ids = [UInt32](repeating: 0, count: 256)
        var realCount: Int32 = 0
        let err = ids.withUnsafeMutableBufferPointer { buf -> CGError in
            CGSGetProcessMenuBarWindowList(cid, 0, Int32(buf.count), buf.baseAddress!, &realCount)
        }
        guard err == .success else { markUnavailable("menuBarWindowList err \(err.rawValue)"); return [] }
        let windowIDs = Array(ids.prefix(Int(max(0, realCount))))
        guard !windowIDs.isEmpty else { return [] }

        // 2. One window-info pass to map windowID → (pid, name).
        let metaByWindow = windowMeta(for: windowIDs)

        // 3. Build items, self-filtering OUR CHROME by FRAME MATCH (Tahoe-safe; pid no
        //    longer identifies our windows — see ProsperStatusItems) and per-display.
        //    Own CONTENT icons (Stats, extensions) are KEPT and enriched with a real
        //    name/bundle from the registry (Tahoe masks them to controlcenter/Item-0).
        let controlX = ProsperStatusItems.controlMinX()
        let ownContent = ProsperStatusItems.live().filter { $0.role == .content }
        var out: [MenuBarItem] = []
        out.reserveCapacity(windowIDs.count)
        var seen = Set<UInt32>()   // the CGS list can repeat a window id during a reflow
        for wid in windowIDs {
            guard seen.insert(wid).inserted else { continue }
            var rect = CGRect.zero
            guard CGSGetScreenRectForWindow(cid, wid, &rect) == .success,
                  rect.width > 0, rect.height > 0 else { continue }
            if controlX.contains(where: { abs($0 - rect.minX) < 2 }) { continue }  // F4 self-filter (chrome only)
            guard displayID(for: rect) == display else { continue }                // F3 per-display
            let meta = metaByWindow[wid]
            if let own = ownContent.first(where: { abs($0.minX - rect.minX) < 2 }) {
                out.append(MenuBarItem(windowID: CGWindowID(wid), pid: getpid(), frame: rect,
                                       bundleID: "com.prosper", displayID: display,
                                       title: own.name ?? meta?.name, isOwn: true))
            } else {
                out.append(MenuBarItem(windowID: CGWindowID(wid), pid: meta?.pid ?? 0, frame: rect,
                                       bundleID: (meta?.pid).flatMap { bundleID(for: $0) }, displayID: display,
                                       title: meta?.name))
            }
        }
        out.sort { $0.frame.minX < $1.frame.minX }
        return out
    }

    /// True when a CGS window's `minX` matches any Prosper-owned status item's
    /// on-screen `minX` (within 2 pt). The window-server frame and the AppKit frame
    /// agree on x to the pixel, so a tight tolerance is enough to self-identify.
    private static func isOwn(minX x: CGFloat, _ ownX: [CGFloat]) -> Bool {
        ownX.contains { abs($0 - x) < 2 }
    }

    /// CGS window id for a Prosper-owned status item, found by matching its on-screen
    /// `minX` (passed in from `item.button.window.frame.minX`) against the live CGS
    /// menu-bar enumeration. This REPLACES mapping via `NSWindow.windowNumber`, which
    /// is unusable on Tahoe (windowNumber moved into a separate +2³² namespace
    /// unrelated to CGWindowID). nil if no window matches within tolerance.
    static func windowID(forItemMinX x: CGFloat, tolerance: CGFloat = 2) -> CGWindowID? {
        guard available else { return nil }
        let cid = CGSMainConnectionID()
        var ids = [UInt32](repeating: 0, count: 256)
        var n: Int32 = 0
        let err = ids.withUnsafeMutableBufferPointer {
            CGSGetProcessMenuBarWindowList(cid, 0, Int32($0.count), $0.baseAddress!, &n)
        }
        guard err == .success else { return nil }
        var best: (id: CGWindowID, dx: CGFloat)?
        for wid in ids.prefix(Int(max(0, n))) {
            var rect = CGRect.zero
            guard CGSGetScreenRectForWindow(cid, wid, &rect) == .success, rect.width > 0 else { continue }
            let dx = abs(rect.minX - x)
            if best == nil || dx < best!.dx { best = (CGWindowID(wid), dx) }
        }
        guard let best, best.dx <= tolerance else { return nil }
        return best.id
    }

    /// Cheap left→right windowID order of FOREIGN menu-bar items on `display`,
    /// WITHOUT the heavy `CGWindowListCopyWindowInfo(.optionAll)` system-wide window
    /// enumeration that `items(onDisplay:)` pays for pid/name/bundle. Used by the
    /// live enforcer as a drift PRE-GATE on its 2s main-thread tick: if this sequence
    /// is unchanged since the last full check, the order cannot have drifted, so it
    /// skips the expensive identity rebuild entirely. Self-filters our own windows
    /// via the per-pid CGS list (two cheap CGS calls, no system window scan). Returns
    /// [] on any CGS error — the caller then falls back to the full check.
    ///
    /// HOT PATH: this is the ONLY thing the steady-state live loop should call per
    /// tick. Keep it free of `CGWindowListCopyWindowInfo` and heap-heavy work.
    static func menuBarWindowOrder(onDisplay display: CGDirectDisplayID) -> [CGWindowID] {
        guard available else { return [] }
        let cid = CGSMainConnectionID()
        var ids = [UInt32](repeating: 0, count: 256)
        var n: Int32 = 0
        let err = ids.withUnsafeMutableBufferPointer {
            CGSGetProcessMenuBarWindowList(cid, 0, Int32($0.count), $0.baseAddress!, &n)
        }
        guard err == .success else { return [] }
        let all = Array(ids.prefix(Int(max(0, n))))
        guard !all.isEmpty else { return [] }
        let controlX = ProsperStatusItems.controlMinX()   // self-filter CHROME by frame match (Tahoe-safe)
        var pairs: [(id: CGWindowID, x: CGFloat)] = []
        pairs.reserveCapacity(all.count)
        for wid in all {
            var rect = CGRect.zero
            guard CGSGetScreenRectForWindow(cid, wid, &rect) == .success,
                  rect.width > 0, rect.height > 0, displayID(for: rect) == display else { continue }
            if isOwn(minX: rect.minX, controlX) { continue }
            pairs.append((CGWindowID(wid), rect.minX))
        }
        return pairs.sorted { $0.x < $1.x }.map(\.id)
    }

    /// Positive sanity probe for the Settings preview strip. Healthy = the CGS
    /// enumeration still contains windows we KNOW exist (our own dividers). See
    /// `MenuBarLogic.previewHealthy` for why a hard error check isn't enough. Only
    /// the preview depends on this — hide/show + spacing are unaffected.
    static func enumHealthy() -> Bool {
        guard available else { return false }
        guard !dividerWindowIDs.isEmpty else { return true }   // nothing to probe against yet
        let cid = CGSMainConnectionID()
        var ids = [UInt32](repeating: 0, count: 256)
        var realCount: Int32 = 0
        let err = ids.withUnsafeMutableBufferPointer { buf -> CGError in
            CGSGetProcessMenuBarWindowList(cid, 0, Int32(buf.count), buf.baseAddress!, &realCount)
        }
        guard err == .success else { return false }
        let seen = Set(ids.prefix(Int(max(0, realCount))).map { CGWindowID($0) })
        return MenuBarLogic.previewHealthy(dividerWindowIDs: dividerWindowIDs, enumeratedWindowIDs: seen)
    }

    /// The display a frame's center lands on; falls back to the main display.
    static func displayID(for frame: CGRect) -> CGDirectDisplayID {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var id = CGDirectDisplayID(0)
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(center, 1, &id, &count) == .success, count > 0 { return id }
        return CGMainDisplayID()
    }

    // MARK: - Private

    /// Live screen frame for one window id (the ordering engine reads this between
    /// moves to confirm an item actually shifted). nil on any CGS error.
    static func frame(for windowID: CGWindowID) -> CGRect? {
        guard available else { return nil }
        var rect = CGRect.zero
        guard CGSGetScreenRectForWindow(CGSMainConnectionID(), UInt32(windowID), &rect) == .success,
              rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    /// Map window ids → (owner pid, name) via one `CGWindowListCopyWindowInfo` pass.
    private static func windowMeta(for windowIDs: [UInt32]) -> [UInt32: (pid: pid_t, name: String?)] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        let wanted = Set(windowIDs)
        var map: [UInt32: (pid: pid_t, name: String?)] = [:]
        map.reserveCapacity(windowIDs.count)
        for w in info {
            guard let num = w[kCGWindowNumber as String] as? UInt32, wanted.contains(num),
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let name = (w[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            map[num] = (pid, name)
        }
        return map
    }

    private static func bundleID(for pid: pid_t) -> String? {
        if let cached = bundleIDCache[pid] { return cached }
        guard let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
        bundleIDCache[pid] = bid
        return bid
    }

    private static func markUnavailable(_ reason: String) {
        guard available else { return }
        available = false
        NSLog("prosper: menu-bar CGS unavailable (\(reason)) — feature disabled")
    }
}
