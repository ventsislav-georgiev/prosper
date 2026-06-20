import Foundation

/// Pure, dependency-free state machine behind the lid-sleep daemon. No threading,
/// no XPC, no process control: the daemon serializes every call on its private
/// queue and injects `apply` (the privileged `pmset` toggle) and `onIdle` (process
/// exit). Pulled out of the executable target precisely so the safety-critical
/// rule — NEVER leave the lid wedged awake when the last client drops or crashes —
/// is unit-testable without root or launchd.
///
/// Not thread-safe by design; the caller owns serialization.
// ponytail: lives in the shared contract lib (the only SwiftPM target a test can
// import) so the daemon's risk logic gets coverage; the app links it unused.
public final class LidHelperCore {
    private let apply: (Bool) -> Bool
    private let onIdle: () -> Void

    public private(set) var connections = 0
    /// Whether the clamshell-sleep override is currently applied.
    public private(set) var overrideOn = false

    public init(apply: @escaping (Bool) -> Bool, onIdle: @escaping () -> Void) {
        self.apply = apply
        self.onIdle = onIdle
    }

    /// A client connected. Caller must cancel any pending idle-exit timer.
    public func connectionOpened() {
        connections += 1
    }

    /// A client disconnected (clean OR crash). Resets the override when the last
    /// client drops so a crashed app never leaves the lid disabled. Returns true
    /// when no clients remain → caller should arm the idle-exit timer.
    @discardableResult
    public func connectionClosed() -> Bool {
        connections = max(0, connections - 1)
        guard connections == 0 else { return false }
        if overrideOn {
            _ = apply(false)
            overrideOn = false
        }
        return true
    }

    /// Force the override OFF at daemon cold-start, self-healing a value left
    /// stuck by an unclean kill. Safe by invariant: a valid override always holds
    /// a live connection, which keeps the daemon alive — so it never cold-starts
    /// while a legitimate override exists. Only a stale value can be present here,
    /// and a client that still wants it on reconnects and re-applies.
    public func reclaimAtStartup() {
        _ = apply(false)
        overrideOn = false
    }

    /// Apply the override on explicit request. Tracks state only when the
    /// privileged op reports success. Returns whether it took effect.
    @discardableResult
    public func setOverride(_ on: Bool) -> Bool {
        let ok = apply(on)
        if ok { overrideOn = on }
        return ok
    }

    /// Idle-exit timer fired: exit via `onIdle` only if no client reconnected in
    /// the window. A late reconnect leaves `connections > 0` and we stay alive.
    public func idleFired() {
        if connections == 0 { onIdle() }
    }
}
