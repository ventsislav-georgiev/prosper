import AppKit
import CoreGraphics

// Synthetic ⌘-drag move primitive for the ordering engine (Phase 2).
//
// macOS exposes no API to set a status item's position; the only lever is
// synthesizing the user's own ⌘-drag. This is a focused port of Ice's
// `MenuBarItemManager` move path: build a menu-bar mouse event aimed at a specific
// window id, deliver it via the "scromble" two-tap handshake (post a sentinel,
// catch it, then post the real event and wait for it to surface), confirm the
// item's frame actually changed, retry, and restore the cursor. This is the
// fragility epicenter — it touches private CGEvent fields and the live cursor —
// so every caller gates it behind the opt-in + OS version + the runtime
// `selfProbe()` below, which proves the whole pipeline on throwaway items before
// any real item is touched. See .omc/plans/menubar-ordering-engine.md.

// MARK: - Errors

enum MenuBarMoveError: Error, Equatable {
    case notAvailable          // CGS bridge down
    case noEventSource
    case eventCreationFailed
    case invalidFrame
    case timedOut
    case didNotMove            // frame never changed after all retries
    case landedWrongSide       // moved, but ended on the wrong side of the anchor
    case modifiersHeld         // user holding keys — refused rather than fight them
}

// MARK: - Cursor helpers

private enum MoveCursor {
    static var location: CGPoint? { CGEvent(source: nil)?.location }
    static func hide() { CGDisplayHideCursor(CGMainDisplayID()) }
    static func show() { CGDisplayShowCursor(CGMainDisplayID()) }
    static func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // Re-couple cursor to the physical mouse (warp disassociates briefly).
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

// The generic CGEvent tap this file used to own now lives in EventTap.swift —
// the mouse module shares it. The scromble callbacks below `return nil` to keep
// swallowing, now that `EventTap.dispatch` honours the callback's return.

// MARK: - The mover

@MainActor
enum MenuBarItemMover {
    /// A destination relative to a neighbor window.
    enum Destination {
        case leftOf(CGWindowID)
        case rightOf(CGWindowID)
        var anchor: CGWindowID { switch self { case .leftOf(let w), .rightOf(let w): w } }
    }

    private static let windowIDField = CGEventField(rawValue: 0x33)!   // undocumented "window id" field
    private static let matchFields: [CGEventField] = [
        .eventSourceUserData, .mouseEventWindowUnderMousePointer,
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent, windowIDField,
    ]

    /// LAZY cursor parking around a BATCH of moves. Entering does NOT touch the
    /// cursor — a batch where every move early-returns (already positioned / order
    /// satisfied) must be invisible to the user. The first move that actually posts
    /// a synthetic drag calls `ensureParked()` (hide + remember position); batch
    /// exit restores only if something parked. One park per batch — instead of per
    /// `move()` — minimizes the window in which a crash could leave the cursor
    /// hidden and avoids per-move hide/show flicker.
    private static var batchDepth = 0
    private static var parkedAt: CGPoint?

    static func withCursorParked<T>(_ body: () async throws -> T) async rethrows -> T {
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0, let p = parkedAt {
                parkedAt = nil
                MoveCursor.warp(to: p)
                MoveCursor.show()
            }
        }
        return try await body()
    }

    /// Hide the cursor the moment a real drag is about to post (no-op when already
    /// parked, or when called outside a batch — every caller wraps, this is a belt).
    private static func ensureParked() {
        guard batchDepth > 0, parkedAt == nil, let location = MoveCursor.location else { return }
        parkedAt = location
        MoveCursor.hide()
    }

    /// Move `windowID` (owned by `pid`) next to its destination anchor. The CALLER
    /// parks the cursor (see `withCursorParked`) and pauses its own event monitors.
    /// Throws on any failure so the arranger can trip its circuit breaker.
    static func move(windowID: CGWindowID, pid: pid_t, to destination: Destination) async throws {
        guard MenuBarBridge.available else { throw MenuBarMoveError.notAvailable }
        guard !modifiersHeld() else { throw MenuBarMoveError.modifiersHeld }
        guard let initialFrame = MenuBarBridge.frame(for: windowID) else { throw MenuBarMoveError.invalidFrame }
        if isAlreadyPositioned(windowID: windowID, destination: destination) { return }

        ensureParked()   // real drag imminent — hide the cursor now (lazy, once per batch)
        var lastError: Error = MenuBarMoveError.didNotMove
        for attempt in 1...5 {
            do {
                try await postMove(windowID: windowID, pid: pid, to: destination)
                guard let newFrame = MenuBarBridge.frame(for: windowID), newFrame != initialFrame else {
                    throw MenuBarMoveError.didNotMove
                }
                // A frame CHANGE is not a frame LANDING: real mouse motion mid-drag
                // (the user grabbing the pointer while a synthetic ⌘-drag is in
                // flight) merges into the drag session and drops the item at an
                // arbitrary x — the old change-only check reported that corrupted
                // drop as success, which is how the chevron once ended up LEFT of
                // the hidden separator (hiding the click target itself). Confirm the
                // item ended on the correct SIDE of its anchor; re-check once after
                // a short settle so a mid-reflow read doesn't fail a good move.
                if landedOnCorrectSide(windowID: windowID, destination: destination) { return }
                try? await Task.sleep(for: .milliseconds(60))
                if landedOnCorrectSide(windowID: windowID, destination: destination) { return }
                throw MenuBarMoveError.landedWrongSide
            } catch {
                lastError = error
                if attempt < 5 { try? await wakeUp(windowID: windowID, pid: pid) }
            }
        }
        throw lastError
    }

