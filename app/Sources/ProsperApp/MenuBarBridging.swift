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

// MARK: - Safe Swift surface

/// One status-bar item measured from the window server.
struct MenuBarItem: Equatable, Sendable {
    var windowID: CGWindowID
    var pid: pid_t
    var frame: CGRect            // screen coords (top-left origin, like CGWindow)
    var bundleID: String?
    var displayID: CGDirectDisplayID
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

        // 2. One window-info pass to map windowID → pid (CGS doesn't give owner pid).
        let pidByWindow = ownerPIDs(for: windowIDs)

        // 3. Build items, self-filtering and per-display.
        let mine = getpid()
        var out: [MenuBarItem] = []
        out.reserveCapacity(windowIDs.count)
        for wid in windowIDs {
            guard let pid = pidByWindow[wid], pid != mine else { continue }   // F4 self-filter
            var rect = CGRect.zero
            guard CGSGetScreenRectForWindow(cid, wid, &rect) == .success,
                  rect.width > 0, rect.height > 0 else { continue }
            guard displayID(for: rect) == display else { continue }            // F3 per-display
            out.append(MenuBarItem(windowID: CGWindowID(wid), pid: pid, frame: rect,
                                   bundleID: bundleID(for: pid), displayID: display))
        }
        out.sort { $0.frame.minX < $1.frame.minX }
        return out
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

    /// Map window ids → owner pid via one `CGWindowListCopyWindowInfo` pass.
    private static func ownerPIDs(for windowIDs: [UInt32]) -> [UInt32: pid_t] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        let wanted = Set(windowIDs)
        var map: [UInt32: pid_t] = [:]
        map.reserveCapacity(windowIDs.count)
        for w in info {
            guard let num = w[kCGWindowNumber as String] as? UInt32, wanted.contains(num),
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            map[num] = pid
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
