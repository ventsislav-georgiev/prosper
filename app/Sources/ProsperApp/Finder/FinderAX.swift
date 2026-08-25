import ApplicationServices
import Foundation

/// The focused element's AX role, asked of ONE app.
///
/// This runs inside the shared keystroke tap, on the main run loop — the whole
/// session's typing is blocked until it answers — so two things matter. The
/// timeout is hard and short: a Finder stuck on a share that went away is
/// exactly the app that stops replying, and 0.1s is under the threshold where a
/// keystroke feels dropped. And the question goes to the app the tap already
/// knows is frontmost rather than to the system-wide element, so a different
/// hung app can never be the one that answers (or fails to).
///
/// Never cache the answer: focus moves without any event this tap sees, and a
/// stale "not editing" verdict is precisely the bug that eats a rename.
enum FinderAX {
    static func focusedRole(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXFocusedUIElement" as CFString, &focused) == .success,
              let focused,
              // Type-check before casting: an unexpected CF type must degrade
              // gracefully inside the tap, never trap.
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var roleRef: CFTypeRef?
        // Safe: the type id was just checked above.
        // swiftlint:disable:next force_cast
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, "AXRole" as CFString, &roleRef) == .success
        else { return nil }
        return roleRef as? String
    }
}