    /// Why the self-probe couldn't confirm ordering — surfaced so the UI can tell the
    /// user "grant Accessibility" (fixable) apart from "this Mac can't do it" (not).
    enum ProbeResult: Equatable {
        case ok
        case needsAccessibility   // Accessibility not granted — synthetic drag can't post
        case unavailable          // CGS bridge down (private symbols gone)
        case enumerationFailed    // couldn't see our own throwaway windows (frame-match)
        case moveFailed           // Accessibility granted but the drag didn't take effect
    }

    /// Set once the probe has confirmed the move pipeline works this session. The
    /// mechanism is a fixed OS capability — once it passes it can't stop working — so a
    /// later caller (every Settings visit re-runs the probe) reuses this instead of
    /// firing another synthetic ⌘-drag that can race a concurrent bar operation (the
    /// preview reveal) and spuriously fail. `force: true` ("Run move test again")
    /// bypasses it. Failures are NOT cached — they're often transient and must retry.
    private static var passedThisSession = false

    /// Runtime gate: prove the move pipeline works on this exact OS by moving a
    /// throwaway status item we own, then tearing it down. Never throws — returns a
    /// reason the caller maps to UI. Logs each gate (the user runs with troubleshooting
    /// logs) so a failure on a new OS is diagnosable from Console.
    ///
    /// Transient `.moveFailed`/`.enumerationFailed` (Tahoe timing, or a concurrent bar
    /// op) are retried a few times before being reported, and a once-passed result is
    /// cached for the session — so re-opening Settings doesn't re-drag and re-race.
    static func selfProbe(force: Bool = false) async -> ProbeResult {
        if passedThisSession && !force { return .ok }
        // Don't drag against a bar whose separators are mid-toggle (preview refresh).
        for _ in 0..<20 where MenuBarManager.shared.isPlacing {
            try? await Task.sleep(for: .milliseconds(50))
        }
        var last: ProbeResult = .moveFailed
        for attempt in 1...3 {
            let r = await probeOnce()
            if r == .ok { passedThisSession = true; return r }
            // Permanent verdicts: don't waste retries on them.
            if r == .needsAccessibility || r == .unavailable { return r }
            last = r
            if attempt < 3 { try? await Task.sleep(for: .milliseconds(150)) }
        }
        return last
    }

