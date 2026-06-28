import AppKit
import CoreGraphics

/// EXPERIMENTAL programmatic menu-bar reorder via a synthesized ⌘-drag — the same
/// gesture a user performs by hand, posted as CGEvents. This is the single most
/// fragile area of any menu-bar manager (Ice's top bug source): it drives another
/// app's status item by synthetic input. It is therefore:
///   - default OFF (`MenuBarStore.reorderEnabled`),
///   - gated on Accessibility (posting events to other processes needs it),
///   - never required for the core hide feature (manual ⌘-drag always works).
///
/// ponytail: this reproduces the *behavioral* ⌘-drag, NOT Ice's full set of
/// undocumented `CGEvent` integer fields (window-under-pointer target ids etc.).
/// That extra plumbing is what breaks subtly across macOS point releases; the
/// plain gesture is more robust at the cost of occasionally missing on a fast
/// machine — hence the bounded async confirm + retry below. Upgrade path: add the
/// private fields only if real-world misses prove too frequent.
@MainActor
enum MenuBarReorder {
    enum Destination {
        case leftOf(CGRect)    // target item's frame
        case rightOf(CGRect)
    }

    /// True only when reorder is enabled AND Accessibility is granted. Prompts for
    /// AX when enabling (caller decides whether to prompt).
    static func isEnabled() -> Bool {
        Preferences.menuBarStore.reorderEnabled && PermissionsManager.isAccessibilityTrusted()
    }

    /// Move the status item at `itemFrame` to a destination, confirming the move by
    /// polling for its frame to change. Async + bounded (no main-thread spin).
    /// `completion(true)` once the frame moves; `completion(false)` on timeout.
    static func move(itemFrame: CGRect, to destination: Destination, windowID: CGWindowID,
                     attempts: Int = 2, completion: @escaping (Bool) -> Void) {
        guard isEnabled() else { completion(false); return }

        // Don't fight a real user drag: only start when no mouse button is down and
        // no modifiers are held.
        guard CGEventSource(stateID: .combinedSessionState)
                .map({ _ in NSEvent.pressedMouseButtons == 0 }) ?? true,
              NSEvent.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty else {
            completion(false); return
        }

        let start = CGPoint(x: itemFrame.midX, y: itemFrame.midY)
        let end: CGPoint
        switch destination {
        case .leftOf(let f): end = CGPoint(x: f.minX - 2, y: f.midY)
        case .rightOf(let f): end = CGPoint(x: f.maxX + 2, y: f.midY)
        }

        postCmdDrag(from: start, to: end)

        // Confirm asynchronously: a few checks with backoff, then retry or give up.
        confirmMoved(windowID: windowID, originalX: itemFrame.minX, checks: 5, interval: 0.03) { moved in
            if moved { completion(true) }
            else if attempts > 1 {
                move(itemFrame: itemFrame, to: destination, windowID: windowID,
                     attempts: attempts - 1, completion: completion)
            } else {
                NSLog("prosper: menu-bar reorder did not confirm (frame unchanged)")
                completion(false)
            }
        }
    }

    // MARK: - Private

    private static func postCmdDrag(from start: CGPoint, to end: CGPoint) {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let cmd = CGEventFlags.maskCommand
        let tap = CGEventTapLocation.cgSessionEventTap

        func post(_ type: CGEventType, _ pt: CGPoint) {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type,
                                  mouseCursorPosition: pt, mouseButton: .left) else { return }
            e.flags = cmd
            e.post(tap: tap)
        }

        post(.leftMouseDown, start)
        // A handful of intermediate drag points so the OS registers a real drag,
        // not a click. Cheap integer interpolation.
        let steps = 8
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t,
                                            y: start.y + (end.y - start.y) * t))
        }
        post(.leftMouseUp, end)
    }

    private static func confirmMoved(windowID: CGWindowID, originalX: CGFloat,
                                     checks: Int, interval: TimeInterval,
                                     done: @escaping (Bool) -> Void) {
        guard checks > 0 else { done(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            if let f = MenuBarBridge.items(onDisplay: CGMainDisplayID())
                .first(where: { $0.windowID == windowID })?.frame,
               abs(f.minX - originalX) > 2 {
                done(true)
            } else {
                confirmMoved(windowID: windowID, originalX: originalX,
                             checks: checks - 1, interval: interval, done: done)
            }
        }
    }
}
