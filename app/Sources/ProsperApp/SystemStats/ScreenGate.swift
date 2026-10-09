import AppKit

/// #186/#217: whether anyone can see the widgets. Pure, so the pause decision —
/// including the self-heal on popover open — is testable without AppKit.
struct ScreenGate: Equatable {
    enum Event { case sleep, wake, lock, unlock, popoverShown }
    /// The notifications that drive the gate (the controller observes exactly these).
    static let notifications: [(Notification.Name, Event)] = [
        (NSWorkspace.screensDidSleepNotification, .sleep),
        (NSWorkspace.screensDidWakeNotification, .wake),
        (Notification.Name("com.apple.screenIsLocked"), .lock),
        (Notification.Name("com.apple.screenIsUnlocked"), .unlock),
    ]
    enum Center { case workspace, distributed }
    /// Lock/unlock exist only as distributed notifications; sleep/wake are NSWorkspace's.
    static func center(for e: Event) -> Center { e == .lock || e == .unlock ? .distributed : .workspace }
    var displayAsleep = false
    var screenLocked = false
    var hidden: Bool { displayAsleep || screenLocked }

    /// Popover delegate reconcile: only a shown popover clears a stale pause.
    mutating func reconcile(popoverShown: Bool) { if popoverShown { apply(.popoverShown) } }

    mutating func apply(_ e: Event) {
        switch e {
        case .sleep: displayAsleep = true
        case .wake: displayAsleep = false
        case .lock: screenLocked = true
        case .unlock: screenLocked = false
        // A missed wake/unlock (fast user switch, login-window round trip) would
        // otherwise freeze the values until the next lock cycle; a click on our
        // menu-bar item can only happen on a lit, unlocked screen.
        case .popoverShown: displayAsleep = false; screenLocked = false
        }
    }
}