    private static func probeOnce() async -> ProbeResult {
        guard MenuBarBridge.available else {
            NSLog("prosper: menu-bar ordering self-probe — CGS bridge unavailable")
            return .unavailable
        }
        // Synthetic ⌘-drag is posted through a session event tap; that requires
        // Accessibility. Without it the move silently no-ops and would look like a
        // dead mechanism — check up front so we can ask for the grant instead.
        guard PermissionsManager.isAccessibilityTrusted() else {
            NSLog("prosper: menu-bar ordering self-probe — Accessibility not granted")
            return .needsAccessibility
        }
        let a = NSStatusBar.system.statusItem(withLength: 24)
        let b = NSStatusBar.system.statusItem(withLength: 24)
        a.button?.title = "◐"; b.button?.title = "◑"
        defer { NSStatusBar.system.removeStatusItem(a); NSStatusBar.system.removeStatusItem(b) }

        // Poll for layout instead of a fixed sleep: on Tahoe the status windows can
        // take >120 ms to attach + position, and a too-early frame read makes the
        // frame-match miss (looked like a dead mechanism). Wait until BOTH throwaway
        // items have distinct CGS windows, up to ~1.2 s.
        var matched: (wa: CGWindowID, wb: CGWindowID)?
        for _ in 0..<24 {
            try? await Task.sleep(for: .milliseconds(50))
            guard let xA = a.button?.window?.frame.minX, let xB = b.button?.window?.frame.minX,
                  let wa = MenuBarBridge.windowID(forItemMinX: xA),
                  let wb = MenuBarBridge.windowID(forItemMinX: xB), wa != wb else { continue }
            matched = (wa, wb); break
        }
        guard let (wa, wb) = matched else {
            NSLog("prosper: menu-bar ordering self-probe — frame-match failed after poll (xA=\(a.button?.window?.frame.minX ?? -1) xB=\(b.button?.window?.frame.minX ?? -1))")
            return .enumerationFailed
        }
        let pid = getpid()
        guard let fa = MenuBarBridge.frame(for: wa), let fb = MenuBarBridge.frame(for: wb),
              fa.width > 0, fb.width > 0, abs(fa.minY - fb.minY) < 2 else {
            NSLog("prosper: menu-bar ordering self-probe — bad probe frames")
            return .enumerationFailed
        }

        // Whichever sits on the right, move it to the left of the other — a real,
        // observable position change using the exact same machinery as live moves.
        let (mover, anchor) = fa.minX > fb.minX ? (wa, wb) : (wb, wa)
        do {
            try await withCursorParked { try await move(windowID: mover, pid: pid, to: .leftOf(anchor)) }
            return .ok
        } catch {
            NSLog("prosper: menu-bar ordering self-probe — move failed: \(error)")
            return .moveFailed
        }
    }

    // MARK: - Internals

