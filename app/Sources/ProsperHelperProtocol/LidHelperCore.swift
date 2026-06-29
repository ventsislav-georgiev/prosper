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
    /// Whether the current remote hold is STICKY — set by a remote-wake promote.
    /// A sticky hold must survive the heartbeat TTL expiry AND a session-idle soft
    /// release (`setRemoteHold(false)`); only a hard release clears it — the user
    /// opening the lid (`clearRemoteHold`) or an explicit sleep (`reclaimAtStartup`).
    /// This is the rule "once the Mac is woken remotely it stays awake until the
    /// user explicitly sleeps it".
    public private(set) var remoteHoldSticky = false

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
        remoteHoldSticky = false
    }

    /// Apply the lid override on explicit request. Tracks state only when the
    /// privileged op reports success. Returns whether it took effect.
    @discardableResult
    public func setOverride(_ on: Bool) -> Bool {
        let ok = applyEffective(lid: on, remote: remoteHoldOn)
        if ok { overrideOn = on }
        return ok
    }

    /// Apply the transient remote-session keep-awake hold (the live-session
    /// heartbeat). Same OR semantics as `setOverride`. `false` is a SOFT release —
    /// ignored while a sticky promote hold is in effect, so a session going idle
    /// (or its TTL lapsing) can't drop a Mac that was remote-woken and is meant to
    /// stay awake until an explicit sleep. `true` never downgrades stickiness.
    /// Tracks state only on a successful apply.
    @discardableResult
    public func setRemoteHold(_ on: Bool) -> Bool {
        if !on && remoteHoldSticky { return true }   // soft release ignored while sticky
        let ok = applyEffective(lid: overrideOn, remote: on)
        if ok { remoteHoldOn = on }
        return ok
    }

    /// Hold sleep open STICKILY for a remote-wake-promoted session. Unlike
    /// `setRemoteHold(true)` this persists past the heartbeat TTL and a session-idle
    /// soft release — only `clearRemoteHold` (lid opened) or `reclaimAtStartup`
    /// (explicit sleep) releases it. Tracks state only on a successful apply.
    @discardableResult
    public func promoteRemoteHold() -> Bool {
        let ok = applyEffective(lid: overrideOn, remote: true)
        if ok { remoteHoldOn = true; remoteHoldSticky = true }
        return ok
    }

    /// Hard release of the remote-session hold regardless of stickiness — the lid
    /// was opened (the user is physically present), so the clamshell keep-awake is
    /// meaningless and must reset. Leaves the lid override untouched (OR semantics).
    @discardableResult
    public func clearRemoteHold() -> Bool {
        remoteHoldSticky = false
        let ok = applyEffective(lid: overrideOn, remote: false)
        if ok { remoteHoldOn = false }
        return ok
    }

    /// Idle-exit timer fired: exit via `onIdle` only if no client reconnected in
    /// the window. A late reconnect leaves `connections > 0` and we stay alive.
    public func idleFired() {
        if connections == 0 { onIdle() }
    }
}
