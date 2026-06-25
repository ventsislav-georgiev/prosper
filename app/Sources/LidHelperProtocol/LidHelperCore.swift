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
    /// Whether the lid (clamshell) sleep override source is currently held.
    public private(set) var overrideOn = false
    /// Whether the remote-session keep-awake source is currently held. Independent
    /// of `overrideOn`; the effective `disablesleep` is the OR of the two.
    public private(set) var remoteHoldOn = false

    public init(apply: @escaping (Bool) -> Bool, onIdle: @escaping () -> Void) {
        self.apply = apply
        self.onIdle = onIdle
    }

    /// Push the OR of both sources to pmset. Both the lid override and the remote-
    /// session hold disable sleep; sleep is only re-enabled when NEITHER holds. The
    /// caller commits a source's flag only on a successful apply.
    @discardableResult
    private func applyEffective(lid: Bool, remote: Bool) -> Bool {
        apply(lid || remote)
    }

    /// A client connected. Caller must cancel any pending idle-exit timer.
    public func connectionOpened() {
        connections += 1
    }

    /// A client disconnected (clean OR crash). Releases the LID override when the
    /// last client drops so a crashed app never leaves the lid wedged disabled. The
    /// remote-session hold is NOT touched here — it isn't tied to a client (the
    /// daemon is resident with zero clients during the poll loop) and has its own
    /// timed expiry. Returns true when no clients remain → caller arms idle-exit.
    @discardableResult
    public func connectionClosed() -> Bool {
        connections = max(0, connections - 1)
        guard connections == 0 else { return false }
        if overrideOn {
            _ = applyEffective(lid: false, remote: remoteHoldOn)
            overrideOn = false
        }
        return true
    }

    /// Force BOTH sources OFF at daemon cold-start, self-healing a value left stuck
    /// by an unclean kill. Safe by invariant: a valid lid override always holds a
    /// live connection (keeps the daemon alive), and the remote hold's expiry never
    /// outlives a process restart — so a cold start can only find stale values, and
    /// a client/heartbeat that still wants them on re-asserts.
    public func reclaimAtStartup() {
        _ = applyEffective(lid: false, remote: false)
        overrideOn = false
        remoteHoldOn = false
    }

    /// Apply the lid override on explicit request. Tracks state only when the
    /// privileged op reports success. Returns whether it took effect.
    @discardableResult
    public func setOverride(_ on: Bool) -> Bool {
        let ok = applyEffective(lid: on, remote: remoteHoldOn)
        if ok { overrideOn = on }
        return ok
    }

    /// Apply the remote-session keep-awake hold. Same OR semantics as `setOverride`:
    /// turning it off leaves sleep disabled if the lid override still holds, and
    /// vice-versa. Tracks state only on a successful apply.
    @discardableResult
    public func setRemoteHold(_ on: Bool) -> Bool {
        let ok = applyEffective(lid: overrideOn, remote: on)
        if ok { remoteHoldOn = on }
        return ok
    }

    /// Idle-exit timer fired: exit via `onIdle` only if no client reconnected in
    /// the window. A late reconnect leaves `connections > 0` and we stay alive.
    public func idleFired() {
        if connections == 0 { onIdle() }
    }
}