    private static func modifiersHeld() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.contains(.maskCommand) || flags.contains(.maskShift)
            || flags.contains(.maskControl) || flags.contains(.maskAlternate)
    }

    /// Cheap "already there?" short-circuit. A transient nil frame (anchor app
    /// relaunching) returns false rather than throwing — the retry/landing-confirm
    /// path handles a genuinely-gone anchor; a hard throw here would wrongly count a
    /// blip as a failed move and feed the breaker.
    private static func isAlreadyPositioned(windowID: CGWindowID, destination: Destination) -> Bool {
        guard let f = MenuBarBridge.frame(for: windowID),
              let t = MenuBarBridge.frame(for: destination.anchor) else { return false }
        switch destination {
        case .leftOf:  return f.maxX == t.minX
        case .rightOf: return f.minX == t.maxX
        }
    }

    /// Directional landing confirmation: the moved item sits on the intended side of
    /// its anchor. Anchor frame gone (app relaunching) → true; can't judge, and the
    /// caller's own drift check will catch a genuinely wrong layout later.
    private static func landedOnCorrectSide(windowID: CGWindowID, destination: Destination) -> Bool {
        guard let f = MenuBarBridge.frame(for: windowID),
              let t = MenuBarBridge.frame(for: destination.anchor) else { return true }
        switch destination {
        case .leftOf:  return f.minX < t.minX
        case .rightOf: return f.minX > t.minX
        }
    }

    private static func endPoint(for destination: Destination) throws -> CGPoint {
        guard let t = MenuBarBridge.frame(for: destination.anchor) else { throw MenuBarMoveError.invalidFrame }
        switch destination {
        case .leftOf:  return CGPoint(x: t.minX, y: t.midY)
        case .rightOf: return CGPoint(x: t.maxX, y: t.midY)
        }
    }

    private static func postMove(windowID: CGWindowID, pid: pid_t, to destination: Destination) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw MenuBarMoveError.noEventSource }
        let start = CGPoint(x: 20_000, y: 20_000)               // off-bar pickup point (Ice's trick)
        let end = try endPoint(for: destination)

        guard let down = makeEvent(.leftMouseDown, at: start, windowID: windowID, pid: pid, source: source),
              let up = makeEvent(.leftMouseUp, at: end, windowID: destination.anchor, pid: pid, source: source) else {
            throw MenuBarMoveError.eventCreationFailed
        }
        permitAllEvents(source: source)
        try await scromble(down, from: .pid(pid), to: .session, confirmFrameChangeOf: windowID)
        try await scromble(up, from: .pid(pid), to: .session, confirmFrameChangeOf: windowID)
    }

    private static func wakeUp(windowID: CGWindowID, pid: pid_t) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let frame = MenuBarBridge.frame(for: windowID) else { return }
        let mid = CGPoint(x: frame.midX, y: frame.midY)
        guard let down = makeEvent(.leftMouseDown, at: mid, windowID: windowID, pid: pid, source: source),
              let up = makeEvent(.leftMouseUp, at: mid, windowID: windowID, pid: pid, source: source) else { return }
        try await scromble(down, from: .pid(pid), to: .session, confirmFrameChangeOf: nil)
        try await scromble(up, from: .pid(pid), to: .session, confirmFrameChangeOf: nil)
    }

    private static func permitAllEvents(source: CGEventSource) {
        for state in [CGEventSuppressionState.eventSuppressionStateRemoteMouseDrag,
                      .eventSuppressionStateSuppressionInterval] {
            source.setLocalEventsFilterDuringSuppressionState(
                [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents], state: state)
        }
        source.localEventsSuppressionInterval = 0
    }

    /// Build a menu-bar mouse event aimed at a specific status-item window. The
    /// undocumented field-stuffing (window-under-pointer + window id + ⌘ on the
    /// down event) is what makes the window server route it to that item as a drag.
    private static func makeEvent(_ type: CGEventType, at location: CGPoint,
                                  windowID: CGWindowID, pid: pid_t, source: CGEventSource) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: location, mouseButton: .left) else { return nil }
        event.flags = (type == .leftMouseDown) ? .maskCommand : []
        let wid = Int64(windowID)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        event.setIntegerValueField(.eventSourceUserData,
                                   value: Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(event))))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: wid)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: wid)
        event.setIntegerValueField(windowIDField, value: wid)
        return event
    }

    private static func eventsMatch(_ a: CGEvent, _ b: CGEvent) -> Bool {
        matchFields.allSatisfy { a.getIntegerValueField($0) == b.getIntegerValueField($0) }
    }

    /// The "scromble": post a sentinel null event to `first`, catch it there, then
    /// post the real event to `second`, listen for it to surface, then re-post it
    /// to `first` so the target actually consumes it. Optionally wait for the
    /// observed item's frame to change. This double-bounce is what makes delivery
    /// reliable across recent macOS — a plain post often no-ops.
    private static func scromble(_ event: CGEvent, from first: EventTap.Location,
                                 to second: EventTap.Location,
                                 confirmFrameChangeOf windowID: CGWindowID?) async throws {
        let initialFrame = windowID.flatMap { MenuBarBridge.frame(for: $0) }
        try await deliver(event, from: first, to: second)
        if let windowID, let initialFrame {
            try await waitForFrameChange(windowID: windowID, from: initialFrame, timeout: .milliseconds(50))
        }
    }

    private static func deliver(_ event: CGEvent, from first: EventTap.Location,
                                to second: EventTap.Location) async throws {
        guard let nullEvent = CGEvent(source: nil) else { throw MenuBarMoveError.eventCreationFailed }
        let nullUserData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(nullEvent)))
        nullEvent.setIntegerValueField(.eventSourceUserData, value: nullUserData)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var tap1: EventTap?
            var tap2: EventTap?
            // Single-shot guard: the success callback and the timeout closure both run
            // on the main actor, but their ordering near the 50 ms boundary isn't
            // guaranteed — without this, a near-simultaneous fire would resume the
            // CheckedContinuation twice and trap. First resume wins.
            var resumed = false
            let finish: @MainActor (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                tap1?.disable(); tap2?.disable()
                cont.resume(with: result)
            }

            tap1 = EventTap(label: "scromble-1", options: .defaultTap, location: first,
                            types: [nullEvent.type]) { proxy, type, rEvent in
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout { proxy.enable(); return nil }
                guard rEvent.getIntegerValueField(.eventSourceUserData) == nullUserData else { return nil }
                proxy.disable()
                post(event, to: second)
                return nil
            }
            tap2 = EventTap(label: "scromble-2", options: .listenOnly, location: second,
                            types: [event.type]) { proxy, type, rEvent in
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout { proxy.enable(); return nil }
                guard eventsMatch(rEvent, event), proxy.isEnabled else { return nil }
                proxy.disable()
                post(event, to: first)
                finish(.success(()))
                return nil
            }

            tap1?.enable()
            tap2?.enable(timeout: .milliseconds(50)) {
                finish(.failure(MenuBarMoveError.timedOut))
            }
            post(nullEvent, to: first)
            _ = (tap1, tap2)   // keep alive until continuation resumes
        }
    }

    private static func post(_ event: CGEvent, to location: EventTap.Location) {
        switch location {
        case .session: event.post(tap: .cgSessionEventTap)
        case .annotatedSession: event.post(tap: .cgAnnotatedSessionEventTap)
        case .hid: event.post(tap: .cghidEventTap)
        case .pid(let pid): event.postToPid(pid)
        }
    }

    private static func waitForFrameChange(windowID: CGWindowID, from initial: CGRect,
                                           timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let f = MenuBarBridge.frame(for: windowID), f != initial { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        // Fixed-delay fallback (matches Ice): don't hard-fail, give the next event a chance.
        try? await Task.sleep(for: .milliseconds(50))
    }
}
