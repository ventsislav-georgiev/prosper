// Shared per-app opt-out for the mouse module (plan 017 entry C).
//
// The two services ask different questions, so there are two query APIs and one
// exception list PER SCOPE — a global list would mean excepting an app from the
// side-button navigation also stops inverting its scroll, which is not what
// "leave this app alone" means for either feature.
//
// Everything here sits on an event-tap hot path, so the rules are: no allocation
// and no window-server call per event. `allEmpty` short-circuits the whole thing
// when nothing is configured (the common case), the pid sets are rebuilt on
// workspace notifications rather than on the event, and the pointer→window
// lookup is cached for half a second.

import AppKit

/// The mouse features that can be excepted per app. Grows with the module.
enum MouseScope: String, CaseIterable {
    case scrollInvert, navigation

    var title: String {
        switch self {
        case .scrollInvert: return "Scroll inversion"
        case .navigation: return "Back/Forward buttons"
        }
    }
}

/// The matching table: bundle-id exception lists resolved against a snapshot of
/// running apps. Pure and value-typed on purpose — the scope separation and the
/// empty-list short-circuit are the parts worth testing, and neither needs
/// UserDefaults or live apps to test.
struct MouseExceptionSet {
    private let pids: [MouseScope: Set<pid_t>]

    /// True when no scope has any exception, so callers can skip the pointer
    /// lookup entirely. This is the common case and the reason the hot path is free.
    let allEmpty: Bool

    init(lists: [MouseScope: [String]] = [:],
         running: [(pid: pid_t, bundleId: String?)] = []) {
        var byScope: [MouseScope: Set<pid_t>] = [:]
        var empty = true
        for scope in MouseScope.allCases {
            let ids = Set(lists[scope] ?? [])
            guard !ids.isEmpty else { continue }
            empty = false
            byScope[scope] = Set(running.compactMap { ids.contains($0.bundleId ?? "") ? $0.pid : nil })
        }
        pids = byScope
        allEmpty = empty
    }

    /// Excepted apps that aren't running have no pid, so they can't match — which
    /// is correct: a dead app owns no window and is never frontmost.
    func excludes(_ pid: pid_t?, _ scope: MouseScope) -> Bool {
        guard let pid, let set = pids[scope] else { return false }
        return set.contains(pid)
    }
}

/// Live wrapper: keeps a `MouseExceptionSet` current and answers the two
/// questions the services actually have.
@MainActor
final class MouseExceptions {
    static let shared = MouseExceptions()

    private(set) var table = MouseExceptionSet()
    var allEmpty: Bool { table.allEmpty }

    /// Pointer→owning-pid cache. Valid while the pointer is still inside the
    /// window we last resolved AND the entry is younger than `cacheTTL`; a
    /// window that moved out from under a parked pointer is picked up on expiry.
    private var cachedPid: pid_t?
    private var cachedBounds: CGRect = .null
    private var cachedAt: CFTimeInterval = 0
    private let cacheTTL: CFTimeInterval = 0.5

    private init() {
        reload()
        let nc = NSWorkspace.shared.notificationCenter
        // Launch/terminate is what changes the pid↔bundle mapping; activation is
        // the moment a stale set would be visible to `excludesActionTarget`.
        for name: NSNotification.Name in [NSWorkspace.didLaunchApplicationNotification,
                                          NSWorkspace.didTerminateApplicationNotification,
                                          NSWorkspace.didActivateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    /// Re-read the lists and rebuild the pid sets. Called on workspace changes and
    /// by Settings after an edit — never from an event callback.
    func reload() {
        var lists: [MouseScope: [String]] = [:]
        for scope in MouseScope.allCases { lists[scope] = Preferences.mouseExceptions(scope) }
        table = MouseExceptionSet(
            lists: lists,
            running: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.bundleIdentifier) })
        cachedBounds = .null   // the answer for a cached pid may have changed
    }

    /// Scroll: the event is delivered to the window under the pointer, so that is
    /// the app whose preference decides.
    func excludesPointerTarget(_ scope: MouseScope) -> Bool {
        guard !table.allEmpty else { return false }
        return table.excludes(pointerPid(), scope)
    }

    /// Buttons: the click happens under the pointer but the synthesized Back/Forward
    /// keystroke lands in the frontmost app, so that is the app that decides.
    func excludesActionTarget(_ scope: MouseScope) -> Bool {
        guard !table.allEmpty else { return false }
        return table.excludes(NSWorkspace.shared.frontmostApplication?.processIdentifier, scope)
    }

    /// Owning pid of the topmost normal window under the cursor, cached.
    private func pointerPid() -> pid_t? {
        let loc = CGEvent(source: nil)?.location ?? .zero
        let now = CACurrentMediaTime()
        if now - cachedAt < cacheTTL, cachedBounds.contains(loc) { return cachedPid }
        let hit = WindowManager.serverWindowUnderCursor()
        cachedPid = hit?.pid
        // No window under the pointer (desktop, or a non-normal layer): hold the
        // "nobody" answer for the full TTL instead of re-scanning the window list
        // on every event. `.infinite` contains every point, so movement alone
        // doesn't invalidate it — expiry does.
        cachedBounds = hit?.bounds ?? .infinite
        cachedAt = now
        return cachedPid
    }
}
